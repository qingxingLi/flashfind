// OpenList 适配器的行为测试（本地 fixture 按实测契约搭）。
//
// 运行：
//   dart run test_openlist.dart
//
// ── 这里验证的是什么 ─────────────────────────────────────────────
// 每一条用例都对应一个**在真机上实测到的行为**（见
// `00-项目管理/任务交付/OL-AUTH-02-OpenList真实契约验证-20261024.md`），
// 而且都刻意构造成「如果那个行为被改错，这条用例就会红」：
//
//   1. 登录成功/失败**都是 HTTP 200**，只能看 body.code
//      → 若适配器改回用 statusCode 判断，第 2 条立刻红（会把密码错当成功）
//   2. token 失效是 code=401 + HTTP 200
//      → 若只看 HTTP 码，会当成列目录成功并返回空，第 3 条红
//   3. 空关键字必须**不发请求**就拒绝
//      → 真机上空关键字返回 80315 条；若哪天放开，第 4 条的请求计数会变
//   4. 搜索必须逐 root 用 scope=0，fixture 也照真机语义区分 scope
//      → 若改回 1，fixture 只回目录，「结果里必须有文件」那条断言会红
//   5. 两类 code=500 语义相反
//      → 若合并成一个错误，第 7/8 条会红
//   6. 结果项没有修改时间
//      → 若有人拿别的值填 modifiedTime，第 9 条红
//
// **不验证**：真机兼容性。fixture 通过 ≠ 真机通过（飞牛那条线已经实证过）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'lib/adapter_contract.dart';
import 'lib/adapter_registry.dart';
import 'lib/adapter_support.dart';
import 'lib/adapters/openlist.dart';
import 'lib/brand_session.dart';
import 'lib/dio_compat.dart';
import 'lib/error_kinds.dart';
import 'lib/upstream_file_types.dart' show FileItem;

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

/// 逐项比较两个列表。
///
/// ★ 不能直接用 `expectEqual`：Dart 的 `List` 没重写 `==`，比的是引用，
/// `[1,2,3] == [1,2,3]` 为 false。第一版测试就栽在这——
/// 报错信息里「期望 [1, 2, 3]，实际 [1, 2, 3]」看着一模一样。
void expectListEqual(List<Object?> actual, List<Object?> expected, String message) {
  if (actual.length != expected.length) {
    throw StateError('$message：长度期望 ${expected.length}，实际 ${actual.length}'
        '（期望 $expected，实际 $actual）');
  }
  for (var i = 0; i < actual.length; i++) {
    if (actual[i] != expected[i]) {
      throw StateError('$message：第 $i 项期望 ${expected[i]}，实际 ${actual[i]}'
          '（期望 $expected，实际 $actual）');
    }
  }
}

// ─────────────────────────────────────────────────────────────
// fixture：按 OpenList 实测形状回包
// ─────────────────────────────────────────────────────────────

/// 一次被 fixture 收到的请求，用于断言「发了什么、发了几次」。
class RecordedRequest {
  RecordedRequest(this.path, this.body, this.authorization);
  final String path;
  final Map<String, Object?> body;
  final String? authorization;
  @override
  String toString() => '$path $body';
}

const _goodUser = 'demo_user';
const _goodPass = 'demo_pass';
const _goodToken = 'demo-token-abc';

/// 开了 TOTP 两步验证的账号。契约来自上游 `server/handles/auth.go`（v4.1.10）：
/// 密码校验通过后 `user.OtpSecret != ""` ⇒ `totp.Validate(req.OtpCode)` 失败即
/// `code=402 "Invalid 2FA code"`，HTTP 仍是 200。**码缺与码错回的是同一个 402**，
/// 服务端不区分，只能由客户端按「这次带没带码」自己判。
const _otpUser = 'otp_user';
const _otpPass = 'otp_pass';
const _otpCode = '123456';

/// 根目录下的存储。
const _rootStorages = <Map<String, Object?>>[
  {'name': 'A0001', 'is_dir': true, 'size': 0, 'type': 1},
  {'name': 'B0002', 'is_dir': true, 'size': 0, 'type': 1},
  {'name': 'readme.md', 'is_dir': false, 'size': 12, 'type': 0},
];

class Fixture {
  Fixture(this.server, this.port);
  final HttpServer server;
  final int port;

  final List<RecordedRequest> requests = [];

  /// 让某个路径的 list 返回 code=500。
  String? listFailureMessage;

  /// 搜索每页返回的条目数上限（用于造分页）。
  int searchTotal = 3;

  /// 让根目录只返回文件、不返回任何存储（用于验证 EmptyScope）。
  bool rootHasNoDir = false;

  /// 某个存储「搜索索引里有、但实际读不了」——模拟真机上 `/C0115` 那种
  /// 上游网盘授权失效：list 报错，search 照样靠索引返回结果。
  String? deadRoot;

  List<RecordedRequest> get searchRequests =>
      requests.where((r) => r.path == '/api/fs/search').toList();

  List<RecordedRequest> get listRequests =>
      requests.where((r) => r.path == '/api/fs/list').toList();

  void reset() {
    requests.clear();
    listFailureMessage = null;
    searchTotal = 3;
    rootHasNoDir = false;
    deadRoot = null;
  }

  Future<void> close() => server.close(force: true);
}

