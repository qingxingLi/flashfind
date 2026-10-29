// 飞牛「打开回退链」端点的真机契约探针（2026-10-29）。
//
// 已量出（不用再测）：
//   * `file.share.list` → `{result:'succ', share:[{path,link,uid,btim,mtim,v}]}`
//     `path` = 存储侧路径（vol2/1000/备份），`link` = 展示链路（vol01/…）。
//   * `/ogh/ac/h/multiple-download` 请求体 = `{"paths":["存储路径"]}`，
//     响应 = `{"token":"<32位hex>"}`（files/path 两种写法均 400）。
//
// 本文件剩最后一件事：拿临时 token GET 文件，量 206 / Range / 无 Bearer 401。
//
// 运行：
//   dart run MyNASCore/probe_fnos_open.dart start  <origin>   → 打授权地址
//   dart run MyNASCore/probe_fnos_open.dart finish <origin> <授权码> → 换 token 并探
//   dart run MyNASCore/probe_fnos_open.dart resume <origin>   → 用存量 refresh 续跑
// 例：dart run MyNASCore/probe_fnos_open.dart start https://nas.example.net
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'lib/dio_compat.dart';
import 'lib/sha256.dart';

const _stateFile = '/tmp/fnos_probe_state.json';

Future<void> main(List<String> args) async {
  final mode = args.isNotEmpty ? args.first : '';
  if (mode == 'start') {
    await _start(args.length > 1 ? args[1] : 'https://nas.example.net');
    return;
  }
  if (mode == 'finish') {
    await _finish(args.length > 1 ? args[1] : '', args.length > 2 ? args[2] : '');
    return;
  }
  if (mode == 'resume') {
    await _resume(args.length > 1 ? args[1] : '');
    return;
  }
  if (mode == 'shares') {
    await _shares(args.length > 1 ? args[1] : 'https://nas.example.net');
    return;
  }
  // ignore: avoid_print
  print('用法：dart run MyNASCore/probe_fnos_open.dart start|finish|resume|shares <origin> [授权码]');
  exitCode = 2;
}

/// 第一段：本地拼授权 URL（与适配器同一条公式），verifier 落盘等第二段。
Future<void> _start(String origin) async {
  final verifier = _newVerifier();
  final challenge =
      base64Url.encode(sha256Bytes(utf8.encode(verifier))).replaceAll('=', '');
  File(_stateFile).writeAsStringSync(jsonEncode({
    'origin': origin,
    'verifier': verifier,
    'challenge': challenge,
  }));
  final url = '$origin/signin?client_id=YJNMPJUGA9'
      '&response_type=code&scope=${Uri.encodeComponent('trim.user.all trim.file.read '
          'trim.file.write trim.download.all trim.appcenter.all trim.photo.all '
          'trim.baidu_netdisk.all trim.system.all trim.log.all '
          'trim.storage.all trim.docker.all')}'
      '&code_challenge=${Uri.encodeComponent(challenge)}&code_challenge_method=S256'
      '&device_name=${Uri.encodeComponent('闪寻')}&device_model=${Uri.encodeComponent('FlashFind for macOS')}'
      '&device_id=flashfind-macos-0000000000000001';
  // ignore: avoid_print
  print('状态已写入 $_stateFile');
  // ignore: avoid_print
  print('请在浏览器打开下面这个地址，登录并同意授权：');
  // ignore: avoid_print
  print(url);
  // ignore: avoid_print
  print('然后把页面上的授权码交给第二段：');
  // ignore: avoid_print
  print('  dart run MyNASCore/probe_fnos_open.dart finish $origin <授权码>');
}

/// 第二段：换 token → 落 refresh → 进探针。
Future<void> _finish(String origin, String code) async {
  final state =
      jsonDecode(File(_stateFile).readAsStringSync()) as Map<String, Object?>;
  if (state['origin'] != origin) {
    // ignore: avoid_print
    print('origin 与第一段不一致：${state['origin']}');
    exitCode = 1;
    return;
  }
  final dio = Dio(BaseOptions(baseUrl: origin))..allowInsecureHTTP = true;
  final Object? tokenReply;
  try {
    tokenReply = await _post(dio, '/oauthapi/third-part/token', {
      'code': code,
      'code_verifier': state['verifier'],
      'client_id': 'YJNMPJUGA9',
    });
  } catch (e) {
    // ignore: avoid_print
    print('授权请求失败（${e.runtimeType}）');
    exitCode = 1;
    return;
  }
  final data = _data(tokenReply);
  final access = data?['access_token'] as String?;
  if (access == null || access.isEmpty) {
    // ignore: avoid_print
    print('授权码没有被接受。');
    exitCode = 1;
    return;
  }
  // ignore: avoid_print
  print('token 已拿到（长度 ${access.length}），不打印内容。');
  // 存 refresh：后续再跑探针走 resume 续期，不用再麻烦用户授权。
  final refresh = data?['refresh_token'];
  if (refresh is String && refresh.isNotEmpty) {
    state['refresh_token'] = refresh;
    File(_stateFile).writeAsStringSync(jsonEncode(state));
  }
  await _probe(dio, access);
}

