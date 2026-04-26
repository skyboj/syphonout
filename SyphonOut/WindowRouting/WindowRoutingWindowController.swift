import AppKit
import ScreenCaptureKit

/// Entry-point controller for the Window Routing module.
/// Hosts the routing panel: a live window list (WindowInventory) displayed
/// in an NSTableView with app icon, app name, and window title columns.
///
/// Steps 3–4 will add WindowMover and OutputSlot integration here.
final class WindowRoutingWindowController: NSWindowController, NSWindowDelegate {

    static let shared = WindowRoutingWindowController()

    // MARK: - Subviews

    private var scrollView: NSScrollView!
    private var tableView: NSTableView!
    private var statusLabel: NSTextField!
    private var refreshButton: NSButton!

    // MARK: - Data

    private let inventory = WindowInventory()
    private var windows: [WindowInfo] = []

    // MARK: - Init

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 440),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Window Routing"
        window.minSize = NSSize(width: 480, height: 320)
        window.center()
        super.init(window: window)
        window.delegate = self
        buildUI()
        wireInventory()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Show

    /// Called from the menu bar. Checks permissions, then shows the window.
    func showRouting() {
        PermissionManager.shared.requirePermissions(in: nil) { [weak self] granted in
            guard granted else { return }
            self?.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - UI Construction

    private func buildUI() {
        guard let content = window?.contentView else { return }

        // ── Top toolbar area ──────────────────────────────────────────────────
        let toolbarHeight: CGFloat = 36
        let toolbarView = NSView()
        toolbarView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(toolbarView)

        let titleLabel = makeLabel("On-Screen Windows", size: 13, bold: true)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        toolbarView.addSubview(titleLabel)

        statusLabel = makeLabel("", size: 11, bold: false)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        toolbarView.addSubview(statusLabel)

        refreshButton = NSButton(title: "Refresh", target: self, action: #selector(manualRefresh))
        refreshButton.bezelStyle = .rounded
        refreshButton.controlSize = .small
        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        toolbarView.addSubview(refreshButton)

        // ── Table ─────────────────────────────────────────────────────────────
        tableView = NSTableView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.rowHeight = 20

        addColumn(id: "icon",    title: "",            width: 20,  minWidth: 20,  maxWidth: 20,  resizable: false)
        addColumn(id: "app",     title: "Application", width: 160, minWidth: 100, maxWidth: 260, resizable: true)
        addColumn(id: "window",  title: "Window",      width: 280, minWidth: 120, maxWidth: 500, resizable: true)
        addColumn(id: "display", title: "Display",     width: 100, minWidth: 80,  maxWidth: 160, resizable: true)

        tableView.dataSource = self
        tableView.delegate   = self

        scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .bezelBorder
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scrollView)

        // ── Bottom status bar ─────────────────────────────────────────────────
        let bottomBar = NSView()
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(bottomBar)

        let countLabel = makeLabel("", size: 11, bold: false)
        countLabel.textColor = .tertiaryLabelColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.tag = 42   // reuse via viewWithTag
        bottomBar.addSubview(countLabel)

        // ── Auto-layout ───────────────────────────────────────────────────────
        NSLayoutConstraint.activate([
            // Toolbar
            toolbarView.topAnchor.constraint(equalTo: content.topAnchor),
            toolbarView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            toolbarView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            toolbarView.heightAnchor.constraint(equalToConstant: toolbarHeight),

            titleLabel.leadingAnchor.constraint(equalTo: toolbarView.leadingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),

            statusLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 10),
            statusLabel.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),

            refreshButton.trailingAnchor.constraint(equalTo: toolbarView.trailingAnchor, constant: -12),
            refreshButton.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),

            // Table scroll view
            scrollView.topAnchor.constraint(equalTo: toolbarView.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),

            // Bottom bar
            bottomBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 24),

            countLabel.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 12),
            countLabel.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
        ])
    }

    // MARK: - Inventory wiring

    private func wireInventory() {
        inventory.onUpdate = { [weak self] updated in
            guard let self else { return }
            self.windows = updated
            self.tableView.reloadData()
            self.updateCountLabel()
            self.statusLabel.stringValue = "Updated \(shortTime())"
        }
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        inventory.start()
        // Force an immediate refresh so the table fills right away
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.inventory.onUpdate?(self?.inventory.windows ?? [])
        }
    }

    func windowWillClose(_ notification: Notification) {
        inventory.stop()
    }

    // MARK: - Actions

    @objc private func manualRefresh() {
        statusLabel.stringValue = "Refreshing…"
        inventory.stop()
        inventory.start()
    }

    // MARK: - Helpers

    private func addColumn(id: String, title: String, width: CGFloat,
                           minWidth: CGFloat, maxWidth: CGFloat, resizable: Bool) {
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        col.title = title
        col.width = width
        col.minWidth = minWidth
        col.maxWidth = maxWidth
        if resizable {
            col.resizingMask = [.autoresizingMask, .userResizingMask]
        } else {
            col.resizingMask = []
        }
        tableView.addTableColumn(col)
    }

    private func makeLabel(_ text: String, size: CGFloat, bold: Bool) -> NSTextField {
        let f = bold
            ? NSFont.boldSystemFont(ofSize: size)
            : NSFont.systemFont(ofSize: size)
        let label = NSTextField(labelWithString: text)
        label.font = f
        return label
    }

    private func updateCountLabel() {
        if let label = window?.contentView?.viewWithTag(42) as? NSTextField {
            let n = windows.count
            label.stringValue = n == 0 ? "No windows" : "\(n) window\(n == 1 ? "" : "s")"
        }
    }

    private func shortTime() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }

    /// Returns the display name for the screen that contains the given frame.
    private func displayName(for frame: CGRect) -> String {
        // NSScreen coordinate system is flipped vs Quartz — convert Y
        let screens = NSScreen.screens
        // Find the NSScreen whose frame contains the window's midpoint
        let mid = CGPoint(x: frame.midX, y: frame.midY)
        for screen in screens {
            // Convert Quartz → AppKit: flip Y relative to the primary screen height
            let primary = screens.first?.frame.height ?? 0
            let appKitRect = CGRect(
                x: screen.frame.origin.x,
                y: primary - screen.frame.origin.y - screen.frame.height,
                width: screen.frame.width,
                height: screen.frame.height
            )
            if appKitRect.contains(mid) {
                return screen.localizedName
            }
        }
        return "Unknown"
    }
}

