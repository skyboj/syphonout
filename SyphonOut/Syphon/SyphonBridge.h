#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

/// Objective-C bridge that owns a CGL context, connects to a SyphonClient,
/// reads each new frame into a shared MTLTexture, and invokes the frame callback.
///
/// Why Obj-C: CGL and OpenGL APIs are C/Obj-C — bridging from Swift requires
/// excessive unsafe pointer work. This class wraps it cleanly.
@interface SyphonBridge : NSObject

@property (nonatomic, readonly) BOOL hasSignal;

/// @param serverDescription  NSDictionary from SyphonServerDirectory
/// @param device             The MTLDevice to create textures on
/// @param frameHandler       Called on the main thread with the latest MTLTexture
- (instancetype)initWithServerDescription:(NSDictionary *)serverDescription
                                   device:(id<MTLDevice>)device
                             frameHandler:(void (^)(id<MTLTexture> texture))frameHandler;

- (void)stop;

@end

NS_ASSUME_NONNULL_END
