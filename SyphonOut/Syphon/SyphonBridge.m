#import "SyphonBridge.h"
#import <Syphon/Syphon.h>
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl.h>

@interface SyphonBridge ()
@property (nonatomic) SyphonClient *syphonClient;
@property (nonatomic) CGLContextObj cglContext;
@property (nonatomic) id<MTLDevice> device;
@property (nonatomic) id<MTLTexture> metalTexture;
@property (nonatomic, copy) void (^frameHandler)(id<MTLTexture>);
@property (nonatomic) BOOL hasSignal;
@end

@implementation SyphonBridge

- (instancetype)initWithServerDescription:(NSDictionary *)serverDescription
                                   device:(id<MTLDevice>)device
                             frameHandler:(void (^)(id<MTLTexture>))frameHandler {
    self = [super init];
    if (!self) return nil;

    _device = device;
    _frameHandler = [frameHandler copy];
    _hasSignal = NO;

    // Create a CGL context for OpenGL texture access
    CGLPixelFormatAttribute attribs[] = {
        kCGLPFAAccelerated,
        kCGLPFANoRecovery,
        (CGLPixelFormatAttribute)0
    };
    CGLPixelFormatObj pixelFormat = NULL;
    GLint numPixelFormats = 0;
    CGLChoosePixelFormat(attribs, &pixelFormat, &numPixelFormats);

    CGLContextObj ctx = NULL;
    CGLCreateContext(pixelFormat, NULL, &ctx);
    CGLDestroyPixelFormat(pixelFormat);
    _cglContext = ctx;

    if (!ctx) return nil;

    __weak typeof(self) weakSelf = self;
    _syphonClient = [[SyphonClient alloc] initWithServerDescription:serverDescription
                                                            context:ctx
                                                            options:nil
                                                    newFrameHandler:^(SyphonClient *client) {
        [weakSelf handleNewFrame:client];
    }];

    return self;
}

- (void)handleNewFrame:(SyphonClient *)client {
    SyphonImage *frame = [client newFrameImage];
    if (!frame) return;

    NSSize size = frame.textureSize;
    NSInteger width  = (NSInteger)size.width;
    NSInteger height = (NSInteger)size.height;
    if (width <= 0 || height <= 0) return;

    CGLSetCurrentContext(_cglContext);

    // Read pixels from the GL_TEXTURE_RECTANGLE texture into a CPU buffer.
    // Syphon textures are GL_TEXTURE_RECTANGLE_ARB (non-normalised coords).
    // We read as BGRA / UInt8 to match MTLPixelFormatBGRA8Unorm.
    NSInteger bytesPerRow = width * 4;
    NSMutableData *buffer = [NSMutableData dataWithLength:(NSUInteger)(bytesPerRow * height)];

    glBindTexture(GL_TEXTURE_RECTANGLE_ARB, frame.textureName);
    glGetTexImage(GL_TEXTURE_RECTANGLE_ARB, 0, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, buffer.mutableBytes);
    glBindTexture(GL_TEXTURE_RECTANGLE_ARB, 0);

    frame = nil; // release SyphonImage

    // Create or resize the MTLTexture as needed
    if (!_metalTexture || (NSInteger)_metalTexture.width != width || (NSInteger)_metalTexture.height != height) {
        MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                        width:(NSUInteger)width
                                                                                       height:(NSUInteger)height
                                                                                    mipmapped:NO];
        desc.usage = MTLTextureUsageShaderRead;
        _metalTexture = [_device newTextureWithDescriptor:desc];
    }

    if (!_metalTexture) return;

    MTLRegion region = MTLRegionMake2D(0, 0, (NSUInteger)width, (NSUInteger)height);
    [_metalTexture replaceRegion:region
                     mipmapLevel:0
                       withBytes:buffer.bytes
                     bytesPerRow:(NSUInteger)bytesPerRow];

    self.hasSignal = YES;

    id<MTLTexture> tex = _metalTexture;
    void (^handler)(id<MTLTexture>) = _frameHandler;
    dispatch_async(dispatch_get_main_queue(), ^{
        handler(tex);
    });
}

- (void)stop {
    [_syphonClient stop];
    _syphonClient = nil;
    _hasSignal = NO;
    if (_cglContext) {
        CGLDestroyContext(_cglContext);
        _cglContext = NULL;
    }
}

- (void)dealloc {
    [self stop];
}

@end
