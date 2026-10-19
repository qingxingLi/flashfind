/// 核心对外错误 `kind` 的**唯一登记表**。
///
/// ## 为什么要有这张表
///
/// `kind` 是 Dart 核心与 Swift 客户端之间的**契约**：核心用它说「出了什么事」，
/// Swift 用它决定给用户看哪句话。这张表若不存在，两边各自写字面量：
///
/// * Dart 在 `AdapterFailure('HttpFailure', …)`、`CoreError('TLSRejected')`
///   里直接写字符串，散落在 8 个文件、50 余处；
/// * Swift 在 `NASSearchFailureText.describe` 里另抄了一张 switch 表。
///
/// 于是新增 kind 时没人知道对面有没有。真实后果：Dart 加了 `HttpFailure`
/// （HTTP/TLS 层失败），Swift 表里没有 ⇒ 界面只能落到兜底分支，显示
/// 「设备返回了未预期的错误（HttpFailure）」——一个技术名词给用户，
/// 而核心明明知道是「文件流请求失败（HTTP 500）」。
///
/// ## 为什么分两类
///
/// 要求「每个 kind 都配一句中文」会逼着给 `SourceExists`（启动期来源重名）
/// 这类内部错误编一句用户文案，那比没有更糟——它会把内部状态泄漏成
/// 用户看得见的提示。所以：
///
/// * [userFacing]：会出现在失败提示里，**Swift 侧必须有一句中文主句**，
///   由 `AdapterErrorKindParityTests` 逐条盯着；
/// * [internal]：连接/启动/协议层内部使用，界面另有专门处理或根本不该出现，
///   只登记、不要求文案。
///
/// ## 两侧怎么锁住
///
/// * Dart：`test_error_kinds.dart` 扫描 `lib/` 与 `bin/` 里的
///   `AdapterFailure('…'` / `CoreError('…'` 字面量，断言每一个都在这张表里
///   （新增 kind 忘记登记 ⇒ 测试失败）；
/// * Swift：`AdapterErrorKindParityTests` 读 `error_kinds.json`，
///   断言 Dart 用过的 kind 全被 Swift 认得、且 userFacing 全有主句。
library;

/// 核心错误种类常量。改动这里的**取值**等于改线上协议，两侧都要跟。
class ErrorKind {
  const ErrorKind._();

  // —— 认证 / 账号 ——
  static const authenticationFailed = 'AuthenticationFailed';
  static const accountDisabled = 'AccountDisabled';
  static const passwordLifecycle = 'PasswordLifecycle';
  static const needsOTP = 'NeedsOTP';
  static const otpRejected = 'OTPRejected';
  static const ipBlocked = 'IPBlocked';
  static const permissionDenied = 'PermissionDenied';
  static const sessionExpired = 'SessionExpired';
  static const needsAuth = 'NeedsAuth';
  static const identityUnverified = 'IdentityUnverified';

  // —— 传输 / 网络 ——
  static const networkFailure = 'NetworkFailure';
  static const timedOut = 'TimedOut';
  static const cancelled = 'Cancelled';
  static const tlsRejected = 'TLSRejected';
  static const httpFailure = 'HttpFailure';
  static const httpDenied = 'HttpDenied';
  static const redirectRejected = 'RedirectRejected';
  static const responseTooLarge = 'ResponseTooLarge';
  static const unsafeEndpoint = 'UnsafeEndpoint';
  static const originChanged = 'OriginChanged';
  static const unsafeApiPath = 'UnsafeApiPath';

  // —— 协议 / 解析 ——
  static const protocolViolation = 'ProtocolViolation';
  static const unsupportedFormat = 'UnsupportedFormat';
  static const directoryUnstable = 'DirectoryUnstable';
  static const incompleteResponse = 'IncompleteResponse';
  static const resultsNotReady = 'ResultsNotReady';
  static const unknownSubmission = 'UnknownSubmission';
  static const inputTooLarge = 'InputTooLarge';

