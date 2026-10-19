// 适配器失败的「上报链路」验证。
//
// 运行：
//   dart run test_adapter_failure_reporting.dart
//
// ── 这里要钉死的是一个真实故障 ─────────────────────────────────────
// 报「WebDAV 和飞牛登录飞牛 NAS 都失败」，界面上只有一个
// 空洞的「连接失败」。查下去发现：适配器其实**早就知道原因** ——
//   webdav → 「无法连接 WebDAV 服务（TLS 握手失败）」
//   fnos   → 「飞牛 NAS 登录失败：所有已知登录端点均不可用」
// 但 `AdapterFailure` 不是 `CoreError`，一路冒到 `command()` 的兜底分支，
// 被压成 `const CoreError('ProtocolViolation')`。于是：
//   * 屏幕上：看不出真因；
//   * 诊断文件里：`errorKind=ProtocolViolation`，与「设备返回了坏数据」同形。
//
// 这个文件锁两件事：
//   1. `AdapterFailure.toCoreError()` 必须把 kind 与那句话都带出来，
//      且 `detail`（会落进诊断文件）**不得含那句话**（可能带路径）；
//   2. 经由真正的 harness 子进程走一遍，线路上收到的必须是带 `reason`
//      的错误，**绝不能再是裸 `ProtocolViolation`**。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'lib/adapter_support.dart';
import 'lib/protocol.dart';

int _passed = 0, _failed = 0;
final _failures = <String>[];

void ok(String name) {
  _passed++;
  // ignore: avoid_print
  print('  ok   $name');
}

void fail(String name, Object error) {
  _failed++;
  _failures.add('$name :: $error');
  // ignore: avoid_print
  print('  FAIL $name\n       $error');
}

void expect(bool condition, String name, [String? note]) {
  if (condition) {
    ok(name);
  } else {
    fail(name, note ?? '断言不成立');
  }
}

/// 找一个「一定连不上」的端口：先占用再释放，端口随即空闲（连接会被拒绝）。
Future<int> closedPort() async {
  final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = probe.port;
  await probe.close();
  return port;
}

/// 用真正的 harness 子进程跑一条 login，把线路上收到的错误事件取回来。
Future<Map<String, Object?>?> wireLoginError({
  required String vendor,
  required String endpoint,
  required bool allowInsecureHTTP,
}) async {
  final trust = await Directory.systemTemp.createTemp('ff2-adapter-failure-');
  final payload = <String, Object?>{
    'protocolVersion': 1,
    'requestID': 'r1',
    'sourceID': 'probe-$vendor',
    'queryID': 'none',
    'command': 'discover',
    'mode': 'live',
    'vendor': vendor,
    'endpoint': endpoint,
    'trust': {'mode': 'system'},
    'allowInsecureHTTP': allowInsecureHTTP,
    'requestBudgetMs': 2000,
    'queryBudgetMs': 2000,
  };
  final login = <String, Object?>{
    'protocolVersion': 1,
    'requestID': 'r2',
    'sourceID': 'probe-$vendor',
    'queryID': 'none',
    'command': 'login',
    'account': 'probe-does-not-exist',
    'password': 'probe-does-not-login',
  };
  try {
    final process = await Process.start(
      Platform.resolvedExecutable,
      ['--disable-dart-dev', 'bin/harness.dart'],
      environment: {'FF2_TRUST_DIR': trust.path},
    );
    process.stdin.write('${jsonEncode(payload)}\n${jsonEncode(login)}\n');
    await process.stdin.flush();
    await process.stdin.close();
    final lines = await process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .toList()
        .timeout(const Duration(seconds: 60));
    await process.exitCode;
    Map<String, Object?>? terminal;
    for (final line in lines) {
      final decoded = jsonDecode(line);
      if (decoded is Map && decoded['requestID'] == 'r2' && decoded['event'] == 'terminal') {
        terminal = Map<String, Object?>.from(decoded);
      }
    }
    return terminal;
  } finally {
    await trust.delete(recursive: true);
  }
}

