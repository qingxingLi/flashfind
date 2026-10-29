// 适配器底座与注册品牌适配器（qnap / ugreen / webdav）的本机验证。
//
// 运行：
//   dart run test_adapters.dart
//
// ── 这里验证的是什么，不是什么 ───────────────────────────────────
// 验证：dio 兼容层的安全约束是否真的生效；注册内的适配器能否在
//       「按协议形状搭的本地 fixture」上走通「登录 → 列共享 → 列目录 → 搜索」的完整链路。
//
// **不验证**：真机兼容性。本机 fixture 通过 ≠ 真机通过 ——
// 飞牛那条线已经实证过这件事：上游适配器在本机怎么测都能过，
// 到了真机上它猜的第一个端点就是 404。
// 所以每个品牌的 capabilities.verifiedOnDevice 一律是 false。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'lib/adapter_contract.dart';
import 'lib/adapter_registry.dart';
import 'lib/adapter_support.dart';
import 'lib/brand_session.dart';
import 'lib/adapters/webdav.dart';
import 'lib/dio_compat.dart';

int _passed = 0, _failed = 0;
final _failures = <String>[];

void ok(String name) {
  _passed++;
  // ignore: avoid_print
  print('  ok   $name');
}

void fail(String name, Object error) {
  _failed++;
  _failures.add('$name :: $error');
  // ignore: avoid_print
  print('  FAIL $name\n       $error');
}

Future<void> check(String name, Future<void> Function() body) async {
  try {
    await body();
    ok(name);
  } catch (error, stack) {
    fail(name, '$error\n${stack.toString().split('\n').take(3).join('\n')}');
  }
}

void expectTrue(bool value, String message) {
  if (!value) throw StateError('期望为真：$message');
}

void expectEqual(Object? actual, Object? expected, String message) {
  if (actual != expected) {
    throw StateError('$message：期望 $expected，实际 $actual');
  }
}

// ─────────────────────────────────────────────────────────────
// A. dio 兼容层的安全约束
// ─────────────────────────────────────────────────────────────

