#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Makes `AVCaptureMetadataOutput` QR scanning work under injection.
///
/// The synthetic camera has no real capture backend, so a metadata output
/// never produces objects — and in the simulator it reports no available
/// types, so apps that filter their requested types by
/// `availableMetadataObjectTypes` (expo-camera) end up scanning for nothing.
///
/// This shim reports QR as available, accepts the app's requested types, and
/// attaches a driver to each output with a delegate: it decodes QR codes from
/// /tmp/SimCam.bgra with CoreImage's `CIDetector` (works in the simulator,
/// unlike Vision) and delivers synthetic `AVMetadataMachineReadableCodeObject`s
/// on the app's queue. `-[AVCaptureVideoPreviewLayer
/// transformedMetadataObjectForMetadataObject:]` maps them into layer
/// coordinates using the same fit/fill and mirror rules the preview driver uses.
void SimCamInstallMetadataShim(void);

NS_ASSUME_NONNULL_END
