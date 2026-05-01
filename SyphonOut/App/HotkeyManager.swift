/// Global hotkey manager — Carbon RegisterEventHotKey edition.
///
/// Uses the Carbon HIToolbox `RegisterEventHotKey` API which is delivered at the
/// kernel level and does NOT require Accessibility permission.  This is the same
/// mechanism used by Alfred, Moom, Quicksilver, and other professional apps.
///
/// Handles all four shortcuts:
///   ⌃⌥F  — freeze all virtual displays
///   ⌃⌥U  — unfreeze all (→ signal)
///   ⌃⌥⌘K — blank all (emergency stop)
///   ⌃⌥⌘S — restore all to signal
///
/// Shortcuts are read from PreferencesStore so they can be changed in the future.

import AppKit
import Carbon.HIToolbox
import os.log

final class HotkeyManager {
    static let shared = HotkeyManager()

    var onFreezeAll:   (() -> Void)?
    var onUnfreezeAll: (() -> Void)?
    var onBlankAll:    (() -> Void)?
    var onRestoreAll:  (() -> Void)?

    private var hotKeyRefs: [EventHotKeyRef] = []
    private var handlerRef: EventHandlerRef?
    private let logger = Logger(subsystem: "com.syphonout.SyphonOut", category: "Hotkeys")

    // Four-char signature "SYPH" packed as UInt32
    private static let sig: FourCharCode = (0x53 << 24) | (0x59 << 16) | (0x50 << 8) | 0x48

    private static let idFreeze:   UInt32 = 1
    private static let idUnfreeze: UInt32 = 2
    private static let idBlank:    UInt32 = 3
    private static let idRestore:  UInt32 = 4

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard handlerRef == nil else { return }
        installCarbonHandler()
        registerAll()
        logger.info("HotkeyManager started (Carbon) — \(self.hotKeyRefs.count) hotkeys registered")
    }

    func stop() {
        hotKeyRefs.forEach { UnregisterEventHotKey($0) }
        hotKeyRefs.removeAll()
        if let ref = handlerRef { RemoveEventHandler(ref); handlerRef = nil }
        logger.info("HotkeyManager stopped")
    }

    // MARK: - Carbon event handler

    private func installCarbonHandler() {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind:  UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // The closure passed as EventHandlerUPP must not capture outer context —
        // it only reads its own parameters plus `userData`.
        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                let mgr = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()

                var hkID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID
                )

                DispatchQueue.main.async {
                    switch hkID.id {
                    case HotkeyManager.idFreeze:   mgr.onFreezeAll?()
                    case HotkeyManager.idUnfreeze: mgr.onUnfreezeAll?()
                    case HotkeyManager.idBlank:    mgr.onBlankAll?()
                    case HotkeyManager.idRestore:  mgr.onRestoreAll?()
                    default: break
                    }
                }
                return noErr
            },
            1, &spec, selfPtr, &handlerRef
        )
    }

    // MARK: - Register hotkeys from PreferencesStore

    private func registerAll() {
        let prefs = PreferencesStore.shared
        register(prefs.shortcutFreezeAll,   id: HotkeyManager.idFreeze)
        register(prefs.shortcutUnfreezeAll, id: HotkeyManager.idUnfreeze)
        register(prefs.shortcutBlankAll,    id: HotkeyManager.idBlank)
        register(prefs.shortcutRestoreAll,  id: HotkeyManager.idRestore)
    }

    private func register(_ combo: PreferencesStore.KeyCombo, id: UInt32) {
        guard combo.keyCode != 0 else { return }
        var hkID = EventHotKeyID(signature: HotkeyManager.sig, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(combo.keyCode),
            carbonModifiers(from: combo.flags),
            hkID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr, let ref {
            hotKeyRefs.append(ref)
        } else {
            logger.warning("RegisterEventHotKey failed for id=\(id), status=\(status) — combo may be taken by another app")
        }
    }

    // MARK: - Modifier conversion

    /// Convert NSEvent.ModifierFlags → Carbon modifier bits.
    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey)     }
        if flags.contains(.option)  { mods |= UInt32(optionKey)  }
        if flags.contains(.shift)   { mods |= UInt32(shiftKey)   }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        return mods
    }
}
