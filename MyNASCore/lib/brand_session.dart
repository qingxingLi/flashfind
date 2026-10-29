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

  /// 下次可直接续期的凭据；没有密码的品牌才有（见 `SessionSecretProviding`）。
  ///
  /// 只在**登录成功后**读一次，随 `sessionState` 一起交上去，由 Swift 侧
  /// 存进本机凭据槽位。账密品牌这里恒为 null —— 它们的密码由界面自己保管，
  /// 适配器不该把它再抄一份出来。
  String? get sessionSecret {
    // 先落到 `Object` 再判：直接对着 `NasBrandAdapter` 做 `is` 时，CFE 不给
    // 提升到「两个不相交接口的交集」类型，访问成员会报「getter 未定义」。
    final Object a = adapter;
    return a is SessionSecretProviding ? a.sessionSecret : null;
  }

  /// 网页打开的兜底地址（fnOS 的站点首页 —— 桌面）。
  ///
  /// 只在 SMB 判定不可达时由 Swift 使用（双击结果 → 445 探测失败 → 开浏览器）。
  /// 每个会话一个入口即可，不含路径级定位（桌面不接受任何定位参数，
  /// 见 `webURLFor` 的说明）。
  String? get webFileURL {
    final Object a = adapter;
    if (a is! WebOpenableAdapter) return null;
    try {
      return a.webURLFor('').toString();
    } on CoreError {
      return null;
    }
  }

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

  /// 登录。
  ///
  /// ★ 这里**不做** `adapter.logout()`（2026-10-29 审查发现的阻断缺陷）：
  /// 飞牛的两段授权之间隔着用户操作，第一段生成的 PKCE verifier 存在
  /// 适配器实例上；用户粘授权码回来说的是**另一次** login —— 先 logout 会把
  /// verifier 清掉，第二段永远报「授权流程已过期」。旧会话的清理由适配器的
  /// `login` 自己负责（换令牌前先清旧态）；用户显式断开才走 `disconnect()`。
  Future<void> login(
    String account,
    String password,
    String? otp, {
    String? authorizeCode,
    List<String>? optionalScopes,
  }) async {
    cancel();
    _epoch++;
    // 飞牛这类 OAuth 品牌允许用户在授权前追加勾选额外权限：如果适配器支持
    //（`AuthorizationScopeCatalog`），把界面选中的可选 scope 交给它，
    // 由它拼进授权地址。不支持的品牌忽略。
    final Object scopeChoosing = adapter;
    if (optionalScopes != null && scopeChoosing is AuthorizationScopeCatalog) {
      scopeChoosing.requestedOptionalScopes = optionalScopes;
    }
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
        authorizeCode: authorizeCode,
      );
      switch (outcome) {
        case LoginSuccess():
          break;
        case LoginNeedsOTP(:final methods, :final rejected):
          // 「还没给码」与「给了被拒」是两个不同的 User 处置：
          // 前者要弹框问，后者要告诉用户刚才那 6 位不对（并让他重填），
          // 混成一个 kind 的话，输错一次之后界面仍然只说「请填写动态码」。
          final suffix = methods.isEmpty ? '' : '（${methods.join('/')}）';
          throw AdapterFailure(
            rejected ? ErrorKind.otpRejected : ErrorKind.needsOTP,
            rejected ? '动态验证码没有被接受，请重新填写$suffix' : '该账号需要动态验证码$suffix',
          );
        case LoginNeedsAuthorizeCode(:final authorizationUrl, :final validFor, :final rejected):
          // ★ 这不是失败，是登录流程的第一段（飞牛这种 OAuth 品牌）。
          // 抛一个**独立类型**而不是 AdapterFailure：调用方要拿到的是那个
          // 授权地址，让它去开浏览器；压成一句错误文案，地址就丢了，
          // 用户会看到「登录失败」而不知道该去哪里授权。
          // 权限清单一并带给界面：弹窗要告知用户「闪寻只需要哪几项」，
          // 其余的让用户勾选后再重新产出授权地址。
          throw LoginChallengeRequired(
            authorizationUrl: authorizationUrl,
            validFor: validFor,
            rejected: rejected,
            scopes: scopeChoosing is AuthorizationScopeCatalog
                ? [for (final s in scopeChoosing.authorizationScopes) s.toJson()]
                : null,
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

  /// 一条结果的「点开之后去哪」。
  ///
  /// 只有三种答案：SMB 位置、网页地址，都没有就是「打不开」。
  /// **不许返回一个猜的地址** —— 用户点下去才失败，比一开始就说「打不开」更糟。
  ///
  /// 优先顺序（2026-10-29 用户定）：**SMB > 网页**。下载不在这里 ——
  /// 它是右键菜单里的显式动作（`download` 命令），不是默认打开方式；
  /// 双击/回车的语义是「就地打开」，下载耗时且占流量，只该被显式要求。
  ///
  /// SMB 分两种：
  /// * 实现了 `SmbShareResolving` 的品牌（fnOS）：共享名来自
  ///   `file.share.list`/`file.share.info` 的映射，解析不出（路径不在任何
  ///   共享前缀下）退网页 —— 文件管理器能看到全部路径，这条路兜得住。
  /// * 其余暴露 SMB 的品牌（群晖等）：卷根就是共享名，沿用旧拼法。
  OpenTarget? _openTargetFor({
    required String path,
    required String owningRoot,
    required List<String> segments,
  }) {
    // ★ 先落 `Object` 再判接口：Dart 对 `NasBrandAdapter` 类型的变量
    //   不做交叉类型提升，直接 `adapter is SmbShareResolving` 之后
    //   变量类型不会变，访问不了接口成员。
    final Object a = adapter;
    if (a is SmbShareResolving) {
      if (smbHost.isNotEmpty) {
        final mapping = a.smbShareFor(path);
        if (mapping != null) {
          return SMBLocation(smbHost, mapping.shareName, mapping.relativeSegments);
        }
      }
      // 解析不出（路径不在任何共享前缀下）→ 落到网页兜底，不走旧拼法：
      // 这个品牌的卷根不是共享名，旧拼法只会造出假目标。
    } else if (adapter.exposesSMBShares && smbHost.isNotEmpty && owningRoot.isNotEmpty) {
      return SMBLocation(
        smbHost,
        owningRoot.startsWith('/') ? owningRoot.substring(1) : owningRoot,
        segments,
      );
    }
    // `WebOpenableAdapter` 与 `NasBrandAdapter` 是两个无关接口，Dart 不会把
    // 「NasBrandAdapter 且 WebOpenableAdapter」这个交叉类型提升出来，只能显式转。
    if (adapter is WebOpenableAdapter && path.isNotEmpty) {
      try {
        return WebLocation((adapter as WebOpenableAdapter).webURLFor(path));
      } on CoreError {
        // 适配器拼出了不合规的地址（跨源 / 带查询串 / 空路径）。这里吞掉并
        // 退回「不可打开」：一条结果打不开，不该让整次搜索失败。
        return null;
      }
    }
    return null;
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
    // openTarget 的优先顺序：**能用 SMB 就用 SMB，否则用网页，两者都没有就不发**。
    //
    // · 群晖 / 威联通 / 绿联 / 跑在 NAS 上的 WebDAV：主机本身就是 SMB 服务器，
    //   `smb://主机/共享/…` 是能直达文件的本地化入口（Finder 会挂载）。
    // · OpenList：网页聚合器，主机只讲 HTTP。以前这里给它拼 `smb://…`，
    //   真机实测双击只弹「连接服务器时出现问题」——一个**必然失败**的假目标。
    //   现在改发网页地址：那是它唯一能到达文件的入口，不是降级。
    // · 两者都没有（未实现网页接口的品牌）：宁可不发，也不要造一个错地址。
    final OpenTarget? open = _openTargetFor(path: path, owningRoot: owningRoot, segments: segments);
    return {
      'id': '$sourceID:$path',
      'name': item.name,
      'path': path,
      'fileType': item.isDirectory
          ? 'folder'
          : FileType.fromExtension(ext).name,
      'size': item.sizeKnown ? item.size : null,
      'modifiedDate': item.modifiedTime?.toIso8601String(),
      'sourceID': sourceID,
      'sourceName': sourceName,
      'sourceType': 'nas',
      'isOnline': true,
      // SMB 行恒为 false：能不能打开要等 Swift 侧核对挂载（含 445 可达性）
      // 与文件是否存在；SMB 不可达时 Swift 退网页（sessionState 的 webFileURL）。
      // 网页行给 true：地址已由适配器用**已核验的 origin** 拼好，点开就能到。
      // 下载不是 canOpen 的事——它是右键菜单里的显式动作。
      'canOpen': open is WebLocation,
      if (open != null) 'openTarget': open.toJson(),
    };
  }

  /// 下载一条结果到本机临时目录（RemoteDownload 打开链的执行端）。
  ///
  /// 只有实现了 `DownloadableAdapter` 的品牌才有这条路；范围校验与
  /// `list` 同一条纪律：不在授权范围内的路径，一步都不许往下走。
  Future<DownloadedArtifact> download(
    String path,
    Cancellation token,
  ) async {
    scope.check(path);
    if (!scopeReady) throw const CoreError('NeedsAuth');
    token.check();
    // ★ 先落成 Object 再判类型：Dart 对 `NasBrandAdapter` 类型的变量
    //   不做接口提升（SessionSecretProviding 那里踩过同一个坑）。
    final Object downloadable = adapter;
    if (downloadable is! DownloadableAdapter) {
      throw const CoreError('DownloadUnsupported');
    }
    final artifact = await downloadable.downloadToTemp(path, token);
    token.check();
    return artifact;
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
    List<String>? roots,
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
      // ★ 本次搜索实际生效的根：没传限定就用全部已授权根；传了就收窄。
      //
      // 收窄在**这里**做（而不是信任客户端）：客户端传的根必须落在已授权
      // 范围之内，否则报 ScopeDenied。
      final effective = (roots == null || roots.isEmpty) ? scope : scope.narrowTo(roots);
      emit(queryID, 'sourceState', {'state': 'starting'});
      // ★ 下发给设备的是**收窄后**的根：品牌适配器逐根各发一次请求，
      // 少一个根就少一次设备侧扫描——检索时间因此真的下降。
      // ★ 部分根没搜通的记录：结果照发，但这次搜索**不许**说成完整。
      //
      // 以前的写法是「只要有根搜通（哪怕零命中）就把别的根的错误吞掉」，
      // 于是「有一个存储的上游失效」被界面显示成「没有找到」——
      // 用户以为这台设备上根本没有这个文件，而真相是有一个位置没搜过。
      final failedRoots = <RootSearchFailure>[];
      final items = await adapter.search(
        query,
        roots: effective.roots.toList(),
        onRootFailure: failedRoots.add,
      );
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
      if (failedRoots.isNotEmpty) {
        _markIncomplete(out, failedRoots);
      }
      out.state = 'completed';
      // ★ 有位置没搜通就不是一次完整的搜索：`isComplete=false` 会让界面
      //   如实显示「结果不完整」，而不是拿一份局部结果冒充全范围结论。
      out.complete = failedRoots.isEmpty;
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

  /// ★ 「有几个位置没搜通」既不是失败，也不是「全都没有找到」。
  ///
  /// 三件事必须一起做，缺一件就退化成原来那句骗人的「没有找到」：
  ///   · `partial` —— 结果不完整；
  ///   · `failedRoots` —— 是**哪几个**位置没搜通（不给名字用户无从判断）；
  ///   · `partialNote` —— 给界面的一句话，说明为什么结果只覆盖其余位置。
  void _markIncomplete(SearchOutcome out, List<RootSearchFailure> failures) {
    out.partial = true;
    out.failedRoots.addAll(failures.map((f) => f.root));
    final first = failures.first;
    out.error = toCoreError(first.failure);
    final names = failures.map((f) => f.root).join('、');
    out.partialNote = failures.length == 1
        ? '搜索位置 $names 这次没能检索（${first.failure.message}）；结果只覆盖其余位置。'
        : '有 ${failures.length} 个搜索位置这次没能检索：$names（${first.failure.message}）；结果只覆盖其余位置。';
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

/// 登录需要用户去浏览器授权 —— **不是失败，是流程的第一段**。
///
/// 为什么要有独立类型，而不是塞进 `AdapterFailure`：
/// `AdapterFailure` 只有 kind + 一句文案，授权地址这个**唯一有用的东西**
/// 会在翻译成 `CoreError` 时被丢掉（`CoreError.reason` 是给人看的短句，
/// 往里塞 400 字符的 URL 既不合适、也会被诊断文件记下来）。
/// 所以单独抛，由 harness 直接换成一条 `authChallenge` 事件发给界面。
///
/// 形状对齐：Swift 侧收到后应当展示 `authorizationUrl`（用户在浏览器里
/// 登录并点授权），再把页面上显示的一次性 code 通过下一次 `login` 命令的
/// `authorizeCode` 字段交回来。
class LoginChallengeRequired implements Exception {
  final Uri authorizationUrl;
  final Duration validFor;

  /// 上一轮提交的 code 被拒绝了（而不是第一次要授权）。
  final bool rejected;

  /// 授权页权限清单（每项 `{id,label,required}`）。
  /// 适配器不提供（账密品牌）时为 null，界面按无清单渲染。
  final List<Map<String, Object?>>? scopes;

  const LoginChallengeRequired({
    required this.authorizationUrl,
    required this.validFor,
    this.rejected = false,
    this.scopes,
  });

  Map<String, Object?> toJson() => {
    'kind': 'authorizeCode',
    'authorizationUrl': authorizationUrl.toString(),
    'validForMs': validFor.inMilliseconds,
    'rejected': rejected,
    if (scopes != null) 'scopes': scopes,
  };

  @override
  String toString() => 'LoginChallengeRequired(rejected=$rejected)';
}
