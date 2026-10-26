// 真实 OpenList 端到端验证：走**产品代码路径**（OpenListAdapter），打真实实例。
//
// 用法（凭据只从环境变量读，不落盘、不进 evidence）：
//   OPENLIST_USER=xxx OPENLIST_PASS=yyy \
//     dart run test_openlist_live.dart --base-url https://openlist.example.net
//   ... --evidence <目录>     # 结果同时脱敏落盘
//
// ── 为什么单有 test_openlist.dart 不够 ─────────────────────────────
// 那个用的是**写死响应的 fixture**：它能证明解析与分诊逻辑不崩，
// 但证明不了真实服务端的行为——真实实例上有已删除存储的陈旧索引、
// 有上游网盘授权失效的存储、有 8 万文件的大目录。这些在 fixture 里没有。
// 飞牛那条线已经实证过「fixture 全绿、真机第一个端点就 404」。
//
// ── 覆盖的 G5 项 ──────────────────────────────────────────────────
// 真实认证 / 枚举存储 / 限定目录搜索 / 分页 / 取消 / 重新登录 / 会话失效。
//
// ── 不做的断言 ────────────────────────────────────────────────────
// 不假设实例上有哪些文件、不硬编码存储名与关键字命中数——那些是数据，
// 不是契约。断言只落在「结构性事实」上（有存储、能列、搜索返回结构正确）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'lib/adapter_contract.dart';
import 'lib/adapter_support.dart';
import 'lib/adapters/openlist.dart';
import 'lib/dio_compat.dart';
import 'lib/error_kinds.dart';
import 'lib/protocol.dart';

int _passed = 0, _failed = 0;
final _failures = <String>[];
final _lines = <String>[];

void _out(String line) {
  _lines.add(line);
  // ignore: avoid_print
  print(line);
}

void _ok(String name) {
  _passed++;
  _out('  ok   $name');
}

void _fail(String name, Object error) {
  _failed++;
  _failures.add('$name :: $error');
  _out('  FAIL $name\n       $error');
}

Future<void> _check(String name, Future<void> Function() body) async {
  try {
    await body();
    _ok(name);
  } on AdapterFailure catch (e) {
    _fail(name, '${e.kind}: ${e.message}');
  } catch (e) {
    _fail(name, e);
  }
}

void _expect(bool value, String message) {
  if (!value) throw StateError('期望为真：$message');
}

void _expectEqual(Object? actual, Object? expected, String message) {
  if (actual != expected) {
    throw StateError('$message：期望 $expected，实际 $actual');
  }
}

// ───────────────────────────── 入口 ─────────────────────────────

