// 飞牛 fnOS 适配器的行为测试（本地 fixture 按真机实测契约搭）。
//
// 运行：
//   dart run test_fnos.dart
//
// ── 这里验证的是什么 ─────────────────────────────────────────────
// 每条用例都对应一条**在真机上量过的行为**（2026-10-28 直连实测 + 官方文档
// `fnnas-labs/fnos-cli-skill`），并且刻意构造成「那个行为被改错就红」：
//
//   1. 登录第一段只产出授权地址、**不发任何请求** → 第 2 条数请求次数
//   2. 授权地址必须带 PKCE challenge、**不能带 redirect_uri**
//      → 飞牛授权页不回跳，带上反而会改变服务端行为
//   3. 第二段的 verifier 要能算出第一段的 challenge（fixture 真的去验）
//      → challenge 算法写错、或 verifier 跨调用丢失，第 4 条红
//   4. 一次请求只能带**一个** path → 第 8 条断言请求体里 path 长度恒为 1
//   5. **空 path 会搜全库**（实测 671KB）→ 第 9 条断言根本不发请求
//   6. 响应是多包数组，**拼接全部 data 才是全集** → 第 10 条 fixture 回
//      100+200+50，只读第一包会得到 100 而红
//   7. 空结果是「没有 data 字段」而不是空数组 → 第 11 条
//   8. 搜索结果的 `path` 是**父目录**，全路径要拼 name → 第 12 条
//   9. 坏路径在搜索上是静默 0，只有 `file.ls` 会报 errno
//      → 第 13 条用 errno 4100 触发部分失败上报
//  10. refresh 之后旧 token 立即失效 → 第 15 条用 401 触发刷新重试
//  11. `file.ls` 不给 size → 必须 `sizeKnown:false`，不许拿 0 冒充
//
// **不验证**：真机兼容性。fixture 通过 ≠ 真机通过。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'lib/adapter_contract.dart';
import 'lib/adapters/fnos.dart';
import 'lib/adapter_support.dart';
import 'lib/brand_session.dart';
import 'lib/upstream_file_types.dart';
import 'lib/dio_compat.dart';
import 'lib/error_kinds.dart';
import 'lib/protocol.dart';
import 'lib/sha256.dart';

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
    fail(name, '$error\n${stack.toString().split('\n').take(4).join('\n')}');
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
// fixture：按飞牛实测形状回包
// ─────────────────────────────────────────────────────────────

class Recorded {
  Recorded(this.path, this.body, this.authorization);
  final String path;
  final Map<String, Object?> body;
  final String? authorization;
}

class FnosFixture {
  late HttpServer _server;
  int port = 0;

  final List<Recorded> requests = <Recorded>[];

  /// 当前有效的 access token。刷新会换一个新的。
  String accessToken = 'token-0';
  String refreshToken = 'refresh-0';

  /// 第一段授权地址里带出去的 challenge，token 交换时用来验 verifier。
  String? expectedChallenge;

  /// 下一次 `/ogh/ac/w` 强制回 401（模拟 token 过期）。
  bool expireNextCall = false;

  /// 每个卷根下放多少条搜索结果；默认走多包（100+200+50）。
  List<int> searchPacketSizes = <int>[100, 200, 50];

  /// 让某个卷根的搜索回 fail + errno。
  final Map<String, int> failSearchFor = <String, int>{};

  /// 存在哪些卷（`file.ls vol{n}/1000` 成功的）。
  final Set<int> volumes = <int>{1, 2};

  /// SMB 共享表（`file.share.list` / `file.share.info`）：存储路径 → 共享名。
  final Map<String, String> smbShares = {'vol2/1000/备份': '备份'};

  /// GET multiple-download 要回的 zip 字节（下载链用例）。
  List<int> downloadZipBytes = <int>[];

  /// 让下一次 GET multiple-download 回 401（模拟 access token 过期）。
  bool expireNextDownload = false;

  /// POST multiple-download 不返回 token（模拟设备异常）。
  bool omitDownloadToken = false;

  /// 对这些存储路径，`file.share.info` 强制回 fail（模拟共享名问不出）。
  final Set<String> shareInfoFailFor = <String>{};

  final Set<String> _issuedDownloadTokens = <String>{};

  int _downloadSerial = 0;

