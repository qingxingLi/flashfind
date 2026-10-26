// Explicit mock/live modes; source trust and credentials arrive via stdin only.
// live trust modes: system | approvedCA | sourcePin. sourcePin uses the bundled native
// helper and never reuses a connection or session across a certificate change.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../lib/core.dart';
import '../lib/protocol.dart';
import '../lib/synology_api.dart';
import '../lib/mock_transport.dart';
import '../lib/http_transport.dart';
import '../lib/source_trust.dart';
import '../lib/source_pinned_transport.dart';
import '../lib/trust_paths.dart';
import '../lib/adapter_registry.dart';
import '../lib/adapter_support.dart';
import '../lib/brand_session.dart';

class Source {
 final SynologyApi? _api; final SynologyCore? _core; final BrandSession? brand; final String trustMode;
 SourceEndpoint? endpoint;
 Cancellation? authToken;
 Source(SynologyApi api,SynologyCore core,this.trustMode,{this.endpoint}) : _api = api, _core = core, brand = null;
 /// 品牌来源（qnap/ugreen/fnos/webdav）。它们不走群晖的证书固定与任务模型。
 Source.brand(this.brand,{this.trustMode = 'system'}) : _api = null, _core = null;
 /// 群晖分支读到的必然是这两种来源；可空性收在 getter 里，
 /// 免得在已经真机验证过的路径上撒一片 `!`。
 SynologyApi get api => _api!;
 SynologyCore get core => _core!;
 /// 两种来源都能被同一段收尾代码取消 / 断开。
 void cancel([String? queryID]) { _core?.cancel(queryID); brand?.cancel(queryID); }
 Future<void> disconnect() async {
  final c = _core;
  if (c != null) { await c.disconnect(); } else { await brand!.disconnect(); }
 }
}
final sources=<String,Source>{};
final pendingDiscovery=<String>{};
final work=<Future<void>>[];
bool shuttingDown=false;
late final SourceTrustStore trustStore;
String identifier(Object? id) {if(id is! String || !RegExp(r'^[a-zA-Z0-9_-]{1,64}$').hasMatch(id))throw const CoreError('ProtocolViolation');return id;}
void send(String request,String source,String query,String event,Map<String,Object?> data) => stdout.writeln(jsonEncode({'protocolVersion':1,'coreRevision':coreRevision,'requestID':request,'sourceID':source,'queryID':query,'event':event,...data}));
Duration requestBudget(Map<String,dynamic> message) {
 final ms=message['requestBudgetMs'] as int? ?? 30000;
 if(ms<1000||ms>120000)throw const CoreError('ProtocolViolation');
 return Duration(milliseconds:ms);
}
// Test-only knob so a slow real device can be bounded; product default stays 30s.
Duration queryBudgetOf(Map<String,dynamic> message) {
 final ms=message['queryBudgetMs'] as int? ?? 30000;
 if(ms<500||ms>600000)throw const CoreError('ProtocolViolation');
 return Duration(milliseconds:ms);
}
/// 本次搜索的位置限定（可选）。
///
/// ★ 缺失 ⇒ null（不限定，按来源的全部已授权根搜）——旧客户端不发它时
/// 行为完全不变。
/// 存在但不是字符串数组 ⇒ 协议违规（不能默默当成「不限定」，那会让
/// 一次拼错的请求悄悄扫了整盘）。
List<String>? searchRoots(Map<String,dynamic> message) {
 if(!message.containsKey('roots'))return null;
 final raw=message['roots'];
 if(raw==null)return null;
 if(raw is! List)throw const CoreError('ProtocolViolation');
 final out=raw.map((v){if(v is! String||v.isEmpty)throw const CoreError('ProtocolViolation');return v;}).toList();
 return out;
}
SourceEndpoint buildEndpoint(String sourceID,String url) {
 try { return SourceEndpoint(sourceID,url); } on StateError catch(e) { throw CoreError(trustStateKind(e.message)); }
}
/// 从 endpoint 取出裸主机名，供结果 openTarget 使用。只接受 IPv4/DNS 名，
/// 不接受端口、路径、凭据或 IPv6 字面量（后者不做隐式改写）。
String hostOf(String url) {
 final h=Uri.tryParse(url)?.host;
 if(h==null||h.isEmpty)return '';
 if(!RegExp(r'^[a-zA-Z0-9](?:[a-zA-Z0-9.-]*[a-zA-Z0-9])?$').hasMatch(h))return '';
 return h;
}
/// 产品端给定的来源展示名。限制长度与字符集，不接受任意控制内容。
String displayNameOf(Map<String,dynamic> message,String fallback) {
 final raw=message['sourceName'];
 if(raw==null)return fallback;
 if(raw is! String||raw.isEmpty||raw.length>64||RegExp(r'[\x00-\x1f]').hasMatch(raw))throw const CoreError('ProtocolViolation');
 return raw;
}
String trustHelper() {
 try { return resolveTrustHelperPath(); } on StateError { throw const CoreError('TrustStoreFailure'); }
}
Map<String,Object?> capabilities(SynologyApi api,String mode,String trustMode) => {'nativeSearch':api.descriptors.containsKey('SYNO.FileStation.Search'),'mode':mode,'mockOnly':mode=='mock','querySemantics':'DSM glob/partial name; device unverified','canOpen':false,'trustMode':trustMode};

