// OpenList / Alist 品牌适配器。
//
// ── 契约来源 ────────────────────────────────────────────────────────
// 全部来自 2026-10-24 对真实实例的实测，不是照抄上游、也不是按 AList 文档推测：
//   `00-项目管理/任务交付/OL-AUTH-02-OpenList真实契约验证-20261024.md`
// 受测版本 OpenList v4.1.10（commit e3c664f）。换了版本要重测，不能假设兼容。
//
// ── 实测出来的六条硬约束（每一条都有对应的坑，见报告第三节）──────────
// 1. **HTTP 状态码不可用于判断**：密码错、token 失效、上游存储失效、目录不存在，
//    服务端一律回 **HTTP 200**，真实结果在 `body.code`。用 `statusCode` 分类
//    会把「密码错」当成成功——这条路必须走 `code`。
// 2. **禁止用 `scope=0`（全盘）搜索**：实测某关键字 66 条结果里 47 条落在
//    已不存在的存储上（`list` 报 `storage not found`，索引里还留着）。
//    全盘搜索会把死链当结果给用户，点开必然失败。
//    ⇒ 只允许 `scope=1` 逐 root 搜，`roots` 由上层授权给出。
// 3. **空关键字会返回全站文件**（实测 80315 条）⇒ 空查询直接拒绝，不发请求。
// 4. **`per_page` 无上限**（1000 条照收，275ms）⇒ 自己限流，默认 100/页。
// 5. **目录不存在静默 0**：`scope=1` + 不存在的 parent 返回 `code=200, total=0`，
//    与「真的没有匹配」不可区分 ⇒ 搜索前用 list 预检 root；预检失败要单独报，
//    不能把「目录没了」显示成「没找到文件」。
// 6. **两类 `code=500` 语义相反**：`failed get storage` = 路径/存储不存在；
//    `failed to list objs` = 该存储的上游网盘凭据失效（不是本账号的问题）。
//    混成一句「加载失败」，用户不知道该改路径还是该去重新授权网盘。
// 7. **两步验证是 `code=402`，而且必须把码随请求发上去**：该账号在网页端开了
//    TOTP 之后，`/api/auth/login` 的密码校验通过还不够，要带 `otp_code`；
//    码缺或错都回 402 `Invalid 2FA code`（HTTP 仍是 200）。
//    这条是**读上游源码 + 复核版本**补上的，不是实测账号观测到的——
//    受测账号没开 2FA，所以第一版把它漏成了「本服务没有 OTP」，那句是错的。
//
// ── 已知限制（如实写在 capabilities.notes 里，不掩盖）───────────────
// · 结果项只有 `parent / name / is_dir / size / type` 五个字段，**没有修改时间**
//   ⇒ `modifiedTime` 一律留 null；不许拿 size 或本轮时间冒充。
// · `type` 字段语义未定（只观测到 `1`），不参与判断，目录/文件一律以 `is_dir` 为准。
// · 搜索走数据库索引（`search_index=database`）⇒ 刚上传的文件可能还没进索引。
//   这条要能解释「网页上看得见、闪寻搜不到」，不能承诺「一定搜得到」。
import 'dart:async';

import '../adapter_contract.dart';
import '../adapter_support.dart';
import '../dio_compat.dart';
import '../error_kinds.dart';
import '../protocol.dart';
import '../upstream_file_types.dart';

/// 单页条数。实测 100 条耗时 ~100–275ms；1000 条虽被接受但没必要。
const int _pageSize = 100;

/// 同时进行的 root 搜索数。
///
/// 4 是折中：公网站点常见单请求 0.2–3 s，10 个存储串行要几十秒；
/// 并发太高又容易被网关限流（实测 429 在突发请求下有出现）。
const int _rootConcurrency = 4;

/// 单次请求最多翻多少页。**必须有上限**：`total` 由服务端给，
/// 拿它当循环终止条件是信任远端；这里再兜一层，防止异常 total 把循环拖死。
const int _maxPages = 50;

/// OpenList 会话与搜索适配器。
class OpenListAdapter implements NasBrandAdapter, WebOpenableAdapter {
  OpenListAdapter({required Dio dio}) : _dio = dio;

  final Dio _dio;

  Cancellation? _cancel;
  String? _identity;

  /// 会话令牌。**只在内存里**：属会话态、不落盘、不进日志。
  /// 实测有效期 48 小时，且 JWT 里带 `pwd_ts` —— 账号改密码会立即失效。
  String? _token;

