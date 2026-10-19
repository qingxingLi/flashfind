import 'dart:async';

import 'protocol.dart';
import 'synology_api.dart';

/// 一次回收的结果。
///
/// 保留「每一类各有几条」而不是只留一个总数：
/// 「设备说任务不存在」和「我们没清理掉」是两回事，
/// 前者是好事（任务确实没了），后者才是要报警的泄漏。
class DrainReport {
  int attempted = 0, cleaned = 0, notFound = 0, abandoned = 0, gaveUp = 0, failed = 0;

  int get resolved => cleaned + notFound + abandoned + gaveUp;

  /// 仍然留在队列里的条数 —— 这是要盯的数字。
  int get remaining => failed;

  bool get isEmpty => attempted == 0;

  Map<String, Object?> toJson() => {
        'attempted': attempted,
        'cleaned': cleaned,
        'notFound': notFound,
        'abandoned': abandoned,
        'gaveUp': gaveUp,
        'remaining': remaining,
      };

  @override
  String toString() =>
      'DrainReport(attempted=$attempted cleaned=$cleaned notFound=$notFound '
      'abandoned=$abandoned gaveUp=$gaveUp remaining=$remaining)';
}

/// 队列里的一条：任务号 + 它**属于哪个会话** + 已试次数。
///
/// 记会话是必需的，不是冗余：DSM 的 taskid 绑定登录会话，
/// 会话换了之后这个号既不可控、也不该再拿新会话去撞它。
/// 没有这份归属信息，「该放弃」和「再试一次」就分不开。
class _Entry {
  final int epoch;
  final String? account;
  int attempts;
  _Entry(this.epoch, this.account) : attempts = 0;
}

/// DSM 搜索任务的**回收队列**。
///
/// ## 为什么必须有它
///
/// `Search.clean` 会失败：设备忙、超时、会话刚好过期都可能导致它不成功。
/// 旧实现把它塞进一个 `List<String> pending` 之后就**再也没人看过**——
/// 那条队列只进不出。于是每失败一次，设备上就多留一个 DSM Search Task。
/// 用户看到的现象正是「File Station 一直正常，闪寻搜几次之后就搜不到了」：
/// 不是索引坏了，是我们自己把设备的搜索资源占住了。
///
/// ## 三条纪律
///
/// 1. **TaskNotFound 等于清理成功**。设备说「没这个任务」，
///    说明它已经不在了，这正是我们想要的结果，不是失败。
/// 2. **队列必须有上限，条目必须有重试上限**。
///    否则一次长时间的设备异常会把队列撑成无界增长，
///    而每次 drain 又会去打一堆注定失败的请求——把设备推进更深的退化窗口。
/// 3. **每次结果都要可见**。`onOutcome` 提供给调用方去记诊断，
///    「清掉了 / 设备说没有 / 放弃了」必须分得开，不能合成一个「完成」。
class PendingTaskManager {
  final SynologyApi api;

  /// 单次 drain 的总体预算。所有条目共享，不是每条一个。
  ///
  /// 与 `BrandSession` 那条教训同源：给每个循环各配一份预算，
  /// 实际耗时就是「条目数 × 预算」。总预算一处封顶。
  final Duration budget;

  /// 队列最多留多少个任务号。超出时丢**最老的**。
  ///
  /// 丢老的而不是拒绝新的：老任务已经过了多次重试还没清掉，
  /// 而新任务是刚刚确认清不掉的，它更有可能在下一次 drain 时成功。
  final int maxRetained;

  /// 单个任务号最多重试几次。超过就放弃并从队列移除。
  final int maxAttempts;

  /// 单次 drain 最多处理几条。控制一次搜索前的额外延迟。
  final int maxPerDrain;

  /// 回收结果回调（`outcome` ∈ cleaned / notFound / abandoned / gaveUp / retrying / evicted）。
  final void Function(String taskID, String outcome, int attempts)? onOutcome;

