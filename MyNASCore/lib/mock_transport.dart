import 'dart:async';
import 'protocol.dart';

typedef MockHook = FutureOr<Map<String,dynamic>?> Function(WireRequest,Cancellation);
class MockTransport implements Transport {
  final calls=<WireRequest>[];
  final MockHook? hook;
  final int count;
  bool native;
  String format;
  int starts=0, cleanCount=0, stopCount=0, abortCount=0;
  MockTransport({this.hook,this.count=451,this.native=true,this.format='JSON'});
  static Map<String,dynamic> ok(Map<String,dynamic> data) => {'success':true,'data':data};
  static Map<String,dynamic> failure(int code) => {'success':false,'error':{'code':code}};
  static Map<String,dynamic> file(int i,{String root='/允许共享'}) => {'name':'中文-$i.txt','path':'$root/中文-$i.txt','isdir':false,'additional':{'size':i,'time':{'mtime':1700000000+i}}};
  Map<String,dynamic> info() => ok({for(final a in ['SYNO.API.Auth','SYNO.FileStation.Info','SYNO.FileStation.List',if(native)'SYNO.FileStation.Search','SYNO.FileStation.Download']) a:{'path':'entry.cgi','minVersion':1,'maxVersion':a=='SYNO.API.Auth'?7:3,'requestFormat':format}});
  @override Future<Map<String,dynamic>> send(WireRequest r,Cancellation t) async {
    t.check();calls.add(r);void abort()=>abortCount++;t.listeners.add(abort);
    try {
      final custom=await hook?.call(r,t);t.check();if(custom!=null)return custom;
      if(r.api=='SYNO.API.Info')return info();
      if(r.api=='SYNO.API.Auth') {if(r.method=='login')return ok({'sid':'FAKE_SID_SECRET','synotoken':'FAKE_CSRF_SECRET'});return ok({});}
      if(r.api=='SYNO.FileStation.Info')return ok({'is_manager':false});
      if(r.api=='SYNO.FileStation.List') {
        final offset=r.parameters['offset'] as int;
        if(r.method=='list_share')return ok({'shares':[{'name':'允许共享','path':'/允许共享'},{'name':'private-unselected','path':'/private-unselected'}],'total':2,'offset':offset});
        return ok({'files':List.generate(3,(i)=>file(i)),'offset':offset,'total':3});
      }
      if(r.api=='SYNO.FileStation.Search') {
        if(r.method=='start') {starts++;return ok({'taskid':'task-$starts'});}
        if(r.method=='stop') {stopCount++;return ok({});}
        if(r.method=='clean') {cleanCount++;return ok({});}
        final offset=r.parameters['offset'] as int,limit=r.parameters['limit'] as int;
        return ok({'files':List.generate(limit==0?0:(count-offset).clamp(0,limit),(i)=>file(offset+i)),'offset':offset,'total':count,'finished':true});
      }
      throw const CoreError('UnsupportedApi');
    } finally {t.listeners.remove(abort);}
  }
}
