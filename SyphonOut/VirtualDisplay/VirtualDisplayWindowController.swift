import AppKit

/// Simple Virtual Display management panel.
///
/// Shows a list of all Virtual Displays with their name, mode, source, and
/// resolution. Allows creating new VDs, deleting existing ones, and
/// renaming them inline. Advanced source/mode wiring is done here instead
/// of in the main menu (which shows only physical output controls).
final class VirtualDisplayWindowController: NSWindowController, NSWindowDelegate {

    static let shared = VirtualDisplayWindowController()

    // MARK: - UI

    private var tableView:    NSTableView!
    private var scrollView:   NSScrollView!
    private var addButton:    NSButton!
    private var deleteButton: NSButton!

    private var vdObserver: NSObjectProtocol?

    // MARK: - Init

    private init() {
        let win = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 360),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Virtual Displays"
        win.center()
        win.minSize = NSSize(width: 480, height: 200)
        super.init(window: win)
        win.delegate = self
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Show

    func show() {
        window?.makeKeyAndOrderFront(nil)
        tableView.reloadData()
        subscribeToChanges()
    }

    /// Called by StatusBarController when opening via menu.
    func subscribeIfNeeded() {
        tableView.reloadData()
        subscribeToChanges()
    }

    // MARK: - UI Construction

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        // Table
        tableView = NSTableView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowSizeStyle = .default
        tableView.delegate   = self
        tableView.dataSource = self
        tableView.doubleAction = #selector(renameVD)
        tableView.target = self

        let cols: [(id: String, title: String, width: CGFloat)] = [
            ("name",       "Name",       160),
            ("mode",       "Mode",       110),
            ("source",     "Source",     160),
            ("assignedTo", "Assigned to", 140),
            ("size",       "Resolution",  95),
        ]
        for col in cols {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(col.id))
            c.title = col.title
            c.width = col.width
            c.resizingMask = .userResizingMask
            tableView.addTableColumn(c)
        }

        scrollView = NSScrollView()
        scrollView.documentView   = tableView
        scrollView.hasVerticalScroller   = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers    = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(scrollView)

        // Bottom toolbar
        addButton = NSButton(title: "+ New", target: self, action: #selector(addVD))
        addButton.bezelStyle = .rounded
        addButton.translatesAutoresizingMaskIntoConstraints = false

        deleteButton = NSButton(title: "Delete", target: self, action: #selector(deleteVD))
        deleteButton.bezelStyle = .rounded
        deleteButton.isEnabled  = false
        deleteButton.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(labelWithString: "Double-click a name to rename.")
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(addButton)
        contentView.addSubview(deleteButton)
        contentView.addSubview(hint)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -10),

            addButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            addButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),

            deleteButton.leadingAnchor.constraint(equalTo: addButton.trailingAnchor, constant: 8),
            deleteButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),

            hint.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            hint.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
        ])
    }

    // MARK: - Change observation

    private func subscribeToChanges() {
        guard vdObserver == nil else { return }
        vdObserver = NotificationCenter.default.addObserver(
            forName: .vdListChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.tableView.reloadData()
        }
    }

    func windowWillClose(_ notification: Notification) {
        if let obs = vdObserver { NotificationCenter.default.removeObserver(obs); vdObserver = nil }
    }

    // MARK: - Actions

    @objc private func addVD() {
        let vd = VirtualDisplayManager.shared.createDisplay()
        tableView.reloadData()
        // Select and start editing the new row
        let row = VirtualDisplayManager.shared.userDisplays.firstIndex(where: { $0.id == vd.id }) ?? 0
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    @objc private func deleteVD() {
        let row = tableView.selectedRow
        let vds = VirtualDisplayManager.shared.userDisplays
        guard row >= 0, row < vds.count else { return }
        let vd = vds[row]
        VirtualDisplayManager.shared.destroyDisplay(id: vd.id)
        tableView.reloadData()
    }

    @objc private func renameVD() {
        let row = tableView.selectedRow
        guard row >= 0 else { return }
        let col = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
        guard col >= 0 else { return }
        tableView.editColumn(col, row: row, with: nil, select: true)
    }

    // MARK: - Assigned to support

    private func allPhysicalDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        guard count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    @objc private func assignedToChanged(_ sender: NSPopUpButton) {
        let row = sender.tag
        let vds = VirtualDisplayManager.shared.userDisplays
        guard row >= 0, row < vds.count else { return }
        let vd = vds[row]

        if let selectedItem = sender.selectedItem,
           let displayId = selectedItem.representedObject as? CGDirectDisplayID {
            VirtualDisplayManager.shared.assignPhysical(displayId: displayId, vdUUID: vd.id)
        } else {
            let currentAssignment = VirtualDisplayManager.shared.assignments.first { $0.value == vd.id }
            if let (displayId, _) = currentAssignment {
                VirtualDisplayManager.shared.unassignPhysical(displayId: displayId)
            }
        }
        tableView.reloadData()
    }
}

