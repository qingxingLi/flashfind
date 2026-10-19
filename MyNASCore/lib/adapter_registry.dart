// 品牌适配器注册表：把 `vendor` 字符串映射到具体适配器。
//
// 契约：Swift 侧 `Vendor.rawValue` 必须与这里的字符串一一对应。
// 新增品牌时**两边一起改**，否则会出现「界面能选、核心不认」的静默失败。
import 'adapters/qnap.dart';
import 'adapters/ugreen.dart';
import 'adapters/webdav.dart';
import 'adapter_contract.dart';
import 'dio_compat.dart';
import 'protocol.dart';

/// 真机验证过的品牌。只有这一档可以对用户说「能用」。
const Set<String> stableVendors = {'webdav'};

/// 已移植但**没有真机证据**的品牌：能跑不代表对，界面必须照
/// `capabilities.verifiedOnDevice` 说话。
const Set<String> experimentalVendors = {'qnap', 'ugreen'};

/// 走原生 DSM 路径的品牌，不经过本注册表。
const String synologyVendor = 'synology';

/// 移植过、但已确认与真实设备不符的品牌。
///
/// 旧 REST 实现已删除，**不随公开仓分发**：公开仓采用全新单 commit 历史，
/// 在那里查不到那份实现。留着一份已知错误的 700 行实现只会让人以为「修修就能用」，
/// 也会让 analyzer 必须为一份不编译的代码长期开排除。
/// 留这张名单是为了「为什么用不了」有处可查：
/// 真实设备确认原生文件搜索使用 WebSocket + HMAC，而不是那份 REST 实现假设的 HTTP。
const Set<String> retiredVendors = {'fnos'};

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
