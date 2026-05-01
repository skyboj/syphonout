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

    // MARK: - Scale mode per physical display

    func scaleMode(for displayID: CGDirectDisplayID) -> SyphonOutScaleMode {
        let dict = defaults.dictionary(forKey: "physicalScaleModes") as? [String: Int] ?? [:]
        let raw = dict[String(displayID)] ?? 0
        return SyphonOutScaleMode(rawValue: UInt32(raw))
    }

    func setScaleMode(_ mode: SyphonOutScaleMode, for displayID: CGDirectDisplayID) {
        var dict = defaults.dictionary(forKey: "physicalScaleModes") as? [String: Int] ?? [:]
        dict[String(displayID)] = Int(mode.rawValue)
        defaults.set(dict, forKey: "physicalScaleModes")
    }

    // MARK: - Keyboard shortcuts (stored as keyCode + modifier flags raw value)

    struct KeyCombo {
        let keyCode: UInt16
        let flags: NSEvent.ModifierFlags

        /// Human-readable string, e.g. "⌃⌥⌘K"
        var displayString: String {
            var s = ""
            if flags.contains(.control) { s += "⌃" }
            if flags.contains(.option)  { s += "⌥" }
            if flags.contains(.shift)   { s += "⇧" }
            if flags.contains(.command) { s += "⌘" }
            s += keyName
            return s
        }

        private var keyName: String {
            // Common key codes (US ANSI hardware layout)
            switch keyCode {
            case 0:  return "A"
            case 1:  return "S"
            case 2:  return "D"
            case 3:  return "F"
            case 4:  return "H"
            case 5:  return "G"
            case 6:  return "Z"
            case 7:  return "X"
            case 8:  return "C"
            case 9:  return "V"
            case 11: return "B"
            case 12: return "Q"
            case 13: return "W"
            case 14: return "E"
            case 15: return "R"
            case 16: return "Y"
            case 17: return "T"
            case 31: return "O"
            case 32: return "U"
            case 34: return "I"
            case 35: return "P"
            case 37: return "L"
            case 38: return "J"
            case 40: return "K"
            case 41: return ";"
            case 45: return "N"
            case 46: return "M"
            case 49: return "Space"
            default: return "(\(keyCode))"
            }
        }
    }

    // Key codes (hardware, layout-independent):
    //   F=3, U=32, K=40, S=1
    // Defaults:
    //   Freeze   ⌃⌥F  — freeze all displays
    //   Unfreeze ⌃⌥U  — unfreeze (back to signal)
    //   Blank    ⌃⌥⌘K — emergency blank (shown in Preferences)
    //   Restore  ⌃⌥⌘S — restore signal (shown in Preferences)
    var shortcutFreezeAll:   KeyCombo { loadCombo(key: "shortcutFreezeAll",   defaultKey: 3,  flags: [.control, .option]) }
    var shortcutUnfreezeAll: KeyCombo { loadCombo(key: "shortcutUnfreezeAll", defaultKey: 32, flags: [.control, .option]) }
    var shortcutBlankAll:    KeyCombo { loadCombo(key: "shortcutBlankAll",    defaultKey: 40, flags: [.control, .option, .command]) }
    var shortcutRestoreAll:  KeyCombo { loadCombo(key: "shortcutRestoreAll",  defaultKey: 1,  flags: [.control, .option, .command]) }

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