/// 品牌来源的 discover。
///
/// 与群晖不同，品牌来源**不做证书固定**：它们多是明文 HTTP 的局域网设备
/// （qnap/fnos/ugreen 的管理口出厂即 http），所以是否放行明文由
/// `allowInsecureHTTP` 显式决定，而不是这里默默降级。
Future<void> discoverBrand(Map<String,dynamic> message,String request,String sourceID,String query,String vendor) async {
 if(!hasBrandAdapter(vendor))throw const CoreError('UnsupportedVendor');
 final endpoint=requireString(message,'endpoint');
 final allowInsecure=message['allowInsecureHTTP']==true;
 final budget=requestBudget(message);
 final sourceName=displayNameOf(message,sourceID);
 final smbHost=hostOf(endpoint);
 final adapter=createBrandAdapter(vendor,endpoint:endpoint,budget:budget,allowInsecureHTTP:allowInsecure);
 final session=BrandSession(adapter,sourceID:sourceID,sourceName:sourceName,smbHost:smbHost,queryBudget:queryBudgetOf(message),emit:(q,e,d){send(requests['$sourceID:$q'] ?? request,sourceID,q,e,d);});
 final raw=message['scopes'];
 final scopes = raw is List
   ? raw.map((v)=>requireString({'v':v},'v')).toList()
   : (message.containsKey('scope') ? [requireString(message,'scope')] : null);
 if(scopes!=null&&scopes.isNotEmpty) await session.selectScopes(scopes);
 sources[sourceID]=Source.brand(session);
 send(request,sourceID,query,'capabilities',{...session.capabilities(),'vendor':vendor,'requestBudgetMs':budget.inMilliseconds,'queryBudgetMs':queryBudgetOf(message).inMilliseconds});
}

/// 品牌来源的命令分支。事件形状与群晖路径**逐字段对齐** ——
/// Swift 侧不该知道底下是哪个品牌。
Future<void> brandCommand(String cmd,Map<String,dynamic> message,String request,String sourceID,String query,Source source) async {
 final session=source.brand!;
 switch(cmd) {
  case 'login':
   final account=requireString(message,'account'), password=requireString(message,'password'), otp=message['otp'] as String?;
   message.remove('password'); message.remove('otp');
   await session.login(account,password,otp);
   // 品牌协议里没有 is_manager 的等价物。这里如实发 managerUnknown，
   // 而不是拿 false 冒充「普通账号」——那会在界面上误导用户。
   send(request,sourceID,query,'sessionState',{'state':'authenticated','sessionPresent':true,'csrfPresent':false,'isManager':false,'managerUnknown':true});
   send(request,sourceID,query,'authState',{'state':'authenticated','isManager':false,'managerUnknown':true});
  case 'listShares':send(request,sourceID,query,'batch',{'shares':await session.shares()});
  case 'selectScope':
   final raw=message['scopes'];
   if(raw is! List||raw.isEmpty)throw const CoreError('ProtocolViolation');
   final scopes=raw.map((v){if(v is! String||v.isEmpty)throw const CoreError('ProtocolViolation');return v;}).toList();
   await session.selectScopes(scopes);
   send(request,sourceID,query,'scopeState',{'state':'scopeReady','scopes':session.scope.roots.toList()});
  case 'list':send(request,sourceID,query,'batch',{'files':await session.list(requireString(message,'path'),Cancellation())});
  case 'search':
   requests['$sourceID:$query']=request;
   final out=await session.search(requireString(message,'query'),query,budget:message.containsKey('queryBudgetMs')?queryBudgetOf(message):null,roots:searchRoots(message));
   send(request,sourceID,query,'searchReturned',out.toJson());
   requests.remove('$sourceID:$query');
  case 'cancel':session.cancel(query);send(request,sourceID,query,'controlAck',{'command':'cancel'});
  case 'disconnect':source.authToken?.cancel();await session.disconnect();sources.remove(sourceID);send(request,sourceID,query,'sourceState',{'state':'disconnected'});
  default:throw const CoreError('UnsupportedCommand');
 }
}

