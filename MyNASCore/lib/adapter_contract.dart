// 品牌适配器的统一接口。
//
// ── 为什么要有这一层 ─────────────────────────────────────────────
// 上游 `NasAdapter` / `NasFileSystem` 是**面向 Flutter UI** 的抽象：里面有
// MediaService、ToolsService、缩略图、转码、上传进度回调……闪寻的产品形态只需要
// 其中一小段：**登录 → 列共享 → 列目录 → 搜索**。
//
// 直接照搬整套抽象会把几十个用不到的方法带进来，还会把 Flutter 的形状
// （`Future<List<FileItem>>` + 一堆 UI 语义）硬塞进核心进程。所以这里定义
// 一个**窄接口**，四个品牌各自实现它。
//
// ── 移植时最容易走形的两条 ───────────────────────────────────────
// 1. **不要在适配器里做授权判定**。授权根由上层 scope 决定，适配器只负责
//    「把设备能给的列表拿回来」。上游 `refreshRoots` / `isInRoot` 之类
//    的过滤语义要**原样保留**（群晖那边就因为 scope 过滤被误读成「账号只看到 1 个共享」）。
// 2. **不要吞掉取消**。搜索可能被用户打断，`cancellation` 触发时
//    必须真实中断在飞的请求，而不是只让结果晚一点返回。
import 'adapter_support.dart';
import 'protocol.dart';
import 'upstream_file_types.dart' show FileItem;

/// 一个可授权的共享根。
class ShareRoot {
  /// 展示名。群晖返回的共享名带前导斜杠（`/示例共享`），**原样保留**，
  /// 归一化由上层做——适配器擅自去掉会掩盖设备的真实行为。
  final String name;

  /// 逻辑路径，搜索与列目录都用它。
  final String path;

  const ShareRoot({required this.name, required this.path});

  @override
  String toString() => 'ShareRoot($name → $path)';
}

/// 登录结果。三个分支穷尽所有情况，调用方不必猜。
sealed class LoginOutcome {
  const LoginOutcome();
}

class LoginSuccess extends LoginOutcome {
  /// 会话身份。用于并发与代际判定：**同一账号重登必须换一个身份**，
  /// 否则上一代的搜索结果会被误判成当前代的。
  final String identity;
  final String? nickname;

  const LoginSuccess({required this.identity, this.nickname});
}

/// 需要动态验证码。`methods` 是设备声明的可用方式（totp/email/sms）。
///
/// [rejected] 区分「还没给码」和「给了但不被接受」这两件事：
/// 有些服务端两种情况回同一个错误码（OpenList 一律 `code=402`
/// `Invalid 2FA code`），只有发起方知道自己这次带没带码。
/// 合在一起说的后果是用户输错一次之后，界面仍然只说「请填写动态码」，
/// 他不知道自己刚才那 6 位是被拒绝的。
class LoginNeedsOTP extends LoginOutcome {
  final List<String> methods;
  final bool rejected;
  const LoginNeedsOTP({this.methods = const ['totp'], this.rejected = false});
}

/// 登录被拒。**`reason` 必须是中文可读文案**，不能是 `AuthFailed` 这种码。
class LoginRejected extends LoginOutcome {
  final String reason;
  final int? apiCode;
  const LoginRejected(this.reason, {this.apiCode});
}

/// 需要用户到浏览器里完成授权，再把页面给出的一次性 code 交回来。
///
/// ── 为什么不能复用 [LoginNeedsOTP] ────────────────────────────────
/// 两者都是「一次登录要用户补一样东西」，但对**界面**的要求完全不同：
///   · OTP 是随密码一起发的 6 位数字，界面给一个输入框就够；
///   · 这里要先给用户一个地址（浏览器打开、登录、点授权），
///     再把页面上显示的一串 code 粘回来。
/// 混用一个类型，界面就只能对着一个授权地址要 6 位验证码 ——
/// 飞牛（fnOS）正是这种：官方协议**没有账号密码登录**，
/// 只有 OAuth 2.0 Authorization Code + PKCE，而且授权页**不回跳**
/// （授权地址里没有 `redirect_uri`），code 只能由用户手动交出。
///
/// 这也不是失败：它是登录流程的第一段，调用方应当把 [authorizationUrl]
/// 交给用户，拿到 code 后**再调一次** `login(authorizeCode: …)`。
class LoginNeedsAuthorizeCode extends LoginOutcome {
  /// 用户在浏览器里打开的授权地址。已含 `code_challenge`，原样展示，不要改写。
  final Uri authorizationUrl;

