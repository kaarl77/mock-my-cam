#import "SimCamMetadataShim.h"
#import "SimCamSharedFrameReader.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

static NSString * const kSimCamSharedPath = @"/tmp/SimCam.bgra";
static const double kSimCamMetadataScansPerSecond = 10.0;

static const void *kSimCamMetadataTypesKey = &kSimCamMetadataTypesKey;
static const void *kSimCamMetadataDriverKey = &kSimCamMetadataDriverKey;

#pragma mark - Synthetic code object

/// A stand-in `AVMetadataMachineReadableCodeObject`. Allocated with
/// `class_createInstance` (no public initializer) and overrides only the
/// getters apps read. Geometry is normalized (0..1, top-left origin) in the
/// streamed frame's space until a preview layer transforms it.
@interface SimCamFakeCodeObject : AVMetadataMachineReadableCodeObject {
@public
    NSString *_scString;
    CGRect _scBounds;
    NSArray<NSValue *> *_scCorners;
    CGSize _scFrameSize;
    uint32_t _scFlags;
}
@end

@implementation SimCamFakeCodeObject
- (AVMetadataObjectType)type { return AVMetadataObjectTypeQRCode; }
- (NSString *)stringValue { return _scString; }
- (CGRect)bounds { return _scBounds; }
- (NSArray<NSDictionary *> *)corners {
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:_scCorners.count];
    for (NSValue *v in _scCorners) {
        CFDictionaryRef d = CGPointCreateDictionaryRepresentation(v.CGPointValue);
        [out addObject:(__bridge_transfer NSDictionary *)d];
    }
    return out;
}
- (CMTime)time { return CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000000000); }
- (CMTime)duration { return kCMTimeInvalid; }
- (CIBarcodeDescriptor *)descriptor { return nil; }
- (NSString *)description {
    return [NSString stringWithFormat:@"<SimCamFakeCodeObject QR \"%@\" %@>",
            _scString, NSStringFromCGRect(_scBounds)];
}
@end

static SimCamFakeCodeObject *SimCamMakeCodeObject(NSString *string, CGRect bounds,
                                                  NSArray<NSValue *> *corners,
                                                  CGSize frameSize, uint32_t flags) {
    SimCamFakeCodeObject *o =
            (SimCamFakeCodeObject *)class_createInstance([SimCamFakeCodeObject class], 0);
    o->_scString = [string copy];
    o->_scBounds = bounds;
    o->_scCorners = [corners copy];
    o->_scFrameSize = frameSize;
    o->_scFlags = flags;
    return o;
}

#pragma mark - Driver

/// One per hooked metadata output: polls the shared buffer, decodes QR codes
/// off the app's queues, and delivers them to the delegate on its queue.
@interface SimCamMetadataDriver : NSObject
- (instancetype)initWithOutput:(AVCaptureMetadataOutput *)output
                      delegate:(id<AVCaptureMetadataOutputObjectsDelegate>)delegate
                         queue:(dispatch_queue_t)queue;
- (void)start;
- (void)stop;
@end

@implementation SimCamMetadataDriver {
    __weak AVCaptureMetadataOutput *_output;
    __weak id<AVCaptureMetadataOutputObjectsDelegate> _delegate;
    dispatch_queue_t _deliveryQueue;
    dispatch_queue_t _scanQueue;
    dispatch_source_t _timer;
    SimCamSharedFrameReader *_reader;
    CIDetector *_detector;
}

- (instancetype)initWithOutput:(AVCaptureMetadataOutput *)output
                      delegate:(id<AVCaptureMetadataOutputObjectsDelegate>)delegate
                         queue:(dispatch_queue_t)queue {
    if ((self = [super init])) {
        _output = output;
        _delegate = delegate;
        _deliveryQueue = queue;
        _scanQueue = dispatch_queue_create("com.kaarlmoroti.mockmycam.metadata", DISPATCH_QUEUE_SERIAL);
        _reader = [[SimCamSharedFrameReader alloc] initWithPath:kSimCamSharedPath];
        _detector = [CIDetector detectorOfType:CIDetectorTypeQRCode
                                       context:[CIContext contextWithOptions:nil]
                                       options:@{ CIDetectorAccuracy: CIDetectorAccuracyHigh }];
    }
    return self;
}

- (void)dealloc { [self stop]; }

