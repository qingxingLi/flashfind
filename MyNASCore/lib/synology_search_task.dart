import 'dart:async';
import 'protocol.dart';
import 'pending_tasks.dart';
import 'synology_api.dart';

/// DSM 搜索任务的**生命周期管理**（P2-03）。
///
/// `start` 之后的 `stop` / `clean`，以及「clean 失败留下的孤儿任务怎么回收」，
/// 全部集中在这里。`SynologyCore` 只管搜索流程本身（判就绪、分页、发布结果），
/// 不再夹带任务清理的细节。
///
/// 为什么值得单独抽出来：任务生命周期的错误不会立刻表现为故障——
/// 一次 clean 失败只是设备上多一个任务，要攒够几十次才变成
/// 「File Station 正常、闪寻搜不到」。这类「累积才发作」的逻辑
/// 混在搜索主流程里，几乎不可能被单独验证；独立之后它有自己一套测试。
class SynologySearchTaskManager {
  final SynologyApi api;
  /// 一次收尾（stop + clean）的总预算。
  ///
  /// 注意是**整次收尾共享**，不是每个 stop / clean 各一份：
  /// 否则设备卡住时，一次搜索能把预算翻好几倍地耗掉。
  final Duration cleanupBudget;
  final PendingTaskManager pending;

  SynologySearchTaskManager(this.api,
      {this.cleanupBudget = const Duration(seconds: 5), PendingTaskManager? pending})
      : pending = pending ?? PendingTaskManager(api, budget: cleanupBudget);

  /// 结束一次搜索在设备上留下的任务：先 `stop` 再 `clean`。
  ///
  /// 返回 `'cleaned'` / `'pending'`。后者意味着**任务留在了设备上**，
  /// 已入队等待下次回收 —— 调用方必须把这个结果如实往外传，
  /// 不能当成成功（详见 `PendingTaskManager` 的说明）。
  ///
  /// - `stop`：只在搜索没有正常跑完时才需要（跑完了设备自己会收）。
  /// - 会话已经换掉的条目直接放弃：`taskid` 绑定会话，换了就再也管不着，
  ///   硬清只会得到一堆 `TaskNotFound`。
  Future<String> finish({
    required String task,
    required int epoch,
    required String? account,
    required bool stop,
    required List<String> cleanupErrors,
  }) async {
    if (epoch != api.sessionEpoch || account != api.accountIdentity) {
      pending.add(task, epoch: epoch, account: account);
      return 'pending';
    }
    final token = Cancellation();
    final timer = Timer(cleanupBudget, () => token.cancel('TimedOut'));
    bool cleanSucceeded = false;
    try {
      if (stop) await _control(task, 'stop', token, cleanupErrors);
      cleanSucceeded = await _control(task, 'clean', token, cleanupErrors);
    } finally {
      timer.cancel();
    }
    if (!cleanSucceeded) pending.add(task, epoch: epoch, account: account);
    return cleanSucceeded ? 'cleaned' : 'pending';
  }

  /// 对设备上的任务下发控制指令。最多两试。
  ///
  /// `TaskNotFound` / `SessionExpired` / 已取消这三类**不再重试**：
  /// 重试一个「设备说没有这个任务」的请求没有意义，只会拖到预算耗尽。
  Future<bool> _control(String task, String method, Cancellation token,
      List<String> cleanupErrors) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        token.check();
        final requestToken = Cancellation();
        void abort() => requestToken.cancel(token.reason);
        token.listeners.add(abort);
        // 单次请求的预算是总预算的四分之一：整次收尾最多两三个请求，
        // 不能让第一个请求就把全部预算吃掉。
        final requestTimer = Timer(
            Duration(
                microseconds:
                    (cleanupBudget.inMicroseconds ~/ 4).clamp(1000, 1000000)),
            () => requestToken.cancel('TimedOut'));
        try {
          await api.taskControl(task, method, requestToken);
          return true;
        } finally {
          requestTimer.cancel();
          token.listeners.remove(abort);
        }
      } on CoreError catch (e) {
        cleanupErrors.add('$method:${e.kind}');
        if (e.kind == 'TaskNotFound' ||
            e.kind == 'SessionExpired' ||
            token.cancelled) {
          break;
        }
        if (attempt == 0) {
          try {
            await token.delay(const Duration(milliseconds: 1));
          } on CoreError {
            break;
          }
        }
      }
    }
    return false;
  }

  /// 回收此前没清掉的任务。会话变了就放弃（条数如实出现在 `abandoned` 里）。
  Future<DrainReport> drain() => pending.drain();
}