  // —— 搜索能力 ——
  static const unsupportedApi = 'UnsupportedApi';
  static const unsupportedSearchNoFallback = 'UnsupportedSearchNoFallback';
  static const unsupportedVendor = 'UnsupportedVendor';
  static const unverifiedAdapter = 'UnverifiedAdapter';
  static const resultLimit = 'ResultLimit';
  static const rateLimited = 'RateLimited';
  static const apiError = 'ApiError';

  // —— 范围 / 路径 ——
  static const scopeUnset = 'ScopeUnset';
  static const scopeDenied = 'ScopeDenied';
  static const scopeUnavailable = 'ScopeUnavailable';
  static const emptyScope = 'EmptyScope';
  static const pathMissing = 'PathMissing';
  static const unsafeLogicalPath = 'UnsafeLogicalPath';
  static const unsafeOpenTarget = 'UnsafeOpenTarget';

  // —— 证书信任 ——
  static const invalidTrustConfiguration = 'InvalidTrustConfiguration';
  static const explicitCertificateConfirmationRequired =
      'ExplicitCertificateConfirmationRequired';
  static const trustStoreFailure = 'TrustStoreFailure';

  // —— 会话 / 命令（核心进程内部）——
  static const unknownSource = 'UnknownSource';
  static const sourceExists = 'SourceExists';
  static const authInProgress = 'AuthInProgress';
  static const unsupportedCommand = 'UnsupportedCommand';
  static const unsupportedMode = 'UnsupportedMode';
  static const shuttingDown = 'ShuttingDown';

  // —— 兜底 ——
  static const unexpectedFailure = 'UnexpectedFailure';
  static const unknownFailure = 'UnknownFailure';

  /// 会出现在用户可见的失败提示里的种类。
  ///
  /// **Swift 必须为这里的每一项都准备一句中文主句**，否则用户体验就是
  /// 一个技术名词。新增项时同步改 Swift 的 `NASSearchFailureText.sentences`，
  /// 不然 `AdapterErrorKindParityTests` 会红。
  static const Set<String> userFacing = {
    authenticationFailed,
    accountDisabled,
    passwordLifecycle,
    needsOTP,
    otpRejected,
    ipBlocked,
    permissionDenied,
    sessionExpired,
    needsAuth,
    identityUnverified,
    networkFailure,
    // 这两个由取消令牌作为 kind 产生（不是某处写出来的字面量），
    // 但同样会出现在提示里，所以归在需要文案的一侧。
    timedOut,
    cancelled,
    tlsRejected,
    httpFailure,
    httpDenied,
    redirectRejected,
    responseTooLarge,
    unsafeEndpoint,
    protocolViolation,
    directoryUnstable,
    incompleteResponse,
    resultsNotReady,
    unknownSubmission,
    unsupportedApi,
    unsupportedSearchNoFallback,
    unsupportedVendor,
    unverifiedAdapter,
    resultLimit,
    rateLimited,
    apiError,
    scopeUnset,
    scopeDenied,
    scopeUnavailable,
    emptyScope,
    pathMissing,
    unsafeLogicalPath,
    invalidTrustConfiguration,
    explicitCertificateConfirmationRequired,
    unexpectedFailure,
    unknownFailure,
  };

  /// 只登记、不配用户文案的种类。
  ///
  /// 它们要么在连接向导里有专门的界面处理，要么根本不该出现在搜索提示里。
  /// 一旦其中某个开始出现在失败提示上，就应当把它移到 [userFacing] 并配文案。
  static const Set<String> internal = {
    unsafeApiPath,
    originChanged,
    unsupportedFormat,
    unsafeOpenTarget,
    trustStoreFailure,
    unknownSource,
    sourceExists,
    authInProgress,
    unsupportedCommand,
    unsupportedMode,
    shuttingDown,
    inputTooLarge,
  };

  /// 全部已知种类。两类之外不应有第三个去处——漏登记等于界面没有文案。
  static Set<String> get all => {...userFacing, ...internal};
}
