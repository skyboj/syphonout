import AppKit
import ApplicationServices

/// PowerPoint Presentation Setup panel.
///
/// Shows a live snapshot of every physically-connected display (including
/// OS-mirrored ones) so the user can assign roles, hit Apply, and have the
/// Slide Show window automatically moved to the right screen.
///
/// Apply order:
///   1. Apply/remove OS mirrors.
///   2. Wait 500 ms for macOS to settle and relocate any windows that were
///      on the now-slave display.
///   3. Look for the PPT Slide Show window.  If found → move immediately.
///      If not found → start a WindowInventory watcher that fires when
///      the window eventually appears.

final class PowerPointSetupWindowController: NSWindowController, NSWindowDelegate {

    static let shared = PowerPointSetupWindowController()

    // MARK: - State

    enum Role: Int, CaseIterable {
        case notUsed       = 0
        case slideShow     = 1
        case speakerMirror = 2

        var label: String {
            switch self {
            case .notUsed:       return "Not Used"
            case .slideShow:     return "Slide Show"
            case .speakerMirror: return "Speaker Notes (Mirror)"
            }
        }
    }

    /// All physically-connected display IDs (NSScreen AND online-but-mirrored).
    private var displayIDs:   [CGDirectDisplayID] = []
    private var roleCards:    [DisplayCard]        = []
    /// Roles keyed by unit number (stable across mirror-set ID reassignments).
    private var rolesByUnit:  [UInt32: Role] = [:]
    /// Display names keyed by unit number — populated from NSScreen.localizedName
    /// and surviving ID changes when macOS creates/removes mirror sets.
    private var nameByUnit:   [UInt32: String] = [:]

    private var stackView:    NSStackView!
    private var statusLabel:  NSTextField!
    private var applyButton:  NSButton!
    private var removeMirrorButton: NSButton!

    private var displayRefreshTimer: Timer?

    /// Watcher for PPT Slide Show — stores the target as a CGDirectDisplayID
    /// so the NSScreen reference is resolved fresh at move time.
    private var slideShowWatcher:    WindowInventory?
    private var watchTargetDisplayID: CGDirectDisplayID?

    // MARK: - Init

