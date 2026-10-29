// 极简 ZIP 读取器（只读解包，纯标准库）。
//
// 为什么必须存在：飞牛（fnOS）的 `/ogh/ac/h/multiple-download` 把**单个文件也
// 打包成 zip** 交付（2026-10-29 真机实测：单文件响应仍是 `application/zip`，
// 文件头 `50 4b 03 04`）。搜索结果的「下载打开」因此必须先解包，
// 才能把真正的文件交给系统。
//
// MyNASCore 的硬约束是**只用 Dart 标准库**（没有 archive 之类的三方包），
// 所以这里手写了读取所需的最小子集：
//   * 压缩方法 0（stored）与 8（deflate，zip 用的是 raw deflate，
//     正好对上 `ZLibCodec(raw: true)`）；
//   * 目录条目照建；其余方法一律拒绝，不静默乱解；
//   * zip64：中心目录里 0xFFFFFFFF 的尺寸/偏移从 extra(0x0001) 读 8 字节扩展；
//   * 大文件安全：条目内容用 `RandomAccessFile` 起流、逐块写盘，
//     **不把整个文件读进内存**；
//   * zip-slip 防护：条目名含 `..`、绝对路径、反斜杠、NUL 的一律跳过——
//     zip 是远端下发的，条目名不可信。
//
// 不做的事（刻意）：不解加密条目、不分卷、不校验 CRC（下载层已受 TLS/HTTP 保护，
// 校验失败的表现交给打开动作本身去暴露）。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'protocol.dart';

/// zip 结构不合预期。调用方应把它折成下载失败，而不是让核心崩溃。
class ZipFormatException extends CoreError {
  const ZipFormatException([String detail = 'MalformedZip'])
      : super('DownloadFailed', detail: detail);
}

/// 解包结果：相对 `dest` 的**顶层**条目（相对路径，已做安全过滤）。
class ZipContents {
  final List<String> topLevelEntries;
  const ZipContents(this.topLevelEntries);
}

