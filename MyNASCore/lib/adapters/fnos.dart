// 飞牛 fnOS 品牌适配器。
//
// ── 契约来源 ────────────────────────────────────────────────────────
// 与 openlist.dart 不同，这里**不是**照抄上游实现，而是三份证据交叉验证：
//   1. 飞牛官方端点文档：`github.com/fnnas-labs/fnos-cli-skill`
//      （`skills/fnos-cli/reference/` 下 file.md / oauth.md / user.md 等 17 个模块）
//   2. 官方 CLI（`@fnnas-labs/fnos-cli` 0.5.1，MIT）的行为与二进制常量
//   3. 2026-10-28 晚在本机对真实设备（nas.example.net，fnOS，uid 1000）的直连实测
// 第 3 条是决定性的：所有端点的请求/响应形状都在那一轮里量过，不是推测。
//
// ── 实测出来的六条硬约束（每条都对应一个坑）─────────────────────────
// 1. **官方协议没有账号密码登录**。`user.md` 原话：「不使用 NAS 用户名密码、
//    2FA 登录或旧 token 恢复链」。唯一的路是 OAuth 2.0 Authorization Code +
//    PKCE，而且**授权 URL 里没有 `redirect_uri`** ⇒ 授权页不回跳，
//    一次性 code 只能由用户从页面上抄下来交给客户端。
//    这就是 `LoginNeedsAuthorizeCode` 存在的唯一理由。
// 2. **一次请求只能带一个 path**。`path:["vol1/1000","vol2/1000"]` 实测
//    7.7s 后报 `failed to read HTTP proxy response`，100% 复现；单 path 100% 成功。
//    ⇒ 逐卷各发一次，绝不能把多个位置塞进同一个请求。
// 3. ★ **不带 `path` 会全盘搜索**。实测缺 `path` 时返回 671KB（全库）。
//    这和 OpenList 空关键字返回全站是同一类陷阱 ⇒ 请求前必须确认 path 非空。
// 4. **无效路径静默返回 0 条**。搜索对不存在的路径回 `result:succ` 且无 `data`，
//    与「真的没有匹配」不可区分。⇒ 卷根可用性必须用 `file.ls` 预检
//    （它会对坏路径明确回 `errno`），不能靠搜索自己证明。
// 5. **响应是 JSON 数组**，不是单个对象。搜索的多包形态是
//    `[{data:[400 条]}, {data:[200]}, …]`，最后一包可能只有 101 条；
//    **把所有元素的 `data` 拼起来才是全集**（实测 12 个元素拼出 2711 条，
//    与飞牛客户端「2000 多条」对得上）。只读第一个元素会少给一个数量级
//    —— 官方 CLI 的 `raw` 子命令正是这么干的（只回 101 条）。
// 6. **refresh 之后旧 access token 立即失效**。实测：刷新拿到新 token 后，
//    用旧 token 打任何端点都回 401 `AUTH_INVALID_TOKEN`。
//    ⇒ 刷新与「使用」必须原子，不能缓存旧值再慢慢换。
//
// ── 已知限制（写在 capabilities.notes 里，不掩盖）───────────────────
// · `file.ls` 返回项**没有 size**（实测字段只有 btim/dir/mtim/name/uid）⇒
//   列目录得到的大小一律 `sizeKnown:false`，不拿 0 冒充「空文件」。
//   搜索结果项有 `size`，那条路照常给。
// · 搜索结果由服务端返回时**不排序**（实测前 20 条年份混杂 2023/24/25）⇒
//   排序全部由客户端的四层排序负责，适配器不假装有相关度。
// · 单次搜索上限实测 5010 条（`.` 与 `1` 都封顶 5010），且**没有分页参数**；
//   5010 以内一次全量返回，因此「200 第一批 + 继续搜索」在客户端侧成立。
// · 偶发「成功但 0 条」的假空（早期观测，10+ 次连跑未复现）⇒ 未做重试，
//   若要重试应由上层判定，不要在这里静默重发（会掩盖真实空结果）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../adapter_contract.dart';
import '../adapter_support.dart';
import '../dio_compat.dart';
import '../error_kinds.dart';
import '../protocol.dart';
import '../sha256.dart';
import '../upstream_file_types.dart';
import '../zip_extract.dart';

/// 官方 CLI 使用的 OAuth 公共客户端 id。
///
/// 它不是秘密：官方文档 `reference/oauth.md` 第一行就写死了这个值，
/// 任何第三方按文档接入都用它。**但 `device_name` 要用我们自己的**
/// （见 [_deviceName]）——复用 client id 是照文档办事，冒充 `trim-cli`
/// 这个设备名则不是。
const String _clientId = 'YJNMPJUGA9';

/// 闪寻运行**必需**的 scope（2026-10-29 审查：原先全量申请 11 项，索取得太多）。
///
/// 逐项对应实际调用：
///   * `trim.user.all` —— 登录后立刻取 `user.info`（拿 uid 与用户名，卷根要用）；
///   * `trim.file.read` —— `file.ls` / 服务端搜索 / `file.share.list`+`info`
///     （SMB 共享名映射）；
///   * `trim.download.all` —— 换下载票据（右键「下载」两项）。
/// 这三项缺一不可，在授权弹窗里锁定勾选。
const List<String> _requiredScopes = [
  'trim.user.all',
  'trim.file.read',
  'trim.download.all',
];

/// 文档里列出的其余 scope：**默认不申请**，由用户在授权弹窗里逐项勾选。
///
/// 不勾就不进授权地址 —— 授权页上根本不会出现，而不是授权完再解释。
const List<({String id, String label})> _optionalScopes = [
  (id: 'trim.file.write', label: '文件写入（闪寻不会写入你的文件）'),
  (id: 'trim.appcenter.all', label: '应用中心'),
  (id: 'trim.photo.all', label: '照片'),
  (id: 'trim.baidu_netdisk.all', label: '百度网盘'),
  (id: 'trim.system.all', label: '系统管理'),
  (id: 'trim.log.all', label: '日志'),
  (id: 'trim.storage.all', label: '存储空间管理'),
  (id: 'trim.docker.all', label: 'Docker'),
];

/// 设备名/型号：出现在飞牛后台的「登录设备」列表里。
/// 必须是闪寻自己的名字，否则用户在设备列表里看到的会是一个他从未装过的程序。
const String _deviceName = '闪寻';
const String _deviceModel = 'FlashFind for macOS';

/// 设备标识。稳定值，用于服务端区分设备。
const String _deviceId = 'flashfind-macos-0000000000000001';

/// 一次性授权码的有效期。官方文档写的是 5 分钟。
const Duration _authorizeCodeTTL = Duration(minutes: 5);

/// 逐卷搜索的并发度。
///
/// 2 而不是更高：设备侧是 J1900 + 4GB 跑 `finder_service`，
/// 实测单卷 2711 条约 1.9s；两卷串行约 3.8s，并发 2 可压到约 2.0s。
/// 再往上加只会让这台机器更慢（CPU 是瓶颈，不是网络）。
const int _rootConcurrency = 2;

/// 探测卷根的编号上限。
///
/// 真实设备上试到 3 就停了（vol1/vol2 存在，vol3 报 errno 65280）。
/// 留 8 是给多盘位机型余量；每多试一个只多一次 `file.ls`。
const int _maxVolumeProbe = 8;

