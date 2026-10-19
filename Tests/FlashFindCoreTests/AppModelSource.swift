import Foundation
import XCTest

/// 读 AppModel 的**整套源码**：主文件 + 所有 `AppModel+<分区>.swift`。
///
/// 为什么必须有这一个入口：AppModel 随 Stage 3A 拆成主文件加若干分区，而 App 层
/// 不可测——几十条断言是靠读源码来守的。只读主文件的话，搬到分区里的实现会
/// 凭空消失：轻则断言假绿（`range(of:)` 返回 nil 却被 `?? ""` 吃掉），重则
/// `region!` 当场崩溃——这两种在拆分时都真实发生过。
///
/// 读文件的 helper 若各写一份，**必须都走这里**：
/// 只修一个，其余照样假绿，而且不会报错告诉你。
///
/// `callerFilePath` 必须显式传调用点的 `#filePath`——写在枚举内部的话
/// 取到的是本文件的位置，root 会推导错。
enum AppModelSource {
    /// 去掉整行注释后的源码（多数断言用它：注释里提一句旧实现就会误报）。
    static func read(callerFilePath: String) throws -> String {
        stripComments(try joined(callerFilePath: callerFilePath))
    }

    /// 保留注释的原文（个别断言要看注释里写的理由）。
    static func readRaw(callerFilePath: String) throws -> String {
        try joined(callerFilePath: callerFilePath)
    }

    private static func joined(callerFilePath: String) throws -> String {
        let root = URL(fileURLWithPath: callerFilePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = root.appendingPathComponent("Sources/FlashFind2App")
        var parts = [try String(contentsOf: dir.appendingPathComponent("AppModel.swift"),
                                encoding: .utf8)]
        // 排序是固定的：不排的话目录枚举顺序随文件系统变，断言结果不可复现。
        let extras = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("AppModel+") && $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in extras { parts.append(try String(contentsOf: url, encoding: .utf8)) }
        return parts.joined(separator: "\n")
    }

    private static func stripComments(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}
