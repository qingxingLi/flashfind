import SwiftUI
import FlashFindCore

/// 「打开闪寻」的快捷键设置，压缩成**一行**。
///
/// ## 为什么不再是一整块说明区
///
/// 当前快捷键、说明、录制按钮、恢复默认、提示铺五六行，说的其实是同一件事。
/// 改成：**点这一行上的快捷键就直接进入录制**，恢复默认收进右键菜单。
struct ShortcutSettingRow: View {
    @ObservedObject var model: AppModel

    private var valueTitle: String {
        model.isRecordingShortcut ? "按下组合键…" : model.globalShortcut.displayName
    }

    var body: some View {
        SettingsLabeledRow("打开闪寻") {
            Button {
                if model.isRecordingShortcut { model.cancelShortcutRecording() }
                else { model.beginShortcutRecording() }
            } label: {
                Text(valueTitle)
                    .font(.system(.body, design: .rounded))
                    .monospacedDigit()
                    .frame(minWidth: 68)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .help("点这里录制新的快捷键")
            .accessibilityIdentifier("shortcut-record")
            .contextMenu {
                Button("恢复默认") { _ = model.resetGlobalShortcut() }
                    .disabled(model.isRecordingShortcut)
                    .accessibilityIdentifier("shortcut-reset")
            }
        }

        if model.isRecordingShortcut {
            Label("按下组合键，Esc 取消", systemImage: "keyboard")
                .ffFont(.settingsBody).foregroundStyle(.secondary)
        }
        if !model.shortcutStatus.isEmpty {
            Label(model.shortcutStatus, systemImage: model.shortcutAvailable ? "info.circle" : "exclamationmark.circle")
                .ffFont(.settingsBody).foregroundStyle(model.shortcutAvailable ? Color.secondary : Color.orange)
                .textSelection(.enabled)
                .accessibilityIdentifier("shortcut-status")
        }
    }
}
