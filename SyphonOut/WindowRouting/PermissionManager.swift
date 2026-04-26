import AppKit
import ScreenCaptureKit

/// Checks and requests the two permissions Window Routing needs:
///   - Accessibility  (to move windows via AX API)
///   - Screen Recording (to enumerate windows via SCShareableContent)
///
/// Usage:
///   PermissionManager.shared.requirePermissions(in: someWindow) { granted in
///       if granted { /* open routing UI */ }
///   }
final class PermissionManager {

    static let shared = PermissionManager()
    private init() {}

    // MARK: - Permission state

    /// Synchronous Accessibility check.
    var hasAccessibility: Bool {
        AXIsProcessTrusted()
    }

    /// Synchronous Screen Recording check via CoreGraphics preflight
    /// (does NOT trigger the system prompt — just reads the current grant state).
    var hasScreenRecording: Bool {
        CGPreflightScreenCaptureAccess()
    }

    var allGranted: Bool {
        hasAccessibility && hasScreenRecording
    }

    // MARK: - Public entry point

    /// Checks permissions and, if any are missing, presents a blocking alert.
    /// @p parentWindow — if non-nil, alert is shown as a sheet; otherwise modal.
    /// @p completion — called on the main thread once the user dismisses the alert
    ///   (true = all granted, false = user dismissed without granting all).
    func requirePermissions(
        in parentWindow: NSWindow? = nil,
        completion: @escaping (Bool) -> Void
    ) {
        // Fast path: already have everything.
        if allGranted {
            completion(true)
            return
        }

        showPermissionAlert(in: parentWindow, completion: completion)
    }

    // MARK: - Private

    private func showPermissionAlert(
        in parentWindow: NSWindow?,
        completion: @escaping (Bool) -> Void
    ) {
        let missing = buildMissingList()

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Additional permissions required"
        alert.informativeText =
            "Window Routing needs the following permissions in System Settings:\n\n" +
            missing.map { "• \($0.displayName)" }.joined(separator: "\n") +
            "\n\nGrant access, then try again."

        // Primary action buttons — one per missing permission.
        for item in missing {
            alert.addButton(withTitle: "Open \(item.displayName) Settings")
        }
        // Dismiss option.
        alert.addButton(withTitle: "Later")

        let respond = { [weak self] (response: NSApplication.ModalResponse) in
            guard let self else { return }

            // Map response index to button index (first button = .alertFirstButtonReturn = 1000).
            let idx = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            if idx >= 0 && idx < missing.count {
                NSWorkspace.shared.open(missing[idx].settingsURL)
                // Watch for the permission being granted while settings is open.
                self.pollUntilGranted(
                    kind: missing[idx].kind,
                    parentWindow: parentWindow,
                    completion: completion
                )
            } else {
                // "Later" pressed — return current state.
                completion(self.allGranted)
            }
        }

        if let parentWindow {
            alert.beginSheetModal(for: parentWindow) { response in
                respond(response)
            }
        } else {
            let response = alert.runModal()
            respond(response)
        }
    }

    // MARK: - Permission descriptors

    private enum PermissionKind { case accessibility, screenRecording }

    private struct MissingPermission {
        let kind: PermissionKind
        let displayName: String
        let settingsURL: URL
    }

    private func buildMissingList() -> [MissingPermission] {
        var list: [MissingPermission] = []
        if !hasAccessibility {
            list.append(MissingPermission(
                kind: .accessibility,
                displayName: "Accessibility",
                settingsURL: URL(string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            ))
        }
        if !hasScreenRecording {
            list.append(MissingPermission(
                kind: .screenRecording,
                displayName: "Screen Recording",
                settingsURL: URL(string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            ))
        }
        return list
    }

    // MARK: - Polling after the user visits System Settings

    /// Polls every second for up to 60 s waiting for @p kind to be granted.
    /// When granted (or timed out), re-evaluates allGranted and either
    /// completes or shows the alert again for any remaining missing items.
    private func pollUntilGranted(
        kind: PermissionKind,
        parentWindow: NSWindow?,
        completion: @escaping (Bool) -> Void
    ) {
        var attempts = 0
        let maxAttempts = 60

        func check() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self else { return }
                attempts += 1
                let granted = kind == .accessibility ? self.hasAccessibility : self.hasScreenRecording
                if granted {
                    // This permission is now granted — re-enter to check for others.
                    if self.allGranted {
                        completion(true)
                    } else {
                        self.showPermissionAlert(in: parentWindow, completion: completion)
                    }
                } else if attempts < maxAttempts {
                    check()
                } else {
                    // Timed out — user probably ignored System Settings.
                    completion(false)
                }
            }
        }

        check()
    }
}
