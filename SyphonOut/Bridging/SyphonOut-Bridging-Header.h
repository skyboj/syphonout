/*
 SyphonOut-Bridging-Header.h
 Exposes C/ObjC APIs to Swift.
 */

#import <Cocoa/Cocoa.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/CAMetalLayer.h>

// Rust core FFI (state machine, Metal renderer, SOLink frame receiver)
#import "syphonout_core.h"

// SOLink subscriber — zero-copy IOSurface frames from OBS obs-solink plugin
#import "SOLinkClient.h"
