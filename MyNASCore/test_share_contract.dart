// Phase 6.3b-3：NAS 来源根 / 共享名契约 —— **适配器边界**的 fixture 契约。
//
// Swift 侧那六条（① ~ ⑥）锁的是「扣位之后」的身份语义，
// 见 Tests/FlashFindCoreTests/NASProviderContractTests.swift；
// 本文件锁的是**另一半**：品牌适配器不许私自重造设备的身份空间。
//
// 复审拍板（2026-10-21，冻结）：
//   一个 NAS source_id = 一个已配置的来源/连接实例（整台设备），
//   共享名必须保留在相对路径中：
//     /共享A/供应商/报告.xlsx  →  共享A/供应商/报告.xlsx
//   「共享名」指 backend 给的**真实路径组件**，不是 UI 显示名。
//
// 由此得到适配器的三条硬规则：
//   1. 服务端给的 path 原样透传（含 share 首段），不剥、不补；
//   2. 逐搜索根发出请求，收到的是哪条根的结果就保留那条根的前缀；
//   3. 若某品牌真把 /volume1/share/... 吐出来（另一套「设备根」定义），
//      必须在**适配器挡板**统一 —— 绝不让 FileID / Executor 按品牌猜。
//
// 四品牌不必四台机器：群晖走真机（.88 + Swift 侧链路测试），
// 其余品牌在这里用"适配器 + mock 回应"证明满足同一个契约。
//
// 用法：
//   dart run test_share_contract.dart

import 'dart:convert';
import 'dart:io';

import 'lib/adapter_registry.dart';
import 'lib/adapters/qnap.dart';
import 'lib/adapters/ugreen.dart';
import 'lib/dio_compat.dart';

/// 所有起过的本地服务。
///
/// 必须全部关掉：只要还有一个 `HttpServer` 在监听，Dart isolate 就不会退出。
/// 第一次跑本文件时就是因为这个挂了 30 多分钟（进程 CPU 0%、管道里一条输出都看不到），
/// 所以这里集中登记，由 `main` 的 finally 统一 `close(force: true)`。
final List<HttpServer> _servers = <HttpServer>[];

/// 一个 mock 设备：按「请求参数 → 响应体」回放，并记录收到的请求。
class MockDevice {
  MockDevice(List<MapEntry<String, Map<String, Object?>>> routes) : _routes = routes;
  final List<MapEntry<String, Map<String, Object?>>> _routes;
  final List<Map<String, String>> requests = [];

  /// 起本地服务；返回 baseUrl。
  Future<String> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _servers.add(server);
    // ignore: unawaited_futures
    server.listen((request) async {
      requests.add(Uri.decodeFull(request.uri.toString()) == request.uri.toString()
          ? {'uri': request.uri.toString(), 'method': request.method}
          : {'uri': request.uri.toString(), 'method': request.method});
      Map<String, Object?>? body;
      for (final route in _routes) {
        if (request.uri.path == route.key) body = route.value;
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(body ?? {'code': 404}));
      await request.response.close();
    });
    return 'http://127.0.0.1:${server.port}';
  }

  /// 包含给定子串的请求 URI（用来断言「确实用这个根发的请求」）。
  Iterable<String> uris() => requests.map((r) => r['uri'] ?? '');
}

Dio _dio(String baseUrl) => Dio(BaseOptions(baseUrl: baseUrl))..allowInsecureHTTP = true;

/// `<share>/<path>` 契约：路径以 `/` 开头，第一段是 share，后面至少还有一段。
void _expectShareRootForm(String path, String share, String what) {
  final segments = path.split('/').where((s) => s.isNotEmpty).toList();
  if (!path.startsWith('/')) {
    throw StateError('$what 路径必须以设备根开头（前导斜杠），实际：$path');
  }
  if (segments.length < 2) {
    throw StateError('$what 路径应至少是 /<share>/<...>，实际：$path');
  }
  if (segments.first != share) {
    throw StateError('$what 第一段必须是共享名 $share，实际：$path');
  }
}

Future<void> check(String name, Future<void> Function() body) async {
  try {
    await body();
    // ignore: avoid_print
    print('  PASS $name');
  } catch (e) {
    // ignore: avoid_print
    print('  FAIL $name\n       $e');
    rethrow;
  }
}

Future<void> main() async {
  // ignore: avoid_print
  print('\nNAS 来源根契约 · 适配器边界（mock 设备，无需真机）');

  try {
    await _runAll();
  } finally {
    // 无论绿红都要收干净；留着监听会让进程永不退出。
    for (final server in _servers) {
      await server.close(force: true);
    }
  }
  // ignore: avoid_print
  print('share-contract: 6 项通过');
}

