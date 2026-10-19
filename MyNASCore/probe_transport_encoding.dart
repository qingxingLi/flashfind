// 传输层「响应编码」诊断探针 —— 不需要任何凭据。
//
// 背景：界面报 ProtocolViolation（"设备返回的内容不符合预期"），而
// http_transport.dart:51 把 jsonDecode / utf8.decode 的**所有**失败都压成
// 同一个 ProtocolViolation。要分清到底是「压缩体没解压」「非法 UTF-8」
// 还是「响应被截断」，必须看原始字节。
//
// 本探针用 **产品自己的 HttpTransport** 发请求（不是另写一份 HTTP 客户端），
// 所以它测的就是线上代码路径。同时用等价的 dart:io 调用把响应头打出来对照。
//
// 选用 SYNO.API.Info method=query（**不带** query 过滤）作为载荷：
//   * 它是**无需登录**的接口，所以可以无凭据运行；
//   * 响应体足够大（实测 7KB+ 压缩后 / 125KB 明文），
//     能跨过反向代理的 gzip 阈值 —— 这正是小响应看不出问题的原因。
//
// 用法：
//   dart run probe_transport_encoding.dart                      # 打内置的两台真实设备
//   dart run probe_transport_encoding.dart host:port host2:port  # 打指定设备
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'lib/http_transport.dart';
import 'lib/protocol.dart';

const _defaults = <String>[
  'demo-nas.example:443',
  'demo-nas.example:5003',
];

Future<void> main(List<String> args) async {
  final targets = args.isEmpty ? _defaults : args;
  for (final target in targets) {
    await _probe(target);
  }
}

Future<void> _probe(String hostPort) async {
  final parts = hostPort.split(':');
  final host = parts[0];
  final port = int.parse(parts.length > 1 ? parts[1] : '443');
  final base = 'https://$host:$port';

  print('==================================================================');
  print('  目标  $base');
  print('==================================================================');

  // ── A) 原生 dart:io —— 与 HttpTransport 完全相同的调用序列，只是把响应头读出来
  print('[A] 原生 dart:io（与 HttpTransport 同一套 API）');
  final client = HttpClient(); // autoUncompress 默认 true，与 HttpTransport 一致
  try {
    final req = await client.openUrl('POST', Uri.parse('$base/webapi/entry.cgi'));
    req.followRedirects = false;
    req.headers.contentType =
        ContentType('application', 'x-www-form-urlencoded', charset: 'utf-8');
    req.headers.set(HttpHeaders.acceptHeader, 'application/json');
    req.add(utf8.encode('api=SYNO.API.Info&method=query&version=1'));
    final res = await req.close();
    final bytes = <int>[];
    await for (final chunk in res) {
      bytes.addAll(chunk);
    }
    print('    statusCode            : ${res.statusCode}');
    print('    协议版本(私有字段)    : ${_protocolVersion(res)}');
    print('    content-type          : ${res.headers.contentType}');
    print('    content-encoding      : ${res.headers.value(HttpHeaders.contentEncodingHeader)}');
    print('    content-length        : ${res.headers.value(HttpHeaders.contentLengthHeader)}');
    print('    transfer-encoding     : ${res.headers.value(HttpHeaders.transferEncodingHeader)}');
    print('    vary                  : ${res.headers.value("vary")}');
    print('    autoUncompress(client): ${client.autoUncompress}');
    print('    收到字节数            : ${bytes.length}');
    print('    首 8 字节             : ${_hex(bytes.take(8).toList())}');
    print('    是否 gzip 魔数 1f8b   : ${_isGzip(bytes)}');
    print('    能否 UTF-8 解码       : ${_utf8Ok(bytes)}');
    print('    能否 JSON 解析        : ${_jsonOk(bytes)}');
  } catch (error) {
    print('    原生调用异常          : ${error.runtimeType} $error');
  } finally {
    client.close(force: true);
  }

  // ── B) 产品传输层 —— 走的就是线上代码
  print('[B] 产品 HttpTransport（线上代码路径）');
  try {
    final endpoint = Endpoint(base, host);
    final transport = HttpTransport(endpoint);
    final request = WireRequest(
      'SYNO.API.Info',
      'query',
      '/webapi/entry.cgi',
      1,
      'probe',
      const {},
      const {'api': 'SYNO.API.Info', 'method': 'query', 'version': '1'},
    );
    final token = Cancellation();
    final timer = Timer(const Duration(seconds: 25), () => token.cancel('TimedOut'));
    try {
      final parsed = await transport.send(request, token);
      final data = parsed['data'];
      final apiCount = data is Map ? data.length : -1;
      print('    结果                  : 成功，success=${parsed['success']}，data 条目数=$apiCount');
      if (data is Map) _dumpDescriptors(data);
    } on CoreError catch (e) {
      print('    结果                  : CoreError(kind=${e.kind}, httpStatus=${e.httpStatus})');
      if (e.kind == 'ProtocolViolation') {
        print('    ⇢ 说明产品传输层**无法**把这段响应解析成 JSON。');
      }
    } finally {
      timer.cancel();
    }
  } catch (error) {
    print('    结果                  : 构造期异常 ${error.runtimeType} $error');
  }
  print('');
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');

/// 打印闪寻真正依赖的 5 个 API 的版本区间与请求格式。
///
/// 这不是装饰：`synology_api.dart` 把 FileStation.* 钉在 version 2、
/// Auth 钉在 version 6。若某台设备实际只提供 version 1 或 3，
/// 客户端的行为（以及设备返回的字段形状）都会变。
/// 同一 API 在不同 DSM 大版本上的响应字段并不一致，所以先把这份表拉出来。
void _dumpDescriptors(Map<dynamic, dynamic> data) {
  const wanted = [
    'SYNO.API.Auth',
    'SYNO.FileStation.Info',
    'SYNO.FileStation.List',
    'SYNO.FileStation.Search',
    'SYNO.FileStation.Download',
    'SYNO.Finder.FileSearch',
  ];
  print('    ── 关键 API 能力表 ──');
  for (final api in wanted) {
    final entry = data[api];
    if (entry is! Map) {
      print('      ${api.padRight(28)} : （设备未提供）');
      continue;
    }
    final min = entry['minVersion'];
    final max = entry['maxVersion'];
    final path = entry['path'];
    final fmt = entry['requestFormat'] ?? '(未声明 → 视为 legacy)';
    print('      ${api.padRight(28)} : v$min..v$max  format=$fmt  path=$path');
  }
}

/// `HttpClientResponse` 的公开接口没有协议版本；这里只是把私有字段读出来
/// 说明「协商到的是 HTTP/1.1 还是 HTTP/2」，读不到就返回 '未知'。
String _protocolVersion(HttpClientResponse res) {
  try {
    return '${(res as dynamic).protocolVersion}';
  } catch (_) {
    return '未知';
  }
}

bool _isGzip(List<int> bytes) =>
    bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b;

bool _utf8Ok(List<int> bytes) {
  try {
    utf8.decode(bytes);
    return true;
  } catch (_) {
    return false;
  }
}

bool _jsonOk(List<int> bytes) {
  try {
    jsonDecode(utf8.decode(bytes));
    return true;
  } catch (_) {
    return false;
  }
}
