import 'dart:async';
import 'dart:convert';

/// 核心协议修订号。
///
/// 必须与 Swift 侧 `MyNASProcessBridge.expectedCoreRevision` 保持一致；
/// 改协议（新增/重命名事件、调整字段语义）时两边一起加一。
///
/// 它防的是一类极难定位的故障：只改了 Dart 源码、忘了重新编译
/// `Resources/MyNAS/bin/mynas-core`，于是客户端是新版、核心还是旧版。
/// 事件名对不上，登录请求发出去就石沉大海——界面既不报错也不超时，
/// 用户和开发者都不知道该往哪看。有了这个号，第一条消息就能把话说清楚。
///
/// 修订记录：
///   1 —— 初版（群晖单品牌）。
///   2 —— 多品牌：discover 新增 `vendor` 与 `allowInsecureHTTP`；
///        capabilities 新增 `verifiedOnDevice` / `notes` / `vendor`；
///        sessionState / authState 新增 `managerUnknown`（品牌协议没有
///        is_manager 的等价物，不能拿 false 冒充「普通账号」）。
///   3 —— 就绪判据改为「拿到 total」而不是 finished：
///        `resultState` 新增 `deviceBusy`（设备侧搜索任务未就绪，属可重试的
///        中间态，**不是失败**）；结果事件新增 `unparsedCount`（有行无法解析
///        时如实告知，不静默丢行）。
///   4 —— 结果事件新增 `duplicateCount`（设备重复返回、已被合并的条数）；
///        分页重复路径由「整次搜索作废」改为去重计数。就绪轮询的 `limit`
///        由 0 改为 1（`limit=0` 在 `Search.list` 上的语义从未真机验证过）。
///        原生助手的失败状态由单一 `ProtocolViolation` 拆成
///        `EmptyBody` / `BodyTooLarge` / `NonJSONBody` / `InvalidTimeout`
///        （不进协议，只进诊断 detail），并把响应体上限由 256 KB 提到 16 MB。
///   5 —— 错误事件新增 `reason`：**适配器写好的那句原因不再被丢掉**。
///        品牌适配器（qnap / ugreen / fnos / webdav）抛的是 `AdapterFailure`，
///        它自带机器可判别的 `kind` 与「给人看的中文原因」；此前没人把它翻成
///        `CoreError`，于是被兜底分支压成一个空洞的 `ProtocolViolation` ——
///        用户看到的「连接失败」里，最要紧的那句「TLS 握手失败」
///        正是在这一步消失的。同时兜底分支不再冒充 `ProtocolViolation`，
///        改报 `UnexpectedFailure` 并把原始异常写到 stderr。
///   6 —— 就绪判据补上另一半：`finished=false` 时的 `total` 是**还在涨的
///        中间数**，不是全集。真机实测：就绪轮询 limit=1 拿到几十条且
///        `finished=false`，第一页 limit=200 拿到的却是另一个更大的全集。
///        旧判据在中间态上放行，于是分页的
///        「total 一致性」断言必炸，用户看到
///        「搜索失败—设备返回的分页数据不完整（IncompleteResponse）」。
///        现在：有 total **且** `finished != false` 才算就绪；「还在扫描」
///        单独给 24 轮预算。事件与字段没有增删，但**同一输入下的结果状态
///        会变**（失败 → 正常完成），因此仍要升号：旧客户端配新核心会把
///        修复后的成功路径当成未知状态。
///   7 —— 搜索命令新增**可选**字段 `roots`：把本次搜索限定到已授权根的
///        子集。核心侧与已授权范围求交集，交集为空即报 ScopeDenied。
///        字段可选 ⇒ 旧客户端不发它时行为完全不变；但它改变了「同一输入
///        下的搜索范围」，因此升号：旧客户端配新核心会忽略这个限定，
///        表现为「界面显示了限定位置，设备却仍在扫全部共享」。
const int coreRevision = 7;

class CoreError implements Exception {
  final String kind, api, method;
  final int? code, httpStatus;
  // Diagnostic only: a transport state label, never response content or credentials.
  // 可以含路径的文案（例如「WebDAV 路径不存在：/x/y」）**不要**放这里，
  // 它会被产品端写进诊断文件；那种话放 `reason`。
  final String? detail;
  /// 给人看的一句话，可以含设备原文（HTTP 状态、TLS 结果等）。
  ///
  /// 与 `detail` 的分工：`detail` 会被产品端落进诊断文件，因此**不得含用户数据**；
  /// `reason` 只走界面，产品端不写盘 —— 这样才能既让用户看懂，又不把
  /// 目录名之类的信息留在日志里。为 null 时界面退回按 `kind` 生成文案。
  final String? reason;
  const CoreError(this.kind, {this.api = '', this.method = '', this.code, this.httpStatus, this.detail, this.reason});
  Map<String, Object?> toJson() => {'kind': kind, 'api': api, 'method': method, 'apiCode': code, 'httpStatus': httpStatus, 'retryable': false, if (detail != null) 'detail': detail, if (reason != null) 'reason': reason};
  @override String toString() => 'CoreError($kind)'; // No raw transport detail.
}
String requireString(Map m, String k) { final v = m[k]; if (v is! String || v.isEmpty) throw const CoreError('ProtocolViolation'); return v; }
int requireInt(Map m, String k) { final v = m[k]; if (v is! int || v < 0) throw const CoreError('ProtocolViolation'); return v; }
bool requireBool(Map m, String k) { final v = m[k]; if (v is! bool) throw const CoreError('ProtocolViolation'); return v; }
int? optionalNonnegativeInt(Map m, String k) => m[k] == null ? null : requireInt(m, k);

