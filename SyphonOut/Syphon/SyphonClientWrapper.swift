import Metal
import Foundation

/// Connects to a SyphonClient and delivers frames as MTLTexture via SyphonBridge (Obj-C).
///
/// Architecture note: CGL and OpenGL APIs live in SyphonBridge.m (Objective-C).
/// Syphon SDK v5 is OpenGL-based (x86_64). Frames are read from the GL_TEXTURE_RECTANGLE
/// into a CPU buffer then uploaded to an MTLTexture (BGRA8).
/// Future: replace with a Metal-native Syphon SDK to eliminate the CPU copy.
final class SyphonClientWrapper {
    private var bridge: SyphonBridge?

    var hasSignal: Bool { bridge?.hasSignal ?? false }

    init(serverDescription: SyphonServerDescription, device: MTLDevice, onFrame: @escaping (MTLTexture) -> Void) {
        // Build the NSDictionary SyphonClient expects
        let desc: [String: Any] = [
            SyphonServerDescriptionUUIDKey: serverDescription.id,
            SyphonServerDescriptionNameKey: serverDescription.name,
            SyphonServerDescriptionAppNameKey: serverDescription.appName
        ]
        bridge = SyphonBridge(serverDescription: desc, device: device) { texture in
            onFrame(texture)
        }
    }

    deinit {
        bridge?.stop()
    }
}
