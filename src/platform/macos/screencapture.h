/**
 * @file src/platform/macos/screencapture.h
 * @brief Declarations for ScreenCaptureKit-based capture on macOS.
 */
#pragma once

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreGraphics/CoreGraphics.h>

#if defined(SUNSHINE_MACOS_SCREENCAPTUREKIT)
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#endif

typedef bool (^SCFrameCallbackBlock)(CMSampleBufferRef);

#if defined(SUNSHINE_MACOS_SCREENCAPTUREKIT)

API_AVAILABLE(macos(12.3))
@interface ApolloScreenCapture : NSObject <SCStreamOutput, SCStreamDelegate>

@property (nonatomic, assign) CGDirectDisplayID displayID;
@property (nonatomic, assign) int frameWidth;
@property (nonatomic, assign) int frameHeight;
@property (nonatomic, assign) int frameRate;
@property (nonatomic, assign) OSType pixelFormat;
@property (nonatomic, assign) BOOL captureHDR;

@property (nonatomic, strong) SCStream *stream;
@property (nonatomic, strong) SCContentFilter *contentFilter;
@property (nonatomic, strong) SCStreamConfiguration *streamConfig;
@property (nonatomic, copy) SCFrameCallbackBlock frameCallback;
@property (nonatomic, strong) dispatch_semaphore_t captureSemaphore;
@property (nonatomic, assign) BOOL isCapturing;

+ (NSArray<NSDictionary *> *)displayNames;
+ (NSString *)getDisplayName:(CGDirectDisplayID)displayID;

- (instancetype)initWithDisplay:(CGDirectDisplayID)displayID frameRate:(int)frameRate;
- (void)setFrameWidth:(int)frameWidth frameHeight:(int)frameHeight;
- (dispatch_semaphore_t)capture:(SCFrameCallbackBlock)frameCallback;
- (void)stopCapture;
- (BOOL)isHDRSupported;
- (BOOL)isHDRActive;
- (BOOL)captureSingleFrame:(void (^)(CMSampleBufferRef _Nullable sampleBuffer, NSError * _Nullable error))completionHandler;

@end

#endif