Future<Fixture> startFixture() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final fixture = Fixture(server, server.port);

  server.listen((request) async {
    final raw = await utf8.decoder.bind(request).join();
    Map<String, Object?> body = const {};
    if (raw.isNotEmpty) {
      try {
        body = (jsonDecode(raw) as Map).cast<String, Object?>();
      } catch (_) {
        body = const {};
      }
    }
    fixture.requests.add(RecordedRequest(
      request.uri.path,
      body,
      request.headers.value('authorization'),
    ));

    request.response.headers.contentType = ContentType.json;

    void reply(Map<String, Object?> envelope) {
      request.response.write(jsonEncode(envelope));
    }

    switch (request.uri.path) {
      case '/api/auth/login':
        final user = body['username'];
        final pass = body['password'];
        if (user == _otpUser) {
          // 2FA 账号：密码对之后还要 otp_code；缺码与错码**都回同一个 402**。
          if (pass != _otpPass) {
            reply({'code': 400, 'message': 'password is incorrect', 'data': null});
          } else if (body['otp_code'] != _otpCode) {
            reply({'code': 402, 'message': 'Invalid 2FA code', 'data': null});
          } else {
            reply({
              'code': 200,
              'message': 'success',
              'data': {'token': _goodToken},
            });
          }
        } else if (user == _goodUser && pass == _goodPass) {
          reply({
            'code': 200,
            'message': 'success',
            'data': {'token': _goodToken},
          });
        } else {
          // ★ 真机实测：密码错是 HTTP 200 + code=400，不是 401。
          reply({'code': 400, 'message': 'password is incorrect', 'data': null});
        }

      case '/api/fs/list':
        // ★ 真机实测：token 坏是 HTTP 200 + code=401。
        if (request.headers.value('authorization') != _goodToken) {
          reply({'code': 401, 'message': 'token is invalidated', 'data': null});
          break;
        }
        final message = fixture.listFailureMessage;
        if (message != null) {
          // ★ 真机实测：HTTP 200 + code=500。
          reply({'code': 500, 'message': message, 'data': null});
          break;
        }
        final path = '${body['path'] ?? '/'}';
        // 「索引里有、实际读不了」的存储：list 必须失败（search 不受影响）。
        if (fixture.deadRoot != null && path == fixture.deadRoot) {
          reply({
            'code': 500,
            'message':
                'failed get objs: failed to list objs: code: 40140120, message: token expired',
            'data': null,
          });
          break;
        }
        if (path == '/') {
          final content = fixture.rootHasNoDir
              ? _rootStorages.where((e) => e['is_dir'] != true).toList()
              : _rootStorages;
          reply({
            'code': 200,
            'message': 'success',
            'data': {
              'content': content,
              'total': content.length,
              'readme': '',
              'header': '',
              'write': true,
              'provider': 'local',
            },
          });
          break;
        }
        // 造一个 250 条的目录用于验证分页（per_page=100 ⇒ 应请求 3 次）。
        final page = (body['page'] as num?)?.toInt() ?? 1;
        final perPage = (body['per_page'] as num?)?.toInt() ?? 100;
        const total = 250;
        final start = (page - 1) * perPage;
        final count = (start >= total) ? 0 : (total - start).clamp(0, perPage);
        final items = List.generate(
          count,
          (i) => {
            'name': 'file_${start + i}.txt',
            'is_dir': false,
            'size': 100 + i,
            'type': 0,
          },
        );
        reply({
          'code': 200,
          'message': 'success',
          'data': {'content': items, 'total': total, 'readme': '', 'header': ''},
        });

      case '/api/fs/search':
        if (request.headers.value('authorization') != _goodToken) {
          reply({'code': 401, 'message': 'token is invalidated', 'data': null});
          break;
        }
        final parent = '${body['parent'] ?? '/'}';
        final page = (body['page'] as num?)?.toInt() ?? 1;
        final perPage = (body['per_page'] as num?)?.toInt() ?? 100;
        final scope = (body['scope'] as num?)?.toInt() ?? 0;
        final total = fixture.searchTotal;
        final start = (page - 1) * perPage;
        final count = (start >= total) ? 0 : (total - start).clamp(0, perPage);
        // ★ fixture 必须跟着 scope 变，照抄真机语义
        //   （上游 internal/db/searchnode.go：0=全部 / 1=仅目录 / 2=仅文件）。
        //
        //   1.1.11 就是在这里漏掉的：fixture 恒返回文件，于是「发错 scope」
        //   在这套测试里一条都不会红，真机上却只能搜到文件夹。
        final isDir = scope == 1;
        final items = List.generate(count, (i) {
          final index = start + i;
          return {
            'parent': parent == '/' ? '/A0001/docs' : parent,
            'name': isDir ? 'hit_$index' : 'hit_$index.pdf',
            'is_dir': isDir,
            'size': 4096,
            'type': isDir ? 1 : 0,
          };
        });
        reply({
          'code': 200,
          'message': 'success',
          'data': {'content': items, 'total': total},
        });

      default:
        reply({'code': 404, 'message': 'no such endpoint', 'data': null});
    }

    await request.response.close();
  });

  return fixture;
}

OpenListAdapter adapterFor(Fixture fixture) {
  final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:${fixture.port}'))
    ..allowInsecureHTTP = true;
  return OpenListAdapter(dio: dio);
}

// ─────────────────────────────────────────────────────────────
// 测试
// ─────────────────────────────────────────────────────────────

