// 品牌会话：把 `NasBrandAdapter` 接到 harness 的事件契约上。
//
// ── 为什么要有这一层 ─────────────────────────────────────────────
// `SynologyCore` 是为**群晖的异步任务模型**量身写的：startSearch 拿 taskid →
// 轮询 finished → 分页拉结果 → stop/clean 清理任务。这套流程是 DSM 特有的。
//
// qnap / ugreen / fnos / webdav 都是**同步返回列表**的模型，没有任务、没有清理、
// 没有轮询。硬把它们的返回塞进 `SynologyCore` 只会污染一条已经真机验证过的路径。
// 所以这里另起一层，但**产出的结果行与事件必须与群晖逐字段同形** ——
// Swift 侧不该知道也不用知道底下是哪个品牌。
//
// 结果行形状（与 SynologyCore.result 对齐，Swift 侧按这个解析）：
//   id / name / path / fileType / size / modifiedDate /
//   sourceID / sourceName / sourceType='nas' / isOnline / canOpen / openTarget?
import 'dart:async';

import 'adapter_contract.dart';
import 'adapter_support.dart';
import 'core.dart' show SearchOutcome;
import 'open_target.dart';
import 'error_kinds.dart';
import 'protocol.dart';
import 'upstream_file_types.dart' show FileItem, FileType;

/// 一次品牌搜索的运行态。用来丢弃过期结果。
class _Run {
  final String queryID;
  final int epoch;
  final Cancellation token = Cancellation();
  _Run(this.queryID, this.epoch);
}

class BrandSession {
  final NasBrandAdapter adapter;
  final String sourceID;

  /// 结果里对外展示的来源名（产品端给定）。
  final String sourceName;

  /// 结果 openTarget 使用的 SMB 主机名，来自用户填写的 NAS 地址。
  final String smbHost;

  final Duration queryBudget;
  final int maxResults;
  final void Function(String queryID, String event, Map<String, Object?> data)
  emit;

  Scope? _scope;
  int _epoch = 0;
  _Run? _active;

  BrandSession(
    this.adapter, {
    required this.sourceID,
    this.sourceName = 'NAS',
    this.smbHost = '',
    this.queryBudget = const Duration(seconds: 30),
    this.maxResults = 2000,
    void Function(String, String, Map<String, Object?>)? emit,
  }) : emit = emit ?? ((_, __, ___) {});

  /// 当前搜索范围根。未选定共享时为 null——此时不允许发起任何搜索。
  Scope get scope {
    final s = _scope;
    if (s == null) throw const CoreError('ScopeUnset');
    return s;
  }

  bool get hasScope => _scope != null;

  /// 已登录且已选定范围。
  bool get scopeReady => _scope != null && adapter.sessionIdentity != null;

  bool get isAuthenticated => adapter.sessionIdentity != null;

  /// 品牌自报的能力。**诚实性由适配器负责**：未在真机验证的能力必须是 false。
  Map<String, Object?> capabilities() => {
    'nativeSearch': adapter.capabilities.nativeSearch,
    'mode': 'live',
    'mockOnly': false,
    'querySemantics': adapter.capabilities.querySemantics,
    'canOpen': false,
    // 与群晖路径保持同名键：Swift 侧不必为品牌单独分支。
    'trustMode': 'system',
    'verifiedOnDevice': adapter.capabilities.verifiedOnDevice,
    'notes': adapter.capabilities.notes,
  };

  Future<void> login(String account, String password, String? otp) async {
    cancel();
    await adapter.logout();
    _epoch++;
    // ★ 给「整个登录过程」一个总预算。
    //
    // 为什么需要：穷举式适配器会按顺序试多个候选端点，而每个端点各吃一次
    // 请求超时 —— 于是总耗时 = 预算 × 端点个数。实测（预算 2 秒）：
    //   qnap 1 个端点 2004ms / webdav 1 个 2003ms
    //   ugreen 2 个端点 4007ms / fnos 4 个端点 8011ms
    // 换到产品默认的 30 秒预算，fnos 在不可达设备上要**等两分钟**才报错。
    // 这里用取消令牌兜住：预算一到，令牌触发，后续端点的请求立刻失败退出。
    final token = Cancellation();
    adapter.cancellation = token;
    final timer = Timer(queryBudget, () => token.cancel('TimedOut'));
    try {
      final outcome = await adapter.login(
        username: account,
        password: password,
        otpCode: otp,
      );
      switch (outcome) {
        case LoginSuccess():
          break;
        case LoginNeedsOTP(:final methods):
          throw AdapterFailure(
            ErrorKind.needsOTP,
            '该账号需要动态验证码${methods.isEmpty ? '' : '（${methods.join('/')}）'}',
          );
        case LoginRejected(:final reason, :final apiCode):
          throw AdapterFailure(ErrorKind.authenticationFailed, reason, apiCode: apiCode);
      }
    } on CoreError catch (e) {
      // 取消令牌抛出的是 CoreError；总预算耗尽要报成「超时」而不是「失败」，
      // 否则用户会以为是密码错了。
      throw AdapterFailure(
        e.kind == ErrorKind.timedOut ? ErrorKind.timedOut : ErrorKind.networkFailure,
        e.kind == 'TimedOut' ? '连接设备超时，请确认地址与网络' : '登录过程中与设备的通信中断',
      );
    } finally {
      timer.cancel();
    }
  }