  /// 这个地址的有效期。飞牛实测 5 分钟（官方文档写明的是一次性 code 的有效期）。
  final Duration validFor;

  /// 是不是「已经提交过 code 但被拒绝」——与 [LoginNeedsOTP.rejected] 同理：
  /// 服务端对「没给」和「给错了」常常回同一个错误，只有发起方知道自己这次
  /// 带没带 code，不区分就会让用户输错一次之后仍然只看到「请去授权」。
  final bool rejected;

  const LoginNeedsAuthorizeCode({
    required this.authorizationUrl,
    this.validFor = const Duration(minutes: 5),
    this.rejected = false,
  });
}

/// 一次搜索里「**这一个根没搜通**」的记录。
///
/// ★ 为什么要单独一个类，而不是让适配器抛异常或静默吞掉：
/// 逐根搜索的品牌（OpenList）里，「某个存储的上游失效」与「这次搜索失败」
/// 是两件不同的事。抛异常会把**已经搜到的其它根的结果**一起丢掉；
/// 静默吞掉则会让上层以为「全范围都没有找到」——而真相是「有 1 个位置
/// 根本没搜」。两者都是把局部不可用冒充成全局结论。
class RootSearchFailure {
  /// 没搜通的那个搜索根（已授权范围内的逻辑路径）。
  final String root;

  /// 这个根为什么没搜通（中文可读文案 + 机器可判别的 kind）。
  final AdapterFailure failure;

  const RootSearchFailure({required this.root, required this.failure});

  @override
  String toString() => 'RootSearchFailure($root → ${failure.kind})';
}

/// 品牌适配器。
///
/// 实现者只需实现这些方法；所有网络访问必须走 `dio_compat.dart` 的 `Dio`
/// （同源锁定 + 禁重定向 + 响应上限 + 真实取消），不要直接开 `HttpClient`。
abstract class NasBrandAdapter {
  /// 品牌标识，与 Swift 侧 `Vendor.rawValue` 一致。
  String get vendor;

  /// 当前会话身份；未登录返回 null。
  String? get sessionIdentity;

  /// 取消令牌。harness 在每次查询开始前注入；适配器要在长操作里 `check()`。
  set cancellation(Cancellation token);

  /// 该品牌**实测到**的能力。真机未验证的一律返回 false 并在 `notes` 里说明。
  BrandCapabilities get capabilities;

  /// 这个后端的结果能否用**同一主机的 SMB 共享**打开。
  ///
  /// 群晖 / 威联通 / 绿联 / 跑在 NAS 上的 WebDAV 都返回 true：它们的主机
  /// 同时就是一台 SMB 服务器，搜索结果的逻辑路径（`/共享/子目录/文件`）
  /// 可以直接拼成 `smb://主机/共享/子目录/文件` 交给 Finder。
  ///
  /// OpenList 必须返回 false：它是**网页聚合器**，把别的网盘挂在一个
  /// HTTP 站点后面。主机只讲 HTTP，`/A0002` 这类「存储」也不是 SMB 共享。
  /// 在这里说 true 的后果不是「降级」，而是**造出一个必然失败的假目标** ——
  /// 真机实测（2026-10-24，AOT 二进制）结果行带着
  /// `smb://openlist.example.invalid/A0002/...`，用户双击后系统弹
  /// 「连接服务器时出现问题」，而真相是这个地址根本不提供 SMB。
  ///
  /// **故意不给默认实现**：四个适配器都是 `implements NasBrandAdapter`，
  /// 抽象类里的方法体不会被继承，写一个「看着像默认值」的 body 只会误导人。
  /// 更要紧的是，这条能力答错的代价是一个用户点得下去、却必然失败的入口，
  /// 所以要求每个品牌显式回答。
  bool get exposesSMBShares;

  /// `authorizeCode`：OAuth 授权码（只有走授权码流程的品牌用）。
  ///
  /// 为什么单独一个参数而不是复用 `otpCode`：两者的**来源**不同 ——
  /// 动态码由设备算出来（TOTP）或短信发来，授权码由用户在浏览器里
  /// 授权后从页面上抄下来。混用会让适配器分不清「用户填的这 6 位」
  /// 到底该当作 TOTP 还是授权码，而这两种校验路径完全不同。
  ///
  /// 品牌适配器的实现**必须接受这两个额外参数**（可以不用），
  /// 否则 `implements` 的签名对不上。
  Future<LoginOutcome> login({
    required String username,
    required String password,
    String? otpCode,
    String? authorizeCode,
  });