/// 续跑：用上次存下的 refresh_token 换新 access，直接进探针。
Future<void> _resume(String origin) async {
  final access = await _refreshAccess(origin);
  if (access == null) {
    exitCode = 1;
    return;
  }
  final dio = Dio(BaseOptions(baseUrl: origin))..allowInsecureHTTP = true;
  // ignore: avoid_print
  print('已续期，直接进探针。');
  await _probe(dio, access);
}

Future<String?> _refreshAccess(String origin) async {
  final state =
      jsonDecode(File(_stateFile).readAsStringSync()) as Map<String, Object?>;
  final refresh = state['refresh_token'];
  if (refresh is! String || refresh.isEmpty) {
    // ignore: avoid_print
    print('状态文件里没有 refresh_token，请走 finish。');
    return null;
  }
  final dio = Dio(BaseOptions(baseUrl: origin))..allowInsecureHTTP = true;
  final reply = await _post(dio, '/oauthapi/refresh',
      {'refresh_token': refresh, 'client_id': 'YJNMPJUGA9'});
  final access = _data(reply)?['access_token'] as String?;
  if (access == null || access.isEmpty) {
    // ignore: avoid_print
    print('续期失败。');
    return null;
  }
  return access;
}

/// 免授权模式：只量 file.share.list 全字段与 file.prop（下载地址形状）。
Future<void> _shares(String origin) async {
  final access = await _refreshAccess(origin);
  if (access == null) {
    exitCode = 1;
    return;
  }
  final dio = Dio(BaseOptions(baseUrl: origin))..allowInsecureHTTP = true;
  Future<Object?> call(String req, [Map<String, Object?> params = const {}]) {
    final body = <String, Object?>{
      'reqid': DateTime.now().microsecondsSinceEpoch.toString(),
      'req': req,
      ...params,
    };
    return _post(dio, '/ogh/ac/w', body, headers: {'Authorization': 'Bearer $access'});
  }

  for (final req in ['file.share.list', 'file.share.info']) {
    // ignore: avoid_print
    print('═══ $req（原样全字段）═══');
    try {
      final r = req == 'file.share.info'
          ? await call('file.share.info', {'path': 'vol2/1000/备份'})
          : await call(req);
      // ignore: avoid_print
      print(const JsonEncoder.withIndent('  ').convert(r));
    } catch (e) {
      // ignore: avoid_print
      print('失败：$e');
    }
  }

  final info = await call('user.info');
  final uid =
      (((_data(info)?['userInfo'] ?? {}) as Map)['uid'])?.toString() ?? '1000';
  for (final v in [1, 2]) {
    final ls = await call('file.ls', {'path': 'vol$v/$uid'});
    for (final f in _filesOf(ls)) {
      if (!_isDir(f)) {
        final p = 'vol$v/$uid/${f['name']}';
        // ignore: avoid_print
        print('\n═══ file.prop $p ═══');
        // ignore: avoid_print
        print(const JsonEncoder.withIndent('  ').convert(await call('file.prop', {'path': p})));
        return;
      }
    }
  }
}

