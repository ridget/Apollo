/**
 * @file src/platform/macos/screencapture.mm
 * @brief ScreenCaptureKit-based screen capture implementation for macOS 12.3+.
 */
#import "screencapture.h"
#import <AppKit/AppKit.h>

#if defined(SUNSHINE_MACOS_SCREENCAPTUREKIT)

@implementation ApolloScreenCapture

+ (NSArray<NSDictionary *> *)displayNames {
  CGDirectDisplayID displays[32];
  uint32_t count;
  if (CGGetActiveDisplayList(32, displays, &count) != kCGErrorSuccess) {
    return [NSArray array];
  }

  NSMutableArray *result = [NSMutableArray array];

  for (uint32_t i = 0; i < count; i++) {
    [result addObject:@{
      @"id": [NSNumber numberWithUnsignedInt:displays[i]],
      @"name": [NSString stringWithFormat:@"%d", displays[i]],
      @"displayName": [self getDisplayName:displays[i]] ?: @"Unknown Display",
    }];
  }

  return [NSArray arrayWithArray:result];
}

+ (NSString *)getDisplayName:(CGDirectDisplayID)displayID {
  for (NSScreen *screen in [NSScreen screens]) {
    if ([screen.deviceDescription[@"NSScreenNumber"] isEqualToNumber:[NSNumber numberWithUnsignedInt:displayID]]) {
      return screen.localizedName;
    }
  }
  return nil;
}

- (instancetype)initWithDisplay:(CGDirectDisplayID)displayID frameRate:(int)frameRate {
  self = [super init];
  if (!self) return nil;

  self.displayID = displayID;
  self.frameRate = frameRate;
  self.pixelFormat = kCVPixelFormatType_32BGRA;
  self.captureHDR = NO;
  self.isCapturing = NO;

  CGDisplayModeRef mode = CGDisplayCopyDisplayMode(displayID);
  if (mode) {
    self.frameWidth = (int)CGDisplayModeGetPixelWidth(mode);
    self.frameHeight = (int)CGDisplayModeGetPixelHeight(mode);
    CFRelease(mode);
  } else {
    self.frameWidth = (int)CGDisplayPixelsWide(displayID);
    self.frameHeight = (int)CGDisplayPixelsHigh(displayID);
  }

  __block BOOL setupComplete = NO;
  __block NSString *errorDescription = nil;
  dispatch_semaphore_t setupSemaphore = dispatch_semaphore_create(0);

  [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *error) {
    if (error) {
      errorDescription = [[error localizedDescription] copy];
      dispatch_semaphore_signal(setupSemaphore);
      return;
    }

    SCDisplay *targetDisplay = nil;
    for (SCDisplay *display in content.displays) {
      if (display.displayID == self.displayID) {
        targetDisplay = display;
        break;
      }
    }

    if (!targetDisplay && content.displays.count > 0) {
      targetDisplay = content.displays[0];
      self.displayID = targetDisplay.displayID;
    }

    if (!targetDisplay) {
      errorDescription = [@"No display found" copy];
      dispatch_semaphore_signal(setupSemaphore);
      return;
    }

    self.contentFilter = [[SCContentFilter alloc] initWithDisplay:targetDisplay excludingWindows:@[]];

    self.streamConfig = [[SCStreamConfiguration alloc] init];
    self.streamConfig.width = self.frameWidth;
    self.streamConfig.height = self.frameHeight;
    self.streamConfig.minimumFrameInterval = CMTimeMake(1, self.frameRate);
    self.streamConfig.pixelFormat = self.pixelFormat;
    self.streamConfig.queueDepth = 5;
    self.streamConfig.showsCursor = YES;

    if (@available(macOS 13.0, *)) {
      self.streamConfig.capturesAudio = NO;
    }

    if (@available(macOS 14.0, *)) {
      if ([self isHDRSupported]) {
        self.captureHDR = YES;
      }
    }

    self.stream = [[SCStream alloc] initWithFilter:self.contentFilter configuration:self.streamConfig delegate:self];

    NSError *addOutputError = nil;
    dispatch_queue_t captureQueue = dispatch_queue_create("com.sudomaker.apollo.screencapture", DISPATCH_QUEUE_SERIAL);
    [self.stream addStreamOutput:self type:SCStreamOutputTypeScreen sampleHandlerQueue:captureQueue error:&addOutputError];

    if (addOutputError) {
      errorDescription = [addOutputError localizedDescription];
      dispatch_semaphore_signal(setupSemaphore);
      return;
    }

    setupComplete = YES;
    dispatch_semaphore_signal(setupSemaphore);
  }];

  long waitResult = dispatch_semaphore_wait(setupSemaphore, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));

  if (waitResult != 0) {
    NSLog(@"ApolloScreenCapture: Setup timed out");
    return nil;
  }

  if (!setupComplete) {
    NSLog(@"ApolloScreenCapture: Setup failed: %@", errorDescription ?: @"Unknown error");
    return nil;
  }

  return self;
}