void emitPrompt(String request,String sourceID,String query,Map<String,Object?> candidate) {
 send(request,sourceID,query,'certificateTrustRequired',{'candidate':candidate,'trustMode':'sourcePin'});
}
Future<void> command(Map<String,dynamic> message) async {
 // `cmd` 提到 try 之外：失败分支要按**哪个命令**失败来分诊
 // （登录挂了与列目录挂了不是一回事），只有局部变量的话兜底里拿不到。
 String request='invalid',sourceID='invalid',query='none',cmd='';
 try {
  if(message['protocolVersion']!=1)throw const CoreError('ProtocolViolation');
  request=identifier(message['requestID']);sourceID=identifier(message['sourceID']);query=identifier(message['queryID']);
  cmd=requireString(message,'command');
  if(shuttingDown)throw const CoreError('ShuttingDown');
  if(cmd=='discover') {
   // 重连是正常操作：同一 sourceID 可能已存在（上次连接成功过、或中途失败留下了会话）。
   // 这里先断开旧的再建新的，discover 因此是幂等的。
   // 否则 Swift 侧每次「重新连接」都会撞 SourceExists，而用户什么都没改。
   if(sources.containsKey(sourceID)) {
    final stale=sources.remove(sourceID);
    stale?.cancel();
    try { await stale?.disconnect(); } catch (_) {}
   }
   if(sources.containsKey(sourceID)||pendingDiscovery.contains(sourceID))throw const CoreError('SourceExists');
   pendingDiscovery.add(sourceID);
   try {
   // 品牌分支：qnap / ugreen / fnos / webdav 走各自的适配器，不经过
   // 群晖的证书固定与任务模型（它们大多是明文 HTTP + 同步列表）。
   final vendor = message['vendor'] as String? ?? synologyVendor;
   if (vendor != synologyVendor) {
    await discoverBrand(message,request,sourceID,query,vendor);
    return;
   }
   final mode = requireString(message,'mode');
   // scope 可缺省：不带 scope 的 discover 只做 API 协商与证书握手，
   // 等用户选定共享后再用 selectScope 绑定范围。这样「添加 NAS」向导
   // 不必在还没拿到共享列表时就要求填写搜索位置。
   // scopes 可缺省：不带范围的 discover 只做 API 协商与证书握手，
   // 等用户在向导里勾选共享后再用 selectScope 绑定。
   final Scope? scope = message.containsKey('scopes')
     ? Scope.multi(array(message,'scopes').map((v)=>requireString({'v':v},'v')))
     : (message.containsKey('scope') ? Scope(requireString(message,'scope')) : null);
   final budget=requestBudget(message);
   final String sourceName=displayNameOf(message,sourceID);
   final String smbHost = hostOf(requireString(message,'endpoint'));
   final Transport t;
   final String trustMode;
   if (mode == 'mock') {
    trustMode='mock';
    final delay=message['mockDelayMs'] as int? ?? 0;
    if(delay<0||delay>5000)throw const CoreError('ProtocolViolation');
    final count=message['mockCount'] as int? ?? 451;if(count<0||count>2000)throw const CoreError('ProtocolViolation');
    t=MockTransport(count:count,hook:(r,c)async{if(delay>0&&r.api=='SYNO.FileStation.Search'&&r.method=='list')await c.delay(Duration(milliseconds:delay));return null;});
   } else if (mode == 'live') {
    if(message.containsKey('mockCount')||message.containsKey('mockDelayMs'))throw const CoreError('ProtocolViolation');
    final trust=object(message['trust']);trustMode=requireString(trust,'mode');
    if(trust.containsKey('helperPath')||trust.containsKey('storePath')||trust.containsKey('sha256'))throw const CoreError('ProtocolViolation');
    final url=requireString(message,'endpoint');
    if(trustMode=='sourcePin') {
     final endpoint=buildEndpoint(sourceID,url);
     t=SourcePinnedTransport(SourcePinnedClient(endpoint,trustStore,helperPath:trustHelper(),requestTimeout:budget));
    } else if (trustMode=='system'||trustMode=='approvedCA') {
     final pem=trustMode=='approvedCA'?requireString(trust,'pem'):null;
     t=HttpTransport(Endpoint(url,'$sourceID:$trustMode',approvedCAPem:pem));
    } else {throw const CoreError('InvalidTrustConfiguration');}
   } else {throw const CoreError('UnsupportedMode');}
   final api=SynologyApi(t,sourceID,requestBudget:budget);
   final core=SynologyCore(api,scope,sourceName:sourceName,smbHost:smbHost,pollInterval:const Duration(milliseconds:500),queryBudget:queryBudgetOf(message),emit:(q,e,d){send(requests['$sourceID:$q'] ?? request,sourceID,q,e,d);});
   try {
    await api.discover(Cancellation());
   } on CertificateTrustError catch(e) {
    emitPrompt(request,sourceID,query,e.candidate);
    send(request,sourceID,query,'sourceState',{'state':'trustRequired'});return;
   }
   sources[sourceID]=Source(api,core,trustMode,endpoint:mode=='live'&&trustMode=='sourcePin'?buildEndpoint(sourceID,requireString(message,'endpoint')):null);
   send(request,sourceID,query,'capabilities',{...capabilities(api,mode,trustMode),'requestBudgetMs':budget.inMilliseconds,'queryBudgetMs':queryBudgetOf(message).inMilliseconds});return;
   } finally {pendingDiscovery.remove(sourceID);}
  }
  if(cmd=='confirmTrust'||cmd=='rejectTrust') {
   // 品牌来源不做证书固定，没有「确认证书」这一步。
   // 若产品端对品牌来源发起确认，说明两端对信任模式的理解不一致，直接拒绝，
   // 而不是顺手建出一个群晖来源。
   if((message['vendor'] as String? ?? synologyVendor)!=synologyVendor)throw const CoreError('InvalidTrustConfiguration');
   // 与 discover 同理：确认前清掉同 sourceID 的旧来源，让重试是安全的。
   if(sources.containsKey(sourceID)) {
    final stale=sources.remove(sourceID);
    stale?.cancel();
    try { await stale?.disconnect(); } catch (_) {}
   }
   if(sources.containsKey(sourceID)||pendingDiscovery.contains(sourceID))throw const CoreError('SourceExists');
   final endpoint=buildEndpoint(sourceID,requireString(message,'endpoint'));
   if(cmd=='rejectTrust') {
    trustStore.reject(endpoint);
    send(request,sourceID,query,'trustState',{'state':'rejected','endpoint':endpoint.toJson()});return;
   }
   if(message['userConfirmed']!=true)throw const CoreError('ExplicitCertificateConfirmationRequired');
   final allowExpired=message['allowExpired']==true;
   try {
    await trustStore.confirm(endpoint,requireString(message,'candidateID'),requireString(message,'sha256'),userConfirmed:true,allowExpired:allowExpired);
   } on StateError {throw const CoreError('ExplicitCertificateConfirmationRequired');}
   // Saved pin is verified by a fresh handshake; the challenged connection is never reused.
   // scopes 可缺省：不带范围的 discover 只做 API 协商与证书握手，
   // 等用户在向导里勾选共享后再用 selectScope 绑定。
   final Scope? scope = message.containsKey('scopes')
     ? Scope.multi(array(message,'scopes').map((v)=>requireString({'v':v},'v')))
     : (message.containsKey('scope') ? Scope(requireString(message,'scope')) : null);
   final budget=requestBudget(message);
   final sourceName=displayNameOf(message,sourceID);
   final smbHost=hostOf(requireString(message,'endpoint'));
   final api=SynologyApi(SourcePinnedTransport(SourcePinnedClient(endpoint,trustStore,helperPath:trustHelper(),requestTimeout:budget)),sourceID,requestBudget:budget);
   try {
    await api.discover(Cancellation());
   } on CertificateTrustError catch(e) {
    emitPrompt(request,sourceID,query,e.candidate);
    send(request,sourceID,query,'trustState',{'state':'confirmationRejected'});return;
   }
   final core=SynologyCore(api,scope,sourceName:sourceName,smbHost:smbHost,pollInterval:const Duration(milliseconds:500),queryBudget:queryBudgetOf(message),emit:(q,e,d){send(requests['$sourceID:$q'] ?? request,sourceID,q,e,d);});
   sources[sourceID]=Source(api,core,'sourcePin',endpoint:endpoint);
   send(request,sourceID,query,'trustState',{'state':'confirmed','sha256':trustStore.pin(endpoint),'allowExpired':allowExpired,'endpoint':endpoint.toJson()});
   send(request,sourceID,query,'capabilities',{...capabilities(api,'live','sourcePin'),'requestBudgetMs':budget.inMilliseconds});return;
  }
  final source=sources[sourceID];
  if(source==null) {
   // `disconnect` 对未知 sourceID 必须是**幂等成功**，不是错误。
   //
   // 产品端每次「连接 / 重新连接 / 确认证书」之前都会先发一条 disconnect
   // 做幂等清理（`AppModel.resetCoreSource`），注释也写明「失败不阻塞后续流程」。
   // 应用刚启动时核心进程是全新的，`sources` 里当然什么都没有 ——
   // 于是这条清理**必然**报 UnknownSource，还会以
   // `{"resultState":"failed","errorKind":"UnknownSource"}` 的形态写进
   // `nas-search-events.jsonl`。那份文件正是排查搜索问题时最先看的东西，
   // 每次启动都往里塞两条假的 failed，等于在自己最需要信任的记录里掺沙子
   // （两条记录与被清理的真实故障行长得一模一样）。
   //
   // 让 disconnect 幂等，噪音就从源头消失了 —— 而不是靠产品端过滤。
   if(cmd=='disconnect'){send(request,sourceID,query,'sourceState',{'state':'disconnected'});return;}
   throw const CoreError('UnknownSource');
  }
  // 品牌来源走自己的分支：它没有群晖的 authToken 抢占语义，也没有任务清理。
  if(source.brand!=null){await brandCommand(cmd,message,request,sourceID,query,source);return;}
  if(source.authToken!=null&&cmd!='cancel'&&cmd!='disconnect')throw const CoreError('AuthInProgress');
  switch(cmd) {
   case 'login':
    final authToken=Cancellation(); source.authToken=authToken;
    try {
    source.core.cancel(); // Drain tasks before account replacement.
    await source.core.disconnect();
    final account = requireString(message,'account'), password = requireString(message,'password'), otp = message['otp'] as String?;
    message.remove('password'); message.remove('otp');
    await source.api.login(account,password,authToken,otp:otp);
    // Session facts only; the sid and CSRF value themselves are never emitted.
    send(request,sourceID,query,'sessionState',{'state':'authenticated','sessionPresent':source.api.hasSession,'csrfPresent':source.api.hasCsrfToken,'isManager':source.api.isManager});
    // 身份与搜索范围解耦：先确认是普通账号，再由用户选共享。
    await source.api.authorize(authToken);
    send(request,sourceID,query,'authState',{'state':'authenticated','isManager':source.api.isManager});
    } catch (_) {source.api.clearSession();rethrow;}
    finally {source.authToken=null;}
   case 'listShares':send(request,sourceID,query,'batch',{'shares':await source.api.shares(null,Cancellation())});
   case 'selectScope':
    // scopes 是数组：用户可以同时勾选多个共享目录。
    final raw=message['scopes'];
    if(raw is! List||raw.isEmpty)throw const CoreError('ProtocolViolation');
    final scopes=raw.map((v){if(v is! String||v.isEmpty)throw const CoreError('ProtocolViolation');return v;}).toList();
    await source.core.selectScopes(Cancellation(),scopes);
    send(request,sourceID,query,'scopeState',{'state':'scopeReady','scopes':source.core.scope.roots.toList()});
   case 'list':send(request,sourceID,query,'batch',{'files':await source.core.list(requireString(message,'path'),Cancellation())});
   case 'search':
    // Events bind THIS request; controls do not queue behind this Future.
    // Use one owner/core per source, event request mapping below supplies correct IDs.
    requests['$sourceID:$query']=request;
    final out=await source.core.search(requireString(message,'query'),query,budget:message.containsKey('queryBudgetMs')?queryBudgetOf(message):null,roots:searchRoots(message));
    send(request,sourceID,query,'searchReturned',out.toJson());
    requests.remove('$sourceID:$query');
   case 'cancel':source.core.cancel(query);send(request,sourceID,query,'controlAck',{'command':'cancel'});
   case 'disconnect':source.authToken?.cancel();await source.core.disconnect();sources.remove(sourceID);send(request,sourceID,query,'sourceState',{'state':'disconnected'});
   default:throw const CoreError('UnsupportedCommand');
  }
 } on CertificateTrustError catch(e) {
  final dropped=sources.remove(sourceID); dropped?.cancel(); // Session gone; the saved pin is not replaced silently.
  emitPrompt(request,sourceID,query,e.candidate);
  send(request,sourceID,query,'sourceState',{'state':'trustInvalidated'});
 }
 on CoreError catch(e) {send(request,sourceID,query,'terminal',{'resultState':'failed','error':e.toJson()});}
 // 品牌适配器的失败**必须原样翻出来**，不能让它掉进下面的兜底分支。
 //
 // 之前没有这一段，于是适配器精心写好的原因（「无法连接 WebDAV 服务
 // （TLS 握手失败）」「飞牛 NAS 登录失败：所有已知登录端点均不可用」）
 // 被压成一句话都没有的 `ProtocolViolation`：界面上只剩「连接失败」，
 // 而这两个真因（端口只讲明文、品牌与端口选错）恰恰是最需要说出来的。
 on AdapterFailure catch(f) {send(request,sourceID,query,'terminal',{'resultState':'failed','error':f.toCoreError(method:cmd).toJson()});}
 catch(e,st) {
  // 兜底分支**不许再说谎**。
  //
  // 原来这里一律报 `ProtocolViolation`，于是「设备返回了不合规的数据」
  // 与「我们自己的代码出了岔子」在界面和诊断里长得一模一样 ——
  // 一次真实的代码缺陷被冒充成设备问题，排查方向整个跑反
  // （排查 WebDAV/飞牛连接失败时就先怀疑了设备）。
  // 原始异常只写 stderr：协议通道不放，也不进事件 ——
  // 事件会落进产品端诊断文件，异常文本里可能带路径或凭据。
  stderr.writeln('unexpected_failure: $e');
  stderr.writeln(st.toString().split('\n').take(8).join('\n'));
  send(request,sourceID,query,'terminal',{'resultState':'failed','error':const CoreError('UnexpectedFailure').toJson()});
 }
}
final requests=<String,String>{};
Future<void> main() async {
 try {
  trustStore=SourceTrustStore(resolveTrustStoreFile());
  await trustStore.load();
 } catch (_) {stderr.writeln('trust_store_unavailable');exit(3);}
 await for(final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
  if(utf8.encode(line).length>65536){send('invalid','invalid','none','terminal',{'error':const CoreError('InputTooLarge').toJson()});continue;}
  try {final f=command(object(jsonDecode(line)));work.add(f);unawaited(f.whenComplete(()=>work.remove(f)));}catch(_){send('invalid','invalid','none','terminal',{'error':const CoreError('ProtocolViolation').toJson()});}
 }
 shuttingDown=true;
 for(final source in sources.values){source.cancel();}
 await Future.wait(List.of(work));
 for(final source in sources.values.toList()){try{await source.disconnect();}catch(_){stderr.writeln('logout_failed');}}
 sources.clear();
}
