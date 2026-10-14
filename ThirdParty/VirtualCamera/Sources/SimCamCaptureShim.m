#import "SimCamCaptureShim.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <fcntl.h>
#import <unistd.h>

// While a real -[AVCaptureDeviceInput initWithDevice:] runs, we hide the
// synthetic format (return nil like a bare simulator device) so AVFoundation's
// internal format inspection doesn't crash. Outside that window the format is
// exposed so scanners can read the preview dimensions.
static BOOL gSimCamSuppressFormats = NO;

#pragma mark - Synthetic capture format

/// A stand-in `AVFrameRateRange` (30 fps). Apps read
/// `format.videoSupportedFrameRateRanges.first.maxFrameRate` to configure the
/// capture; an empty array leaves that nil.
@interface SimCamFakeFrameRateRange : AVFrameRateRange
@end
@implementation SimCamFakeFrameRateRange
- (double)minFrameRate { return 30.0; }
- (double)maxFrameRate { return 30.0; }
- (CMTime)minFrameDuration { return CMTimeMake(1, 30); }
- (CMTime)maxFrameDuration { return CMTimeMake(1, 30); }
@end

/// A stand-in `AVCaptureDeviceFormat`. The critical getter is
/// `formatDescription`: scanners/preview code read its video dimensions to size
/// the preview texture. A nil format (the default for our fake device) yields a
/// 0×0 preview — frames flow but nothing shows. We build a real
/// `CMVideoFormatDescription` matching the streamed frame size.
@interface SimCamFakeFormat : AVCaptureDeviceFormat {
@public
    CMVideoFormatDescriptionRef _desc;
    NSArray *_ranges;
}
@end
@implementation SimCamFakeFormat
- (CMFormatDescriptionRef)formatDescription { return _desc; }
- (NSArray<AVFrameRateRange *> *)videoSupportedFrameRateRanges { return _ranges; }
- (AVMediaType)mediaType { return AVMediaTypeVideo; }
- (NSString *)description { return @"<SimCamFakeFormat>"; }
// Apps derive zoom from these (expo-camera: max^zoom); the real getters read
// ivars our fake lacks. No optical zoom, so the range is exactly 1×.
- (CGFloat)videoMaxZoomFactor { return 1.0; }
- (CGFloat)videoZoomFactorUpscaleThreshold { return 1.0; }
// AVFoundation pokes these simulator-internal getters during
// -[AVCaptureDeviceInput initWithDevice:] (via defaultSimulatedAperture); the
// real implementations read ivars our fake lacks and crash. Overriding
// defaultSimulatedAperture to a constant avoids the figCaptureSourceVideoFormat
// path entirely; the latter is neutralized too as a safety net.
- (float)defaultSimulatedAperture { return 0.0f; }
- (id)figCaptureSourceVideoFormat { return nil; }
@end

/// Reads the width/height of the current frame from the shared buffer header so
/// the reported format matches what we're actually streaming (correct preview
/// aspect). Falls back to 1280×720 before any frame exists.
static void SimCamCurrentFrameDims(int32_t *outW, int32_t *outH) {
    *outW = 1280; *outH = 720;
    int fd = open("/tmp/SimCam.bgra", O_RDONLY);
    if (fd < 0) return;
    uint32_t hdr[6] = {0};
    if (pread(fd, hdr, sizeof(hdr), 0) == (ssize_t)sizeof(hdr)) {
        uint32_t w = hdr[2], h = hdr[3];  // header offsets 8 (width), 12 (height)
        if (w > 0 && w <= 4096 && h > 0 && h <= 4096) { *outW = (int32_t)w; *outH = (int32_t)h; }
    }
    close(fd);
}

/// Shared fake format, rebuilt when the streamed frame size changes.
static AVCaptureDeviceFormat *SimCamSharedFakeFormat(void) {
    static SimCamFakeFormat *cached = nil;
    static int32_t cachedW = 0, cachedH = 0;
    int32_t w, h;
    SimCamCurrentFrameDims(&w, &h);
    if (cached != nil && cachedW == w && cachedH == h) return cached;

    CMVideoFormatDescriptionRef desc = NULL;
    if (CMVideoFormatDescriptionCreate(kCFAllocatorDefault,
            kCVPixelFormatType_32BGRA, w, h, NULL, &desc) != noErr || desc == NULL) {
        return cached;
    }
    SimCamFakeFormat *f = (SimCamFakeFormat *)class_createInstance([SimCamFakeFormat class], 0);
    f->_desc = desc;  // owned; retained for the lifetime of the cached format
    SimCamFakeFrameRateRange *range =
            (SimCamFakeFrameRateRange *)class_createInstance([SimCamFakeFrameRateRange class], 0);
    f->_ranges = @[range];
    cached = f;
    cachedW = w;
    cachedH = h;
    return f;
}

