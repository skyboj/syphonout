import AppKit
import ServiceManagement

/// Persistent preferences backed by UserDefaults.
final class PreferencesStore {
    static let shared = PreferencesStore()
    private let defaults = UserDefaults.standard

    private init() {}

    // MARK: - Launch at login

    var launchAtLogin: Bool {
        get { defaults.bool(forKey: "launchAtLogin") }
        set {
            defaults.set(newValue, forKey: "launchAtLogin")
            if #available(macOS 13, *) {
                if newValue {
                    try? SMAppService.mainApp.register()
                } else {
                    try? SMAppService.mainApp.unregister()
                }
            }
        }
    }

    // MARK: - Primary display

    var primaryDisplayID: CGDirectDisplayID {
        get { CGDirectDisplayID(defaults.integer(forKey: "primaryDisplayID")) }
        set { defaults.set(Int(newValue), forKey: "primaryDisplayID") }
    }

    // MARK: - Crossfade duration (seconds)

    var crossfadeDuration: Double {
        get { defaults.object(forKey: "crossfadeDuration") as? Double ?? 0.1 }
        set { defaults.set(max(0.05, min(0.5, newValue)), forKey: "crossfadeDuration") }
    }

    // MARK: - Display aliases

    func displayAlias(for displayID: CGDirectDisplayID) -> String? {
        let dict = defaults.dictionary(forKey: "displayAliases") as? [String: String] ?? [:]
        return dict[String(displayID)]
    }

    func setDisplayAlias(_ alias: String, for displayID: CGDirectDisplayID) {
        var dict = defaults.dictionary(forKey: "displayAliases") as? [String: String] ?? [:]
        dict[String(displayID)] = alias.isEmpty ? nil : alias
        defaults.set(dict, forKey: "displayAliases")
    }

    // MARK: - Keyboard shortcuts (stored as keyCode + modifier flags raw value)

    struct KeyCombo {
        let keyCode: UInt16
        let flags: NSEvent.ModifierFlags
    }

    // Defaults: ⌃⌥F, ⌃⌥U, ⌃⌥B, ⌃⌥S
    // Key codes: F=3, U=32, B=11, S=1
    var shortcutFreezeAll:   KeyCombo { loadCombo(key: "shortcutFreezeAll",   defaultKey: 3,  flags: [.control, .option]) }
    var shortcutUnfreezeAll: KeyCombo { loadCombo(key: "shortcutUnfreezeAll", defaultKey: 32, flags: [.control, .option]) }
    var shortcutBlankAll:    KeyCombo { loadCombo(key: "shortcutBlankAll",    defaultKey: 11, flags: [.control, .option]) }
    var shortcutRestoreAll:  KeyCombo { loadCombo(key: "shortcutRestoreAll",  defaultKey: 1,  flags: [.control, .option]) }

    private func loadCombo(key: String, defaultKey: UInt16, flags: NSEvent.ModifierFlags) -> KeyCombo {
        guard let dict = defaults.dictionary(forKey: key),
              let kc = dict["keyCode"] as? Int,
              let rawFlags = dict["flags"] as? UInt
        else {
            return KeyCombo(keyCode: defaultKey, flags: flags)
        }
        return KeyCombo(keyCode: UInt16(kc), flags: NSEvent.ModifierFlags(rawValue: rawFlags))
    }

    func saveCombo(_ combo: KeyCombo, key: String) {
        defaults.set(["keyCode": Int(combo.keyCode), "flags": combo.flags.rawValue], forKey: key)
    }
}