    private init() {
        let win = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 340),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "PowerPoint Setup"
        win.center()
        win.minSize = NSSize(width: 480, height: 280)
        super.init(window: win)
        win.delegate = self
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Show

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refreshDisplays()
        startDisplayRefreshTimer()
        requestAppleEventsPermission()
    }

    /// Proactively request Automation permission for Microsoft PowerPoint.
    /// macOS 10.14+ requires explicit user authorization before any Apple Event
    /// can be sent. Running a benign "get name" script triggers the system dialog
    /// the first time; subsequent calls are instant (TCC cache hit).
    private func requestAppleEventsPermission() {
        DispatchQueue.global(qos: .background).async {
            var errDict: NSDictionary?
            let script = NSAppleScript(source: """
            tell application "Microsoft PowerPoint"
                get name
            end tell
            """)
            let result = script?.executeAndReturnError(&errDict)
            DispatchQueue.main.async {
                if let e = errDict {
                    let msg = e["NSAppleScriptErrorMessage"] as? String ?? "\(e)"
                    if msg.contains("Not authorized") {
                        AppLog.shared.warn("PPT AS: Automation permission denied — ask user to enable in System Settings → Privacy & Security → Automation", category: "PPTSetup")
                    } else {
                        AppLog.shared.info("PPT AS: permission probe: \(msg)", category: "PPTSetup")
                    }
                } else {
                    AppLog.shared.info("PPT AS: Automation permission granted (probe='\(result?.stringValue ?? "ok")')", category: "PPTSetup")
                }
            }
        }
    }

    // MARK: - UI

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        stackView = NSStackView()
        stackView.orientation = .horizontal
        stackView.spacing     = 16
        stackView.alignment   = .top
        stackView.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.documentView = stackView
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller   = false
        scrollView.autohidesScrollers    = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(scrollView)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font      = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(statusLabel)

        applyButton = NSButton(title: "Apply", target: self, action: #selector(applySetup))
        applyButton.bezelStyle = .rounded
        applyButton.keyEquivalent = "\r"
        applyButton.translatesAutoresizingMaskIntoConstraints = false

        removeMirrorButton = NSButton(title: "Remove Mirror", target: self, action: #selector(removeMirror))
        removeMirrorButton.bezelStyle = .rounded
        removeMirrorButton.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(applyButton)
        contentView.addSubview(removeMirrorButton)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            scrollView.bottomAnchor.constraint(equalTo: applyButton.topAnchor, constant: -12),

            applyButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            applyButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            applyButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 90),

            removeMirrorButton.trailingAnchor.constraint(equalTo: applyButton.leadingAnchor, constant: -8),
            removeMirrorButton.centerYAnchor.constraint(equalTo: applyButton.centerYAnchor),

            statusLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            statusLabel.centerYAnchor.constraint(equalTo: applyButton.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: removeMirrorButton.leadingAnchor, constant: -8),
        ])
    }

    // MARK: - Display refresh

    /// Returns all physically connected display IDs — both active (in NSScreen.screens)
    /// and online-but-mirrored (not in NSScreen.screens, but CGDisplayIsOnline).
    private func allOnlineDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        guard count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    private func refreshDisplays() {
        // Active displays (in NSScreen.screens) — update name cache by unit number.
        let activeIDs: [CGDirectDisplayID] = NSScreen.screens.compactMap {
            $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        }
        for screen in NSScreen.screens {
            if let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                nameByUnit[CGDisplayUnitNumber(id)] = screen.localizedName
            }
        }
        let activeSet = Set(activeIDs)

        // Append online-but-not-active IDs (mirror slaves — new IDs, same hardware).
        let mirroredIDs = allOnlineDisplayIDs().filter { !activeSet.contains($0) }
        let allIDs = activeIDs + mirroredIDs

        if allIDs != displayIDs {
            displayIDs = allIDs
            rebuildCards(allIDs: allIDs)
        }

        // Refresh snapshots only for active (non-mirrored) displays.
        for card in roleCards where activeSet.contains(card.displayID) {
            card.refreshSnapshot()
        }
    }

    private func rebuildCards(allIDs: [CGDirectDisplayID]) {
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        roleCards.removeAll()

        let activeSet: Set<CGDirectDisplayID> = Set(NSScreen.screens.compactMap {
            $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        })

        for displayID in allIDs {
            let unit     = CGDisplayUnitNumber(displayID)
            let isMirror = !activeSet.contains(displayID)

            // Look up name by unit number — survives ID changes after mirroring.
            // Fall back to OutputWindowController's app-wide cache (seeded at launch
            // from NSScreen before any mirrors were applied).
            let name = nameByUnit[unit]
                ?? OutputWindowController.displayNameByUnit[unit]
                ?? "Display \(unit)"

            // Look up (or default) role by unit number.
            let role: Role
            if let saved = rolesByUnit[unit] {
                role = saved
            } else {
                role = defaultRole(for: displayID, in: allIDs)
                rolesByUnit[unit] = role
            }

            let card = DisplayCard(
                displayID:    displayID,
                displayName:  name,
                isMirrored:   isMirror,
                initialRole:  role
            ) { [weak self] newRole in
                self?.rolesByUnit[unit] = newRole
            }
            roleCards.append(card)
            stackView.addArrangedSubview(card)
        }
    }

    private func defaultRole(for displayID: CGDirectDisplayID, in allIDs: [CGDirectDisplayID]) -> Role {
        if CGDisplayIsBuiltin(displayID) != 0 { return .speakerMirror }
        let firstExternal = allIDs.first { CGDisplayIsBuiltin($0) == 0 }
        if displayID == firstExternal { return .slideShow }
        return .notUsed
    }

    // MARK: - Display refresh timer

    private func startDisplayRefreshTimer() {
        stopDisplayRefreshTimer()
        displayRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshDisplays()
        }
    }

    private func stopDisplayRefreshTimer() {
        displayRefreshTimer?.invalidate()
        displayRefreshTimer = nil
    }

    func windowWillClose(_ notification: Notification) {
        stopDisplayRefreshTimer()
        // Do NOT stop the slide show watcher here — it must survive window close so
        // the user doesn't have to keep this window open during the presentation.
        // The watcher stops itself once the Slide Show is confirmed on the right display.
    }

    // MARK: - Apply

    @objc private func applySetup() {
        stopSlideShowWatcher()
        applyButton.isEnabled = false

        // Build ID→role map from unit-based roles (for all currently known IDs).
        let slideShowID      = displayIDs.first { rolesByUnit[CGDisplayUnitNumber($0)] == .slideShow }
        let speakerMirrorIDs = displayIDs.filter  { rolesByUnit[CGDisplayUnitNumber($0)] == .speakerMirror }
        let builtinID        = displayIDs.first { CGDisplayIsBuiltin($0) != 0 }

        var messages: [String] = []

        // ── 1a. Remove mirrors for displays no longer assigned Speaker Notes ──
        // If a display is currently in an OS mirror set but the user changed its
        // role, remove the mirror so it can act independently again.
        for displayID in displayIDs {
            let unit = CGDisplayUnitNumber(displayID)
            let role = rolesByUnit[unit] ?? .notUsed
            // CGDisplayMirrorsDisplay returns the display this one mirrors, or 0.
            if CGDisplayMirrorsDisplay(displayID) != kCGNullDirectDisplay && role != .speakerMirror {
                let name = nameByUnit[unit] ?? "\(displayID)"
                AppLog.shared.info("PPT Setup: removing mirror on \(name) (role changed to \(role.label))", category: "PPTSetup")
                removeSystemMirror(for: displayID)
                messages.append("Unmirror: \(name)")
            }
        }

        // ── 1b. Apply mirrors for Speaker Notes displays ──────────────────
        let mirrorMasterID: CGDirectDisplayID? = builtinID ?? speakerMirrorIDs.first
        let displaysToMirror = speakerMirrorIDs.filter { $0 != mirrorMasterID }

        if displaysToMirror.isEmpty && speakerMirrorIDs.contains(where: { $0 == builtinID }) {
            messages.append("Speaker: MacBook (no mirror needed)")
        } else {
            for mirrorID in displaysToMirror {
                guard let masterID = mirrorMasterID else { continue }
                applySystemMirror(mirrorDisplay: mirrorID, masterDisplay: masterID)
                let mirrorName = nameByUnit[CGDisplayUnitNumber(mirrorID)] ?? "\(mirrorID)"
                let masterName = nameByUnit[CGDisplayUnitNumber(masterID)] ?? "\(masterID)"
                AppLog.shared.info("PPT Setup: system mirror \(mirrorName) ← \(masterName)", category: "PPTSetup")
                messages.append("Mirror: \(mirrorName) ← \(masterName)")
            }
        }

        // ── 2. Move Slide Show window ─────────────────────────────────────
        // Store the target as a plain ID — resolve to NSScreen fresh at move
        // time so we're not holding a stale NSScreen reference from before the
        // mirror config change.
        guard let targetID = slideShowID else {
            if messages.isEmpty { messages.append("Roles saved") }
            setStatus("✓ " + messages.joined(separator: "  |  "))
            applyButton.isEnabled = true
            return
        }

        // After a mirror change PPT needs 2-3 s to recognise the new display
        // layout and reassign its internal Presenter View / Slide Show slots.
        // Swapping too early sends Slide Show in the wrong direction.
        // If no mirrors were actually changed, 0.5 s is still enough.
        let mirrorsChanged = messages.contains(where: { $0.hasPrefix("Mirror:") || $0.hasPrefix("Unmirror:") })
        let settleDelay: Double = mirrorsChanged ? 2.5 : 0.5

        let mirrorMsg = messages.joined(separator: "  |  ")
        setStatus((mirrorMsg.isEmpty ? "" : mirrorMsg + "  |  ") + "⏳ Waiting for display layout to settle…")

        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) { [weak self] in
            guard let self else { return }
            self.applyButton.isEnabled = true
            self.moveSlideShowToDisplay(targetID: targetID, mirrorMsg: mirrorMsg)
        }
    }

    private func moveSlideShowToDisplay(targetID: CGDirectDisplayID, mirrorMsg: String) {
        // Resolve target NSScreen fresh after mirror config has settled.
        guard let targetScreen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == targetID
        }) else {
            AppLog.shared.warn("PPT Setup: target display \(targetID) not in NSScreen.screens after settling", category: "PPTSetup")
            setStatus((mirrorMsg.isEmpty ? "" : mirrorMsg + "  |  ") + "⚠ Target display unavailable")
            return
        }

        // Enable Presenter View (the only real AppleScript property for display routing).
        // PPT hardcodes: Presenter View on main display (menu bar), Slide Show on first
        // external. The |slide show monitor| property does NOT exist in PPT's sdef —
        // it accepts the set silently but discards it immediately. Correction is done
        // via 'swap displays' in the watcher if PPT chose the wrong screen.
        setPPTPresenterView()

        let screenName = targetScreen.localizedName
        let prefix = mirrorMsg.isEmpty ? "" : mirrorMsg + "  |  "

        if findSlideShowWindow() != nil {
            // Slide Show already running — check if it's on the right display and swap if not.
            watchTargetDisplayID = targetID
            setStatus(prefix + "⏳ Checking Slide Show display…")
            startSlideShowWatcher(targetDisplayID: targetID)
        } else {
            // Presentation not started yet — watcher will verify placement once it opens.
            watchTargetDisplayID = targetID
            setStatus(prefix + "✓ Ready → \(screenName)  |  Start presentation to begin")
            startSlideShowWatcher(targetDisplayID: targetID)
        }
    }

    @objc private func removeMirror() {
        for id in displayIDs {
            removeSystemMirror(for: id)
        }
        AppLog.shared.info("PPT Setup: removed all system mirrors", category: "PPTSetup")
        setStatus("✓ Mirror removed")
    }

    private func setStatus(_ msg: String) {
        statusLabel.stringValue = msg
    }

    // MARK: - WindowInventory watcher

    /// - allowFullscreenRestart: when true, the watcher will call restartForFullscreen()
    ///   after confirming the Slide Show reached the target via teleport.  Set to false
    ///   for the "verify-only" watcher that runs after the fullscreen restart so we
    ///   don't loop indefinitely.
    private func startSlideShowWatcher(targetDisplayID: CGDirectDisplayID,
                                       allowFullscreenRestart: Bool = true) {
        let watcher = WindowInventory()
        // swapAttempted = true ONLY when the button was actually pressed (not on AX failure).
        // This lets us retry on the next tick if PPT's windows weren't accessible yet.
        var swapAttempted = false
        // restartAttempted = true after we escalate to end-show + rerun.
        var restartAttempted = false
        var ticksAfterSwap = 0

        watcher.onUpdate = { [weak self] (windows: [WindowInfo]) in
            guard let self else { return }

            let pptWindows = windows.filter { $0.appName.localizedCaseInsensitiveContains("PowerPoint") }
            guard !pptWindows.isEmpty else { return }

            // Wait until the Slide Show window appears.
            guard let slideShowWindow = pptWindows.first(where: {
                $0.title.localizedCaseInsensitiveContains("Slide Show")
            }) else { return }

            let primaryH   = NSScreen.screens.first?.frame.height ?? 0
            let windowMidX = slideShowWindow.frame.midX
            let windowMidY = primaryH - slideShowWindow.frame.midY   // Quartz→AppKit

            // Re-resolve the target screen on every tick: display IDs can be
            // reassigned when macOS settles after a mirror-set change.
            guard let targetScreen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == targetDisplayID
            }) else {
                AppLog.shared.warn("PPT watcher: target \(targetDisplayID) not in NSScreen — mirrored/disconnected?", category: "PPTSetup")
                self.setStatus("⚠ Presentation display not visible (mirrored?)")
                self.stopSlideShowWatcher()
                return
            }

            let alreadyOnTarget = targetScreen.frame.contains(CGPoint(x: windowMidX, y: windowMidY))
            let pid = pid_t(slideShowWindow.pid)
            AppLog.shared.info(
                "PPT watcher: mid=(\(Int(windowMidX)),\(Int(windowMidY))) target=\(targetScreen.localizedName) \(targetScreen.frame) onTarget=\(alreadyOnTarget)",
                category: "PPTSetup"
            )

            if alreadyOnTarget {
                if swapAttempted && allowFullscreenRestart {
                    // We had to teleport the window — it's on the right display but
                    // PPT couldn't resize it (sizeErr=-25200), so it's not fullscreen.
                    // Restart the slide show so PPT re-enters proper fullscreen on the
                    // target display (which is now the only external after mirroring).
                    AppLog.shared.info(
                        "PPT watcher: Slide Show on \(targetScreen.localizedName) via teleport — restarting for fullscreen",
                        category: "PPTSetup"
                    )
                    self.setStatus("↺ Entering fullscreen on \(targetScreen.localizedName)…")
                    self.stopSlideShowWatcher()
                    self.restartForFullscreen(pid: pid, targetDisplayID: targetDisplayID)
                } else {
                    AppLog.shared.info("PPT watcher: Slide Show ✓ on \(targetScreen.localizedName)", category: "PPTSetup")
                    self.setStatus("✓ Slide Show → \(targetScreen.localizedName)")
                    self.stopSlideShowWatcher()
                }
                return
            }

            // ── Wrong display ──────────────────────────────────────────────

            if !swapAttempted {
                // Step 1: click Swap Displays to update PPT's internal display assignment
                // (moves the window from MacBook→M550SL internally, updating PPT's routing).
                // Step 2: 0.3s later, teleport the Slide Show window directly to the
                // target display via AX kAXPositionAttribute — this bypasses PPT's
                // slow animation AND the mirror-slave bounce-back problem (M550SL is
                // slave so PPT's swap bounces back; D32x-D1 is independent and stays).
                let clicked = self.clickSwapDisplaysInPresenterView(pid: pid)
                if clicked {
                    swapAttempted = true
                    ticksAfterSwap = 0
                    self.setStatus("↩ Moving Slide Show to target display…")
                    // Teleport after a brief pause to let PPT register the swap command
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                        guard let self else { return }
                        self.teleportSlideShowToDisplay(pid: pid, targetDisplayID: targetDisplayID)
                    }
                }
                // else: empty window list — PPT transitioning; retry next 0.5s tick

            } else if !restartAttempted {
                // Swap was clicked; wait for PPT to finish its display-swap animation.
                // PPT's animation can take up to ~17 s (observed in logs), so don't
                // restart until 25 s have elapsed without the slide show reaching target.
                ticksAfterSwap += 1
                AppLog.shared.info("PPT watcher: waiting for swap to complete (tick \(ticksAfterSwap)/50)", category: "PPTSetup")

                if ticksAfterSwap >= 50 {   // 25 s
                    // Still wrong after 25 s — escalate to restarting PPT's presentation
                    // so it re-detects the display layout (especially after mirror changes).
                    restartAttempted = true
                    AppLog.shared.warn("PPT watcher: 25 s after swap, still wrong — restarting slide show", category: "PPTSetup")
                    self.setStatus("↺ Restarting slide show for new display layout…")
                    self.stopSlideShowWatcher()
                    self.restartSlideShow(pid: pid, targetDisplayID: targetDisplayID, allowFullscreenRestart: false)
                }
            }
        }
        watcher.start(interval: 0.5)
        slideShowWatcher = watcher
    }

    // MARK: - Direct AX window teleport

    /// Moves the PPT Slide Show window directly to the target display by setting
    /// kAXPositionAttribute and kAXSizeAttribute.  Called 0.3 s after clicking
    /// "Swap Displays" so PPT has registered the swap (updating its internal
    /// routing state from MacBook→M550SL to "external") before we override the
    /// physical position to D32x-D1.
    ///
    /// This bypasses two problems:
    ///  • PPT's 15+ s swap animation (we teleport instantly)
    ///  • Mirror bounce-back (window on slave M550SL returns to master MacBook;
    ///    D32x-D1 is an independent display so the window stays there)
    private func teleportSlideShowToDisplay(pid: pid_t, targetDisplayID: CGDirectDisplayID) {
        guard let targetScreen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == targetDisplayID
        }) else {
            AppLog.shared.warn("PPT teleport: target screen \(targetDisplayID) not in NSScreen", category: "PPTSetup")
            return
        }

        let app = AXUIElementCreateApplication(pid)
        var rawWindows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &rawWindows) == .success,
              let windows = rawWindows as? [AXUIElement] else {
            AppLog.shared.warn("PPT teleport: no AX windows for pid=\(pid)", category: "PPTSetup")
            return
        }

        guard let slideShowWin = windows.first(where: {
            var rawTitle: CFTypeRef?
            AXUIElementCopyAttributeValue($0, kAXTitleAttribute as CFString, &rawTitle)
            return (rawTitle as? String ?? "").localizedCaseInsensitiveContains("Slide Show")
        }) else {
            AppLog.shared.warn("PPT teleport: Slide Show AX window not found (have \(windows.count) windows)", category: "PPTSetup")
            return
        }

        // Convert AppKit frame (Y-up, origin=bottom-left of primary) to
        // Quartz / AX coordinates (Y-down, origin=top-left of primary).
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        var position = CGPoint(x: targetScreen.frame.minX,
                               y: primaryH - targetScreen.frame.maxY)
        var size     = CGSize(width:  targetScreen.frame.width,
                              height: targetScreen.frame.height)

        guard let posValue  = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize,  &size) else { return }

        let posErr  = AXUIElementSetAttributeValue(slideShowWin, kAXPositionAttribute as CFString, posValue)
        let sizeErr = AXUIElementSetAttributeValue(slideShowWin, kAXSizeAttribute    as CFString, sizeValue)

        AppLog.shared.info(
            "PPT teleport: Slide Show → \(targetScreen.localizedName) Quartz(\(Int(position.x)),\(Int(position.y))) \(Int(size.width))×\(Int(size.height))  posErr=\(posErr.rawValue) sizeErr=\(sizeErr.rawValue)",
            category: "PPTSetup"
        )
    }

    // MARK: - Slide show restart

    /// Called when the watcher has confirmed the Slide Show reached the target
    /// display via teleport, but the window is not fullscreen (PPT blocks AX size
    /// changes via kAXSizeAttribute).  Toggles native macOS fullscreen on the
    /// Slide Show window via AXFullScreen attribute, with green-button fallback.
    /// This avoids the risky AppleScript end-show + run-slide-show round trip.
    private func restartForFullscreen(pid: pid_t, targetDisplayID: CGDirectDisplayID) {
        let app = AXUIElementCreateApplication(pid)
        var rawWindows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &rawWindows) == .success,
              let windows = rawWindows as? [AXUIElement] else {
            AppLog.shared.warn("PPT fullscreen: no AX windows for pid=\(pid)", category: "PPTSetup")
            return
        }

        guard let slideShowWin = windows.first(where: {
            var rawTitle: CFTypeRef?
            AXUIElementCopyAttributeValue($0, kAXTitleAttribute as CFString, &rawTitle)
            return (rawTitle as? String ?? "").localizedCaseInsensitiveContains("Slide Show")
        }) else {
            AppLog.shared.warn("PPT fullscreen: Slide Show AX window not found", category: "PPTSetup")
            return
        }

        AppLog.shared.info("PPT fullscreen: entering native fullscreen on Slide Show window", category: "PPTSetup")
        WindowMover.enterFullscreen(slideShowWin)

        // Verify after a moment.  If still not fullscreen, fall back to AppleScript restart.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            var rawFS: CFTypeRef?
            let isFS = AXUIElementCopyAttributeValue(slideShowWin, "AXFullScreen" as CFString, &rawFS) == .success
                       && (rawFS as? Bool == true)
            if isFS {
                AppLog.shared.info("PPT fullscreen: ✓ window is now fullscreen", category: "PPTSetup")
                if let targetScreen = NSScreen.screens.first(where: {
                    ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == targetDisplayID
                }) {
                    self.setStatus("✓ Slide Show → \(targetScreen.localizedName) (fullscreen)")
                }
            } else {
                AppLog.shared.warn("PPT fullscreen: AX fullscreen didn't stick — falling back to slide-show restart", category: "PPTSetup")
                self.restartSlideShow(pid: pid, targetDisplayID: targetDisplayID, allowFullscreenRestart: false)
            }
        }
    }

    /// Exits the running PPT slide show (via AX fullscreen toggle + AppleScript)
    /// and immediately restarts it.  After a mirror-config change, PPT may have
    /// stale display assignments; restarting forces it to re-detect the new layout
    /// (e.g. MacBook + D32x-D1 after M550SL was mirrored from MacBook).
    private func restartSlideShow(pid: pid_t, targetDisplayID: CGDirectDisplayID,
                                   allowFullscreenRestart: Bool = true) {
        let app = AXUIElementCreateApplication(pid)

        // Step 1: tell the Slide Show window to leave fullscreen so AppleScript
        // "end show" won't hit the -32192 error it gets in proper fullscreen.
        var rawWindows: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &rawWindows) == .success,
           let windows = rawWindows as? [AXUIElement] {
            for win in windows {
                var rawTitle: CFTypeRef?
                AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &rawTitle)
                if (rawTitle as? String ?? "").localizedCaseInsensitiveContains("Slide Show") {
                    AXUIElementSetAttributeValue(win, "AXFullScreen" as CFString, kCFBooleanFalse)
                    AppLog.shared.info("PPT restart: cleared AXFullScreen on Slide Show window", category: "PPTSetup")
                    break
                }
            }
        }

        // Step 2: give AX a moment to exit fullscreen, then end+restart via AppleScript.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }

            let source = """
            tell application "Microsoft PowerPoint"
                try
                    if (count of presentations) = 0 then return "no-presentation"
                    set ap to active presentation
                    set sss to slide show settings of ap
                    try
                        set ssw to slide show window of ap
                        end show ssw
                    on error
                    end try
                    delay 0.4
                    run slide show sss
                    return "restarted"
                on error e
                    return "restart-error:" & e
                end try
            end tell
            """
            AppLog.shared.info("PPT restart: running end-show + run-slide-show", category: "PPTSetup")
            DispatchQueue.global(qos: .userInitiated).async {
                var errDict: NSDictionary?
                let result = NSAppleScript(source: source)?.executeAndReturnError(&errDict)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if let e = errDict {
                        let msg = e["NSAppleScriptErrorMessage"] as? String ?? "\(e)"
                        AppLog.shared.error("PPT restart AppleScript: \(msg)", category: "PPTSetup")
                        self.setStatus("⚠ Restart failed — stop & restart the presentation manually")
                    } else {
                        let val = result?.stringValue ?? "ok"
                        AppLog.shared.info("PPT restart result: \(val)", category: "PPTSetup")
                        if val.contains("error") {
                            self.setStatus("⚠ Restart error — stop & restart the presentation manually")
                        } else {
                            self.setStatus("↺ Presentation restarted — verifying display…")
                            // Give PPT 2 s to open the slide show, then watch.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                                self?.startSlideShowWatcher(targetDisplayID: targetDisplayID,
                                                            allowFullscreenRestart: allowFullscreenRestart)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - AX "Swap Displays" button click

    /// Finds and clicks the "Swap Displays" button in PPT's Presenter View via the
    /// Accessibility API.  This is equivalent to the user clicking the swap button
    /// in the Presenter View toolbar — and works even when the Slide Show is in
    /// fullscreen on a different macOS Space.
    ///
    /// Returns `true` if the button was found and the press action was sent.
    /// Returns `false` if AX returned an empty window list (PPT may be transitioning
    /// after a display-config change) — caller should retry on the next tick.
    @discardableResult
    private func clickSwapDisplaysInPresenterView(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)

        var rawWindows: CFTypeRef?
        let winErr = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &rawWindows)

        // If AX reports success but returns 0 windows, PPT is mid-transition (e.g.
        // right after a mirror change); return false so the caller retries next tick.
        guard winErr == .success, let windows = rawWindows as? [AXUIElement], !windows.isEmpty else {
            AppLog.shared.warn(
                "PPT AX swap: no windows (err=\(winErr.rawValue)) — PPT likely transitioning, will retry",
                category: "PPTSetup"
            )
            return false
        }

        // Log all windows so we can see what AX returns.
        for (i, win) in windows.enumerated() {
            var rawTitle: CFTypeRef?
            AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &rawTitle)
            AppLog.shared.info("PPT AX swap: window[\(i)] = '\(rawTitle as? String ?? "<no title>")'", category: "PPTSetup")
        }

        // Try every accessible window — Presenter View is whichever one is on the current Space.
        for window in windows {
            if let button = findAxSwapButton(in: window) {
                var rawTitle: CFTypeRef?
                var rawDesc:  CFTypeRef?
                AXUIElementCopyAttributeValue(button, kAXTitleAttribute as CFString, &rawTitle)
                AXUIElementCopyAttributeValue(button, kAXDescriptionAttribute as CFString, &rawDesc)
                let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
                AppLog.shared.info(
                    "PPT AX swap: pressed '\(rawTitle as? String ?? "")'/'\(rawDesc as? String ?? "")' → AXError=\(result.rawValue)",
                    category: "PPTSetup"
                )
                return true
            }
        }

        // Button not found — log full AX button tree so we can identify the right label.
        AppLog.shared.warn("PPT AX swap: swap button NOT found — dumping all buttons for investigation:", category: "PPTSetup")
        for (i, window) in windows.enumerated() {
            logAllAXButtons(in: window, windowIndex: i)
        }
        return false
    }

    /// Recursively walks the AX element tree looking for a button whose title or
    /// description suggests a display-swap / exchange action.
    private func findAxSwapButton(in element: AXUIElement, depth: Int = 0) -> AXUIElement? {
        guard depth < 25 else { return nil }

        var rawRole: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &rawRole)
        let role = rawRole as? String ?? ""

        if role == (kAXButtonRole as String) || role == "AXToolbarButton" {
            var t: CFTypeRef?
            var d: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &t)
            AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &d)
            let combined = ((t as? String ?? "") + " " + (d as? String ?? "")).lowercased()

            if combined.contains("swap")
               || combined.contains("exchange")
               || (combined.contains("switch") && (combined.contains("display") || combined.contains("screen")))
               || (combined.contains("change") && (combined.contains("display") || combined.contains("screen"))) {
                return element
            }
        }

        var rawChildren: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &rawChildren) == .success,
              let children = rawChildren as? [AXUIElement] else { return nil }

        for child in children {
            if let found = findAxSwapButton(in: child, depth: depth + 1) { return found }
        }
        return nil
    }

    /// Recursively logs every AX button found in the element tree (for debugging when
    /// `findAxSwapButton` returns nil and we need to identify the real button label).
    private func logAllAXButtons(in element: AXUIElement, windowIndex: Int, depth: Int = 0) {
        guard depth < 8 else { return }

        var rawRole: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &rawRole)
        let role = rawRole as? String ?? ""

        if role == (kAXButtonRole as String) || role == "AXToolbarButton" || role == "AXMenuButton" {
            var t: CFTypeRef?
            var d: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &t)
            AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &d)
            AppLog.shared.info(
                "PPT AX btn[win\(windowIndex),d\(depth)]: role=\(role) title='\(t as? String ?? "")' desc='\(d as? String ?? "")'",
                category: "PPTSetup"
            )
        }

        var rawChildren: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &rawChildren) == .success,
           let children = rawChildren as? [AXUIElement] {
            for child in children { logAllAXButtons(in: child, windowIndex: windowIndex, depth: depth + 1) }
        }
    }

    private func stopSlideShowWatcher() {
        slideShowWatcher?.stop()
        slideShowWatcher  = nil
        watchTargetDisplayID = nil
    }

    // MARK: - PowerPoint AppleScript

    /// Enables Presenter View in PPT's slide show settings.
    ///
    /// NOTE: `slide show monitor` does NOT exist in PowerPoint for Mac's AppleScript
    /// dictionary (confirmed by inspecting PowerPoint.sdef). Setting it silently
    /// succeeds but is immediately discarded. PPT hardcodes: Presenter View on the
    /// macOS main display (menu bar), Slide Show on the first external display.
    /// The only reliable correction is `swap displays` after the show starts, which
    /// is done by the watcher when it detects the show is on the wrong screen.
    private func setPPTPresenterView() {
        let source = """
        tell application "Microsoft PowerPoint"
            try
                if (count of presentations) = 0 then return "no-presentation"
                set show with presenter of slide show settings of active presentation to true
                return "presenter-view-enabled"
            on error e
                return "error:" & e
            end try
        end tell
        """
        AppLog.shared.info("PPT AS: enabling Presenter View", category: "PPTSetup")
        runAppleScript(source, category: "PPTSetup")
    }

    /// Swaps which display shows the Slide Show vs Presenter View.
    /// Tries multiple syntaxes because the sdef entry for `swap displays` is
    /// ambiguous about whether the presenter tool is a direct parameter or target.
    private func swapPPTDisplays() {
        let source = """
        tell application "Microsoft PowerPoint"
            try
                -- Approach 1: tell-block on presenter tool via presenter view window list
                set pvList to every presenter view window
                if (count of pvList) > 0 then
                    try
                        set pt to presenter tool of item 1 of pvList
                        tell pt
                            swap displays
                        end tell
                        return "swapped-via-pvw-tell"
                    on error e1
                        -- Approach 2: swap displays sent directly to app
                        try
                            swap displays
                            return "swapped-direct"
                        on error e2
                            -- Approach 3: tell-block on presenter tool via slide show window
                            try
                                set pt2 to presenter tool of slide show window of active presentation
                                tell pt2
                                    swap displays
                                end tell
                                return "swapped-via-ssw-tell"
                            on error e3
                                return "all-failed: e1=" & e1 & " e2=" & e2 & " e3=" & e3
                            end try
                        end try
                    end try
                else
                    -- No presenter view window — try direct app command anyway
                    try
                        swap displays
                        return "swapped-direct-no-pvw"
                    on error e4
                        return "no-pvw + direct-failed: " & e4
                    end try
                end if
            on error outerErr
                return "outer:" & outerErr
            end try
        end tell
        """
        AppLog.shared.info("PPT AS: swapping displays", category: "PPTSetup")
        runAppleScript(source, category: "PPTSetup")
    }

    /// Logs all properties of PPT's slide show settings (diagnostic) then
    /// stops and restarts the slide show so PPT re-picks the display.
    /// With only one external display visible after mirrors, the restarted
    /// show MUST go to that external display (macOS + PPT convention).
    private func dumpPPTSettingsAndRestart() {
        // Note: no backslash line continuations — they become literal \ in AppleScript
        // and cause "Expected expression but found unknown token".
        let source = """
        tell application "Microsoft PowerPoint"
            try
                if (count of presentations) = 0 then return "no-presentation"
                set ap to active presentation
                set sss to slide show settings of ap
                set propLog to "showType=" & (show type of sss as string) & " withPresenter=" & (show with presenter of sss as string)
                try
                    set ssw to slide show window of ap
                    end show ssw
                end try
                delay 0.5
                run slide show sss
                return "restarted | " & propLog
            on error e
                return "error:" & e
            end try
        end tell
        """
        AppLog.shared.info("PPT: dumping settings + restarting slide show", category: "PPTSetup")
        runAppleScript(source, category: "PPTSetup")
    }

    private func runAppleScript(_ source: String, category: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            var errDict: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&errDict)
            DispatchQueue.main.async {
                if let e = errDict {
                    let msg = e["NSAppleScriptErrorMessage"] as? String ?? "\(e)"
                    AppLog.shared.error("PPT AS error: \(msg)", category: category)
                } else {
                    AppLog.shared.info("PPT AS result: \(result?.stringValue ?? "nil")", category: category)
                }
            }
        }
    }

    // MARK: - System mirror API

    private func applySystemMirror(mirrorDisplay: CGDirectDisplayID, masterDisplay: CGDirectDisplayID) {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == CGError.success,
              let config else {
            AppLog.shared.error("PPT Setup: CGBeginDisplayConfiguration failed", category: "PPTSetup")
            return
        }
        CGConfigureDisplayMirrorOfDisplay(config, mirrorDisplay, masterDisplay)
        let err = CGCompleteDisplayConfiguration(config, .forSession)
        if err != CGError.success {
            AppLog.shared.error("PPT Setup: CGCompleteDisplayConfiguration err=\(err.rawValue)", category: "PPTSetup")
        }
    }

    private func removeSystemMirror(for displayID: CGDirectDisplayID) {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == CGError.success,
              let config else { return }
        CGConfigureDisplayMirrorOfDisplay(config, displayID, kCGNullDirectDisplay)
        CGCompleteDisplayConfiguration(config, .forSession)
    }

    // MARK: - PowerPoint window lookup

    /// Finds the PPT Slide Show window using CGWindowList (ALL windows, not just
    /// onscreen-only — catches fullscreen windows on other Spaces).
    private func findSlideShowWindow() -> WindowInfo? {
        guard let entry = pptSnapshotWindows().first(where: {
            $0.appName.localizedCaseInsensitiveContains("PowerPoint") &&
            $0.title.localizedCaseInsensitiveContains("Slide Show")
        }) else { return nil }

        return WindowInfo(
            id:      entry.id,
            title:   entry.title,
            appName: entry.appName,
            appIcon: nil,
            pid:     entry.pid,
            frame:   entry.frame
        )
    }
}