Future<void> main() async {
  // ignore: avoid_print
  print('\n[1] OpenList 适配器（本地 fixture 按实测契约搭）');

  final fixture = await startFixture();
  try {
    await loginTests(fixture);
    await otpTests(fixture);
    await listTests(fixture);
    await searchTests(fixture);
    await partialFailureTests(fixture);
    await shapeTests(fixture);
    await registryTests();
    await openTargetTests();
  } finally {
    await fixture.close();
  }

  // ignore: avoid_print
  print('\n通过 $_passed，失败 $_failed');
  if (_failed > 0) {
    // ignore: avoid_print
    print('失败项：');
    for (final f in _failures) {
      // ignore: avoid_print
      print('  · $f');
    }
    exitCode = 1;
  }
}

Future<void> loginTests(Fixture fixture) async {
  // ignore: avoid_print
  print('\n  登录');

  await check('登录成功拿到会话身份，且令牌走 authorization 头', () async {
    fixture.reset();
    final adapter = adapterFor(fixture);
    final outcome = await adapter.login(username: _goodUser, password: _goodPass);
    expectTrue(outcome is LoginSuccess, '期望 LoginSuccess，实际 $outcome');
    expectTrue(adapter.sessionIdentity != null, '登录后应有会话身份');
    final login = fixture.requests.firstWhere((r) => r.path == '/api/auth/login');
    expectEqual(login.body['username'], _goodUser, '请求体账号');
  });

  await check('★ 密码错是 HTTP 200 + code=400，必须判为登录失败', () async {
    fixture.reset();
    final adapter = adapterFor(fixture);
    // 这条用例就是冲着「用 statusCode 判断」那个坑来的：
    // 服务端回的是 200，任何把 HTTP 200 当成功的实现都会在这里拿到 LoginSuccess。
    final outcome = await adapter.login(username: _goodUser, password: 'wrong');
    expectTrue(outcome is LoginRejected, '期望 LoginRejected，实际 $outcome');
    final rejected = outcome as LoginRejected;
    expectTrue(rejected.reason.contains('密码'), '拒绝原因应说明密码问题，实际：${rejected.reason}');
    expectEqual(rejected.apiCode, 400, '设备码');
    expectTrue(adapter.sessionIdentity == null, '登录失败不应留下会话身份');
  });

  await check('同一账号重登换一个会话身份', () async {
    fixture.reset();
    final adapter = adapterFor(fixture);
    await adapter.login(username: _goodUser, password: _goodPass);
    final first = adapter.sessionIdentity;
    await Future<void>.delayed(const Duration(milliseconds: 3));
    await adapter.login(username: _goodUser, password: _goodPass);
    final second = adapter.sessionIdentity;
    expectTrue(first != second, '重登后的身份应不同（代次判定依赖它）');
  });

  await check('登出清空本地会话状态', () async {
    fixture.reset();
    final adapter = adapterFor(fixture);
    await adapter.login(username: _goodUser, password: _goodPass);
    await adapter.logout();
    expectTrue(adapter.sessionIdentity == null, '登出后不应再有身份');
  });
}

/// 两步验证（TOTP）。
///
/// 依据：上游 `server/handles/auth.go`（v4.1.10，与本实例同版）。
/// **没有开 2FA 的账号可做真机验证**，所以这里锁的是协议行为与接线，
/// 不是「真机上已经点通过」——那一条要等用户拿开了 2FA 的账号实测。
Future<void> otpTests(Fixture fixture) async {
  // ignore: avoid_print
  print('\n  两步验证（TOTP）');

  await check('★ 开了 2FA 的账号：不带码时是「要码」，且请求体里没有 otp_code', () async {
    fixture.reset();
    final adapter = adapterFor(fixture);
    final outcome = await adapter.login(username: _otpUser, password: _otpPass);
    expectTrue(outcome is LoginNeedsOTP, '期望 LoginNeedsOTP，实际 $outcome');
    final needs = outcome as LoginNeedsOTP;
    expectTrue(!needs.rejected, '没带码时应是「要码」，不是「码被拒」');
    final login = fixture.requests.firstWhere((r) => r.path == '/api/auth/login');
    // 空串会被服务端当「给了但不对」，于是「还没要码」与「码错了」在现场无法区分。
    expectTrue(!login.body.containsKey('otp_code'), '没带码时不该发 otp_code');
    expectTrue(adapter.sessionIdentity == null, '2FA 未完成时不该留会话身份');
  });

  await check('★ 带正确的 6 位码 → 登录成功，且码真的发给了服务端', () async {
    fixture.reset();
    final adapter = adapterFor(fixture);
    final outcome =
        await adapter.login(username: _otpUser, password: _otpPass, otpCode: _otpCode);
    expectTrue(outcome is LoginSuccess, '期望 LoginSuccess，实际 $outcome');
    expectTrue(adapter.sessionIdentity != null, '登录后应有会话身份');
    final login = fixture.requests.firstWhere((r) => r.path == '/api/auth/login');
    expectEqual(login.body['otp_code'], _otpCode, '请求体里的动态码');
  });

  await check('★ 带错码 → 「码被拒」，不能说成密码错', () async {
    fixture.reset();
    final adapter = adapterFor(fixture);
    final outcome =
        await adapter.login(username: _otpUser, password: _otpPass, otpCode: '000000');
    expectTrue(outcome is LoginNeedsOTP, '期望 LoginNeedsOTP，实际 $outcome');
    final needs = outcome as LoginNeedsOTP;
    expectTrue(needs.rejected, '带了码却被 402 拒绝，必须标成 rejected');
    expectTrue(adapter.sessionIdentity == null, '2FA 未完成时不该留会话身份');
  });

  await check('★ 会话层把 402 翻成 NeedsOTP / OTPRejected（界面靠这个弹窗）', () async {
    // 未带码 → NeedsOTP：Swift 侧据此弹出「请输入 6 位动态码」。
    final first = BrandSession(adapterFor(fixture), sourceID: 'src-otp-1');
    try {
      await first.login(_otpUser, _otpPass, null);
      throw StateError('期望抛 AdapterFailure，实际登录成功');
    } on AdapterFailure catch (failure) {
      expectEqual(failure.kind, ErrorKind.needsOTP, '未带码时的错误类型');
    }

    // 带了码被拒 → OTPRejected：文案要能说「刚才那 6 位不对」，
    // 而不是回到「该账号需要动态验证码」（用户会以为界面没理他）。
    final second = BrandSession(adapterFor(fixture), sourceID: 'src-otp-2');
    try {
      await second.login(_otpUser, _otpPass, '000000');
      throw StateError('期望抛 AdapterFailure，实际登录成功');
    } on AdapterFailure catch (failure) {
      expectEqual(failure.kind, ErrorKind.otpRejected, '码错时的错误类型');
    }
  });

  await check('普通账号（没开 2FA）不会被 402 干扰', () async {
    fixture.reset();
    final adapter = adapterFor(fixture);
    final outcome = await adapter.login(username: _goodUser, password: _goodPass);
    expectTrue(outcome is LoginSuccess, '期望 LoginSuccess，实际 $outcome');
  });
}

