// Source-level leaf certificate pinning, ported from pinning prototype 0.1.
// Identity is the leaf certificate SHA-256 of one sourceID+host+port. No system trust store
// mutation, no unconditional accept, no silent pin replacement.
// The native helper only performs HTTPS and leaf evaluation; DSM business logic stays in Dart.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
// 只为了 lenientNonnegativeInt（宽松整数）。protocol.dart 不反向依赖本文件，
// 不会形成环。
import 'protocol.dart';
import 'sha256.dart';

String fingerprint(X509Certificate cert) => sha256Hex(cert.der);

class SourceEndpoint {
  final String sourceID;
  final Uri uri;
  SourceEndpoint(this.sourceID, String endpoint) : uri = Uri.parse(endpoint) {
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,64}$').hasMatch(sourceID) ||
        uri.scheme != 'https' || uri.host.isEmpty || uri.userInfo.isNotEmpty ||
        uri.hasQuery || uri.hasFragment || (uri.path != '' && uri.path != '/') ||
        uri.port < 1 || uri.port > 65535) {
      throw StateError('UnsafeEndpoint');
    }
  }
  String get key => jsonEncode([sourceID, uri.host.toLowerCase(), uri.port]);
  Map<String, Object> toJson() => {
    'sourceID': sourceID, 'host': uri.host.toLowerCase(), 'port': uri.port,
    'endpoint': uri.replace(path: '', query: null, fragment: null).toString(),
  };
}

class CertificateCandidate {
  final SourceEndpoint endpoint;
  final X509Certificate cert;
  final String nonce;
  final List<String> reasons;
  final List<String> san;
  CertificateCandidate(this.endpoint, this.cert, this.reasons, this.san)
      : nonce = List.generate(24, (_) => Random.secure().nextInt(256))
          .map((n) => n.toRadixString(16).padLeft(2, '0')).join();
  String get digest => fingerprint(cert);
  bool get expired => DateTime.now().toUtc().isAfter(cert.endValidity.toUtc());
  Map<String, Object?> toJson() => {
    'state': 'certificateTrustRequired', ...endpoint.toJson(),
    'candidateID': nonce, 'subject': cert.subject, 'issuer': cert.issuer,
    'san': san, 'sha256': digest,
    'validFrom': cert.startValidity.toUtc().toIso8601String(),
    'validUntil': cert.endValidity.toUtc().toIso8601String(),
    'expired': expired, 'failureReasons': reasons,
  };
}

class TrustRequired implements Exception {
  final CertificateCandidate candidate;
  TrustRequired(this.candidate);
}

class NativeTransportError implements Exception {
  final String kind;
  final int? httpStatus;
  /// 助手报告的**响应体字节数**（只在「响应体不可用」这类失败上有值）。
  ///
  /// 它回答的是「到底是超过上限、还是根本不是 JSON、还是空响应」——
  /// 这三种原因的处理方式完全不同，而在此之前它们被压成同一个
  /// `ProtocolViolation`，诊断里只剩一句「响应不符合预期」。
  /// 这里只带**数字**，不含任何响应内容。
  final int? bytes;
  NativeTransportError(this.kind, this.httpStatus, {this.bytes});
}

class SourceTrustStore {
  final File file;
  final Map<String, Map<String, dynamic>> _records = {};
  final Map<String, CertificateCandidate> _pending = {};
  SourceTrustStore(this.file);
  Future<void> load() async {
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    if (type != FileSystemEntityType.file) throw StateError('UnsafeTrustStore');
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map || decoded['version'] != 1 || decoded['records'] is! Map) {
      throw StateError('InvalidTrustStore');
    }
    for (final entry in (decoded['records'] as Map).entries) {
      if (entry.key is! String || entry.value is! Map) throw StateError('InvalidTrustStore');
      final record = Map<String, dynamic>.from(entry.value as Map);
      final endpoint = SourceEndpoint(record['sourceID'] as String, record['endpoint'] as String);
      if (entry.key != endpoint.key || !RegExp(r'^[0-9a-f]{64}$').hasMatch(record['sha256'] as String)) {
        throw StateError('InvalidTrustStore');
      }
      _records[entry.key as String] = record;
    }
  }
  String? pin(SourceEndpoint endpoint) => _records[endpoint.key]?['sha256'] as String?;
  bool permitsExpired(SourceEndpoint endpoint) => _records[endpoint.key]?['allowExpired'] == true;
  void present(CertificateCandidate candidate) => _pending[candidate.endpoint.key] = candidate;
  void reject(SourceEndpoint endpoint) { _pending.remove(endpoint.key); }
  Future<void> confirm(SourceEndpoint endpoint, String candidateID, String digest,
      {required bool userConfirmed, required bool allowExpired}) async {
    final candidate = _pending[endpoint.key];
    if (!userConfirmed || candidate == null || candidate.nonce != candidateID ||
        candidate.digest != digest || (candidate.expired && !allowExpired)) {
      throw StateError('ExplicitCertificateConfirmationRequired');
    }
    final previous = _records[endpoint.key];
    _records[endpoint.key] = {
      ...endpoint.toJson(), 'sha256': digest, 'allowExpired': candidate.expired && allowExpired,
      'confirmedAt': DateTime.now().toUtc().toIso8601String(),
    };
    try { await _save(); }
    catch (_) { if (previous == null) { _records.remove(endpoint.key); } else { _records[endpoint.key] = previous; } rethrow; }
    _pending.remove(endpoint.key);
  }
  Future<void> _save() async {
    if (!await file.parent.exists()) throw StateError('TrustDirectoryRequired');
    var directory = file.parent.absolute;
    while (true) {
      if (await FileSystemEntity.type(directory.path, followLinks: false) != FileSystemEntityType.directory) {
        throw StateError('UnsafeTrustDirectory');
      }
      if (directory.parent.path == directory.path) break;
      directory = directory.parent;
    }
    if (await FileSystemEntity.type(file.path, followLinks: false) == FileSystemEntityType.link) {
      throw StateError('UnsafeTrustStore');
    }
    final temporary = File('${file.path}.${Random.secure().nextInt(1 << 32)}.tmp');
    try {
      await temporary.create(exclusive: true);
      final chmod = await Process.run('/bin/chmod', ['600', temporary.path]);
      if (chmod.exitCode != 0) throw StateError('TrustStorePermissions');
      await temporary.writeAsString(jsonEncode({'version': 1, 'records': _records}), flush: true);
      await temporary.rename(file.path);
    } finally { if (await temporary.exists()) await temporary.delete(); }
  }
}