  /// 列出可授权的共享根。返回空列表是合法结果（设备没有共享）。
  Future<List<ShareRoot>> shareRoots();

  /// 列出某个目录的内容。`path` 是逻辑路径（如 `/示例共享/照片`）。
  Future<List<FileItem>> list(String path);

  /// 服务端搜索。
  ///
  /// `roots` 是**已授权的**搜索根集合，由上层 scope 给出——适配器不得自行扩大范围。
  /// 设备若不支持服务端搜索，**必须**抛 `AdapterFailure('UnsupportedApi', ...)`，
  /// 而不是回退成全盘遍历（那会在大型 NAS 上把设备拖垮，群晖上已经踩过）。
  ///
  /// `onRootFailure`：**部分根没搜通**时逐条回调。
  ///
  /// ★ 只有「所有根都没搜通」才允许抛异常；只要有一个根搜通了，
  ///   本次搜索就是**有结论**的，那些没搜通的根必须走这个回调交给上层，
  ///   由上层决定「保留已搜到的部分 + 标记不完整」。
  ///   把失败吞掉（只因为「有根成功了」）等于告诉用户「全都没有找到」，
  ///   而真相是「有一个位置根本没搜」——1.1.16 就是这个形态。
  Future<List<FileItem>> search(
    String query, {
    required List<String> roots,
    void Function(RootSearchFailure failure)? onRootFailure,
  });

  /// 结束会话。失败不抛异常——登出失败不该阻塞用户重新连接。
  Future<void> logout();
}

/// 「结果可以在站点网页里打开」的适配器实现这个接口。
///
/// 单独一个接口而不是往 `NasBrandAdapter` 里加抽象成员：SMB 那条路已经
/// 有 `exposesSMBShares` 回答「能不能用 SMB」，这里回答的是另一个问题。
/// 做成**标记接口**，不需要网页出口的品牌连一行都不用改——给四个已经
/// 跑通的适配器各加一个「我返回 null」的空实现，除了增加噪声没有任何收益。
///
/// 实现者必须做到：地址只能由**已授权的 origin** + 逻辑路径拼出来，
/// 不许夹带凭据（token / 密码 / 签名参数）。伪造得越自由，越容易变成
/// 「点一下就把会话令牌发给别人的站点」。
abstract class WebOpenableAdapter {
  /// 把逻辑路径换成浏览器地址。路径里的中文、空格、`%`、`#`、`?`
  /// 都必须按 RFC 3986 逐段百分号编码，不能靠字符串拼接。
  Uri webURLFor(String logicalPath);
}

/// 「结果可以下载到本机打开」的适配器实现这个接口。
///
/// ── 为什么需要它 ────────────────────────────────────────────────
/// 飞牛（fnOS）的文件既没有已验证的 SMB 共享名映射（445 不可达，`link`
/// 字段语义未验证），也没有网页直链。唯一**端到端量过**的打开路径是
/// 下载：`multiple-download` 拿临时 token → GET 拉 zip 包（**单文件也打包**，
/// 2026-10-29 实测）→ 客户端解包 → 交系统打开。这是它的「能打开」，
/// 不是降级方案。
///
/// 实现者必须做到：
///   * 落盘位置是 `Directory.systemTemp` 下的新建目录，不碰用户目录；
///   * 解包用 `zip_extract.dart`，条目名不可信（zip-slip 防护在那边）；
///   * 失败抛 `CoreError('DownloadFailed', detail:…)`，不许静默返回空。
abstract class DownloadableAdapter {
  /// 把一条**存储侧**路径（如 `/vol2/1000/备份/a.pdf`）下载并解包，
  /// 返回可直接交给 `NSWorkspace.open` 的本地路径。
  ///
  /// 单文件 zip → 返回解出的那个文件；目录 zip → 返回解出的目录本身。
  Future<DownloadedArtifact> downloadToTemp(String logicalPath, Cancellation cancel);
}

