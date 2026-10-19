import Foundation
import ServiceManagement

/// 「登录时启动闪寻」。
///
/// 闪寻是只挂状态栏的后台工具（`LSUIElement`），「开机自动起来」是它最该有的
/// 一项设置——不然每次开机用户都得自己去 /Applications 点一次，状态栏图标才出现。
///
/// 用 `SMAppService.mainApp`（macOS 13+）而不是旧 `SMLoginItemSetEnabled`：
/// 后者需要额外塞一个 helper bundle，而这里要的就是「把主 App 注册成登录项」。
///
/// ⚠️ 诚实边界：注册是否成功由系统决定（未公证 / ad-hoc 签名 / App 不在
/// /Applications 时系统可能直接拒绝）。所以这里的 `set` 会**把系统给的原因
/// 原样返回**，由界面如实显示，绝不假装成功。
enum LaunchAtLogin {
    /// 当前是否已注册为登录项。
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// 打开 / 关闭登录时启动。
    /// - Returns: 成功返回 `nil`；失败返回系统给的原因。
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                // 已经开着就不要重复注册（重复 register 会抛错，但那不算故障）。
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