/// 把 `zip` 解到 `dest` 目录（必须已存在）。
///
/// 返回顶层条目列表。单文件 zip 的顶层就是那个文件本身；
/// 目录 zip 的顶层是那个目录。调用方据此决定「打开哪个路径」。
Future<ZipContents> extractZip(File zip, Directory dest) async {
  if (!await dest.exists()) {
    await dest.create(recursive: true);
  }
  final raf = await zip.open();
  try {
    final length = await raf.length();
    if (length < 22) throw const ZipFormatException('TooShort');

    // ── EOCD：从文件尾向前扫 64KB + 22 字节（最大注释长度）──────────
    final scanFrom = length > 22 + (1 << 16) ? length - 22 - (1 << 16) : 0;
    await raf.setPosition(scanFrom);
    final tail = await raf.read(length - scanFrom);
    var eocd = -1;
    for (var i = tail.length - 22; i >= 0; i--) {
      if (tail[i] == 0x50 &&
          tail[i + 1] == 0x4b &&
          tail[i + 2] == 0x05 &&
          tail[i + 3] == 0x06) {
        eocd = i;
        break;
      }
    }
    if (eocd < 0) throw const ZipFormatException('NoEOCD');
    final base = scanFrom + eocd;

    var cdSize = _u32(tail, eocd + 12);
    var cdOffset = _u32(tail, eocd + 16);

    // ── zip64：EOCD 字段满标时从 zip64 EOCD 取真值 ──────────────────
    if (cdOffset == 0xFFFFFFFF || cdSize == 0xFFFFFFFF) {
      if (base < 20) throw const ZipFormatException('NoZip64Locator');
      await raf.setPosition(base - 20);
      final locator = await raf.read(20);
      if (!_sig(locator, 0, 0x07064b50)) {
        throw const ZipFormatException('NoZip64Locator');
      }
      final z64 = _u64(locator, 8);
      await raf.setPosition(z64);
      final z64Eocd = await raf.read(56);
      if (!_sig(z64Eocd, 0, 0x06064b50)) {
        throw const ZipFormatException('NoZip64EOCD');
      }
      cdSize = _u64(z64Eocd, 40);
      cdOffset = _u64(z64Eocd, 48);
    }
    if (cdOffset + cdSize > length) throw const ZipFormatException('CDOutOfRange');

    // 中心目录整体不大（每条约 46 字节 + 名字），整段读进来逐条解析。
    await raf.setPosition(cdOffset);
    final cd = await raf.read(cdSize);

    final topLevel = <String>{};
    var p = 0;
    while (p + 46 <= cd.length) {
      if (!_sig(cd, p, 0x02014b50)) {
        // 中心目录应连续；见到别的签名说明结构坏了，到此为止（前面的条目仍有效）。
        break;
      }
      final method = _u16(cd, p + 10);
      var csize = _u32(cd, p + 20);
      var usize = _u32(cd, p + 24);
      final nlen = _u16(cd, p + 28);
      final elen = _u16(cd, p + 30);
      final clen = _u16(cd, p + 32);
      var lho = _u32(cd, p + 42);
      final utf8Flag = (_u16(cd, p + 8) & 0x800) != 0;
      final nameBytes = Uint8List.sublistView(cd, p + 46, p + 46 + nlen);
      final name = utf8Flag
          ? utf8.decode(nameBytes, allowMalformed: true)
          : latin1.decode(nameBytes);
      p += 46 + nlen + elen + clen;

      // zip64 extra：0xFFFFFFFF 的字段按 (usize, csize, lho) 顺序出现在 0x0001 里。
      var extra = p - elen;
      final extraEnd = extra + elen;
      while (extra + 4 <= extraEnd) {
        final id = _u16(cd, extra);
        final size = _u16(cd, extra + 2);
        if (id == 0x0001) {
          var q = extra + 4;
          if (usize == 0xFFFFFFFF && q + 8 <= extra + 4 + size) {
            usize = _u64(cd, q);
            q += 8;
          }
          if (csize == 0xFFFFFFFF && q + 8 <= extra + 4 + size) {
            csize = _u64(cd, q);
            q += 8;
          }
          if (lho == 0xFFFFFFFF && q + 8 <= extra + 4 + size) {
            lho = _u64(cd, q);
          }
          break;
        }
        extra += 4 + size;
      }

      // ── zip-slip 防护：名字不可信 ────────────────────────────────
      if (name.isEmpty ||
          name.contains('\u0000') ||
          name.contains('\\') ||
          name.startsWith('/') ||
          name.contains(':')) {
        continue;
      }
      final segments = name.split('/');
      if (segments.any((s) => s.isEmpty && name != segments.join('/')) ||
          segments.contains('..') ||
          segments.contains('.')) {
        continue;
      }
      final isDir = name.endsWith('/');
      final targetPath =
          '${dest.path}/${segments.where((s) => s.isNotEmpty).join('/')}';

      if (isDir) {
        await Directory(targetPath).create(recursive: true);
      } else {
        // 本地头里也可能有 zip64 extra；数据起点只看它的 nlen/elen。
        await raf.setPosition(lho);
        final local = await raf.read(30);
        if (!_sig(local, 0, 0x04034b50)) throw const ZipFormatException('BadLocalHeader');
        final lnlen = _u16(local, 26);
        final lelen = _u16(local, 28);
        final dataStart = lho + 30 + lnlen + lelen;
        final outFile = File(targetPath);
        await outFile.parent.create(recursive: true);
        final sink = outFile.openWrite();
        try {
          final source = () {
            final s = zip.openRead(dataStart, dataStart + csize);
            if (method == 0) return s;
            if (method == 8) return ZLibCodec(raw: true).decoder.bind(s);
            throw ZipFormatException('Method$method');
          }();
          await for (final chunk in source) {
            sink.add(chunk);
          }
        } finally {
          await sink.flush();
          await sink.close();
        }
      }
      topLevel.add(segments.first);
    }
    return ZipContents(topLevel.toList(growable: false));
  } finally {
    await raf.close();
  }
}

bool _sig(Uint8List b, int at, int v) =>
    at + 4 <= b.length &&
    b[at] == (v & 0xff) &&
    b[at + 1] == ((v >> 8) & 0xff) &&
    b[at + 2] == ((v >> 16) & 0xff) &&
    b[at + 3] == ((v >> 24) & 0xff);

int _u16(Uint8List b, int at) => b[at] | (b[at + 1] << 8);

int _u32(Uint8List b, int at) =>
    b[at] | (b[at + 1] << 8) | (b[at + 2] << 16) | (b[at + 3] << 24);

int _u64(Uint8List b, int at) =>
    _u32(b, at) | (_u32(b, at + 4) << 32);