Future<void> main() async {
  // ignore: avoid_print
  print('闪寻 · 适配器失败上报链路验证');

  // ── 1. 翻译本身 ───────────────────────────────────────────────
  // ignore: avoid_print
  print('\n══ 1. AdapterFailure → CoreError 的翻译');
  {
    const failure = AdapterFailure('AuthenticationFailed', '无法连接 WebDAV 服务（TLS 握手失败）', apiCode: 401);
    final error = failure.toCoreError(method: 'login');
    expect(error.kind == 'AuthenticationFailed', 'kind 原样保留（不再被压成 ProtocolViolation）',
        '实际 ${error.kind}');
    expect(error.reason == '无法连接 WebDAV 服务（TLS 握手失败）', '给人看的那句话被带出来',
        '实际 ${error.reason}');
    expect(error.method == 'login', 'method 记录了是哪个命令失败', '实际 ${error.method}');
    expect(error.code == 401, '设备错误码保留', '实际 ${error.code}');
    // detail 会落进产品端诊断文件，不能把可能含路径的句子放进去。
    expect(error.detail == 'adapter:AuthenticationFailed', 'detail 只是机器标签，不含那句话',
        '实际 ${error.detail}');
    final json = error.toJson();
    expect(json['reason'] == '无法连接 WebDAV 服务（TLS 握手失败）', 'reason 进了协议 JSON');
    expect(json['detail'] == 'adapter:AuthenticationFailed', 'detail 进了协议 JSON 且是标签');
  }
  {
    final error = AdapterFailures.pathMissing('WebDAV 路径不存在：/共享目录-子目录/某目录').toCoreError();
    expect(!error.toJson().containsKey('reason') || !('${error.detail}').contains('/'),
        '带路径的文案只进 reason，不进 detail（诊断文件不落路径）',
        'detail=${error.detail}');
    expect((error.reason ?? '').contains('/共享目录-子目录'), 'reason 保留完整原因供界面显示');
  }

  // ── 2. 线路上真的带上来了吗 ────────────────────────────────────
  // ignore: avoid_print
  print('\n══ 2. 经由 harness 子进程：线路上必须带 reason');
  {
    final port = await closedPort();
    final terminal = await wireLoginError(
      vendor: 'webdav', endpoint: 'http://127.0.0.1:$port', allowInsecureHTTP: true);
    if (terminal == null) {
      fail('webdav 不可达端口 → 收到 terminal', '没有收到 login 的 terminal 事件');
    } else {
      final error = terminal['error'] as Map<String, Object?>? ?? const {};
      expect(error['kind'] != 'ProtocolViolation',
          '不可达端口不再报 ProtocolViolation（那是兜底分支在冒充设备问题）',
          '实际 kind=${error['kind']}');
      expect(error['kind'] == 'AuthenticationFailed', 'kind 是适配器给出的 AuthenticationFailed',
          '实际 ${error['kind']}');
      final reason = error['reason'] as String? ?? '';
      expect(reason.contains('WebDAV'), 'reason 里带得回「无法连接 WebDAV 服务」这类可用信息',
          '实际 reason="$reason"');
      expect((error['detail'] as String? ?? '').startsWith('adapter:'),
          'detail 是机器标签（会落诊断文件）', '实际 ${error['detail']}');
    }
  }

  // ignore: avoid_print
  print('\n──────────────────────────────────────────────');
  // ignore: avoid_print
  print('通过 $_passed / 失败 $_failed');
  for (final f in _failures) {
    // ignore: avoid_print
    print('  · $f');
  }
  exitCode = _failed == 0 ? 0 : 1;
}

// 让 `expect` 里用到的导入不被判为未使用。
// ignore: unused_element
const int _keepImportsWarm = coreRevision;
