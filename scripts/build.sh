#!/bin/sh
# 统一构建入口 —— **只做分发，不合并实现**。
#
#   ./scripts/build.sh core      编译 Dart 核心 + native trust helper，装进 Resources/MyNAS
#   ./scripts/build.sh app       编译 Swift 可执行体 FlashFind2App
#   ./scripts/build.sh test      Swift 全量测试（唯一回归门槛）+ Dart 核心行为测试
#   ./scripts/build.sh package   完整打包：编译 + 签名 + zip + dmg + 挂载复核
#
# 为什么要有这一层：此前「打包」「装核心」两个入口散在根目录，新人只能靠翻
# README 猜该跑哪个。这里把「做什么」收敛成四个动词，底层脚本各自保持独立——
# 合并成一个大脚本会让「只想重编核心」的人被迫跑完打包，也让各步日志搅在一起。
#
# 参数原样透传给底层脚本，本层不解释、不改写。
set -eu

cd "$(dirname "$0")/.."
CLIENT=$(pwd)

usage() {
    cat <<'USAGE'
用法: scripts/build.sh <core|app|test|package> [底层脚本参数...]

  core     重新编译 Dart AOT 核心与 native trust helper，装进 Resources/MyNAS。
           底层: tools/install-mynas-core.sh（自带 analyze + 行为测试 + 冒烟）。
           缺 Dart SDK 时该脚本自己会报错退出，不静默跳过。

  app      swift build --product FlashFind2App（debug）。
           ★ MyNAS 运行时（Resources/MyNAS/）是构建产物、不进 Git，clean clone 后
             不在位。此时本子命令**直接失败**并指路，绝不产出一个缺运行时的 App。
           加 --with-core 则先自动跑 core 再编译。

  test     先跑 Swift 全量测试，再逐个跑 Dart 核心行为测试（test_*.dart）。
           test_webdav_live.dart 需要真机设备，本入口**跳过并显式打印**。
           本机没有 Dart SDK 时同样打印「未执行」，不用旧数字冒充本轮结果。

  package  完整打包。必填 --output <新目录>，以及下列之一：
             --scratch <目录> --temporary-alias <项目内软链>   （源码构建）
             --app-from-zip <已发布 zip>                     （只重做安装包，不重编）
           可加 --release / --icon <.icns> / --reuse-mynas-resources <.app>
           底层: scripts/build_trial.py

不带子命令、或子命令不认识：打印用法并以 1 退出，不猜你要干什么。
USAGE
}

die() {
    echo "build.sh: $1" >&2
    usage >&2
    exit 1
}

[ $# -ge 1 ] || die "缺少子命令"

cmd=$1
shift

# Dart SDK 的装法各人不同，不写任何人的本机路径：环境变量 → PATH → 常见位置。
find_dart() {
    if [ -n "${DART_SDK:-}" ] && [ -x "$DART_SDK/bin/dart" ]; then
        echo "$DART_SDK/bin/dart"
        return 0
    fi
    if command -v dart >/dev/null 2>&1; then
        command -v dart
        return 0
    fi
    for candidate in "$HOME/flutter/bin/cache/dart-sdk" \
                     /opt/homebrew/opt/dart-sdk/libexec \
                     /usr/local/opt/dart-sdk/libexec \
                     /usr/lib/dart; do
        if [ -x "$candidate/bin/dart" ]; then
            echo "$candidate/bin/dart"
            return 0
        fi
    done
    return 1
}

# 本包依赖的官方 MCP SDK 声明了 `swift-tools-version:6.1`，而 SwiftPM 校验的是
# 「被依赖包的 tools-version vs **当前工具链**」——不是拿本包 manifest 去比
# （四组对照实验见方案 §8.1.1）。工具链低于 6.1 时，报错落在依赖包身上：
#   error: package 'swift-sdk' is using Swift tools version 6.1.0
#          but the installed version is 6.0.3
# 那句话太容易被读成「仓库坏了」。入口处先说清缺什么、怎么补。
require_swift_61() {
    v=$(swift --version 2>/dev/null | sed -n 's/.*Swift version \([0-9][0-9.]*\).*/\1/p' | head -1)
    if [ -n "$v" ] && printf '%s\n' "$v" | awk -F. '{exit !($1>6 || ($1==6 && $2>=1))}'; then
        return 0
    fi
    echo "build.sh: 本包需要 Swift 6.1+（MCP SDK 0.12.1 的 swift-tools-version 是 6.1）。" >&2
    echo "          当前工具链：${v:-无法识别}" >&2
    echo "          两条路，任选其一：" >&2
    echo "            1) 装 Xcode 16.3+，并把 xcode-select 指向它（全局生效）" >&2
    echo "            2) 用已装好的 6.1+ 工具链，只对这一条命令生效：" >&2
    echo "               TOOLCHAINS=<CFBundleIdentifier> ./scripts/build.sh $cmd" >&2
    echo "               （标识见 ~/Library/Developer/Toolchains/*.xctoolchain/Info.plist）" >&2
    exit 1
}

case "$cmd" in
core)
    # 底层脚本是 bash，必须用 bash 调，不能 sh。
    exec bash "$CLIENT/tools/install-mynas-core.sh" "$@"
    ;;
