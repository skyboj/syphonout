import AppKit
import Combine

/// Owns all OutputControllers (one per physical display) and coordinates global operations.
final class OutputManager: ObservableObject {
    @Published private(set) var outputs: [OutputController] = []
    @Published private(set) var mirrorEnabled: Bool = false

    private var serverDiscovery: SyphonServerDiscovery?
    private var selectedServers: [CGDirectDisplayID: SyphonServerDescription] = [:]
    private var cancellables = Set<AnyCancellable>()

    var primaryOutput: OutputController? { outputs.first }

    // MARK: - Lifecycle

    func start() {
        buildOutputs()

        let discovery = SyphonServerDiscovery()
        self.serverDiscovery = discovery

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func screensDidChange() {
        buildOutputs()
    }

    private func buildOutputs() {
        let screens = NSScreen.screens
        // Preserve existing controllers for screens that are still connected
        var newOutputs: [OutputController] = []
        for screen in screens {
            if let existing = outputs.first(where: { $0.screen == screen }) {
                newOutputs.append(existing)
            } else {
                newOutputs.append(OutputController(screen: screen))
            }
        }
        outputs = newOutputs
    }

    // MARK: - Per-output control

    func setMode(_ mode: OutputMode, for output: OutputController) {
        let servers = serverDiscovery?.servers ?? []
        let selected = selectedServers[output.displayID]
        output.setMode(mode, availableServers: servers, selectedServer: selected)
        objectWillChange.send()
    }

    func selectServer(_ server: SyphonServerDescription?, for output: OutputController) {
        selectedServers[output.displayID] = server
        if case .signal = output.mode, let server = server {
            output.switchSource(to: server)
        }
        objectWillChange.send()
    }

    func selectedServer(for output: OutputController) -> SyphonServerDescription? {
        selectedServers[output.displayID]
    }

    var availableServers: [SyphonServerDescription] {
        serverDiscovery?.servers ?? []
    }

    // MARK: - Global operations

    func freezeAll() {
        outputs.forEach { setMode(.freeze, for: $0) }
    }

    func unfreezeAll() {
        outputs.forEach { setMode(.signal, for: $0) }
    }

    func blankAll(option: OutputMode.BlankOption = .black) {
        outputs.forEach { setMode(.blank(option), for: $0) }
    }

    func restoreAll() {
        outputs.forEach { setMode(.signal, for: $0) }
    }

    // MARK: - Mirror mode

    func setMirrorEnabled(_ enabled: Bool) {
        mirrorEnabled = enabled
        guard enabled, let primaryServer = primaryOutput.flatMap({ selectedServers[$0.displayID] }) else { return }
        for output in outputs.dropFirst() {
            selectServer(primaryServer, for: output)
        }
    }

    // MARK: - Status

    var globalIconState: GlobalIconState {
        let activeOutputs = outputs.filter { if case .off = $0.mode { return false }; return true }
        if activeOutputs.isEmpty { return .empty }
        let allSignal = activeOutputs.allSatisfy { $0.signalStatus == .present }
        return allSignal ? .solid : .half
    }
}

enum GlobalIconState {
    case solid  // ●
    case half   // ◑
    case empty  // ○
}