Future<void> listTests(Fixture fixture) async {
  // ignore: avoid_print
  print('\n  列目录');

  await check('根目录列出存储（目录项）', () async {
    fixture.reset();
    final adapter = adapterFor(fixture);
    await adapter.login(username: _goodUser, password: _goodPass);
    final roots = await adapter.shareRoots();
    expectEqual(roots.length, 2, '只有 is_dir 的项才是存储');
    expectEqual(roots.first.path, '/A0001', '第一个存储路径');
    expectEqual(roots.last.name, 'B0002', '第二个存储名');
  });

  await check('根目录只有文件时抛 EmptyScope 而不是静默返回空', () async {
    fixture.reset();
    fixture.rootHasNoDir = true;
    final adapter = adapterFor(fixture);
    await adapter.login(username: _goodUser, password: _goodPass);
    try {
      await adapter.shareRoots();
      throw StateError('期望抛 EmptyScope，实际成功返回空列表');
    } on AdapterFailure catch (e) {
      expectEqual(e.kind, ErrorKind.emptyScope, '错误种类');
      expectTrue(e.message.contains('存储'), '文案应指向「去网页端添加存储」，实际：${e.message}');
    }
  });

  await check('★ token 失效是 HTTP 200 + code=401，必须报会话失效', () async {
    fixture.reset();
    final adapter = adapterFor(fixture);
    await adapter.login(username: _goodUser, password: _goodPass);
    // 换一个坏令牌：真机上服务端回 200 + code=401。
    final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:${fixture.port}'))
      ..allowInsecureHTTP = true;
    final forged = OpenListAdapter(dio: dio);
    try {
      await forged.list('/');
      throw StateError('期望抛会话失效，实际成功返回');
    } on AdapterFailure catch (e) {
      expectEqual(e.kind, ErrorKind.sessionExpired, '错误种类');
    }
  });

  await check('★ 分页：250 条按 per_page=100 翻 3 页取全', () async {
    fixture.reset();
    final adapter = adapterFor(fixture);
    await adapter.login(username: _goodUser, password: _goodPass);
    final items = await adapter.list('/A0001/docs');
    expectEqual(items.length, 250, '应取满 total');
    final lists = fixture.listRequests;
    expectEqual(lists.length, 3, '应请求 3 页（100+100+50）');
    expectListEqual(lists.map((r) => r.body['page']).toList(), [1, 2, 3], '翻页顺序');
    expectEqual(lists.first.body['per_page'], 100, '每页条数应自限为 100');
  });

  await check('★ 500「storage not found」判为路径不存在', () async {
    fixture.reset();
    fixture.listFailureMessage = 'failed get storage: storage not found; rawPath: /GONE';
    final adapter = adapterFor(fixture);
    await adapter.login(username: _goodUser, password: _goodPass);
    try {
      await adapter.list('/GONE');
      throw StateError('期望抛 PathMissing，实际成功返回');
    } on AdapterFailure catch (e) {
      expectEqual(e.kind, ErrorKind.pathMissing, '错误种类');
    }
  });

  await check('★ 500「failed to list objs」判为上游存储失效，不能混成路径不存在', () async {
    fixture.reset();
    fixture.listFailureMessage =
        'failed get objs: failed to list objs: code: 40140120, message: token expired';
    final adapter = adapterFor(fixture);
    await adapter.login(username: _goodUser, password: _goodPass);
    try {
      await adapter.list('/UPSTREAM');
      throw StateError('期望抛业务错误，实际成功返回');
    } on AdapterFailure catch (e) {
      expectEqual(e.kind, ErrorKind.apiError, '错误种类应是业务错误而不是 PathMissing');
      expectTrue(e.message.contains('上游'), '文案要说清是上游网盘授权失效，实际：${e.message}');
    }
  });
}