Future<void> _runAll() async {

  await check('[qnap] 搜索结果的 path 原样保留共享名（不剥、不补）', () async {
    final device = MockDevice([
      MapEntry(
        '/cgi-bin/filemanager/utilRequest.cgi',
        {
          'status': 1,
          'datas': [
            {
              'filename': '报告.xlsx',
              'path': '/共享A/供应商/报告.xlsx',
              'isfolder': 0,
              'filesize': 2048,
            },
          ],
        },
      ),
    ]);
    final base = await device.start();
    final items = await QnapAdapter(dio: _dio(base))
        .search('报告', roots: const ['/共享A']);
    if (items.length != 1) throw StateError('应返回 1 条，实际 ${items.length}');
    if (items.first.path != '/共享A/供应商/报告.xlsx') {
      throw StateError('适配器改写了服务端路径：${items.first.path}');
    }
    _expectShareRootForm(items.first.path, '共享A', 'qnap');
    // 适配器必须是「逐根发原样请求」，不是自己全盘遍历。
    if (!device.uris().any((u) => u.contains('path=%2F%E5%85%B1%E4%BA%ABA') ||
        u.contains(utf8.encode('共享A').toString()) ||
        u.contains('search'))) {
      throw StateError('没有看到针对该根的 server-search 请求：${device.uris()}');
    }
  });

  await check('[qnap] 两个共享的结果各自保留自己的 share（不互相串味）', () async {
    final device = MockDevice([
      MapEntry(
        '/cgi-bin/filemanager/utilRequest.cgi',
        {
          'status': 1,
          'datas': [
            {'filename': '年报.pdf', 'path': '/共享B/年报.pdf', 'isfolder': 0},
          ],
        },
      ),
    ]);
    final base = await device.start();
    final items = await QnapAdapter(dio: _dio(base))
        .search('年报', roots: const ['/共享A', '/共享B']);
    // mock 对两个根回同一份体；两条结果的 path 都应是共享B/年报.pdf，
    // 关键是**没有任何一条被改写成少一段或多一段**。
    if (items.isEmpty) throw StateError('没有结果');
    for (final item in items) {
      _expectShareRootForm(item.path, '共享B', 'qnap 共享B');
      if (item.path != '/共享B/年报.pdf') {
        throw StateError('路径被改写：${item.path}');
      }
    }
    if (device.requests.length != 2) {
      throw StateError('两个搜索根应各发一次请求，实际 ${device.requests.length}');
    }
  });

  await check('[qnap] 服务端不给 path 时的回退**不会伪造共享名**（越权会在 Scope 处被挡）', () async {
    final device = MockDevice([
      MapEntry(
        '/cgi-bin/filemanager/utilRequest.cgi',
        {
          'status': 1,
          'datas': [
            {'filename': '年报.pdf', 'isfolder': 0},
          ],
        },
      ),
    ]);
    final base = await device.start();
    final items = await QnapAdapter(dio: _dio(base))
        .search('年报', roots: const ['/共享A']);
    if (items.length != 1) throw StateError('应返回 1 条，实际 ${items.length}');
    // 回退是 `/<name>`——**不含共享名**。这里不断言它是「正确身份」，只记录：
    // 它不在任何授权根之下，会话层的 Scope 会据 ScopeDenied 判失败，
    // 而不是让这条结果以「共享A/年报.pdf」的身份混进 locate 返回。
    if (items.first.path.startsWith('/共享A')) {
      throw StateError('适配器按搜索根伪造了共享名：${items.first.path}');
    }
    if (items.first.path != '/年报.pdf') {
      throw StateError('回退形态变了：${items.first.path}');
    }
  });

  await check('[ugreen] 搜索结果的 path 原样保留共享名', () async {
    final device = MockDevice([
      MapEntry(
        '/ugreen/v1/file/search',
        {
          'code': 200,
          'data': {
            'total': 1,
            'files': [
              {'name': '报告.xlsx', 'path': '/共享A/供应商/报告.xlsx'},
            ],
          },
        },
      ),
    ]);
    final base = await device.start();
    final items = await UGreenAdapter(dio: _dio(base))
        .search('报告', roots: const ['/共享A']);
    if (items.length != 1) throw StateError('应返回 1 条，实际 ${items.length}');
    if (items.first.path != '/共享A/供应商/报告.xlsx') {
      throw StateError('适配器改写了服务端路径：${items.first.path}');
    }
    _expectShareRootForm(items.first.path, '共享A', 'ugreen');
  });

  await check('[ugreen] 服务端缺 path 时按父目录回退，共享名仍在', () async {
    final device = MockDevice([
      MapEntry(
        '/ugreen/v1/file/search',
        {
          'code': 200,
          'data': {
            'files': [
              {'name': '年报.pdf'},
            ],
          },
        },
      ),
    ]);
    final base = await device.start();
    final items = await UGreenAdapter(dio: _dio(base))
        .search('年报', roots: const ['/共享A/供应商']);
    if (items.length != 1) throw StateError('应返回 1 条，实际 ${items.length}');
    // 回退 = `<搜索根>/<文件名>` —— 共享名仍然是第一段。
    if (items.first.path != '/共享A/供应商/年报.pdf') {
      throw StateError('回退路径不符合契约：${items.first.path}');
    }
    _expectShareRootForm(items.first.path, '共享A', 'ugreen 回退');
  });

  await check('品牌注册表与这条契约（哪些品牌共用这条出口）保持一致', () async {
    // 群晖走原生 DSM 路径，不进品牌注册表；其余共用
    // `lib/adapter_contract.dart` 的 FileItem + brand_session.row()。
    if (hasBrandAdapter('synology')) {
      throw StateError('群晖不该注册为品牌适配器');
    }
    for (final vendor in ['qnap', 'ugreen', 'webdav']) {
      if (!hasBrandAdapter(vendor)) {
        throw StateError('$vendor 应在品牌注册表里（它也走同一条出口）');
      }
    }
  });
}