- (void)setFrameWidth:(int)frameWidth frameHeight:(int)frameHeight {
  self.frameWidth = frameWidth;
  self.frameHeight = frameHeight;

  if (self.streamConfig) {
    self.streamConfig.width = frameWidth;
    self.streamConfig.height = frameHeight;

    if (self.stream && self.isCapturing) {
      [self.stream updateConfiguration:self.streamConfig completionHandler:^(NSError *error) {
        if (error) {
          NSLog(@"ApolloScreenCapture: Failed to update stream configuration: %@", error);
        }
      }];
    }
  }
}

- (dispatch_semaphore_t)capture:(SCFrameCallbackBlock)frameCallback {
  @synchronized(self) {
    self.frameCallback = frameCallback;
    self.captureSemaphore = dispatch_semaphore_create(0);

    [self.stream startCaptureWithCompletionHandler:^(NSError *error) {
      if (error) {
        NSLog(@"ApolloScreenCapture: Failed to start capture: %@", error);
        dispatch_semaphore_signal(self.captureSemaphore);
      } else {
        self.isCapturing = YES;
      }
    }];

    return self.captureSemaphore;
  }
}

- (void)stopCapture {
  @synchronized(self) {
    if (!self.isCapturing) return;

    [self.stream stopCaptureWithCompletionHandler:^(NSError *error) {
      if (error) {
        NSLog(@"ApolloScreenCapture: Error stopping capture: %@", error);
      }
      self.isCapturing = NO;
      if (self.captureSemaphore) {
        dispatch_semaphore_signal(self.captureSemaphore);
      }
    }];
  }
}

- (BOOL)isHDRSupported {
  CGDisplayModeRef mode = CGDisplayCopyDisplayMode(self.displayID);
  if (!mode) return NO;

  BOOL supported = NO;
  CFStringRef colorSpace = CGDisplayModeCopyPixelEncoding(mode);
  if (colorSpace) {
    NSString *csString = (__bridge NSString *)colorSpace;
    supported = [csString containsString:@"HDR"] || [csString containsString:@"10"];
    CFRelease(colorSpace);
  }
  CFRelease(mode);
  return supported;
}

- (BOOL)isHDRActive {
  return self.captureHDR;
}