#pragma mark - Synthetic capture device

/// A stand-in `AVCaptureDevice`. It is never initialized through AVFoundation's
/// (unavailable) designated initializer — we allocate it with
/// `class_createInstance` and only override the getters that
/// `AVCaptureDeviceInput`, `AVCaptureSession`, and typical app setup code read.
@interface SimCamFakeDevice : AVCaptureDevice
@end

@implementation SimCamFakeDevice

- (NSString *)uniqueID { return @"com.kaarlmoroti.mockmycam.front"; }
- (NSString *)modelID { return @"MockMyCam Virtual Camera"; }
- (NSString *)localizedName { return @"MockMyCam Camera"; }
- (NSString *)manufacturer { return @"MockMyCam"; }
- (AVCaptureDeviceType)deviceType { return AVCaptureDeviceTypeBuiltInWideAngleCamera; }
- (AVCaptureDevicePosition)position { return AVCaptureDevicePositionFront; }
- (BOOL)hasMediaType:(AVMediaType)mediaType { return [mediaType isEqualToString:AVMediaTypeVideo]; }
- (BOOL)supportsAVCaptureSessionPreset:(AVCaptureSessionPreset)preset { return YES; }
- (BOOL)isConnected { return YES; }
- (BOOL)isSuspended { return NO; }
- (AVCaptureDeviceFormat *)activeFormat { return gSimCamSuppressFormats ? nil : SimCamSharedFakeFormat(); }
- (NSArray<AVCaptureDeviceFormat *> *)formats { return gSimCamSuppressFormats ? @[] : @[SimCamSharedFakeFormat()]; }

// Configuration is a no-op but must succeed: apps wrap focus/exposure/format
// changes in lockForConfiguration:/unlockForConfiguration, and may assign the
// active format / frame durations — all no-ops on the synthetic device.
- (BOOL)lockForConfiguration:(NSError **)outError { if (outError) *outError = nil; return YES; }
- (void)unlockForConfiguration {}
- (void)setActiveFormat:(AVCaptureDeviceFormat *)format {}
- (void)setActiveVideoMinFrameDuration:(CMTime)duration {}
- (void)setActiveVideoMaxFrameDuration:(CMTime)duration {}
- (CMTime)activeVideoMinFrameDuration { return CMTimeMake(1, 30); }
- (CMTime)activeVideoMaxFrameDuration { return CMTimeMake(1, 30); }

// Capability probes — apps gate feature setup on these; "unsupported" keeps
// them from configuring hardware we don't have.
- (BOOL)isFocusModeSupported:(AVCaptureFocusMode)mode { return NO; }
- (BOOL)isExposureModeSupported:(AVCaptureExposureMode)mode { return NO; }
- (BOOL)isWhiteBalanceModeSupported:(AVCaptureWhiteBalanceMode)mode { return NO; }
- (BOOL)hasTorch { return NO; }
- (BOOL)hasFlash { return NO; }
- (BOOL)isTorchModeSupported:(AVCaptureTorchMode)mode { return NO; }
- (BOOL)isTorchAvailable { return NO; }
- (BOOL)isFlashAvailable { return NO; }
- (BOOL)isFocusPointOfInterestSupported { return NO; }
- (BOOL)isExposurePointOfInterestSupported { return NO; }
- (BOOL)isSmoothAutoFocusSupported { return NO; }
- (BOOL)isLowLightBoostSupported { return NO; }
- (CGFloat)videoZoomFactor { return 1.0; }
- (CGFloat)minAvailableVideoZoomFactor { return 1.0; }
- (CGFloat)maxAvailableVideoZoomFactor { return 1.0; }
- (BOOL)isRampingVideoZoom { return NO; }

