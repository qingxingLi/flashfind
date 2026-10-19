import AppKit
import SwiftUI
import FlashFindCore

/// 不带系统密码自动填充的密码框。
///
/// SwiftUI 的 `SecureField` 会自动接入 macOS 的「密码」自动填充：
/// 点进去就弹出 `Passwords…` 下拉，列出钥匙串里的条目。
/// 对闪寻来说这是**干扰**——密码由闪寻自己的钥匙串条目管理
/// （账号名固定为 `nas-source:<id>`），不需要系统自动填充来选；
/// 而且那个下拉会盖住界面，让人以为密码没填对。
///
/// 这里用 `NSSecureTextField` 直接构造。系统自动填充是 `SecureField`
/// 附带的，**换掉控件本身**就没有这一层——不是关某个开关能解决的。
struct PlainSecureField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    var accessibilityID: String?

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSSecureTextField {
        let field = NSSecureTextField()
        field.stringValue = context.coordinator.text.wrappedValue
        field.placeholderString = placeholder.isEmpty ? nil : placeholder
        field.lineBreakMode = .byTruncatingTail
        field.focusRingType = .default
        if let accessibilityID { field.identifier = NSUserInterfaceItemIdentifier(accessibilityID) }
        // 文本变化接两条通道：delegate 与通知。
        //
        // 不是"保险起见多写一遍"——是因为这条路径**曾经整条失效**（见 Coordinator 的说明），
        // 代价是用户填了密码却被告知"请输入密码"，按钮一直点不了。
        // 两条通道写的是同一个绑定、同一个值，重复写无害；任一条被未来某次改动弄断，
        // 输入也不会再丢。
        field.delegate = context.coordinator
        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(Coordinator.textChanged(_:)),
            name: NSControl.textDidChangeNotification, object: field)
        return field
    }

    func updateNSView(_ field: NSSecureTextField, context: Context) {
        // 【必须】每次都把最新的绑定交回 Coordinator。
        //
        // Coordinator 只创建一次，它最初捕获的 @Binding 在外层视图重建后
        // 会指向**旧的存储位置**。若不刷新，就会出现这个真实故障：
        //
        //   1. 用户敲第二个字符 → 文本框内容 "ab"
        //   2. 通知把 "ab" 写进旧位置，模型里的值仍是 "a"
        //   3. SwiftUI 调 updateNSView，发现 "ab" != "a"，把文本框回写成 "a"
        //
        // 于是每敲一个字符就被截回上一个长度——表现为「密码框只能打一个字」。
        context.coordinator.text = $text
        // 回写规则复用 FlashFindCore.SecureFieldEcho，与单元测试共用同一份判定。
        // NSTextField 没有 isEditing 属性，用「当前有 field editor」判断。
        if SecureFieldEcho.shouldWrite(fieldValue: field.stringValue,
                                        boundValue: text,
                                        isEditing: field.currentEditor() != nil) {
            field.stringValue = text
        }
    }

    static func dismantleNSView(_ field: NSSecureTextField, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        /// 绑定本身可变，由 updateNSView 持续刷新（见上）。
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        /// 通道一：`NSTextFieldDelegate`。参数是 `Notification`，不会写错类型。
        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        /// 通道二：`NSControl.textDidChangeNotification`。
        ///
        /// 【参数类型必须是 `Notification`，绝不能写成 `NSSecureTextField`。】
        ///
        /// 这不是风格问题，是一个真实发生过的故障：NotificationCenter 的回调约定是
        /// `func method(_ notification: Notification)`，而之前这里写成了
        /// `(_ sender: NSSecureTextField)`。编译能过、运行时也不做类型校验，
        /// 但传进来的**根本不是文本框，而是 `NSNotification`**；
        /// 紧接着一句 `sender.stringValue` 立刻抛：
        ///
        ///     -[NSConcreteNotification stringValue]: unrecognized selector sent to instance
        ///
        /// 最阴的是它**不表现成崩溃**：AppKit 的事件循环会吞掉这类异常继续运行，
        /// 于是「写回模型」这一步永远不执行，而文本框自己保留着用户的输入。
        /// 用户看到密码框里有一串圆点，程序却认为「你没输入密码」——
        /// 「连接」按钮一直是灰的，底下还提示「请输入密码」。
        ///
        @objc func textChanged(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}