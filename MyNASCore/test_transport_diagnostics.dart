// 证书固定传输层（原生助手）失败状态的**诊断契约**回归测试。
//
// ── 为什么要有这个文件 ────────────────────────────────────────────
// 复搜仍然失败时，诊断轨迹里群晖源那一行是：
//
//     errorKind = ProtocolViolation
//     errorDetail = native:ProtocolViolation
//     errorApi = SYNO.FileStation.Search / errorMethod = list
//     reportedTotal = null
//
// `native:` 前缀只可能来自 `source_pinned_transport.dart`，也就是**原生助手**
// 报回来的状态。但三件完全不同的事曾被压成同一个 `ProtocolViolation`：
//
//   · 响应体是空的
//   · 响应体超过 262144 字节（256 KB —— 一个没有任何依据的魔数）
//   · 响应体不是 JSON
//
// 于是「到底差在哪」在诊断里根本读不出来，只能靠猜。现在拆成
// `EmptyBody` / `BodyTooLarge` / `NonJSONBody` / `InvalidTimeout`，
// 并把**字节数**带进 `detail`。这个文件锁的就是这条链路：
// 拆开的每种状态都必须 (a) 归到 ProtocolViolation（不能掉进 NetworkFailure），
// (b) 在 detail 里留下可区分的标识与字节数。
//
// 运行：dart run test_transport_diagnostics.dart
import 'dart:io';

import 'lib/source_pinned_transport.dart';
import 'lib/source_trust.dart';

int _passed = 0, _failed = 0;

void _check(String title, bool Function() body) {
  try {
    if (!body()) throw StateError('断言失败');
    _passed++;
    stdout.writeln('  ✅ $title');
  } catch (error) {
    _failed++;
    stdout.writeln('  ❌ $title');
    stdout.writeln('     $error');
  }
}

void _expect(bool condition, String message) {
  if (!condition) throw StateError(message);
}

void main() {
  stdout.writeln('原生助手失败状态的诊断契约');

  // ── 对外错误种类 ──────────────────────────────────────────────
  //
  // 「响应体不可用」这一类必须全部落在 ProtocolViolation 上：
  // 用户处置是同一件事（设备返回的东西没法当 API 响应解读）。
  // **绝不能落到默认分支**：默认是 NetworkFailure，那会把
  // 「代理挡了 / 响应太大」说成「网络不通」，指向完全错误的排查方向。
  _check('响应体相关的四种助手状态都归到 ProtocolViolation', () {
    for (final kind in ['EmptyBody', 'BodyTooLarge', 'NonJSONBody', 'InvalidTimeout']) {
      _expect(transportKind(kind) == 'ProtocolViolation', '$kind 应为 ProtocolViolation，实际 ${transportKind(kind)}');
      _expect(transportKind(kind) != 'NetworkFailure', '$kind 不能掉进 NetworkFailure');
    }
    return true;
  });

  _check('原有的助手状态映射不被这次改动破坏', () {
    _expect(transportKind('HttpFailure') == 'HttpFailure', 'HttpFailure 应原样透出');
    _expect(transportKind('TimedOut') == 'TimedOut', 'TimedOut 应原样透出');
    _expect(transportKind('UnsafeEndpoint') == 'UnsafeEndpoint', 'UnsafeEndpoint 应原样透出');
    _expect(transportKind('ProtocolViolation') == 'ProtocolViolation', '旧助手仍会报这个状态');
    return true;
  });

  _check('未知状态退回 NetworkFailure（明确的兜底，而非静默通过）', () {
    _expect(transportKind('SomethingBrandNew') == 'NetworkFailure', '未知状态应有确定的兜底');
    return true;
  });

  // ── 诊断 detail ───────────────────────────────────────────────
  //
  // detail 只进诊断文件、不给用户看，但它必须能把失败**分开**：
  // 带不带字节数、是哪种状态，决定了下一步该查代理、查设备还是查客户端。
  _check('BodyTooLarge 的 detail 带上字节数', () {
    final detail = nativeTransportDetail(NativeTransportError('BodyTooLarge', null, bytes: 312480));
    _expect(detail == 'native:BodyTooLarge:312480', '实际 $detail');
    return true;
  });

  _check('NonJSONBody 的 detail 也带字节数（0 字节与 400KB 是两回事）', () {
    _expect(nativeTransportDetail(NativeTransportError('NonJSONBody', null, bytes: 4123)) == 'native:NonJSONBody:4123',
        '实际 ${nativeTransportDetail(NativeTransportError('NonJSONBody', null, bytes: 4123))}');
    _expect(nativeTransportDetail(NativeTransportError('EmptyBody', null, bytes: 0)) == 'native:EmptyBody:0',
        '空响应要能和「有内容但读不出来」区分开');
    return true;
  });

  _check('没有字节数时不凭空补一个（旧助手不会给这个字段）', () {
    final detail = nativeTransportDetail(NativeTransportError('HttpFailure', 502));
    _expect(detail == 'native:HttpFailure', '实际 $detail');
    return true;
  });

  stdout.writeln('');
  stdout.writeln('通过 $_passed 项，失败 $_failed 项');
  if (_failed > 0) exitCode = 1;
}
