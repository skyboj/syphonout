import Metal
import Foundation

/// Wraps SyphonMetalClient (Syphon.framework) and delivers new frames as MTLTexture.
///
/// When Syphon.framework is linked, replace the stub with the real implementation.
final class SyphonClientWrapper {
    private(set) var hasSignal: Bool = false

    // MARK: - Syphon Framework integration point
    //
    // import Syphon
    // private var client: SyphonMetalClient?
    //
    // When a new frame arrives from the real Syphon client:
    //   client = SyphonMetalClient(serverDescription: desc, device: device, options: nil) { [weak self] client in
    //       guard let self = self, let client = client else { return }
    //       if let frame = client.newFrameImage() {
    //           self.hasSignal = true
    //           self.onFrame(frame)   // frame is an MTLTexture
    //       }
    //   }
    //
    // Crossfade note: the texture delivered via onFrame is passed straight to
    // MetalRenderer.updateTexture(_:), which manages the crossfade internally.

    private let onFrame: (MTLTexture) -> Void

    init(serverDescription: SyphonServerDescription, device: MTLDevice, onFrame: @escaping (MTLTexture) -> Void) {
        self.onFrame = onFrame
        // Stub: real connection happens here with Syphon.framework
    }

    deinit {
        // Disconnect from Syphon server
        hasSignal = false
    }
}
