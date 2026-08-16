import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    true
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    // 单实例（与 Electron requestSingleInstanceLock 对齐）：多开的第二个实例
    // 激活已有窗口后退出。否则 zcode:// 登录回调可能被不在等待回调的实例截走，
    // 两实例的写盘/切换也会互相干扰。
    let ownPid = ProcessInfo.processInfo.processIdentifier
    let bundleId = Bundle.main.bundleIdentifier
    let others = NSWorkspace.shared.runningApplications.filter {
      $0.bundleIdentifier == bundleId && $0.processIdentifier != ownPid
    }
    if let existing = others.first {
      if #available(macOS 14.0, *) {
        existing.activate()
      } else {
        existing.activate(options: [.activateIgnoringOtherApps])
      }
      NSApp.terminate(nil)
      return
    }
    NSAppleEventManager.shared().setEventHandler(
      self,
      andSelector: #selector(handleURLEvent(_:withReplyEvent:)),
      forEventClass: AEEventClass(kInternetEventClass),
      andEventID: AEEventID(kAEGetURL)
    )
    NSLog("[zcodehelper] GURL handler registered")
    super.applicationDidFinishLaunching(notification)
  }

  @objc func handleURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
    NSLog("[zcodehelper] GURL event arrived")
    guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue else { return }
    ZcodeBridge.shared.handleOpenURL(urlString)
  }
}