Future<void> shimTests() async {
  // ignore: avoid_print
  print('\n[A] dio 兼容层安全约束');

  await check('未显式放行时拒绝明文 HTTP', () async {
    final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:9'));
    try {
      await dio.get<dynamic>('/x');
      throw StateError('明文 HTTP 竟然被放行');
    } on DioException catch (e) {
      expectTrue(
        e.message.contains('明文'),
        '错误应说明是明文被拒，实际：${e.message}',
      );
    }
  });

  await check('绝对 URL 跑出已授权来源时被拒（SSRF 防线）', () async {
    final dio = Dio(BaseOptions(baseUrl: 'https://nas.local'))
      ..allowInsecureHTTP = true;
    try {
      await dio.get<dynamic>('http://evil.example.com/steal');
      throw StateError('跨来源请求竟然被放行');
    } on DioException catch (e) {
      expectTrue(
        e.message.contains('来源范围'),
        '错误应说明超出来源范围，实际：${e.message}',
      );
    }
  });

  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final port = server.port;

  server.listen((request) async {
    switch (request.uri.path) {
      case '/redirect':
        request.response.statusCode = 302;
        request.response.headers.set('location', 'http://127.0.0.1:$port/ok');
      case '/big':
        request.response.write('x' * 4096);
      case '/json':
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'hello': 'world'}));
      case '/notjson':
        request.response.headers.contentType = ContentType.html;
        request.response.write('<html>login page</html>');
      default:
        request.response.write('ok');
    }
    await request.response.close();
  });

  Dio local() => Dio(BaseOptions(baseUrl: 'http://127.0.0.1:$port'))
    ..allowInsecureHTTP = true;

  await check('拒绝跟随重定向', () async {
    try {
      await local().get<dynamic>('/redirect');
      throw StateError('3xx 竟然被当成功');
    } on DioException catch (e) {
      expectTrue(e.message.contains('重定向'), '错误应说明重定向被拒，实际：${e.message}');
    }
  });

  await check('响应体超出上限即中断', () async {
    final dio = local()..maxResponseBytes = 128;
    try {
      await dio.get<dynamic>('/big', options: Options(responseType: ResponseType.plain));
      throw StateError('超大响应竟然被整包收下');
    } on DioException catch (e) {
      expectTrue(e.message.contains('上限'), '错误应说明超限，实际：${e.message}');
    }
  });

  await check('JSON 响应正常解析', () async {
    final response = await local().get<dynamic>('/json');
    expectEqual(response.statusCode, 200, '状态码');
    expectEqual((response.data as Map)['hello'], 'world', '解析出的字段');
  });

  await check('带正文的请求 + 自定义头（回归：headers are not mutable）', () async {
    // dart:io 在 req.add(body) 之后会把 headers 置为不可变。
    // 曾经的顺序 bug：先 add 正文再 set 头 → 抛 HttpException，
    // 于是**所有 POST 类适配器**（qnap/fnos/ugreen）与 WebDAV 的 PROPFIND 全部失败，
    // 而 GET 测试照样通过。这条用例就是钉死这个顺序。
    final response = await local().request<dynamic>(
      '/json',
      method: 'POST',
      data: jsonEncode({'a': 1}),
      options: Options(
        method: 'POST',
        contentType: 'application/xml;charset=UTF-8',
        headers: const {
          'depth': '1',
          'accept': 'application/xml,text/xml',
          'accept-charset': 'utf-8',
          'accept-encoding': '',
        },
      ),
    );
    expectEqual(response.statusCode, 200, '状态码');
  });

  await check('非 JSON 正文不冒充成功', () async {
    try {
      await local().get<dynamic>('/notjson');
      throw StateError('HTML 登录页竟然被当成 JSON 数据');
    } on DioException catch (e) {
      expectTrue(e.message.contains('JSON'), '错误应说明不是合法 JSON，实际：${e.message}');
    }
  });

  await check('日志工具会抹掉 URL 的 query（凭据不进日志）', () async {
    // qnap 的 sid、webdav 的签名串都可能挂在 query 上，日志里绝不能出现。
    final safe = Logger.safeUrl('https://nas.local/dav/a?sid=SECRET&token=XYZ');
    expectTrue(!safe.contains('SECRET'), 'query 必须被抹掉，实际：$safe');
    expectTrue(!safe.contains('XYZ'), 'query 必须被抹掉，实际：$safe');
    expectTrue(safe.contains('/dav/a'), '路径应保留，实际：$safe');
  });

  await server.close(force: true);
}

// ─────────────────────────────────────────────────────────────
// B. WebDAV 端到端（本地 fixture 按真实协议形状搭）
// ─────────────────────────────────────────────────────────────

const _propfindBody = '''<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/</D:href>
    <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop>
    <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
  </D:response>
  <D:response>
    <D:href>/%E7%85%A7%E7%89%87/</D:href>
    <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype>
    <D:getlastmodified>Fri, 09 Oct 2026 10:00:00 GMT</D:getlastmodified></D:prop>
    <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
  </D:response>
  <D:response>
    <D:href>/report%202026.pdf</D:href>
    <D:propstat><D:prop><D:resourcetype/>
    <D:getcontentlength>2048</D:getcontentlength>
    <D:getlastmodified>Fri, 09 Oct 2026 11:30:00 GMT</D:getlastmodified></D:prop>
    <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
  </D:response>
</D:multistatus>''';

// 根目录没有文件夹的 PROPFIND 响应（自身 + 一个文件）。
const _filesOnlyPropfindBody = '''<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/files-only/</D:href>
    <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop>
    <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
  </D:response>
  <D:response>
    <D:href>/files-only/readme.txt</D:href>
    <D:propstat><D:prop><D:resourcetype/></D:prop>
    <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
  </D:response>
</D:multistatus>''';

