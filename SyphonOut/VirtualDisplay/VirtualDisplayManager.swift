import Foundation
import AppKit

/// Models a Virtual Display — logical video channel owned by the user.
struct VirtualDisplay: Identifiable, Codable {
    let id: String
    var name: String
    var width: UInt32
    var height: UInt32
    var sourceUUID: String?
    /// Raw mode value because SyphonOutMode (C enum) is not Codable.
    var modeRaw: UInt32

    var mode: SyphonOutMode {
        get { SyphonOutMode(rawValue: modeRaw) }
        set { modeRaw = newValue.rawValue }
    }

    var modeDescription: String {
        switch mode {
        case SYPHON_OUT_MODE_SIGNAL:             return "Signal"
        case SYPHON_OUT_MODE_FREEZE:             return "Freeze"
        case SYPHON_OUT_MODE_BLANK_BLACK:        return "Black"
        case SYPHON_OUT_MODE_BLANK_WHITE:        return "White"
        case SYPHON_OUT_MODE_BLANK_TEST_PATTERN: return "Test Pattern"
        case SYPHON_OUT_MODE_OFF:                return "Off"
        default: return "Unknown"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, width, height, sourceUUID, modeRaw
    }
}

/// Manages the lifecycle of Virtual Displays and their assignment to physical outputs.
final class VirtualDisplayManager: ObservableObject {
    static let shared = VirtualDisplayManager()

    @Published private(set) var displays: [VirtualDisplay] = []
    /// displayId → vdUUID
    @Published private(set) var assignments: [CGDirectDisplayID: String] = [:]

    private let defaults = UserDefaults.standard
    private let displaysKey = "virtualDisplays"
    private let assignmentsKey = "vdAssignments"

    private init() {
        load()
        if displays.isEmpty {
            createDefaultDisplay()
        } else {
            // Re-create Rust VD entries (lost on process restart) and
            // reconnect ObjC bridges for any VD that already has a source.
            reconnectAll()
        }
    }

    private func load() {
        if let data = defaults.data(forKey: displaysKey),
           let saved = try? JSONDecoder().decode([VirtualDisplay].self, from: data) {
            displays = saved
        }
        if let data = defaults.data(forKey: assignmentsKey),
           let saved = try? JSONDecoder().decode([String: String].self, from: data) {
            assignments = saved.reduce(into: [:]) { result, pair in
                if let id = UInt32(pair.key) {
                    result[CGDirectDisplayID(id)] = pair.value
                }
            }
        }
    }

