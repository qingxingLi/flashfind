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
/// 网页打开目标：结果在站点里的地址，交给默认浏览器。
///
/// 只给**没有 SMB、只有网页界面**的后端用（当前只有 OpenList）。它不是
/// 「降级方案」——对这个后端来说，网页就是唯一能到达文件的入口。
///
/// ★ 三条不许：不许带查询串（凭据会被带进地址栏与历史记录）、不许带
/// userInfo（`https://user:pass@host`）、不许跨源（origin 必须与来源地址一致）。
/// 校验放在这里而不是只靠调用方自觉：这个对象会变成结果行里可以被复制的文本。
class WebLocation extends OpenTarget {
  final Uri url;
  WebLocation(this.url) {
    final scheme = url.scheme.toLowerCase();
    if (scheme != 'https' && scheme != 'http') {
      throw const CoreError('UnsafeOpenTarget');
    }
    if (url.host.isEmpty || url.userInfo.isNotEmpty || url.hasQuery || url.hasFragment) {
      throw const CoreError('UnsafeOpenTarget');
    }
  }
  @override
  Map<String, Object?> toJson() => {'kind': 'webLocation', 'url': url.toString()};
}

class RemoteDownload extends OpenTarget {
 final String sourceID,logicalPath;
 RemoteDownload(this.sourceID,this.logicalPath,Scope scope) {scope.check(logicalPath);}
 @override Map<String,Object?> toJson()=>{'kind':'remoteDownload','sourceID':sourceID,'logicalPath':logicalPath};
}
