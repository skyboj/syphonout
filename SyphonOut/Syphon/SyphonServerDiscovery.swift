import Foundation
import Combine

/// Discovers available Syphon servers and publishes the live list.
///
/// When Syphon.framework is linked, replace the stub body with real
/// SyphonServerDirectory observation (SyphonServerAnnounceNotification /
/// SyphonServerRetireNotification).
final class SyphonServerDiscovery: ObservableObject {
    @Published private(set) var servers: [SyphonServerDescription] = []

    // MARK: - Syphon Framework integration point
    //
    // Replace this stub with:
    //   import Syphon
    //   private var directory: SyphonServerDirectory
    //
    //   init() {
    //       directory = SyphonServerDirectory.shared()
    //       NotificationCenter.default.addObserver(
    //           self,
    //           selector: #selector(serversChanged),
    //           name: NSNotification.Name(rawValue: SyphonServerAnnounceNotification),
    //           object: nil
    //       )
    //       NotificationCenter.default.addObserver(
    //           self,
    //           selector: #selector(serversChanged),
    //           name: NSNotification.Name(rawValue: SyphonServerRetireNotification),
    //           object: nil
    //       )
    //       refresh()
    //   }
    //
    //   @objc private func serversChanged() { refresh() }
    //
    //   private func refresh() {
    //       let raw = directory.servers(matchingName: nil, appName: nil) ?? []
    //       servers = raw.map { desc in
    //           SyphonServerDescription(
    //               id: desc[SyphonServerDescriptionUUIDKey] as? String ?? UUID().uuidString,
    //               name: desc[SyphonServerDescriptionNameKey] as? String ?? "Unknown",
    //               appName: desc[SyphonServerDescriptionAppNameKey] as? String ?? "Unknown"
    //           )
    //       }
    //   }

    init() {}
}
