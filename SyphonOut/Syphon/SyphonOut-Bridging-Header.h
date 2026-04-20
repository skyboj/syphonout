/*
 SyphonOut-Bridging-Header.h
 Exposes C/ObjC APIs to Swift.

 Intentionally has NO compile-time dependency on Syphon.framework.
 Syphon is loaded at runtime via SyphonNative.m (dlopen).
*/

#import <Cocoa/Cocoa.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/CAMetalLayer.h>

// Rust core FFI (state machine, Metal renderer, Syphon IOSurface receiver)
#import "syphonout_core.h"

// ObjC runtime Syphon bridge (dlopen-based, no Syphon.framework at link time)
#import "SyphonNative.h"