    /// Re-register all persisted VDs with the Rust core and re-wire ObjC bridges.
    /// Called on init when there are saved VDs (i.e. not first launch).
    private func reconnectAll() {
        for vd in displays {
            // Re-create VD in Rust (core was just initialised — state is empty)
            vd.id.withCString { vdC in
                vd.name.withCString { nameC in
                    syphonout_vd_create(vdC, nameC, vd.width, vd.height)
                }
            }
            vd.id.withCString { syphonout_vd_set_mode($0, vd.mode) }

            // Re-open the ObjC bridge if a source was previously selected.
            // The actual subscription will only succeed once discovery has
            // run and the server is in the cache, so setSource re-attempts
            // lazily when the user changes the source. Here we pre-wire it
            // so users don't have to re-select on every launch.
            if let src = vd.sourceUUID {
                setSource(vdId: vd.id, sourceUUID: src)
            }
        }

        // Re-apply physical assignments
        for (displayId, vdUUID) in assignments {
            vdUUID.withCString { syphonout_physical_assign(UInt32(displayId), $0) }
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(displays) {
            defaults.set(data, forKey: displaysKey)
        }
        let stringMap = assignments.reduce(into: [String: String]()) { $0[String($1.key)] = $1.value }
        if let data = try? JSONEncoder().encode(stringMap) {
            defaults.set(data, forKey: assignmentsKey)
        }
    }

    @discardableResult
    func createDisplay(name: String? = nil, width: UInt32 = 1920, height: UInt32 = 1080) -> VirtualDisplay {
        let uuid = UUID().uuidString
        let vd = VirtualDisplay(
            id: uuid,
            name: name ?? "Display \(displays.count + 1)",
            width: width,
            height: height,
            sourceUUID: nil,
            modeRaw: SYPHON_OUT_MODE_SIGNAL.rawValue
        )
        displays.append(vd)
        uuid.withCString { cStr in
            vd.name.withCString { nameCStr in
                syphonout_vd_create(cStr, nameCStr, width, height)
            }
        }
        save()
        return vd
    }

    func destroyDisplay(id: String) {
        guard let index = displays.firstIndex(where: { $0.id == id }) else { return }
        let affected = assignments.filter { $0.value == id }.map { $0.key }
        for displayId in affected {
            unassignPhysical(displayId: displayId)
        }
        id.withCString { syphonout_vd_destroy($0) }
        displays.remove(at: index)
        save()
    }

    private func createDefaultDisplay() {
        // Create the default VD but do NOT assign it to any physical output.
        // The user selects which physical display gets the signal via the menu.
        createDisplay(name: "Main")
    }

    func setSource(vdId: String, sourceUUID: String) {
        guard let index = displays.firstIndex(where: { $0.id == vdId }) else { return }
        displays[index].sourceUUID = sourceUUID

        // Update Rust state
        vdId.withCString { vdC in
            sourceUUID.withCString { srcC in
                syphonout_vd_set_source(vdC, srcC)
            }
        }

        // Wire the correct ObjC bridge (only one active per VD at a time)
        if sourceUUID.hasPrefix("solink:") {
            let rawUUID = String(sourceUUID.dropFirst("solink:".count))
            vdId.withCString { vdC in
                rawUUID.withCString { SOLinkClientSetServerForVD(vdC, $0) }
            }
            vdId.withCString { SyphonNativeClearServerForVD($0) }
        } else {
            vdId.withCString { vdC in
                sourceUUID.withCString { SyphonNativeSetServerForVD(vdC, $0) }
            }
            vdId.withCString { SOLinkClientClearServerForVD($0) }
        }

        save()
    }

    func clearSource(vdId: String) {
        guard let index = displays.firstIndex(where: { $0.id == vdId }) else { return }
        displays[index].sourceUUID = nil
        vdId.withCString { vdC in
            syphonout_vd_clear_source(vdC)
            SyphonNativeClearServerForVD(vdC)
            SOLinkClientClearServerForVD(vdC)
        }
        save()
    }

    func setMode(vdId: String, mode: SyphonOutMode) {
        guard let index = displays.firstIndex(where: { $0.id == vdId }) else { return }
        displays[index].mode = mode
        vdId.withCString { syphonout_vd_set_mode($0, mode) }
        save()
    }

    func setSize(vdId: String, width: UInt32, height: UInt32) {
        guard let index = displays.firstIndex(where: { $0.id == vdId }) else { return }
        displays[index].width = width
        displays[index].height = height
        vdId.withCString { syphonout_vd_set_size($0, width, height) }
        save()
    }

    func setName(vdId: String, name: String) {
        guard let index = displays.firstIndex(where: { $0.id == vdId }) else { return }
        displays[index].name = name
        vdId.withCString { vdC in
            name.withCString { syphonout_vd_set_name(vdC, $0) }
        }
        save()
    }

    func assignPhysical(displayId: CGDirectDisplayID, vdUUID: String) {
        assignments[displayId] = vdUUID
        vdUUID.withCString { vdC in
            syphonout_physical_assign(UInt32(displayId), vdC)
        }
        save()
        NotificationCenter.default.post(
            name: .vdAssignmentChanged,
            object: nil,
            userInfo: ["displayId": displayId, "assigned": true]
        )
    }

    func unassignPhysical(displayId: CGDirectDisplayID) {
        assignments.removeValue(forKey: displayId)
        syphonout_physical_unassign(UInt32(displayId))
        save()
        NotificationCenter.default.post(
            name: .vdAssignmentChanged,
            object: nil,
            userInfo: ["displayId": displayId, "assigned": false]
        )
    }

    func assignedVD(for displayId: CGDirectDisplayID) -> VirtualDisplay? {
        guard let vdId = assignments[displayId] else { return nil }
        return displays.first { $0.id == vdId }
    }
}
