// Adapted MyNAS synology_api.dart at 2b1458e205e0 (MIT).
// Preserved API/method envelopes, Auth session and FileStation field mappings.
// Replaced Flutter/Dio/global logging with injected pure-Dart transport.
import 'dart:async';
import 'protocol.dart';
import 'upstream_synology_models.dart';

class Page {
  final List<FileStationFile> files;
  /// 设备报告的总数/偏移。「未知」一律用 null 表示——
  /// **不能用 0 冒充**（契约：不存在字段不能伪装 0/false）。
  final int? total, offset;
  /// 设备是否声明「这批结果已经算完」。
  ///
  /// null = 设备没给这个字段。**它只是参考值，不是就绪判据**：
  /// HAR 里确实存在 `finished=false` 且 `total=70` 的中间态，
  /// 也存在 `finished=true` 却**没有 total** 的形态（设备侧未就绪/退化）。
  final bool? finished;
  /// 本页里**无法解析而被跳过**的行数。必须如实上报，不能静默丢行。
  final int unparsedCount;
  /// 设备**实际返回**的行数（含被跳过的坏行）。
  ///
  /// 分页游标必须按这个数推进，不能按解析成功的条数推进 ——
  /// 否则跳过一行就会让下一页的 offset 少走一格，重复取回同一批数据，
  /// 最终表现为 DirectoryUnstable 或死循环。
  final int rawCount;
  /// 跳过原因的摘要（最多 3 条，形如「第 2 行：缺少 path」）。
  /// 只含字段名与行号，**不含文件名/路径**。
  final List<String> unparsedReasons;
  Page(this.files, this.total, this.offset, this.finished,
      {this.unparsedCount = 0, this.rawCount = -1, this.unparsedReasons = const []});

  /// 就绪判据：**拿到 `total`，且设备没有说「还在扫描」**。
  ///
  /// 反面形态是 `finished=true` 但无 `total`——
  /// 那是「未就绪」，**不是「0 条结果」**，两者绝不能混为一谈。
  ///
  /// 补上另一半：**`finished=false` 时的 `total` 是「目前已发现数」，
  /// 还会继续涨** —— 真机上可观察到就绪轮询 `limit=1` 拿到几十条，
  /// 紧接着第一页 `limit=200` 拿到的却是另一个更大的数。
  /// 只判 `total != null` 会在中间态上放行，让分页的「total 一致性」断言
  /// 必炸（IncompleteResponse）。详见 `core.dart` 就绪循环处的完整记录。
  ///
  /// 用 `finished != false` 而不是 `== true`：设备没给这个字段（null）时
  /// 无从判断，只能按「有 total 就放行」，不能被我们卡死。
  bool get ready => total != null && finished != false;

