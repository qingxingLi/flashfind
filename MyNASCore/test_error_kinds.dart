// 核心错误 kind 契约的回归测试 —— 纯本机，不连设备。
//
// ── 为什么专门要有这个文件 ─────────────────────────────────────────
// `kind` 是 Dart 核心与 Swift 界面之间的契约：核心用它说「出了什么事」，
// Swift 用它决定给用户看哪句话。契约若只存在于两边各自写的字面量里，
// 于是「Dart 新增了一个 kind」和「Swift 知不知道它」完全是两件事。
//
// 已经发生过的真实后果：Dart 有 `HttpFailure`（HTTP/TLS 层失败），
// Swift 表里没有 ⇒ 界面落到兜底分支显示「设备返回了未预期的错误（HttpFailure）」，
// 而核心明明知道是「文件流请求失败（HTTP 500）」。
//
// 这里守三条：
//   1. **产品代码里出现的 kind 字面量必须已登记**（新增 kind 忘登记 ⇒ 红）；
//   2. **两类互不重叠**（一个 kind 不能既要求文案又不要求）；
//   3. **导出的 JSON 与 Dart 表一致**（改了表忘重新导出 ⇒ 红，
//      否则 Swift 侧的比对就是拿旧契约在比，等于没锁）。
//
// 运行：dart run test_error_kinds.dart
import 'dart:convert';
import 'dart:io';

import 'lib/error_kinds.dart';

int _passed = 0, _failed = 0;

void _check(String name, bool Function() body) {
  try {
    if (body()) {
      _passed++;
      stdout.writeln('  ✓ $name');
    } else {
      _failed++;
      stdout.writeln('  ✗ $name');
    }
  } catch (e) {
    _failed++;
    stdout.writeln('  ✗ $name —— 抛异常：$e');
  }
}

/// 扫出产品代码里用到的 kind。
///
/// 两条来源都算，因为适配器层已经改成引用 `ErrorKind.xxx` 常量，
/// 而核心层仍在 `CoreError('…')` 里写字面量：
///   * `AdapterFailure('…'` / `CoreError('…'` 的**字面量**；
///   * `ErrorKind.<常量>` 的**引用**（经 [constantToKind] 还原成 kind 取值）。
///
/// 为什么是扫源码而不是只靠常量：漏改一处，契约就又是「看起来统一、
/// 实际各写各的」。扫描能把存量一起管住，且对新增零成本。
///
/// 只看 `lib/` 与 `bin/`：测试文件里的假 kind（如 `UnexpectedCall`）
/// 不属于对外契约。
Map<String, List<String>> scanKinds(Directory root, Map<String, String> constToKind) {
  final found = <String, List<String>>{};
  final literal = RegExp(r"\b(?:AdapterFailure|CoreError)\s*\(\s*'([A-Za-z][A-Za-z0-9]*)'");
  final ref = RegExp(r"\bErrorKind\.([a-zA-Z][a-zA-Z0-9]*)");
  for (final entry in root.listSync(recursive: true)) {
    if (entry is! File || !entry.path.endsWith('.dart')) continue;
    final rel = entry.path.split('${Platform.pathSeparator}MyNASCore${Platform.pathSeparator}').last;
    if (rel == 'lib/error_kinds.dart') continue; // 表自身不是「使用」
    final lines = entry.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      // 注释里会出现 `AdapterFailure('UnsupportedApi', ...)` 这类示例（adapter_contract.dart
      // 就有），必须跳过，否则把文档误当成协议。
      if (lines[i].trimLeft().startsWith('//')) continue;
      final at = '$rel:${i + 1}';
      for (final m in ref.allMatches(lines[i])) {
        final kind = constToKind[m.group(1)];
        if (kind != null) found.putIfAbsent(kind, () => <String>[]).add(at);
      }
      // 允许跨行构造（`lib/adapters/webdav.dart` 里的 EmptyScope / RateLimited 就是换行的）。
      final window = lines.skip(i).take(3).join('\n');
      final m = literal.firstMatch(window);
      if (m == null) continue;
      found.putIfAbsent(m.group(1)!, () => <String>[]).add(at);
    }
  }
  return found;
}

