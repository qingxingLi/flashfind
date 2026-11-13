import AppKit
import SwiftUI
import FlashFindCore

/// 长按 ⌘Q 退出：短按一律吞掉，按住才显示「长按关闭闪寻」进度环，圈走满才真的退出。
/// 文案由用户 2026-11-13 指定（原为「关闭中」，看不出要一直按住）。
///
/// 用户 2026-11-13 原话：「在加入一个长按 command+Q 才能退出闪寻的设定，
/// 长按时有一个转圈关闭中的动画，圈走到头关闭闪寻，防止误操作关闭软件。」
///
/// ★ 为什么用本地事件监视器：闪寻是 accessory（没有主菜单栏），但 ⌘Q 仍会由
/// AppKit 的 key equivalent 直接触发 `terminate:`。在事件分发前把 keyDown 吞掉
/// （返回 nil）是唯一能拦住它的位置；菜单里那颗「退出闪寻」按钮是用户明确点击，
/// 保持直接退出，不受长按约束。
@MainActor
final class QuitHoldController {
    @MainActor static let shared = QuitHoldController()

    private var monitor: Any?
    private var timer: Timer?
    private var startedAt: Date?
    private var panel: NSPanel?
    private let ringState = QuitHoldRingState()

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            // ★ 不让 `NSEvent` 充当 `assumeIsolated` 的返回值：它不是 Sendable，
            // Swift 6 会告警（未来是硬错误）。隔离域里只带出一个 Bool。
            let swallow = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                return self.handle(event: event) == nil
            }
            return swallow ? nil : event
        }
    }

    private func handle(event: NSEvent) -> NSEvent? {
        switch event.type {
        case .keyDown:
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let others = flags.intersection([.shift, .option, .control])
            let isQuit = QuitHoldPolicy.isQuitKeyDown(
                keyCode: event.keyCode,
                hasCommand: flags.contains(.command),
                hasOtherModifiers: !others.isEmpty,
                isRepeat: event.isARepeat)
            guard isQuit else { return event }
            // 长按会不断重发 keyDown（isARepeat = true）：不许重启计时，
            // 否则圈永远走不到头。
            if startedAt == nil { beginHold() }
            return nil
        case .keyUp:
            if event.keyCode == QuitHoldPolicy.quitKeyCode { cancelHold() }
            return event
        case .flagsChanged:
            if !event.modifierFlags.contains(.command) { cancelHold() }
            return event
        default:
            return event
        }
    }

    private func beginHold() {
        startedAt = Date()
        ringState.progress = 0
        showPanel()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: QuitHoldPolicy.tickInterval,
                                     repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard let startedAt else { return }
        // 松开 ⌘ 时 keyUp 可能落在别的响应者上；这里再兜一次硬件修饰键状态。
        if !NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) {
            cancelHold()
            return
        }
        let value = QuitHoldPolicy.progress(elapsed: Date().timeIntervalSince(startedAt))
        ringState.progress = value
        if QuitHoldPolicy.shouldTerminate(progress: value) { finishQuit() }
    }

    /// 只有 `QuitHoldPolicy.shouldTerminate(progress:)` 为真时才会走到这里。
    private func finishQuit() {
        timer?.invalidate()
        timer = nil
        hidePanel()
        NSApplication.shared.terminate(nil)
    }

    private func cancelHold() {
        timer?.invalidate()
        timer = nil
        startedAt = nil
        ringState.progress = 0
        hidePanel()
    }

    // MARK: - 进度环面板

    private func showPanel() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            var frame = panel.frame
            frame.origin = CGPoint(x: visible.midX - frame.width / 2,
                                   y: visible.midY - frame.height / 2)
            panel.setFrame(frame, display: false)
        }
        panel.orderFrontRegardless()
    }

    private func hidePanel() { panel?.orderOut(nil) }

    private func makePanel() -> NSPanel {
        let size = CGSize(width: 176, height: 132)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let hosting = NSHostingView(rootView: QuitHoldRing(state: ringState))
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting
        return panel
    }
}

@MainActor
final class QuitHoldRingState: ObservableObject {
    @Published var progress: Double = 0
}

/// 进度环：`trim(from: 0, to: progress)` 从 0 画到 1，圈走到头即退出。
/// 面板本身透明 + `clipShape`，避免「窗口是矩形、圆角是画出来的」在四角露出直角亮块。
private struct QuitHoldRing: View {
    @ObservedObject var state: QuitHoldRingState

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 4)
                    Circle()
                        .trim(from: 0, to: max(0.001, state.progress))
                        .stroke(Color(nsColor: .controlAccentColor),
                                style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 52, height: 52)
                Text("长按关闭闪寻")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(nsColor: .labelColor))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .frame(width: 176, height: 132)
    }
}
