#if DEBUG

import AppKit

/// 合成按键事件、跑一遍键盘链路，验证原生事件投递在 UI 包里是真的通的。
///
/// 这是**开发期的证据采集设施**，不是产品功能：它会往包外写 Evidence JSON、
/// 会往面板里投递合成按键。正式包里不该有它，所以整个文件包在 `#if DEBUG`
/// 下——Release 构建（`swift build -c release`）连编译都不会编进去。
///
/// 注意别把 `AppEnvironment.isPreview` 那 40 多处守卫也照这个办法隔离：
/// 那些是**安全网**（防止误打 preview 标记的包被当生产用），Release 里恒为
/// false、编译器会消掉。为了「隔离」去给每一处补生产分支，等于把安全网拆薄，
/// 方向是反的。
@MainActor
enum PreviewInteractionValidation {
    static func run(panel: NSPanel, model: AppModel) {
        guard AppEnvironment.isPreview else { return }
        Task { @MainActor in
            let originalQuery = model.query
            var checks: [String: Bool] = [:]
            @MainActor func key(_ code: UInt16, modifiers: NSEvent.ModifierFlags = [], characters: String = "") {
                if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                               timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: panel.windowNumber, context: nil,
                                               characters: characters, charactersIgnoringModifiers: characters,
                                               isARepeat: false, keyCode: code) {
                    NSApplication.shared.postEvent(event, atStart: false)
                }
            }
            func settle() async { try? await Task.sleep(nanoseconds: 200_000_000) }
            key(125); await settle()
            checks["down_selects_second"] = model.selected == "preview-2"
            key(126); await settle()
            checks["up_selects_first"] = model.selected == "preview-1"
            let editor = panel.firstResponder as? NSTextView
            editor?.setSelectedRange(NSRange(location: 0, length: 0))
            key(0, modifiers: .command, characters: "a"); await settle()
            checks["command_a_uses_native_editor"] = editor?.selectedRange().length == originalQuery.utf16.count
            key(36); await settle()
            checks["return_reaches_isolated_open"] = model.status == "UI 预览 · 文件操作已隔离"
            key(53); await settle()
            checks["escape_hides_panel"] = !panel.isVisible
            NotificationCenter.default.post(name: .showFlashFind2, object: nil)
            await settle()
            checks["reopen_restores_query_selection"] = panel.isVisible && model.query == originalQuery && model.selected == "preview-1"
            model.query = ""; model.changedQuery()
            try? await Task.sleep(nanoseconds: 400_000_000)
            checks["clearing_collapses_to_search_row"] = abs(panel.frame.height - SearchLayout.searchHeight) < 1 && model.results.isEmpty
            let record: [String: Any] = ["scope": "isolated UI fixture events; not NAS functionality", "checks": checks]
            if let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]) {
                let url = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Evidence/keyboard-validation.json")
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}

#endif
