import Foundation

/// Lightweight, Syphon-framework-independent description of a Syphon server.
/// When the real Syphon.framework is linked, replace this stub with
/// a typealias to the framework's own SyphonServerDescription.
struct SyphonServerDescription: Identifiable, Hashable {
    let id: String          // unique per server (UUID string from Syphon framework)
    let name: String        // human-readable server name (e.g. "OBS")
    let appName: String     // host application name

    var displayName: String { "\(appName) — \(name)" }
}
