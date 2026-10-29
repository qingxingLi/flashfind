// 品牌适配器注册表：把 `vendor` 字符串映射到具体适配器。
//
// 契约：Swift 侧 `Vendor.rawValue` 必须与这里的字符串一一对应。
// 新增品牌时**两边一起改**，否则会出现「界面能选、核心不认」的静默失败。
import 'adapters/fnos.dart';
import 'adapters/openlist.dart';
import 'adapters/qnap.dart';
import 'adapters/ugreen.dart';
import 'adapters/webdav.dart';
import 'adapter_contract.dart';
import 'dio_compat.dart';
import 'protocol.dart';

/// 真机验证过的品牌。只有这一档可以对用户说「能用」。
///
/// `openlist` 于 2026-10-24 在真实实例（v4.1.10 / commit e3c664f）上量过登录、
/// 列存储、限定目录搜索与分页，证据见
/// `00-项目管理/任务交付/OL-AUTH-02-OpenList真实契约验证-20261024.md`。
const Set<String> stableVendors = {'webdav', 'openlist'};

/// 已移植但**没有真机证据**的品牌：能跑不代表对，界面必须照
/// `capabilities.verifiedOnDevice` 说话。
///
/// `fnos` 于 2026-10-28 重新加入：旧实现（假设 REST 接口）已删除，
/// 新实现按官方端点文档 + 对真实设备的直连实测重写（OAuth 授权码 + PKCE、
/// 逐卷 `appcgi.finder.fileSearch`）。**端点契约是真机上量的，
/// 但这份 Dart 实现本身还没跑过真机**，所以留在这一档而不是 stableVendors。
const Set<String> experimentalVendors = {'qnap', 'ugreen', 'fnos'};

/// 走原生 DSM 路径的品牌，不经过本注册表。
const String synologyVendor = 'synology';

/// 移植过、但已确认与真实设备不符、且**没有重做**的品牌。
///
/// 旧的 fnOS REST 实现曾在这里（真实设备确认原生搜索走 WebSocket + HMAC，
/// 不是那份实现假设的 HTTP）。2026-10-28 按官方文档重写后已移出本名单，
/// 名单本身保留：下一个被证伪的品牌要有个地方记「为什么用不了」。
const Set<String> retiredVendors = <String>{};

bool hasBrandAdapter(String vendor) =>
    stableVendors.contains(vendor) || experimentalVendors.contains(vendor);

/// 按品牌建适配器。
///
/// `endpoint` 是用户填的完整地址（含 scheme/port）；`allowInsecureHTTP`
/// 决定是否放行明文 http —— 这台设备的性质由来源配置显式决定，
/// 而不是由适配器默默降级。
NasBrandAdapter createBrandAdapter(
  String vendor, {
  required String endpoint,
  required Duration budget,
  bool allowInsecureHTTP = false,
}) {
  final dio = Dio(
    BaseOptions(
      baseUrl: endpoint,
      connectTimeout: budget,
      receiveTimeout: budget,
      sendTimeout: budget,
    ),
  )..allowInsecureHTTP = allowInsecureHTTP;

  switch (vendor) {
    case 'qnap':
      return QnapAdapter(dio: dio);
    case 'ugreen':
      return UGreenAdapter(dio: dio);
    case 'webdav':
      return WebDavAdapter(dio: dio);
    case 'openlist':
      return OpenListAdapter(dio: dio);
    case 'fnos':
      return FnOSAdapter(dio: dio);
    case synologyVendor:
      // 群晖不走这里：它有自己的传输栈（证书固定 + CSRF + 任务模型）。
      throw const CoreError('UnsupportedVendor');
    default:
      throw const CoreError('UnsupportedVendor');
  }
}

/// 没有实现的品牌，给一句「为什么」。
///
/// 用户听到「上游已有 FnOSAdapter」和听到「暂不支持」是完全不同的感受 ——
/// 这里要把「没接」说得具体、可核对，而不是含糊带过。
String unsupportedVendorReason(String vendor) {
  if (vendor == synologyVendor) return '群晖走原生路径，不应到这来';
  if (retiredVendors.contains(vendor)) {
    return '$vendor 适配器已下线：既有实现与真实设备协议不符';
  }
  return '闪寻还没有接入 $vendor 适配器';
}