// MARK: - DisplayCard

final class DisplayCard: NSView {

    let displayID:   CGDirectDisplayID
    let displayName: String
    let isMirrored:  Bool
    private let onRoleChange: (PowerPointSetupWindowController.Role) -> Void

    private let snapshotView: NSImageView
    private let nameLabel:    NSTextField
    private let rolePicker:   NSPopUpButton

    init(
        displayID:    CGDirectDisplayID,
        displayName:  String,
        isMirrored:   Bool,
        initialRole:  PowerPointSetupWindowController.Role,
        onRoleChange: @escaping (PowerPointSetupWindowController.Role) -> Void
    ) {
        self.displayID    = displayID
        self.displayName  = displayName
        self.isMirrored   = isMirrored
        self.onRoleChange = onRoleChange

        snapshotView = NSImageView()
        snapshotView.imageScaling   = .scaleProportionallyUpOrDown
        snapshotView.imageAlignment = .alignCenter
        snapshotView.wantsLayer     = true
        snapshotView.layer?.cornerRadius      = 4
        snapshotView.layer?.masksToBounds     = true
        snapshotView.layer?.backgroundColor   = NSColor(white: 0.1, alpha: 1).cgColor
        snapshotView.translatesAutoresizingMaskIntoConstraints = false

        let isMain = (NSScreen.main?.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        let nameSuffix = isMain ? " (Main)" : isMirrored ? " ⌀" : ""
        nameLabel = NSTextField(labelWithString: displayName + nameSuffix)
        nameLabel.font      = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        nameLabel.alignment = .center
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        rolePicker = NSPopUpButton(frame: .zero, pullsDown: false)
        rolePicker.translatesAutoresizingMaskIntoConstraints = false
        for role in PowerPointSetupWindowController.Role.allCases {
            rolePicker.addItem(withTitle: role.label)
            rolePicker.lastItem?.tag = role.rawValue
        }
        rolePicker.selectItem(withTag: initialRole.rawValue)
        // Mirrored displays are still assignable — changing role and clicking
        // Apply will remove the mirror and apply the new configuration.

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(snapshotView)
        addSubview(nameLabel)
        addSubview(rolePicker)

        // Built-in: blue accent border; mirrored: dim border
        wantsLayer = true
        if CGDisplayIsBuiltin(displayID) != 0 {
            layer?.borderColor  = NSColor.controlAccentColor.cgColor
            layer?.borderWidth  = 1.5
            layer?.cornerRadius = 6
        } else if isMirrored {
            layer?.borderColor  = NSColor.tertiaryLabelColor.cgColor
            layer?.borderWidth  = 1
            layer?.cornerRadius = 6
        }

        rolePicker.target = self
        rolePicker.action = #selector(pickerChanged)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 210),

            snapshotView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            snapshotView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            snapshotView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            snapshotView.heightAnchor.constraint(equalTo: snapshotView.widthAnchor, multiplier: 9.0 / 16.0),

            nameLabel.topAnchor.constraint(equalTo: snapshotView.bottomAnchor, constant: 6),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),

            rolePicker.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 4),
            rolePicker.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            rolePicker.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            rolePicker.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])

        if isMirrored {
            // Show a "⌀ Mirrored" overlay on the snapshot area
            let label = NSTextField(labelWithString: "⌀  Mirrored")
            label.font      = .systemFont(ofSize: 12, weight: .medium)
            label.textColor = .tertiaryLabelColor
            label.alignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: snapshotView.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: snapshotView.centerYAnchor),
            ])
        }

        refreshSnapshot()
    }

    required init?(coder: NSCoder) { fatalError() }

    func refreshSnapshot() {
        guard !isMirrored else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            guard let cgImage = CGDisplayCreateImage(self.displayID) else { return }
            let nsImage = NSImage(cgImage: cgImage, size: .zero)
            DispatchQueue.main.async { self.snapshotView.image = nsImage }
        }
    }

    @objc private func pickerChanged() {
        let rawValue = rolePicker.selectedTag()
        if let role = PowerPointSetupWindowController.Role(rawValue: rawValue) {
            onRoleChange(role)
        }
    }
}