- (BOOL)captureSingleFrame:(void (^)(CMSampleBufferRef _Nullable sampleBuffer, NSError * _Nullable error))completionHandler {
  if (!self.contentFilter) {
    if (completionHandler) {
      completionHandler(nil, [NSError errorWithDomain:@"ApolloScreenCapture" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"Content filter not initialized"}]);
    }
    return NO;
  }

  SCStreamConfiguration *config = [[SCStreamConfiguration alloc] init];
  config.width = self.frameWidth;
  config.height = self.frameHeight;
  config.pixelFormat = self.pixelFormat;
  config.showsCursor = YES;

  if (@available(macOS 14.0, *)) {
    [SCScreenshotManager captureImageWithFilter:self.contentFilter
                                  configuration:config
                              completionHandler:^(CGImageRef _Nullable image, NSError * _Nullable error) {
      if (error || !image) {
        if (completionHandler) {
          completionHandler(nil, error ?: [NSError errorWithDomain:@"ApolloScreenCapture" code:-2 userInfo:@{NSLocalizedDescriptionKey: @"Failed to capture image"}]);
        }
        return;
      }

      CVPixelBufferRef pixelBuffer = NULL;
      size_t width = CGImageGetWidth(image);
      size_t height = CGImageGetHeight(image);

      NSDictionary *pixelBufferAttributes = @{
        (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
        (id)kCVPixelBufferWidthKey: @(width),
        (id)kCVPixelBufferHeightKey: @(height),
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)
      };

      CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)pixelBufferAttributes, &pixelBuffer);

      if (status != kCVReturnSuccess || !pixelBuffer) {
        if (completionHandler) {
          completionHandler(nil, [NSError errorWithDomain:@"ApolloScreenCapture" code:-3 userInfo:@{NSLocalizedDescriptionKey: @"Failed to create pixel buffer"}]);
        }
        return;
      }

      CVPixelBufferLockBaseAddress(pixelBuffer, 0);
      void *pxdata = CVPixelBufferGetBaseAddress(pixelBuffer);
      size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);

      CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
      CGContextRef context = CGBitmapContextCreate(pxdata, width, height, 8, bytesPerRow, colorSpace, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);

      if (context) {
        CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
        CGContextRelease(context);
      }
      CGColorSpaceRelease(colorSpace);
      CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);

      CMVideoFormatDescriptionRef formatDescription = NULL;
      CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &formatDescription);

      CMSampleTimingInfo timingInfo = {kCMTimeInvalid, kCMTimeZero, kCMTimeInvalid};
      CMSampleBufferRef sampleBuffer = NULL;

      if (formatDescription) {
        CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, YES, NULL, NULL, formatDescription, &timingInfo, &sampleBuffer);
        CFRelease(formatDescription);
      }

      CVPixelBufferRelease(pixelBuffer);

      if (completionHandler) {
        completionHandler(sampleBuffer, nil);
      }

      if (sampleBuffer) {
        CFRelease(sampleBuffer);
      }
    }];
    return YES;
  } else {
    __block CMSampleBufferRef capturedBuffer = NULL;
    __block BOOL frameReceived = NO;
    dispatch_semaphore_t frameSemaphore = dispatch_semaphore_create(0);

    dispatch_semaphore_t signal = [self capture:^(CMSampleBufferRef sampleBuffer) {
      if (!frameReceived && sampleBuffer) {
        capturedBuffer = (CMSampleBufferRef)CFRetain(sampleBuffer);
        frameReceived = YES;
        dispatch_semaphore_signal(frameSemaphore);
      }
      return NO;
    }];

    long frameResult = dispatch_semaphore_wait(frameSemaphore, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));

    dispatch_semaphore_wait(signal, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));

    if (frameResult != 0 || !capturedBuffer) {
      if (completionHandler) {
        completionHandler(nil, [NSError errorWithDomain:@"ApolloScreenCapture" code:-5 userInfo:@{NSLocalizedDescriptionKey: @"Failed to capture frame (fallback path)"}]);
      }
      if (capturedBuffer) {
        CFRelease(capturedBuffer);
      }
      return NO;
    }

    if (completionHandler) {
      completionHandler(capturedBuffer, nil);
    }
    CFRelease(capturedBuffer);
    return YES;
  }
}

#pragma mark - SCStreamOutput

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
  if (type != SCStreamOutputTypeScreen) return;

  @synchronized(self) {
    if (self.frameCallback) {
      BOOL continueCapture = self.frameCallback(sampleBuffer);
      if (!continueCapture) {
        [self stopCapture];
      }
    }
  }
}

#pragma mark - SCStreamDelegate

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
  NSLog(@"ApolloScreenCapture: Stream stopped with error: %@", error);
  @synchronized(self) {
    self.isCapturing = NO;
    if (self.captureSemaphore) {
      dispatch_semaphore_signal(self.captureSemaphore);
    }
  }
}

@end

#endif
