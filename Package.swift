// swift-tools-version: 5.9
import Foundation
import PackageDescription

// `flashfind-mcp` 的版本从哪来（Phase 10 定案）。
//
// 它是一个**独立命令行可执行文件**，不放在 `Contents/MacOS`，所以 `Bundle.main`
// 不指向宿主 `闪寻.app`——实测在那个位置 `Bundle.main.infoDictionary` 就是 nil，
// `AppVersion.machineReadable` 会回落成 `0.0.0-dev`，MCP 客户端的 `serverInfo.version`
// 也就成了假值。
//
// ★ 修法用 Apple 给命令行工具的标准做法（Xcode 里的
//   `CREATE_INFOPLIST_SECTION_IN_BINARY`）：链接期把 plist 嵌进 Mach-O 的
//   `__TEXT,__info_plist`，之后 `Bundle.main` 原生就能读到，Helper 代码一行不改。
// ★ **不做**「运行时从可执行文件向上找宿主 .app 的 Info.plist」：那会给 Helper
//   装上一个它不该有的隐含契约（单独拷出来跑就变样、目录结构一变就读不到），
//   且本来属于它自己的版本却要依赖「碰巧被谁装着」。
// ★ 嵌入必须在 `codesign` **之前**——签完再改 Mach-O 会让签名失效。
//
// 版本事实仍在 `Resources/Packaging/Info.plist` 一处；`HelperInfo.plist` 是它的
// 派生副本，一致性由 `HelperPackagingTests` 与打包脚本双重守着（两份不一致就失败）。
let packagingDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Resources/Packaging")
// 链接器不接受相对路径（工作目录是 .build 里的某处），而写死绝对路径会让
// 公开仓克隆到别人机器上直接链接失败——所以用 `#filePath` 推。
let helperInfoPlist = packagingDirectory.appendingPathComponent("HelperInfo.plist").path

