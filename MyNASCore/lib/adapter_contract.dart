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

  Future<LoginOutcome> login({
    required String username,
    required String password,
    String? otpCode,
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