/// 探针主体：user.info → 样例文件 → GET 三件事。
Future<void> _probe(Dio dio, String access) async {
  final state =
      jsonDecode(File(_stateFile).readAsStringSync()) as Map<String, Object?>;
  final origin = (state['origin'] as String?) ?? '';

  Future<Object?> call(String req, [Map<String, Object?> params = const {}]) {
    final body = <String, Object?>{
      'reqid': DateTime.now().microsecondsSinceEpoch.toString(),
      'req': req,
      ...params,
    };
    return _post(dio, '/ogh/ac/w', body, headers: {'Authorization': 'Bearer $access'});
  }

  final info = await call('user.info');
  final uid =
      (((_data(info)?['userInfo'] ?? {}) as Map)['uid'])?.toString() ?? '1000';
  // ignore: avoid_print
  print('\n[user.info] uid=$uid');

  String? sampleFile;
  for (var v = 1; v <= 3 && sampleFile == null; v++) {
    final ls = await call('file.ls', {'path': 'vol$v/$uid'});
    final files = _filesOf(ls);
    if (v == 1 && files.isNotEmpty) {
      // ignore: avoid_print
      print('  首条原始 JSON：${jsonEncode(files.first)}');
    }
    // ignore: avoid_print
    print('  vol$v/$uid 条目：' +
        files.take(8).map((f) => '${f['name']}${_isDir(f) ? '(目录)' : ''}').join(', '));
    for (final f in files) {
      if (!_isDir(f)) {
        sampleFile = 'vol$v/$uid/${f['name']}';
        break;
      }
    }
    // 三层深挖，优先找真文件而不是目录。
    var dirs = files.where((f) => _isDir(f)).map((f) => '${f['name']}').toList();
    for (var depth = 0; depth < 3 && sampleFile == null && dirs.isNotEmpty; depth++) {
      final next = <String>[];
      for (final d in dirs.take(4)) {
        final sub = v == 1 ? 'vol1/$uid/$d' : 'vol$v/$uid/$d';
        final prefix = sub;
        final ls2 = await call('file.ls', {'path': prefix});
        for (final f in _filesOf(ls2)) {
          if (!_isDir(f)) {
            sampleFile = '$prefix/${f['name']}';
            break;
          }
          next.add('$prefix/${f['name']}');
        }
        if (sampleFile != null) break;
      }
      dirs = next;
    }
  }
  // ignore: avoid_print
  print('\n[样例文件] ${sampleFile ?? '（没找到，下面的 GET 探针跳过）'}');
  if (sampleFile == null) return;

  // ── 拿临时 token，然后原生 HttpClient GET（dio 有 JSON 体积上限，装不下文件）──
  // ignore: avoid_print
  print('\n═══ GET 文件（原生 HttpClient，每次领新 token）═══');
  final correctBody = {'paths': <Object?>[sampleFile]};
  final client = HttpClient();
  Future<void> probe(String path,
      {required bool withAuth, bool range = true}) async {
    try {
      final reply = await _post(dio, '/ogh/ac/h/multiple-download', correctBody,
          headers: {'Authorization': 'Bearer $access'});
      final t = reply is Map ? reply['token'] : null;
      if (t is! String || t.isEmpty) {
        // ignore: avoid_print
        print('  下载凭据获取失败。');
        return;
      }
      final uri =
          Uri.parse('$origin$path').replace(queryParameters: {'token': t});
      final req = await client.openUrl('GET', uri);
      if (range) req.headers.set('Range', 'bytes=0-99');
      if (withAuth) req.headers.set('Authorization', 'Bearer $access');
      final resp = await req.close();
      final bytes = <int>[];
      await for (final chunk in resp) {
        if (bytes.length < 64) bytes.addAll(chunk.take(64 - bytes.length));
        if (bytes.length >= 64) break;
      }
      final head = latin1.decode(bytes.take(8).toList(), allowInvalid: true);
      // ignore: avoid_print
      print('GET $path (auth=$withAuth range=$range) → HTTP ${resp.statusCode}  '
          'content-range=${resp.headers.value('content-range')}  '
          'content-length=${resp.headers.value('content-length')}  '
          'type=${resp.headers.value('content-type')}  '
          '文件头=${head.codeUnits.map((c) => c.toRadixString(16).padLeft(2, '0')).join(' ')}');
    } catch (e) {
      // ignore: avoid_print
      print('GET $path (auth=$withAuth range=$range) 失败（${e.runtimeType}）');
    }
  }

  await probe('/ogh/ac/h/multiple-download', withAuth: true);
  await probe('/ogh/ac/h/download', withAuth: true);
  await probe('/ogh/ac/h/multiple-download', withAuth: false);
  await probe('/ogh/ac/h/multiple-download', withAuth: true, range: false);
  client.close(force: true);

  // ignore: avoid_print
  print('\n完成。把上面的原始输出交给开发侧落契约。');
}

Map<String, Object?>? _data(Object? reply) {
  if (reply is Map && reply['data'] is Map) {
    return (reply['data'] as Map).cast<String, Object?>();
  }
  return null;
}

/// PKCE code_verifier：48 字节随机数的 base64url（与适配器同一形状）。
String _newVerifier() {
  final random = Random.secure();
  return base64Url
      .encode(List<int>.generate(48, (_) => random.nextInt(256)))
      .replaceAll('=', '');
}

bool _isDir(Map<String, Object?> f) => f['dir'] == 1 || f['dir'] == true;

List<Map<String, Object?>> _filesOf(Object? reply) {
  if (reply is! List || reply.isEmpty) return const [];
  final first = reply.first;
  if (first is! Map) return const [];
  final files = first['files'];
  if (files is! List) return const [];
  return files.whereType<Map>().map((m) => m.cast<String, Object?>()).toList();
}

Future<Object?> _post(Dio dio, String path, Map<String, Object?> payload,
    {Map<String, dynamic>? headers}) async {
  final response = await dio.post<dynamic>(path, data: payload,
      options: Options(headers: <String, dynamic>{
        'accept': 'application/json',
        ...?headers,
      }, responseType: ResponseType.json));
  return response.data;
}