Future<void> searchTests(Fixture fixture) async {
  // ignore: avoid_print
  print('\n  搜索');

  await check('★ 空关键字直接拒绝，且不发出任何搜索请求', () async {
    fixture.reset();
    final adapter = adapterFor(fixture);
    await adapter.login(username: _goodUser, password: _goodPass);
    fixture.reset(); // 只统计搜索阶段的请求
    try {
      await adapter.search('   ', roots: const ['/A0001']);
      throw StateError('期望拒绝空查询，实际成功返回');
    } on AdapterFailure catch (e) {
      expectEqual(e.kind, ErrorKind.unsupportedQuery, '错误种类');
    }
    // 真机上空关键字会返回全站 8 万条，所以这里的关键是「一个请求都没发」。
    expectEqual(fixture.searchRequests.length, 0, '空查询不得发出搜索请求');
  });

  await check('★ 搜索只用 scope=0，逐 root 各发一次', () async {
    fixture.reset();
    final adapter = adapterFor(fixture);
    await adapter.login(username: _goodUser, password: _goodPass);
    fixture.reset();
    await adapter.search('报告', roots: const ['/A0001', '/B0002']);
    final searches = fixture.searchRequests;
    expectEqual(searches.length, 2, '两个 root 应各发一次');
    expectListEqual(searches.map((r) => r.body['scope']).toList(), [0, 0],
        'scope 必须是 0（上游语义：0=全部 / 1=仅目录 / 2=仅文件；'
        '1.1.11 写成 1，真机上只能搜到文件夹）');
    expectListEqual(searches.map((r) => r.body['parent']).toList(),
        ['/A0001', '/B0002'], 'parent 必须是各 root 自己');
    expectEqual(searches.first.body['keywords'], '报告', '关键字应原样传递（中文不转码）');
    expectEqual(searches.first.body['per_page'], 100, '每页条数应自限');
  });

  await check('★ scope=0 的结果里必须有文件，不能只剩文件夹', () async {
    fixture.reset();
    final adapter = adapterFor(fixture);
    await adapter.login(username: _goodUser, password: _goodPass);
    fixture.reset();
    final items = await adapter.search('报告', roots: const ['/A0001']);
    expectTrue(items.isNotEmpty, '应有结果');
    // ★ 这条就是 1.1.11 的 bug：fixture 以前恒返回文件，所以「发错 scope」全绿；
    //   现在 fixture 照真机语义（scope=1 只回目录）返回，发错这里必红。
    expectTrue(items.any((i) => !i.isDirectory),
        '结果里必须至少有一个文件，实际全是文件夹（scope 写成了 1？）');
  });

  await check('★ 有 root 搜通但零命中时：不抛别的存储的 500，但必须如实上报那个没搜通的位置', () async {
    fixture.reset();
    fixture.deadRoot = '/DEAD';
    fixture.searchTotal = 0; // /A0001 搜通但确实没命中
    final adapter = adapterFor(fixture);
    await adapter.login(username: _goodUser, password: _goodPass);
    fixture.reset();
    fixture.deadRoot = '/DEAD';
    fixture.searchTotal = 0; // ★ reset() 会冲回 3，必须再设一次
    final failures = <RootSearchFailure>[];
    final items = await adapter.search('报告', roots: const ['/DEAD', '/A0001'],
        onRootFailure: failures.add);
    // 结论对**搜通的那部分**来说是「没有找到」，不该把 500 顶成整次搜索的失败。
    expectEqual(items.length, 0, '应返回空结果而不是抛错');
    // ★ 但「不抛错」不等于「没这回事」：/DEAD 必须被报出来，
    //   否则上层只能说「没有找到」——而真相是有一个位置根本没搜。
    expectListEqual(failures.map((f) => f.root).toList(), ['/DEAD'],
        '没搜通的位置必须逐条上报（只检查返回数组会漏掉这一半）');
  });

  await check('★ 适配器把每个没搜通的根逐条上报，可读根的结果照常返回', () async {
    fixture.reset();
    fixture.deadRoot = '/B0002';
    final adapter = adapterFor(fixture);
    await adapter.login(username: _goodUser, password: _goodPass);
    fixture.reset();
    fixture.deadRoot = '/B0002';
    final failures = <RootSearchFailure>[];
    final items = await adapter.search('报告', roots: const ['/A0001', '/B0002'],
        onRootFailure: failures.add);
    expectEqual(items.length, 3, '可读 root 的结果照常返回');
    expectEqual(failures.length, 1, '只上报没搜通的那一个');
    expectEqual(failures.first.root, '/B0002', '上报的根路径');
  });

  await check('★ 所有 root 都没搜通时，才把失败报出去', () async {
    fixture.reset();
    final adapter = adapterFor(fixture);
    await adapter.login(username: _goodUser, password: _goodPass);
    fixture.reset();
    fixture.deadRoot = '/DEAD';
    try {
      await adapter.search('报告', roots: const ['/DEAD']);
      throw StateError('期望报错，实际返回了空结果');
    } on AdapterFailure catch (e) {
      expectTrue(e.message.contains('上游'), '文案要说清是上游授权失效：${e.message}');
    }
  });

  await check('同一目录重复出现在 roots 里时结果按路径去重', () async {
    fixture.reset();
    final adapter = adapterFor(fixture);
    await adapter.login(username: _goodUser, password: _goodPass);
    fixture.reset();
    // 真实场景：用户勾了父子两个目录（/A0001 与 /A0001/docs），
    // 同一文件会被两次搜索各命中一次，必须只留一条。
    final items = await adapter.search('报告', roots: const ['/A0001', '/A0001']);
    expectEqual(items.length, 3, '同一路径只保留一条');
    final paths = items.map((i) => i.path).toSet();
    expectEqual(paths.length, items.length, '结果路径应唯一');
  });

  await check('★ 搜索的翻页与 total 一致', () async {
    fixture.reset();
    final adapter = adapterFor(fixture);
    await adapter.login(username: _goodUser, password: _goodPass);
    // ★ 顺序要紧：reset() 会把 searchTotal 冲回 3，必须先 reset 再设值。
    fixture.reset();
    fixture.searchTotal = 150;
    final items = await adapter.search('报告', roots: const ['/A0001']);
    expectEqual(items.length, 150, '应取满 total');
    expectEqual(fixture.searchRequests.length, 2, '150 条按 100/页应翻 2 页');
  });

  await check('没有授权范围时抛 ScopeUnset，不发请求', () async {
    fixture.reset();
    final adapter = adapterFor(fixture);
    await adapter.login(username: _goodUser, password: _goodPass);
    fixture.reset();
    try {
      await adapter.search('报告', roots: const []);
      throw StateError('期望拒绝，实际成功返回');
    } on AdapterFailure catch (e) {
      expectEqual(e.kind, ErrorKind.scopeUnset, '错误种类');
    }
    expectEqual(fixture.searchRequests.length, 0, '未选范围不应发请求');
  });

  await check('★ 索引有结果但存储读不了时，不把死链当结果返回', () async {
    fixture.reset();
    final adapter = adapterFor(fixture);
    await adapter.login(username: _goodUser, password: _goodPass);
    fixture.reset();
    fixture.deadRoot = '/DEAD';
    // fixture 的 search 不看 deadRoot，照样返回 3 条——正是真机上 /C0115 的形态：
    // 搜索走索引成功、列目录走上游失败。只搜不验的实现在这里会拿到 3 条死链。
    try {
      await adapter.search('报告', roots: const ['/DEAD']);
      throw StateError('期望报错，实际把死链当结果返回了');
    } on AdapterFailure catch (e) {
      expectTrue(
        e.kind == ErrorKind.apiError || e.kind == ErrorKind.pathMissing,
        '错误种类应是业务错误或路径不存在，实际 ${e.kind}',
      );
      expectTrue(e.message.contains('上游'), '文案要说清是上游授权失效：${e.message}');
    }
  });

  await check('一个 root 读不了不影响其他 root 正常返回结果', () async {
    fixture.reset();
    final adapter = adapterFor(fixture);
    await adapter.login(username: _goodUser, password: _goodPass);
    fixture.reset();
    fixture.deadRoot = '/DEAD';
    final items = await adapter.search('报告', roots: const ['/DEAD', '/A0001']);
    // 单个存储失效不该让整次搜索失败：/A0001 有结果就应当交出来。
    expectEqual(items.length, 3, '可读 root 的结果应照常返回');
  });
}