  int _tokenSerial = 1;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    port = _server.port;
    _server.listen(_handle);
  }

  Future<void> stop() async {
    await _server.close(force: true);
  }

  void reset() {
    requests.clear();
    accessToken = 'token-0';
    refreshToken = 'refresh-0';
    expectedChallenge = null;
    expireNextCall = false;
    searchPacketSizes = <int>[100, 200, 50];
    failSearchFor.clear();
    volumes
      ..clear()
      ..addAll(<int>{1, 2});
    smbShares
      ..clear()
      ..addAll(<String, String>{'vol2/1000/备份': '备份'});
    downloadZipBytes = <int>[];
    expireNextDownload = false;
    omitDownloadToken = false;
    shareInfoFailFor.clear();
    _issuedDownloadTokens.clear();
  }

  List<Recorded> get oghCalls =>
      requests.where((r) => r.path == '/ogh/ac/w').toList();

  Future<void> _handle(HttpRequest request) async {
    final raw = await utf8.decoder.bind(request).join();
    Map<String, Object?> body = <String, Object?>{};
    if (raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) body = decoded.cast<String, Object?>();
      } catch (_) {}
    }
    final auth = request.headers.value('authorization');
    requests.add(Recorded(request.uri.path, body, auth));

    void reply(Object? payload, {int status = 200}) {
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(payload));
    }

    // ★ 每个分支都必须让响应流真正结束。只 write 不 close 的话
    //   dart:io 不会把响应发出去，客户端会一直等 —— 测试表现为整轮挂住。
    try {
      _dispatch(request, body, auth, reply);
    } finally {
      await request.response.close();
    }
  }

  void _dispatch(
    HttpRequest request,
    Map<String, Object?> body,
    String? auth,
    void Function(Object?, {int status}) reply,
  ) {
    switch (request.uri.path) {
      case '/oauthapi/third-part/token':
        final code = '${body['code'] ?? ''}';
        final verifier = '${body['code_verifier'] ?? ''}';
        final clientId = '${body['client_id'] ?? ''}';
        if (clientId.isEmpty) {
          // 真机实测：缺 client_id 回 11002，不是 11004。
          reply({'code': 11002, 'msg': 'authentication failed'});
          return;
        }
        if (code != 'GOODCODE') {
          reply({'code': 11004, 'msg': 'invalid code'});
          return;
        }
        // ★ 真的去验 PKCE：verifier 必须能算出第一段带出去的 challenge。
        final challenge = base64Url
            .encode(sha256Bytes(utf8.encode(verifier)))
            .replaceAll('=', '');
        if (expectedChallenge == null || challenge != expectedChallenge) {
          reply({'code': 11004, 'msg': 'invalid code_verifier'});
          return;
        }
        _tokenSerial++;
        accessToken = 'token-$_tokenSerial';
        refreshToken = 'refresh-$_tokenSerial';
        reply({
          'code': 0,
          'msg': 'success',
          'data': {
            'access_token': accessToken,
            'refresh_token': refreshToken,
            'expires_in': 3600,
            'expires_at': DateTime.now().millisecondsSinceEpoch + 3600 * 1000,
          },
        });

      case '/oauthapi/refresh':
        if ('${body['refresh_token'] ?? ''}' != refreshToken) {
          reply({'code': 11002, 'msg': 'authentication failed'});
          return;
        }
        _tokenSerial++;
        accessToken = 'token-$_tokenSerial';
        // 真机实测：refresh 不会返回新的 refresh_token。
        reply({
          'code': 0,
          'msg': 'success',
          'data': {
            'access_token': accessToken,
            'expires_in': 3600,
            'expires_at': DateTime.now().millisecondsSinceEpoch + 3600 * 1000,
          },
        });

      case '/ogh/ac/w':
        if (expireNextCall) {
          expireNextCall = false;
          reply(
            {
              'code': 'AUTH_INVALID_TOKEN',
              'detail': 'The access token is missing, invalid, or expired.',
              'status': 401,
              'title': 'Unauthorized',
            },
            status: 401,
          );
          return;
        }
        if (auth != 'Bearer $accessToken') {
          reply(
            {
              'code': 'AUTH_INVALID_TOKEN',
              'detail': 'The access token is missing, invalid, or expired.',
              'status': 401,
              'title': 'Unauthorized',
            },
            status: 401,
          );
          return;
        }
        _replyOgh(body, reply);

      case '/ogh/ac/h/multiple-download':
        if (request.method == 'POST') {
          if (auth != 'Bearer $accessToken') {
            reply(
              {
                'code': 'AUTH_INVALID_TOKEN',
                'detail': 'expired',
                'status': 401,
                'title': 'Unauthorized',
              },
              status: 401,
            );
            return;
          }
          if (omitDownloadToken) {
            reply({'result': 'succ'});
            return;
          }
          _downloadSerial++;
          final token = 'dl-token-$_downloadSerial';
          _issuedDownloadTokens.add(token);
          reply({'token': token});
          return;
        }
        // GET：拿 token 换 zip 包。
        final token = request.uri.queryParameters['token'] ?? '';
        if (!_issuedDownloadTokens.contains(token)) {
          reply({'code': 'AUTH_INVALID_TOKEN', 'detail': 'bad token'}, status: 401);
          return;
        }
        if (expireNextDownload) {
          expireNextDownload = false;
          reply({'code': 'AUTH_INVALID_TOKEN', 'detail': 'expired'}, status: 401);
          return;
        }
        request.response.headers.contentType = ContentType.binary;
        request.response.add(downloadZipBytes);

      default:
        reply({'error': 'no such endpoint'}, status: 404);
    }
  }

  void _replyOgh(Map<String, Object?> body, void Function(Object?, {int status}) reply) {
    final req = '${body['req'] ?? ''}';
    switch (req) {
      case 'user.info':
        reply([
          {
            'result': 'succ',
            'userInfo': {'uid': 1000, 'user': 'tester', 'admin': true},
          }
        ]);

      case 'file.share.list':
        reply([
          {
            'result': 'succ',
            'share': [
              for (final entry in smbShares.entries)
                {
                  'path': entry.key,
                  'link': entry.key,
                  'uid': 1000,
                  'btim': 1760579592,
                  'mtim': 1790900779,
                  'v': 2,
                },
            ],
          }
        ]);

      case 'file.share.info':
        final path = '${body['path'] ?? ''}';
        final name = shareInfoFailFor.contains(path) ? null : smbShares[path];
        if (name == null) {
          reply([{'result': 'fail', 'errno': 4100, 'errmsg': 'path not found'}]);
          return;
        }
        reply([{'result': 'succ', 'shareName': name, 'uid': 1000}]);

      case 'file.ls':
        final path = '${body['path'] ?? ''}';
        final match = RegExp(r'^vol(\d+)/1000$').firstMatch(path);
        if (match != null) {
          final volume = int.parse(match.group(1)!);
          if (!volumes.contains(volume)) {
            // 真机实测：不存在的卷回 errno 65280。
            reply([
              {'errno': 65280, 'result': 'fail'}
            ]);
            return;
          }
          reply([
            {
              'files': [
                {'btim': 1757549185, 'dir': 1, 'mtim': 1757564938, 'name': '工作资料', 'uid': 1000},
                {'btim': 1757549186, 'dir': 1, 'mtim': 1757568293, 'name': 'Photos', 'uid': 1000},
              ],
              'uver': 117518492958720,
            }
          ]);
          return;
        }
        if (path == 'vol2/1000/工作资料') {
          reply([
            {
              'files': [
                {'btim': 1757549185, 'dir': 1, 'mtim': 1757564938, 'name': '16949', 'uid': 1000},
              ]
            }
          ]);
          return;
        }
        // 真机实测：不存在的路径回 errno 4100。
        reply([
          {'errno': 4100, 'result': 'fail'}
        ]);

      case 'appcgi.finder.fileSearch':
        final key = body['key'];
        if (key is! String || key.isEmpty) {
          // 真机实测：缺 key 回 errno 100000002 + result fail。
          reply([
            {'errno': 100000002, 'req': req, 'result': 'fail', 'rev': '0.1'}
          ]);
          return;
        }
        final paths = body['path'];
        if (paths is! List || paths.isEmpty) {
          // ★ 真机实测：不带 path 会搜全库（671KB）。
          //   fixture 把这种请求记成一个特殊标记，让「空 path 守卫」那条用例能红。
          reply([
            {
              'data': [
                {'name': 'EVERYTHING.pdf', 'path': 'vol1/1000', 'dir': 0, 'size': 1, 'mtim': 1, 'btim': 1, 'uid': 1000}
              ],
              'req': req,
              'result': 'succ',
              'rev': '0.1',
            }
          ]);
          return;
        }
        final storage = '${paths.first}';
        final failure = failSearchFor[storage];
        if (failure != null) {
          reply([
            {'errno': failure, 'req': req, 'result': 'fail', 'rev': '0.1'}
          ]);
          return;
        }
        // 多包：每个元素一段 data，最后一包可能不足 200。
        final packets = <Object?>[];
        var index = 0;
        for (final size in searchPacketSizes) {
          final data = List.generate(size, (i) {
            final n = index + i;
            return {
              'btim': 1600000000 + n,
              'dir': 0,
              'mtim': 1700000000 + n,
              'name': 'hit_$n.pdf',
              'path': '$storage/子目录',
              'size': 1024 + n,
              'uid': 1000,
            };
          });
          index += size;
          packets.add({'data': data, 'req': req, 'result': 'succ', 'rev': '0.1'});
        }
        reply(packets);

      default:
        // 真机实测：未知端点回纯文本 Forbidden（HTTP 403）。
        reply('Forbidden', status: 403);
    }
  }
}