  factory Page.parse(Map<String, dynamic> data, {bool search = false}) {
    final raw = data['files'];
    final files = <FileStationFile>[];
    final reasons = <String>[];
    if (raw is List) {
      for (var i = 0; i < raw.length; i++) {
        try {
          files.add(FileStationFile.fromJson(object(raw[i])));
        } catch (error) {
          // ★ 单行坏掉**不能毁掉整次搜索**。
          // 一次 200 条的分页里只要有一行的字段形态超出预期，
          // 旧实现就会让整份列表以 ProtocolViolation 收场、已收到的结果全部作废。
          // 现在的分工是：跳过坏行 + 计数上报（调用方据此如实告知），
          // 只有「整页都没有可解析行」才上升为失败。
          if (reasons.length < 3) reasons.add('第 ${i + 1} 行：$error');
        }
      }
    }
    return Page(
      files,
      lenientNonnegativeInt(data, 'total'),
      lenientNonnegativeInt(data, 'offset'),
      search ? (data['finished'] is bool ? data['finished'] as bool : null) : null,
      unparsedCount: raw is List ? raw.length - files.length : 0,
      rawCount: raw is List ? raw.length : 0,
      unparsedReasons: reasons,
    );
  }
}
class SynologyApi {
  final Transport transport;
  final String sourceID;
  final Duration requestBudget;
  final void Function(Map<String,Object?>) log;
  final unsupportedVersions = <String>{};
  final descriptors = <String,ApiDescriptor>{};
  String? _sid, _csrf;
  String? accountIdentity;
  int sessionEpoch = 0;
  Future<void>? _refreshFlight;
  bool scopeReady = false;
  final validatedRoots = <String>{};
  SynologyApi(this.transport, this.sourceID, {this.requestBudget = const Duration(seconds:30), void Function(Map<String,Object?>)? log}) : log = log ?? ((_) {});
  bool get authenticated => _sid != null;
  bool get hasSession => _sid != null;
  bool get hasCsrfToken => _csrf != null;
  Future<Map<String,dynamic>> _send(WireRequest request, Cancellation parent, {bool acceptError = false}) async {
    parent.check(); final token = Cancellation(); void abort() => token.cancel(parent.reason);
    parent.listeners.add(abort); final timer = Timer(requestBudget, () => token.cancel('TimedOut'));
    try {
      final response = await transport.send(request, token);
      token.check(); parent.check();
      log({'api':request.api,'method':request.method,'sourceID':sourceID});
      if (response['success'] is! bool) throw const CoreError('ProtocolViolation');
      if (response['success'] != true && !acceptError) {
        final error = object(response['error']); throw apiError(request.api, request.method, requireInt(error,'code'));
      }
      return response;
    } on CoreError { rethrow; } catch (_) { throw CoreError('NetworkFailure', api:request.api, method:request.method); }
    finally { timer.cancel(); parent.listeners.remove(abort); }
  }
  Future<Map<String,dynamic>> call(String api, String method, Map<String,Object?> params, Cancellation token, {bool cleanup = false}) async {
    final d = descriptors[api]; if (d == null) throw CoreError(unsupportedVersions.contains(api) ? 'UnsupportedVersion' : 'UnsupportedApi',api:api,method:method);
    final all = <String,Object?>{...params, if (_sid != null) '_sid':_sid, if (_csrf != null) 'SynoToken':_csrf};
    final r = await _send(WireRequest(api,method,d.webPath,d.version,sourceID,all,encodeFields(api,d.version,method,all,d.format),cleanup:cleanup),token);
    if (r['data'] == null && (cleanup || method == 'logout')) return <String,dynamic>{};
    return object(r['data']);
  }
  Future<void> discover(Cancellation token) async {
    Map<String,dynamic> response;
    Future<Map<String,dynamic>> probe(String path) => _send(WireRequest('SYNO.API.Info','query',path,1,sourceID,{'query':'SYNO.API.Auth,SYNO.FileStation.Info,SYNO.FileStation.List,SYNO.FileStation.Search,SYNO.FileStation.Download'},{'api':'SYNO.API.Info','method':'query','version':'1','query':'SYNO.API.Auth,SYNO.FileStation.Info,SYNO.FileStation.List,SYNO.FileStation.Search,SYNO.FileStation.Download'}),token);
    try { response = await probe('/webapi/entry.cgi'); }
    on CoreError catch (e) { if (e.httpStatus != 404 && e.kind != 'UnsupportedApi') rethrow; response = await probe('/webapi/query.cgi'); }
    final data = object(response['data']); unsupportedVersions.clear(); final found = <String,ApiDescriptor>{};
    for (final api in ['SYNO.API.Auth','SYNO.FileStation.Info','SYNO.FileStation.List','SYNO.FileStation.Search','SYNO.FileStation.Download']) {
      if (!data.containsKey(api)) continue;
      final d = object(data[api]); final min = requireInt(d,'minVersion'), max = requireInt(d,'maxVersion');
      if (min > max) throw const CoreError('ProtocolViolation');
      final implemented = api == 'SYNO.API.Auth' ? 6 : 2;
      if (implemented < min || implemented > max) { unsupportedVersions.add(api); continue; }
      found[api] = ApiDescriptor(requireString(d,'path'),implemented,d['requestFormat'] == null ? 'legacy' : requireString(d,'requestFormat'));
    }
    descriptors..clear()..addAll(found);
  }
  // Auth parameter construction follows upstream login:89; POST transport required.
  Future<void> login(String account, String password, Cancellation token, {String? otp}) async {
    clearSession();
    final data = await call('SYNO.API.Auth','login',{'account':account,'passwd':password,'format':'sid','session':'FileStation','enable_syno_token':'yes',if(otp != null) 'otp_code':otp},token);
    _sid = requireString(data,'sid'); _csrf = data['synotoken'] as String?; accountIdentity = account; sessionEpoch++;
  }
  // 身份校验与搜索范围准入解耦：
  // 登录后先列共享，由用户选择搜索位置，再对该范围做准入校验。
  //
  // 管理员账号**允许使用**。曾经有一条限制（is_manager==true 一律拒绝），
  // 但那条限制只是为了把验收对象固定成普通账号而加的，从未在真机上验证过
  // 管理员账号的实际能力，属于未经证实的推断。
  //
  // 需要如实告知用户的代价：管理员账号在 list_share 里能看到**全部**共享，
  // 因此用它搜索时，搜索范围不再等于「你被别人授予的目录」，
  // 而是「这台 NAS 上的全部目录」。这是权限边界的实质性放宽，
  // 由用户在客户端明确知情后自行选择，而不是在这里替他决定。
  Future<void> authorize(Cancellation token) async {
    if (!authenticated) throw const CoreError('NeedsAuth');
    final info = await call('SYNO.FileStation.Info','get',{},token);
    if (info['is_manager'] is! bool) throw const CoreError('IdentityUnverified');
    isManager = info['is_manager'] == true;
    scopeReady = true;
  }
  /// 当前会话是否为管理员。UI 用它来提示权限范围变化，不是用来拒绝登录的。
  bool isManager = false;
  // 范围准入：该共享必须真实出现在此账号的共享列表里，才允许纳入搜索。
  Future<void> validateScope(Cancellation token, Scope scope) async {
    if (!scopeReady) throw const CoreError('NeedsAuth');
    // 每一个选中的目录都必须在该账号的共享列表里真实存在。
    // 只校验「至少有一个」是不够的——那会把未授权的目录也纳入搜索。
    final visible = (await shares(null,token)).toSet();
    for (final root in scope.roots) {
      if (!visible.contains(root)) { scopeReady = false; throw const CoreError('ScopeUnavailable'); }
      validatedRoots.add(root);
    }
  }
  // Session refresh never resends non-idempotent Search.start.
  Future<void> refreshOnce(Future<void> Function() operation) {
    if (_refreshFlight != null) return _refreshFlight!;
    final flight = operation(); _refreshFlight = flight;
    return flight.whenComplete(() { if (identical(_refreshFlight,flight)) _refreshFlight = null; });
  }
  void clearSession() { _sid = null; _csrf = null; accountIdentity = null; scopeReady = false; validatedRoots.clear(); sessionEpoch++; }
  Future<void> logout(Cancellation token) async {
    try { if (authenticated) { await call('SYNO.API.Auth','logout',{'session':'FileStation'},token); } }
    finally { clearSession(); }
  }
  // Adapted upstream listFiles:209: explicit 200 page, no owner/real_path.
  Future<Page> listFiles(String path, int offset, Cancellation token, {int limit = 200}) async {
    final data = await call('SYNO.FileStation.List','list',{'folder_path':path,'offset':offset,'limit':limit,'sort_by':'name','sort_direction':'asc','filetype':'all','additional':['size','time','type']},token);
    return Page.parse(data);
  }
  // scope 为 null 时返回该账号可见的全部共享（供产品端「选择搜索位置」用）；
  // 指定 scope 时只保留与 scope.root 完全一致的共享，用于准入校验。
  Future<List<String>> shares(Scope? scope, Cancellation token) async {
    if (!scopeReady) throw const CoreError('NeedsAuth');
    final result = <String>[]; int offset = 0; int? total; final seen = <String>{};
    while (true) {
      final data = await call('SYNO.FileStation.List','list_share',{'offset':offset,'limit':200,'onlywritable':false},token);
      final reported = requireInt(data,'total'); final returned = requireInt(data,'offset'); final raw = array(data,'shares');
      if (returned != offset || (total != null && total != reported) || raw.length + offset > reported) throw const CoreError('ProtocolViolation');
      total = reported;
      for (final item in raw) { final map = object(item); final path = requireString(map,'path'); requireString(map,'name'); Scope.validate(path); if (!seen.add(path)) throw const CoreError('ProtocolViolation'); if (scope == null || path == scope.root) result.add(path); }
      offset += raw.length;
      if (offset == total) return result;
      if (raw.isEmpty) throw const CoreError('DirectoryUnstable');
    }
  }
  // Adapted upstream startSearch:436: folder array, explicit recursive true.
  //
  // ⚠️ 编码由 protocol.dart 的 encodeFields 统一负责：Search 的 requestFormat
  // 是 JSON，因此所有字段会被自动 jsonEncode 一次。**这里不能手工 jsonEncode**，
  // 否则 taskid / pattern / sort_by 会被二次编码成 "\"...\""，设备返回
  // finished=true 但没有 total（表现为 ProtocolViolation / 搜索随机失效）。
  //
  // 设备要求 taskid 以 JSON 字符串形式传入（taskid="1791..."），这一点由
  // encodeFields 自动满足。
  //
  // ⛔ 不要再去改下面这些参数来「修」搜索失效。参数消融实验的
  // 结论是：只有 taskid 的引号是决定项，
  // sort_by / sort_direction / additional / search_content / search_type /
  // pattern 引号**全部无影响**（各 12/12）。这里的取值与 File Station
  // 网页版 HAR 对齐，保留原样即可。
  /// folder_path 传**全部**已授权目录 —— DSM 的 start 本就接受数组，
  /// 一次搜索即可覆盖多个共享，不必每个目录各搜一次。
  Future<String> startSearch(List<String> roots, String query, Cancellation token) async {
    if (roots.isEmpty) throw const CoreError('ScopeDenied');
    final data = await call('SYNO.FileStation.Search','start',{
      'folder_path':roots,
      'recursive':true,
      'pattern':query,
      'search_content':true,
      'search_type':'simple',
    },token);
    return requireString(data,'taskid');
  }
  // Adapted upstream getSearchResult:455: explicit polling/page limits + strict data.
  //
  // sort_by用 filename、sort_direction 大写 ASC，与 File Station 网页版一致
  // （依据 File Station 网页版的 HAR）。同样由 encodeFields 统一编码，勿手工加引号。
  Future<Page> searchPage(String task, int offset, int limit, Cancellation token) async {
    final data = await call('SYNO.FileStation.Search','list',{
      'taskid':task,
      'offset':offset,
      'limit':limit,
      'sort_by':'filename',
      'sort_direction':'ASC',
      'additional':['real_path','size','owner','time','perm','type'],
    },token);
    return Page.parse(data,search:true);
  }
  Future<void> taskControl(String task, String method, Cancellation token) async {
    await call('SYNO.FileStation.Search',method,{'taskid':task},token,cleanup:true);
  }
}