/// 部分失败：**不许伪装成完整的零结果**。
///
/// 1.1.16 的形态（Codex 复审提出）：只要有一个 root 搜通（哪怕零命中），
/// 适配器就吞掉其它 root 的错误，`BrandSession` 于是报
/// `completed / isComplete=true / partial=false`。界面上就是
/// 「没有找到」，而真相是**有一个位置压根没搜过**——
/// 用户会以为这台设备上没有这个文件。
///
/// 下面这几条锁的是**会话的最终状态与元数据**，不是适配器返回的那个数组：
/// 只查数组的话，「吞掉失败」与「如实上报」两种情况长得一模一样。
Future<void> partialFailureTests(Fixture fixture) async {
  // ignore: avoid_print
  print('\n  部分失败（会话层）');

  Future<BrandSession> sessionFor(List<String> roots) async {
    final adapter = adapterFor(fixture);
    await adapter.login(username: _goodUser, password: _goodPass);
    final session = BrandSession(adapter, sourceID: 'src-partial');
    await session.selectScopes(roots);
    return session;
  }

  await check('★ 有位置没搜通时，会话必须报不完整，而不是「没有找到」', () async {
    fixture.reset();
    fixture.deadRoot = '/B0002'; // 预检失败：上游网盘授权失效
    fixture.searchTotal = 0; // /A0001 搜通但确实零命中
    final session = await sessionFor(const ['/A0001', '/B0002']);
    fixture.reset();
    fixture.deadRoot = '/B0002';
    fixture.searchTotal = 0;

    final out = await session.search('报告', 'q-partial-1');

    expectEqual(out.state, 'completed', '搜通的那部分结果仍然有效，状态是完成');
    expectEqual(out.files.length, 0, '/A0001 确实没命中');
    expectTrue(out.partial, '★ 必须标记不完整（1.1.16 这里是 false）');
    expectTrue(!out.complete, '★ isComplete 必须为 false（1.1.16 这里是 true）');
    expectListEqual(out.failedRoots, ['/B0002'], '必须说清是哪几个位置没搜');
    expectTrue(out.error != null, '必须带上没搜通的原因');
    expectTrue((out.partialNote ?? '').contains('/B0002'),
        '给界面的说明要写出位置名，实际：${out.partialNote}');
  });

  await check('★ 成功与失败并存：保留成功部分，同时报不完整', () async {
    fixture.reset();
    fixture.deadRoot = '/B0002';
    final session = await sessionFor(const ['/A0001', '/B0002']);
    fixture.reset();
    fixture.deadRoot = '/B0002';

    final out = await session.search('报告', 'q-partial-2');

    expectEqual(out.files.length, 3, '可读位置的结果必须保留');
    expectEqual(out.state, 'completed', '有结果就更不能说成失败');
    expectTrue(out.partial, '同时有位置没搜通，必须报不完整');
    expectListEqual(out.failedRoots, ['/B0002'], '失败位置');
    // 结果行本身不受影响：不因为「有几个位置坏了」就少给字段。
    expectEqual(out.files.first['path'], '/A0001/hit_0.pdf', '结果路径');
  });

  await check('★ 所有位置都没搜通时，才算这次搜索失败', () async {
    fixture.reset();
    fixture.deadRoot = '/B0002';
    final session = await sessionFor(const ['/B0002']);
    fixture.reset();
    fixture.deadRoot = '/B0002';

    final out = await session.search('报告', 'q-partial-3');

    expectEqual(out.state, 'failed', '一台存储都没搜通就是失败');
    expectEqual(out.files.length, 0, '没有可交付的结果');
    expectTrue(out.error != null, '失败必须带原因');
  });

  await check('全部位置都正常时不得标记不完整（回归）', () async {
    fixture.reset();
    final session = await sessionFor(const ['/A0001']);
    fixture.reset();

    final out = await session.search('报告', 'q-partial-4');

    expectEqual(out.files.length, 3, '正常搜索的结果');
    expectTrue(!out.partial, '没有失败位置就不该标不完整');
    expectTrue(out.complete, '完整就是完整');
    expectTrue(out.failedRoots.isEmpty, '失败位置应为空');
    expectTrue(out.partialNote == null, '不该凭空给一句说明');
  });
}

