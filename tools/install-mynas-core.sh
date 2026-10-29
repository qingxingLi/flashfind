#!/bin/bash
# 构建并安装 MyNAS 搜索核心到闪寻客户端
#
# 为什么需要这个脚本：
#   AppModel 通过 Bundle.main.resourceURL/…/MyNAS/bin/mynas-core 定位核心，
#   但 `swift build` 对 executableTarget 的 resources 不会在 .build 产物里生成
#   可用的资源 bundle。因此核心由本脚本安装到固定位置，不依赖 SwiftPM 资源机制。
#
# 产物：Resources/MyNAS/bin/mynas-core（arm64 Mach-O，自包含 Dart AOT）
#      Resources/MyNAS/native/TrustHTTP（原生 HTTPS 助手）
#
# 用法：bash tools/install-mynas-core.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT="$(cd "$HERE/.." && pwd)"
OUT="$CLIENT/Resources/MyNAS"
# Dart SDK 的安装位置各人不同（官方包 / brew / Flutter 自带 / 自定义工具链），
# 所以这里不写任何人的本机绝对路径：优先 DART_SDK，再看 PATH，最后兜几个常见位置。
find_dart_sdk() {
  if [[ -n "${DART_SDK:-}" && -x "$DART_SDK/bin/dart" ]]; then echo "$DART_SDK"; return 0; fi
  if command -v dart >/dev/null 2>&1; then
    local bin resolved
    bin="$(cd "$(dirname "$(command -v dart)")" && pwd)"
    resolved="$(cd "$bin/.." && pwd)"
    [[ -x "$resolved/bin/dart" ]] && { echo "$resolved"; return 0; }
  fi
  for candidate in /opt/homebrew/opt/dart-sdk/libexec \
                   /usr/local/opt/dart-sdk/libexec \
                   "$HOME/flutter/bin/cache/dart-sdk" \
                   /usr/lib/dart; do
    [[ -x "$candidate/bin/dart" ]] && { echo "$candidate"; return 0; }
  done
  return 1
}

DART_SDK="$(find_dart_sdk)" || {
  echo "找不到 Dart SDK：设 DART_SDK=/path/to/dart-sdk，或把 dart 放进 PATH" >&2
  exit 1
}
# 模块缓存落在构建目录里：它能删能重建，不必指向谁的私人目录。
SWIFT_MODULE_CACHE="${SWIFT_MODULE_CACHE:-$CLIENT/.build/swift-module-cache}"
mkdir -p "$SWIFT_MODULE_CACHE" 2>/dev/null || true
echo "==> Dart SDK：$DART_SDK"

echo "==> 静态检查核心源码（仅提示，不阻断构建）"
# 核心里存在两条既有 warning（未使用的 _fallback、恒假比较），
# dart analyze 因此返回非零；这里只看 error/warning 摘要，不阻断。
"$DART_SDK/bin/dart" analyze "$CLIENT/MyNASCore" 2>&1 | tail -3 || true

echo "==> 核心行为测试"
# 协议层改动的回归护栏（管理员账号、证书信任、批量发布等）。
# 这些断言写在 Dart 侧，因为它们验的是核心行为，Swift 测试覆盖不到。
"$DART_SDK/bin/dart" run "$CLIENT/MyNASCore/test_admin_identity.dart"
"$DART_SDK/bin/dart" run "$CLIENT/MyNASCore/test_multi_scope.dart"
# 来源根 / 共享名契约（6.3b-3）：适配器不许私自重造设备的身份空间。
"$DART_SDK/bin/dart" run "$CLIENT/MyNASCore/test_share_contract.dart"
# 飞牛 fnOS 端点契约（2026-10-28）：本地 fixture 模拟全部端点，真的验 PKCE、
# 多包拼接、单 path 搜索、下载 Range、refresh 后旧 token 失效。
# 这些断言必须在 Dart 侧，Swift 测试打不到适配器内部。
"$DART_SDK/bin/dart" run "$CLIENT/MyNASCore/test_fnos.dart"

echo "==> 编译 Dart AOT 核心"
mkdir -p "$OUT/bin" "$OUT/native"
"$DART_SDK/bin/dart" compile exe "$CLIENT/MyNASCore/bin/harness.dart" \
  -o "$OUT/bin/mynas-core"

echo "==> 编译原生 HTTPS 助手"
cp "$CLIENT/MyNASCore/native/TrustHTTP.swift" "$OUT/native/"
/usr/bin/swiftc -module-cache-path "$SWIFT_MODULE_CACHE" \
  "$OUT/native/TrustHTTP.swift" -o "$OUT/native/TrustHTTP"

echo "==> 校验产物"
for f in "$OUT/bin/mynas-core" "$OUT/native/TrustHTTP"; do
  [[ -x "$f" ]] || { echo "缺少可执行文件：$f" >&2; exit 1; }
  echo "  $(basename "$f") $(stat -f%z "$f") bytes"
done
file "$OUT/bin/mynas-core" | sed 's/^/  /'

echo "==> 冒烟测试（无凭据，预期返回 trust 相关错误而非崩溃）"
STATE="$(mktemp -d)"
chmod 700 "$STATE"
printf '%s\n' '{"protocolVersion":1,"requestID":"r1","sourceID":"demo-nas","queryID":"none","command":"discover","mode":"live","endpoint":"https://demo-nas.example:5001","scope":"/示例共享","trust":{"mode":"sourcePin"},"requestBudgetMs":30000,"queryBudgetMs":30000}' \
  | FF2_TRUST_DIR="$STATE" "$OUT/bin/mynas-core" 2>&1 | head -2
rm -rf "$STATE"

echo "完成。核心位于 $OUT"