/// 飞牛 fnOS 适配器。
class FnOSAdapter
    implements
        NasBrandAdapter,
        SessionSecretProviding,
        DownloadableAdapter,
        SmbShareResolving,
        WebOpenableAdapter,
        SignedInAccountProviding,
        AuthorizationScopeCatalog {
  FnOSAdapter({required Dio dio}) : _dio = dio;

  final Dio _dio;
  Cancellation? _cancel;
  final Logger _log = Logger();

  String? _identity;

  /// SMB 共享表（`shareRoots()` 时取一次，会话内不变）。
  ///
  /// `storagePath` 是共享对应的存储路径（如 `vol2/1000/备份`，**不带**前导
  /// 斜杠，与 `file.share.list` 的返回一致）；`name` 是 SMB 共享名
  /// （`file.share.info` 的 `shareName`，实测等于末段，但字段独立存在，
  /// 管理员可以起别名 —— 所以必须问，不能拼）。
  final List<({String storagePath, String name})> _smbShares = <({String storagePath, String name})>[];

  /// 本次会话是否**已经问过一次**共享表（问出来是空也算问过）。
  ///
  /// 用途只有一个：搜索前兜一次底（见 [_ensureSmbShares]）。会话建立时
  /// 已经刷过一次，正常不会用到；用到就是「又有某条建立路径忘了刷」，
  /// 那时宁可在第一次搜索上多花一次往返，也不要整台设备都只能开网页。
  bool _smbSharesLoaded = false;

  /// 会话令牌。**只在内存里**：属会话态，不落盘、不进日志。
  String? _accessToken;
  String? _refreshToken;
  DateTime? _accessTokenExpiresAt;

  /// 交给上层保管的那一串东西：**refresh token**，不是密码（飞牛没有密码）。
  ///
  /// 上层把它存进本机凭据槽位，下次 `login(password: <它>)` 原样回传，
  /// 由 [login] 走续期分支直接恢复会话。见 `SessionSecretProviding` 的说明：
  /// 没有这条通道，用户每次启动 App 都得再去浏览器授权一遍。
  @override
  String? get sessionSecret => _refreshToken;

  /// 当前账号 uid。卷根路径 `vol{n}/{uid}` 要用它。
  int? _uid;

  /// 设备侧账号名（`user.info` 的 `userInfo.user`）。
  ///
  /// ★ 它存在的唯一理由是**打开链认亲**：飞牛的来源配置里没有账号字段
  ///   （OAuth 授权码登录），而本机 SMB 挂载带着登录账号。没有它，
  ///   「这台 Mac 上挂的就是这台 NAS 的这个共享」这条判据永远拿不到证据，
  ///   双击结果只能打开登录网页（2026-10-29 真机报障）。
  String? _signedInUser;

  @override
  String? get signedInAccount => _signedInUser;

  /// 会话一成立就把打开链要用的两样东西备齐：**设备账号** 与 **SMB 共享表**。
  ///
  /// ★★ 2026-10-29 真机二次报障（`openFallback` 写着
  ///   `deviceAccountKnown:false, rowHasSMBTarget:false`）：这两样原来只在
  ///   `shareRoots()` 里准备，而重启 App 走的是 refresh token 续期
  ///   （`_restoreFromSavedToken`），**根本不经过 `shareRoots()`**。
  ///   于是「自动重连成功」之后账号恒 null、共享表恒空，
  ///   `smbShareFor()` 一律返回 null ⇒ 结果行没有 SMB 目标 ⇒ 开登录网页。
  ///
  /// 判据：**会话恢复 ≠ 会话可用**。凡是「只有会话建立那一刻才拿得到」的
  /// 东西，三条建立路径（授权码登录 / 令牌续期 / 列位置）必须都备，
  /// 否则就变成「只有第一次连的那一回能用」。
  ///
  /// 不抛：共享表只是打开链的一路，列不出来退网页，不能把会话搞坏。
  /// 取消例外（`_refreshSmbShares` 自己会穿透）。
  Future<void> _absorbSessionIdentity(Map? userInfo) async {
    final user = _stringField(userInfo, 'user');
    // 空串当没拿到：拿空串去比只会得到「谁都不匹配」的假结论。
    _signedInUser = (user != null && user.isNotEmpty) ? user : null;
    await _refreshSmbShares();
  }

  /// 第一段生成、第二段要用的 PKCE verifier。
  ///
  /// 必须跨两次 `login` 调用存活：界面拿到授权地址后，用户去浏览器操作，
  /// 回来时调的是**另一次** login。放在适配器实例上而不是方法局部变量，
  /// 正因为这两次调用之间隔着用户操作。
  String? _pendingVerifier;
  DateTime? _pendingIssuedAt;

  /// 界面勾选的可选 scope（默认空：只申请必需项）。
  List<String> _requestedOptionalScopes = const <String>[];

  @override
  List<AuthorizationScopeOption> get authorizationScopes => [
    for (final id in _requiredScopes)
      AuthorizationScopeOption(id: id, label: _requiredScopeLabel(id), required: true),
    for (final o in _optionalScopes)
      AuthorizationScopeOption(id: o.id, label: o.label, required: false),
  ];

  @override
  set requestedOptionalScopes(List<String> ids) {
    final known = _optionalScopes.map((o) => o.id).toSet();
    _requestedOptionalScopes = ids.where(known.contains).toList();
  }

  /// 授权地址里实际携带的 scope 串：必需项 + 界面勾选的可选项。
  String get _requestedScope =>
      [..._requiredScopes, ..._requestedOptionalScopes].join(' ');

  String _requiredScopeLabel(String id) => switch (id) {
    'trim.user.all' => '账号信息（读取当前账号，用于定位你的存储空间）',
    'trim.file.read' => '文件读取（搜索、列目录、识别 SMB 共享）',
    'trim.download.all' => '文件下载（右键「下载」两项）',
    _ => id,
  };

  // ─────────────────────── 窄接口的表面 ───────────────────────

  @override
  String get vendor => 'fnos';

  @override
  String? get sessionIdentity => _identity;

  @override
  set cancellation(Cancellation token) {
    _cancel = token;
    _dio.cancellation = token;
  }

  @override
  BrandCapabilities get capabilities => const BrandCapabilities(
    nativeSearch: true,
    // ★ 适配器代码本身**还没在真机上跑过**（端点契约是在真机上量过的，
    //   但那是用 Python 直连验的，不是这个 Dart 实现）。按契约如实写 false。
    verifiedOnDevice: false,
    querySemantics:
        '服务端文件名索引搜索（appcgi.finder.fileSearch）：只匹配文件名，'
        '按存储空间逐卷各发一次；不递归遍历目录、不读文件内容、不做全盘搜索。',
    notes:
        '端点契约于 2026-10-28 在真实设备（fnOS，uid 1000）直连实测：'
        '搜索按卷根发一次即覆盖全部子目录（2711 条命中 1189 个父目录）；'
        '响应是多包 JSON 数组，拼接全部 data 才是全集；单次上限 5010 条且无分页；'
        '结果自带 mtim/btim/size/dir，客户端排序可用；'
        '服务端不排序、无相关度分数；无效路径静默返回 0 条（与「没有匹配」不可区分）。'
        '登录走 OAuth 2.0 授权码 + PKCE，官方协议不支持账号密码；'
        '授权页不回跳，code 需用户手动交出。'
        '尚未真机验证的部分：这个 Dart 适配器本身、授权码交换的端到端。'
        '打开链（2026-10-29 用户定）：SMB（445 可达时，共享名走 share.list/info 映射，'
        '映射规则待真机终验）> 网页（只到站点桌面，飞牛没有能定位到文件的网页地址）> '
        '下载只作右键选项：multiple-download 拿 token → GET 拉 zip 包'
        '（**单文件也打包**）→ 客户端解包；Range 被服务端无视，不支持断点。',
  );

  /// SMB 是打开链的第一优先（445 可达时），**但共享名必须走映射**。
  ///
  /// 旧版本这里一度说 false（当时以为第三段就是共享名，后来实测证伪），
  /// 现在回 true 的前提是：`smbShareFor` 用 `file.share.list` + `file.share.info`
  /// 做前缀映射，解析不出就返回 null —— `BrandSession` 拿到 null 会退网页，
  /// 绝不会拿 `vol2` 这种卷号去冒充共享名。
  @override
  bool get exposesSMBShares => true;

  // ─────────────────────────── 登录 ───────────────────────────

  /// 两段式 OAuth 授权。
  ///
  /// 第一段（`authorizeCode` 为空）：生成 PKCE verifier + challenge，
  /// 拼出授权地址返回 `LoginNeedsAuthorizeCode`，**不碰网络**。
  /// 用户拿这个地址去浏览器登录、点授权，页面上显示一串一次性 code。
  ///
  /// 第二段（`authorizeCode` 非空）：拿 code + verifier 换 token。
  ///
  /// ★ 为什么第一段不发任何请求：授权 URL 是本地拼出来的（官方 CLI 的
  /// `login --authorize-only` 也是对同一个 `/signin` 端点拼参数），
  /// 先发一次「申请」请求纯属多余，还多一个失败点。
  @override
  Future<LoginOutcome> login({
    required String username,
    required String password,
    String? otpCode,
    String? authorizeCode,
  }) async {
    _cancel?.check();
    final code = (authorizeCode ?? '').trim();

    if (code.isEmpty) {
      // ★ 先试「用上次存下的 refresh token 直接续期」。
      //
      // 凭据槽位里存的不是密码（飞牛没有密码），是上一次登录换来的 refresh token，
      // 由上层在登录成功后照 `sessionSecret` 原样存下、下次填进 `password` 送回来。
      // 没有这一步，用户每次启动 App 都要再去浏览器授权一遍 —— 而这正是
      // 「mac 上最快速」最不能接受的那种摩擦，也违反「不改用户习惯」。
      //
      // 续期失败**不是终局**：令牌被吊销、换了账号、服务端清了会话都会走到这里。
      // 这时不能报「登录失败」把用户堵在门外，而要退回第一段重新产出授权地址，
      // 让他再授权一次——那才是这条协议下唯一能自救的动作。
      final saved = password.trim();
      if (saved.isNotEmpty) {
        final restored = await _restoreFromSavedToken(saved);
        if (restored != null) return restored;
      }
      // 第一段：只产出授权地址。
      final verifier = _newCodeVerifier();
      _pendingVerifier = verifier;
      _pendingIssuedAt = DateTime.now();
      final url = _authorizationUrl(verifier);
      _log.i('FnOSAdapter: 生成授权地址，等待用户交出授权码');
      return LoginNeedsAuthorizeCode(authorizationUrl: url, validFor: _authorizeCodeTTL);
    }

    // 第二段：换 token。
    final verifier = _pendingVerifier;
    if (verifier == null) {
      // 没有 verifier 就换不了：PKCE 的 challenge 是它算出来的。
      // 常见于「换了账号/重启后直接粘 code」——必须重新生成地址。
      return const LoginRejected('授权流程已过期，请重新获取授权链接');
    }
    final issuedAt = _pendingIssuedAt;
    if (issuedAt != null && DateTime.now().difference(issuedAt) > _authorizeCodeTTL) {
      _pendingVerifier = null;
      return const LoginRejected('授权码已超过 5 分钟有效期，请重新获取授权链接');
    }

    _identity = null;
    _accessToken = null;
    _refreshToken = null;
    _accessTokenExpiresAt = null;
    _uid = null;

    final Object? body;
    try {
      body = await _postJson('/oauthapi/third-part/token', {
        'code': code,
        'code_verifier': verifier,
        'client_id': _clientId,
      });
    } on AdapterFailure catch (failure) {
      return LoginRejected(failure.message, apiCode: failure.apiCode);
    }

    final data = _oauthData(body);
    if (data == null) {
      final msg = _oauthMessage(body);
      // 已经提交过 code 却被拒 ⇒ 让界面说「这次的不对」，而不是「去授权」。
      if (msg != null && msg.isNotEmpty) {
        return LoginRejected('授权码没有被接受：$msg', apiCode: _oauthCode(body));
      }
      return const LoginRejected('授权码没有被接受，请重新获取授权链接', );
    }

    final access = _stringField(data, 'access_token');
    if (access == null || access.isEmpty) {
      return const LoginRejected('服务端没有返回访问令牌，请确认这个地址是飞牛 fnOS');
    }
    _accessToken = access;
    _refreshToken = _stringField(data, 'refresh_token') ?? _refreshToken;
    _accessTokenExpiresAt = _expiryFrom(data);
    _pendingVerifier = null;
    _pendingIssuedAt = null;

    // 立刻取一次身份：既验证 token 真能用，也顺便拿到 uid（卷根要用）。
    try {
      final info = await _call('user.info');
      final userInfo = _firstMapField(info, 'userInfo');
      _uid = _intField(userInfo, 'uid');
      final user = _stringField(userInfo, 'user');
      _identity = 'fnos-${user ?? 'user'}-${DateTime.now().millisecondsSinceEpoch}';
      // 打开链的两样东西随会话一起备（账号 + 共享表），别等 `shareRoots()`。
      await _absorbSessionIdentity(userInfo);
      _log.i('FnOSAdapter: login ok uid=${_uid ?? '?'} '
          'account-known=${_signedInUser != null} smb-shares=${_smbShares.length}');
      return LoginSuccess(identity: _identity!, nickname: user);
    } on AdapterFailure catch (failure) {
      _accessToken = null;
      return LoginRejected(failure.message, apiCode: failure.apiCode);
    }
  }

  /// 用上层保存的 refresh token 续期。成功返回 [LoginSuccess]，失败返回 `null`。
  ///
  /// ★ 失败**不抛异常**，理由见调用处：调用方要退回授权流程。
  /// ★ 但**取消必须穿透**（`CoreError` 原样上抛）——把用户主动取消当成
  ///   「令牌失效」，会弹出一个没人要的授权地址。
  Future<LoginSuccess?> _restoreFromSavedToken(String refreshToken) async {
    _identity = null;
    _accessToken = null;
    _refreshToken = refreshToken;
    _accessTokenExpiresAt = null;
    _uid = null;
    try {
      await _ensureToken();
      final info = await _call('user.info');
      final userInfo = _firstMapField(info, 'userInfo');
      _uid = _intField(userInfo, 'uid');
      final user = _stringField(userInfo, 'user');
      _identity = 'fnos-${user ?? 'user'}-${DateTime.now().millisecondsSinceEpoch}';
      // ★★ 续期这条路以前**什么都不备** —— 重启 App 后账号空、共享表空，
      //   双击结果开登录网页（2026-10-29 真机）。恢复会话就得当新会话办。
      await _absorbSessionIdentity(userInfo);
      // 日志用 ASCII 前缀：AOT 快照里的中文不是 UTF-8 明文，出包后按字节
      // 搜索新代码时中文恒为 0（旧版本就踩过），ASCII 才是可核对的钉子。
      _log.i('FnOSAdapter: restore-session ok uid=${_uid ?? '?'} '
          'account-known=${_signedInUser != null} smb-shares=${_smbShares.length}');
      return LoginSuccess(identity: _identity!, nickname: user);
    } on AdapterFailure catch (failure) {
      _log.i('FnOSAdapter: 已保存的令牌续期失败（${failure.message}），退回授权流程');
      _identity = null;
      _accessToken = null;
      _refreshToken = null;
      _accessTokenExpiresAt = null;
      _uid = null;
      return null;
    }
  }

  /// 拼授权地址。参数集合与官方 CLI 产出的完全一致（实测抓到的那个 URL）。
  ///
  /// 手工拼 query 而不是用 `Uri(queryParameters:)`：Dart 会把空格编码成 `+`，
  /// 而飞牛侧（nginx + Go）按 `%20` 解析 scope 列表，`+` 会被当成字面加号，
  /// 结果是「scope 无效」这种极难定位的授权失败。
  Uri _authorizationUrl(String verifier) {
    final origin = _dio.siteOrigin;
    final challenge = _codeChallenge(verifier);
    final query = <String>[
      'client_id=${Uri.encodeComponent(_clientId)}',
      'scope=${Uri.encodeComponent(_requestedScope)}',
      'code_challenge=${Uri.encodeComponent(challenge)}',
      'code_challenge_method=S256',
      'device_id=${Uri.encodeComponent(_deviceId)}',
      'device_name=${Uri.encodeComponent(_deviceName)}',
      'device_model=${Uri.encodeComponent(_deviceModel)}',
    ].join('&');
    return Uri.parse(
      '${origin.scheme}://${origin.host}:${origin.port}/signin?$query',
    );
  }

  /// PKCE verifier：43–128 个 `[A-Za-z0-9-._~]` 字符。这里取 64。
  static String _newCodeVerifier() {
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final random = Random.secure();
    return List.generate(64, (_) => alphabet[random.nextInt(alphabet.length)]).join();
  }

  /// `BASE64URL(SHA256(verifier))`，**去掉尾部 `=`**（RFC 7636 要求无填充）。
  static String _codeChallenge(String verifier) {
    final digest = sha256Bytes(utf8.encode(verifier));
    return base64Url.encode(digest).replaceAll('=', '');
  }

  // ───────────────────────── 令牌维持 ─────────────────────────

  /// 确保手上有一个还能用的 access token，必要时刷新。
  ///
  /// 提前 60 秒刷新：官方 CLI 也是这个阈值。飞牛的 access token 有效 1 小时，
  /// 卡在边界上会让一次搜索在发出后才发现过期。
  Future<void> _ensureToken() async {
    _cancel?.check();
    if (_accessToken != null) {
      final expires = _accessTokenExpiresAt;
      if (expires == null || expires.difference(DateTime.now()) > const Duration(seconds: 60)) {
        return;
      }
    }
    final refresh = _refreshToken;
    if (refresh == null) {
      // 冷启动（没有凭据）：等用户走授权流程。
      throw const AdapterFailure(ErrorKind.needsAuth, '还没有连接这台飞牛，请先完成授权');
    }
    final Object? body;
    try {
      body = await _postJson('/oauthapi/refresh', {
        'refresh_token': refresh,
        'client_id': _clientId,
      });
    } on AdapterFailure catch (failure) {
      _identity = null;
      throw AdapterFailure(ErrorKind.sessionExpired, '登录状态已失效，请重新授权：${failure.message}');
    }
    final data = _oauthData(body);
    final access = _stringField(data, 'access_token');
    if (access == null || access.isEmpty) {
      _identity = null;
      throw const AdapterFailure(ErrorKind.sessionExpired, '登录状态已失效，请重新授权');
    }
    _accessToken = access;
    // ★ refresh 可能不返回新的 refresh token（实测这次没返回）。
    //   不返回时必须**保留旧值**，否则下一次刷新就没凭据了。
    _refreshToken = _stringField(data, 'refresh_token') ?? refresh;
    _accessTokenExpiresAt = _expiryFrom(data);
    _log.d('FnOSAdapter: 已刷新 access token');
  }

  /// `expires_at` 是**毫秒**时间戳（实测 1793200899289）。
  /// 缺失时退回 `expires_in`（秒）；两者都没有就当作未知（下次调用再刷）。
  static DateTime? _expiryFrom(Object? data) {
    final at = _intField(data, 'expires_at');
    if (at != null && at > 0) {
      return DateTime.fromMillisecondsSinceEpoch(at);
    }
    final inSeconds = _intField(data, 'expires_in');
    if (inSeconds != null && inSeconds > 0) {
      return DateTime.now().add(Duration(seconds: inSeconds));
    }
    return null;
  }

  // ───────────────────────── 共享根 ─────────────────────────

  /// 返回**存储空间卷根**，如 `/vol2/1000`。
  ///
  /// ── 为什么位置是卷根，不是一个一个共享文件夹 ──────────────────
  /// 实测（2026-10-28）：搜 `报告` 落在 1189 个不同父目录上，
  /// 说明卷根一次就递归覆盖了全部子目录。而「一次请求只能带一个 path」，
  /// 若把 12 个共享文件夹各当一个位置，一次搜索要发 12 次、等 12 份延迟，
  /// 换来的是完全相同的覆盖范围。
  ///
  /// ── 卷根怎么来 ──────────────────────────────────────────────
  /// 飞牛没有「列出存储空间」的公开端点（`stor.*` / `file.volume.list`
  /// 实测全 403）。可用的是：`user.info` 给 uid，然后逐个试
  /// `vol{n}/{uid}`——`file.ls` 对存在的路径回 succ、不存在回 `errno`。
  /// 这条路的好处是**顺带完成了可用性预检**：探测失败的卷根本不会
  /// 出现在位置列表里，用户不会选到一个搜不了的位置。
  @override
  Future<List<ShareRoot>> shareRoots() async {
    _cancel?.check();
    await _ensureToken();

    final info = await _call('user.info');
    final userInfo = _firstMapField(info, 'userInfo');
    final uid = _intField(userInfo, 'uid');
    if (uid == null) {
      throw const AdapterFailure(
        ErrorKind.protocolViolation,
        '这台飞牛没有返回用户编号（uid），无法确定存储位置',
      );
    }
    _uid = uid;
    final user = _stringField(userInfo, 'user');
    // 账号名交给打开链认 SMB 挂载用（见 `SignedInAccountProviding`）。
    // 空串当没拿到：拿空串去比只会得到「谁都不匹配」的假结论。
    _signedInUser = (user != null && user.isNotEmpty) ? user : null;
    if (_identity == null) {
      _identity = 'fnos-${user ?? 'user'}-${DateTime.now().millisecondsSinceEpoch}';
    }

    final roots = <ShareRoot>[];
    for (var v = 1; v <= _maxVolumeProbe; v++) {
      _cancel?.check();
      final storage = 'vol$v/$uid';
      if (await _probeDirectory(storage)) {
        roots.add(ShareRoot(name: '存储空间 $v', path: '/$storage'));
      }
    }
    if (roots.isEmpty) {
      throw AdapterFailure(
        ErrorKind.emptyScope,
        '登录成功，但这个账号（uid $uid）下没有任何可访问的存储空间。'
        '请先在飞牛网页端确认这个账号能看到哪些文件夹。',
      );
    }
    // 这里**无条件重取**（不用 `_ensureSmbShares`）：列位置是「设备结构可能变了」
    // 的时刻，用户也可能刚在网页端加了共享。多一次往返换一次准确，值。
    await _refreshSmbShares();
    _log.i('FnOSAdapter: roots=${roots.length} smb-shares=${_smbShares.length}');
    return roots;
  }

  /// 取 SMB 共享表（会话建立时一次）。失败不擞：SMB 只是打开链的一路，
  /// 列不出来就退网页，不能让连接失败。
  Future<void> _refreshSmbShares() async {
    _smbShares.clear();
    try {
      final body = await _call('file.share.list');
      final elements = body is List ? body : <Object?>[body];
      for (final element in elements) {
        if (element is! Map) continue;
        final list = element['share'];
        if (list is! List) continue;
        for (final entry in list) {
          if (entry is! Map) continue;
          final raw = (entry['path'] as String?)?.trim() ?? '';
          final storage = _normalizeStorage(raw);
          if (storage.isEmpty) continue;
          // ★ 问不出共享名就**跳过这条共享**，不拿路径末段顶上
          //（2026-10-29 审查）：`shareName` 是管理员起的，可以与目录名不同，
          // 猜错了会去挂载一个错误的共享。跳过 ⇒ 这条路径的打开退网页，
          // 文件管理器兜得住，比打开错位置诚实。
          // 问名用**设备原样给的**路径（`info` 认的是它自己的坐标），
          // 只有存进表里比较时才归一化。
          final name = await _shareName(raw);
          if (name == null || name.isEmpty) continue;
          _smbShares.add((storagePath: storage, name: name));
        }
      }
      // 只在**成功走完**时置位：中途失败（超时/拒绝）留 false，下次还能再问。
      _smbSharesLoaded = true;
    } on CoreError catch (error) {
      // 取消不许被「退网页」兜底吞掉：用户已经不在这台设备上了。
      if (error.kind == 'Cancelled') rethrow;
      _log.w('FnOSAdapter: 列 SMB 共享失败（打开将退网页）：$error');
    } catch (error) {
      _log.w('FnOSAdapter: 列 SMB 共享失败（打开将退网页）：$error');
    }
  }

  /// 存储路径归一化：去掉首尾的 `/`。
  ///
  /// ★ 2026-10-29 真机：`smbShareFor` 拿「不带前导斜杠」的结果路径去比设备给的
  ///   共享路径，只要设备那边多一个 `/`（或结尾多一个），前缀就永远对不上，
  ///   整张共享表等于没有 —— 而症状是「双击打开登录网页」，看上去像匹配算法错了。
  ///   这条归一化对两边都做一遍，不让标点决定功能。
  static String _normalizeStorage(String path) {
    var value = path.trim();
    while (value.startsWith('/')) {
      value = value.substring(1);
    }
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }

  /// 确保共享表问过一次。已问过（哪怕问出来是空表）就直接返回。
  Future<void> _ensureSmbShares() async {
    if (_smbSharesLoaded) return;
    await _refreshSmbShares();
  }

  /// 问 `file.share.info` 拿共享名（实测：`shareName: "备份"`）。
  ///
  /// 只捕 [AdapterFailure]（设备明确回的查询失败）返回 null；取消、超时等
  /// [CoreError] 一律向上传 —— 整张共享表的外层兜底会按「退网页」收场，
  /// 但不许在这里把用户的取消吞成「这条共享没有名字」。
  Future<String?> _shareName(String storagePath) async {
    try {
      final body = await _call('file.share.info', {'path': storagePath});
      final elements = body is List ? body : <Object?>[body];
      for (final element in elements) {
        if (element is! Map) continue;
        final name = element['shareName'];
        if (name is String && name.isNotEmpty) return name;
      }
      return null;
    } on AdapterFailure {
      return null;
    }
  }

  /// 存储路径 → SMB 共享映射。**最长前缀优先**：共享可能嵌套
  /// （`vol2/1000` 与 `vol2/1000/备份` 都是共享时，后者更精确）。
  /// 已经解析出几条共享；**还没问过就返回 null**（不是 0）。
  /// 打开链退网页时，这个数能直接分出「共享表是空的」还是「路径没落在任何共享下」。
  @override
  int? get resolvedShareCount => _smbSharesLoaded ? _smbShares.length : null;

  @override
  SmbShareMapping? smbShareFor(String logicalPath) {
    // 两侧都归一化（见 `_normalizeStorage`）：设备给的共享路径与结果路径
    // 只要有一个多了前导/结尾斜杠，前缀比较就永远失败。
    final normalized = _normalizeStorage(logicalPath);
    if (normalized.isEmpty) return null;
    ({String storagePath, String name})? best;
    var bestLen = -1;
    for (final share in _smbShares) {
      if (normalized == share.storagePath) {
        if (share.storagePath.length > bestLen) {
          best = share;
          bestLen = share.storagePath.length;
        }
      } else if (normalized.startsWith('${share.storagePath}/')) {
        if (share.storagePath.length > bestLen) {
          best = share;
          bestLen = share.storagePath.length;
        }
      }
    }
    if (best == null) return null;
    final rest = normalized.substring(best.storagePath.length);
    final segments = rest.split('/').where((s) => s.isNotEmpty).toList();
    return SmbShareMapping(shareName: best.name, relativeSegments: segments);
  }

  /// 网页入口：**站点首页**（桌面）。
  ///
  /// ★ 2026-10-29 真机否掉了原来的 `/app/file`（用户截图：浏览器只得到
  ///   `Not Found`）。`/app/*` 根本不是页面，而是 **App 容器入口**：
  ///   服务端对 `/app` 回 301 到 `:5667/app/`，容器要靠 `/app/ticket` 换票
  ///   才渲染得出来。走反代（只开 443）或外网访问时 5667 根本不通，于是
  ///   5666 上这个前缀只剩两种结局 —— 无会话 `invalid token`（HTTP 200，
  ///   不是页面），有会话 `Not Found`。两种都不是文件管理器。
  ///   教训：**「200」不是「可达」**，当年就是拿状态码当证据才记成「实测可达」。
  ///
  /// 能确定打开、且已登录浏览器直接进得去的只有桌面 SPA（`/`，返回真 HTML）。
  /// 桌面只读 `uniqueDeviceId` / `theme` / `state` 三个 query，没有任何
  /// 「打开某个应用」或「定位到某个目录」的参数 ⇒ **不能路径级定位**，
  /// 也不假装能：给一个看起来能定位的地址，用户点开只会得到错误页。
  @override
  Uri webURLFor(String logicalPath) {
    var origin = _dio.options.baseUrl;
    if (origin.endsWith('/')) origin = origin.substring(0, origin.length - 1);
    return Uri.parse('$origin/');
  }

  /// 目录是否可读。**这是唯一能区分「路径不存在」和「没有匹配」的手段**：
  /// 搜索对坏路径静默回 0 条（文件头第 4 条），`file.ls` 会明确报 errno。
  Future<bool> _probeDirectory(String storagePath) async {
    try {
      final body = await _call('file.ls', {'path': storagePath});
      final first = _firstElement(body);
      if (first == null) return false;
      if (_stringField(first, 'result') == 'fail') return false;
      return first['files'] is List;
    } on AdapterFailure {
      // 单个卷探测失败不该让整次枚举失败：这台机器可能有 5 个卷、
      // 其中 4 个当前不可用（未挂载/无权限），剩下那个照样能用。
      return false;
    }
  }

  // ───────────────────────── 列目录 ─────────────────────────

  /// `file.ls {path}` → `[{files:[{btim,dir,mtim,name,uid}], uver}]`。
  ///
  /// ★ 返回项**没有 size**：实测字段只有五个。因此大小一律标成「未知」，
  ///   不拿 0 冒充——否则界面上「空文件」和「不知道多大」会长得一样。
  ///   搜索结果那条路（`fileSearch`）是带 size 的，两条不要混。
  @override
  Future<List<FileItem>> list(String path) async {
    _cancel?.check();
    await _ensureToken();
    final storage = _storagePath(path);
    _log.d('FnOSAdapter: list => $storage');

    final body = await _call('file.ls', {'path': storage});
    final first = _firstElement(body);
    if (first == null) return const <FileItem>[];
    _throwIfFailed(first, action: '列目录', path: path);

    final entries = first['files'];
    if (entries is! List) return const <FileItem>[];

    final out = <FileItem>[];
    for (final entry in entries) {
      if (entry is! Map) continue;
      final name = _stringField(entry, 'name');
      if (name == null || name.isEmpty) continue;
      final isDir = _intField(entry, 'dir') == 1;
      out.add(FileItem(
        name: name,
        path: _joinLogical(path, name),
        isDirectory: isDir,
        size: 0,
        // 设备没给大小 ⇒ 未知，不是 0。
        sizeKnown: false,
        modifiedTime: _timeFromSeconds(_intField(entry, 'mtim')),
        createdTime: _timeFromSeconds(_intField(entry, 'btim')),
        extension: isDir ? null : PathCompat.extension(name),
        isHidden: name.startsWith('.'),
      ));
    }
    return out;
  }

  // ───────────────────────── 搜索 ─────────────────────────

  /// 逐卷搜索后合并。
  ///
  /// ── 三个必须守住的点 ────────────────────────────────────────
  /// 1. **一个请求只能一个 path**（文件头第 2 条）：这是逐卷发的全部理由。
  /// 2. **path 不许为空**（文件头第 3 条）：空 path 会让服务端搜全库。
  ///    请求构造处会再断言一次，不靠调用方自觉。
  /// 3. **多包要拼接**（文件头第 5 条）：每个响应元素都带一段 `data`，
  ///    只取第一个会少给一个数量级。
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
        '搜索词不能为空：飞牛在关键字为空时会返回存储里的全部文件。',
      );
    }
    if (roots.isEmpty) {
      throw const AdapterFailure(ErrorKind.scopeUnset, '还没有选择这台飞牛的搜索位置');
    }

    await _ensureToken();
    // 兜底：没有共享表就没有 SMB 目标，整台设备只能开网页（2026-10-29 真机）。
    // 放在搜索前而不是 `row()` 里，是因为 `row()` 是同步的、拿不了网络。
    await _ensureSmbShares();

    // 逐卷并发（默认 2 路）。并发只改等待方式，不改结果顺序：
    // 合并按 roots 原顺序做，去重也在合并时一次性完成。
    final outcomes = List<_RootOutcome?>.filled(roots.length, null);
    var cursor = 0;

    Future<void> worker() async {
      while (true) {
        final index = cursor++;
        if (index >= roots.length) return;
        _cancel?.check();
        outcomes[index] = await _searchOneRoot(keyword, roots[index]);
      }
    }

    await Future.wait([
      for (var i = 0; i < _rootConcurrency && i < roots.length; i++) worker(),
    ]);

    final seen = <String>{};
    final results = <FileItem>[];
    AdapterFailure? firstFailure;
    var searchedRoots = 0;

    for (final outcome in outcomes) {
      if (outcome == null) continue;
      final failure = outcome.failure;
      if (failure != null) {
        firstFailure ??= failure;
        // 一个根没搜通就上报一条：上层据此把这次结果标成「不完整」，
        // 而不是让用户以为「全都没有找到」。
        onRootFailure?.call(RootSearchFailure(root: outcome.root, failure: failure));
        _log.w('FnOSAdapter: root ${outcome.root} 搜索失败 => ${failure.kind}');
        continue;
      }
      searchedRoots++;
      for (final item in outcome.items) {
        if (seen.add(item.path)) results.add(item);
      }
    }

    if (searchedRoots == 0 && firstFailure != null) throw firstFailure;
    return results;
  }

  Future<_RootOutcome> _searchOneRoot(String keyword, String root) async {
    final storage = _storagePath(root);
    if (storage.isEmpty) {
      // ★ 绝不允许把空 path 发出去：实测那会搜全库并回 671KB。
      return _RootOutcome(
        root,
        const <FileItem>[],
        const AdapterFailure(ErrorKind.scopeDenied, '搜索位置不合法：空路径'),
      );
    }

    final items = <FileItem>[];
    try {
      final body = await _call('appcgi.finder.fileSearch', {
        'key': keyword,
        // 恰好一个元素。多一个就会整次失败（实测 7.7s 后报错）。
        'path': <String>[storage],
      });
      final elements = body is List ? body : <Object?>[body];
      for (final element in elements) {
        if (element is! Map) continue;
        _throwIfFailed(element, action: '搜索', path: root);
        final data = element['data'];
        if (data is! List) continue; // 空结果就是没有 data 字段
        for (final raw in data) {
          final converted = _toSearchItem(raw, root);
          if (converted != null) items.add(converted);
        }
      }
    } on AdapterFailure catch (failure) {
      return _RootOutcome(root, const <FileItem>[], failure);
    }
    return _RootOutcome(root, items, null);
  }

  /// 搜索结果项 → `FileItem`。
  ///
  /// 形状：`{btim, dir, mtim, name, path, size, uid}`，其中 **`path` 是父目录**
  /// 的存储侧坐标（`vol2/1000/Photos/质检`），不是文件全路径，必须拼上 `name`。
  FileItem? _toSearchItem(Object? raw, String root) {
    if (raw is! Map) return null;
    final name = _stringField(raw, 'name');
    if (name == null || name.isEmpty) return null;

    final parentStorage = _stringField(raw, 'path') ?? '';
    final storageFull = parentStorage.isEmpty ? name : PathCompat.join(parentStorage, name);
    final logical = '/$storageFull';

    // 服务端本应只返回该 root 之下的东西；万一越界就不要把它当成本次结果，
    // 否则上层 `Scope.narrowTo` 会判 ScopeDenied，整个位置看起来像坏了。
    if (!_withinRoot(logical, root)) return null;

    final isDir = _intField(raw, 'dir') == 1;
    final size = _intField(raw, 'size');
    return FileItem(
      name: name,
      path: logical,
      isDirectory: isDir,
      size: isDir ? 0 : (size ?? 0),
      // 搜索项带 size（实测有），目录的大小没有意义 ⇒ 目录一律未知。
      sizeKnown: !isDir && size != null,
      modifiedTime: _timeFromSeconds(_intField(raw, 'mtim')),
      createdTime: _timeFromSeconds(_intField(raw, 'btim')),
      extension: isDir ? null : PathCompat.extension(name),
      isHidden: name.startsWith('.'),
    );
  }

  // ─────────────────────────── 登出 ───────────────────────────

  /// 官方文档写明 `logout` 只清本地 session，不承诺远端撤销。
  /// 这里同样只清内存态（凭据本来也没落盘）。
  @override
  Future<void> logout() async {
    _accessToken = null;
    _refreshToken = null;
    _accessTokenExpiresAt = null;
    _identity = null;
    _uid = null;
    _signedInUser = null;
    _pendingVerifier = null;
    _pendingIssuedAt = null;
    _smbShares.clear();
    _smbSharesLoaded = false;
    _log.i('FnOSAdapter: 已清除会话状态');
  }

  // ─────────────────────── 下载打开（RemoteDownload）───────────────────────

  /// 真机契约（2026-10-29 实测，原始输出在 probe_fnos_open.dart）：
  ///
  /// ① `POST /ogh/ac/h/multiple-download`，body `{"paths":["存储侧路径"]}`
  ///    （**不带**前导 `/`）→ `{"token":"32位hex"}`。字段名 `files`/`path` 都 400。
  /// ② `GET /ogh/ac/h/multiple-download?token=<t>` + Bearer → **200 全量 zip**
  ///    （单文件也打包，`PK` 头）；Range 被服务端无视（回 200 不是 206）；
  ///    无 Bearer → 401。
  /// ③ `/ogh/ac/h/download` 端点**不存在**（403 Forbidden）。
  ///
  /// 取消只检查在**阶段之间**（拿 token 前、写流中途不监听 cancel）——
  /// 流式下载的即时取消要给读流挂监听，v1 不做；桥接层的看门狗兜底。
  @override
  Future<DownloadedArtifact> downloadToTemp(
      String logicalPath, Cancellation cancel) async {
    await _ensureToken();
    cancel.check();
    final storage = _storageSideOf(logicalPath);
    final segments = storage.split('/').where((s) => s.isNotEmpty).toList();
    final name = segments.isEmpty ? logicalPath : segments.last;
    final token = await _downloadToken(storage);
    final workDir = await Directory.systemTemp.createTemp('flashfind-fnos-');
    try {
      final zipFile = File('${workDir.path}/bundle.zip');
      await _downloadZip(zipFile, token, cancel);
      final contentDir = Directory('${workDir.path}/content');
      final entries = await extractZip(zipFile, contentDir);
      await zipFile.delete();
      if (entries.topLevelEntries.isEmpty) {
        throw const CoreError('DownloadFailed', detail: 'ZipEmpty');
      }
      // 单条目（单文件 / 单目录 zip）→ 直接交那个条目；
      // 多条目 → 交解包目录本身，让用户看到整个结构。
      final local = entries.topLevelEntries.length == 1
          ? '${contentDir.path}/${entries.topLevelEntries.first}'
          : contentDir.path;
      int? size;
      if (await FileSystemEntity.isFile(local)) {
        size = await File(local).length();
      }
      _log.i('FnOSAdapter: 下载完成 $name → ${entries.topLevelEntries.length} 条目');
      return DownloadedArtifact(localPath: local, name: name, byteSize: size);
    } on ZipFormatException {
      await _cleanup(workDir);
      rethrow;
    } on CoreError {
      await _cleanup(workDir);
      rethrow;
    } catch (error) {
      await _cleanup(workDir);
      throw CoreError('DownloadFailed', detail: '$error');
    }
  }

  /// 存储侧路径校验 + 归一：去掉前导 `/`，拒绝空、`..`、NUL。
  String _storageSideOf(String logicalPath) {
    final trimmed = logicalPath.trim();
    final withoutSlash =
        trimmed.startsWith('/') ? trimmed.substring(1) : trimmed;
    final segments = withoutSlash.split('/').where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty ||
        segments.contains('..') ||
        segments.any((s) => s.contains('\u0000'))) {
      throw CoreError('DownloadFailed', detail: 'UnsafePath');
    }
    return segments.join('/');
  }

  Future<String> _downloadToken(String storage) async {
    final reply = await _withAuthRetry(() => _postJson(
          '/ogh/ac/h/multiple-download',
          {'paths': <Object?>[storage]},
          headers: {'Authorization': 'Bearer ${_accessToken ?? ''}'},
        ));
    final token = reply is Map ? reply['token'] : null;
    if (token is! String || token.isEmpty) {
      throw CoreError('DownloadFailed', detail: 'NoToken:${reply.runtimeType}');
    }
    return token;
  }

  /// GET zip 落盘。401 时刷新重试一次（与 `_withAuthRetry` 同一条纪律：
  /// refresh 之后旧 token 立即失效，所以失败重试要带**新**token）。
  Future<void> _downloadZip(File target, String token, Cancellation cancel) async {
    final client = HttpClient();
    try {
      var origin = _dio.options.baseUrl;
      if (origin.endsWith('/')) origin = origin.substring(0, origin.length - 1);
      for (var attempt = 0;; attempt++) {
        cancel.check();
        final uri = Uri.parse('$origin/ogh/ac/h/multiple-download')
            .replace(queryParameters: {'token': token});
        final request = await client.openUrl('GET', uri);
        request.headers.set('Authorization', 'Bearer ${_accessToken ?? ''}');
        final response = await request.close();
        if (response.statusCode == 401 && attempt == 0 && _refreshToken != null) {
          await response.drain<void>();
          _accessToken = null;
          await _ensureToken();
          continue;
        }
        if (response.statusCode != 200) {
          await response.drain<void>();
          throw CoreError('DownloadFailed', detail: 'HTTP ${response.statusCode}');
        }
        final sink = target.openWrite();
        try {
          await for (final chunk in response) {
            sink.add(chunk);
          }
          await sink.flush();
        } finally {
          await sink.close();
        }
        return;
      }
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _cleanup(Directory dir) async {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {
      // 临时目录清不掉就让系统 temp 收拾，不值得让失败信息变得含糊。
    }
  }

  // ─────────────────── 传输：/ogh/ac/w 统一入口 ───────────────────

  /// 调一个 appcgi 端点。
  ///
  /// 通道语义（实测）：`POST /ogh/ac/w`，头带 `Authorization: Bearer <token>`，
  /// body 是 `{reqid, req, ...params}`；响应是 **JSON 数组**。
  ///
  /// ★ **不需要 HMAC 签名**。官方 `_conventions.md` 说「当 session 中存在
  ///   secret 时使用 HMAC-SHA256 签名」，而 CLI 的 session 里根本没有 secret
  ///   字段（只有 accessToken / refreshToken / oauthClientId / oauthDeviceId）。
  ///   实测直连带 Bearer 就通，`user.info` / `file.ls` / `file.share.list` /
  ///   `appcgi.finder.fileSearch` 全部 200。
  Future<Object?> _call(String req, [Map<String, Object?> params = const {}]) async {
    return _withAuthRetry(() async {
      final body = <String, Object?>{
        'reqid': _newRequestId(),
        'req': req,
        ...params,
      };
      return _postJson(
        '/ogh/ac/w',
        body,
        headers: {'Authorization': 'Bearer ${_accessToken ?? ''}'},
      );
    });
  }

  /// 401 时刷新一次再重试。
  ///
  /// 为什么必须重试而不是直接报失效：access token 只有 1 小时，
  /// 用户挂着设置页过一会儿再搜，第一次请求就会撞 401。
  /// 直接报「请重新连接」会把一次正常过期说成登录失败。
  /// **只重试一次**：刷新后仍 401 说明问题不在过期，重复刷只会消耗 refresh token。
  Future<Object?> _withAuthRetry(Future<Object?> Function() action) async {
    try {
      return await action();
    } on AdapterFailure catch (failure) {
      if (failure.kind != ErrorKind.sessionExpired) rethrow;
      if (_refreshToken == null) rethrow;
      _log.w('FnOSAdapter: 收到 401，刷新后重试一次');
      _accessToken = null;
      await _ensureToken();
      return await action();
    }
  }

  /// 原始 JSON POST。OAuth 端点与业务端点共用（两者都回 JSON）。
  Future<Object?> _postJson(
    String path,
    Map<String, Object?> payload, {
    Map<String, dynamic>? headers,
  }) async {
    try {
      final response = await _dio.post<dynamic>(
        path,
        data: payload,
        options: Options(
          headers: <String, dynamic>{
            'accept': 'application/json',
            ...?headers,
          },
          responseType: ResponseType.json,
        ),
      );
      return response.data;
    } on DioException catch (error) {
      throw _translate(error, path);
    }
  }

  AdapterFailure _translate(DioException error, String action) {
    if (error.type == DioExceptionType.cancel) {
      return const AdapterFailure(ErrorKind.cancelled, '这次操作已取消');
    }
    final embedded = error.error;
    if (embedded is CoreError && embedded.kind.isNotEmpty) {
      return AdapterFailure(embedded.kind, embedded.reason ?? embedded.kind);
    }
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        // 搜索这条路的超时是真会发生的：2711 条要 1.9s，弱网下更久。
        return const AdapterFailure(ErrorKind.timedOut, '飞牛没有在预期时间内响应，请检查网络');
      case DioExceptionType.badCertificate:
        return const AdapterFailure(
          ErrorKind.tlsRejected,
          'TLS 握手失败：这个地址的证书不被信任，或端口不对',
        );
      case DioExceptionType.connectionError:
        return const AdapterFailure(ErrorKind.networkFailure, '无法连接到飞牛，请确认地址与网络');
      case DioExceptionType.badResponse:
        final status = error.response?.statusCode;
        if (status == 401 || status == 403) {
          // 401 AUTH_INVALID_TOKEN：token 过期或缺失。
          // 403 也归这里：`/ogh/ac/w` 对未知端点回的是纯文本 Forbidden，
          // 与「凭据不对」在现象上一样（都进不来），区分留给调用点。
          return AdapterFailures.sessionExpired(status);
        }
        if (status == 429) {
          return const AdapterFailure(
            ErrorKind.rateLimited,
            '飞牛在限流：请求过于频繁，请稍等片刻',
            apiCode: 429,
          );
        }
        return AdapterFailure(ErrorKind.httpFailure, '$action 收到 HTTP $status', apiCode: status);
      case DioExceptionType.cancel:
        return const AdapterFailure(ErrorKind.cancelled, '这次操作已取消');
      case DioExceptionType.unknown:
        return AdapterFailure(ErrorKind.networkFailure, '$action 失败：${error.message}');
    }
  }

  /// 业务失败分诊。飞牛把错误放在**数组元素的 `result`/`errno`** 上。
  ///
  /// 实测到的 errno：
  /// · `4100` —— 路径不存在（`file.ls` on 不存在的目录）
  /// · `65280` —— 卷不存在（`file.ls vol3/1000`）
  /// · `100000002` —— 缺必需参数（缺 `key`）
  /// · 搜索对**坏路径**不报错，只回 `result:succ` 且没有 `data`
  ///   ⇒ 这种情形在这里看不出来，只能靠 `file.ls` 预检（见 [_probeDirectory]）。
  void _throwIfFailed(Map element, {required String action, required String path}) {
    if (_stringField(element, 'result') != 'fail') return;
    final errno = _intField(element, 'errno');
    if (errno == 4100 || errno == 65280) {
      throw AdapterFailures.pathMissing('$path 不存在，或这个账号访问不到它');
    }
    if (errno == 100000002) {
      throw AdapterFailure(
        ErrorKind.protocolViolation,
        '$action 缺少必需参数（设备码 $errno），这通常是闪寻的缺陷',
        apiCode: errno,
      );
    }
    throw AdapterFailure(
      ErrorKind.apiError,
      errno == null ? '$action 失败（设备未说明原因）' : '$action 失败（设备码 $errno）',
      apiCode: errno,
    );
  }

  // ─────────────────────── 形状与小工具 ───────────────────────

  /// 24 位大写十六进制请求 id。官方实现是这个形状（示例 `69ba…`）。
  static String _newRequestId() {
    final random = Random.secure();
    return List.generate(24, (_) => random.nextInt(16).toRadixString(16)).join().toUpperCase();
  }

  /// 逻辑路径 → 存储侧坐标。两者只差一个前导 `/`：
  /// `/vol2/1000/共享文档` ↔ `vol2/1000/共享文档`。
  ///
  /// ★ 之所以让逻辑路径**保留 `vol{n}/{uid}` 前缀**，而不是剥成
  /// `/共享文档`：搜索结果返回的就是存储侧坐标，保留前缀后
  /// 「结果 → 逻辑路径」只是补一个斜杠，不需要做前缀裁剪；
  /// 一旦裁剪，`Scope` 判定、SMB 共享名推导都要各写一次换算，
  /// 而任何一处算错的表现都是「搜得到但打不开」。
  static String _storagePath(String logicalPath) {
    var p = logicalPath.trim();
    while (p.startsWith('/')) {
      p = p.substring(1);
    }
    while (p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }

  static String _joinLogical(String parent, String name) {
    final base = parent.isEmpty ? '/' : parent;
    final clean = name.startsWith('/') ? name.substring(1) : name;
    return base == '/' ? '/$clean' : '$base/$clean';
  }

  /// `path` 是否落在 `root` 之下。按段比对，不能拼字符串前缀
  /// （`/vol2/1000X` 不是 `/vol2/1000` 的子目录）。
  static bool _withinRoot(String path, String root) {
    final a = root.split('/').where((s) => s.isNotEmpty).toList();
    final b = path.split('/').where((s) => s.isNotEmpty).toList();
    if (b.length < a.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static DateTime? _timeFromSeconds(int? seconds) {
    if (seconds == null || seconds <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
  }

  /// 业务端点的响应恒为数组，取第一个元素（单包情形下就是唯一那个）。
  /// 元素不是对象时返回 null —— 那种响应说明设备行为变了，交给调用方当空处理。
  static Map? _firstElement(Object? body) {
    final first = body is List ? (body.isEmpty ? null : body.first) : body;
    return first is Map ? first : null;
  }

  static Map? _firstMapField(Object? body, String key) {
    final first = _firstElement(body);
    if (first == null) return null;
    final value = first[key];
    return value is Map ? value : null;
  }

  /// OAuth 端点的信封是 `{code, msg, data}`，与业务端点的数组不同。
  static Map? _oauthData(Object? body) {
    if (body is! Map) return null;
    if (_intField(body, 'code') != 0) return null;
    final data = body['data'];
    return data is Map ? data : null;
  }

  static int? _oauthCode(Object? body) => body is Map ? _intField(body, 'code') : null;

  static String? _oauthMessage(Object? body) => body is Map ? _stringField(body, 'msg') : null;

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
}

/// 一个根（卷）的搜索产物。
class _RootOutcome {
  const _RootOutcome(this.root, this.items, this.failure);
  final String root;
  final List<FileItem> items;
  final AdapterFailure? failure;
}