/// 一次成功下载的产物。
class DownloadedArtifact {
  /// 本地文件或目录的绝对路径（临时目录内）。
  final String localPath;
  /// 远端条目的名字（结果行自己的 name），用于诊断与界面提示。
  final String name;
  /// 解包后的大小（字节）。目录或未知时为 null——不拿 0 冒充。
  final int? byteSize;
  const DownloadedArtifact({required this.localPath, required this.name, this.byteSize});
}

/// 能把逻辑路径解析成「SMB 共享名 + 相对段」的适配器实现这个接口。
///
/// ── 为什么需要它 ────────────────────────────────────────────────
/// 群晖那类设备的卷根就是 SMB 共享名（`/video/…` → `smb://主机/video/…`），
/// `BrandSession` 拿卷根首段拼就行。飞牛（fnOS）不是：它的 SMB 共享是
/// **任意文件夹**（`file.share.list` 返回 `path: vol2/1000/备份` 这样的
/// 存储路径），共享名要靠 `file.share.info` 单独问（2026-10-29 实测返回
/// `shareName: "备份"`）。拿卷根首段（`vol2`）当共享名必然弹出
/// 「连接不上」——那是个假目标。
///
/// 实现者必须做到：
///   * 共享名单**只在会话建立时**取一次（`shareRoots()`），不许每行都发请求；
///   * 解析不出（路径不在任何共享前缀之下，或 `file.share.info` 没问出）
///     返回 null，**不许猜**（2026-10-29 审查：拿路径末段当共享名，
///     管理员起了别名就会打开错误的共享）；
///   * 共享名以 `file.share.info` 的 `shareName` 为准。
abstract class SmbShareResolving {
  /// 逻辑路径（`/vol2/1000/备份/sub/x.pdf`）→ 共享名 `备份` + 相对段
  /// `[sub, x.pdf]`。不在任何共享前缀下时返回 null。
  SmbShareMapping? smbShareFor(String logicalPath);

  /// 这个会话**已经解析出几条共享**；还没问过时为 null。
  ///
  /// 存在的唯一理由是诊断：打开链退到网页时，得能分清是
  /// 「共享表压根没取到（0 条）」还是「取到了，但这条路径不在任何共享前缀下」。
  /// **默认 null，不要返回 0** —— 0 是「问了，一条都没有」的断言。
  int? get resolvedShareCount => null;
}

/// 一次成功解析的 SMB 映射。
class SmbShareMapping {
  /// SMB 共享名（`file.share.info` 的 `shareName`）。
  final String shareName;
  /// 去掉共享前缀后的相对路径段（已经不含空段）。
  final List<String> relativeSegments;
  const SmbShareMapping({required this.shareName, required this.relativeSegments});
}


/// 「登录不靠密码、靠一串可续期的令牌」的适配器实现这个接口。
///
/// ── 为什么需要它 ────────────────────────────────────────────────
/// 闪寻把「下次还能连上」所需的东西存在本机凭据文件里，只有一个槽位。
/// 账密品牌的槽位里放密码；飞牛（fnOS）没有密码 —— 它走 OAuth 授权码，
/// 换来的是 access + refresh 两枚令牌。若不为它留一条回传通道，就会出现
/// 两种都不可接受的结果：
///   * 每次启动 App 都要用户再去浏览器授权一遍；
///   * 或者槽位里存了个空串，界面显示「已记住」，下次照样连不上。
///
/// 所以槽位的语义是「**下次登录所需的那一串东西**」：账密品牌是密码，
/// 这里则是 refresh token。由适配器自己回答那串东西是什么，
/// 上层只负责原样保管、原样回传（回传走 `login(password:)`）。
///
/// 做成**标记接口**而不是往 `NasBrandAdapter` 里加抽象成员：
/// 四个账密适配器是 `implements`，抽象类里的默认实现不会被继承，
/// 加进去等于逼它们各写一行「我返回 null」——除了噪声没有任何收益。
abstract class SessionSecretProviding {
  /// 下次可直接续期的凭据；拿不到时返回 null（比如还没登录）。
  String? get sessionSecret;
}