FnOSAdapter adapterFor(FnosFixture fixture) {
  final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:${fixture.port}'))
    ..allowInsecureHTTP = true;
  return FnOSAdapter(dio: dio);
}

// ─────────────────────────────────────────────────────────────
// 用例
// ─────────────────────────────────────────────────────────────

Future<void> loginTests(FnosFixture fixture) async {
  // ignore: avoid_print
  print('\n[1] 登录：OAuth 授权码两段式');

  await check('第一段只产出授权地址，不发任何请求', () async {
    fixture.reset();
    final adapter = adapterFor(fixture);
    final outcome = await adapter.login(username: '', password: '');
    if (outcome is! LoginNeedsAuthorizeCode) {
      throw '期望 LoginNeedsAuthorizeCode，实际 ${outcome.runtimeType}';
    }
    expectEqual(fixture.requests.length, 0, '第一段不该产生网络请求');
  });

  await check('授权地址含 PKCE 参数且不带 redirect_uri', () async {
    fixture.reset();
    final adapter = adapterFor(fixture);
    final outcome = await adapter.login(username: '', password: '')
        as LoginNeedsAuthorizeCode;
    final url = outcome.authorizationUrl;
    expectEqual(url.path, '/signin', '授权页路径');
    final q = url.queryParameters;
    expectEqual(q['code_challenge_method'], 'S256', 'challenge 方法');
    expectTrue((q['code_challenge'] ?? '').isNotEmpty, 'challenge 不能为空');
    expectTrue(!q.containsKey('redirect_uri'), '不能带 redirect_uri（飞牛授权页不回跳）');
    expectEqual(q['client_id'], 'YJNMPJUGA9', 'client id');
    expectTrue((q['scope'] ?? '').contains('trim.file.read'), 'scope 要含 file.read');
    expectTrue(!url.toString().contains('+'), 'scope 空格必须编码成 %20，不能是 +');
    // 把 challenge 交给 fixture，供 token 交换时验 verifier。
    fixture.expectedChallenge = q['code_challenge'];
  });

  await check('没有 verifier 时提交 code 必须被拒绝', () async {
    fixture.reset();
    final adapter = adapterFor(fixture);
    // 不跑第一段，直接提交 code。
    final outcome = await adapter.login(username: '', password: '', authorizeCode: 'GOODCODE');
    if (outcome is! LoginRejected) {
      throw '期望 LoginRejected，实际 ${outcome.runtimeType}';
    }
    expectEqual(fixture.requests.length, 0, '没有 verifier 时不该发请求');
  });

  await check('正确 code + verifier 换到 token 并拿到身份', () async {
    fixture.reset();
    final adapter = adapterFor(fixture);
    final first = await adapter.login(username: '', password: '') as LoginNeedsAuthorizeCode;
    fixture.expectedChallenge = first.authorizationUrl.queryParameters['code_challenge'];
    final second = await adapter.login(username: '', password: '', authorizeCode: 'GOODCODE');
    if (second is! LoginSuccess) throw '期望 LoginSuccess，实际 ${second.runtimeType}';
    expectTrue(second.identity.isNotEmpty, '身份不能为空');
    expectEqual(adapter.sessionIdentity, second.identity, 'sessionIdentity 要跟着更新');
  });

  await check('错的 verifier 换来 11004 ⇒ LoginRejected 且文案带原因', () async {
    fixture.reset();
    final adapter = adapterFor(fixture);
    await adapter.login(username: '', password: '');
    // fixture 记住的是「上一次」challenge；这里故意改掉，模拟 verifier 不匹配。
    fixture.expectedChallenge = 'a-different-challenge';
    final second = await adapter.login(username: '', password: '', authorizeCode: 'GOODCODE');
    if (second is! LoginRejected) throw '期望 LoginRejected，实际 ${second.runtimeType}';
    expectTrue(second.reason.contains('授权码'), '文案要说清是授权码的问题：${second.reason}');
  });
}