  /// 账号的 `base_path`（`/api/me` 给）。**游客账号常见 `/guest_dir`**。
  ///
  /// ★ 这是两个坐标系的换算基准，2026-10-27 真机报障的根因：
  ///   · `list` 与请求里的 `parent` 都是**相对 base_path 的客户端坐标**（`/Book`）；
  ///   · `/api/fs/search` 返回项的 `parent` 是**存储侧绝对路径**（`/guest_dir/Book/…`）。
  /// 不换算 ⇒ 结果全部落在授权根之外 ⇒ 上层 `Scope.narrowTo` 判 `ScopeDenied`，
  /// 界面表现是「搜不到 + 所选目录不在该账号的可搜索范围内」，而服务器明明回了结果。
  ///
  /// 实测（2026-10-27）：公网站点上两种形态都真实存在 —— 一种 `base_path='/'`，
  /// 另一种（游客账号）`base_path='/guest_dir'`，两种都必须能搜。
  String? _basePath;

  final Logger _log = Logger();

  // ─────────────────────── 窄接口的表面 ───────────────────────

  @override
  String get vendor => 'openlist';

  @override
  String? get sessionIdentity => _identity;

  @override
  set cancellation(Cancellation token) {
    _cancel = token;
    _dio.cancellation = token;
  }

  /// 能力声明。
  ///
  /// `nativeSearch = true` 与 `verifiedOnDevice = true` 都基于真机实测；
  /// 但**验证范围仅此一台实例与该账号**，`notes` 里逐条写清验到什么、没验什么。
  @override
  BrandCapabilities get capabilities => const BrandCapabilities(
    nativeSearch: true,
    verifiedOnDevice: true,
    querySemantics:
        '服务端索引搜索（/api/fs/search）：只匹配文件名，逐授权目录用 scope=0 检索；'
        '不做全盘搜索、不递归遍历目录、不读文件内容。',
    notes:
        '真机已验证（OpenList v4.1.10 / commit e3c664f）：'
        '账号密码登录得 JWT（有效期 48 小时，改密码即失效）；'
        '根目录列出存储列表；parent 按 LIKE 前缀限定在该 root 内，越界为 0；分页 page/per_page 正常；'
        '中文关键字正常；零结果为 code=200 total=0；'
        'code=401 映射会话失效、400 映射密码错、'
        '500「failed get storage」映射路径不存在、「failed to list objs」映射上游存储失效。'
        '已知限制：结果项不含修改时间（界面对该来源不显示时间）；'
        'type 字段语义未确认，不参与判断；'
        '搜索基于数据库索引，刚上传的文件可能尚未入库。'
        '两步验证：开了 TOTP 的账号按 code=402 提示补 6 位动态码——'
        '依据上游 server/handles/auth.go（同版本 v4.1.10）与 fixture 复现，'
        '本轮没有开 2FA 的账号可真机走一遍，界面链路待实测。'
        '已验证范围仅此一台实例与该账号。',
  );

  /// 结果**不能**用 SMB 打开。
  ///
  /// OpenList 是网页聚合器：主机只讲 HTTP，`/A0002` 这类「存储」不是 SMB 共享。
  /// 真机实测（2026-10-24，AOT 二进制）结果行带过
  /// `smb://openlist.example.invalid/A0002/…`，用户双击只会收到
  /// 「连接服务器时出现问题」——一个必然失败的假目标。
  /// 要说「点开结果」，得走网页 URL（阶段 OL-OPEN），那不是把 SMB 硬凑上来能解决的。
  @override
  bool get exposesSMBShares => false;