  PendingTaskManager(this.api,
      {this.budget = const Duration(seconds: 3),
      this.maxRetained = 32,
      this.maxAttempts = 3,
      this.maxPerDrain = 4,
      this.onOutcome});

  final Map<String, _Entry> _entries = <String, _Entry>{};
  final List<String> _order = <String>[];

  int get count => _entries.length;
  bool get isEmpty => _entries.isEmpty;

  /// 当前队列里的任务号快照（诊断与测试用）。
  List<String> get taskIDs => List.unmodifiable(_order);

  /// 登记一个没能清掉的任务号。
  ///
  /// `epoch` / `account` 是这个任务所属的会话，用于后续判断该不该放弃。
  void add(String taskID, {required int epoch, required String? account}) {
    if (taskID.isEmpty) return;
    if (_entries.containsKey(taskID)) return;
    _order.add(taskID);
    _entries[taskID] = _Entry(epoch, account);
    while (_order.length > maxRetained) {
      final dropped = _order.removeAt(0);
      final entry = _entries.remove(dropped);
      onOutcome?.call(dropped, 'evicted', entry?.attempts ?? 0);
    }
  }

  void _remove(String taskID) {
    _order.remove(taskID);
    _entries.remove(taskID);
  }

  /// 尝试回收队列里的任务。
  ///
  /// 任务所属的会话与**当前**会话不一致时直接放弃：
  /// 换了会话之后这个 taskid 既不可控，继续拿新会话去撞它也只是给设备添乱。
  /// 放弃也要如实报出来——它是「我们知道有东西没清掉」的证据。
  Future<DrainReport> drain() async {
    final report = DrainReport();
    if (_order.isEmpty) return report;

    final token = Cancellation();
    final timer = Timer(budget, () => token.cancel('TimedOut'));
    try {
      // 快照：drain 过程中会改队列，不能一边遍历一边删。
      final targets = _order.take(maxPerDrain).toList();
      for (final taskID in targets) {
        if (token.cancelled) break;
        report.attempted++;
        final entry = _entries[taskID];
        if (entry == null) continue;

        if (entry.epoch != api.sessionEpoch ||
            entry.account != api.accountIdentity) {
          report.abandoned++;
          _remove(taskID);
          onOutcome?.call(taskID, 'abandoned', entry.attempts);
          continue;
        }

        final stop = await _control(taskID, 'stop', token);
        if (stop == ControlResult.notFound) {
          report.notFound++;
          _remove(taskID);
          onOutcome?.call(taskID, 'notFound', entry.attempts);
          continue;
        }
        final clean = await _control(taskID, 'clean', token);
        if (clean == ControlResult.notFound) {
          report.notFound++;
          _remove(taskID);
          onOutcome?.call(taskID, 'notFound', entry.attempts);
          continue;
        }
        if (stop == ControlResult.ok && clean == ControlResult.ok) {
          report.cleaned++;
          _remove(taskID);
          onOutcome?.call(taskID, 'cleaned', entry.attempts);
          continue;
        }

        // 还没清掉。试够了就放弃，否则留着下次再来。
        final attempts = entry.attempts + 1;
        if (attempts >= maxAttempts) {
          report.gaveUp++;
          _remove(taskID);
          onOutcome?.call(taskID, 'gaveUp', attempts);
        } else {
          report.failed++;
          entry.attempts = attempts;
          onOutcome?.call(taskID, 'retrying', attempts);
        }
      }
    } finally {
      timer.cancel();
    }
    return report;
  }

  Future<ControlResult> _control(
      String taskID, String method, Cancellation token) async {
    try {
      await api.taskControl(taskID, method, token);
      return ControlResult.ok;
    } on CoreError catch (e) {
      // 设备说「没这个任务」＝ 任务已经不在了 ＝ 清理的目标已达成。
      if (e.kind == 'TaskNotFound') return ControlResult.notFound;
      return ControlResult.failed;
    } catch (_) {
      return ControlResult.failed;
    }
  }
}

enum ControlResult { ok, notFound, failed }