/// 宽松整数：缺失、类型不符、负数**一律返回 null（表示「未知」）**，绝不抛异常。
///
/// 与 [requireInt] 的分工必须说清楚，否则很容易把两者混用成「全宽松」：
///   * [requireInt] 用于**协议必需**字段——它缺失就说明设备行为变了，
///     那是真问题，必须报错而不是拿 0 冒充（契约：不存在字段不能伪装 0/false）。
///   * 这个函数用于设备**可以不给、也可能给哨兵值**的可选字段
///     （`total` / 分页 `offset` / 文件 `size` / 时间戳）。
///     给不出来时正确答案是「未知」，而不是「0」——更不是让整次搜索失败。
int? lenientNonnegativeInt(Map m, String k) { final v = m[k]; return (v is int && v >= 0) ? v : null; }
Map<String, dynamic> object(Object? v) { if (v is! Map<String, dynamic>) throw const CoreError('ProtocolViolation'); return v; }
List<dynamic> array(Map m, String k) { final v = m[k]; if (v is! List) throw const CoreError('ProtocolViolation'); return v; }

class Cancellation {
  bool cancelled = false;
  String reason = 'Cancelled';
  final listeners = <void Function()>[];
  void cancel([String why = 'Cancelled']) { if (cancelled) return; cancelled = true; reason = why; for (final f in List.of(listeners)) { f(); } listeners.clear(); }
  void check() { if (cancelled) throw CoreError(reason); }
  Future<void> delay(Duration d) async {
    check(); final c = Completer<void>(); late Timer timer;
    void abort() { timer.cancel(); if (!c.isCompleted) c.completeError(CoreError(reason)); }
    timer = Timer(d, () { if (!c.isCompleted) c.complete(); }); listeners.add(abort);
    try { await c.future; } finally { listeners.remove(abort); timer.cancel(); }
  }
}
class ApiDescriptor {
  final String path, format;
  final int version;
  ApiDescriptor(this.path, this.version, this.format) {
    if (path.isEmpty || path.contains(RegExp(r'[:?#%\\]')) || path.startsWith('/') || path.split('/').any((s) => s.isEmpty || s == '.' || s == '..')) throw const CoreError('UnsafeApiPath');
    if (format != 'JSON' && format != 'legacy') throw const CoreError('UnsupportedFormat');
  }
  String get webPath => '/webapi/$path';
}
class WireRequest {
  final String api, method, path, sourceID;
  final int version;
  final Map<String, Object?> parameters;
  final Map<String, String> fields;
  final bool cleanup;
  WireRequest(this.api, this.method, this.path, this.version, this.sourceID, this.parameters, this.fields, {this.cleanup = false});
  String get httpMethod => 'POST'; // No credentials in URL.
  String get encodedBody => fields.entries.map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}').join('&');
}
Map<String, String> encodeFields(String api, int version, String method, Map<String, Object?> params, String format) {
  final out = <String,String>{'api':api, 'version':'$version', 'method':method};
  for (final e in params.entries) {
    if (e.value == null) continue;
    if (e.key == '_sid' || e.key == 'SynoToken') { out[e.key] = '${e.value}'; continue; }
    if (format == 'JSON') { out[e.key] = jsonEncode(e.value); }
    else if (e.value is List || e.value is Map) { out[e.key] = jsonEncode(e.value); }
    else { out[e.key] = '${e.value}'; }
  }
  return out;
}
abstract class Transport {
  // Must abort underlying work when cancellation fires; not merely Future.timeout.
  Future<Map<String,dynamic>> send(WireRequest request, Cancellation cancellation);
}
CoreError apiError(String api, String method, int code) {
  String kind = 'UnknownApiError';
  if (api == 'SYNO.API.Auth' && method == 'login') {
    kind = switch (code) { 400 => 'AuthenticationFailed', 401 => 'AccountDisabled', 402 => 'PermissionDenied', 403 || 406 => 'NeedsOTP', 404 => 'OTPRejected', 407 => 'IPBlocked', 408 || 409 || 410 => 'PasswordLifecycle', _ => kind };
  } else {
    kind = switch (code) { 102 => 'UnsupportedApi', 103 => 'UnsupportedMethod', 104 => 'UnsupportedVersion', 105 || 407 => 'PermissionDenied', 106 || 107 || 119 => 'SessionExpired', 408 => 'PathMissing', 599 => 'TaskNotFound', _ => kind };
  }
  return CoreError(kind, api:api, method:method, code:code);
}
/// 搜索范围：允许**多个**共享根。
///
/// 最初是单根设计（单个 `root` 字符串），于是界面上只能单选一个搜索位置。
/// 但 DSM 的 `Search.start` 本来就接受 `folder_path` 数组——多目录一次搜索即可覆盖，
/// 不必让用户为每个目录各搜一次再自己拼结果。
///
/// 多根不放松安全边界：`allows` 仍要求路径落在**某一个**已授权根之下，
/// 且所有根都必须先通过 `validateScope` 的共享准入校验。
class Scope {
  /// 已授权的共享根集合。每个元素都经过 validate。
  final Set<String> roots;
  final Set<String> excluded;
  Scope(String root,{this.excluded = const {'@eaDir','#recycle','@Recycle'}}) : roots = _checked([root]);
  Scope.multi(Iterable<String> roots,{this.excluded = const {'@eaDir','#recycle','@Recycle'}}) : roots = _checked(roots);
  static Set<String> _checked(Iterable<String> values) {
    final cleaned = values.map((v) => v.trim()).where((v) => v.isNotEmpty).toSet();
    if (cleaned.isEmpty) throw const CoreError('ScopeDenied');
    for (final path in cleaned) {
      validate(path);
      if (path == '/' || path.startsWith('/volume1/')) throw const CoreError('ScopeDenied');
    }
    return cleaned;
  }
  /// 兼容单根调用点。多根时取排序后的第一个——仅用于日志与提示，不用于授权判定。
  String get root => (roots.toList()..sort()).first;
  bool get isSingle => roots.length == 1;
  static void validate(String path) {
    if (!path.startsWith('/') || path.contains('\u0000') || path.split('/').skip(1).any((s)=>s.isEmpty || s=='.' || s=='..') || RegExp(r'%(?:2e|2f|00)', caseSensitive:false).hasMatch(path)) throw const CoreError('UnsafeLogicalPath');
  }
  /// 落在**任一**已授权根之下即允许。不能简单拼字符串前缀：
  /// `/示例共享` 必须放行 `/示例共享/a.txt`，但绝不能放行 `/示例共享X/a.txt`。
  bool allows(String path) => owningRoot(path) != null;
  /// 找出这条路径所属的授权根；都不属于时返回 null。
  String? owningRoot(String path) {
    validate(path);
    for (final root in roots) {
      final a = root.split('/'), b = path.split('/');
      if (b.length >= a.length && List.generate(a.length, (i) => a[i] == b[i]).every((x) => x)) return root;
    }
    return null;
  }
  void check(String path) { if (!allows(path)) throw const CoreError('ScopeDenied'); }
  bool excludes(String path) => path.split('/').any(excluded.contains);