  /// OpenList 的网页入口：`<origin>/<逻辑路径>`。
  ///
  /// 依据是 2026-10-24 对真实实例（v4.1.10 / commit e3c664f）的实测，
  /// 不是照抄上游文档：
  /// · 前端是 **history 模式**的 SPA，路由只有 `/`、`*`、`/@login`、`/@manage/*`；
  ///   `*` 兜底把 `decodeURIComponent(location.pathname)` 当作要浏览的逻辑路径。
  /// · 服务端对深路径回落同一份 index.html：`/A0002/`、`/A0002/我的文档/`、
  ///   以及百分号编码形式**都回 200 / text/html / 18244 B**，与 `/` 完全一致
  ///   ⇒ 深链接可用，**不需要** `#` 路由（老 AList 是 hash，这一版不是）。
  /// · 路径逐段交给 `Uri` 编码：中文→UTF-8 百分号、空格→`%20`、字面 `%`→`%25`、
  ///   `#`→`%23`、`?`→`%3F`。字符串拼凑会让「名字里带 % 或 # 的文件」打不开。
  @override
  Uri webURLFor(String logicalPath) {
    final origin = _dio.siteOrigin;
    final segments = logicalPath.split('/').where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty) throw const CoreError('UnsafeOpenTarget');
    return Uri(
      scheme: origin.scheme,
      host: origin.host,
      port: origin.port,
      pathSegments: segments,
    );
  }

  // ─────────────────────────── 登录 ───────────────────────────

  /// `POST /api/auth/login {username,password[,otp_code]}` → `data.token`。
  ///
  /// 实测语义：**成功与失败都是 HTTP 200**，差别只在 `code`：
  /// - 200 → 拿到 token；
  /// - 400 `password is incorrect` → 账号或密码错（注意不是 401）；
  /// - 401 `token is invalidated` → 令牌失效（登录阶段一般不会出现）；
  /// - 402 `Invalid 2FA code` → 该账号开了两步验证（TOTP），码缺或错。
  ///
  /// ★ 上一版这里写着「没有验证码、没有 OTP」——**那是错的**，已纠正。
  /// 当时受测账号没开 2FA，于是「这个账号没有」被写成了「这个服务没有」。
  /// 上游 `server/handles/auth.go`（v4.1.10）里明明白白：
  /// `LoginReq.OtpCode string json:"otp_code"`，`user.OtpSecret != ""` 时
  /// `totp.Validate` 失败即回 **402**。所以必须把这个字段发上，
  /// 且 402 要走 `LoginNeedsOTP` 而不是 `LoginRejected`——
  /// 后者会被会话层翻成「账号或密码不正确」，用户反复改密码也进不去。
  ///
  /// 没有 PKCE / 没有浏览器交接：2FA 是随密码一起发的 6 位码，不是 OAuth。
  @override
  Future<LoginOutcome> login({
    required String username,
    required String password,
    String? otpCode,
  }) async {
    _identity = null;
    _token = null;
    // 换账号/重登 ⇒ 必须重新读 base_path：不同账号的可见根可能完全不同。
    _basePath = null;
    _cancel?.check();

    final preparedOtp = (otpCode ?? '').trim();
    final hasOtp = preparedOtp.isNotEmpty;

    _log
      ..i('OpenListAdapter: 开始登录')
      ..i('OpenListAdapter: 目标地址 => ${Logger.safeUrl(_dio.baseUrl)}')
      ..i('OpenListAdapter: 用户名 => $username')
      ..i('OpenListAdapter: 动态码 => ${hasOtp ? "有" : "无"}');

    final Object? body;
    try {
      body = await _request('/api/auth/login', {
        'username': username,
        'password': password,
        // 没码时**不发**这个键：空串会被服务端当作「给了但不对」，
        // 于是「还没要码」和「码错了」在现场就无法区分。
        if (hasOtp) 'otp_code': preparedOtp,
      }, needAuth: false);
    } on AdapterFailure catch (failure) {
      // 登录端点的网络/TLS 失败原样上抛：那不是「密码错」。
      return LoginRejected(failure.message, apiCode: failure.apiCode);
    }

    final envelope = _envelope(body);
    final code = envelope.code;
    final message = envelope.message;

    if (code == 200) {
      final token = _stringField(envelope.data, 'token');
      if (token == null || token.isEmpty) {
        // 服务端说成功却没给令牌：不能假装已登录，否则后面每一步都会 401。
        return const LoginRejected('服务端返回成功但未提供会话令牌，请确认该地址确实是 OpenList。',
            apiCode: 200);
      }
      _token = token;
      // 窄接口要求「同一账号重登必须换一个身份」，毫秒时间戳天然保证每次不同。
      _identity = 'openlist-${DateTime.now().millisecondsSinceEpoch}';
      _log.i('OpenListAdapter: 登录成功');
      return LoginSuccess(identity: _identity!);
    }

    if (code == 402) {
      // 服务端只说「Invalid 2FA code」，不区分「没给」与「给错」。
      // 本次带没带码只有我们知道，用它来判断，别让用户去猜。
      _log.w('OpenListAdapter: 需要两步验证码（本次${hasOtp ? "已带码但被拒绝" : "未带码"}）');
      return LoginNeedsOTP(methods: const ['totp'], rejected: hasOtp);
    }

    return LoginRejected(_loginFailureText(code, message), apiCode: code);
  }

  String _loginFailureText(int? code, String? message) {
    if (code == 400) return '账号或密码不正确';
    if (code == 401) return '登录令牌已失效，请重新登录';
    // 402 由 [login] 直接翻成 LoginNeedsOTP，正常不会走到这里；
    // 留着是为了 `code` 万一从别处传进来时不至于显示一句英文原文。
    if (code == 402) return '这个账号开了两步验证，动态验证码没有被接受';
    if (code == 403) return '该账号被禁止登录这个服务';
    if (code == 429) return '服务器在限流：请求过于频繁，请等几分钟再试';
    final raw = (message ?? '').trim();
    return raw.isEmpty ? '登录失败（服务端未说明原因）' : '登录失败：$raw';
  }

  // ───────────────────────── 共享根 ─────────────────────────

  /// 根下条目超过这个数，就**不再逐个当搜索位置**，只给「整个根」一个位置。
  ///
  /// 判据不是「界面卡不卡」，而是**搜索代价**：每个位置 = 一次预检 + 一次搜索，
  /// 4 路并发下墙钟时间 ≈ `N/4 × RTT`。公网站点单次 RTT 0.3–3 s，
  /// 20 个位置就已经十几秒，50 个以上基本等于不可用。
  static const int _flatRootLimit = 50;

  /// 「整个根」这个合成位置的展示名。只在根下条目多到列不动、或根下没有子目录时出现。
  static const String _wholeRootName = '全部目录';

  /// OpenList 没有「共享」概念：根目录下的各项就是账号可见的存储。
  ///
  /// 这里返回根目录里的**目录**。单个存储不可用（上游网盘失效）不阻断枚举：
  /// 用户需要看到它存在、以及为什么点进去是空的——那比让它凭空消失更有用。
  ///
  /// ★ 两种形态必须分开处理，这是 2026-10-27 那次报障的结论
  ///   （「首页有 N 多文件夹的怎么办」）：
  ///   · 根下十几个存储（常见自建站点）⇒ 整根 + 逐个目录都列，用户按需勾；
  ///   · 根下成百上千个目录（公开资源库，实测某站点 1724 个）⇒ 只给整根。
  ///     平铺 1724 行复选框列不完也勾不完；真勾上则一次搜索要发 3448 个请求。
  ///     而 `parent='/'` + `scope=0` 实测一次覆盖全库（含三级子目录），
  ///     请求数从 3448 降到 2，结果一条不少 —— 收敛不是降级，是正解。
  @override
  Future<List<ShareRoot>> shareRoots() async {
    _cancel?.check();
    _log.i('OpenListAdapter: 枚举根目录（存储列表）');

    // 先只取第一页看 `total`：上千条要翻十几页，连接流程没必要为此白等。
    final total = await _rootEntryCount();
    if (total > _flatRootLimit) {
      _log.i('OpenListAdapter: 根下 $total 项，超过 $_flatRootLimit ⇒ 只提供整根位置');
      return const <ShareRoot>[ShareRoot(name: _wholeRootName, path: '/')];
    }

    final entries = await list('/');
    if (entries.isEmpty) {
      throw const AdapterFailure(
        ErrorKind.emptyScope,
        '登录成功，但根目录下没有任何存储。'
        '请先在 OpenList 网页端添加一个存储，再回来连接。',
      );
    }
    // 根下只有散文件、没有子目录时，「整根」就是唯一能用的位置；
    // 有子目录时也把整根放在首位 —— 它是唯一能「一次搜全部」的位置，
    // 而逐个勾选 N 个位置的代价是 2N 次请求。
    final dirs = entries.where((entry) => entry.isDirectory);
    return <ShareRoot>[
      const ShareRoot(name: _wholeRootName, path: '/'),
      for (final entry in dirs) ShareRoot(name: entry.name, path: _norm(entry.path)),
    ];
  }

  /// 根目录条目总数，**只发一次请求**（`per_page=_pageSize`）。
  ///
  /// 不能直接用 `list('/')` 数长度：那个会按 `total` 翻页取全，上千条要十几次
  /// 往返。这里只需要判断「是不是多到列不动」，第一页信封里的 `total` 就够；
  /// 少数老版本不回 `total` 时退化成「第一页的条数」，判据依然成立。
  Future<int> _rootEntryCount() async {
    final Object? body;
    try {
      body = await _request('/api/fs/list', {
        'path': '/',
        'password': '',
        'page': 1,
        'per_page': _pageSize,
        'refresh': false,
      });
    } on AdapterFailure catch (failure) {
      throw _asListFailure(failure, '/');
    }
    final envelope = _envelope(body);
    _throwIfFailed(envelope, action: '列目录', path: '/');
    final data = envelope.data;
    return _intField(data, 'total') ?? _listField(data, 'content').length;
  }

  // ───────────────────────── 列目录 ─────────────────────────

  /// `POST /api/fs/list {path,page,per_page,refresh}`，按 `total` 翻页取全。
  ///
  /// 两类 `code=500` 必须分开报（见文件头第 6 条）。
  @override
  Future<List<FileItem>> list(String path) async {
    _cancel?.check();
    final target = _norm(path.isEmpty ? '/' : path);
    _log.d('OpenListAdapter: list => $target');

    final out = <FileItem>[];
    var page = 1;
    while (page <= _maxPages) {
      _cancel?.check();
      final Object? body;
      try {
        body = await _request('/api/fs/list', {
          'path': target,
          'password': '',
          'page': page,
          'per_page': _pageSize,
          'refresh': false,
        });
      } on AdapterFailure catch (failure) {
        throw _asListFailure(failure, target);
      }

      final envelope = _envelope(body);
      _throwIfFailed(envelope, action: '列目录', path: target);
      final data = envelope.data;
      final content = _listField(data, 'content');
      for (final item in content) {
        final converted = _toFileItem(item, parent: target);
        if (converted != null) out.add(converted);
      }

      final total = _intField(data, 'total');
      if (content.isEmpty) break;
      if (total == null || out.length >= total) break;
      page++;
    }
    return out;
  }

  /// 把列目录的传输层失败翻成「路径不存在」还是「上游存储失效」。
  AdapterFailure _asListFailure(AdapterFailure failure, String path) {
    if (failure.kind == ErrorKind.pathMissing) return failure;
    return failure;
  }

  // ───────────────────────── 搜索 ─────────────────────────

  /// 逐 root 用 `scope=0` 检索后合并。
  ///
  /// **`scope` 的语义是上游写死的，不能凭字面猜**（上游 `internal/model/search.go`）：
  ///     0 = 全部   1 = 仅目录   2 = 仅文件
  /// 落在查询里就是 `internal/db/searchnode.go` 的
  ///     if req.Scope != 0 { isDir := req.Scope == 1; … WHERE is_dir = isDir }
  ///
  /// ★ 1.1.11 及之前这里写的是 `scope=1`，于是真机上**只能搜到文件夹、搜不到文件**。
  ///   当时注释写的理由是「scope=0 会带回已删除存储的死链」——那个观察本身没错
  ///   （全盘 `parent='/'` 时确实有 71% 落在已删存储上），但**结论错了**：
  ///   死链是靠下面两件事挡住的，跟 scope 无关：
  ///     · 逐 root 发请求，且上游 `whereInParent` 用 `parent LIKE 'X/%'` 做前缀限定；
  ///     · 每个 root 先过 `_ensureRootUsable`，上游失效的存储直接跳过。
  ///   用 scope 去挡死链，代价是砍掉了全部文件结果 —— 得不偿失。
  ///
  /// 空查询直接拒绝：实测空 `keywords` 返回全站 80315 条。
  @override
  Future<List<FileItem>> search(
    String query, {
    required List<String> roots,
    void Function(RootSearchFailure failure)? onRootFailure,
  }) async {
    _cancel?.check();
    final keyword = query.trim();
    if (keyword.isEmpty) {
      throw const AdapterFailure(
        ErrorKind.unsupportedQuery,
        '搜索词不能为空：这个服务在关键字为空时会返回全部文件。',
      );
    }
    if (roots.isEmpty) {
      throw const AdapterFailure(
        ErrorKind.scopeUnset,
        '还没有选择这台 OpenList 的搜索位置。',
      );
    }

    // 两个坐标系换算一次就够（缓存在适配器里）；读不到按「无前缀」处理。
    final base = await _ensureBasePath();

    // ★ 多个 root **并发**搜，不再一个一个排队。
    //
    // 2026-10-27 报障「索引路径较多时搜索很慢」：原实现是 for 循环串行，
    // 每个 root 先 `_ensureRootUsable`（一次 list）再 search —— **2×N 个请求全串行**。
    // 公网站点单次 RTT 就有 0.2–3 s，10 个存储要等十几到几十秒。
    // 这里并发 + 预检与搜索并行发（两者互不依赖），同样的请求数，墙钟时间按并发度下降。
    final outcomes = List<_RootOutcome?>.filled(roots.length, null);
    var cursor = 0;

    Future<void> worker() async {
      while (true) {
        final index = cursor++;
        if (index >= roots.length) return;
        _cancel?.check();
        outcomes[index] = await _searchRoot(keyword, _norm(roots[index]), base);
      }
    }

    await Future.wait([
      for (var i = 0; i < _rootConcurrency && i < roots.length; i++) worker(),
    ]);

    // ★ 合并按 **roots 原顺序**做：并发只改等待方式，不改结果顺序。
    // 去重也放在这里一次性做，避免多个 worker 抢同一个 Set 造成不确定顺序。
    final seen = <String>{};
    final results = <FileItem>[];
    AdapterFailure? firstFailure;
    var searchedRoots = 0;

    for (final outcome in outcomes) {
      if (outcome == null) continue;
      final failure = outcome.failure;
      if (failure != null) {
        firstFailure ??= failure;
        // ★ 一个根没搜通就**上报一条**，不许静静丢掉。
        //
        // 「有别的根搜通了」只能决定**不抛异常**（那部分结果仍然有效），
        // 不能决定不报：上层拿到这些记录才知道「哪几个位置没搜」，
        // 从而把这次结果说成「不完整」，而不是「没有找到」。
        onRootFailure?.call(RootSearchFailure(root: outcome.root, failure: failure));
        _log.w('OpenListAdapter: root ${outcome.root} 搜索失败 => ${failure.kind}');
        continue;
      }
      searchedRoots++;
      for (final item in outcome.items) {
        if (seen.add(item.path)) results.add(item);
      }
    }

    // ★ 只有**所有 root 都没搜通**时，那次失败才是本次搜索的真实结果，才抛出去。
    //
    // 部分根失败的情形由 `onRootFailure` 交给上层：结果照常返回，
    // 但那次搜索必须被标记成「不完整」——否则「有一个存储坏了」
    // 会被界面说成「全都没有找到」，而用户根本看不出有一个位置没搜过。
    if (searchedRoots == 0 && firstFailure != null) {
      throw firstFailure;
    }
    return results;
  }

  /// 单个 root：预检与搜索**并行**发，两者都回来后按「以预检为准」判定。
  ///
  /// 预检存在的理由见 [search]：搜索只查索引、列目录才碰上游，
  /// 「索引里有、实际读不了」的存储必须挡掉，否则用户拿到一堆点不开的死链。
  /// 但它和搜索互不依赖 —— 串起来只是白等一个 RTT。
  Future<_RootOutcome> _searchRoot(String keyword, String parent, String base) async {
    final items = <FileItem>[];
    final usable = _ensureRootUsable(parent);
    final searching = _searchOneRoot(keyword, parent, base, items);

    AdapterFailure? failure;
    try {
      await usable;
    } on AdapterFailure catch (error) {
      failure = error;
    }
    try {
      await searching;
    } on AdapterFailure catch (error) {
      failure ??= error;
    }
    return _RootOutcome(parent, items, failure);
  }

  /// 轻量确认一个目录/存储可读（`per_page=1` 只取一条）。
  ///
  /// 存在意义见 [search] 里的注释：搜索走索引、列目录走上游，两者可能一个成功
  /// 一个失败。**以列目录的结果为准**——索引里有但列不出来的，就是打不开的。
  Future<void> _ensureRootUsable(String path) async {
    final body = await _request('/api/fs/list', {
      'path': path,
      'password': '',
      'page': 1,
      'per_page': 1,
      'refresh': false,
    });
    _throwIfFailed(_envelope(body), action: '检查搜索位置', path: path);
  }

  /// 读账号的 `base_path`。失败不致命：按 `/` 处理（老版本/网关改写都没有这个字段）。
  Future<String> _ensureBasePath() async {
    final cached = _basePath;
    if (cached != null) return cached;

    var base = '/';
    try {
      final response = await _dio.get<dynamic>(
        '/api/me',
        options: Options(
          headers: <String, dynamic>{
            'accept': 'application/json',
            if (_token != null) 'authorization': _token!,
          },
          responseType: ResponseType.json,
        ),
      );
      final envelope = _envelope(response.data);
      if (envelope.code == 200) {
        final raw = _stringField(envelope.data, 'base_path');
        if (raw != null && raw.trim().isNotEmpty) base = _norm(raw);
      }
    } on DioException catch (error) {
      _log.w('OpenListAdapter: 读取 base_path 失败，按 / 处理 => ${error.type}');
    }
    _basePath = base;
    _log.i('OpenListAdapter: 账号 base_path => $base');
    return base;
  }

  /// 存储侧绝对路径 → 客户端坐标。返回 null 表示这条不在本会话可见范围内。
  ///
  /// `base == '/'` 时服务端本来就用客户端坐标，原样返回。
  static String? _clientPath(String serverPath, String base) {
    if (base.isEmpty || base == '/') return serverPath;
    if (serverPath == base) return '/';
    if (serverPath.startsWith('$base/')) return serverPath.substring(base.length);
    return null;
  }

  Future<void> _searchOneRoot(
      String keyword, String parent, String base, List<FileItem> results) async {
    var page = 1;
    var dropped = 0;
    while (page <= _maxPages) {
      _cancel?.check();
      final Object? body;
      try {
        body = await _request('/api/fs/search', {
          'parent': parent,
          'keywords': keyword,
          // 0 = 全部（文件 + 目录）。写成 1 就只剩目录，写成 2 就只剩文件；
          // 语义见 [search] 的注释，别照字面猜。
          'scope': 0,
          'page': page,
          'per_page': _pageSize,
          'password': '',
        });
      } on DioException catch (error) {
        throw _translate(error, '搜索');
      }

      final envelope = _envelope(body);
      _throwIfFailed(envelope, action: '搜索', path: parent);
      final data = envelope.data;
      final content = _listField(data, 'content');
      for (final item in content) {
        // ★ 结果项自带的是**存储侧绝对路径**（可能带 base_path 前缀）。
        // 不换算就会落到授权根之外，上层判 ScopeDenied（见 `_basePath` 的说明）。
        final serverParent = _norm(_stringField(item, 'parent') ?? parent);
        final mapped = _clientPath(serverParent, base);
        if (mapped == null) {
          // 不在本会话可见范围内（别的账号/别的游客根）：不是「失败」，是看不见。
          dropped++;
          continue;
        }
        final converted = _toFileItem(item, parent: mapped);
        if (converted == null) continue;
        results.add(converted);
      }

      final total = _intField(data, 'total');
      if (content.isEmpty) break;
      if (total == null || (page * _pageSize) >= total) break;
      page++;
    }
    if (dropped > 0) {
      _log.w('OpenListAdapter: root $parent 有 $dropped 条结果不在本账号可见范围内，已丢弃');
      // ★ 一条都没换算出客户端坐标 ⇒ 不是「没找到」，而是这个 root 的返回
      //   整体落在账号可见范围之外（base_path 与配置的位置对不上）。
      //   静默返回空会被界面说成「没有找到」，必须报成范围错误。
      if (results.isEmpty) {
        throw AdapterFailure(
          ErrorKind.scopeDenied,
          '这个位置返回的结果都不在账号可见范围内（账号基准路径与位置不匹配）。',
        );
      }
    }
  }

  // ─────────────────────────── 登出 ───────────────────────────

  /// 令牌没有服务端注销端点（实测无 `/api/auth/logout` 可用语义），
  /// 故只清本地状态。令牌是会话态、不落盘，清掉即等于失效于本机。
  @override
  Future<void> logout() async {
    _token = null;
    _identity = null;
    _basePath = null;
    _log.i('OpenListAdapter: 已清除会话状态');
  }

  // ─────────────────────── 传输与响应解包 ───────────────────────

  /// 统一请求。返回已解码的**整个信封**（`{code,message,data}`）。
  ///
  /// 只把传输层错误抛成 `AdapterFailure`；业务码交给调用方按语义处理，
  /// 因为同一个 `code` 在登录与列目录两处的含义并不相同。
  Future<Object?> _request(String path, Map<String, Object?> payload,
      {bool needAuth = true}) async {
    final headers = <String, dynamic>{
      'accept': 'application/json',
      // 实测：服务端不校验 `Bearer` 前缀，原样放令牌即可（与网页端行为一致）。
      if (needAuth && _token != null) 'authorization': _token!,
    };
    try {
      final response = await _dio.post<dynamic>(
        path,
        data: payload,
        options: Options(headers: headers, responseType: ResponseType.json),
      );
      return response.data;
    } on DioException catch (error) {
      throw _translate(error, '请求 $path');
    }
  }

  AdapterFailure _translate(DioException error, String action) {
    // 取消要原样保真，不能被说成网络故障。
    if (error.type == DioExceptionType.cancel) {
      return const AdapterFailure(ErrorKind.cancelled, '这次搜索已取消');
    }
    final embedded = error.error;
    if (embedded is CoreError && embedded.kind.isNotEmpty) {
      return AdapterFailure(embedded.kind, embedded.reason ?? embedded.kind);
    }
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return AdapterFailure(ErrorKind.timedOut, '$action 超时：服务端没有响应');
      case DioExceptionType.badCertificate:
        return AdapterFailure(ErrorKind.tlsRejected,
            'TLS 握手失败：这个地址的证书不被信任，或端口不对');
      case DioExceptionType.connectionError:
        return AdapterFailure(ErrorKind.networkFailure, '$action 时无法连接到服务');
      case DioExceptionType.badResponse:
        final status = error.response?.statusCode;
        // 与业务错误不同，HTTP 层真的非 2xx 时按状态码分类。
        if (status == 401 || status == 403) {
          _identity = null;
          return AdapterFailures.sessionExpired(status);
        }
        if (status == 429) {
          return const AdapterFailure(ErrorKind.rateLimited,
              '服务器在限流：请求过于频繁，请等几分钟再试', apiCode: 429);
        }
        if (status != null && status >= 300 && status < 400) {
          return AdapterFailures.protocolViolation(
              '服务端要求重定向（HTTP $status），已拒绝跟随；请检查地址是否指向了登录门户');
        }
        return AdapterFailure(ErrorKind.httpFailure, '$action 收到 HTTP $status',
            apiCode: status);
      case DioExceptionType.cancel:
        return const AdapterFailure(ErrorKind.cancelled, '这次搜索已取消');
      case DioExceptionType.unknown:
        return AdapterFailure(ErrorKind.networkFailure, '$action 失败：${error.message}');
    }
  }

  /// 业务码失败 → `AdapterFailure`。**这是本适配器唯一的分诊点**：
  /// 所有业务错误都是 HTTP 200，只能从 `code` + `message` 判断。
  void _throwIfFailed(_Envelope envelope, {required String action, required String path}) {
    final code = envelope.code;
    if (code == 200) return;

    if (code == 401) {
      // 「token is invalidated」：会话过期（改密码也会导致）。
      _identity = null;
      _token = null;
      throw AdapterFailures.sessionExpired(code);
    }
    if (code == 403) {
      throw AdapterFailures.permissionDenied('该账号没有这个位置的权限', code);
    }
    if (code == 404) {
      throw AdapterFailures.pathMissing('$path 不存在：这个目录可能已被移动或删除');
    }
    if (code == 429) {
      throw const AdapterFailure(ErrorKind.rateLimited,
          '服务器在限流：请求过于频繁，请等几分钟再试', apiCode: 429);
    }
    if (code == 500) {
      final message = envelope.message ?? '';
      // 两类 500 语义相反，必须分开（文件头第 6 条）。
      if (message.contains('failed get storage')) {
        throw AdapterFailures.pathMissing(
            '这个存储已经不在 OpenList 上了（$path）。'
            '搜索索引里可能还留着它的旧记录——请在网页端确认该存储是否被删除。');
      }
      if (message.contains('failed to list objs')) {
        throw AdapterFailure(
          ErrorKind.apiError,
          '这个存储的上游网盘授权已失效（$path），与你的 OpenList 账号密码无关。'
          '请到 OpenList 网页端重新授权该存储。',
          apiCode: 500,
        );
      }
      throw AdapterFailure(ErrorKind.apiError, '$action 失败：服务端报错（$path）',
          apiCode: 500);
    }
    final raw = (envelope.message ?? '').trim();
    throw AdapterFailure(
      ErrorKind.apiError,
      raw.isEmpty ? '$action 失败（服务端码 $code）' : '$action 失败：$raw',
      apiCode: code,
    );
  }

  // ─────────────────────── 数据形状 ───────────────────────

  _Envelope _envelope(Object? body) {
    if (body is! Map) {
      // 返回 HTML 登录页 / 反代错误页时就是这个现象，不能说成「没有结果」。
      throw AdapterFailures.protocolViolation(
          '服务端返回的不是 OpenList 的接口数据（可能被反向代理或登录门户拦截了）');
    }
    return _Envelope(
      code: _intField(body, 'code'),
      message: _stringField(body, 'message'),
      data: body['data'],
    );
  }

  /// 条目 → `FileItem`。
  ///
  /// 结果项来自搜索时**自带 `parent`**；来自列目录时没有，由调用方传入。
  /// 两种情况都要拼出完整路径，且不能出现 `//`。
  FileItem? _toFileItem(Object? raw, {String? parent}) {
    if (raw is! Map) return null;
    final name = _stringField(raw, 'name');
    if (name == null || name.isEmpty) return null;

    final isDir = raw['is_dir'] == true;
    // 目录的 size 服务端给的是元数据大小（实测 626709 之类），不是内容大小 ⇒
    // 目录一律标成「大小未知」，避免界面上出现一个像容量又不是容量的数字。
    final rawSize = _intField(raw, 'size');
    final sizeKnown = !isDir && rawSize != null;
    final size = isDir ? 0 : (rawSize ?? 0);

    final parentPath = parent ?? _stringField(raw, 'parent') ?? '';
    final fullPath = _join(parentPath, name);

    return FileItem(
      name: name,
      path: fullPath,
      isDirectory: isDir,
      size: size,
      sizeKnown: sizeKnown,
      // 服务端不提供修改时间（实测字段只有 5 个）⇒ 保持 null，不拿别的值冒充。
      modifiedTime: null,
      createdTime: null,
      mimeType: null,
      extension: isDir ? null : PathCompat.extension(name),
      isHidden: name.startsWith('.'),
    );
  }

  // ─────────────────────── 小工具 ───────────────────────

  static String _norm(String path) {
    var p = path.trim();
    if (p.isEmpty) return '/';
    if (!p.startsWith('/')) p = '/$p';
    while (p.length > 1 && p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }

  static String _join(String parent, String name) {
    final base = _norm(parent);
    final clean = name.startsWith('/') ? name.substring(1) : name;
    return base == '/' ? '/$clean' : '$base/$clean';
  }

  static int? _intField(Object? map, String key) {
    if (map is! Map) return null;
    final value = map[key];
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  static String? _stringField(Object? map, String key) {
    if (map is! Map) return null;
    final value = map[key];
    return value is String ? value : null;
  }

  static List<Object?> _listField(Object? map, String key) {
    if (map is! Map) return const [];
    final value = map[key];
    return value is List ? value : const [];
  }
}

/// `{code, message, data}` 信封。实测所有接口都用这个形状。
class _Envelope {
  const _Envelope({required this.code, required this.message, required this.data});
  final int? code;
  final String? message;
  final Object? data;
}

/// 一个 root 的搜索产物：成功时 `failure == null`，`items` 可直接并入总结果。
class _RootOutcome {
  const _RootOutcome(this.root, this.items, this.failure);
  final String root;
  final List<FileItem> items;
  final AdapterFailure? failure;
}
