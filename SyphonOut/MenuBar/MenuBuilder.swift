import AppKit

/// Builds the NSMenu content dynamically each time the menu opens.
///
/// New structure (physical outputs first):
///
///   [Display Name]  ● Live
///     Source: OBS: Program ▶
///     Mode: Signal ▶
///     Scale: Fill ▶
///   ──────────────────────
///   Virtual Displays…
///   PowerPoint Preset  ◻
///   Window Routing…
///   Show Log…   ⇧⌘L
///   ──────────────────────
///   Preferences…  ⌘,
///   Quit          ⌘Q
///
enum MenuBuilder {

    static func build(menu: NSMenu, outputs: [OutputWindowController], delegate: StatusBarController) {
        let vdManager = VirtualDisplayManager.shared
        let servers   = availableServers()

        // ── Physical Outputs (top-level — the main daily task) ─────────────
        for output in outputs {
            addPhysicalSection(to: menu, output: output, vdManager: vdManager,
                               servers: servers, delegate: delegate)
            menu.addItem(.separator())
        }

        // ── Utilities ──────────────────────────────────────────────────────
        let vdMgrItem = NSMenuItem(
            title: "Virtual Displays…",
            action: #selector(StatusBarController.openVirtualDisplays(_:)),
            keyEquivalent: ""
        )
        vdMgrItem.target = delegate
        menu.addItem(vdMgrItem)

        let pptItem = NSMenuItem(
            title: "PowerPoint Setup…",
            action: #selector(StatusBarController.openPowerPointSetup(_:)),
            keyEquivalent: ""
        )
        pptItem.target = delegate
        menu.addItem(pptItem)

        let routingItem = NSMenuItem(
            title: "Window Routing…",
            action: #selector(StatusBarController.openWindowRouting(_:)),
            keyEquivalent: ""
        )
        routingItem.target = delegate
        menu.addItem(routingItem)

        let logItem = NSMenuItem(
            title: "Show Log…",
            action: #selector(StatusBarController.showLogViewer(_:)),
            keyEquivalent: "l"
        )
        logItem.keyEquivalentModifierMask = [.command, .shift]
        logItem.target = delegate
        menu.addItem(logItem)

        menu.addItem(.separator())

        // ── App actions ────────────────────────────────────────────────────
        let prefsItem = NSMenuItem(
            title: "Preferences…",
            action: #selector(StatusBarController.openPreferences(_:)),
            keyEquivalent: ","
        )
        prefsItem.target = delegate
        menu.addItem(prefsItem)

        let quitItem = NSMenuItem(
            title: "Quit SyphonOut",
            action: #selector(StatusBarController.quitApp(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = delegate
        menu.addItem(quitItem)
    }

    // MARK: - Physical Output section

    private static func addPhysicalSection(
        to menu: NSMenu,
        output: OutputWindowController,
        vdManager: VirtualDisplayManager,
        servers: [(uuid: String, name: String, appName: String)],
        delegate: StatusBarController
    ) {
        let assignedVD = vdManager.assignedVD(for: output.displayId)

        // ── Header: "Built-in Retina Display  (Main)  ● Live" ────────────
        let statusDot: String
        if output.isMirrored {
            statusDot = "⌀ Mirrored"
        } else if let vd = assignedVD {
            if let src = vd.sourceUUID {
                statusDot = servers.contains(where: { $0.uuid == src }) ? "● Live" : "⚠ No Signal"
            } else {
                statusDot = "○ No Source"
            }
        } else {
            statusDot = "○ Unassigned"
        }
        let mainBadge = output.isMainDisplay ? "  (Main)" : ""
        let headerItem = NSMenuItem(
            title: "\(output.displayAlias)\(mainBadge)   \(statusDot)",
            action: nil,
            keyEquivalent: ""
        )
        headerItem.isEnabled = false
        menu.addItem(headerItem)

        // ── Thumbnail preview (below header) ─────────────────────────────
        let thumbItem = makeDisplayThumbnailItem(for: output)
        menu.addItem(thumbItem)

        // ── Source submenu ─────────────────────────────────────────────────
        if let vd = assignedVD {
            // Source is selected against the assigned VD
            let sourceMenu = NSMenu()
            let noneItem = NSMenuItem(
                title: "None",
                action: #selector(StatusBarController.setPhysicalSource(_:)),
                keyEquivalent: ""
            )
            noneItem.representedObject = ["displayId": output.displayId, "uuid": ""] as [String: Any]
            noneItem.target = delegate
            noneItem.state = (vd.sourceUUID == nil) ? .on : .off
            sourceMenu.addItem(noneItem)
            if !servers.isEmpty { sourceMenu.addItem(.separator()) }

            for server in servers {
                let displayName = server.appName.isEmpty || server.appName == server.name
                    ? server.name
                    : "\(server.appName): \(server.name)"
                let item = NSMenuItem(
                    title: displayName,
                    action: #selector(StatusBarController.setPhysicalSource(_:)),
                    keyEquivalent: ""
                )
                item.representedObject = ["displayId": output.displayId, "uuid": server.uuid] as [String: Any]
                item.target = delegate
                item.state = (vd.sourceUUID == server.uuid) ? .on : .off
                sourceMenu.addItem(item)
            }

            let currentSourceName: String = {
                guard let uuid = vd.sourceUUID else { return "None" }
                if let s = servers.first(where: { $0.uuid == uuid }) { return s.name }
                if uuid.hasPrefix("solink:") { return "SOLink (offline)" }
                return "Syphon (offline)"
            }()
            let sourceItem = NSMenuItem(title: "  Source: \(currentSourceName)", action: nil, keyEquivalent: "")
            sourceItem.submenu = sourceMenu
            menu.addItem(sourceItem)
        } else {
            // No VD assigned — offer to assign one (source = choose VD)
            let assignMenu = NSMenu()
            if vdManager.displays.isEmpty {
                let emptyItem = NSMenuItem(title: "No Virtual Displays", action: nil, keyEquivalent: "")
                emptyItem.isEnabled = false
                assignMenu.addItem(emptyItem)
            } else {
                for vd in vdManager.displays {
                    let item = NSMenuItem(
                        title: vd.name,
                        action: #selector(StatusBarController.assignPhysical(_:)),
                        keyEquivalent: ""
                    )
                    item.representedObject = ["displayId": output.displayId, "vdId": vd.id] as [String: Any]
                    item.target = delegate
                    assignMenu.addItem(item)
                }
            }
            let assignItem = NSMenuItem(title: "  Source: Assign Virtual Display…", action: nil, keyEquivalent: "")
            assignItem.submenu = assignMenu
            menu.addItem(assignItem)
        }

        // ── Mode submenu ───────────────────────────────────────────────────
        let modeMenu = NSMenu()
        let currentMode = assignedVD?.mode ?? output.currentMode
        for (title, mode) in [
            ("Signal",       SYPHON_OUT_MODE_SIGNAL),
            ("Freeze",       SYPHON_OUT_MODE_FREEZE),
            ("Blank Black",  SYPHON_OUT_MODE_BLANK_BLACK),
            ("Blank White",  SYPHON_OUT_MODE_BLANK_WHITE),
            ("Test Pattern", SYPHON_OUT_MODE_BLANK_TEST_PATTERN),
            ("Off",          SYPHON_OUT_MODE_OFF),
        ] {
            let item = NSMenuItem(
                title: title,
                action: #selector(StatusBarController.setPhysicalMode(_:)),
                keyEquivalent: ""
            )
            item.representedObject = ["displayId": output.displayId, "mode": mode.rawValue] as [String: Any]
            item.target = delegate
            item.state = (currentMode == mode) ? .on : .off
            modeMenu.addItem(item)
        }
        let modeLbl = modeName(currentMode)
        let modeItem = NSMenuItem(title: "  Mode: \(modeLbl)", action: nil, keyEquivalent: "")
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        // ── Scale submenu ──────────────────────────────────────────────────
        let scaleMenu = NSMenu()
        let currentScale = output.currentScaleMode
        for (label, scaleMode) in [
            ("Fill (stretch)",  SYPHON_OUT_SCALE_MODE_FILL),
            ("Fit (letterbox)", SYPHON_OUT_SCALE_MODE_FIT),
        ] {
            let item = NSMenuItem(
                title: label,
                action: #selector(StatusBarController.setScaleMode(_:)),
                keyEquivalent: ""
            )
            item.representedObject = ["displayId": output.displayId, "mode": scaleMode.rawValue] as [String: Any]
            item.target = delegate
            item.state = (currentScale == scaleMode) ? .on : .off
            scaleMenu.addItem(item)
        }
        let scaleLbl = (currentScale == SYPHON_OUT_SCALE_MODE_FILL) ? "Fill" : "Fit"
        let scaleItem = NSMenuItem(title: "  Scale: \(scaleLbl)", action: nil, keyEquivalent: "")
        scaleItem.submenu = scaleMenu
        menu.addItem(scaleItem)
    }

    // MARK: - Display thumbnail

    /// Creates a non-interactive NSMenuItem containing a small live preview
    /// of the given display (captured synchronously via CGDisplayCreateImage).
    private static func makeDisplayThumbnailItem(for output: OutputWindowController) -> NSMenuItem {
        let hPad: CGFloat = 14   // left/right margin inside the menu item
        let vPad: CGFloat = 6    // top/bottom margin
        let aspectRatio: CGFloat = 9.0 / 16.0

        // Use the display's actual pixel aspect ratio if available,
        // otherwise fall back to 16:9.
        let displayAspect: CGFloat = {
            let bounds = CGDisplayBounds(output.displayId)
            guard bounds.width > 0, bounds.height > 0 else { return aspectRatio }
            return bounds.height / bounds.width
        }()

        // The menu is typically ~270 pt wide; thumbnail fills the available width
        // minus horizontal padding.
        let menuWidth: CGFloat  = 270
        let thumbW: CGFloat     = menuWidth - hPad * 2
        let thumbH: CGFloat     = (thumbW * displayAspect).rounded()
        let totalH: CGFloat     = thumbH + vPad * 2

        // --- Outer container (stretches to menu width) ---
        let container = MenuItemView(frame: NSRect(x: 0, y: 0, width: menuWidth, height: totalH))

        // --- Image / placeholder view ---
        let imageView = NSImageView()
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 5
        imageView.layer?.masksToBounds = true
        imageView.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: hPad),
            imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -hPad),
            imageView.topAnchor.constraint(equalTo: container.topAnchor, constant: vPad),
            imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -vPad),
        ])

        if output.isMirrored {
            // Try to capture the slave display's own framebuffer first — macOS sometimes
            // maintains one even for mirrored slaves. Fall back to the master display if nil.
            // In a mirror set both framebuffers are identical, so either gives the real signal.
            let masterID = CGDisplayMirrorsDisplay(output.displayId)
            let captureImage: CGImage? = CGDisplayCreateImage(output.displayId)
                ?? (masterID != kCGNullDirectDisplay ? CGDisplayCreateImage(masterID) : nil)
            if let cgImage = captureImage {
                imageView.image = NSImage(cgImage: cgImage, size: .zero)
            }
            // "⌀ Mirrored" badge — small, bottom-right corner
            let badge = NSTextField(labelWithString: "⌀ Mirrored")
            badge.font = .systemFont(ofSize: 10, weight: .medium)
            badge.textColor = .white
            badge.backgroundColor = NSColor(white: 0, alpha: 0.55)
            badge.drawsBackground = true
            badge.isBezeled = false
            badge.alignment = .center
            badge.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(badge)
            NSLayoutConstraint.activate([
                badge.trailingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: -4),
                badge.bottomAnchor.constraint(equalTo: imageView.bottomAnchor, constant: -4),
            ])
        } else if let cgImage = CGDisplayCreateImage(output.displayId) {
            imageView.image = NSImage(cgImage: cgImage, size: .zero)
        }
        // else: display off or capture failed → shows the dark background only

        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.view = container
        item.isEnabled = false
        return item
    }

    // MARK: - MenuItemView

    /// A plain NSView subclass used as an NSMenuItem.view.
    /// Overrides intrinsicContentSize so Auto Layout gives it a stable height
    /// and the menu doesn't collapse the view to zero.
    private class MenuItemView: NSView {
        override var intrinsicContentSize: NSSize {
            return frame.size
        }
    }

    // MARK: - Helpers

    private static func modeName(_ mode: SyphonOutMode) -> String {
        switch mode {
        case SYPHON_OUT_MODE_SIGNAL:             return "Signal"
        case SYPHON_OUT_MODE_FREEZE:             return "Freeze"
        case SYPHON_OUT_MODE_BLANK_BLACK:        return "Blank Black"
        case SYPHON_OUT_MODE_BLANK_WHITE:        return "Blank White"
        case SYPHON_OUT_MODE_BLANK_TEST_PATTERN: return "Test Pattern"
        case SYPHON_OUT_MODE_OFF:                return "Off"
        default:                                  return "Mode(\(mode.rawValue))"
        }
    }

    static func availableServers() -> [(uuid: String, name: String, appName: String)] {
        var result: [(uuid: String, name: String, appName: String)] = []
        withUnsafeMutablePointer(to: &result) { ptr in
            syphonout_get_servers({ infoPtr, count, ctx in
                guard let infoPtr, let ctx else { return }
                let arr = ctx.assumingMemoryBound(
                    to: [(uuid: String, name: String, appName: String)].self)
                for i in 0..<Int(count) {
                    let info = infoPtr[i]
                    let uuid    = info.uuid     != nil ? String(cString: info.uuid)     : ""
                    let name    = info.name     != nil ? String(cString: info.name)     : ""
                    let appName = info.app_name != nil ? String(cString: info.app_name) : ""
                    arr.pointee.append((uuid: uuid, name: name, appName: appName))
                }
            }, ptr)
        }
        return result
    }
}