// MARK: - NSTableViewDataSource

extension VirtualDisplayWindowController: NSTableViewDataSource {

    func numberOfRows(in tableView: NSTableView) -> Int {
        VirtualDisplayManager.shared.userDisplays.count
    }
}

// MARK: - NSTableViewDelegate

extension VirtualDisplayWindowController: NSTableViewDelegate {

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let vds = VirtualDisplayManager.shared.userDisplays
        guard row < vds.count else { return nil }
        let vd = vds[row]

        let colId = tableColumn?.identifier.rawValue ?? ""

        if colId == "assignedTo" {
            return makeAssignedToCell(tableView: tableView, row: row, vd: vd)
        }

        let text: String
        switch colId {
        case "name":   text = vd.name
        case "mode":   text = vd.modeDescription
        case "source": text = sourceLabel(for: vd)
        case "size":   text = "\(vd.width)×\(vd.height)"
        default:       text = ""
        }

        let id = NSUserInterfaceItemIdentifier(colId)
        var cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTextField
        if cell == nil {
            cell = NSTextField()
            cell?.identifier = id
            cell?.isBordered = false
            cell?.drawsBackground = false
            cell?.font = .systemFont(ofSize: NSFont.systemFontSize)
        }
        cell?.stringValue = text

        // Only the Name column is editable (on double-click)
        if colId == "name" {
            cell?.isEditable = true
            cell?.delegate   = self
            cell?.tag        = row   // stash row for delegate callback
        } else {
            cell?.isEditable = false
        }
        return cell
    }

    private func makeAssignedToCell(tableView: NSTableView, row: Int, vd: VirtualDisplay) -> NSView? {
        let cellId = NSUserInterfaceItemIdentifier("assignedToCell")
        var cell = tableView.makeView(withIdentifier: cellId, owner: self) as? NSTableCellView
        if cell == nil {
            cell = NSTableCellView()
            cell?.identifier = cellId

            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.bezelStyle = .rounded
            popup.translatesAutoresizingMaskIntoConstraints = false
            popup.target = self
            popup.action = #selector(assignedToChanged(_:))
            cell?.addSubview(popup)
            if let cell {
                NSLayoutConstraint.activate([
                    popup.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    popup.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                    popup.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }
        }

        guard let popup = cell?.subviews.compactMap({ $0 as? NSPopUpButton }).first else { return cell }
        popup.tag = row

        let displays = allPhysicalDisplayIDs()
        let currentAssignment = VirtualDisplayManager.shared.assignments.first { $0.value == vd.id }

        popup.removeAllItems()
        popup.addItem(withTitle: "—")
        popup.lastItem?.representedObject = nil

        var selectedIndex: Int = 0
        for (i, displayId) in displays.enumerated() {
            let name = OutputWindowController.screenName(for: displayId)
            popup.addItem(withTitle: name)
            popup.lastItem?.representedObject = displayId as NSObject
            if displayId == currentAssignment?.key {
                selectedIndex = i + 1
            }
        }
        popup.selectItem(at: selectedIndex)

        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        deleteButton.isEnabled = tableView.selectedRow >= 0
    }

    private func sourceLabel(for vd: VirtualDisplay) -> String {
        guard let uuid = vd.sourceUUID else { return "None" }
        let servers = MenuBuilder.availableServers()
        if let s = servers.first(where: { $0.uuid == uuid }) { return s.name }
        if uuid.hasPrefix("solink:") { return "SOLink (offline)" }
        return "Syphon (offline)"
    }
}

// MARK: - NSTextFieldDelegate (inline rename)

extension VirtualDisplayWindowController: NSTextFieldDelegate {

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        let row = field.tag
        let vds = VirtualDisplayManager.shared.userDisplays
        guard row < vds.count else { return }
        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != vds[row].name else { return }
        VirtualDisplayManager.shared.renameDisplay(id: vds[row].id, name: newName)
    }
}