/// 「设备认得我的账号名」的品牌实现这个接口。
///
/// ── 为什么需要它 ────────────────────────────────────────────────
/// 打开链要回答「这台 Mac 上已有的挂载，是不是这台 NAS 的这个共享」
/// （见 Swift 侧 `SMBMountCandidate.matching`）。判定用的证据是
/// **共享名 + 登录账号**：来源里填的是域名、访达里挂的是局域网 IP 时，
/// 域名与 IP 之间没有可靠换算，只剩「谁在登录这个共享」这一条旁证。
///
/// 账密品牌的账号就在用户填的表单里（`config.username`）。飞牛没有表单账号
/// ——它走 OAuth 授权码，来源配置里的账号字段恒为空串，于是那条旁证永远
/// 拿不到，打开一律退回网页（2026-10-29 真机：文件就在 `/Volumes/共享文档`
/// 下可读，双击却打开飞牛的登录页）。设备自己在 `user.info` 里报了
/// `userInfo.user`，这就是 SMB 登录用的那个账号，回传上去即可。
///
/// 做成**可选接口**而不是往 `NasBrandAdapter` 里加抽象成员：四个账密适配器是
/// `implements`，抽象类里的默认实现不会被继承（同 `SessionSecretProviding`）。
abstract class SignedInAccountProviding {
  /// 设备侧账号名（`user.info` 的 `userInfo.user`）；还没登录时返回 null。
  ///
  /// ★ 这是**登录名**，不是昵称：它要跟 SMB 挂载里的登录账号逐字比对。
  ///   拿不到就返回 null，不许拿别的东西顶（顶错了会把别的共享认成本来源）。
  String? get signedInAccount;
}

/// 授权页上的一项权限。
class AuthorizationScopeOption {
  /// 授权协议里的 scope 标识（如 `trim.file.read`）。
  final String id;

  /// 给用户看的中文说明（弹窗里逐项展示的就是它）。
  final String label;

  /// 是否为闪寻运行所必需。必需项在界面上锁定勾选；可选项默认不申请。
  final bool required;

  const AuthorizationScopeOption({
    required this.id,
    required this.label,
    required this.required,
  });

  Map<String, Object?> toJson() => {'id': id, 'label': label, 'required': required};
}

/// 授权页权限可由用户增减的品牌实现这个接口（目前只有飞牛 fnOS）。
///
/// ── 为什么做成可选接口 ────────────────────────────────────────
/// 账密品牌没有「授权页」，权限跟着账号走；把这个形状塞进
/// `NasBrandAdapter` 等于逼每个适配器都实现一套无意义的空表。
/// 与 `SessionSecretProviding` 同一理由：`implements` 继承不了默认实现，
/// 标记接口让不相关的品牌一行不改。
abstract class AuthorizationScopeCatalog {
  /// 完整清单（必需项在前）。界面弹窗逐项展示；必需项锁定勾选，
  /// 可选项默认不勾 —— **不申请就不出现在授权页**，而不是授权后再解释。
  List<AuthorizationScopeOption> get authorizationScopes;

  /// 界面勾选的可选 scope。登录（第一段）前由 `BrandSession` 写入；
  /// 授权地址按「必需 + 已勾选可选」拼 scope 参数。
  set requestedOptionalScopes(List<String> ids);
}

/// 品牌能力声明。**这是给界面看的，必须诚实**：
/// 没在真机上验证过的能力写 true 就是在骗用户。
class BrandCapabilities {
  /// 是否有服务端原生搜索。
  final bool nativeSearch;

  /// 是否已在真机上验证过（而不是只在模拟/本机 fixture 上跑通）。
  final bool verifiedOnDevice;

  /// 搜索语义的一句话说明，直接展示给用户。
  final String querySemantics;

  /// 验证情况备注。未验证时这里必须写清「未验证」，不能留空。
  final String notes;

  const BrandCapabilities({
    required this.nativeSearch,
    required this.verifiedOnDevice,
    required this.querySemantics,
    required this.notes,
  });

  Map<String, Object?> toJson() => {
    'nativeSearch': nativeSearch,
    'verifiedOnDevice': verifiedOnDevice,
    'querySemantics': querySemantics,
    'notes': notes,
  };
}

/// 把 `AdapterFailure` 翻成线上 `CoreError`。
///
/// 放在这一层是因为它是**唯一的边界**：适配器内部用中文可读的
/// `AdapterFailure`，往 Swift 出去的是机器可判别的 `CoreError`。
CoreError toCoreError(Object error) {
  if (error is AdapterFailure) {
    return CoreError(error.kind, code: error.apiCode, detail: error.message);
  }
  if (error is CoreError) return error;
  return CoreError('UnknownFailure', detail: '$error');
}
