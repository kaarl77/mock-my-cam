// SimProbe — a minimal iOS app used to verify camera injection.
//
// It puts an AVCaptureVideoPreviewLayer on screen and assigns it a session,
// which triggers the injected dylib's swizzled `-[AVCaptureVideoPreviewLayer
// setSession:]` hook. With injection working, the layer shows MockMyCam's frames;
// without it, the magenta background shows through (an obvious failure signal).
import UIKit
import AVFoundation

final class ViewController: UIViewController {
    private let previewLayer = AVCaptureVideoPreviewLayer()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .magenta
        let session = AVCaptureSession()
        previewLayer.session = session            // triggers the swizzled setSession:
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer.frame = view.bounds
    }
}

// iOS 27 terminates apps that haven't adopted the UIScene lifecycle, so the
// window is owned by a scene delegate (declared in Info.plist's scene manifest
// under this Objective-C name) rather than the app delegate.
@objc(SimProbeSceneDelegate)
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene,
               willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = ViewController()
        window.makeKeyAndVisible()
        self.window = window
    }
}

final class AppDelegate: UIResponder, UIApplicationDelegate {}

UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(AppDelegate.self))