Future<void> shareRootTests(FnosFixture fixture) async {
  // ignore: avoid_print
  print('\n[2] 共享根：逐卷探测');

  await check('只返回真实存在的存储空间，不存在的卷不进列表', () async {
    fixture.reset();
    fixture.volumes
      ..clear()
      ..addAll(<int>{1, 2});
    final adapter = adapterFor(fixture);
    await loginHelper(adapter, fixture);
    final roots = await adapter.shareRoots();
    expectEqual(roots.length, 2, '卷数');
    expectEqual(roots[0].path, '/vol1/1000', '第一个卷根');
    expectEqual(roots[1].path, '/vol2/1000', '第二个卷根');
    expectTrue(roots.every((r) => r.name.contains('存储空间')), '展示名要能看懂');
  });

  await check('★ 卷不存在时用 file.ls 的 errno 排除，而不是当成空卷', () async {
    fixture.reset();
    fixture.volumes
      ..clear()
      ..add(2);
    final adapter = adapterFor(fixture);
    await loginHelper(adapter, fixture);
    final roots = await adapter.shareRoots();
    expectEqual(roots.length, 1, '只该有 vol2');
    expectEqual(roots.single.path, '/vol2/1000', '剩下的那个是 vol2');
  });

  await check('一个卷都探测不到时报 EmptyScope，不返回空列表', () async {
    fixture.reset();
    fixture.volumes.clear();
    final adapter = adapterFor(fixture);
    await loginHelper(adapter, fixture);
    try {
      await adapter.shareRoots();
      throw '期望抛 EmptyScope';
    } on AdapterFailure catch (failure) {
      expectEqual(failure.kind, ErrorKind.emptyScope, '错误种类');
    }
  });
}

Future<void> searchTests(FnosFixture fixture) async {
  // ignore: avoid_print
  print('\n[3] 搜索：逐卷 + 多包聚合');

  await check('空关键字不发请求就拒绝', () async {
    fixture.reset();
    final adapter = adapterFor(fixture);
    await loginHelper(adapter, fixture);
    final before = fixture.requests.length;
    try {
      await adapter.search('   ', roots: ['/vol2/1000']);
      throw '期望抛 UnsupportedQuery';
    } on AdapterFailure catch (failure) {
      expectEqual(failure.kind, ErrorKind.unsupportedQuery, '错误种类');
    }
    expectEqual(fixture.requests.length, before, '不该发请求');
  });

  await check('没有搜索位置时报 ScopeUnset', () async {
    fixture.reset();
    final adapter = adapterFor(fixture);
    await loginHelper(adapter, fixture);
    try {
      await adapter.search('报告', roots: const <String>[]);
      throw '期望抛 ScopeUnset';
    } on AdapterFailure catch (failure) {
      expectEqual(failure.kind, ErrorKind.scopeUnset, '错误种类');
    }
  });

  await check('★ 一次请求只能带一个 path（多 path 在真机上必挂）', () async {
    fixture.reset();
    final adapter = adapterFor(fixture);
    await loginHelper(adapter, fixture);
    await adapter.search('报告', roots: ['/vol1/1000', '/vol2/1000']);
    final searches = fixture.oghCalls
        .where((r) => '${r.body['req']}' == 'appcgi.finder.fileSearch')
        .toList();
    expectTrue(searches.isNotEmpty, '应该有搜索请求');
    for (final call in searches) {
      final paths = call.body['path'];
      expectTrue(paths is List, 'path 必须是数组');
      expectEqual((paths as List).length, 1, 'path 必须恰好一个元素');
    }
  });

  await check('★ 空 path 绝不发出去（真机上会搜全库）', () async {
    fixture.reset();
    fixture.searchPacketSizes = <int>[2];
    final adapter = adapterFor(fixture);
    await loginHelper(adapter, fixture);
    final before = fixture.oghCalls
        .where((r) => '${r.body['req']}' == 'appcgi.finder.fileSearch')
        .length;

    // 混一个非法位置（`/` 转成存储路径就是空串）和一个正常位置。
    // 若实现把空 path 发了出去，fixture 会回一条 EVERYTHING.pdf，
    // 下面的条数断言就会变成 3 而红。
    final failures = <RootSearchFailure>[];
    final items = await adapter.search(
      '报告',
      roots: ['/', '/vol2/1000'],
      onRootFailure: failures.add,
    );

    final searches = fixture.oghCalls
        .where((r) => '${r.body['req']}' == 'appcgi.finder.fileSearch')
        .toList();
    expectEqual(searches.length - before, 1, '只该为合法位置发一次请求');
    for (final call in searches) {
      final paths = call.body['path'] as List;
      expectTrue('${paths.first}'.isNotEmpty, '发出去的 path 不能为空');
    }
    expectEqual(items.length, 2, '合法位置的结果要保留，且不该混入全库结果');
    expectEqual(failures.length, 1, '非法位置要上报成「这个位置没搜成」');
    expectEqual(failures.single.root, '/', '上报的是哪个位置');
  });

  await check('★ 多包必须拼接：100+200+50 要得到 350 条', () async {
    fixture.reset();
    fixture.searchPacketSizes = <int>[100, 200, 50];
    final adapter = adapterFor(fixture);
    await loginHelper(adapter, fixture);
    final items = await adapter.search('报告', roots: ['/vol2/1000']);
    expectEqual(items.length, 350, '只读第一包会得到 100 条');
  });

  await check('空结果是「没有 data 字段」，不是空数组', () async {
    fixture.reset();
    fixture.searchPacketSizes = <int>[];
    final adapter = adapterFor(fixture);
    await loginHelper(adapter, fixture);
    final items = await adapter.search('zzz无此文件', roots: ['/vol2/1000']);
    expectEqual(items.length, 0, '空结果');
  });

  await check('★ 搜索结果的 path 是父目录，全路径要拼上文件名', () async {
    fixture.reset();
    fixture.searchPacketSizes = <int>[1];
    final adapter = adapterFor(fixture);
    await loginHelper(adapter, fixture);
    final items = await adapter.search('报告', roots: ['/vol2/1000']);
    expectEqual(items.length, 1, '条数');
    expectEqual(items.first.path, '/vol2/1000/子目录/hit_0.pdf', '逻辑全路径');
    expectTrue(items.first.sizeKnown, '搜索项带 size，应当标成已知');
    expectTrue(items.first.modifiedTime != null, '搜索项带 mtim，时间不能为空');
  });

  await check('★ 一个卷失败不影响另一个卷，且要上报这次不完整', () async {
    fixture.reset();
    fixture.searchPacketSizes = <int>[2];
    fixture.failSearchFor['vol1/1000'] = 4100;
    final adapter = adapterFor(fixture);
    await loginHelper(adapter, fixture);
    final failures = <RootSearchFailure>[];
    final items = await adapter.search(
      '报告',
      roots: ['/vol1/1000', '/vol2/1000'],
      onRootFailure: failures.add,
    );
    expectEqual(items.length, 2, 'vol2 的结果要保留');
    expectEqual(failures.length, 1, 'vol1 的失败要上报');
    expectEqual(failures.single.root, '/vol1/1000', '上报的是哪个位置');
  });

  await check('所有卷都失败时才抛异常', () async {
    fixture.reset();
    fixture.failSearchFor['vol1/1000'] = 4100;
    fixture.failSearchFor['vol2/1000'] = 4100;
    final adapter = adapterFor(fixture);
    await loginHelper(adapter, fixture);
    try {
      await adapter.search('报告', roots: ['/vol1/1000', '/vol2/1000']);
      throw '期望抛异常';
    } on AdapterFailure catch (failure) {
      expectEqual(failure.kind, ErrorKind.pathMissing, '错误种类');
    }
  });

  await check('两个卷的结果按逻辑路径去重', () async {
    fixture.reset();
    fixture.searchPacketSizes = <int>[2];
    final adapter = adapterFor(fixture);
    await loginHelper(adapter, fixture);
    final items = await adapter.search('报告', roots: ['/vol2/1000', '/vol2/1000']);
    // 同一卷搜两次，结果完全相同 ⇒ 去重后仍是 2 条。
    expectEqual(items.length, 2, '重复位置不该让结果翻倍');
  });
}