// Setters camera libraries call unconditionally inside lockForConfiguration
// (expo-camera sets videoZoomFactor on every session start). The real
// implementations validate against hardware state our fake doesn't have and
// throw ("Not supported by this device"), so they're accepted as no-ops.
- (void)setVideoZoomFactor:(CGFloat)factor {}
- (void)rampToVideoZoomFactor:(CGFloat)factor withRate:(float)rate {}
- (void)cancelVideoZoomRamp {}
- (AVCaptureFocusMode)focusMode { return AVCaptureFocusModeLocked; }
- (void)setFocusMode:(AVCaptureFocusMode)mode {}
- (void)setFocusPointOfInterest:(CGPoint)point {}
- (void)setSmoothAutoFocusEnabled:(BOOL)enabled {}
- (AVCaptureExposureMode)exposureMode { return AVCaptureExposureModeLocked; }
- (void)setExposureMode:(AVCaptureExposureMode)mode {}
- (void)setExposurePointOfInterest:(CGPoint)point {}
- (void)setExposureTargetBias:(float)bias completionHandler:(void (^)(CMTime))handler {
    if (handler) handler(kCMTimeInvalid);
}
- (AVCaptureWhiteBalanceMode)whiteBalanceMode { return AVCaptureWhiteBalanceModeLocked; }
- (void)setWhiteBalanceMode:(AVCaptureWhiteBalanceMode)mode {}
- (AVCaptureTorchMode)torchMode { return AVCaptureTorchModeOff; }
- (void)setTorchMode:(AVCaptureTorchMode)mode {}
- (BOOL)setTorchModeOnWithLevel:(float)level error:(NSError **)outError {
    if (outError) *outError = nil;
    return YES;
}
- (void)setSubjectAreaChangeMonitoringEnabled:(BOOL)enabled {}
- (void)setAutomaticallyEnablesLowLightBoostWhenAvailable:(BOOL)enabled {}
- (void)setAutomaticallyAdjustsVideoHDREnabled:(BOOL)enabled {}
- (void)setVideoHDREnabled:(BOOL)enabled {}

@end

static AVCaptureDevice *SimCamSharedFakeDevice(void) {
    static AVCaptureDevice *device = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        device = (AVCaptureDevice *)class_createInstance([SimCamFakeDevice class], 0);
    });
    return device;
}

#pragma mark - Swizzle helpers

static void SimCamReplaceClassMethod(Class cls, SEL sel, id block) {
    Method m = class_getClassMethod(cls, sel);
    if (m == NULL) return;
    method_setImplementation(m, imp_implementationWithBlock(block));
}

static void SimCamReplaceInstanceMethod(Class cls, SEL sel, id block) {
    Method m = class_getInstanceMethod(cls, sel);
    if (m == NULL) return;
    method_setImplementation(m, imp_implementationWithBlock(block));
}

static const void *kSimCamSessionRunningKey = &kSimCamSessionRunningKey;

#pragma mark - AVCaptureDeviceInput bypass

// -[AVCaptureDeviceInput initWithDevice:error:] inspects many simulator-internal
// AVCaptureDeviceFormat getters (defaultSimulatedAperture,
// isCinematicVideoCaptureSupported, …) that read ivars our synthetic format
// lacks — each one crashes. Instead of faking every getter (fragile) or
// bypassing the initializer (leaves the input half-built and unusable), we let
// the real initializer run with the format hidden — the init handles a
// format-less device fine — then re-expose the format afterward.
static IMP gOriginalInputInitWithDevice = NULL;
static id simcam_inputInitWithDevice(id self, SEL _cmd, id device, NSError **error) {
    if (device != nil && [device isKindOfClass:[SimCamFakeDevice class]]) {
        BOOL previous = gSimCamSuppressFormats;
        gSimCamSuppressFormats = YES;
        id result = ((id (*)(id, SEL, id, NSError **))gOriginalInputInitWithDevice)(self, _cmd, device, error);
        gSimCamSuppressFormats = previous;
        return result;
    }
    return ((id (*)(id, SEL, id, NSError **))gOriginalInputInitWithDevice)(self, _cmd, device, error);
}

#pragma mark - Install