// Certificate bytes reported by the native helper. The helper computes the digest with
// CryptoKit; Dart recomputes it independently from the DER and rejects mismatches.
class NativeCertificate implements X509Certificate {
  @override final Uint8List der;
  @override final String subject, issuer;
  @override final DateTime startValidity, endValidity;
  NativeCertificate(Map<String, dynamic> input)
    : der = base64Decode(input['der'] as String), subject = input['subject'] as String,
      issuer = input['issuer'] as String, startValidity = DateTime.parse(input['validFrom'] as String),
      endValidity = DateTime.parse(input['validUntil'] as String) {
    if (fingerprint(this) != input['sha256']) throw StateError('CertificateMetadataMismatch');
  }
  @override String get pem => '-----BEGIN CERTIFICATE-----\n${base64Encode(der)}\n-----END CERTIFICATE-----';
  // Identity is SHA-256 only; SHA-1 is deliberately not part of the pin contract.
  @override Uint8List get sha1 => Uint8List(0);
}

class SourcePinnedClient {
  final SourceEndpoint endpoint;
  final SourceTrustStore store;
  final String? approvedCAPem;
  final String helperPath;
  final Duration requestTimeout;
  SourcePinnedClient(this.endpoint, this.store, {required this.helperPath, this.requestTimeout = const Duration(seconds:30), this.approvedCAPem});
  Future<Map<String, dynamic>> post(String path, Map<String, String> fields,
      {void Function(void Function())? onAbortReady, String? synoToken}) async {
    if (!path.startsWith('/webapi/') || path.contains('..') || path.contains('%') ||
        path.contains('?') || path.contains('#') || path.contains('\\')) {
      throw StateError('UnsafeApiPath');
    }
    // No credentials in argv or environment: the request body travels over the child stdin pipe only.
    final process = await Process.start(helperPath, [], runInShell: false);
    onAbortReady?.call(() => process.kill());
    final output = process.stdout.transform(utf8.decoder).join();
    final errors = process.stderr.drain<void>();
    try {
      process.stdin.writeln(jsonEncode({...endpoint.toJson(), 'path': path,
        'body': fields.entries.map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}').join('&'),
        'requestTimeoutMs':requestTimeout.inMilliseconds, 'sha256': store.pin(endpoint), 'allowExpired': store.permitsExpired(endpoint),
        if (approvedCAPem != null) 'approvedCAPem': approvedCAPem,
        if (synoToken != null && synoToken.isNotEmpty) 'synoToken': synoToken,
      }));
      await process.stdin.close();
      final raw = await output.timeout(requestTimeout + const Duration(seconds:5)); await errors;
      if (await process.exitCode != 0) throw StateError('NativeTransportFailure');
      final parsed = jsonDecode(raw) as Map<String, dynamic>;
      if (parsed['state'] == 'certificateTrustRequired') {
        final info = Map<String, dynamic>.from(parsed['certificate'] as Map);
        final candidate = CertificateCandidate(endpoint, NativeCertificate(info),
          List<String>.from(parsed['failureReasons'] as List), List<String>.from(info['san'] as List));
        store.present(candidate); throw TrustRequired(candidate);
      }
      if (parsed['state'] != 'response') {
        throw NativeTransportError(parsed['state'] as String, parsed['httpStatus'] as int?,
            bytes: lenientNonnegativeInt(parsed, 'bytes'));
      }
      return Map<String, dynamic>.from(parsed['body'] as Map);
    } finally { process.kill(); }
  }
}
