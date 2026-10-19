// DSM Search Task 回收队列的回归测试 —— 全部在本机用脚本化传输层跑。
//
// ── 为什么专门要有这个文件 ─────────────────────────────────────────
// 旧实现里 `SynologyCore.pending` 是一个只 `add`、从不消费的 `List<String>`。
// `Search.clean` 失败一次，设备上就永久多一个 DSM Search Task。
// 用户侧的现象是「File Station 一直正常，闪寻搜几次之后就搜不到了」——
// 不是索引坏了，是我们自己占住了设备的搜索资源。
//
// 这类泄漏**不可能靠单次搜索测试发现**：它要累积才发作，
// 而每次单独看都是「这次 clean 失败了，已记入 pending」这种看起来很正常的输出。
// 所以这里测的是**队列本身的进出**，而不是某一次搜索的结果。
//
// 运行：dart run test_pending_tasks.dart
import 'dart:io';

import 'lib/core.dart';
import 'lib/pending_tasks.dart';
import 'lib/protocol.dart';
import 'lib/synology_api.dart';

// ─────────────────────────── 脚本化传输层 ───────────────────────────

class ScriptedTransport implements Transport {
  final Map<String, List<Map<String, dynamic>>> script;
  final List<WireRequest> calls = [];
  /// `clean` 前 N 次调用一律失败，之后按 script 走。
  ///
  /// 用「前 N 次」而不是排队 N 条错误响应：核心的 `control()` 每次最多两试，
  /// 真实调用次数取决于失败发生在第几试，硬排队数极易对不上。
  /// 按次数表达意图才稳。
  int cleanFailures;
  ScriptedTransport(this.script, {this.cleanFailures = 0});

  @override
  Future<Map<String, dynamic>> send(WireRequest request, Cancellation cancellation) async {
    cancellation.check();
    calls.add(request);
    if (request.method == 'clean' && cleanFailures > 0) {
      cleanFailures--;
      return _error(100);
    }
    final key = '${request.api}/${request.method}';
    final queue = script[key];
    if (queue == null || queue.isEmpty) {
      throw CoreError('UnexpectedCall', api: request.api, method: request.method);
    }
    return queue.length == 1 ? queue.first : queue.removeAt(0);
  }

  int countOf(String method) =>
      calls.where((c) => c.method == method).length;
}

Map<String, dynamic> _descriptors() => {
      'success': true,
      'data': {
        'SYNO.API.Auth': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 7},
        'SYNO.FileStation.Info': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 2, 'requestFormat': 'JSON'},
        'SYNO.FileStation.List': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 2, 'requestFormat': 'JSON'},
        'SYNO.FileStation.Search': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 2, 'requestFormat': 'JSON'},
        'SYNO.FileStation.Download': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 2, 'requestFormat': 'JSON'},
      }
    };

Map<String, dynamic> _data(Map<String, dynamic> data) => {'success': true, 'data': data};

/// DSM 错误响应。`599` 是「任务不存在」，`100` 用来造一个普通失败。
Map<String, dynamic> _error(int code) => {
      'success': false,
      'error': {'code': code}
    };

// ─────────────────────────── 夹具 ───────────────────────────

Future<(SynologyCore, ScriptedTransport)> _connected(
    List<Map<String, dynamic>> cleanQueue, {int cleanFailures = 0}) async {
  final transport = ScriptedTransport({
    'SYNO.API.Info/query': [_descriptors()],
    'SYNO.API.Auth/login': [_data({'sid': 'SID-1', 'synotoken': 'TOKEN-1'})],
    'SYNO.API.Auth/logout': [_data(<String, dynamic>{})],
    'SYNO.FileStation.Info/get': [_data({'is_manager': false})],
    'SYNO.FileStation.List/list_share': [
      _data({
        'total': 1,
        'offset': 0,
        'shares': [
          {'path': '/share', 'name': 'share'}
        ],
      })
    ],
    'SYNO.FileStation.Search/start': [_data({'taskid': 'TASK-1'})],
    // total=0：搜索**正常走完**（不会落到分页循环里），
    // 于是 `out.complete == true` ⇒ 收尾不调 stop，只调 clean。
    // 这样脚本里 clean 的调用次数才是可数的。
    'SYNO.FileStation.Search/list': [
      _data({'total': 0, 'offset': 0, 'finished': true, 'files': []})
    ],
    'SYNO.FileStation.Search/stop': [_data(<String, dynamic>{})],
    'SYNO.FileStation.Search/clean': cleanQueue,
  }, cleanFailures: cleanFailures);
  final api = SynologyApi(transport, 'src-1', requestBudget: const Duration(seconds: 5));
  final token = Cancellation();
  await api.discover(token);
  await api.login('u', 'p', token);
  await api.authorize(token);
  final core = SynologyCore(api, null,
      sourceName: '测试 NAS',
      pollInterval: const Duration(milliseconds: 1),
      queryBudget: const Duration(seconds: 10));
  await core.selectScopes(token, ['/share']);
  return (core, transport);
}

