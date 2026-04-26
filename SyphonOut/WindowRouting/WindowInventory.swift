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

/// Periodically enumerates on-screen windows via SCShareableContent.
/// Refresh interval: 2 seconds. Calls `onUpdate` on the main thread whenever
/// the list changes (added, removed, or renamed windows).
///
final class WindowInventory {

    // MARK: - Public state

    /// Current snapshot; always accessed/mutated on main thread.
    private(set) var windows: [WindowInfo] = []

    /// Called on main thread after each refresh that produced a different list.
    var onUpdate: (([WindowInfo]) -> Void)?

    // MARK: - Private

    private var refreshTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.syphonout.WindowInventory", qos: .utility)
    private var iconCache: [pid_t: NSImage] = [:]

    // MARK: - Lifecycle

    func start() {
        guard refreshTimer == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .seconds(2), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.refresh() }
        timer.resume()
        refreshTimer = timer
    }

    func stop() {
        refreshTimer?.cancel()
        refreshTimer = nil
    }

    // MARK: - Fetch

    private func refresh() {
        // SCShareableContent.getExcludingDesktopWindows is the modern API
        // that doesn't need a running capture session.
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { [weak self] content, error in
            guard let self, let content else { return }
            let snapshot = self.buildSnapshot(from: content.windows)
            DispatchQueue.main.async {
                // Only fire onUpdate when something actually changed.
                if !self.listsEqual(self.windows, snapshot) {
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
            // Skip system UI server, Dock, WindowServer noise
            let bundle = app.bundleIdentifier ?? ""
            if bundle == "com.apple.dock" { continue }
            if bundle == "com.apple.WindowManager" { continue }

            let pid = app.processID
            let icon = cachedIcon(pid: pid, app: app)
            let title = w.title ?? ""
            let appName = app.applicationName

            let info = WindowInfo(
                id: CGWindowID(w.windowID),
                title: title,
                appName: appName,
                appIcon: icon,
                pid: pid,
                frame: w.frame
            )
            result.append(info)
        }
        // Sort: by app name, then window title
        return result.sorted {
            if $0.appName != $1.appName { return $0.appName < $1.appName }
            return $0.displayTitle < $1.displayTitle
        }
    }

    // MARK: - Icon cache

    private func cachedIcon(pid: pid_t, app: SCRunningApplication) -> NSImage? {
        if let cached = iconCache[pid] { return cached }
        let running = NSRunningApplication(processIdentifier: pid)
        let icon = running?.icon
        if let icon {
            // Scale down to 16×16 for table display
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
        return zip(a, b).allSatisfy { $0.id == $1.id && $0.title == $1.title }
    }
}