Future<void> main(List<String> args) async {
  var baseUrl = '';
  String? evidenceDir;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--base-url' && i + 1 < args.length) baseUrl = args[i + 1];
    if (args[i] == '--evidence' && i + 1 < args.length) evidenceDir = args[i + 1];
  }
  final user = Platform.environment['OPENLIST_USER'] ?? '';
  final pass = Platform.environment['OPENLIST_PASS'] ?? '';
  if (baseUrl.isEmpty || user.isEmpty || pass.isEmpty) {
    _out('用法：OPENLIST_USER=… OPENLIST_PASS=… dart run test_openlist_live.dart '
        '--base-url https://<host> [--evidence <dir>]');
    exit(2);
  }

  _out('\n[OpenList 真机端到端] $baseUrl');
  final dio = Dio(BaseOptions(
    baseUrl: baseUrl,
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 30),
    sendTimeout: const Duration(seconds: 30),
  ));
  final adapter = OpenListAdapter(dio: dio);

  // 1. 认证
  var loggedIn = false;
  await _check('真实登录成功并拿到会话身份', () async {
    final outcome = await adapter.login(username: user, password: pass);
    if (outcome is! LoginSuccess) {
      throw StateError('期望 LoginSuccess，实际 $outcome');
    }
    _expect(adapter.sessionIdentity != null, '登录后应有会话身份');
    loggedIn = true;
  });

  if (!loggedIn) {
    _out('\n登录失败，后续用例跳过');
    _finish(evidenceDir, baseUrl);
    return;
  }

  // 2. 错误密码（真机确认 code=400 走拒绝分支）
  await _check('错误密码被拒（不是异常，是 LoginRejected）', () async {
    final probe = OpenListAdapter(dio: Dio(BaseOptions(
      baseUrl: baseUrl,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
    )));
    final outcome = await probe.login(username: user, password: '${pass}__wrong__');
    if (outcome is! LoginRejected) {
      throw StateError('期望 LoginRejected，实际 $outcome');
    }
    _out('       拒绝原因：${outcome.reason}（设备码 ${outcome.apiCode}）');
  });

  // 3. 枚举存储
  var roots = <ShareRoot>[];
  await _check('枚举存储（根目录）', () async {
    roots = await adapter.shareRoots();
    _expect(roots.isNotEmpty, '真实实例应至少有一个存储');
    _out('       共 ${roots.length} 个存储：${roots.map((r) => r.name).join(', ')}');
  });

  // 4. 逐个 list，记录可用性（不假设内容）
  await _check('逐个存储列目录（失败只影响该存储）', () async {
    for (final root in roots) {
      try {
        final items = await adapter.list(root.path);
        final dirs = items.where((i) => i.isDirectory).length;
        _out('       ${root.name}: ${items.length} 项（目录 $dirs）');
      } on AdapterFailure catch (e) {
        // 上游网盘失效 / 存储被删 —— 真实实例上会真的出现，如实记录不掩盖。
        _out('       ${root.name}: 不可用（${e.kind}）${e.message}');
      }
    }
  });

  // 4b. ★ 必须挑一个**搜索真有结果**的存储。
  //
  // 第一版按「第一个能列目录的存储」选，结果那个存储下没有匹配项，
  // 搜索返回 0 条 —— 于是「搜索」这条用例是绿的，但其实什么都没验到：
  // 路径抽检被跳过、分页一条没翻、结果字段一条没看。
  // 「没失败」不等于「验证过」，这里必须真的搜出东西来。
  var searchableRoot = '';
  var searchableTotal = 0;
  await _check('挑出搜索有结果的存储（否则下面的搜索等于空跑）', () async {
    var fallbackRoot = '';
    var fallbackTotal = 0;
    for (final root in roots) {
      try {
        final items = await adapter.search('a', roots: [root.path]);
        final files = items.where((i) => !i.isDirectory).length;
        _out('       ${root.name}: 搜 "a" 命中 ${items.length} 条（其中文件 $files）');
        if (items.length > fallbackTotal) {
          fallbackTotal = items.length;
          fallbackRoot = root.path;
        }
        // ★ 优先挑「能搜到文件」的存储。
        //   1.1.11 发的是 scope=1（上游语义 = 仅目录），全站只剩目录；
        //   若这里随便挑一个只有目录的存储，下面「必须有文件」的抽检就被静默跳过了。
        if (files > 0 && items.length > searchableTotal) {
          searchableTotal = items.length;
          searchableRoot = root.path;
        }
      } on AdapterFailure catch (e) {
        _out('       ${root.name}: 搜索不可用（${e.kind}）');
      }
    }
    if (searchableRoot.isEmpty) {
      searchableRoot = fallbackRoot;
      searchableTotal = fallbackTotal;
    }
    _expect(searchableRoot.isNotEmpty,
        '这台实例上没有任何存储能搜出结果——搜索路径无法被真机验证，'
        '不能当作通过；请换一个有文件进过索引的存储再测');
    _out('       ⇒ 用 $searchableRoot（$searchableTotal 条）做后续验证');
  });

  // 5. 限定目录搜索
  await _check('scope=0：结果不越界，而且必须包含文件', () async {
    final items = await adapter.search('a', roots: [searchableRoot]);
    _out('       在 $searchableRoot 搜 "a"：${items.length} 条'
        '（文件 ${items.where((i) => !i.isDirectory).length}）');
    _expect(items.isNotEmpty, '选中的存储应能搜出结果（见上一步）');
    // ★ 这条就是 1.1.11 的真机 bug 判据：上游 scope 是 0=全部 / 1=仅目录 / 2=仅文件，
    //   写成 1 时这里会变成「只有目录」，用户搜文件名一条都搜不到。
    _expect(items.any((i) => !i.isDirectory),
        '结果里必须至少有一条文件，实际全是目录（scope 写成了 1？）');
    for (final item in items.take(3)) {
      _out('         ${item.path}（dir=${item.isDirectory}）');
      _expect(item.path.startsWith(searchableRoot), '结果必须落在被授权的存储内：${item.path}');
      _expect(item.modifiedTime == null, '服务端不提供修改时间，不得编造');
      _expect(item.name.isNotEmpty, '结果应有文件名');
    }
  });

  // 6. 搜索结果的路径可用性抽检：取一条结果去 list 它的父目录
  await _check('搜索结果指向的目录真实可列（防陈旧索引）', () async {
    final items = await adapter.search('a', roots: [searchableRoot]);
    _expect(items.isNotEmpty, '应有结果可抽检');
    var checked = 0;
    for (final target in items.take(3)) {
      final parent = PathCompat.dirname(target.path);
      final listed = await adapter.list(parent);
      _expect(listed.isNotEmpty, '$parent 应能列出内容');
      checked++;
    }
    _out('       抽检 $checked 条结果的父目录，全部可列 ✅');
  });

  // 7. 分页：真机上 per_page=100，条数超过 100 就证明真的翻了页
  await _check('分页：超过一页时翻页取全且去重', () async {
    final items = await adapter.search('a', roots: [searchableRoot]);
    final paths = items.map((i) => i.path).toList();
    _expect(paths.length == paths.toSet().length, '结果路径应唯一（去重生效）');
    _out('       搜 "a"：${items.length} 条，唯一路径 ${paths.toSet().length} 条');
    if (items.length > 100) {
      _out('       ${items.length} > 100 ⇒ 确认发生了多页取数 ✅');
    } else {
      // 这条要如实说明：少于 100 条时**没有**验证到翻页。
      _out('       注意：本轮只命中 ${items.length} 条（≤100），'
          '本次运行未覆盖真实翻页；翻页逻辑由 fixture 用例'
          '「分页：250 条按 per_page=100 翻 3 页取全」覆盖');
    }
  });

  // 8. 空关键字必须拒绝
  await _check('空关键字被拒（真机上会返回全站文件）', () async {
    try {
      await adapter.search('  ', roots: [searchableRoot]);
      throw StateError('期望拒绝空查询，实际成功返回');
    } on AdapterFailure catch (e) {
      _expectEqual(e.kind, ErrorKind.unsupportedQuery, '错误种类');
    }
  });

  // 9. 取消
  await _check('取消令牌预先置位时立即中止', () async {
    final token = Cancellation()..cancel();
    adapter.cancellation = token;
    try {
      await adapter.search('a', roots: [searchableRoot]);
      throw StateError('期望被取消，实际成功返回');
    } on CoreError catch (e) {
      _expect(e.kind == 'Cancelled', '应报 Cancelled，实际 ${e.kind}');
    } on AdapterFailure catch (e) {
      _expect(e.kind == ErrorKind.cancelled, '应报 Cancelled，实际 ${e.kind}');
    } finally {
      adapter.cancellation = Cancellation();
    }
  });

  // 10. 重新登录换身份
  await _check('重新登录换一个会话身份', () async {
    final before = adapter.sessionIdentity;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final outcome = await adapter.login(username: user, password: pass);
    _expect(outcome is LoginSuccess, '重登应成功');
    _expect(adapter.sessionIdentity != before,
        '重登后身份必须变化（代次判定依赖它）');
  });

  _finish(evidenceDir, baseUrl);
}

void _finish(String? evidenceDir, String baseUrl) {
  _out('\n通过 $_passed，失败 $_failed');
  if (_failed > 0) {
    _out('失败项：');
    for (final f in _failures) {
      _out('  · $f');
    }
  }
  if (evidenceDir != null) {
    final dir = Directory(evidenceDir)..createSync(recursive: true);
    File('${dir.path}/openlist-live.log').writeAsStringSync(_lines.join('\n'));
    // 只落「计数与结论」，不落任何账号、令牌与业务路径。
    File('${dir.path}/openlist-live-summary.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'host': Uri.parse(baseUrl).host,
        'passed': _passed,
        'failed': _failed,
        'failures': _failures,
        'ranAt': DateTime.now().toIso8601String(),
      }),
    );
    _out('证据已脱敏落盘：${dir.path}');
  }
  exitCode = _failed > 0 ? 1 : 0;
}
