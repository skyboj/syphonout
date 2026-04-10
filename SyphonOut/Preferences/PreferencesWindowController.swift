import AppKit

/// Simple preferences window.
final class PreferencesWindowController: NSWindowController {
    static let shared = PreferencesWindowController()

    private let prefs = PreferencesStore.shared

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
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

    // MARK: - UI

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        // Launch at login
        let loginCheck = NSButton(checkboxWithTitle: "Launch at login", target: self, action: #selector(toggleLaunchAtLogin(_:)))
        loginCheck.state = prefs.launchAtLogin ? .on : .off
        stack.addArrangedSubview(loginCheck)

        // Crossfade duration
        let crossfadeRow = NSStackView()
        crossfadeRow.orientation = .horizontal
        crossfadeRow.spacing = 8
        let crossfadeLabel = NSTextField(labelWithString: "Crossfade duration:")
        let crossfadeField = NSTextField()
        crossfadeField.stringValue = String(format: "%.0f ms", prefs.crossfadeDuration * 1000)
        crossfadeField.isEditable = true
        crossfadeField.target = self
        crossfadeField.action = #selector(crossfadeChanged(_:))
        crossfadeRow.addArrangedSubview(crossfadeLabel)
        crossfadeRow.addArrangedSubview(crossfadeField)
        stack.addArrangedSubview(crossfadeRow)

        // Shortcuts info
        let shortcutsLabel = NSTextField(labelWithString: "Global shortcuts:")
        stack.addArrangedSubview(shortcutsLabel)

        let shortcuts = [
            ("Freeze all outputs", "⌃⌥F"),
            ("Unfreeze all outputs", "⌃⌥U"),
            ("Blank all (black)", "⌃⌥B"),
            ("Restore to signal", "⌃⌥S"),
        ]
        for (title, key) in shortcuts {
            let row = NSTextField(labelWithString: "    \(title): \(key)")
            row.textColor = .secondaryLabelColor
            stack.addArrangedSubview(row)
        }
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSButton) {
        prefs.launchAtLogin = sender.state == .on
    }

    @objc private func crossfadeChanged(_ sender: NSTextField) {
        if let ms = Double(sender.stringValue.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) {
            prefs.crossfadeDuration = ms / 1000.0
        }
    }
}
