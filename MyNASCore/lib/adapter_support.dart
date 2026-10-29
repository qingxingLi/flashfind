// 品牌适配器的共用小件（零 pub 依赖）。
//
// 上游四个适配器除了 dio / path 之外，还依赖三样内部东西：
//   my_nas/core/utils/logger.dart       —— 日志
//   my_nas/core/errors/*.dart           —— 异常类型
//   my_nas/core/i18n/app_l10n.dart      —— Flutter 本地化字符串
//
// 前两样在这里用等价物替掉；第三样**不替代**——闪寻是中文单语产品，
// 移植时把 `appL10n.xxxApiAuthFailed` 之类的键**直接换成中文文案**，
// 比维护一套几十个键的字符串表更实在。
import 'dart:convert';
import 'dart:io';

import 'error_kinds.dart';
import 'protocol.dart';

/// 适配器日志。
///
/// 上游是 Flutter 的 logger 包，会落盘到 app.log。这里默认**静默**：
/// 闪寻的核心是子进程，stdout 走的是与 Swift 的协议通道，
/// 往里混日志会污染协议帧。需要排查时用 `FF_ADAPTER_LOG=1` 打开，
/// 且**只写 stderr**——协议通道不受影响。
///
/// 另一条硬规矩：**不打印凭据**。URL 的 query 一律抹掉再打，
/// 因为 qnap 的会话标识、webdav 的签名串都可能挂在 query 上。
class Logger {
  static bool enabled = _envEnabled();

  static bool _envEnabled() {
    // 编译期定义优先（`dart compile exe --define=FF_ADAPTER_LOG=true`）。
    if (const bool.fromEnvironment('FF_ADAPTER_LOG')) return true;
    // 运行期环境变量兜底，方便直接 `FF_ADAPTER_LOG=1 dart run`。
    try {
      final value = Platform.environment['FF_ADAPTER_LOG'];
      return value == '1' || value == 'true';
    } catch (_) {
      return false;
    }
  }

  /// 去掉 query 与 userInfo，只留 scheme/host/path。
  static String safeUrl(String url) {
    final parsed = Uri.tryParse(url);
    if (parsed == null) return '<unparsable-url>';
    if (parsed.scheme.isEmpty) return parsed.path.isEmpty ? url : parsed.path;
    return Uri(
      scheme: parsed.scheme,
      host: parsed.host,
      port: parsed.port,
      path: parsed.path,
    ).toString();
  }

  void d(String message, [Object? error]) => _write('D', message, error);
  void i(String message, [Object? error]) => _write('I', message, error);
  void w(String message, [Object? error]) => _write('W', message, error);
  void e(String message, [Object? error]) => _write('E', message, error);

  void _write(String level, String message, Object? error) {
    if (!enabled) return;
    // stderr 是诊断通道，不是协议通道。
    // ignore: avoid_print
    print('[adapter/$level] $message${error == null ? '' : ' :: $error'}');
  }
}