/// 从 `lib/error_kinds.dart` 读出「常量名 → kind 取值」。
///
/// 不手写这份映射：手写会漂移，而它一旦漂移，引用就查不出来，
/// 扫描会静默少算（比直接报错更危险）。
Map<String, String> constantToKind(File table) {
  final re = RegExp(r"static const (\w+) = '([A-Za-z0-9]+)';");
  final out = <String, String>{};
  for (final m in re.allMatches(table.readAsStringSync())) {
    out[m.group(1)!] = m.group(2)!;
  }
  if (out.isEmpty) throw StateError('没解析到任何常量，正则与 error_kinds.dart 已经不匹配了');
  return out;
}

void main() {
  stdout.writeln('核心错误 kind 契约');

  final here = File(Platform.script.toFilePath()).parent;
  final consts = constantToKind(File('${here.path}/lib/error_kinds.dart'));
  final used = <String, List<String>>{}
    ..addAll(scanKinds(Directory('${here.path}/lib'), consts))
    ..addAll(scanKinds(Directory('${here.path}/bin'), consts));

  _check('扫描确实抓到了字面量（扫不到就是正则失效，等于没测）', () {
    if (used.isEmpty) {
      stdout.writeln('    !! 一个 kind 都没扫到');
      return false;
    }
    return used.length >= 20;
  });

  stdout.writeln('  扫描到 ${used.length} 个产品代码里的 kind：${used.keys.toList()..sort()}');

  _check('★ 产品代码里出现的每个 kind 都已登记在 ErrorKind.all', () {
    final missing = used.keys.where((k) => !ErrorKind.all.contains(k)).toList()..sort();
    for (final k in missing) {
      stdout.writeln('    !! 未登记：$k —— ${used[k]!.join(', ')}');
    }
    if (missing.isNotEmpty) {
      stdout.writeln('    在 lib/error_kinds.dart 里补上，并把它归入 userFacing 或 internal。');
    }
    return missing.isEmpty;
  });

  _check('userFacing 与 internal 不重叠', () {
    final both = ErrorKind.userFacing.intersection(ErrorKind.internal);
    if (both.isNotEmpty) stdout.writeln('    !! 同时属于两类：$both');
    return both.isEmpty;
  });

  _check('ErrorKind.all 恰好等于两类之和', () {
    final expected = {...ErrorKind.userFacing, ...ErrorKind.internal};
    return ErrorKind.all.length == expected.length &&
        ErrorKind.all.every(expected.contains);
  });

  _check('没有登记了却从未使用的 kind（表膨胀会让"哪些错误真的会发生"失真）', () {
    final unused = ErrorKind.all.where((k) => !used.containsKey(k)).toList()..sort();
    // 这两类例外是**设计上**就没有字面量的：DSM 错误码动态映射出来的种类、
    // 以及取消令牌直接把 reason 当 kind 用。
    const dynamicAllowed = {
      'AccountDisabled', 'OTPRejected', 'IPBlocked', 'PasswordLifecycle',
      'Cancelled', 'TimedOut',
    };
    final bad = unused.where((k) => !dynamicAllowed.contains(k)).toList();
    if (bad.isNotEmpty) stdout.writeln('    !! 登记了但产品代码里没有出处：$bad');
    return bad.isEmpty;
  });

  _check('★ 导出的 error_kinds.json 与 Dart 表一致', () {
    final f = File('${here.path}/error_kinds.json');
    if (!f.existsSync()) {
      stdout.writeln('    !! 缺少 error_kinds.json —— 跑 dart run bin/export_error_kinds.dart');
      return false;
    }
    final json = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    final jf = (json['userFacing'] as List).cast<String>();
    final ji = (json['internal'] as List).cast<String>();
    final okUF = jf.length == ErrorKind.userFacing.length &&
        jf.every(ErrorKind.userFacing.contains);
    final okI =
        ji.length == ErrorKind.internal.length && ji.every(ErrorKind.internal.contains);
    if (!okUF) stdout.writeln('    !! userFacing 不一致：JSON ${jf.length} 项 vs 表 ${ErrorKind.userFacing.length} 项');
    if (!okI) stdout.writeln('    !! internal 不一致');
    return okUF && okI;
  });

  stdout.writeln('\n通过 $_passed 项，失败 $_failed 项');
  if (_failed > 0) exitCode = 1;
}
