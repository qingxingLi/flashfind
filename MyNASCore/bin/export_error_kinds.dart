// 导出核心错误 kind 契约，供 Swift 侧比对。
//
// 产物 `MyNASCore/error_kinds.json` 是**提交进仓库**的：Swift 测试读它，
// 而 SwiftPM 测试进程里没有 Dart 运行时，跑不了 Dart 代码。
//
// 代价是这份文件可能与 `lib/error_kinds.dart` 漂移 —— 所以
// `test_error_kinds.dart` 会拿它和 Dart 表逐项比对；改了表忘了重新导出，
// 那个测试会红。
//
// 运行：dart run bin/export_error_kinds.dart
import 'dart:convert';
import 'dart:io';

import '../lib/error_kinds.dart';

void main() {
  String sorted(String kind) => kind;
  final userFacing = ErrorKind.userFacing.map(sorted).toList()..sort();
  // 两类必须互斥：一个 kind 不能既要求文案又不要求，否则 Swift 侧无所适从。
  // `userFacing ∩ internal == ∅` 由 test_error_kinds.dart 盯着。
  final internal = ErrorKind.internal.map(sorted).toList()..sort();

  final payload = <String, Object?>{
    // 改这个值等于改契约格式，Swift 的解析要同步改。
    'contractVersion': 1,
    'coreRevisionHint': 'ErrorKind 表与 Swift NASSearchFailureText 的对齐契约',
    'userFacing': userFacing,
    'internal': internal,
  };

  final out = File.fromUri(
      Uri.directory(Platform.script.resolve('..').toFilePath()).resolve('error_kinds.json'));
  out.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(payload)}\n',
      flush: true,
  );
  stdout.writeln('已写出 ${out.path}');
  stdout.writeln('userFacing ${userFacing.length} 项，internal ${internal.length} 项');
}
