import AppKit

/// Real-time log viewer window. Subscribes to `AppLog.shared` events.
///
/// Layout:
///   ┌──────────────────────────────────────────────────────────────┐
///   │ [Filter category…]  [Auto-scroll ✓]  [Pause]                  │
///   ├──────────────────────────────────────────────────────────────┤
///   │  [scrollable monospaced text area]                            │
///   ├──────────────────────────────────────────────────────────────┤
///   │  [Copy All]  [Save to File…]  [Clear]                         │
///   └──────────────────────────────────────────────────────────────┘
final class LogViewerWindowController: NSWindowController, NSWindowDelegate {

    static let shared = LogViewerWindowController()

    // MARK: - Subviews

    private var filterField:    NSTextField!
    private var autoScrollBox:  NSButton!
    private var pauseBox:       NSButton!
    private var scrollView:     NSScrollView!
    private var textView:       NSTextView!
    private var copyButton:     NSButton!
    private var saveButton:     NSButton!
    private var clearButton:    NSButton!
    private var entryCountLabel: NSTextField!

    // MARK: - State

    private var observer: NSObjectProtocol?
    private var paused = false

    // MARK: - Init

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 540),
            styleMask:   [.titled, .closable, .resizable, .miniaturizable],
            backing:     .buffered,
            defer:       false
        )
        window.title   = "SyphonOut Log"
        window.minSize = NSSize(width: 600, height: 360)
        window.center()
        super.init(window: window)
        window.delegate = self
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Show

    func showLog() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - UI

    private func buildUI() {
        guard let content = window?.contentView else { return }

        // ── Top toolbar ───────────────────────────────────────────────────────
        let toolbar = NSView()
        content.addSubview(toolbar)

        filterField = NSTextField()
        filterField.placeholderString = "Filter category (e.g. PPTPreset)…"
        filterField.bezelStyle = .roundedBezel
        filterField.controlSize = .small
        filterField.target = self
        filterField.action = #selector(filterChanged)
        toolbar.addSubview(filterField)

        autoScrollBox = NSButton(checkboxWithTitle: "Auto-scroll", target: self, action: nil)
        autoScrollBox.state = .on
        toolbar.addSubview(autoScrollBox)

        pauseBox = NSButton(checkboxWithTitle: "Pause", target: self, action: #selector(togglePause))
        pauseBox.state = .off
        toolbar.addSubview(pauseBox)

        entryCountLabel = NSTextField(labelWithString: "0 entries")
        entryCountLabel.textColor = .secondaryLabelColor
        entryCountLabel.font = NSFont.systemFont(ofSize: 11)
        toolbar.addSubview(entryCountLabel)

        // ── Text view ─────────────────────────────────────────────────────────
        scrollView = NSScrollView()
        scrollView.hasVerticalScroller   = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers    = false
        scrollView.borderType            = .bezelBorder
        content.addSubview(scrollView)

        textView = NSTextView()
        textView.isEditable          = false
        textView.isSelectable        = true
        textView.isRichText          = false
        textView.font                = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textColor           = .labelColor
        textView.backgroundColor     = NSColor.textBackgroundColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled  = false
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable   = true
        textView.autoresizingMask        = [.width]
        textView.textContainer?.widthTracksTextView   = false
        textView.textContainer?.containerSize         = NSSize(
            width:  CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        scrollView.documentView = textView

        // ── Bottom bar ────────────────────────────────────────────────────────
        let bottomBar = NSView()
        content.addSubview(bottomBar)

        copyButton = NSButton(title: "Copy All", target: self, action: #selector(copyAll))
        copyButton.bezelStyle  = .rounded
        copyButton.controlSize = .regular
        bottomBar.addSubview(copyButton)

        saveButton = NSButton(title: "Save to File…", target: self, action: #selector(saveToFile))
        saveButton.bezelStyle  = .rounded
        saveButton.controlSize = .regular
        bottomBar.addSubview(saveButton)

        clearButton = NSButton(title: "Clear", target: self, action: #selector(clearLog))
        clearButton.bezelStyle  = .rounded
        clearButton.controlSize = .regular
        bottomBar.addSubview(clearButton)

        // ── Layout ────────────────────────────────────────────────────────────
        [toolbar, scrollView, bottomBar,
         filterField, autoScrollBox, pauseBox, entryCountLabel,
         copyButton, saveButton, clearButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: content.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 40),

            filterField.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 12),
            filterField.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            filterField.widthAnchor.constraint(equalToConstant: 240),

            autoScrollBox.leadingAnchor.constraint(equalTo: filterField.trailingAnchor, constant: 16),
            autoScrollBox.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            pauseBox.leadingAnchor.constraint(equalTo: autoScrollBox.trailingAnchor, constant: 12),
            pauseBox.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            entryCountLabel.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -12),
            entryCountLabel.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor, constant: -4),

            bottomBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 44),

            copyButton.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 12),
            copyButton.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),

            saveButton.leadingAnchor.constraint(equalTo: copyButton.trailingAnchor, constant: 8),
            saveButton.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),

            clearButton.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -12),
            clearButton.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
        ])
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        // Render existing entries on open.
        renderAll()
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: .appLogAppended, object: nil, queue: .main
            ) { [weak self] note in
                guard let self, !self.paused else { return }
                guard let entry = note.userInfo?["entry"] as? AppLog.Entry else { return }
                self.append(entry)
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        if let obs = observer {
            NotificationCenter.default.removeObserver(obs)
            observer = nil
        }
    }

    // MARK: - Rendering

    private var filterText: String {
        filterField.stringValue.trimmingCharacters(in: .whitespaces)
    }

    private func passesFilter(_ entry: AppLog.Entry) -> Bool {
        let f = filterText
        return f.isEmpty || entry.category.localizedCaseInsensitiveContains(f)
    }

    private func renderAll() {
        let snapshot = AppLog.shared.entries
        let lines    = snapshot.filter(passesFilter).map { $0.formatted }
        textView.string = lines.joined(separator: "\n")
        if !lines.isEmpty { textView.string += "\n" }
        updateEntryCount(total: snapshot.count, shown: lines.count)
        scrollToBottomIfNeeded()
    }

    private func append(_ entry: AppLog.Entry) {
        guard passesFilter(entry) else {
            updateEntryCount()
            return
        }
        let line = entry.formatted + "\n"
        textView.textStorage?.append(NSAttributedString(
            string: line,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: color(for: entry.level),
            ]
        ))
        updateEntryCount()
        scrollToBottomIfNeeded()
    }

    private func color(for level: AppLog.Level) -> NSColor {
        switch level {
        case .debug: return .tertiaryLabelColor
        case .info:  return .labelColor
        case .warn:  return .systemOrange
        case .error: return .systemRed
        }
    }

    private func updateEntryCount(total: Int? = nil, shown: Int? = nil) {
        let t = total ?? AppLog.shared.entries.count
        if let shown {
            entryCountLabel.stringValue = "\(shown) / \(t) entries"
        } else {
            entryCountLabel.stringValue = "\(t) entries"
        }
    }

    private func scrollToBottomIfNeeded() {
        guard autoScrollBox.state == .on else { return }
        textView.scrollToEndOfDocument(nil)
    }

    // MARK: - Actions

    @objc private func filterChanged() {
        renderAll()
    }

    @objc private func togglePause() {
        paused = pauseBox.state == .on
    }

    @objc private func copyAll() {
        let text = textView.string
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        AppLog.shared.info("Log copied to clipboard (\(text.count) chars)", category: "LogViewer")
    }

    @objc private func saveToFile() {
        let panel = NSSavePanel()
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "syphonout-log-\(stamp).txt"
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                try self.textView.string.write(to: url, atomically: true, encoding: .utf8)
                AppLog.shared.info("Log saved to \(url.path)", category: "LogViewer")
            } catch {
                AppLog.shared.error("Save failed: \(error.localizedDescription)", category: "LogViewer")
            }
        }
    }

    @objc private func clearLog() {
        AppLog.shared.clear()
        textView.string = ""
        updateEntryCount(total: 0, shown: 0)
    }
}
