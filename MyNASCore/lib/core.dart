import 'dart:async';
import 'protocol.dart';
import 'synology_api.dart';
import 'pending_tasks.dart';
import 'synology_search_task.dart';
import 'upstream_synology_models.dart';
import 'upstream_file_types.dart' show FileType;
import 'open_target.dart';

class SearchOutcome {
  String state = 'failed', cleanup = 'notRequired';
  CoreError? error;
  String? limitReason;
  final files = <Map<String,Object?>>[];
  int? reportedTotal;
  int fetchedCount = 0;
  /// 设备返回了、但我们**无法解析**而被跳过的行数。
  ///
  /// 必须如实上报：静默丢行会让用户以为「就是没有这些文件」，
  /// 而这恰恰是排查这类故障时最需要看见的数字。
  int unparsedCount = 0;
  /// 设备**重复返回**（同一条 path 出现多次）而被合并掉的条数。
  ///
  /// 与 `unparsedCount` 分开记：一个是「看不懂」，一个是「给重了」，
  /// 处置完全不同。见 `_search` 里的分页循环。
  int duplicateCount = 0;
  bool partial = false, truncated = false, complete = false;
  final cleanupErrors = <String>[];
  /// 本次搜索**开始前**回收旧 DSM 任务的结果。
  ///
  /// 单独列出来而不是并进 `cleanup`：一个说的是「别人的烂摊子」，
  /// 一个说的是「本次搜索自己的收尾」，混在一起就分不清泄漏发生在哪一次。
  DrainReport? pendingBefore;
  /// 本次搜索**结束后**再回收一次的结果（本次 clean 失败的东西也进队列）。
  DrainReport? pendingAfter;
  Map<String,Object?> toJson() => {'resultState':state,'cleanupState':cleanup,'error':error?.toJson(),'isComplete':complete,'partial':partial,'truncated':truncated,'reportedTotal':reportedTotal,'fetchedCount':fetchedCount,'unparsedCount':unparsedCount,'duplicateCount':duplicateCount,'publishedCount':files.length,'cleanupErrors':cleanupErrors,'partialReason':error?.kind ?? limitReason,if (pendingBefore != null) 'pendingBefore':pendingBefore!.toJson(),if (pendingAfter != null) 'pendingAfter':pendingAfter!.toJson()};
}
class Lease {
  final String queryID;
  final int epoch;
  final Duration budget;
  final String? account;
  final Cancellation token = Cancellation();
  String? task;
  bool starting = false, startSubmitted = false;
  Lease(this.queryID,this.epoch,this.account,this.budget);
}
class SynologyCore {
  final SynologyApi api;
  /// 搜索范围根。登录并由用户选定共享之前为 null，因此不是 final。
  Scope? _scope;
  /// 结果里对外展示的来源名（产品端给定，例如「群晖 NAS」）。
  final String sourceName;
  /// 结果 openTarget 使用的 SMB 主机名，来自用户填写的 NAS 地址。
  final String smbHost;
  final Duration queryBudget, cleanupBudget, pollInterval, startGrace;
  final int maxResults;
  /// 判断「设备还没算完」时，最多再看几眼就认定它未就绪。
  ///
  /// 上限刻意很小：已证明失败的搜索任务其响应**逐次一致**，
  /// 多轮询纯浪费时间；而且设备侧存在连续搜索后的退化窗口，堆重试只会加重它。
  final int readinessPollLimit;
  /// 设备声明「还在扫描」（`finished=false`）时，最多再等几轮。
  ///
  /// 与 [readinessPollLimit] 分成两个预算，因为这两种等待的性价比完全不同：
  /// · `readinessPollLimit` 管的是「没给 total」—— 已证明失败的搜索任务
  ///   响应逐次一致，多轮纯浪费时间，所以刻意小；
  /// · 本项管的是「还在扫」—— 大目录的真实耗时，**等是有产出的**。
  ///
  /// 真机实测：两台设备上从 start 到 `finished=true` 分别用时
  /// 0.19~0.80s 与 0.43~1.05s。按 500ms 轮询间隔，两者都在 3 轮内收敛。
  /// 取 24 轮（≈12s）给足一个数量级的余量，仍远在 30s 查询预算之内。
  final int scanningPollLimit;
  /// 就绪轮询时向设备请求的行数。
  ///
  /// 这一步**只是为了拿到 `total`**，所以越小越好。
  ///
  /// 不能取 `0`：`limit=0` 在 `Search.list` 上的语义没有保证，
  /// 若设备把它理解成「不限量」，一次就绪轮询就会把整个结果集拖回来
  /// —— 公司级共享上正是几百 KB 的量级。
  ///
  /// 取 `1`：只多带一行，`total` 照样有，且在真实设备上验证过可用，
  /// 所以这不是一个新参数。
  static const int readinessLimit = 1;
  Lease? active;
  /// DSM 搜索任务的生命周期（start 之后的 stop / clean 与孤儿回收）。
  ///
  /// 旧实现里这些细节散在 `SynologyCore._cleanup` 里，而「没能清掉的任务」
  /// 是一个只进不出的 `List` —— clean 失败一次设备上就永久多一个任务。
  /// 任务号是不透明字符串，从不外发、不落盘。
  late final SynologySearchTaskManager tasks;
  /// 没能清掉的任务队列。**投影**到 `tasks`，外部只读它来观察队列状态。
  PendingTaskManager get pendingTasks => tasks.pending;
  final void Function(String queryID, String event, Map<String,Object?> data) emit;
  SynologyCore(this.api,Scope? scope,{this.sourceName = 'NAS',this.smbHost = '',this.queryBudget = const Duration(seconds:30),this.cleanupBudget = const Duration(seconds:5),this.pollInterval = const Duration(milliseconds:500),this.startGrace = const Duration(seconds:2),this.maxResults = 2000,this.readinessPollLimit = 3,this.scanningPollLimit = 24,void Function(String,String,Map<String,Object?>)? emit}) : _scope = scope, emit = emit ?? ((_,__,___) {}) {
    tasks = SynologySearchTaskManager(api, cleanupBudget: cleanupBudget);
  }
  /// 当前搜索范围根。未选定共享时为 null——此时不允许发起任何搜索。
  Scope get scope { final s=_scope; if(s==null)throw const CoreError('ScopeUnset'); return s; }
  bool get hasScope => _scope != null;
  /// 切换搜索范围（可多选）。必须**每一个**目录都通过共享准入校验后才生效。
  Future<void> selectScopes(Cancellation token, List<String> roots) async {
    final next = Scope.multi(roots);
    if (next.roots.any((r) => !api.validatedRoots.contains(r))) {
      await api.validateScope(token, next);
    }
    cancel();
    _scope = next;
  }
  bool get scopeReady => _scope != null && api.scopeReady
      && _scope!.roots.every(api.validatedRoots.contains);
  bool current(Lease l) => identical(active,l) && l.epoch == api.sessionEpoch && l.account == api.accountIdentity && !l.token.cancelled;
  void publish(Lease l, String event, Map<String,Object?> data) { if (current(l)) emit(l.queryID,event,data); }
  void cancel([String? queryID]) { final l = active; if (l != null && (queryID == null || l.queryID == queryID)) l.token.cancel(); }
  Future<void> disconnect() async {
    final running = _running; cancel(); if (running != null) { await running; }
    // 登出之前把遗留任务收掉：会话一断，taskid 就再也管不着了。
    await drainPendingTasks();
    final t = Cancellation(), timer = Timer(cleanupBudget, () => t.cancel('TimedOut'));
    try { await api.logout(t); } finally { timer.cancel(); active = null; }
  }
  Future<SearchOutcome>? _running;
  Future<SearchOutcome> search(String query, String queryID,{Duration? budget}) {
    cancel(); final previous = _running;
    final l = Lease(queryID,api.sessionEpoch,api.accountIdentity,budget ?? queryBudget); active = l;
    final f = _searchAfter(previous,l,query); _running = f; return f;
  }
  Future<SearchOutcome> _searchAfter(Future<SearchOutcome>? previous, Lease l, String query) async {
    await Future<void>.delayed(Duration.zero); // Allow queued controls before submission.
    // One task per source; control channel remains asynchronous while waiting.
    if (previous != null) { await previous; }
    final out = await _search(l,query);
    if (identical(active,l) && l.epoch == api.sessionEpoch) emit(l.queryID,'terminal',out.toJson());
    return out;
  }
  Map<String,Object?> result(FileStationFile f) {
    final owning = scope.owningRoot(f.path);
    if (owning == null) throw const CoreError('ScopeDenied');
    // 相对段与 SMB 共享名都要按「这条结果属于哪个根」计算——
    // 多根下沿用单一 root 会算错共享名，Finder 定位就会指到别的目录。
    final segments = f.path.substring(owning.length).split('/').where((s)=>s.isNotEmpty).toList();
    final ext = f.name.contains('.') ? f.name.split('.').last : '';
    final open = smbHost.isEmpty ? null : SMBLocation(smbHost,owning.substring(1),segments).toJson();
    return {'id':'${api.sourceID}:${f.path}','name':f.name,'path':f.path,'fileType':f.isDir ? 'folder' : FileType.fromExtension(ext).name,'size':f.size,'modifiedDate':f.modifyTime?.toIso8601String(),'sourceID':api.sourceID,'sourceName':sourceName,'sourceType':'nas','isOnline':true,'canOpen':false,if (open != null) 'openTarget':open};
  }
  Future<List<Map<String,Object?>>> list(String path, Cancellation token, {void Function(int)? countReceived, void Function(int)? countUnparsed}) async {
    scope.check(path); if (!scopeReady) throw const CoreError('NeedsAuth');
    int offset = 0; int? total; final seen = <String>{}; final out = <Map<String,Object?>>[];
    while (true) {
      final p = await api.listFiles(path,offset,token);
      // 目录读取这条路**要求 total 必须存在**：没有它就无法判断「取完了没有」。
      // 这与搜索路径不同——搜索路径可以把缺 total 当成「设备未就绪」，
      // 因为那里有明确的「未就绪」语义可表达；目录读取没有，只能报不稳定。
      final pageTotal = p.total;
      if (pageTotal == null) throw const CoreError('DirectoryUnstable', detail: '目录列表响应缺少 total');
      if (p.offset != offset || (total != null && pageTotal != total) || offset + p.rawCount > pageTotal) throw const CoreError('DirectoryUnstable');
      total = pageTotal; countReceived?.call(p.files.length);
      if (p.unparsedCount > 0) countUnparsed?.call(p.unparsedCount);
      for (final f in p.files) { scope.check(f.path); if (!seen.add(f.path)) throw const CoreError('DirectoryUnstable'); if (!scope.excludes(f.path)) out.add(result(f)); }
      // ★ 游标按设备**返回**的行数推进，不是解析成功的行数：
      // 少走一格就会重复取回同一批数据，表现为 DirectoryUnstable 或死循环。
      offset += p.rawCount;
      if (offset >= total) return out;
      if (p.rawCount == 0) throw const CoreError('DirectoryUnstable');
    }
  }
  Future<SearchOutcome> _search(Lease l, String query) async {
    final out = SearchOutcome();
    final timer = Timer(l.budget,()=>l.token.cancel('TimedOut'));
    try {
      l.token.check();
      if (!scopeReady || l.epoch != api.sessionEpoch) { throw CoreError(hasScope ? 'NeedsAuth' : 'ScopeUnset'); }
      if (query.trim().isEmpty) { out.state='completed'; out.complete=true; out.reportedTotal=0; return out; }
      if (!api.descriptors.containsKey('SYNO.FileStation.Search')) { throw const CoreError('UnsupportedSearchNoFallback'); }
      // ★ 建新任务之前，先把以前没清掉的老任务收一遍。
      //
      // 不这么做的话，设备上遗留的 DSM Search Task 会越积越多，
      // 表现就是「File Station 一直正常，闪寻搜几次之后就搜不到了」——
      // 不是索引坏了，是我们自己占住了设备的搜索资源。
      final drained = await drainPendingTasks();
      if (!drained.isEmpty) out.pendingBefore = drained;
      scope.check(scope.root); publish(l,'sourceState',{'state':'starting'});
      l.starting=true; l.startSubmitted=true;
      // Cancellation after submission waits a bounded grace for a late task ID.
      final startToken = Cancellation(); Timer? grace;
      void startCancel() { grace ??= Timer(startGrace,()=>startToken.cancel(l.token.reason)); }
      l.token.listeners.add(startCancel);
      try { l.task=await api.startSearch(scope.roots.toList(),query,startToken); }
      on CoreError catch (e) { if (e.kind == 'NetworkFailure' || e.kind == 'TimedOut' || e.kind == 'Cancelled') throw const CoreError('UnknownSubmission'); rethrow; }
      finally { l.starting=false; grace?.cancel(); l.token.listeners.remove(startCancel); }
      l.token.check();
      publish(l,'sourceState', {'state':'polling'});
      // ───────────────────────────────────────────────────────────────────
      // 就绪判据：**拿到 `total` 且设备声明这次搜索已经跑完**。
      //
      // 真机上量到的两件事：
      //   * 「`finished=true` 却**没有** `total`」是**未就绪/退化**，
      //     **不是「0 条结果」**（契约禁止把它显示成没找到文件）；
      //   * `finished=false` 时的 `total` 只是「目前已发现数」，还会继续涨
      //     （就绪轮询 `limit=1` 报 33~103，第一页分页 `limit=200` 报 239）。
      // 旧判据只看 `total != null`，于是在这个中间态上放行，紧接着分页第一条
      // 一致性断言 `page.total != total` 必炸 —— 用户看到的就是
      // 「搜索失败—设备返回的分页数据不完整（错误类型 IncompleteResponse）」。
      //
      // 「这次搜索还没跑完」与「已经跑完」是设备上两个不同的状态，
      // 只有后者的 `total` 才是全集。这也解释了「再搜一次就好了」：
      // 请求抵达时搜索若已跑完，旧判据碰巧是对的；没跑完就必然失败。
      //
      // 分页循环因此仍然**不检查 `finished`**（中间态合法，见下），
      // 但「与就绪时报告的全集一致」这条断言得以守住：现在拿到的 total
      // 已经是设备声明算完之后的全集。
      // ───────────────────────────────────────────────────────────────────
      Page status;
      var readinessPoll = 0;
      while (true) {
        l.token.check();
        // limit 取 1 而不是 0：这里只要 `total`，而 `limit=0` 的语义在
        // `Search.list` 上从未验证过（详见 [readinessLimit]）。
        status = await api.searchPage(l.task!,0,readinessLimit,l.token);
        if (status.ready) break;
        if (status.finished == false && readinessPoll < scanningPollLimit) {
          // 设备还在扫描：等。这是大目录的真实耗时，不是故障。
          readinessPoll++;
          await l.token.delay(pollInterval);
          continue;
        }
        // 确认未就绪：设备既没给 total，也没说还在算（或等够了还没算完）。
        // 归类为**可重试的中间态**，不是协议违规、更不是零结果。
        throw CoreError('ResultsNotReady',
            api: 'SYNO.FileStation.Search', method: 'list',
            detail: '轮询 ${readinessPoll + 1} 次仍未拿到可用的 total'
                    '（finished=${status.finished}），设备侧搜索任务未就绪');
      }
      final total = status.total!;
      out.reportedTotal = total;
      int offset=0; final paths=<String>{};
      while (offset < total) {
        l.token.check(); if (l.epoch != api.sessionEpoch || l.account != api.accountIdentity) throw const CoreError('SessionExpired');
        final page=await api.searchPage(l.task!,offset,200,l.token);
        // ★ 这里**不再检查 `page.finished`**。分页响应带 `finished=false`
        // 是合法中间态（HAR 里就有 `finished=false` 且 `total=70` 的样本）。
        // 旧实现要求 `page.finished == true`，后果是：**只要设备在分页期间
        // 仍在继续扫描，第一页就会被判成 ProtocolViolation，整份已就绪的
        // 203 条结果全部作废、界面显示 0 条**——故障现场就是
        // `reportedTotal=203` + `fetchedCount=0`。
        //
        // 需要守住的是「这一页与就绪时报告的全集一致」，否则分页会静默丢/重。
        if (page.total == null) throw const CoreError('IncompleteResponse', api:'SYNO.FileStation.Search', method:'list', detail: '分页响应缺少 total');
        if (page.total != total) throw const CoreError('IncompleteResponse', api:'SYNO.FileStation.Search', method:'list', detail: '分页 total 与就绪时报告的不一致');
        if (page.offset != offset) throw const CoreError('IncompleteResponse', api:'SYNO.FileStation.Search', method:'list', detail: '分页 offset 回显与请求不一致');
        if (page.rawCount == 0) throw const CoreError('DirectoryUnstable', api:'SYNO.FileStation.Search', method:'list', detail: '还有未取完的结果，但分页返回了空列表');
        if (offset + page.rawCount > total) throw const CoreError('IncompleteResponse', api:'SYNO.FileStation.Search', method:'list', detail: '分页返回条数超出报告总数');
        // 一整页一行都解析不出来 —— 这不是「没有结果」，是响应形态变了，必须报错。
        if (page.files.isEmpty) throw CoreError('IncompleteResponse', api:'SYNO.FileStation.Search', method:'list', detail: '整页 ${page.rawCount} 行均无法解析：${page.unparsedReasons.join('；')}');
        // ─────────────────────────────────────────────────────────────
        // 设备在同一次 `Search.list` 里**不保证每条 path 唯一**。
        //
        // 证据（真机）：`reportedTotal=203`、`fetchedCount=0`。
        // `fetchedCount` 是在这个循环**之后**才累加的，说明重复出现在**第一页
        // 内部** —— 毕竟第一页跑起来时 `paths` 还是空的，页间重叠解释不了它。
        // 旧实现把它当成 ProtocolViolation，于是「设备多给了一条」就让
        // 整份已经就绪的 203 条结果全部作废、界面显示 0 条 ——
        // 处置与后果完全不成比例。
        //
        // 现在：同一条路径只保留一次，条数如实计入 `duplicateCount`（进诊断）。
        // ─────────────────────────────────────────────────────────────
        var freshInPage = 0;
        // 去重与发布必须是**同一个循环**：分成两个循环时，第二个循环遍历的
        // 仍是 `page.files`（含重复行），于是「查过重了」和「照样发两遍」
        // 会同时成立 —— 界面上的重复结果正是这么漏出去的。
        //
        // 按批发布，不要一文件一个 batch：一文件一批会让 Swift 侧对**每个结果**
        // 都做一次挂载表扫描 + 派发后台任务，结果量大时（实测过 800+）
        // 会退化成几百次重复系统调用。
        final accepted=<Map<String,Object?>>[];
        for (final f in page.files) {
          scope.check(f.path);
          if (!paths.add(f.path)) { out.duplicateCount++; continue; }
          freshInPage++;
          if (scope.excludes(f.path)) continue;
          if (out.files.length >= maxResults) { out.truncated=true; throw const CoreError('ResultLimit'); }
          final row=result(f); out.files.add(row); accepted.add(row);
        }
        // 整页都是已经见过的路径 ⇒ 设备没有按 offset 推进（或结果集在两次请求
        // 之间被重排），继续下去只会一直取回同一批数据。
        // 这里**必须报错**：静默去重会让用户拿到一份残缺的结果，
        // 而他会以为那就是全部。
        if (freshInPage == 0) {
          throw CoreError('DirectoryUnstable', api:'SYNO.FileStation.Search', method:'list',
              detail: '整页 ${page.rawCount} 行均为已见过的路径（设备未按 offset 推进）');
        }
        out.fetchedCount += page.rawCount; // 设备**原始返回**数量，含被跳过的坏行与重复行。
        out.unparsedCount += page.unparsedCount;
        if (accepted.isNotEmpty) publish(l,'batch',{'files':accepted,'isComplete':false});
        offset += page.rawCount; // 同上：按设备返回行数推进，而非解析成功行数。
      }
      out.state='completed'; out.complete=true;
    } on CoreError catch (e) {
      out.error=e; out.partial=out.files.isNotEmpty || out.truncated;
      // A user cancel or a fired query budget aborts whatever request is in flight, so the
      // transport can surface NetworkFailure instead of the real cause. The cancellation
      // reason is what the user actually did, so it decides the visible state; the raw
      // error is kept for diagnosis.
      final cancelled = l.token.cancelled;
      final cause = cancelled ? l.token.reason : e.kind;
      // `deviceBusy` 是**可重试的中间态**，不是失败：设备还没把结果算出来。
      // 把它显示成 failed 会让用户以为「这台 NAS 搜不了」，
      // 而实际上等一会儿、或者少连打几次搜索就好了。
      out.state=switch(cause) {'Cancelled'=>'cancelled','TimedOut'=>'timedOut','ResultLimit'=>'truncated','SessionExpired'||'NeedsAuth'=>'needsAuth','ResultsNotReady'=>'deviceBusy',_=>'failed'};
      if (e.kind == 'UnknownSubmission') { out.cleanup='pending'; }
      // Error arrives independently of slow cleanup, but no superseded results.
      if (identical(active,l)) emit(l.queryID,'sourceState',{'state':out.state,'error':e.toJson(), if(cancelled) 'underlyingError':e.kind});
    } catch (error) {
      // ★ 这里以前写的是 `catch (_) { out.error = const CoreError('ProtocolViolation'); }`，
      // 把**所有**非 CoreError 的异常（类型转换失败、越界、断言……）压成同一个
      // 没有任何信息的 ProtocolViolation。后果是
      // 「缺字段 / 类型不符 / 客户端代码缺陷」三种完全不同的原因
      // 在界面和诊断里长得一模一样，无法区分。
      // 现在保留异常**类型**与一段**不含值**的说明（异常消息里可能带路径/文件名，
      // 引号内容一律剔除），`detail` 只用于诊断、不会展示给用户。
      out.error = CoreError('ProtocolViolation', detail: 'client:${_clientCause(error)}');
      out.partial = out.files.isNotEmpty;
    }
    finally {
      timer.cancel();
      if (l.task != null) await _cleanup(l,out,stop:!out.complete);
      // 本次 clean 若失败了，也已经在队列里；顺手再收一次，
      // 别把「本次的烂摊子」留到下一次搜索才处理。
      final after = await drainPendingTasks();
      if (!after.isEmpty) out.pendingAfter = after;
      if (out.error?.kind == 'SessionExpired') api.clearSession();
    }
    return out;
  }
  /// 收掉本次搜索在设备上留下的任务。
  ///
  /// stop / clean 怎么发、失败后怎么入队，都在 `SynologySearchTaskManager` 里；
  /// 这里只负责把结果（`cleaned` / `pending`）写进 outcome。
  Future<void> _cleanup(Lease l, SearchOutcome out, {required bool stop}) async {
    out.cleanup = await tasks.finish(task: l.task!, epoch: l.epoch, account: l.account,
                                     stop: stop, cleanupErrors: out.cleanupErrors);
  }

  /// 回收此前没清掉的 DSM 搜索任务。
  ///
  /// 会话已经换掉的条目会被放弃（taskid 绑定会话，换了就管不着了），
  /// 放弃的条数如实出现在 `DrainReport.abandoned` 里。
  Future<DrainReport> drainPendingTasks() => tasks.drain();
}

/// 把一个**非 CoreError** 的异常收敛成一行可诊断、且**不含任何内容**的说明。
///
/// 异常消息里经常夹着出错的原始值（可能是一条路径或文件名），
/// 而这段文字会进入诊断文件，所以引号内的内容一律替换掉。
/// 保留的信息是「异常类型 + 结构化的说明」，足以区分
/// 「设备少给了字段」「字段类型不符」和「客户端自己写错了」这三类完全不同的原因。
String _clientCause(Object error) {
  var text = '$error'.split('\n').first;
  text = text.replaceAll(RegExp(r"'[^']*'"), "…").replaceAll(RegExp(r'"[^"]*"'), '…');
  if (text.length > 140) text = '${text.substring(0, 140)}…';
  return '${error.runtimeType}: $text';
}
