// 多搜索位置（多根 Scope）的行为测试。
//
// 背景：Scope 最初是单根设计（单个 root 字符串），界面上因此只能单选一个搜索位置。
// 但 DSM 的 Search.start 本就接受 folder_path 数组，多目录一次搜索即可覆盖。
//
// 这里锁住三件事：
//   1. 多根都能被 allows 接受；
//   2. **不能**用字符串前缀冒充包含关系（`/示例共享X` 不该被 `/示例共享` 放行）；
//   3. owningRoot 能正确指出某条结果属于哪个共享 —— Finder 定位依赖它算共享名。
import 'dart:io';
import 'lib/protocol.dart';

Future<void> main() async {
  _acceptsEveryRoot();
  _rejectsPrefixLookalikes();
  _owningRootIsCorrect();
  _rejectsEmptyAndUnsafe();
  stdout.writeln('multi-scope: 4 项通过');
}

void _acceptsEveryRoot() {
  final scope = Scope.multi(['/示例共享', '/docker', '/home']);
  if (scope.roots.length != 3) throw StateError('应保留 3 个根');
  if (scope.isSingle) throw StateError('3 个根不算是单根');
  for (final path in ['/示例共享/a.txt', '/docker/b/Dockerfile', '/home/c/d.md']) {
    if (!scope.allows(path)) throw StateError('应允许 $path');
  }
}

void _rejectsPrefixLookalikes() {
  final scope = Scope.multi(['/示例共享', '/docker']);
  // 前缀相同但不是子目录：这是多根改造最容易引入的越权口子。
  for (final path in ['/示例共享X/a.txt', '/dockerfile/b', '/家目录/a']) {
    if (scope.allows(path)) throw StateError('不该允许 $path');
  }
  // `/` 这类畸形路径：`allows` 抛 UnsafeLogicalPath 而不是返回 false——
  // 这是原实现就有的刻意设计（畸形输入不该被当成「不在范围内」而静默放过），
  // 上面 _rejectsEmptyAndUnsafe 里单独断言了这一行为。
  if (scope.owningRoot('/示例共享/a.txt') != '/示例共享') throw StateError('owningRoot 判断错误');
}

void _owningRootIsCorrect() {
  final scope = Scope.multi(['/示例共享', '/docker']);
  // 每一段都要按「这条结果属于哪个共享」算，Finder 定位据此拼 SMB URL；
  // 若统一用单一 root，指向的共享就会错。
  final cases = {
    '/示例共享/质量/a.xlsx': '/示例共享',
    '/docker/compose.yml': '/docker',
  };
  cases.forEach((path, expected) {
    final owning = scope.owningRoot(path);
    if (owning != expected) throw StateError('$path 属于 $owning，应为 $expected');
  });
  if (scope.owningRoot('/示例共享X/a') != null) throw StateError('非子目录不该有归属根');
}

void _rejectsEmptyAndUnsafe() {
  var rejected = 0;
  // 空列表、空串列表、空根、根目录、物理卷路径、含穿越的路径——都要被拒。
  try { Scope.multi([]); } on CoreError catch (e) { if (e.kind == 'ScopeDenied') rejected++; }
  try { Scope.multi(['']); } on CoreError catch (e) { if (e.kind == 'ScopeDenied') rejected++; }
  // `/` 会先被 validate 拦下（含空段）→ UnsafeLogicalPath，而不是 ScopeDenied。
  // 两者的区别只是「在哪一步被拒」，安全效果相同：都是拒绝。
  try { Scope('/'); } on CoreError catch (e) { if (e.kind == 'UnsafeLogicalPath' || e.kind == 'ScopeDenied') rejected++; }
  try { Scope('/volume1/secret'); } on CoreError catch (e) { if (e.kind == 'ScopeDenied') rejected++; }
  try { Scope('/示例共享/../../etc'); } on CoreError catch (e) { if (e.kind == 'UnsafeLogicalPath') rejected++; }
  if (rejected != 5) throw StateError('应拒绝 5 种非法范围，实际 $rejected');
  // 合法多根不应被误拒：加一个不会改变计数的合法构造。
  Scope.multi(['/示例共享', '/home', '/docker']);
  if (rejected != 5) throw StateError('合法范围被误拒');
  // 其中只要有一个根非法，整组都要被拒——不能「部分放行」。
  var groupRejected = false;
  try { Scope.multi(['/示例共享', '/volume1/secret']); } on CoreError catch (e) { groupRejected = e.kind == 'ScopeDenied'; }
  if (!groupRejected) throw StateError('多根中混入未授权根时必须整组拒绝');
}