Future<void> shapeTests(Fixture fixture) async {
  // ignore: avoid_print
  print('\n  数据形状');

  await check('★ 结果项没有修改时间时保持 null，不拿别的值冒充', () async {
    fixture.reset();
    final adapter = adapterFor(fixture);
    await adapter.login(username: _goodUser, password: _goodPass);
    fixture.reset();
    final items = await adapter.search('报告', roots: const ['/A0001']);
    expectTrue(items.isNotEmpty, '应有结果');
    for (final item in items) {
      expectTrue(item.modifiedTime == null, '服务端不提供 mtime，不得编造（${item.name}）');
      expectTrue(item.createdTime == null, '服务端不提供创建时间，不得编造');
    }
  });

  await check('目录不报大小（is_dir 的 size 不是内容大小）', () async {
    fixture.reset();
    final adapter = adapterFor(fixture);
    await adapter.login(username: _goodUser, password: _goodPass);
    final roots = await adapter.shareRoots();
    for (final root in roots) {
      final items = await adapter.list(root.path);
      for (final item in items.where((i) => i.isDirectory)) {
        expectTrue(!item.sizeKnown, '目录的大小应标记为未知（${item.name}）');
        expectEqual(item.size, 0, '目录 size 应为 0');
      }
    }
  });

  await check('搜索结果的完整路径由 parent + name 拼出', () async {
    fixture.reset();
    final adapter = adapterFor(fixture);
    await adapter.login(username: _goodUser, password: _goodPass);
    fixture.reset();
    final items = await adapter.search('报告', roots: const ['/A0001']);
    expectTrue(items.isNotEmpty, '应有结果');
    // 实测结果项自带 parent 字段；适配器必须用它而不是拿 root 顶替。
    expectEqual(items.first.path, '/A0001/hit_0.pdf', '结果路径');
    expectEqual(items.first.extension, '.pdf', '扩展名');
  });

  await check('列目录的条目路径不含双斜杠', () async {
    fixture.reset();
    final adapter = adapterFor(fixture);
    await adapter.login(username: _goodUser, password: _goodPass);
    final items = await adapter.list('/A0001/docs/');
    for (final item in items.take(5)) {
      expectTrue(!item.path.contains('//'), '路径不应出现双斜杠：${item.path}');
    }
  });
}

Future<void> registryTests() async {
  // ignore: avoid_print
  print('\n  注册表');

  await check('openlist 已注册且属真机验证档', () async {
    expectTrue(stableVendors.contains('openlist'), 'openlist 应在 stableVendors');
    expectTrue(hasBrandAdapter('openlist'), 'hasBrandAdapter 应认 openlist');
  });

  await check('工厂能造出 OpenListAdapter', () async {
    final adapter = createBrandAdapter(
      'openlist',
      endpoint: 'https://example.invalid',
      budget: const Duration(seconds: 1),
    );
    expectEqual(adapter.vendor, 'openlist', 'vendor 标识');
    expectTrue(adapter.capabilities.nativeSearch, 'OpenList 有服务端原生搜索');
  });
}