// MyNAS 搜索核心（Dart AOT 可执行 + 原生 HTTPS 助手）随 App 一起分发。
// AppModel 通过 Bundle.main.resourceURL/…/MyNAS/bin/mynas-core 定位它，
// 由 MyNASProcessBridge 以空参数启动，凭据只经stdin 管道传入。
//
// 对外产品是 Core 库、App，以及 1.1.2 起随包分发的 MCP 助手（target 名
// `FlashFindMCP`，打包后叫 `flashfind-mcp`）。CLI / smoke 是开发期工具，源码在
// tools/DevTools/，不列进 products，但仍可 `swift run FlashFindCLI` /
// `swift build --target FlashFindSmoke` 构建。
let package = Package(
    name: "FlashFind2",
    platforms: [.macOS(.v13)],
    // 说明：`FlashFindMCP` 没有单独的 product 条目——SwiftPM 会给每个
    // executableTarget 自动生成同名 product（`FlashFindCLI` / `FlashFindSmoke` 也是
    // 这样来的，见 `swift package describe`）。这里不重复声明，免得以后有人以为
    // 「没写进 products 就不算产品」而再加一份。
    products: [.library(name: "FlashFindCore", targets: ["FlashFindCore"]),
               .executable(name: "FlashFind2App", targets: ["FlashFind2App"])],
    dependencies: [
        // 官方 MCP Swift SDK（1.1.2 的协议层）。
        //
        // ★ exact，不用 from：SDK 还是 0.x，按语义化版本 0.x 的 **minor 是破坏性**的，
        //   `from: "0.12.1"` 会在某次 resolve 时自动升到 0.13 —— 换掉 API，
        //   而我们的构建可能"成功"到一半才炸。升级走单独 PR + 重跑测试与红证。
        // ★ 该包 manifest 是 `swift-tools-version:6.1`，所以**工具链必须 >= 6.1**；
        //   本包自己的 tools-version 仍保持 5.9（见方案 §8.1.1：SwiftPM 校验的是
        //   「被依赖包的 tools-version vs 当前工具链」，不是拿根包去比）。
        // ★ 它声明了 `branch: "main"` 的 swift-docc-plugin 依赖，本身不可复现。实测它
        //   **没有被拉进我们的依赖图**（SwiftPM 会裁掉"没有 target 引用其 product"的依赖），
        //   但它随时可能因为新增用法重新进图 → `Package.resolved` 必须提交，发布构建必须
        //   钉 `--only-use-versions-from-resolved-file`（方案 §8.1.3）。
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
        // swift-log 本来是 swift-sdk 的传递依赖（`Package.resolved` 里早有 1.15.1）。
        // Phase 11-lite 起 `FlashFindCore` 要显式 `import Logging`：`SanitizingTransport`
        // 是 `Transport` 的实现，而该协议要求一个 `Logger` 属性——名字出现在我们
        // 自己的代码里，就不该靠「传递依赖恰好可见」活着（那是哪天上游换个 logger
        // 实现就会静默断掉的隐式契约）。
        // ★ 这里钉 `exact: "1.15.1"`，与 `Package.resolved` 里已有的那一条**同一个版本**，
        //   所以 `swift package resolve` 之后 resolved 文件逐字节不变（判据见方案 §8.1.3）。
        .package(url: "https://github.com/apple/swift-log.git", exact: "1.15.1")
    ],
    targets: [
        // sqlite3.c 是上游的 amalgamation（单文件合并版），我们不改它一字——
        // 改了下次升级上游就要重新打一遍补丁。但它有 55 处 `MAX` / `MIN`
        // 会与 macOS SDK 里的同名宏撞上，每个编译单元刷一条
        // “ambiguous expansion of macro”。这 55 条不是我们的代码问题，
        // 也**不表示行为有分歧**（两侧都是取大/取小，展开结果一致），
        // 留着只会把真正属于 Swift 代码的警告淹掉。所以只在编译这一层关掉它。
        .target(name: "CSQLite", publicHeadersPath: "include", cSettings: [
            .define("SQLITE_ENABLE_FTS5"), .define("SQLITE_THREADSAFE", to: "1"),
            .define("SQLITE_ENABLE_COLUMN_METADATA"),
            .unsafeFlags(["-Wno-ambiguous-macro"])
        ]),
        // FlashFindCore 依赖 SDK，**只因为** `MCP/MCPHandler.swift`（Core 里唯一
        // `import MCP` 的文件，结构测试守着）。Tool / 路由 / 权限那些文件仍然不认识 SDK。
        //
        // ★ 代价要说清：App 目标和测试目标都依赖 FlashFindCore，于是它们也会链接
        //   SDK 的运行时（swift-nio 等）。这个代价在 Phase 10 打包时要复核一次
        //   （App 体积、公证、重复二进制），但**不靠「把 handler 挪进可执行文件」来省**——
        //   那会让 handler 变成不可测的代码（executableTarget 测试依赖不了）。
        .target(name: "FlashFindCore",
                dependencies: ["CSQLite",
                               .product(name: "MCP", package: "swift-sdk"),
                               .product(name: "Logging", package: "swift-log")]),

        .executableTarget(name: "FlashFindCLI", dependencies: ["FlashFindCore"],
                          path: "tools/DevTools/FlashFindCLI"),
        .executableTarget(name: "FlashFindSmoke", dependencies: ["FlashFindCore"],
                          path: "tools/DevTools/FlashFindSmoke"),
        // Phase 6.1 的**跨进程**冒烟入口：起一个真实的权威端监听，让另一个进程去连。
        // `swift test` 里的监听与用例同进程，证明不了权限位、第二个实例、stale 接管
        // 这些「跨进程才看得见」的事。不进产品（与上面两个 CLI 同类）。
        .executableTarget(name: "AuthoritySmoke", dependencies: ["FlashFindCore"],
                          path: "tools/DevTools/AuthoritySmoke"),
        // 注意：MyNAS 搜索核心不由 SwiftPM 资源机制分发。
        // `swift build` 对 executableTarget 的 resources 不会在 .build 产物里
        // 生成可用的资源 bundle，而 AppModel 需要的是一个真实可执行文件。
        // 因此核心随构建脚本安装到 app-state 旁的固定位置，见 tools/install-mynas-core.sh。
        .executableTarget(name: "FlashFind2App", dependencies: ["FlashFindCore"],
                          linkerSettings: [.linkedFramework("Carbon"), .linkedFramework("QuickLookUI")]),
        // Phase 5.5 起的**唯一** SDK 入口：`Sources/FlashFindMCP/main.swift` 只做装配
        // （建 `Server`、挂 `ListTools` / `CallTool` 两个 handler、跑 `StdioTransport`）。
        //
        // ★ 5.1 那个只用来证明「SDK 真被编译链接」的临时 target `MCPLink` 已删除。
        //   两个 SDK 入口长期并存，迟早变成第二个「同一事实写两遍」的地方：
        //   验证 linkage 的责任现在归这里——它引用的 `Server` / `StdioTransport`
        //   比 `LogLevel` 大得多，链接不上就根本起不来。
        .executableTarget(name: "FlashFindMCP",
                          dependencies: ["FlashFindCore", .product(name: "MCP", package: "swift-sdk")],
                          // 逐项 `-Xlinker`：SwiftPM 把 unsafeFlags 原样交给 clang driver，
                          // 不是每个参数都会被当成链接器参数转过去。
                          linkerSettings: [
                              .unsafeFlags(["-Xlinker", "-sectcreate",
                                            "-Xlinker", "__TEXT",
                                            "-Xlinker", "__info_plist",
                                            "-Xlinker", helperInfoPlist])
                          ]),
        // 测试目标也直接依赖 SDK：`MCPServerTests` 要用官方 `Client` 真的连一次
        // （initialize / tools/list / tools/call 走线），`MCPHandlerTests` 要构造
        // `CallTool.Parameters`。Core 本身不 re-export SDK，所以这里必须显式声明。
        .testTarget(name: "FlashFindCoreTests",
                    dependencies: ["FlashFindCore", "CSQLite",
                                   .product(name: "MCP", package: "swift-sdk"),
                                   .product(name: "Logging", package: "swift-log")])
    ]
)
