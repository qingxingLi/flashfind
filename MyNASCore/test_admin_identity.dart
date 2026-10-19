// 管理员账号行为的回归测试。
//
// 管理员账号的实际能力从未在真机上验证过。
// 「is_manager == true 一律拒绝」这条硬限制，就是把这种未经证实的推断
// 当成了结论——它是为了把验收对象固定成普通账号而加的。
//
// 现在管理员账号**允许使用**，但身份要记录下来透给客户端提示用户：
// 管理员在 list_share 里能看到全部共享，搜索范围因此不受「被授予哪些目录」限制。
// 这是权限边界的实质性放宽，必须由用户知情后自行选择，而不是客户端替他决定。
import 'dart:io';
import 'lib/synology_api.dart';
import 'lib/protocol.dart';
import 'lib/mock_transport.dart';

Future<void> main() async {
  await _adminIsAccepted();
  await _adminIsRecorded();
  await _ordinaryAccountIsUnaffected();
  await _nonBooleanIdentityStillRejected();
  stdout.writeln('admin identity: 4 项通过');
}

SynologyApi _api(Map<String, Object?> info) {
  final transport = MockTransport(hook: (r, c) async {
    if (r.api == 'SYNO.FileStation.Info') return MockTransport.ok(info);
    return null;
  });
  return SynologyApi(transport, 'admin-probe');
}

Future<void> _adminIsAccepted() async {
  final api = _api({'is_manager': true});
  await api.discover(Cancellation());
  await api.login('admin', 'p', Cancellation());
  // 关键断言：管理员**不再**被拒绝。
  await api.authorize(Cancellation());
  if (!api.scopeReady) throw StateError('管理员账号应当被接受');
  if (api.isManager != true) throw StateError('管理员身份应当被记录');
}

Future<void> _adminIsRecorded() async {
  // 身份是通过 sessionState/authState 的 isManager 字段透给 Swift 的，
  // 这里确认字段真的被记录，而不是默认值碰巧为 true。
  final api = _api({'is_manager': false});
  await api.discover(Cancellation());
  await api.login('nasuser', 'p', Cancellation());
  await api.authorize(Cancellation());
  if (api.isManager != false) throw StateError('普通账号不应被标为管理员');
}

Future<void> _ordinaryAccountIsUnaffected() async {
  final api = _api({'is_manager': false});
  await api.discover(Cancellation());
  await api.login('nasuser', 'p', Cancellation());
  await api.authorize(Cancellation());
  if (!api.scopeReady) throw StateError('普通账号应当照常可用');
  if (api.isManager) throw StateError('普通账号不应被标为管理员');
}

Future<void> _nonBooleanIdentityStillRejected() async {
  // 真正需要拒绝的是「无法确认身份」，而不是「身份是管理员」。
  final api = _api({'is_manager': 'yes'});
  await api.discover(Cancellation());
  await api.login('who', 'p', Cancellation());
  var rejected = false;
  try { await api.authorize(Cancellation()); } on CoreError catch (e) { rejected = e.kind == 'IdentityUnverified'; }
  if (!rejected) throw StateError('身份无法确认时必须拒绝');
}