// MARK: - CGWindowList snapshot (all windows, not onscreen-only)

/// Synchronous snapshot of ALL windows via CGWindowList — includes windows on
/// other Spaces and fullscreen presentations that optionOnScreenOnly would miss.
private func pptSnapshotWindows() -> [(id: CGWindowID, title: String, appName: String, pid: pid_t, frame: CGRect)] {
    // Note: no .optionOnScreenOnly — we want windows on all Spaces.
    guard let rawList = CGWindowListCopyWindowInfo(
        [.excludeDesktopElements],
        kCGNullWindowID
    ) else { return [] }

    let list = rawList as NSArray
    var result: [(id: CGWindowID, title: String, appName: String, pid: pid_t, frame: CGRect)] = []
    for item in list {
        guard let dict = item as? NSDictionary else { continue }
        guard let wid   = dict[kCGWindowNumber] as? Int,
              let title = dict[kCGWindowName]   as? String,
              !title.isEmpty else { continue }
        let appName = dict[kCGWindowOwnerName] as? String ?? ""
        let pid     = dict[kCGWindowOwnerPID]  as? Int32  ?? 0

        var frame = CGRect.zero
        if let bounds    = dict[kCGWindowBounds] as? NSDictionary,
           let boundsRef = bounds as? CFDictionary {
            CGRectMakeWithDictionaryRepresentation(boundsRef, &frame)
        }
        result.append((id: CGWindowID(wid), title: title, appName: appName,
                       pid: pid_t(pid), frame: frame))
    }
    return result
}
