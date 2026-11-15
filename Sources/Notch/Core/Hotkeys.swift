import Carbon.HIToolbox
import AppKit

/// Global hotkeys via Carbon RegisterEventHotKey (no Accessibility permission needed).
/// Each registration is tested: a combo owned by another app fails and is reported (rule 5).
@MainActor
final class Hotkeys {
    static let shared = Hotkeys()

    struct Binding { let name: String; let key: Int; let mods: Int; let action: () -> Void }

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private(set) var failed: [String] = []
    private(set) var registered: [String] = []
    private var installed = false

    func register(_ bindings: [Binding]) {
        installHandler()
        for (i, b) in bindings.enumerated() {
            let id = UInt32(i + 1)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(b.key), UInt32(b.mods),
                                             EventHotKeyID(signature: OSType(0x4E544348), id: id), // 'NTCH'
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref); handlers[id] = b.action; registered.append(b.name)
            } else {
                failed.append(b.name)
                NSLog("Notch: hotkey \(b.name) is taken by another app (\(status))")
            }
        }
    }

    private func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { MainActor.assumeIsolated { Hotkeys.shared.handlers[id]?() } }
            return noErr
        }, 1, &spec, nil, nil)
    }

    static let ctrlOpt = controlKey | optionKey
}