Future<void> webdavTests() async {
  // ignore: avoid_print
  print('\n[B] WebDAV 适配器（本地 fixture 端到端）');

  const user = 'nasuser', pass = 'test-only';
  final expectedBasic = 'Basic ${base64Encode(utf8.encode('$user:$pass'))}';
  var sawBasicAuth = false;

  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final port = server.port;

  server.listen((request) async {
    final auth = request.headers.value('authorization');
    if (auth != expectedBasic) {
      request.response.statusCode = 401;
      request.response.headers.set('WWW-Authenticate', 'Basic realm="Restricted"');
      request.response.write('Not Authorized');
      await request.response.close();
      return;
    }
    sawBasicAuth = true;
    switch (request.method) {
      case 'OPTIONS':
        request.response.statusCode = 200;
        request.response.headers.set('DAV', '1,2');
      case 'PROPFIND':
        request.response.statusCode = 207;
        request.response.headers.contentType =
            ContentType.parse('application/xml; charset=utf-8');
        request.response.write(_propfindBody);
      default:
        request.response.statusCode = 405;
    }
    await request.response.close();
  });

  Dio makeDio() =>
      Dio(BaseOptions(baseUrl: 'http://127.0.0.1:$port'))..allowInsecureHTTP = true;

  await check('匿名首请求拿 401，升级 Basic 后登录成功', () async {
    final adapter = WebDavAdapter(dio: makeDio());
    final outcome = await adapter.login(username: user, password: pass);
    expectTrue(outcome is LoginSuccess, '期望登录成功，实际 $outcome');
    expectTrue(sawBasicAuth, '适配器应完成 401 → Basic 的重试握手');
    expectTrue(adapter.sessionIdentity != null, '登录后应有会话身份');
    await adapter.logout();
  });

  await check('密码错误时返回 LoginRejected 而不是抛异常', () async {
    final adapter = WebDavAdapter(dio: makeDio());
    final outcome = await adapter.login(username: user, password: 'wrong');
    expectTrue(outcome is LoginRejected, '期望登录被拒，实际 $outcome');
    if (outcome is LoginRejected) {
      expectTrue(
        outcome.reason.contains('账号') || outcome.reason.contains('密码'),
        '拒绝原因应可读，实际：${outcome.reason}',
      );
    }
  });

  await check('口令不进入 URL（只在 Authorization 头里）', () async {
    final adapter = WebDavAdapter(dio: makeDio());
    await adapter.login(username: user, password: pass);
    // fixture 只认 Authorization 头；若适配器把口令拼进 URL，上面的登录会失败。
    expectTrue(sawBasicAuth, '认证必须走请求头');
    await adapter.logout();
  });

  await check('PROPFIND 解析出子项，且跳过自身', () async {
    final adapter = WebDavAdapter(dio: makeDio());
    await adapter.login(username: user, password: pass);
    final items = await adapter.list('/');
    expectEqual(items.length, 2, '应解析出 2 个子项（跳过根自身）');
    final names = items.map((i) => i.name).toSet();
    expectTrue(names.contains('照片'), '中文目录名应正确百分号解码，实际 $names');
    expectTrue(names.contains('report 2026.pdf'), '文件名里的空格应正确解码，实际 $names');
    final pdf = items.firstWhere((i) => i.name == 'report 2026.pdf');
    expectEqual(pdf.size, 2048, 'contentlength');
    expectEqual(pdf.isDirectory, false, 'isDirectory');
    final dir = items.firstWhere((i) => i.name == '照片');
    expectEqual(dir.isDirectory, true, '集合应识别为目录');
    expectTrue(dir.modifiedTime != null, '应解析出修改时间');
    await adapter.logout();
  });

  await check('服务端搜索必须明确报不支持，且不做全盘遍历', () async {
    final adapter = WebDavAdapter(dio: makeDio());
    await adapter.login(username: user, password: pass);
    try {
      await adapter.search('报告', roots: const ['/']);
      throw StateError('WebDAV 没有服务端搜索，不该返回结果');
    } on AdapterFailure catch (e) {
      expectEqual(e.kind, 'UnsupportedApi', '失败种类');
    }
    await adapter.logout();
  });

  await check('子集[webdav] 已真机验证，能力声明必须如实反映', () async {
    final caps = WebDavAdapter(dio: makeDio()).capabilities;
    expectEqual(caps.verifiedOnDevice, true, 'verifiedOnDevice');
    expectTrue(caps.notes.contains('真机已验证'), 'notes 应写明真机已验证，实际：${caps.notes}');
    expectTrue(caps.notes.contains('5005'), 'notes 应指明验证的设备端口，实际：${caps.notes}');
    // 真机验证了搜索能力也不变：WebDAV 本来就没有服务端搜索。
    expectEqual(caps.nativeSearch, false, 'nativeSearch');
  });

  // ── 真机撞到的三类服务器行为（openlist.demo-nas.example）──
  // 实测：站点根 PROPFIND 405（Web 界面占着根，WebDAV 在 /dav）、
  // /dav 对无凭据/错凭据也全回 429（nginx 限流，与密码无关）、
  // http 打 443 → 302 → https。这三类都会落进兜底文案，用户无从下手。
  final odd = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  odd.listen((request) async {
    // 适配器的 _fixSlashes 会给路径补尾随 '/'（/limited → /limited/），
    // 场景匹配前先把尾斜杠归一掉。
    final reqPath = request.uri.path.length > 1 && request.uri.path.endsWith('/')
        ? request.uri.path.substring(0, request.uri.path.length - 1)
        : request.uri.path;
    final auth = request.headers.value('authorization');
    // 不少服务器对匿名 OPTIONS 也放行（密码没被碰过）——这是「假登陆」的温床，
    // 适配器必须在后续 PROPFIND 里把凭据验证做实。这个路径专门模拟它。
    if (reqPath == '/anon-open' && request.method == 'OPTIONS') {
      request.response.statusCode = 200;
      request.response.headers.set('DAV', '1,2');
      await request.response.close();
      return;
    }
    if (auth != expectedBasic) {
      request.response.statusCode = 401;
      request.response.headers.set('WWW-Authenticate', 'Basic realm="Restricted"');
      await request.response.close();
      return;
    }
    if (request.method == 'OPTIONS') {
      switch (reqPath) {
        case '/webui':
          request.response.statusCode = 405;
        case '/moved':
          request.response.statusCode = 302;
          request.response.headers.set('location', 'https://example.invalid/same');
        default:
          request.response.statusCode = 200;
          request.response.headers.set('DAV', '1,2');
      }
      await request.response.close();
      return;
    }
    if (request.method == 'PROPFIND') {
      switch (reqPath) {
        case '/limited':
          request.response.statusCode = 429;
        case '/webui':
          request.response.statusCode = 405;
        case '/moved':
          request.response.statusCode = 302;
          request.response.headers.set('location', 'https://example.invalid/same');
        case '/files-only':
          // 根目录全是文件、没有一个文件夹 —— 「0 个可搜索位置」的取证场景。
          request.response.statusCode = 207;
          request.response.headers.contentType =
              ContentType.parse('application/xml; charset=utf-8');
          request.response.write(_filesOnlyPropfindBody);
        default:
          request.response.statusCode = 207;
          request.response.headers.contentType =
              ContentType.parse('application/xml; charset=utf-8');
          request.response.write(_propfindBody);
      }
      await request.response.close();
      return;
    }
    request.response.statusCode = 405;
    await request.response.close();
  });

  Future<AdapterFailure> readDirFailure(String path) async {
    final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:${odd.port}'))
      ..allowInsecureHTTP = true;
    final adapter = WebDavAdapter(dio: dio);
    final outcome = await adapter.login(username: user, password: pass);
    expectTrue(outcome is LoginSuccess, '前置：登录应成功，实际 $outcome');
    try {
      await adapter.list(path);
      throw StateError('$path 不该返回结果');
    } on AdapterFailure catch (e) {
      await adapter.logout();
      return e;
    }
  }

  await check('PROPFIND 被 429 限流时：说明与密码无关并劝停重试', () async {
    final e = await readDirFailure('/limited');
    expectEqual(e.kind, 'RateLimited', '失败种类');
    expectTrue(e.message.contains('与账号密码无关'), '必须先摘掉密码嫌疑：${e.message}');
    expectTrue(e.message.contains('等几分钟'), '要给出可操作的下一步：${e.message}');
  });

  await check('PROPFIND 405 时：指路 /dav 子路径', () async {
    final e = await readDirFailure('/webui');
    expectEqual(e.kind, 'UnsupportedApi', '失败种类');
    expectTrue(e.message.contains('/dav'), '必须说出 OpenList/Alist 的惯例路径：${e.message}');
  });

  await check('PROPFIND 被 302 重定向时：点出明文开关', () async {
    final e = await readDirFailure('/moved');
    expectTrue(e.message.contains('明文'), '重定向最常见原因是明文打 https 端口：${e.message}');
  });

  await check('登录（ping）阶段的 405/302 同样要可读', () async {
    Future<LoginRejected> pingRejected(String subPath) async {
      final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:${odd.port}$subPath'))
        ..allowInsecureHTTP = true;
      final adapter = WebDavAdapter(dio: dio);
      final outcome = await adapter.login(username: user, password: pass);
      expectTrue(outcome is LoginRejected, '$subPath 应登录失败，实际 $outcome');
      await adapter.logout();
      return outcome as LoginRejected;
    }

    final notDav = await pingRejected('/webui');
    expectTrue(notDav.reason.contains('/dav'), '405 必须指路 /dav：${notDav.reason}');

    final moved = await pingRejected('/moved');
    expectTrue(moved.reason.contains('明文'), '302 必须点出明文开关：${moved.reason}');
  });

  // ── 报「假登陆」：OPTIONS 匿名放行的服务器上，账号密码
  // 错了照样显示已登录。登录必须对凭据做一次真验证（PROPFIND Depth:0）。──
  await check('登录必须真验证凭据（OPTIONS 匿名放行也不算数）', () async {
    Future<Object> anonLogin(String password) async {
      final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:${odd.port}/anon-open'))
        ..allowInsecureHTTP = true;
      final adapter = WebDavAdapter(dio: dio);
      final outcome = await adapter.login(username: user, password: password);
      await adapter.logout();
      return outcome;
    }

    final wrong = await anonLogin('definitely-wrong');
    expectTrue(wrong is LoginRejected, '匿名放行的服务器上错密码必须被拒，实际 $wrong');
    expectTrue(
      wrong is LoginRejected && wrong.reason.contains('密码'),
      '拒绝原因应指向凭据：${wrong is LoginRejected ? wrong.reason : wrong}',
    );
    final right = await anonLogin(pass);
    expectTrue(right is LoginSuccess, '正确密码应登录成功，实际 $right');
  });

  await check('根目录没有文件夹时报 EmptyScope 并给出条目数', () async {
    final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:${odd.port}/files-only'))
      ..allowInsecureHTTP = true;
    final adapter = WebDavAdapter(dio: dio);
    final outcome = await adapter.login(username: user, password: pass);
    expectTrue(outcome is LoginSuccess, '前置：登录应成功，实际 $outcome');
    try {
      await adapter.shareRoots();
      throw StateError('0 个文件夹不该静默返回空表');
    } on AdapterFailure catch (e) {
      expectEqual(e.kind, 'EmptyScope', '失败种类');
      expectTrue(e.message.contains('1 个条目'), '应说清根目录里有几个条目：${e.message}');
      expectTrue(e.message.contains('路径'), '要给出可操作的下一步（填「路径」）：${e.message}');
    }
    await adapter.logout();
  });

  odd.close();

  await server.close(force: true);
}