void SimCamInstallCaptureShim(void) {
    Class deviceClass = NSClassFromString(@"AVCaptureDevice");
    if (deviceClass == nil) return;

    AVCaptureDevice *fake = SimCamSharedFakeDevice();

    // --- AVCaptureDevice discovery: vend the synthetic camera for video. ---
    SimCamReplaceClassMethod(deviceClass, @selector(defaultDeviceWithMediaType:),
        ^AVCaptureDevice *(id self, AVMediaType mediaType) {
            return [mediaType isEqualToString:AVMediaTypeVideo] ? fake : nil;
        });
    SimCamReplaceClassMethod(deviceClass, @selector(deviceWithUniqueID:),
        ^AVCaptureDevice *(id self, NSString *uid) { return fake; });
    SimCamReplaceClassMethod(deviceClass, @selector(devicesWithMediaType:),
        ^NSArray *(id self, AVMediaType mediaType) {
            return [mediaType isEqualToString:AVMediaTypeVideo] ? @[fake] : @[];
        });
    SimCamReplaceClassMethod(deviceClass, @selector(devices),
        ^NSArray *(id self) { return @[fake]; });

    // Newer entry point apps use directly.
    SimCamReplaceClassMethod(deviceClass, @selector(defaultDeviceWithDeviceType:mediaType:position:),
        ^AVCaptureDevice *(id self, AVCaptureDeviceType type, AVMediaType mediaType, AVCaptureDevicePosition pos) {
            return [mediaType isEqualToString:AVMediaTypeVideo] ? fake : nil;
        });

    // --- Authorization: report camera access as granted. ---
    SimCamReplaceClassMethod(deviceClass, @selector(authorizationStatusForMediaType:),
        ^AVAuthorizationStatus(id self, AVMediaType mediaType) { return AVAuthorizationStatusAuthorized; });
    SimCamReplaceClassMethod(deviceClass, @selector(requestAccessForMediaType:completionHandler:),
        ^(id self, AVMediaType mediaType, void (^handler)(BOOL)) { if (handler) handler(YES); });

    // --- Discovery session: report the synthetic camera. ---
    Class discoveryClass = NSClassFromString(@"AVCaptureDeviceDiscoverySession");
    if (discoveryClass) {
        SimCamReplaceInstanceMethod(discoveryClass, @selector(devices),
            ^NSArray *(id self) { return @[fake]; });
    }

    // iOS 17 preferred-camera entry points. Unhooked, they return the
    // simulator's own non-functional AVCaptureFigVideoDevice, which apps
    // (expo-camera) may pick over the discovery result.
    SimCamReplaceClassMethod(deviceClass, @selector(systemPreferredCamera),
        ^AVCaptureDevice *(id self) { return fake; });
    SimCamReplaceClassMethod(deviceClass, @selector(userPreferredCamera),
        ^AVCaptureDevice *(id self) { return fake; });

    // --- AVCaptureSession: accept the synthetic input and "run" without a
    //     real capture backend. The synthetic device has no real ports, so we
    //     swallow input/connection wiring; frames come from the injected
    //     sample-buffer / preview-layer drivers instead. ---
    Class sessionClass = NSClassFromString(@"AVCaptureSession");
    if (sessionClass) {
        SimCamReplaceInstanceMethod(sessionClass, @selector(canAddInput:),
            ^BOOL(id self, AVCaptureInput *input) { return YES; });
        SimCamReplaceInstanceMethod(sessionClass, @selector(addInput:),
            ^(id self, AVCaptureInput *input) { /* swallow — no real backend */ });
        SimCamReplaceInstanceMethod(sessionClass, @selector(canAddConnection:),
            ^BOOL(id self, AVCaptureConnection *c) { return YES; });
        SimCamReplaceInstanceMethod(sessionClass, @selector(addConnection:),
            ^(id self, AVCaptureConnection *c) { /* swallow */ });

        // startRunning on a session with only a data output and no real input
        // hangs in the simulator, so don't call through. Mark running and post
        // the notification apps may wait on.
        SimCamReplaceInstanceMethod(sessionClass, @selector(startRunning), ^(id self) {
            objc_setAssociatedObject(self, kSimCamSessionRunningKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [[NSNotificationCenter defaultCenter]
                postNotificationName:AVCaptureSessionDidStartRunningNotification object:self];
        });
        SimCamReplaceInstanceMethod(sessionClass, @selector(stopRunning), ^(id self) {
            objc_setAssociatedObject(self, kSimCamSessionRunningKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [[NSNotificationCenter defaultCenter]
                postNotificationName:AVCaptureSessionDidStopRunningNotification object:self];
        });
        SimCamReplaceInstanceMethod(sessionClass, @selector(isRunning), ^BOOL(id self) {
            NSNumber *running = objc_getAssociatedObject(self, kSimCamSessionRunningKey);
            return running.boolValue;
        });
    }

    // --- AVCaptureDeviceInput: bypass the crashing real init for our device. ---
    Class inputClass = NSClassFromString(@"AVCaptureDeviceInput");
    if (inputClass) {
        Method m = class_getInstanceMethod(inputClass, @selector(initWithDevice:error:));
        if (m) {
            gOriginalInputInitWithDevice = method_getImplementation(m);
            method_setImplementation(m, (IMP)simcam_inputInitWithDevice);
        }
    }

    NSLog(@"[SimCamInject] capture shim installed — synthetic camera vended");
}
