import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    // 响应式下限：再小则布局不可用
    self.minSize = NSSize(width: 480, height: 480)

    RegisterGeneratedPlugins(registry: flutterViewController)
    // 桥注册放在这里：FlutterViewController 一定已就绪，MethodChannel 才能收到
    // Dart 侧调用（此前放在 AppDelegate.applicationDidFinishLaunching 里，
    // mainFlutterWindow?.contentViewController 可能仍为 nil，导致捕获等调用静默失败）。
    ZcodeBridge.shared.register(with: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}