/// `package:path` 的最小等价物。
///
/// 实测四个适配器只用到三个函数：`basename`(9) / `extension`(8) / `dirname`(3)。
/// 与其 vendored 整个 path 包，不如按 NAS 场景的语义自己实现——
/// 因为 NAS 逻辑路径**恒为 POSIX 风格**（`/` 分隔），不需要处理 Windows 盘符，
/// 也就不需要 path 包里那一整套 context 抽象。
class PathCompat {
  /// 取路径最后一段。`/a/b/c.txt` → `c.txt`；`/` → `''`。
  static String basename(String path) {
    if (path.isEmpty) return '';
    var p = path;
    while (p.length > 1 && p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    final index = p.lastIndexOf('/');
    if (index < 0) return p;
    return p.substring(index + 1);
  }

  /// 取扩展名，**含点**。`a.tar.gz` → `.gz`；无扩展名 → `''`。
  /// 与 package:path 的 `extension` 语义一致：`.bashrc` 这种点开头
  /// 「无扩展名」的文件返回 `''`（`lastIndexOf('.') == 0` 是边界，不是扩展名）。
  static String extension(String path) {
    final name = basename(path);
    final index = name.lastIndexOf('.');
    if (index <= 0) return '';
    return name.substring(index);
  }

  /// 去掉扩展名。`/a/b.txt` → `/a/b`。
  static String withoutExtension(String path) {
    final ext = extension(path);
    if (ext.isEmpty) return path;
    return path.substring(0, path.length - ext.length);
  }

  /// 取父目录。`/a/b/c` → `/a/b`；`/a` → `/`。
  static String dirname(String path) {
    if (path.isEmpty) return '.';
    var p = path;
    while (p.length > 1 && p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    final index = p.lastIndexOf('/');
    if (index < 0) return '.';
    if (index == 0) return '/';
    return p.substring(0, index);
  }

  /// 拼接。任一段为空则忽略；结果恒以单个 `/` 分隔。
  static String join(String a, String b) {
    if (a.isEmpty) return b;
    if (b.isEmpty) return a;
    final left = a.endsWith('/') ? a.substring(0, a.length - 1) : a;
    final right = b.startsWith('/') ? b.substring(1) : b;
    return '$left/$right';
  }
}

/// 适配器层的失败。
///
/// 与 `CoreError` 的分工：`CoreError` 是**线上协议**的形状（会被序列化给 Swift），
/// 这里的是**适配器内部**的形状，保留中文可读文案与设备返回的原始码。
/// harness 负责在边界上把 `AdapterFailure` 翻译成 `CoreError`。
class AdapterFailure implements Exception {
  /// 机器可判别的种类，会翻成线上错误码。
  final String kind;

  /// 用户可读的中文原因。规划书要求这类失败必须说清「发生了什么、下一步做什么」。
  final String message;

  /// 设备返回的原始错误码（如果有）。
  final int? apiCode;

  const AdapterFailure(this.kind, this.message, {this.apiCode});

  /// 翻成核心错误：**kind 与给人看的那句话都要留住。**
  ///
  /// 这一步曾经整条缺失，代价是一个真实故障：
  /// 适配器明明抛出了「无法连接 WebDAV 服务（TLS 握手失败）」，
  /// 但 `AdapterFailure` 不是 `CoreError`，一路冒到 `command()` 的兜底分支，
  /// 被压成 `const CoreError('ProtocolViolation')` —— 界面据此显示
  /// 「设备返回的内容不符合预期」，而真实原因（这台设备的 5005 端口
  /// 只讲明文 HTTP）一个字都没传出去。用户能看到的只有一个「连接失败」。
  ///
  /// 分工沿用 `CoreError` 的约定：`reason` 走界面（可含设备原文），
  /// `detail` 只放机器标签（会被产品端写进诊断文件，不得含路径等用户数据）。
  CoreError toCoreError({String api = '', String method = ''}) => CoreError(
    kind,
    api: api,
    method: method,
    code: apiCode,
    detail: 'adapter:$kind',
    reason: message,
  );

  @override
  String toString() => 'AdapterFailure($kind): $message';
}

/// 常见失败的构造快捷方式。四个品牌共用，保证文案口径一致。
class AdapterFailures {
  static AdapterFailure authFailed([String? detail, int? code]) => AdapterFailure(
    ErrorKind.authenticationFailed,
    detail ?? '账号或密码不正确',
    apiCode: code,
  );

  static AdapterFailure needsOTP([int? code]) =>
      AdapterFailure(ErrorKind.needsOTP, '该账号需要动态验证码', apiCode: code);

  static AdapterFailure sessionExpired([int? code]) =>
      AdapterFailure(ErrorKind.sessionExpired, '登录会话已失效，请重新连接', apiCode: code);

  static AdapterFailure permissionDenied([String? detail, int? code]) =>
      AdapterFailure(ErrorKind.permissionDenied, detail ?? '该账号没有访问此位置的权限', apiCode: code);

  static AdapterFailure unsupported([String? detail]) => AdapterFailure(
    ErrorKind.unsupportedApi,
    detail ?? '该设备没有闪寻需要的搜索接口',
  );

  static AdapterFailure protocolViolation([String? detail]) =>
      AdapterFailure(ErrorKind.protocolViolation, detail ?? '设备返回了无法识别的数据格式');

  static AdapterFailure network([String? detail]) =>
      AdapterFailure(ErrorKind.networkFailure, detail ?? '无法连接到设备');

  /// 连接超时。与 [network] 分开：超时时用户该查的是「网络慢/设备忙」，
  /// 而连不上该查的是「地址对不对、设备在不在线」。
  static AdapterFailure timedOut([String? detail]) =>
      AdapterFailure(ErrorKind.timedOut, detail ?? '连接设备超时');

  /// TLS 握手/证书层失败（NAS 自签证书最常见）。
  ///
  /// **不能**报成认证失败：那会让用户去改密码，而真正要处理的是证书信任。
  static AdapterFailure tlsRejected([String? detail]) => AdapterFailure(
    ErrorKind.tlsRejected,
    detail ?? '和设备建立不起加密连接，请检查证书是否受信任',
  );

  static AdapterFailure pathMissing([String? detail]) =>
      AdapterFailure(ErrorKind.pathMissing, detail ?? '该位置不存在或已被移动');

  /// 还没有真机验证过的品牌，在能力声明里如实说明。
  static AdapterFailure unverified(String vendor) => AdapterFailure(
    ErrorKind.unverifiedAdapter,
    '$vendor 适配器尚未在真机上验证过',
  );
}

/// 上游用 `jsonEncode` 拼请求体，这里保持同一格式，便于逐字段比对。
String encodeJsonBody(Object? data) => jsonEncode(data);