Future<void> transportTests(FnosFixture fixture) async {
  // ignore: avoid_print
  print('\n[4] 传输：401 刷新重试');

  await check('★ 401 后自动刷新并重试一次', () async {
    fixture.reset();
    final adapter = adapterFor(fixture);
    await loginHelper(adapter, fixture);
    fixture.expireNextCall = true;
    final items = await adapter.search('报告', roots: ['/vol2/1000']);
    expectTrue(items.isNotEmpty, '刷新后应当拿到结果');
    final refreshed = fixture.requests.where((r) => r.path == '/oauthapi/refresh');
    expectEqual(refreshed.length, 1, '应当刷新一次');
  });

  await check('file.ls 没有 size 时要标成未知，不能冒充 0', () async {
    fixture.reset();
    final adapter = adapterFor(fixture);
    await loginHelper(adapter, fixture);
    final items = await adapter.list('/vol2/1000/工作资料');
    expectEqual(items.length, 1, '条目数');
    expectTrue(!items.single.sizeKnown, '设备没给大小 ⇒ 未知');
    expectTrue(items.single.isDirectory, '这是一个目录');
  });

  await check('列不存在的目录时报 PathMissing，不说成「空的」', () async {
    fixture.reset();
    final adapter = adapterFor(fixture);
    await loginHelper(adapter, fixture);
    try {
      await adapter.list('/vol2/1000/不存在');
      throw '期望抛 PathMissing';
    } on AdapterFailure catch (failure) {
      expectEqual(failure.kind, ErrorKind.pathMissing, '错误种类');
    }
  });
}

/// [5] 续期：用存下的 refresh token 直接恢复会话。
///
/// 没有这条路，用户每次启动 App 都要再去浏览器授权一遍 —— 而这正是
/// 「mac 上最快速」最不能接受的那种摩擦。这条分支藏过的坑有两个：
///   * 续期成功却把 `refresh_token` 清了（fixture 模拟 refresh 不返回新令牌）；
///   * 令牌失效时报「登录失败」而不是退回授权第一段。
Future<void> resumeTests(FnosFixture fixture) async {
  // ignore: avoid_print
  print('\n[5] 续期：用存下的 refresh token 直接恢复会话');

  await check('★ 带旧令牌登录时不产出授权地址，直接续期成功', () async {
    fixture.reset();
    final first = adapterFor(fixture);
    await loginHelper(first, fixture);
    final saved = first.sessionSecret;
    expectTrue(saved != null && saved.isNotEmpty, '登录后要能交出续期令牌');

    // 统计口径从「续期那一刻」起算：上面 loginHelper 走的完整两段
    // （含一次换码）属于历史，不该算到续期头上。
    final requestsBefore = fixture.requests.length;
    final exchangesBefore =
        fixture.requests.where((r) => r.path == '/oauthapi/third-part/token').length;

    // 新实例 = App 重启后重建的适配器，内存里什么都没有。
    final reborn = adapterFor(fixture);
    final outcome = await reborn.login(username: '', password: saved!);
    expectTrue(outcome is LoginSuccess, '应当直接续期成功，实际 ${outcome.runtimeType}');
    // fixture 的 refresh 不返回新 refresh_token ⇒ 必须保留旧值，否则下次没得刷。
    expectEqual(reborn.sessionSecret, saved, 'refresh 不返回新令牌时要保留旧值');
    expectEqual(
      fixture.requests.where((r) => r.path == '/oauthapi/third-part/token').length,
      exchangesBefore,
      '续期不该再换一次授权码',
    );
    expectTrue(fixture.requests.length > requestsBefore, '续期要真的发过请求（refresh）');
  });

  await check('令牌失效时退回授权流程，不报「登录失败」', () async {
    fixture.reset();
    final adapter = adapterFor(fixture);
    final outcome = await adapter.login(username: '', password: 'refresh-已失效');
    // 这是这条协议下唯一能自救的动作：重新给一个授权地址。
    expectTrue(outcome is LoginNeedsAuthorizeCode,
        '应当退回授权第一段，实际 ${outcome.runtimeType}');
    final challenge = (outcome as LoginNeedsAuthorizeCode)
        .authorizationUrl.queryParameters['code_challenge'];
    expectTrue(challenge?.isNotEmpty == true,
        '退回时必须是一个带 PKCE 的真实授权地址');
  });

  await check('没有存过令牌（空密码）时同样走授权，且不发任何请求', () async {
    fixture.reset();
    final adapter = adapterFor(fixture);
    final outcome = await adapter.login(username: '', password: '');
    expectTrue(outcome is LoginNeedsAuthorizeCode, '空凭据 ⇒ 授权第一段');
    expectEqual(fixture.requests.length, 0, '第一段不该发任何请求');
  });

  await check('未登录时 sessionSecret 必须为空，不许把空串当令牌交出去', () async {
    fixture.reset();
    final adapter = adapterFor(fixture);
    // （「实现了续期接口」是类型事实，静态检查兜底，不写恒真的运行时断言。）
    expectTrue(adapter.sessionSecret == null, '还没登录时不该有令牌');
  });
}

