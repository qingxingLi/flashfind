// swift-tools-version: 5.9
import PackageDescription

// MyNAS 搜索核心（Dart AOT 可执行 + 原生 HTTPS 助手）随 App 一起分发。
// AppModel 通过 Bundle.main.resourceURL/…/MyNAS/bin/mynas-core 定位它，
// 由 MyNASProcessBridge 以空参数启动，凭据只经stdin 管道传入。
//
// 对外产品只有 Core 库与 App；CLI / smoke 是开发期工具，源码在 tools/DevTools/，
// 不列进 products，但仍可 `swift run FlashFindCLI` / `swift build --target FlashFindSmoke` 构建。
let package = Package(
    name: "FlashFind2",
    platforms: [.macOS(.v13)],
    products: [.library(name: "FlashFindCore", targets: ["FlashFindCore"]),
               .executable(name: "FlashFind2App", targets: ["FlashFind2App"])],
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
        .target(name: "FlashFindCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "FlashFindCLI", dependencies: ["FlashFindCore"],
                          path: "tools/DevTools/FlashFindCLI"),
        .executableTarget(name: "FlashFindSmoke", dependencies: ["FlashFindCore"],
                          path: "tools/DevTools/FlashFindSmoke"),
        // 注意：MyNAS 搜索核心不由 SwiftPM 资源机制分发。
        // `swift build` 对 executableTarget 的 resources 不会在 .build 产物里
        // 生成可用的资源 bundle，而 AppModel 需要的是一个真实可执行文件。
        // 因此核心随构建脚本安装到 app-state 旁的固定位置，见 tools/install-mynas-core.sh。
        .executableTarget(name: "FlashFind2App", dependencies: ["FlashFindCore"],
                          linkerSettings: [.linkedFramework("Carbon"), .linkedFramework("QuickLookUI")]),
        .testTarget(name: "FlashFindCoreTests", dependencies: ["FlashFindCore", "CSQLite"])
    ]
)
