// Pure Dart strict HTTPS transport; live CLI requires explicit source origin.
// fixtures only; real NAS wire compatibility is still unverified.
import 'dart:convert';
import 'dart:io';
import 'protocol.dart';

class Endpoint {
  final Uri origin;
  final String trustIdentity;
  final SecurityContext? securityContext;
  Endpoint(String url,this.trustIdentity,{String? approvedCAPem}):origin=Uri.parse(url),securityContext=_context(approvedCAPem) {
    if(origin.scheme!='https'||origin.host.isEmpty||origin.userInfo.isNotEmpty||origin.query.isNotEmpty||origin.fragment.isNotEmpty||(origin.path.isNotEmpty&&origin.path!='/')||trustIdentity.isEmpty)throw const CoreError('UnsafeEndpoint');
  }
  static SecurityContext? _context(String? pem) {
    if (pem == null) return null; // Default OS root verification.
    try { return SecurityContext(withTrustedRoots:false)..setTrustedCertificatesBytes(utf8.encode(pem)); }
    catch (_) { throw const CoreError('InvalidTrustConfiguration'); }
  }
  Uri apiURL(String path) {
    if(!path.startsWith('/webapi/'))throw const CoreError('UnsafeApiPath');
    ApiDescriptor(path.substring('/webapi/'.length),2,'legacy');
    final target=origin.replace(path:path);
    if(target.host!=origin.host||target.port!=origin.port||target.scheme!=origin.scheme)throw const CoreError('OriginChanged');
    return target;
  }
}
class HttpTransport implements Transport {
  final Endpoint endpoint;
  final int maxResponseBytes;
  HttpTransport(this.endpoint,{this.maxResponseBytes=4*1024*1024});
  @override Future<Map<String,dynamic>> send(WireRequest r,Cancellation token) async {
    token.check();final client=HttpClient(context:endpoint.securityContext);HttpClientRequest? request;
    void abort(){request?.abort(CoreError(token.reason));client.close(force:true);}
    token.listeners.add(abort);
    try {
      request=await client.openUrl(r.httpMethod,endpoint.apiURL(r.path));token.check();
      request.followRedirects=false;
      request.headers.contentType=ContentType('application','x-www-form-urlencoded',charset:'utf-8');
      request.headers.set(HttpHeaders.acceptHeader,'application/json');
      // This device rejects a body-carried SynoToken with code 119; CSRF must be a header.
      final synoToken=r.fields['SynoToken'];
      if(synoToken!=null&&synoToken.isNotEmpty)request.headers.set('X-Syno-Token',synoToken);
      request.add(utf8.encode(r.encodedBody));
      final response=await request.close();token.check();
      if(response.statusCode>=300&&response.statusCode<400)throw const CoreError('RedirectRejected');
      if(response.statusCode==401||response.statusCode==403)throw CoreError('HttpDenied',httpStatus:response.statusCode);
      if(response.statusCode!=200)throw CoreError('HttpFailure',httpStatus:response.statusCode);
      final bytes=<int>[];
      await for(final chunk in response){token.check();if(bytes.length+chunk.length>maxResponseBytes)throw const CoreError('ResponseTooLarge');bytes.addAll(chunk);}
      final Map<String,dynamic> parsed;
      try {parsed=object(jsonDecode(utf8.decode(bytes)));}catch(_){throw const CoreError('ProtocolViolation');}
      return parsed;
    } on CoreError {token.check();rethrow;}
    on HandshakeException {throw const CoreError('TLSRejected');}
    on SocketException {token.check();throw const CoreError('NetworkFailure');}
    catch(_) {token.check();throw const CoreError('NetworkFailure');}
    finally {token.listeners.remove(abort);client.close(force:true);}
  }
}