/// 结果行的 `openTarget`：**点了必须真能到**。
///
/// 2026-10-24 用 AOT 二进制打真机时看见结果行带着
/// `smb://openlist.example.invalid/A0002/…`，而 OpenList 主机只讲 HTTP、
/// `/A0002` 也不是 SMB 共享 —— 用户双击只会收到「连接服务器时出现问题」。
///
/// 现在 OpenList 改发**网页地址**（OL-OPEN）。三条用例必须一起看：
/// 只测「WebDAV 仍发 SMB」会漏掉「网页编码错」；只测「OpenList 发网页」
/// 会漏掉「SMB 那条路被顺手改坏」。
Future<void> openTargetTests() async {
  // ignore: avoid_print
  print('\n  openTarget（点开结果去哪）');

  const smbHost = 'openlist.example.invalid';
  final dir = const FileItem(
    name: '体系审核',
    path: '/A0002/体系审核',
    isDirectory: true,
    size: 0,
    sizeKnown: false,
  );

  await check('★ OpenList 的结果行带网页目标，而不是必然失败的 SMB 地址', () async {
    final session = BrandSession(
      createBrandAdapter('openlist',
          endpoint: 'https://$smbHost', budget: const Duration(seconds: 1)),
      sourceID: 's1',
      // 故意传一个非空的主机名：harness 对所有品牌来源都是这么传的。
      // 若把「不发 SMB」写在 harness 里而不是适配器契约里，这条用例就测不到了。
      smbHost: smbHost,
    );
    final row = session.row(dir, '/A0002');
    final target = row['openTarget'];
    expectTrue(target is Map, 'OpenList 结果行应有 openTarget，实际：$target');
    final map = target as Map;
    expectEqual(map['kind'], 'webLocation', 'openTarget 种类（不该是 smbLocation）');
    expectEqual(map['url'], 'https://$smbHost/A0002/%E4%BD%93%E7%B3%BB%E5%AE%A1%E6%A0%B8',
        '网页地址：中文按 UTF-8 百分号编码，路径不带结尾斜杠');
    // 其余字段不能因为这次改动一起丢
    expectEqual(row['path'], '/A0002/体系审核', '路径');
    expectEqual(row['fileType'], 'folder', '目录类型');
    expectTrue(row['canOpen'] == true, '网页目标应当 canOpen=true（点开就能到）');
  });

  await check('★ 空格 / 字面 % / # / ? 都必须编码，不能靠字符串拼', () async {
    final session = BrandSession(
      createBrandAdapter('openlist',
          endpoint: 'https://$smbHost', budget: const Duration(seconds: 1)),
      sourceID: 's1',
      smbHost: smbHost,
    );
    final ugly = const FileItem(
      name: '报告 100% #1?.pdf',
      path: '/A0002/报告 100% #1?.pdf',
      isDirectory: false,
      size: 10,
      sizeKnown: true,
    );
    final map = session.row(ugly, '/A0002')['openTarget'] as Map;
    // 逐段编码：空格→%20、字面 %→%25、#→%23、?→%3F。
    // 少编一个，浏览器就会把它当成「空格结束」「锚点」「查询串」，
    // 落到错误的路径上——而且不报错，只是「文件不存在」。
    expectEqual(
        map['url'],
        'https://$smbHost/A0002/%E6%8A%A5%E5%91%8A%20100%25%20%231%3F.pdf',
        '特殊字符编码');
  });

  await check('未实现网页接口的后端不会凭空得到网页目标', () async {
    // 威联通没有实现 `WebOpenableAdapter`：它的结果只能走 SMB，
    // 不该因为「会话层新加了网页分支」而多出一个地址。
    final session = BrandSession(
      createBrandAdapter('qnap',
          endpoint: 'https://nas.example.invalid:8080',
          budget: const Duration(seconds: 1)),
      sourceID: 's1',
      smbHost: 'nas.example.invalid',
    );
    final map = session.row(dir, '/A0002')['openTarget'] as Map;
    expectEqual(map['kind'], 'smbLocation', '威联通仍走 SMB（没有被网页目标顶掉）');
  });

  await check('WebDAV 的结果行照旧带 openTarget（SMB 是这条路的正常出口）', () async {
    final session = BrandSession(
      createBrandAdapter('webdav',
          endpoint: 'https://nas.example.invalid:5005/dav',
          budget: const Duration(seconds: 1)),
      sourceID: 's1',
      smbHost: 'nas.example.invalid',
    );
    final row = session.row(dir, '/A0002');
    final target = row['openTarget'];
    expectTrue(target is Map, 'WebDAV 结果行应有 openTarget，实际：$target');
    final map = target as Map;
    expectEqual(map['kind'], 'smbLocation', 'openTarget 种类');
    expectEqual(map['host'], 'nas.example.invalid', 'openTarget 主机');
    expectTrue(row['canOpen'] == false, 'SMB 行的 canOpen 仍是 false（要等挂载核对）');
  });

  await check('适配器自己声明了这条能力，而不是靠品牌名去猜', () async {
    expectTrue(
        !createBrandAdapter('openlist',
                endpoint: 'https://x.invalid', budget: const Duration(seconds: 1))
            .exposesSMBShares,
        'OpenList 必须声明 exposesSMBShares=false');
    expectTrue(
        createBrandAdapter('webdav',
                endpoint: 'https://x.invalid/dav', budget: const Duration(seconds: 1))
            .exposesSMBShares,
        'WebDAV 仍应声明 true');
  });
}
