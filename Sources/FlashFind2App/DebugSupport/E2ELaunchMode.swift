#if DEBUG

import Foundation
import FlashFindCore

/// 开发构建的「产品装配验证」启动模式（Phase 6.3b-4）。
///
/// 只认环境变量 `FF_E2E_LAUNCH=1`；发布构建里整个文件被编译掉，产品二进制
/// 不认识这些变量。
///
/// ## 它为什么存在
///
/// 跨进程 E2E 要启动**真的** `FlashFind2App`，但产品的启动路径有两件事在测试里
/// 不能按原样发生：
///
/// 1. **偏好读的是用户真实设置**（AI 访问默认关、本机范围是用户自己挑的）。
///    测试既不该改用户的设置，也不能依赖它——那样的用例在这台机器绿、
///    换台机器就红，而且红的原因与代码无关。
/// 2. **引导窗口 / 搜索浮窗 / 全局快捷键是给真实用户用的**，测试里只会抢焦点，
///    还可能和用户正开着的那份闪寻抢同一个快捷键。
///
/// socket 位置不在这里：`FF_AUTHORITY_SOCKET` 由 `MCPAuthorityController` 读，
/// 与助手端同名同义（助手在 `Sources/FlashFindMCP/main.swift` 里读同一个变量）。
///
/// ## 它**不**做什么
///
/// 不替换任何装配：仍然构造真的 `AppModel`（真 `LocalSearchProvider`、
/// 真 `SearchCoordinator`、真 `MCPAuthorityController`），本机搜索范围也仍由
/// `AppModel` 自己按偏好算出来。这里换掉的只有「偏好从哪儿来」与「要不要开窗」。
/// 一旦它开始替 App 配 provider 或替 App 决定授权，6.3b-4 要验的东西就消失了。
struct E2ELaunchMode {

    /// `nil` = 正常产品启动。
    static var current: E2ELaunchMode? {
        guard ProcessInfo.processInfo.environment["FF_E2E_LAUNCH"] == "1" else { return nil }
        return E2ELaunchMode(environment: ProcessInfo.processInfo.environment)
    }

    let preferences: InMemoryClientPreferences
    let cacheDirectory: URL?

    /// 测试启动一律无窗口：没有引导、没有搜索浮窗、不注册全局快捷键。
    /// 不设成可选项——「有窗口的 E2E」会按机器上当前的焦点状态时好时坏。
    let isHeadless = true

    private init(environment: [String: String]) {
        preferences = InMemoryClientPreferences(values: Self.decode(environment["FF_E2E_PREFERENCES"]))
        cacheDirectory = environment["FF_E2E_CACHE_DIR"].flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true)
        }
    }

    // MARK: - 偏好解码

    /// 把 `FF_E2E_PREFERENCES` 的 JSON 对象转成偏好字典。
    ///
    /// 解析失败**不**回落到真实偏好：那会让一次测试悄悄读写用户的设置。
    /// 这里退回空字典（= AI 关、零来源），用例会在第一条断言上明确失败。
    private static func decode(_ raw: String?) -> [String: Any] {
        guard let raw, let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if let raw, !raw.isEmpty {
                FileHandle.standardError.write(
                    Data("flashfind-app: FF_E2E_PREFERENCES is not a JSON object, using empty preferences\n".utf8))
            }
            return [:]
        }
        var values: [String: Any] = [:]
        for (key, value) in object {
            switch value {
            case let bool as Bool: values[key] = bool
            case let string as String: values[key] = string
            case let array as [Any]:
                values[key] = array.compactMap { $0 as? String }
            case let number as NSNumber: values[key] = number.intValue
            default: continue
            }
        }
        return values
    }
}

#endif
