import Foundation
import Combine

/// Discovers available Syphon servers via SyphonServerDirectory and publishes the live list.
final class SyphonServerDiscovery: ObservableObject {
    @Published private(set) var servers: [SyphonServerDescription] = []

    private let directory = SyphonServerDirectory.shared()!

    init() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(serversChanged),
                       name: .SyphonServerAnnounce, object: directory)
        nc.addObserver(self, selector: #selector(serversChanged),
                       name: .SyphonServerUpdate, object: directory)
        nc.addObserver(self, selector: #selector(serversChanged),
                       name: .SyphonServerRetire, object: directory)
        refresh()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func serversChanged() {
        refresh()
    }

    private func refresh() {
        let raw = (directory.servers(matchingName: nil, appName: nil) as? [[String: Any]]) ?? []
        servers = raw.compactMap { dict in
            guard let id = dict[SyphonServerDescriptionUUIDKey] as? String else { return nil }
            return SyphonServerDescription(
                id: id,
                name: dict[SyphonServerDescriptionNameKey] as? String ?? "Unknown",
                appName: dict[SyphonServerDescriptionAppNameKey] as? String ?? "Unknown"
            )
        }
    }
}
