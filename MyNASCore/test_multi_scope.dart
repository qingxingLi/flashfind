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
  _wholeRootScopeIsExplicitlyGranted();
  stdout.writeln('multi-scope: 5 项通过');
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
  // 空列表、空串列表、物理卷路径、含穿越的路径——都要被拒。
  //
  // ★ `'/'` 不在这个列表里了：它现在是「整个可见空间」这个**合法**位置，
  //   但只对声明了整根授权的来源成立，见 `_wholeRootScopeIsExplicitlyGranted`
  //   与 test_search_roots 的 hostile 列表（未授权的 "/" 仍被拒）。
  try { Scope.multi([]); } on CoreError catch (e) { if (e.kind == 'ScopeDenied') rejected++; }
  try { Scope.multi(['']); } on CoreError catch (e) { if (e.kind == 'ScopeDenied') rejected++; }
  try { Scope('/volume1/secret'); } on CoreError catch (e) { if (e.kind == 'ScopeDenied') rejected++; }
  try { Scope('/示例共享/../../etc'); } on CoreError catch (e) { if (e.kind == 'UnsafeLogicalPath') rejected++; }
  if (rejected != 4) throw StateError('应拒绝 4 种非法范围，实际 $rejected');
  // 合法多根不应被误拒：加一个不会改变计数的合法构造。
  Scope.multi(['/示例共享', '/home', '/docker']);
  if (rejected != 4) throw StateError('合法范围被误拒');
  // 其中只要有一个根非法，整组都要被拒——不能「部分放行」。
  var groupRejected = false;
  try { Scope.multi(['/示例共享', '/volume1/secret']); } on CoreError catch (e) { groupRejected = e.kind == 'ScopeDenied'; }
  if (!groupRejected) throw StateError('多根中混入未授权根时必须整组拒绝');
}

/// ★ `'/'` = 「整个可见空间」，**只在显式授权时才成立**。
///
/// 为什么需要它：OpenList 那种根下挂着上千个文件夹的站点（实测 1724 个），
/// 逐个当搜索位置既列不完也勾不完，真勾上则一次搜索要发 2×N 个请求。
/// 而 `parent='/'` 一次就覆盖全库。
///
/// 这不等于「放开根目录」：群晖那种按共享授权的来源，roots 里根本没有 `'/'`，
/// 请求它照样被 `owningRoot == null` 拒掉（见 test_search_roots 的 hostile 列表）。
void _wholeRootScopeIsExplicitlyGranted() {
  final scope = Scope.multi(['/']);
  if (!scope.allows('/AIR/x.rar')) throw StateError('整根授权应放行根下任意路径');
  if (!scope.allows('/a/b/c.txt')) throw StateError('整根授权应放行任意深度');
  if (scope.owningRoot('/AIR/x.rar') != '/') throw StateError('整根授权下的归属根应为 /');
  // 收窄到整根本身（界面里「全部目录」存的就是这个值）。
  if (!scope.narrowTo(['/']).allows('/任何/路径')) throw StateError('应允许收窄到整根');
  // 收窄到整根下的某个子目录，同样成立 —— 且不允许越出这个子目录。
  final narrowed = scope.narrowTo(['/AIR']);
  if (!narrowed.allows('/AIR/x.rar')) throw StateError('整根之下应可收窄到子目录');
  if (narrowed.allows('/其他/x.rar')) throw StateError('收窄后不该放行别的子目录');
}
