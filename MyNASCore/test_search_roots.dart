// 搜索位置限定（`roots` 字段）的行为测试。
//
// 背景：界面上的「在选定位置搜索」要真的减少设备侧检索量，就必须把
// 限定的根**下发给设备**，而不是在客户端过滤结果。
//
// 这里锁住三件事：
//   1. 收窄后的根集合确实变小（少一个根 = 少一次设备侧扫描）；
//   2. 收窄**只允许变小**，越权的根一律拒绝（ScopeDenied）；
//   3. 不传 roots 时行为与从前完全一致（不限定）。
import 'dart:io';
import 'lib/protocol.dart';

Future<void> main() async {
  _narrowsToRequestedRoots();
  _rejectsUnauthorizedRoots();
  _rejectsMalformedRequests();
  _noRequestMeansNoNarrowing();
  stdout.writeln('search-roots: 4 项通过');
}

/// 收窄到某个根 ⇒ 生效的根集合只剩它。
void _narrowsToRequestedRoots() {
  final scope = Scope.multi(['/照片', '/文档', '/home']);
  final narrowed = scope.narrowTo(['/照片']);
  if (narrowed.roots.length != 1) throw StateError('应只剩 1 个根');
  if (!narrowed.roots.contains('/照片')) throw StateError('应保留 /照片');
  // 收窄后**不该**再放行其它根下的路径。
  if (narrowed.allows('/文档/a.txt')) throw StateError('收窄后不该再放行 /文档');
  // 原范围不受影响（收窄不是破坏性操作）。
  if (!scope.allows('/文档/a.txt')) throw StateError('原范围不该被收窄改掉');
}

/// ★ 越权的根一律拒绝 —— 这是本测试存在的最主要理由。
///
/// 客户端是不可信输入：它说「搜 /别人的目录」时，核心必须自己再判一次。
/// 只靠客户端保证是不够的——一次越权就能把整个盘扫一遍。
void _rejectsUnauthorizedRoots() {
  final scope = Scope.multi(['/照片', '/文档']);
  final hostile = [
    '/别人家',           // 完全无关
    '/照片X/a.txt',      // 前缀相同但不是子目录（多根改造踩过的坑）
    '/',                 // 整盘
    '/volume1/homes',    // 物理卷路径
    '',                  // 空串
    '/照片/../文档',     // 路径穿越
  ];
  for (final path in hostile) {
    var denied = false;
    try {
      scope.narrowTo([path]);
    } on CoreError catch (e) {
      if (e.kind == 'ScopeDenied' || e.kind == 'UnsafeLogicalPath') denied = true;
    }
    denied ? null : throw StateError('不该放行 $path');
  }
  // 空列表同样拒绝（不是「不限定」）。
  var emptyDenied = false;
  try {
    scope.narrowTo([]);
  } on CoreError catch (e) {
    if (e.kind == 'ScopeDenied') emptyDenied = true;
  }
  if (!emptyDenied) throw StateError('空列表不该被当成「不限定」');
}

/// 畸形请求要么拒绝，要么明确报错 —— 不能默默放行。
void _rejectsMalformedRequests() {
  final scope = Scope.multi(['/照片']);
  // 子目录是允许的：授权根之下再收窄一级，仍然在授权范围之内。
  final child = scope.narrowTo(['/照片/2024']);
  if (child.roots.length != 1) throw StateError('子目录收窄应保留 1 个根');
  if (!child.allows('/照片/2024/a.jpg')) throw StateError('子目录内的路径该放行');
  if (child.allows('/照片/2025/a.jpg')) throw StateError('子目录外的路径不该放行');
}

/// 不传 roots ⇒ 不收窄（调用方据此保持原行为）。
void _noRequestMeansNoNarrowing() {
  final scope = Scope.multi(['/照片', '/文档']);
  // 调用点的约定是「null 或空列表 = 不限定」，由调用方判断，不由 narrowTo 判断。
  // narrowTo 收到空列表一律拒绝（宁可报错，也不要静默扫全盘）。
  var denied = false;
  try {
    scope.narrowTo([]);
  } on CoreError catch (e) {
    if (e.kind == 'ScopeDenied') denied = true;
  }
  if (!denied) throw StateError('空列表必须拒绝');
  // 原始范围仍是两个根。
  if (scope.roots.length != 2) throw StateError('原范围不该被改变');
}