- (void)start {
    if (_timer != nil) return;
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _scanQueue);
    uint64_t interval = (uint64_t)(NSEC_PER_SEC / kSimCamMetadataScansPerSecond);
    dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, 0), interval, interval / 10);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_timer, ^{ [weakSelf tick]; });
    dispatch_resume(_timer);
}

- (void)stop {
    if (_timer != nil) {
        dispatch_source_cancel(_timer);
        _timer = nil;
    }
}

- (void)tick {
    AVCaptureMetadataOutput *output = _output;
    id<AVCaptureMetadataOutputObjectsDelegate> delegate = _delegate;
    if (output == nil || delegate == nil) { [self stop]; return; }
    if (![output.metadataObjectTypes containsObject:AVMetadataObjectTypeQRCode]) return;

    UIImage *frame = [_reader latestImage];
    if (frame.CGImage == NULL) return;
    uint32_t flags = _reader.latestFlags;
    CIImage *image = [CIImage imageWithCGImage:frame.CGImage];
    CGRect extent = image.extent;
    if (extent.size.width <= 0 || extent.size.height <= 0) return;

    NSMutableArray *objects = [NSMutableArray array];
    for (CIFeature *feature in [_detector featuresInImage:image]) {
        if (![feature isKindOfClass:[CIQRCodeFeature class]]) continue;
        CIQRCodeFeature *qr = (CIQRCodeFeature *)feature;
        if (qr.messageString.length == 0) continue;
        // CoreImage is bottom-left origin in pixels; metadata objects are
        // top-left origin, normalized.
        CGFloat w = extent.size.width, h = extent.size.height;
        CGPoint (^norm)(CGPoint) = ^CGPoint(CGPoint p) {
            return CGPointMake(p.x / w, 1.0 - p.y / h);
        };
        CGRect b = qr.bounds;
        CGRect bounds = CGRectMake(b.origin.x / w, 1.0 - CGRectGetMaxY(b) / h,
                                   b.size.width / w, b.size.height / h);
        NSArray *corners = @[
            [NSValue valueWithCGPoint:norm(qr.topLeft)],
            [NSValue valueWithCGPoint:norm(qr.topRight)],
            [NSValue valueWithCGPoint:norm(qr.bottomRight)],
            [NSValue valueWithCGPoint:norm(qr.bottomLeft)],
        ];
        [objects addObject:SimCamMakeCodeObject(qr.messageString, bounds, corners, extent.size, flags)];
    }
    if (objects.count == 0) return;

    dispatch_async(_deliveryQueue, ^{
        if (![delegate respondsToSelector:@selector(captureOutput:didOutputMetadataObjects:fromConnection:)]) return;
        AVCaptureConnection *connection = output.connections.firstObject;
        [delegate captureOutput:output didOutputMetadataObjects:objects fromConnection:connection];
    });
}

@end

#pragma mark - Preview-layer coordinate transform

/// Maps a normalized frame-space point into the layer the way the preview
/// driver draws the frame: aspect-fill or aspect-fit (header flag), centered,
/// optionally mirrored horizontally.
static CGPoint SimCamLayerPoint(CGPoint p, CGRect layerBounds, CGSize frame, uint32_t flags) {
    CGFloat sx = layerBounds.size.width / frame.width;
    CGFloat sy = layerBounds.size.height / frame.height;
    CGFloat scale = (flags & kSimCamFlagFillGravity) ? MAX(sx, sy) : MIN(sx, sy);
    CGSize shown = CGSizeMake(frame.width * scale, frame.height * scale);
    CGFloat ox = CGRectGetMidX(layerBounds) - shown.width / 2.0;
    CGFloat oy = CGRectGetMidY(layerBounds) - shown.height / 2.0;
    CGFloat x = (flags & kSimCamFlagMirror) ? 1.0 - p.x : p.x;
    return CGPointMake(ox + x * shown.width, oy + p.y * shown.height);
}