// ─────────────────────────── 断言 ───────────────────────────

int _passed = 0, _failed = 0;

Future<void> _check(String title, Future<void> Function() body) async {
  try {
    await body();
    _passed++;
    stdout.writeln('  ✅ $title');
  } catch (error) {
    _failed++;
    stdout.writeln('  ❌ $title');
    stdout.writeln('     $error');
  }
}

void _expect(bool condition, String message) {
  if (!condition) throw StateError(message);
}

// ─────────────────────────── 场景 ───────────────────────────

Future<void> main() async {
  stdout.writeln('\nDSM Search Task 回收队列');

  // ── 验收标准本体：clean 第一次失败、第二次成功 ⇒ pending 归零 ──
  await _check('clean 第一次失败、第二次成功 ⇒ 队列清空', () async {
    final (core, _) = await _connected([_error(100), _data(<String, dynamic>{})]);
    core.pendingTasks.add('T-LEAK', epoch: core.api.sessionEpoch, account: core.api.accountIdentity);
    _expect(core.pendingTasks.count == 1, '入队后应剩 1 条');

    final first = await core.drainPendingTasks();
    _expect(first.failed == 1, '第一次应仍未清掉，实际 ${first.toJson()}');
    _expect(core.pendingTasks.count == 1, '失败后应留在队列里等重试');

    final second = await core.drainPendingTasks();
    _expect(second.cleaned == 1, '第二次应清掉，实际 ${second.toJson()}');
    _expect(core.pendingTasks.count == 0, '★ 队列必须归零，实际 ${core.pendingTasks.count}');
  });

  await _check('设备说「任务不存在」(599) ⇒ 视为清理成功并出队', () async {
    final (core, _) = await _connected([_error(599)]);
    core.pendingTasks.add('T-GONE', epoch: core.api.sessionEpoch, account: core.api.accountIdentity);
    final report = await core.drainPendingTasks();
    _expect(report.notFound == 1, '应记为 notFound，实际 ${report.toJson()}');
    _expect(core.pendingTasks.count == 0, 'notFound 必须出队');
    _expect(report.remaining == 0, 'notFound 不许算成剩余泄漏');
  });

  await _check('队列有上限：超出时淘汰最老的，不是无界增长', () async {
    final (core, _) = await _connected([_error(100)]);
    final manager = PendingTaskManager(core.api, maxRetained: 2);
    for (final id in ['T1', 'T2', 'T3']) {
      manager.add(id, epoch: core.api.sessionEpoch, account: core.api.accountIdentity);
    }
    _expect(manager.count == 2, '上限 2，实际 ${manager.count}');
    _expect(manager.taskIDs.join(',') == 'T2,T3', '应淘汰最老的 T1，实际 ${manager.taskIDs}');
  });

  await _check('同一任务号重复登记不产生两条', () async {
    final (core, _) = await _connected([_error(100)]);
    final manager = PendingTaskManager(core.api);
    manager.add('T-DUP', epoch: core.api.sessionEpoch, account: core.api.accountIdentity);
    manager.add('T-DUP', epoch: core.api.sessionEpoch, account: core.api.accountIdentity);
    _expect(manager.count == 1, '重复登记应幂等，实际 ${manager.count}');
  });

  await _check('重试有上限：连续失败到上限后放弃出队，不无限堆积', () async {
    final (core, _) = await _connected([_error(100)]);
    final manager = PendingTaskManager(core.api, maxAttempts: 2);
    manager.add('T-STUCK', epoch: core.api.sessionEpoch, account: core.api.accountIdentity);

    final first = await manager.drain();
    _expect(first.failed == 1, '第一次应记为仍在重试，实际 ${first.toJson()}');
    final second = await manager.drain();
    _expect(second.gaveUp == 1, '到上限应放弃，实际 ${second.toJson()}');
    _expect(manager.count == 0, '放弃后必须出队，否则每次都白打一次设备');
  });

  await _check('会话已换 ⇒ 放弃，且如实记为 abandoned 而不是「清掉了」', () async {
    final (core, _) = await _connected([_data(<String, dynamic>{})]);
    final stale = core.api.sessionEpoch;
    core.pendingTasks.add('T-OLD', epoch: stale, account: core.api.accountIdentity);
    // 重新登录 ⇒ sessionEpoch 递增，旧任务号已不可控。
    final token = Cancellation();
    await core.api.login('u', 'p', token);
    _expect(core.api.sessionEpoch != stale, '重登后 epoch 必须变化');

    final report = await core.drainPendingTasks();
    _expect(report.abandoned == 1, '应记为 abandoned，实际 ${report.toJson()}');
    _expect(report.cleaned == 0, '★ 不许把「放弃了」记成「清掉了」');
    _expect(core.pendingTasks.count == 0, '放弃后出队');
  });

  await _check('单次 drain 受 maxPerDrain 限制，不会一次打一堆请求', () async {
    final (core, transport) = await _connected([_error(100)]);
    final manager = PendingTaskManager(core.api, maxPerDrain: 2, maxAttempts: 99);
    for (final id in ['T1', 'T2', 'T3', 'T4']) {
      manager.add(id, epoch: core.api.sessionEpoch, account: core.api.accountIdentity);
    }
    final before = transport.countOf('clean');
    final report = await manager.drain();
    _expect(report.attempted == 2, '一次最多处理 2 条，实际 ${report.attempted}');
    _expect(transport.countOf('clean') - before == 2, '设备侧也只应被打 2 次 clean');
    _expect(manager.count == 4, '未处理的仍留在队列');
  });

  // ── 端到端：搜索里 clean 失败 ⇒ 入队；下一次搜索 start 之前先回收 ──
  await _check('端到端：搜索收尾 clean 失败 ⇒ 下一次搜索开始前自动回收', () async {
    // clean 的脚本按**调用次序**展开（核心的 `control()` 每次最多两试）：
    //   搜索1 收尾        : 失败、失败  ⇒ 入队
    //   搜索1 结束再收一次: 失败、失败  ⇒ attempts=1，留在队列
    //   搜索2 开始前回收  : 成功        ⇒ 出队 ★ 这一条是本次要证明的
    //   搜索2 收尾        : 成功
    // clean 前 3 次失败、第 4 次起成功。调用次序：
    //   搜索1 收尾（两试，都失败）→ 入队
    //   搜索1 结束再收一次（第 3 次，失败）→ attempts=1，留在队列
    //   搜索2 开始前回收（第 4 次，成功）→ ★ 出队，这就是要证明的
    final (core, transport) =
        await _connected([_data(<String, dynamic>{})], cleanFailures: 3);

    final first = await core.search('报告', 'Q1');
    _expect(first.cleanup == 'pending', '第一次 clean 应失败，实际 ${first.cleanup}');
    _expect(core.pendingTasks.count == 1, '失败后应入队，实际 ${core.pendingTasks.count}');

    final cleanBefore = transport.countOf('clean');
    final second = await core.search('报告', 'Q2');
    _expect(core.pendingTasks.count == 0, '★ 第二次搜索后队列必须归零，实际 ${core.pendingTasks.count}');
    _expect(second.pendingBefore != null, '回收结果应出现在结果里供诊断');
    _expect(second.pendingBefore!.cleaned == 1,
        '应真的清掉了 1 条，实际 ${second.pendingBefore!.toJson()}');
    _expect(transport.countOf('clean') > cleanBefore, '设备侧必须真的收到了 clean');
  });

  await _check('无遗留任务时 drain 是空操作，不给搜索加额外往返', () async {
    final (core, transport) = await _connected([_data(<String, dynamic>{})]);
    final before = transport.countOf('stop');
    await core.drainPendingTasks();
    _expect(transport.countOf('stop') == before, '空队列不该产生任何请求');
  });

  stdout.writeln('\n通过 $_passed 项，失败 $_failed 项');
  if (_failed > 0) exitCode = 1;
}