app)
    # ★ Resources/MyNAS/ 整份被 .gitignore 排除（它是 install-mynas-core.sh 的产物），
    #   所以 clean clone 后这里一定是空的。裸 swift build 会「编译成功」——Package.swift
    #   并不把 mynas-core 当资源依赖——而产出的 App 缺 NAS 运行时。这种成功比报错更糟：
    #   它要到用户点了 NAS 搜索才炸，报错落在运行时、指不回构建步骤，排查成本极高。
    #   因此：运行时不在位 ⇒ 明确失败并指路；显式 --with-core ⇒ 先补建再编译。
    auto_core=0
    if [ "${1:-}" = "--with-core" ]; then auto_core=1; shift; fi
    core_bin="$CLIENT/Resources/MyNAS/bin/mynas-core"
    helper_bin="$CLIENT/Resources/MyNAS/native/TrustHTTP"
    if [ ! -x "$core_bin" ] || [ ! -x "$helper_bin" ]; then
        if [ "$auto_core" = 1 ]; then
            echo "==> MyNAS 运行时不在位，先构建 core（--with-core）"
            bash "$CLIENT/tools/install-mynas-core.sh" || exit 1
        else
            echo "build.sh: MyNAS 运行时不在位：" >&2
            for f in "$core_bin" "$helper_bin"; do
                [ -x "$f" ] || echo "    缺 $f" >&2
            done
            echo "Resources/MyNAS/ 是构建产物、不进 Git，clean clone 后必须先补建。" >&2
            echo "    先执行：      ./scripts/build.sh core" >&2
            echo "    或一步到位：  ./scripts/build.sh app --with-core" >&2
            exit 1
        fi
    fi
    require_swift_61
    exec swift build --package-path "$CLIENT" --product FlashFind2App --disable-sandbox \
        --only-use-versions-from-resolved-file "$@"
    ;;
test)
    require_swift_61
    echo "==> Swift 全量测试（唯一回归门槛）"
    # ★ 1.1.2 起本包依赖官方 MCP SDK（`exact 0.12.1`），而该 SDK 的 manifest 声明了
    #   `swift-docc-plugin` 的 `branch: "main"` 依赖。branch 依赖本身不可复现，
    #   所以「用哪份依赖」不交给每次 resolve 去猜：这里钉死只用 Package.resolved
    #   记录的版本，解析结果与文件不符就直接失败，而不是悄悄换一个 commit 继续测。
    #   ★ 升级依赖的唯一合法路径是显式跑 `swift package resolve` 并提交新的
    #   Package.resolved；本入口不替任何人做这个决定。
    swift test --package-path "$CLIENT" --disable-sandbox \
        --only-use-versions-from-resolved-file
    echo
    echo "==> Dart 核心行为测试"
    if dart_bin=$(find_dart); then
        echo "    Dart SDK：$dart_bin"
        for suite in "$CLIENT"/MyNASCore/test_*.dart; do
            case "$suite" in
            */test_webdav_live.dart)
                echo "    跳过 $(basename "$suite")：需要真机设备与真实 NAS"
                continue
                ;;
            esac
            echo "    ---- $(basename "$suite")"
            # ★ 必须进 MyNASCore 目录再跑。
            #   本入口的 cwd 是 client 根（`cd "$(dirname "$0")/.."`），而
            #   test_adapter_failure_reporting 的第二部分会起 harness 子进程，
            #   子进程按相对路径找核心与 harness —— 在 client 根跑，这条
            #   「webdav 不可达端口 → 收到 terminal」必红，且只在通过本入口
            #   跑时才红，单独 `cd MyNASCore && dart run` 是绿的。
            #   于是「统一入口是红的、直接跑是绿的」这种最容易被当成抽风的
            #   不一致，根子就是 cwd。用 subshell 切过去，不动外层 cwd。
            ( cd "$CLIENT/MyNASCore" && "$dart_bin" run "$suite" )
        done
    else
        echo "    *** 未执行：本机找不到 Dart SDK ***"
        echo "    设 DART_SDK=/path/to/dart-sdk，或把 dart 放进 PATH 后重跑。"
        echo "    （此处不沿用历史数字，本轮 Dart 套件状态就是未执行。）"
    fi
    ;;
package)
    require_swift_61
    [ $# -ge 1 ] || die "package 需要 --output <新目录>"
    case " $* " in
    *" --output "*) ;;
    *) die "package 需要 --output <新目录>" ;;
    esac
    exec python3 "$CLIENT/scripts/build_trial.py" "$@"
    ;;
*)
    die "未知子命令：$cmd"
    ;;
esac
