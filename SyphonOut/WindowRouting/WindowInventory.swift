import AppKit
import ScreenCaptureKit

/// A snapshot of a single on-screen window.
struct WindowInfo: Identifiable {
    let id: CGWindowID
    let title: String          // window title (may be empty)
    let appName: String        // owning application display name
    let appIcon: NSImage?      // 16×16 icon, nil if unavailable
    let pid: pid_t
    let frame: CGRect          // on-screen frame in Quartz coordinates

    /// Display string used in the table's "Window" column.
    var displayTitle: String {
        title.isEmpty ? "(no title)" : title
    }
}

/// Periodically enumerates windows via SCShareableContent.
/// Refresh interval: 2 seconds. Calls `onUpdate` on the main thread whenever
/// the list changes (added, removed, or renamed windows).
final class WindowInventory {

    // MARK: - Public state

    private(set) var windows: [WindowInfo] = []
    var onUpdate: (([WindowInfo]) -> Void)?

    // MARK: - Private

    private var refreshTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.syphonout.WindowInventory", qos: .utility)
    private var iconCache: [pid_t: NSImage] = [:]

    // Bundles that produce only system-internal windows, not useful to route.
    private static let filteredBundles: Set<String> = [
        "com.apple.dock",
        "com.apple.WindowManager",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.systemuiserver",
        "com.apple.screencaptureui",
        "com.apple.Spotlight",
        "com.apple.spotlight",
    ]

    // App display names that are always system helpers, never content windows.
    private static let filteredAppNames: Set<String> = [
        "Spotlight",
        "Open and Save Panel Server",
        "LinkedNotesUIService",
    ]

    // MARK: - Lifecycle

    func start() {
        guard refreshTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .seconds(2), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.refresh(force: false) }
        timer.resume()
        refreshTimer = timer
    }

    func stop() {
        refreshTimer?.cancel()
        refreshTimer = nil
    }

    /// Immediately fetch a fresh snapshot and always call onUpdate regardless of
    /// whether the list appears equal. Use this after a move so the new positions
    /// are committed to `windows` before the next Move action.
    func forceRefresh() {
        queue.async { [weak self] in self?.refresh(force: true) }
    }

    // MARK: - Fetch

    private func refresh(force: Bool) {
        // onScreenWindowsOnly: false — include windows on ALL Spaces and displays,
        // not just the currently active Space. This ensures presentation windows,
        // confidence monitors, and windows on external displays always appear.
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { [weak self] content, error in
            guard let self, let content else { return }
            let snapshot = self.buildSnapshot(from: content.windows)
            DispatchQueue.main.async {
                // Always update when forced, or when the list actually changed.
                // IMPORTANT: listsEqual checks frame too — so a window that was
                // moved to another screen is detected as changed even if its title
                // and ID are identical.
                if force || !self.listsEqual(self.windows, snapshot) {
                    self.windows = snapshot
                    self.onUpdate?(snapshot)
                }
            }
        }
    }

    private func buildSnapshot(from scWindows: [SCWindow]) -> [WindowInfo] {
        var result: [WindowInfo] = []
        for w in scWindows {
            guard let app = w.owningApplication else { continue }

            let bundle  = app.bundleIdentifier ?? ""
            let appName = app.applicationName

            // Skip our own output windows
            if bundle == (Bundle.main.bundleIdentifier ?? "com.syphonout.SyphonOut") { continue }

            // Skip known system-only bundles
            if Self.filteredBundles.contains(bundle) { continue }

            // Skip windows with no meaningful owner (Menubar, tracking overlays…)
            if appName.isEmpty { continue }

            // Skip AutoFill credential overlay windows (named "AutoFill (AppName)")
            if appName.hasPrefix("AutoFill") { continue }

            // Skip known system helper process names
            if Self.filteredAppNames.contains(appName) { continue }

            // Skip tiny windows — too small to be useful for routing (< 100×100 pts)
            if w.frame.width < 100 || w.frame.height < 100 { continue }

            let pid   = app.processID
            let icon  = cachedIcon(pid: pid, app: app)
            let title = w.title ?? ""

            result.append(WindowInfo(
                id:      CGWindowID(w.windowID),
                title:   title,
                appName: appName,
                appIcon: icon,
                pid:     pid,
                frame:   w.frame
            ))
        }
        return result.sorted {
            if $0.appName != $1.appName { return $0.appName < $1.appName }
            return $0.displayTitle < $1.displayTitle
        }
    }

    // MARK: - Icon cache

    private func cachedIcon(pid: pid_t, app: SCRunningApplication) -> NSImage? {
        if let cached = iconCache[pid] { return cached }
        let running = NSRunningApplication(processIdentifier: pid)
        if let icon = running?.icon {
            let small = NSImage(size: NSSize(width: 16, height: 16))
            small.lockFocus()
            icon.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16),
                      from: .zero, operation: .copy, fraction: 1)
            small.unlockFocus()
            iconCache[pid] = small
            return small
        }
        return nil
    }

    // MARK: - Change detection

    private func listsEqual(_ a: [WindowInfo], _ b: [WindowInfo]) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).allSatisfy {
            $0.id == $1.id &&
            $0.title == $1.title &&
            $0.frame == $1.frame   // detect window moves/resizes
        }
    }
}