// ─────────────────────────────────────────────────────────────
// C. 注册品牌的共同契约
// ─────────────────────────────────────────────────────────────

Future<void> contractTests() async {
  // ignore: avoid_print
  print('\n[C] 注册品牌的共同契约');

  DraftAdapter make(String vendor) {
    final dio = Dio(BaseOptions(baseUrl: 'https://192.0.2.1'))
      ..allowInsecureHTTP = true;
    return DraftAdapter(vendor, dio);
  }

  // fnos 2026-10-29 重新接回注册表（`portedUnverified`，真机契约已量过、SMB 打开链待验）。
  // 当前**没有**任何下线品牌，所以「下线品牌」那条用例改成守机制本身。
  const vendors = ['qnap', 'ugreen', 'webdav', 'fnos'];

  await check('注册表认在册品牌，不认别的品牌', () async {
    for (final vendor in vendors) {
      expectTrue(hasBrandAdapter(vendor), '注册表应包含 $vendor');
    }
    expectTrue(!hasBrandAdapter('synology'), '群晖不走品牌注册表');
    expectTrue(!hasBrandAdapter('generic'), 'generic 没有适配器');
  });

  await check('在册品牌都不在下线表里（下线＝既要摘注册也要进表）', () async {
    for (final vendor in vendors) {
      expectTrue(!retiredVendors.contains(vendor), '$vendor 在册却还留在下线表');
    }
    // 机制本身要能说清「为什么」：对没接入的品牌不能说成「下线过」。
    final reason = unsupportedVendorReason('generic');
    expectTrue(reason.contains('还没有接入') || reason.contains('未接入'),
        '没接过的品牌要给「没接入」，不是「下线」：实际 $reason');
    expectTrue(!reason.contains('下线'), '没接过就不能说下线：$reason');
  });

  await check('标 stable 必须有真机证据，两档不得重叠', () async {
    for (final vendor in stableVendors) {
      expectTrue(
        make(vendor).adapter.capabilities.verifiedOnDevice,
        '$vendor 自称 stable 却没有真机证据',
      );
    }
    for (final vendor in experimentalVendors) {
      expectTrue(!stableVendors.contains(vendor), '$vendor 不能既 stable 又 experimental');
    }
  });

  await check('vendor 标识与 Swift 侧取值一致', () async {
    for (final vendor in vendors) {
      expectEqual(make(vendor).adapter.vendor, vendor, '$vendor 的 vendor 取值');
    }
  });

  await check('能力声明与各品牌真实验证状态一致（不许虚报，也不许漏报）', () async {
    // 这份名单必须与 lib/adapters/*.dart 的 capabilities 以及
    // Sources/FlashFindCore/NASSourceConfig.swift 的 adapterStatus 三方一致。
    const deviceVerified = {'webdav'};
    for (final vendor in vendors) {
      final caps = make(vendor).adapter.capabilities;
      final expected = deviceVerified.contains(vendor);
      expectEqual(
        caps.verifiedOnDevice,
        expected,
        '$vendor 的 verifiedOnDevice（期望 $expected）',
      );
      expectTrue(caps.notes.isNotEmpty, '$vendor 的 notes 不能为空');
      if (expected) {
        expectTrue(
          caps.notes.contains('真机已验证'),
          '$vendor 已真机验证，notes 必须写明，实际：${caps.notes}',
        );
      } else {
        expectTrue(
          caps.notes.contains('未') && caps.notes.contains('验证'),
          '$vendor 未真机验证，notes 必须说清，实际：${caps.notes}',
        );
      }
    }
  });

  await check('没有服务端搜索的品牌必须先报 UnsupportedApi（不许先摸网络）', () async {
    for (final vendor in vendors) {
      final adapter = make(vendor).adapter;
      if (adapter.capabilities.nativeSearch) continue;
      // 用不可达地址：如果实现先去连设备，就会抛 NetworkFailure 而不是 UnsupportedApi。
      try {
        await adapter.search('x', roots: const ['/share']);
        throw StateError('$vendor 声明没有服务端搜索，却返回了结果');
      } on AdapterFailure catch (e) {
        expectEqual(e.kind, 'UnsupportedApi', '$vendor 的失败种类');
      }
    }
  });

  await check('有服务端搜索的品牌：不可达时如实失败，绝不返回编造结果', () async {
    for (final vendor in vendors) {
      final adapter = make(vendor).adapter;
      if (!adapter.capabilities.nativeSearch) continue;
      var returned = false;
      Object? failure;
      try {
        // 不可达地址上，唯一可接受的结果是失败。
        final items = await adapter
            .search('x', roots: const ['/share'])
            .timeout(const Duration(seconds: 40));
        returned = items.isNotEmpty || items.isEmpty;
      } catch (e) {
        failure = e;
      }
      expectTrue(!returned, '$vendor 在不可达设备上返回了结果，属于编造');
      expectTrue(failure is AdapterFailure, '$vendor 的失败应是 AdapterFailure，实际 $failure');
    }
  });

  await check('会话层给整次登录一个总预算（穷举适配器不得把超时乘端点数）', () async {
    // 上面那条用例量到的是**适配器裸调**的耗时：fnos 4 个端点 → 4 倍预算。
    // 这里走会话层，验证总预算真的把总耗时压住了。
    //
    // fnos 不在这条用例里：它的登录第一段**压根不碰网络**（只生成 PKCE 与
    // 授权地址），所以「不可达地址上登录必须失败」这个前提对它不成立 ——
    // 它必然抛 `LoginChallengeRequired`。这条缺陷已被 `test_fnos.dart`
    // 的两段授权用例覆盖（那段才是它的登录契约）。
    for (final vendor in vendors.where((v) => v != 'fnos')) {
      final adapter = make(vendor).adapter;
      final session = BrandSession(
        adapter,
        sourceID: vendor,
        queryBudget: const Duration(seconds: 2),
      );
      final started = DateTime.now();
      try {
        await session.login('u', 'p', null).timeout(const Duration(seconds: 20));
        throw StateError('$vendor 在不可达地址上登录成功');
      } catch (e) {
        if (e is StateError) rethrow;
        expectTrue(e is AdapterFailure, '$vendor 的失败应是 AdapterFailure，实际 $e');
        // 不可达地址上允许出现的种类只有「连不上」这一类：
        // TimedOut / NetworkFailure / TLSRejected（自签证书或中间设备拦了握手）。
        // **绝不能是 AuthenticationFailed** —— 那会让用户跑去改密码。
        const connectionKinds = {'TimedOut', 'NetworkFailure', 'TLSRejected'};
        expectTrue(
          connectionKinds.contains((e as AdapterFailure).kind),
          '$vendor 失败种类应为「连不上」，实际 ${e.kind}',
        );
      }
      final elapsed = DateTime.now().difference(started);
      // ignore: avoid_print
      print('        $vendor 会话登录失败耗时 ${elapsed.inMilliseconds}ms（预算 2s）');
      expectTrue(
        elapsed < const Duration(seconds: 6),
        '$vendor 登录耗时 ${elapsed.inMilliseconds}ms，超过总预算太多',
      );
    }
  });

  await check('裸调适配器也能失败（不断言耗时，仅记录基线）', () async {
    for (final vendor in vendors) {
      final adapter = make(vendor).adapter;
      final started = DateTime.now();
      Object? failure;
      LoginOutcome? outcome;
      try {
        // 契约：login 是「返回 sealed 结果」而不是抛异常。
        // 所以这里必须检查返回值，不能靠 catch 判断成败。
        outcome = await adapter
            .login(username: 'u', password: 'p')
            .timeout(const Duration(seconds: 60));
      } catch (e) {
        failure = e; // 抛异常也可接受，但不是唯一形态
      }
      final elapsed = DateTime.now().difference(started);
      expectTrue(
        outcome is! LoginSuccess,
        '$vendor 在不可达地址上报告登录成功',
      );
      expectTrue(
        failure == null || failure is AdapterFailure || failure is DioException,
        '$vendor 的失败类型不可接受：$failure',
      );
      // 记录实测耗时：**穷举式适配器会把「每端点超时」乘上端点个数**，
      // 飞牛/绿联各有 4~11 个候选端点，这是它们真机体验差的结构性原因。
      // ignore: avoid_print
      print('        $vendor 失败耗时 ${elapsed.inMilliseconds}ms');
      expectTrue(
        elapsed < const Duration(seconds: 60),
        '$vendor 耗时应受预算约束，实际 ${elapsed.inMilliseconds}ms',
      );
    }
  });
}

/// 用注册表建一个适配器；测试里只需要拿到接口。
class DraftAdapter {
  final String _vendor;
  final Dio _dio;
  DraftAdapter(this._vendor, this._dio);
  NasBrandAdapter get adapter => createBrandAdapter(
    _vendor,
    endpoint: _dio.baseUrl,
    // 预算压到 2 秒：穷举式适配器有 4~11 个候选端点，
    // 每个都吃满预算的话，用例会慢到没人愿意跑。
    budget: const Duration(seconds: 2),
    allowInsecureHTTP: true,
  );
}

Future<void> main() async {
  // ignore: avoid_print
  print('闪寻 · 适配器底座与本机验证（fixture 通过 ≠ 真机通过）');
  await shimTests();
  await webdavTests();
  await contractTests();

  // ignore: avoid_print
  print('\n通过 $_passed 项，失败 $_failed 项');
  if (_failures.isNotEmpty) {
    // ignore: avoid_print
    print('\n失败明细：');
    for (final f in _failures) {
      // ignore: avoid_print
      print('  - $f');
    }
  }
  exitCode = _failed == 0 ? 0 : 1;
}
