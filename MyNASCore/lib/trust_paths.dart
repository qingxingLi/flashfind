// resource-only adaptation: bundled AOT entry resolves beside its helper.
// State is supplied only by the owning Swift application, not protocol messages.
import 'dart:io';
Directory _root() => File(Platform.script.toFilePath()).parent.parent;
String resolveTrustHelperPath() {
 final file=File('${_root().path}/native/TrustHTTP');
 if(FileSystemEntity.typeSync(file.path,followLinks:false)!=FileSystemEntityType.file || file.statSync().mode & 0x49 == 0) throw StateError('TrustHelperMissing');
 return file.path;
}
File resolveTrustStoreFile() {
 final path=Platform.environment['FF2_TRUST_DIR'];
 if(path==null || !Directory(path).isAbsolute)throw StateError('TrustDirectoryRequired');
 final dir=Directory(path);
 if(FileSystemEntity.typeSync(path,followLinks:false)!=FileSystemEntityType.directory)throw StateError('UnsafeTrustDirectory');
 return File('${dir.path}/source-trust.json');
}