/// 走完整登录（两段），返回已登录的适配器。
Future<void> loginHelper(FnOSAdapter adapter, FnosFixture fixture) async {  final first = await adapter.login(username: '', password: '') as LoginNeedsAuthorizeCode;
  fixture.expectedChallenge = first.authorizationUrl.queryParameters['code_challenge'];
  final second = await adapter.login(username: '', password: '', authorizeCode: 'GOODCODE');
  if (second is! LoginSuccess) throw '登录失败：${second.runtimeType}';
}

// ─────────────────────────── 下载打开（RemoteDownload）───────────────────────────

/// 手工拼一个 stored 条目的 zip（与 fnOS 实测的「单文件也打包」同一形状）。
List<int> buildZip(List<(String, List<int>)> entries) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  var offset = 0;
  for (final (name, data) in entries) {
    final nameBytes = utf8.encode(name);
    final local = BytesBuilder();
    void u16(BytesBuilder b, int v) {
      b.addByte(v & 0xff);
      b.addByte((v >> 8) & 0xff);
    }

    void u32(BytesBuilder b, int v) {
      u16(b, v & 0xffff);
      u16(b, (v >> 16) & 0xffff);
    }

    u32(local, 0x04034b50);
    u16(local, 20); // version needed
    u16(local, 0x0800); // UTF-8 名字
    u16(local, 0); // stored
    u16(local, 0);
    u16(local, 0);
    u32(local, 0); // crc（fixture 不校验）
    u32(local, data.length);
    u32(local, data.length);
    u16(local, nameBytes.length);
    u16(local, 0);
    local.add(nameBytes);
    local.add(data);
    final localBytes = local.takeBytes();
    out.add(localBytes);

    u32(central, 0x02014b50);
    u16(central, 20);
    u16(central, 20);
    u16(central, 0x0800);
    u16(central, 0);
    u16(central, 0);
    u16(central, 0);
    u32(central, 0);
    u32(central, data.length);
    u32(central, data.length);
    u16(central, nameBytes.length);
    u16(central, 0);
    u16(central, 0);
    u16(central, 0);
    u16(central, 0);
    u32(central, 0);
    u32(central, offset);
    central.add(nameBytes);
    offset += localBytes.length;
  }
  final centralBytes = central.takeBytes();
  out.add(centralBytes);
  final eocd = BytesBuilder();
  void u16(BytesBuilder b, int v) {
    b.addByte(v & 0xff);
    b.addByte((v >> 8) & 0xff);
  }

  void u32(BytesBuilder b, int v) {
    u16(b, v & 0xffff);
    u16(b, (v >> 16) & 0xffff);
  }

  u32(eocd, 0x06054b50);
  u16(eocd, 0);
  u16(eocd, 0);
  u16(eocd, entries.length);
  u16(eocd, entries.length);
  u32(eocd, centralBytes.length);
  u32(eocd, offset);
  u16(eocd, 0);
  out.add(eocd.takeBytes());
  return out.takeBytes();
}