static IMP gOriginalTransformedMetadataObject = NULL;
static id simcam_transformedMetadataObject(CALayer *self, SEL _cmd, AVMetadataObject *object) {
    if (![object isKindOfClass:[SimCamFakeCodeObject class]]) {
        return ((id (*)(id, SEL, id))gOriginalTransformedMetadataObject)(self, _cmd, object);
    }
    SimCamFakeCodeObject *src = (SimCamFakeCodeObject *)object;
    CGRect layerBounds = self.bounds;
    NSMutableArray *corners = [NSMutableArray arrayWithCapacity:src->_scCorners.count];
    CGFloat minX = CGFLOAT_MAX, minY = CGFLOAT_MAX, maxX = -CGFLOAT_MAX, maxY = -CGFLOAT_MAX;
    for (NSValue *v in src->_scCorners) {
        CGPoint p = SimCamLayerPoint(v.CGPointValue, layerBounds, src->_scFrameSize, src->_scFlags);
        [corners addObject:[NSValue valueWithCGPoint:p]];
        minX = MIN(minX, p.x); minY = MIN(minY, p.y);
        maxX = MAX(maxX, p.x); maxY = MAX(maxY, p.y);
    }
    CGRect bounds = corners.count ? CGRectMake(minX, minY, maxX - minX, maxY - minY) : CGRectZero;
    return SimCamMakeCodeObject(src->_scString, bounds, corners, src->_scFrameSize, src->_scFlags);
}

#pragma mark - AVCaptureMetadataOutput hooks

static IMP gOriginalSetMetadataObjectsDelegate = NULL;
static void simcam_setMetadataObjectsDelegate(id self, SEL _cmd,
        id<AVCaptureMetadataOutputObjectsDelegate> delegate, dispatch_queue_t queue) {
    ((void (*)(id, SEL, id, dispatch_queue_t))gOriginalSetMetadataObjectsDelegate)(self, _cmd, delegate, queue);

    SimCamMetadataDriver *existing = objc_getAssociatedObject(self, kSimCamMetadataDriverKey);
    [existing stop];
    objc_setAssociatedObject(self, kSimCamMetadataDriverKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (delegate == nil || queue == nil) return;

    SimCamMetadataDriver *driver = [[SimCamMetadataDriver alloc] initWithOutput:self
                                                                       delegate:delegate
                                                                          queue:queue];
    objc_setAssociatedObject(self, kSimCamMetadataDriverKey, driver, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [driver start];
    NSLog(@"[SimCamInject] AVCaptureMetadataOutput delegate hooked (%@)", NSStringFromClass([delegate class]));
}

static void SimCamReplaceInstanceMethod(Class cls, SEL sel, id block) {
    Method m = class_getInstanceMethod(cls, sel);
    if (m == NULL) return;
    method_setImplementation(m, imp_implementationWithBlock(block));
}

void SimCamInstallMetadataShim(void) {
    Class outputClass = NSClassFromString(@"AVCaptureMetadataOutput");
    if (outputClass == nil) return;

    // Only QR is decodable here; reporting it lets apps that filter their
    // requested types by availability (expo-camera) keep it.
    SimCamReplaceInstanceMethod(outputClass, @selector(availableMetadataObjectTypes),
        ^NSArray *(id self) { return @[AVMetadataObjectTypeQRCode]; });
    // The real setter validates against the (empty) hardware list and throws,
    // so requested types are stored as-is.
    SimCamReplaceInstanceMethod(outputClass, @selector(setMetadataObjectTypes:),
        ^(id self, NSArray *types) {
            objc_setAssociatedObject(self, kSimCamMetadataTypesKey, [types copy],
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        });
    SimCamReplaceInstanceMethod(outputClass, @selector(metadataObjectTypes),
        ^NSArray *(id self) { return objc_getAssociatedObject(self, kSimCamMetadataTypesKey) ?: @[]; });

    Method setDelegate = class_getInstanceMethod(outputClass, @selector(setMetadataObjectsDelegate:queue:));
    if (setDelegate) {
        gOriginalSetMetadataObjectsDelegate =
                method_setImplementation(setDelegate, (IMP)simcam_setMetadataObjectsDelegate);
    }

    Class previewLayerClass = NSClassFromString(@"AVCaptureVideoPreviewLayer");
    Method transform = previewLayerClass
            ? class_getInstanceMethod(previewLayerClass, @selector(transformedMetadataObjectForMetadataObject:))
            : NULL;
    if (transform) {
        gOriginalTransformedMetadataObject =
                method_setImplementation(transform, (IMP)simcam_transformedMetadataObject);
    }

    NSLog(@"[SimCamInject] metadata shim installed (QR via CIDetector)");
}