  /// 共享列表。**不做任何过滤** —— 上游 device 返回几个就报几个。
  /// 「客户端只暴露 1 个」是 scope 的事，不是这里的事；在适配器层过滤会让
  /// 用户和开发者都看不到设备的真实行为（群晖上已经这样误读过一次）。
  Future<List<Map<String, Object?>>> shares() async {
    final roots = await adapter.shareRoots();
    return [
      for (final root in roots)
        {
          'name': root.name,
          'path': root.path,
          'sourceID': sourceID,
          'sourceName': sourceName,
        },
    ];
  }

  /// 切换搜索范围（可多选）。
  Future<void> selectScopes(List<String> roots) async {
    final next = Scope.multi(roots);
    cancel();
    _scope = next;
  }

  void cancel([String? queryID]) {
    final run = _active;
    if (run != null && (queryID == null || run.queryID == queryID)) {
      run.token.cancel();
    }
  }

  Future<void> disconnect() async {
    cancel();
    try {
      await adapter.logout();
    } catch (_) {
      // 登出失败不该阻止用户重新连接。
    }
    _active = null;
    _scope = null;
    _epoch++;
  }

  /// 逻辑路径规范化：去掉尾随 '/'（`/` 自身保留）。
  ///
  /// ── 为什么必须在会话层再做一次 ────────────────────────────────
  /// 带尾随斜杠的路径会被 `Scope.validate` 判成 `UnsafeLogicalPath`
  /// （`split('/').skip(1).any((s) => s.isEmpty)` 正好命中那个空段），
  /// 于是**用户每往下进一层目录，整份列表就会失败**。
  ///
  /// webdav 适配器已就地修过（上游的 PROPFIND 解析器自己拼了尾随斜杠）；
  /// 但 fnos / ugreen 的 path 直接取服务端返回的 `file['path']`，
  /// 而这两家**没有真机验证** —— 真机上返回什么，现在谁也不知道。
  /// 所以在会话层加一道跨品牌的统一防线。
  ///
  /// 这**不是掩盖设备行为**：闪寻的逻辑路径模型本来就不含尾随斜杠
  /// （`Scope.validate` 的定义即如此，`shareRoots()` 也一直这么产出）。
  /// 只做「去尾随斜杠」这一种变换，不改其它任何语义。
  static String normalizeLogicalPath(String path) {
    var v = path;
    while (v.length > 1 && v.endsWith('/')) v = v.substring(0, v.length - 1);
    return v;
  }

  /// 结果行（与 SynologyCore.result 同形）。
  Map<String, Object?> row(FileItem item, String owningRoot) {
    final path = normalizeLogicalPath(item.path);
    final ext = item.extension ??
        (item.name.contains('.') ? item.name.split('.').last : '');
    final relative = path.length > owningRoot.length
        ? path.substring(owningRoot.length)
        : '';
    final segments = relative.split('/').where((s) => s.isNotEmpty).toList();
    final open = smbHost.isEmpty || owningRoot.isEmpty
        ? null
        : SMBLocation(
            smbHost,
            owningRoot.startsWith('/') ? owningRoot.substring(1) : owningRoot,
            segments,
          ).toJson();
    return {
      'id': '$sourceID:$path',
      'name': item.name,
      'path': path,
      'fileType': item.isDirectory
          ? 'folder'
          : FileType.fromExtension(ext).name,
      'size': item.size,
      'modifiedDate': item.modifiedTime?.toIso8601String(),
      'sourceID': sourceID,
      'sourceName': sourceName,
      'sourceType': 'nas',
      'isOnline': true,
      // 打开能力由 Swift 侧按 SMB 挂载可达性判定；这里恒为 false，
      // 与群晖路径一致（那边也是先发结构、后台核对存在性再刷新）。
      'canOpen': false,
      if (open != null) 'openTarget': open,
    };
  }