  /// 把已授权范围**收窄**到指定的根子集（本次搜索的位置限定）。
  ///
  /// ★ 这是「在选定位置搜索」真正减少设备侧检索量的落点：收窄后的
  /// `roots` 会被下发给设备（群晖 `Search.start(folder_path[])`、
  /// 品牌适配器逐根各发一次），少一个根就少一次设备侧扫描。
  ///
  /// ★ 它**只允许收窄，绝不允许扩大**：
  /// - 请求的根必须落在某个已授权根之下；
  /// - 交集为空 ⇒ 报 `ScopeDenied`，不放行。
  ///
  /// 客户端是**不可信输入**：它说「搜 /别人家」时，核心必须自己再判一次。
  /// 只靠客户端保证「我传的根一定授权过」是不够的——一次越权就能把
  /// 整个盘扫一遍。
  Scope narrowTo(Iterable<String> requested) {
    final wanted = requested.map((v) => v.trim()).where((v) => v.isNotEmpty).toSet();
    if (wanted.isEmpty) throw const CoreError('ScopeDenied');
    // 只接受「已授权根之内」的路径。
    //
    // 用 `owningRoot` 判定而不是字符串前缀拼接：`/示例共享X` 不是
    // `/示例共享` 的子目录，拼前缀会把它放进来（多根改造踩过的那个坑）。
    final allowed = <String>{};
    for (final path in wanted) {
      validate(path);
      if (path == '/' || path.startsWith('/volume1/')) throw const CoreError('ScopeDenied');
      if (owningRoot(path) == null) throw const CoreError('ScopeDenied');
      allowed.add(path);
    }
    // 收窄后的授权范围 = 请求的这些根（它们都落在原授权范围之内）。
    return Scope.multi(allowed);
  }
}