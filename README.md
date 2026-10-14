# MockMyCam

A macOS menu-bar app that feeds a **fake camera into the running iOS Simulator** — so a
simulator app sees a "real" camera where Apple normally provides none. Use your Mac's
webcam as a live feed, or mock an image / looped video.

<p align="center">
  <strong>🌐 <a href="https://mockmycam.kaarlmoroti.com/">mockmycam.kaarlmoroti.com</a></strong><br>
  <em>Webcam · Image · Video → /tmp/SimCam.bgra → injected into the sim's AVFoundation</em>
</p>

## How it works

```
webcam / image / video  →  BGRAConverter  →  FramePipeline  →  SharedFrameWriter  →  /tmp/SimCam.bgra (mmap)
                                                                                            │ reads
menu-bar UI  →  DylibInstaller + SimulatorController (xcrun simctl)  ──inject──►  VirtualCamera.dylib (in the sim app)
```

- MockMyCam writes BGRA frames into a memory-mapped file (`/tmp/SimCam.bgra`). `/tmp` inside
  the simulator is the host's `/private/tmp`, so the same bytes are visible to both.
- It injects `VirtualCamera.dylib` into a simulator app via
  `xcrun simctl spawn <udid> launchctl setenv DYLD_INSERT_LIBRARIES …`. The dylib vends a
  **synthetic `AVCaptureDevice`** (the iOS 26 simulator ships none), makes `AVCaptureSession`
  accept it, and feeds frames through `AVCaptureVideoDataOutput` sample buffers — so apps that
  build a real capture session (Flutter, react-native-vision-camera, scanners) work. It also
  swizzles `AVCaptureVideoPreviewLayer` (and photo capture / image picker) for preview-layer apps.
- The dylib is **vendored from [baguette](https://github.com/tddworks/baguette)** (Apache-2.0).
  We build it from source (`Scripts/build-dylib.sh`) and bundle it; see `ThirdParty/VirtualCamera/`.

## Requirements

- Apple Silicon Mac, macOS 14+
- Xcode 16+ with an iOS Simulator runtime (tested on Xcode 27.1 / iOS 27.0 and 27.1)

## Build & run

```bash
make app     # builds the dylib + release app → build/MockMyCam.app
make run     # launches it (menu-bar icon: camera.viewfinder)
```

## Installing a downloaded build

MockMyCam isn't yet signed with an Apple Developer ID or notarized, so a build
downloaded from the web is quarantined and Gatekeeper refuses to open it
("Apple could not verify…"). After moving `MockMyCam.app` to `/Applications`,
clear the quarantine flag:

```bash
xattr -dr com.apple.quarantine /Applications/MockMyCam.app
```

(Or open it once via **System Settings ▸ Privacy & Security ▸ Open Anyway**.)
Building from source with `make app` doesn't have this issue.

## Using it

1. **Boot a simulator** (Xcode ▸ Open Developer Tool ▸ Simulator, or run your app once).
2. Click the menu-bar icon and pick your **Simulator** from the dropdown.
3. Pick a **source**: Webcam (choose a camera), Image, or Video. Click **Start**.
   You'll see a live preview of the outgoing feed.
4. Click **Arm** — installs + injects the dylib into the selected simulator.
5. Click **Relaunch app…** and choose your app. It relaunches with the camera injected.
   *(Apps must be (re)launched **after** arming — `DYLD_INSERT_LIBRARIES` only applies at launch.
   Launching from Xcode after arming works too.)*
6. **Mirror** / **Fill** toggle how the frame is displayed in the sim.

On first webcam use, macOS asks for camera permission (System Settings ▸ Privacy ▸ Camera).

## Known limitations

- **Metadata (QR/barcode) output not hooked yet.** The dylib now vends a synthetic
  `AVCaptureDevice` and delivers frames through `AVCaptureVideoDataOutput` sample buffers
  (Flutter, `react-native-vision-camera`, most camera/scanner apps) as well as
  `AVCaptureVideoPreviewLayer`, `AVCapturePhotoOutput`, and `UIImagePickerController`.
  Apps that scan codes via `AVCaptureMetadataOutput` (rather than reading the sample buffers
  themselves) don't get synthetic metadata objects yet — that hook can be added next.
- **Camera permission prompt.** Because the app now drives a real `AVCaptureSession`, iOS
  shows its normal "… would like to access the Camera" prompt on first use. Tap **Allow** once;
  frames are delivered regardless of the outcome (there's no real hardware behind it).
- **One simulator at a time** (single shared `/tmp/SimCam.bgra`).
- **Relaunch required** after arming (inherent to DYLD injection).
- EXIF-rotated still images use their stored orientation (rotation not yet auto-applied).

## Verifying

```bash
make test    # unit tests (deterministic; E2E + webcam tests are gated/skipped)
make e2e     # on-simulator end-to-end: injects a frame, screenshots, asserts pixels
             #   (needs a booted simulator)
```

The E2E suite proves the whole pipe on a real simulator: it feeds a solid color and a
red-top/blue-bottom image, then screenshots the sim and asserts the rendered pixels (incl.
orientation). Live webcam capture: `MOCKMYCAM_WEBCAM=1 swift test --filter WebcamFrameProviderTests`
(needs camera access granted to the test runner).

## Licensing

MockMyCam is licensed under the Apache License 2.0 (see `LICENSE` and `NOTICE`). It bundles `VirtualCamera.dylib`, built from sources
vendored from baguette under the Apache License 2.0 — see `ThirdParty/VirtualCamera/LICENSE`
and `ThirdParty/VirtualCamera/NOTICE`.