// MARK: - NSTableViewDataSource

extension WindowRoutingWindowController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { windows.count }
}

// MARK: - NSTableViewDelegate

extension WindowRoutingWindowController: NSTableViewDelegate {

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < windows.count else { return nil }
        let info = windows[row]
        let colID = tableColumn?.identifier.rawValue ?? ""

        switch colID {
        case "icon":
            let cell = dequeueCell(tableView, id: "icon") as? NSImageView
                ?? NSImageView()
            cell.identifier = NSUserInterfaceItemIdentifier("icon")
            cell.image = info.appIcon
            cell.imageScaling = .scaleProportionallyUpOrDown
            return cell

        case "app":
            let cell = dequeueTextCell(tableView, id: "app")
            cell.stringValue = info.appName
            return cell

        case "window":
            let cell = dequeueTextCell(tableView, id: "window")
            cell.stringValue = info.displayTitle
            cell.textColor = info.title.isEmpty ? .tertiaryLabelColor : .labelColor
            return cell

        case "display":
            let cell = dequeueTextCell(tableView, id: "display")
            cell.stringValue = displayName(for: info.frame)
            cell.textColor = .secondaryLabelColor
            return cell

        default:
            return nil
        }
    }

    private func dequeueCell(_ tv: NSTableView, id: String) -> NSView? {
        tv.makeView(withIdentifier: NSUserInterfaceItemIdentifier(id), owner: nil)
    }

    private func dequeueTextCell(_ tv: NSTableView, id: String) -> NSTextField {
        if let existing = tv.makeView(withIdentifier: NSUserInterfaceItemIdentifier(id), owner: nil) as? NSTextField {
            existing.textColor = .labelColor
            return existing
        }
        let label = NSTextField(labelWithString: "")
        label.identifier = NSUserInterfaceItemIdentifier(id)
        label.font = NSFont.systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        return label
    }
}
