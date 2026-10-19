import 'protocol.dart';
sealed class OpenTarget {
  Map<String,Object?> toJson();
  static void segments(List<String> values) { if(values.any((s)=>s.isEmpty || s=='.' || s=='..' || s.contains('/') || s.contains('\u0000'))) throw const CoreError('UnsafeOpenTarget'); }
}
class MountedFile extends OpenTarget {
 final String sourceID, shareID; final List<String> relativeSegments;
 MountedFile(this.sourceID,this.shareID,this.relativeSegments) {OpenTarget.segments(relativeSegments);}
 @override Map<String,Object?> toJson()=>{'kind':'mountedFile','sourceID':sourceID,'shareID':shareID,'relativeSegments':relativeSegments};
 // Swift must resolve actual mount and symlinks before permitting an open.
}
class SMBLocation extends OpenTarget {
 final String host,share;final List<String> relativeSegments;
 SMBLocation(this.host,this.share,this.relativeSegments) {if(!RegExp(r'^[a-zA-Z0-9.-]+$').hasMatch(host)||share.isEmpty||share.contains('/'))throw const CoreError('UnsafeOpenTarget');OpenTarget.segments(relativeSegments);}
 Uri get uri=>Uri(scheme:'smb',host:host,pathSegments:[share,...relativeSegments]);
 @override Map<String,Object?> toJson()=>{'kind':'smbLocation','host':host,'share':share,'relativeSegments':relativeSegments};
}
class RemoteDownload extends OpenTarget {
 final String sourceID,logicalPath;
 RemoteDownload(this.sourceID,this.logicalPath,Scope scope) {scope.check(logicalPath);}
 @override Map<String,Object?> toJson()=>{'kind':'remoteDownload','sourceID':sourceID,'logicalPath':logicalPath};
}
