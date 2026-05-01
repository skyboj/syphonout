import AppKit
import ApplicationServices
import ScreenCaptureKit
import os.log

/// Preferences window: crossfade, global hotkeys, permissions check.
final class PreferencesWindowController: NSWindowController {
    static let shared = PreferencesWindowController()

    private let prefs = PreferencesStore.shared
    private let logger = Logger(subsystem: "com.syphonout.SyphonOut", category: "Preferences")

    // Permission status indicators
    private var accessibilityDot  = NSTextField(labelWithString: "○")
    private var screenCaptureDot  = NSTextField(labelWithString: "○")

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 430),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "SyphonOut Preferences"
        window.center()
        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        refreshPermissionStatus()
    }

    // MARK: - UI

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        // ── General ─────────────────────────────────────────────────────────
        addSectionHeader("General", to: stack)

        let loginCheck = NSButton(checkboxWithTitle: "Launch at login", target: self,
                                  action: #selector(toggleLaunchAtLogin(_:)))
        loginCheck.state = prefs.launchAtLogin ? .on : .off
        stack.addArrangedSubview(loginCheck)

        let crossfadeRow = NSStackView()
        crossfadeRow.orientation = .horizontal
        crossfadeRow.spacing = 8
        crossfadeRow.addArrangedSubview(NSTextField(labelWithString: "Crossfade duration:"))
        let crossfadeField = NSTextField()
        crossfadeField.stringValue = String(format: "%.0f ms", prefs.crossfadeDuration * 1000)
        crossfadeField.isEditable = true
        crossfadeField.target = self
        crossfadeField.action = #selector(crossfadeChanged(_:))
        crossfadeField.widthAnchor.constraint(equalToConstant: 70).isActive = true
        crossfadeRow.addArrangedSubview(crossfadeField)
        stack.addArrangedSubview(crossfadeRow)

        stack.addArrangedSubview(NSBox.separator())

        // ── Global Hotkeys ───────────────────────────────────────────────────
        addSectionHeader("Global Hotkeys", to: stack)

        let hotkeys: [(String, String)] = [
            ("Blank all displays (emergency stop)",  "⌃⌥⌘K"),
            ("Restore all displays to signal",       "⌃⌥⌘S"),
        ]
        for (label, key) in hotkeys {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 8
            let lbl = NSTextField(labelWithString: label)
            lbl.textColor = .labelColor
            let kbd = NSTextField(labelWithString: key)
            kbd.textColor = .secondaryLabelColor
            kbd.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            row.addArrangedSubview(lbl)
            row.addArrangedSubview(NSView()) // spacer
            row.addArrangedSubview(kbd)
            stack.addArrangedSubview(row)
        }

        let hotkeyNote = NSTextField(wrappingLabelWithString:
            "Hotkeys require Accessibility permission. Grant it below, then relaunch.")
        hotkeyNote.textColor = .secondaryLabelColor
        hotkeyNote.font = NSFont.systemFont(ofSize: 11)
        stack.addArrangedSubview(hotkeyNote)

        stack.addArrangedSubview(NSBox.separator())

        // ── Permissions ──────────────────────────────────────────────────────
        addSectionHeader("Permissions", to: stack)

        stack.addArrangedSubview(permRow(
            label: "Accessibility (global hotkeys)",
            dot: accessibilityDot,
            buttonTitle: "Grant…",
            action: #selector(grantAccessibility(_:))
        ))
        stack.addArrangedSubview(permRow(
            label: "Screen Recording (window capture)",
            dot: screenCaptureDot,
            buttonTitle: "Grant…",
            action: #selector(grantScreenCapture(_:))
        ))

        let checkBtn = NSButton(title: "Check Permissions", target: self,
                                action: #selector(checkPermissions(_:)))
        stack.addArrangedSubview(checkBtn)
    }

    // MARK: - Permission helpers

    private func permRow(label: String, dot: NSTextField, buttonTitle: String, action: Selector) -> NSView {
        dot.font = NSFont.systemFont(ofSize: 16)
        dot.textColor = .secondaryLabelColor

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.addArrangedSubview(dot)
        row.addArrangedSubview(NSTextField(labelWithString: label))
        row.addArrangedSubview(NSView()) // spacer
        let btn = NSButton(title: buttonTitle, target: self, action: action)
        btn.bezelStyle = .inline
        row.addArrangedSubview(btn)
        return row
    }

    private func refreshPermissionStatus() {
        // Accessibility — check for THIS process explicitly (not just "any trusted app").
        let accessOK = AXIsProcessTrusted()
        accessibilityDot.stringValue = accessOK ? "●" : "○"
        accessibilityDot.textColor   = accessOK ? .systemGreen : .systemOrange

        // Screen Recording — use CGWindowListCopyWindowInfo as a proxy check.
        // If the list returns nil/empty without access, we're not authorised.
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
        let screenOK = list != nil && CFArrayGetCount(list) > 0
        screenCaptureDot.stringValue = screenOK ? "●" : "○"
        screenCaptureDot.textColor   = screenOK ? .systemGreen : .systemOrange
    }

    // MARK: - Actions

    @objc private func toggleLaunchAtLogin(_ sender: NSButton) {
        prefs.launchAtLogin = sender.state == .on
    }

    @objc private func crossfadeChanged(_ sender: NSTextField) {
        let digits = sender.stringValue.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        if let ms = Double(digits) {
            prefs.crossfadeDuration = ms / 1000.0
            syphonout_set_crossfade_duration_ms(ms)
        }
    }

    @objc private func checkPermissions(_ sender: Any) {
        refreshPermissionStatus()
    }

    @objc private func grantAccessibility(_ sender: Any) {
        // Prompt the system to show the Accessibility request dialog.
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
        // Open System Settings to the exact pane for quick navigation.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.refreshPermissionStatus() }
    }

    @objc private func grantScreenCapture(_ sender: Any) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.refreshPermissionStatus() }
    }

    // MARK: - Layout helpers

    private func addSectionHeader(_ title: String, to stack: NSStackView) {
        let lbl = NSTextField(labelWithString: title)
        lbl.font = NSFont.boldSystemFont(ofSize: 13)
        stack.addArrangedSubview(lbl)
    }
}

private extension NSBox {
    static func separator() -> NSBox {
        let sep = NSBox()
        sep.boxType = .separator
        return sep
    }
}