/// 打开链（2026-10-29 用户定）：SMB（映射）> 网页；下载只作右键选项。
Future<void> openChainTests(FnosFixture fixture) async {
  await check('打开链：SMB 共享映射——前缀匹配 + 最长优先', () async {
    fixture.reset();
    final adapter = adapterFor(fixture);
    await loginHelper(adapter, fixture);
    fixture.smbShares['vol2/1000/备份/私人'] = '私人空间';
    await adapter.shareRoots();

    final hit = adapter.smbShareFor('/vol2/1000/备份/子/x.pdf');
    expectTrue(hit != null, '共享前缀下应当解析得出');
    expectEqual(hit!.shareName, '备份', '共享名来自 file.share.info');
    expectTrue(
      hit.relativeSegments.join('/') == '子/x.pdf',
      '相对段要去掉共享前缀：${hit.relativeSegments}',
    );

    // 嵌套共享：更长的前缀赢。
    final nested = adapter.smbShareFor('/vol2/1000/备份/私人/a.txt');
    expectEqual(nested!.shareName, '私人空间', '最长前缀优先');

    expectTrue(adapter.smbShareFor('/vol2/1000/其他/y.mp4') == null,
        '不在任何共享前缀下必须返回 null，不许猜');
  });

  await check('打开链：结果行 SMB 命中发 smbLocation，未命中退网页', () async {
    fixture.reset();
    final adapter = adapterFor(fixture);
    await loginHelper(adapter, fixture);
    await adapter.shareRoots();
    final session = BrandSession(adapter,
        sourceID: 's1', sourceName: '飞牛', smbHost: 'nas.local');

    final inside = session.row(
        const FileItem(
            name: 'x.pdf', path: '/vol2/1000/备份/sub/x.pdf', isDirectory: false, size: 3),
        '/vol2/1000');
    final target = inside['openTarget'] as Map<String, Object?>?;
    expectTrue(target != null, '共享前缀下的行必须有打开目标');
    expectEqual(target!['kind'], 'smbLocation', '发 SMB 目标');
    expectEqual(target['share'], '备份', '共享名是映射出来的那个');
    expectTrue(inside['canOpen'] == false, 'SMB 行 canOpen 由 Swift 核对后决定');

    final outside = session.row(
        const FileItem(
            name: 'y.mp4', path: '/vol2/1000/其他/y.mp4', isDirectory: false, size: 4),
        '/vol2/1000');
    final webTarget = outside['openTarget'] as Map<String, Object?>?;
    expectEqual(webTarget!['kind'], 'webLocation', '共享外退网页文件管理器');
    expectTrue(
      webTarget['url'] == 'http://127.0.0.1:${fixture.port}/',
      '网页入口是站点首页（不是 /app/file，那个是 App 容器入口）：${webTarget['url']}',
    );
    expectTrue(outside['canOpen'] == true, '网页行点开就能到，canOpen 为真');
  });

  await check('打开链：SMB 共享列表取不到时行退网页，连接不失败', () async {
    fixture.reset();
    final adapter = adapterFor(fixture);
    await loginHelper(adapter, fixture);
    fixture.smbShares.clear(); // 列共享会 404 → 静默为空
    await adapter.shareRoots();
    expectTrue(adapter.smbShareFor('/vol2/1000/备份/x') == null, '共享表为空时必须解析不出');

    final session = BrandSession(adapter,
        sourceID: 's1', sourceName: '飞牛', smbHost: 'nas.local');
    final row = session.row(
        const FileItem(
            name: 'x.pdf', path: '/vol2/1000/备份/x.pdf', isDirectory: false, size: 3),
        '/vol2/1000');
    expectEqual((row['openTarget'] as Map<String, Object?>)['kind'], 'webLocation',
        '共享表拿不到时退网页');
  });

  await check('打开链：webFileURL 只在实现网页接口时给出', () async {
    fixture.reset();
    final adapter = adapterFor(fixture);
    await loginHelper(adapter, fixture);
    final session = BrandSession(adapter, sourceID: 's1');
    // 2026-10-29 真机：`/app/file` 在浏览器里是 Not Found（App 容器要 ticket，
    // 且容器在 5667，反代环境不通）⇒ 兜底只能是站点首页。
    expectTrue(session.webFileURL == 'http://127.0.0.1:${fixture.port}/',
        'webFileURL 是站点首页：${session.webFileURL}');
  });

  await check('打开链：共享名问不出就跳过那条共享，不拿路径末段猜（2026-10-29 审查）', () async {
    fixture.reset();
    final adapter = adapterFor(fixture);
    await loginHelper(adapter, fixture);
    // 列表里有这条共享，但 info 问不出名字：旧代码会拿「相册」这个目录名
    // 顶上 —— 管理员给共享起别名时会打开错误的共享。
    fixture.smbShares['vol1/1000/相册'] = '我的照片';
    fixture.shareInfoFailFor.add('vol1/1000/相册');
    await adapter.shareRoots();
    expectTrue(adapter.smbShareFor('/vol1/1000/相册/2024/a.jpg') == null,
        '问不出共享名 ⇒ 解析不出 ⇒ 打开退网页，不许猜末段');
  });
}

/// 授权链与权限（2026-10-29 审查）：两段授权必须能走通、默认只申请必需 scope。
Future<void> authorizationFlowTests(FnosFixture fixture) async {
  await check('BrandSession 两段授权：第一段挑战带权限清单，第二段换到令牌', () async {
    fixture.reset();
    final adapter = adapterFor(fixture);
    final session = BrandSession(adapter, sourceID: 's1');
    try {
      await session.login('', '', null);
      throw '第一段应当抛 LoginChallengeRequired';
    } on LoginChallengeRequired catch (challenge) {
      expectTrue(challenge.authorizationUrl.toString().isNotEmpty, '第一段要给出授权地址');
      fixture.expectedChallenge = challenge.authorizationUrl.queryParameters['code_challenge'];
      final scopes = challenge.scopes;
      expectTrue(scopes != null, '权限清单要随挑战一起交给界面');
      expectEqual(scopes!.length, 11, '必需 3 项 + 可选 8 项');
      expectEqual(scopes.where((s) => s['required'] == true).length, 3, '必需项 3 项');
      expectTrue(scopes.every((s) => '${s['label']}'.isNotEmpty), '每项都要有给用户看的说明');
    }
    // ★ 红证：BrandSession.login 若在第二段前先 logout，verifier 会被清掉，
    // 这里必然报「授权流程已过期」。
    await session.login('', '', null, authorizeCode: 'GOODCODE');
    expectTrue(adapter.sessionIdentity != null, '第二段应当登录成功');
  });

  await check('授权地址默认只带必需 scope；勾选可选后追加', () async {
    fixture.reset();
    final adapter = adapterFor(fixture);
    final first = await adapter.login(username: '', password: '') as LoginNeedsAuthorizeCode;
    expectEqual(first.authorizationUrl.queryParameters['scope'],
        'trim.user.all trim.file.read trim.download.all', '默认只申请必需 3 项');
    adapter.requestedOptionalScopes = ['trim.photo.all', 'trim.docker.all'];
    final second = await adapter.login(username: '', password: '') as LoginNeedsAuthorizeCode;
    final scope = second.authorizationUrl.queryParameters['scope'] ?? '';
    expectTrue(scope.contains('trim.photo.all') && scope.contains('trim.docker.all'),
        '勾选的可选项要进授权地址：$scope');
    expectTrue(!scope.contains('trim.file.write'), '没勾的不许进授权地址：$scope');
  });

  await check('requestedOptionalScopes 只认文档里列过的 scope', () async {
    fixture.reset();
    final adapter = adapterFor(fixture);
    adapter.requestedOptionalScopes = ['trim.photo.all', 'trim.made.up.all'];
    final outcome = await adapter.login(username: '', password: '') as LoginNeedsAuthorizeCode;
    final scope = outcome.authorizationUrl.queryParameters['scope'] ?? '';
    expectTrue(scope.contains('trim.photo.all'), '合法的可选项照常带上');
    expectTrue(!scope.contains('made.up'), '凭空造出的 scope 不许进授权地址：$scope');
  });
}

