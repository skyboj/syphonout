import AppKit
import ScreenCaptureKit

/// Checks and requests the two permissions Window Routing needs:
///   - Accessibility    (to move windows via AX API)
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

    /// Accessibility check + prompt. `AXIsProcessTrustedWithOptions` with
    /// kAXTrustedCheckOptionPrompt:true both reads current state AND causes
    /// macOS to add this binary to System Settings → Privacy → Accessibility
    /// (same binary-path registration behaviour as CGRequestScreenCaptureAccess).
    var hasAccessibility: Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    /// Screen Recording check + prompt. `CGRequestScreenCaptureAccess` reads
    /// the current grant state AND triggers the system prompt on first call,
    /// adding the app to System Settings → Privacy → Screen Recording.
    var hasScreenRecording: Bool {
        CGRequestScreenCaptureAccess()
    }

    var allGranted: Bool {
        hasAccessibility && hasScreenRecording
    }

    // MARK: - Public entry point

    /// Checks permissions and, if any are missing, presents a blocking alert.
    /// `parentWindow` — if non-nil, alert is shown as a sheet; otherwise modal.
    /// `completion` — called on the main thread:
    ///   true  = all permissions granted
    ///   false = user dismissed without granting all
    func requirePermissions(
        in parentWindow: NSWindow? = nil,
        completion: @escaping (Bool) -> Void
    ) {
        if allGranted { completion(true); return }
        showPermissionAlert(in: parentWindow, completion: completion)
    }

    // MARK: - Alert

    private func showPermissionAlert(
        in parentWindow: NSWindow?,
        completion: @escaping (Bool) -> Void
    ) {
        let missing = buildMissingList()
        guard !missing.isEmpty else { completion(true); return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Additional permissions required"
        alert.informativeText =
            "Window Routing needs the following permissions:\n\n" +
            missing.map { "• \($0.displayName)" }.joined(separator: "\n") +
            "\n\nIf already enabled, click \"Check Again\" to retry."

        // Button order matters: first = default (Return key)
        // "Check Again" is primary so the user can retry without reopening settings.
        alert.addButton(withTitle: "Check Again")
        for item in missing {
            alert.addButton(withTitle: "Open \(item.displayName) Settings")
        }
        alert.addButton(withTitle: "Later")

        let respond = { [weak self] (response: NSApplication.ModalResponse) in
            guard let self else { return }
            let idx = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue

            if idx == 0 {
                // "Check Again" — re-evaluate immediately
                if self.allGranted {
                    completion(true)
                } else {
                    self.showPermissionAlert(in: parentWindow, completion: completion)
                }
            } else if idx >= 1 && idx <= missing.count {
                // "Open X Settings" — open the relevant pane, then poll
                let item = missing[idx - 1]
                NSWorkspace.shared.open(item.settingsURL)
                self.pollUntilGranted(kind: item.kind,
                                      parentWindow: parentWindow,
                                      completion: completion)
            } else {
                // "Later"
                completion(self.allGranted)
            }
        }

        if let parentWindow {
            alert.beginSheetModal(for: parentWindow) { respond($0) }
        } else {
            respond(alert.runModal())
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

    // MARK: - Polling

    /// Polls every second for up to 60 s waiting for a specific permission.
    /// When granted, re-evaluates allGranted and either completes or re-shows
    /// the alert for any remaining missing permissions.
    private func pollUntilGranted(
        kind: PermissionKind,
        parentWindow: NSWindow?,
        completion: @escaping (Bool) -> Void
    ) {
        var attempts = 0

        func check() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self else { return }
                attempts += 1
                let granted = kind == .accessibility
                    ? self.hasAccessibility
                    : self.hasScreenRecording
                if granted {
                    if self.allGranted {
                        completion(true)
                    } else {
                        self.showPermissionAlert(in: parentWindow, completion: completion)
                    }
                } else if attempts < 60 {
                    check()
                } else {
                    completion(false)
                }
            }
        }

        check()
    }
}
