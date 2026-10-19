import AppKit
import Carbon
import FlashFindCore

/// Registers the replacement first: a conflict never discards the working key.
@MainActor
final class GlobalHotKeyRegistrar {
    private var hotkey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var current: GlobalShortcutSpec?
    private static var sequence: UInt32 = 0
    private var activeID: UInt32?
    var onPress: (() -> Void)?
    func replace(with spec: GlobalShortcutSpec) -> String? {
        if let message = spec.validationMessage { return message }
        if current == spec, hotkey != nil { return nil }
        if handler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let context = Unmanaged.passUnretained(self).toOpaque()
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, data in
                guard let event, let data else { return OSStatus(eventNotHandledErr) }
                var identifier = EventHotKeyID()
                guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr else { return OSStatus(eventNotHandledErr) }
                let registrar = Unmanaged<GlobalHotKeyRegistrar>.fromOpaque(data).takeUnretainedValue()
                DispatchQueue.main.async {
                    guard identifier.signature == 0x46463232, identifier.id == registrar.activeID else { return }
                    registrar.onPress?()
                }
                return noErr
            }, 1, &type, context, &handler)
            guard status == noErr else { return "无法启用全局快捷键（\(status)）；仍可从菜单栏打开闪寻" }
        }
        Self.sequence &+= 1
        var replacement: EventHotKeyRef?
        let status = RegisterEventHotKey(spec.keyCode, spec.modifiers, EventHotKeyID(signature: 0x46463232, id: Self.sequence), GetApplicationEventTarget(), 0, &replacement)
        guard status == noErr, let replacement else { return "这个快捷键已被占用或系统拒绝注册（\(status)）；原快捷键保留，请选择其他组合" }
        if let hotkey { UnregisterEventHotKey(hotkey) }
        hotkey = replacement; current = spec; activeID = Self.sequence
        return nil
    }
    func stop() {
        if let hotkey { UnregisterEventHotKey(hotkey) }; hotkey = nil; current = nil; activeID = nil
        if let handler { RemoveEventHandler(handler) }; handler = nil
    }
}