Future<void> downloadTests(FnosFixture fixture) async {
  await check('下载打开：单文件 zip 解包后拿到文件本体', () async {
    fixture.reset();
    final adapter = adapterFor(fixture);
    await loginHelper(adapter, fixture);
    fixture.downloadZipBytes =
        buildZip([('报告.txt', utf8.encode('你好，飞牛'))]);
    final artifact =
        await adapter.downloadToTemp('/vol1/1000/报告.txt', Cancellation());
    expectEqual(artifact.name, '报告.txt', '远端条目名要如实带回');
    expectTrue(artifact.byteSize == utf8.encode('你好，飞牛').length,
        '解包后大小应当已知（单文件）');
    expectTrue(artifact.localPath.endsWith('报告.txt'),
        '单文件 zip 应当交出文件本身：${artifact.localPath}');
    final content = await File(artifact.localPath).readAsString();
    expectEqual(content, '你好，飞牛', '解包内容必须逐字节一致');
    // 请求体契约：paths 数组、不带前导 /（字段名 files/path 都 400，实测）。
    final downloadPost = fixture.requests
        .where((r) => r.path == '/ogh/ac/h/multiple-download')
        .toList();
    expectEqual(jsonEncode(downloadPost.first.body['paths']), jsonEncode(['vol1/1000/报告.txt']),
        '请求体必须是 paths 数组 + 存储侧路径');
  });

  await check('下载打开：GET 401 时刷新一次再重试', () async {
    fixture.reset();
    final adapter = adapterFor(fixture);
    await loginHelper(adapter, fixture);
    fixture.expireNextDownload = true;
    fixture.downloadZipBytes = buildZip([('a.txt', utf8.encode('ok'))]);
    final artifact =
        await adapter.downloadToTemp('/vol1/1000/a.txt', Cancellation());
    expectTrue(artifact.localPath.isNotEmpty, '刷新重试后应当成功');
    final refreshes =
        fixture.requests.where((r) => r.path == '/oauthapi/refresh').length;
    expectTrue(refreshes == 1, '只应刷新一次，实际 $refreshes');
  });

  await check('下载打开：zip-slip 条目名被跳过，不落到解包目录之外', () async {
    fixture.reset();
    final adapter = adapterFor(fixture);
    await loginHelper(adapter, fixture);
    fixture.downloadZipBytes = buildZip([
      ('../evil.txt', utf8.encode('x')),
      ('good.txt', utf8.encode('g')),
    ]);
    final artifact =
        await adapter.downloadToTemp('/vol1/1000/x.txt', Cancellation());
    expectTrue(artifact.localPath.endsWith('good.txt'),
        '只应有干净条目：${artifact.localPath}');
    final extractedRoot = Directory(artifact.localPath).parent;
    expectTrue(
        !await File('${extractedRoot.path}/evil.txt').exists() &&
            !await File('${extractedRoot.parent.path}/evil.txt').exists(),
        '危险条目不许被解出来');
  });

  await check('下载打开：多条目 zip 返回解包目录本身', () async {
    fixture.reset();
    final adapter = adapterFor(fixture);
    await loginHelper(adapter, fixture);
    fixture.downloadZipBytes = buildZip([
      ('相册/a.txt', utf8.encode('1')),
      ('相册/b.txt', utf8.encode('2')),
    ]);
    final artifact =
        await adapter.downloadToTemp('/vol1/1000/相册', Cancellation());
    expectTrue(await FileSystemEntity.isDirectory(artifact.localPath),
        '多条目应当交目录：${artifact.localPath}');
    expectTrue(
        await File('${artifact.localPath}/a.txt').exists() &&
            await File('${artifact.localPath}/b.txt').exists(),
        '两个条目都要在');
  });

  await check('下载打开：设备没给 token 回 DownloadFailed，不挂住', () async {
    fixture.reset();
    final adapter = adapterFor(fixture);
    await loginHelper(adapter, fixture);
    fixture.omitDownloadToken = true;
    try {
      await adapter.downloadToTemp('/vol1/1000/a.txt', Cancellation());
      throw '应当抛出 DownloadFailed';
    } on CoreError catch (error) {
      expectEqual(error.kind, 'DownloadFailed', 'kind 必须可分诊');
    }
  });

  await check('下载打开：空路径与穿越路径拒绝，不发请求', () async {
    fixture.reset();
    final adapter = adapterFor(fixture);
    await loginHelper(adapter, fixture);
    final before = fixture.requests.length;
    for (final bad in ['/', '/vol1/../1000/x', '/a\u0000b']) {
      try {
        await adapter.downloadToTemp(bad, Cancellation());
        throw '$bad 应当抛出 DownloadFailed';
      } on CoreError catch (error) {
        expectEqual(error.kind, 'DownloadFailed', '$bad 必须被本地拒绝');
      }
    }
    expectEqual(fixture.requests.length, before, '本地拒绝不许发网络请求');
  });
}

Future<void> main() async {
  final fixture = FnosFixture();
  await fixture.start();
  // ignore: avoid_print
  print('fnOS 适配器测试（fixture: 127.0.0.1:${fixture.port}）');
  try {
    await loginTests(fixture);
    await shareRootTests(fixture);
    await searchTests(fixture);
    await transportTests(fixture);
    await resumeTests(fixture);
    await downloadTests(fixture);
    await openChainTests(fixture);
    await authorizationFlowTests(fixture);
  } finally {
    await fixture.stop();
  }

  // ignore: avoid_print
  print('\n通过 $_passed，失败 $_failed');
  if (_failed > 0) {
    // ignore: avoid_print
    print('失败项：');
    for (final item in _failures) {
      // ignore: avoid_print
      print('  · $item');
    }
    exitCode = 1;
  }
}