  Future<List<Map<String, Object?>>> list(
    String path,
    Cancellation token,
  ) async {
    scope.check(path);
    if (!scopeReady) throw const CoreError('NeedsAuth');
    token.check();
    final items = await adapter.list(path);
    token.check();
    final out = <Map<String, Object?>>[];
    for (final item in items) {
      // 用规范化后的逻辑路径做范围判定（见 normalizeLogicalPath 的说明）。
      final logical = normalizeLogicalPath(item.path);
      scope.check(logical);
      if (scope.excludes(logical)) continue;
      final owning = scope.owningRoot(logical);
      if (owning == null) throw const CoreError('ScopeDenied');
      out.add(row(item, owning));
    }
    return out;
  }

  /// 服务端搜索。
  ///
  /// 与群晖路径一样：**设备没有服务端搜索就是失败，不回退全盘遍历**。
  /// 上游好几个品牌都写了客户端 BFS 兜底，那会在大型 NAS 上把设备拖垮 ——
  /// 移植时统一改成抛 `UnsupportedApi`。
  Future<SearchOutcome> search(
    String query,
    String queryID, {
    Duration? budget,
  }) async {
    cancel();
    final out = SearchOutcome();
    if (!scopeReady) {
      out.error = CoreError(hasScope ? 'NeedsAuth' : 'ScopeUnset');
      out.state = 'needsAuth';
      return out;
    }
    if (query.trim().isEmpty) {
      out.state = 'completed';
      out.complete = true;
      out.reportedTotal = 0;
      return out;
    }
    if (!adapter.capabilities.nativeSearch) {
      out.error = const CoreError('UnsupportedSearchNoFallback');
      out.state = 'failed';
      return out;
    }

    // 把本次查询的取消令牌交给适配器：它要在长操作里 check()，
    // 实现「真实中断在飞请求」而不是「晚一点再返回结果」。
    final run = _Run(queryID, _epoch);
    _active = run;
    adapter.cancellation = run.token;
    final timer = Timer(budget ?? queryBudget, () => run.token.cancel('TimedOut'));

    try {
      scope.check(scope.root);
      emit(queryID, 'sourceState', {'state': 'starting'});
      final items = await adapter.search(query, roots: scope.roots.toList());
      run.token.check();

      out.reportedTotal = items.length;
      final seen = <String>{};
      final batch = <Map<String, Object?>>[];
      for (final item in items) {
        run.token.check();
        // 同 list()：范围判定用规范化后的逻辑路径（去尾随斜杠）。
        final logical = normalizeLogicalPath(item.path);
        scope.check(logical);
        if (!seen.add(logical)) {
          throw const CoreError('ProtocolViolation');
        }
        out.fetchedCount++;
        if (scope.excludes(logical)) continue;
        if (out.files.length >= maxResults) {
          out.truncated = true;
          throw const CoreError('ResultLimit');
        }
        final owning = scope.owningRoot(logical);
        if (owning == null) throw const CoreError('ScopeDenied');
        final r = row(item, owning);
        out.files.add(r);
        batch.add(r);
      }
      if (batch.isNotEmpty) {
        emit(queryID, 'batch', {'files': batch, 'isComplete': false});
      }
      out.state = 'completed';
      out.complete = true;
    } on CoreError catch (e) {
      _recordFailure(out, run, e);
    } on AdapterFailure catch (e) {
      _recordFailure(out, run, toCoreError(e));
    } catch (_) {
      _recordFailure(out, run, const CoreError('ProtocolViolation'));
    } finally {
      timer.cancel();
    }
    return out;
  }

  void _recordFailure(SearchOutcome out, _Run run, CoreError error) {
    out.error = error;
    out.partial = out.files.isNotEmpty || out.truncated;
    // 取消 / 超时会中断在飞的请求，传输层可能把它报成 NetworkFailure。
    // 用户实际做的是取消，所以由取消原因决定对外状态 —— 与 SynologyCore 同一约定。
    final cancelled = run.token.cancelled;
    final cause = cancelled ? run.token.reason : error.kind;
    out.state = switch (cause) {
      'Cancelled' => 'cancelled',
      'TimedOut' => 'timedOut',
      'ResultLimit' => 'truncated',
      'SessionExpired' || 'NeedsAuth' => 'needsAuth',
      _ => 'failed',
    };
    if (identical(_active, run)) {
      emit(run.queryID, 'sourceState', {
        'state': out.state,
        'error': error.toJson(),
        if (cancelled) 'underlyingError': error.kind,
      });
    }
  }

  /// 品牌会话没有异步任务，因此没有需要清理的远端对象。
  /// 保留这个 getter 是为了让 harness 能用同一段代码收尾两种来源。
  bool get supportsTaskCleanup => false;
}
