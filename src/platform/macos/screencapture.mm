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
      errorDescription = [error localizedDescription];
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
      errorDescription = @"No display found";
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
