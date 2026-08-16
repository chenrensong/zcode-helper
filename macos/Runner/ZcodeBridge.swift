import Cocoa
import FlutterMacOS
import WebKit

/// Flutter 与 macOS 原生能力之间的桥：进程枚举/结束、ZCode 启动、
/// 打开系统浏览器、主机身份（真实 home / 用户名）、zcode:// 协议
/// 登录回调的接管与转发。
///
/// 单例：注册在 MainFlutterWindow.awakeFromNib（模板新式时序，FlutterViewController
/// 一定存在），AppDelegate 不再自行注册，避免 channel 未就绪导致 Dart 侧调用静默失败。
class ZcodeBridge {
    static let shared = ZcodeBridge()
    private init() {}

    static let channelName = "zcode.helper/bridge"

    private var channel: FlutterMethodChannel?

    private static let logQueue = DispatchQueue(label: "zcodehelper.bridge.log")

    /// 诊断日志：~/Library/Logs/zcode-helper.log（与 Dart 侧 appLog 同文件）。
    private func log(_ message: String) {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs", isDirectory: true)
        guard let dir else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(stamp)] [bridge] \(message)\n"
        Self.logQueue.async {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("zcode-helper.log")
            if let handle = FileHandle(forWritingAtPath: url.path) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    func register(with messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
        self.channel = channel
        log("bridge registered pid=\(ProcessInfo.processInfo.processIdentifier)")
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self = self else {
                result(nil)
                return
            }
            let args = call.arguments as? [String: Any]
            switch call.method {
            case "listRunningZcode":
                result(self.runningZcodeList())
            case "launchZCode":
                self.launchZCode(path: args?["path"] as? String, result: result)
            case "terminatePids":
                let pids = (args?["pids"] as? [Int]) ?? []
                result(self.terminate(pids: pids))
            case "openUrl":
                let url = (args?["url"] as? String) ?? ""
                result(self.openUrl(url))
            case "hostIdentity":
                result(self.hostIdentity())
            case "openOAuthWindow":
                let url = (args?["url"] as? String) ?? ""
                let title = (args?["title"] as? String) ?? "登录"
                self.openOAuthWindow(url: url, title: title, result: result)
            case "closeOAuthWindow":
                OAuthWebWindowController.shared.close(notify: false)
                result(true)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    /// 应用内 OAuth 窗口：WKWebView 拦截 zcode:// 回调（不经系统协议路由，
    /// 不需要关 ZCode / 接管协议），复用 onOAuthCallback 通路送达 Dart。
    private func openOAuthWindow(url: String, title: String, result: @escaping FlutterResult) {
        guard !url.isEmpty, URL(string: url) != nil else {
            result(false)
            return
        }
        log("openOAuthWindow (authorize url, query omitted)")
        OAuthWebWindowController.shared.open(
            urlString: url,
            title: title,
            onIntercept: { [weak self] urlString in
                self?.handleOpenURL(urlString)
            },
            onClosed: { [weak self] in
                self?.log("oauth window closed by user")
                self?.channel?.invokeMethod("onOAuthWindowClosed", arguments: nil)
            }
        )
        result(true)
    }

    /// zcode:// 回调到达：应用内 OAuth 窗口拦截，或 AppDelegate 转发的
    /// GURL AppleEvent（兜底）。Dart 侧校验 state 后换 token。
    func handleOpenURL(_ urlString: String) {
        // 回调 url 含授权码，日志只记长度。
        log("GURL received (len=\(urlString.count))")
        channel?.invokeMethod("onOAuthCallback", arguments: ["url": urlString])
    }

    /// 主机身份：getpwuid 返回真实 home 与用户名（ZCode 凭据的 enc:v1 密钥用
    /// 真实 home 派生）。
    private func hostIdentity() -> [String: String] {
        guard let pw = getpwuid(getuid()) else { return [:] }
        let home = pw.pointee.pw_dir.flatMap { String(validatingUTF8: $0) } ?? ""
        let user = pw.pointee.pw_name.flatMap { String(validatingUTF8: $0) } ?? ""
        guard !home.isEmpty else { return [:] }
        return ["home": home, "user": user.isEmpty ? NSUserName() : user]
    }

    private func openUrl(_ url: String) -> Bool {
        guard let parsed = URL(string: url) else { return false }
        return NSWorkspace.shared.open(parsed)
    }

    /// 枚举 ZCode 主进程（一个主进程即一个实例），与 Electron 版
    /// instance.js parsePosixZCodeProcesses 的 /^ZCode(\s+\[...\])?$/ 语义对齐。
    /// helper/CLI 子进程（dev.zcode.app.helper）、Safari AutoFill、本应用自身
    /// 均不算实例。
    private func runningZcodeList() -> [[String: Any]] {
        let ownPid = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications.filter { app in
            guard app.processIdentifier != ownPid else { return false }
            let name = app.localizedName ?? ""
            let bundle = app.bundleIdentifier ?? ""
            let exec = app.executableURL?.lastPathComponent ?? ""
            let isMainProcess = bundle == "dev.zcode.app"
                || (exec == "ZCode"
                    && name.range(of: "^ZCode(?:\\s+\\[[^\\]]+\\])?$", options: .regularExpression) != nil)
            return isMainProcess
        }
        return apps.map { app in
            var dict: [String: Any] = [
                "pid": Int(app.processIdentifier),
                "name": app.localizedName ?? "ZCode",
            ]
            if let bundleId = app.bundleIdentifier { dict["bundleId"] = bundleId }
            if let url = app.executableURL { dict["path"] = url.path }
            return dict
        }
    }

    private func launchZCode(path: String?, result: @escaping FlutterResult) {
        let configuration = NSWorkspace.OpenConfiguration()
        if let path = path, !path.isEmpty {
            // ZCode 可执行文件在 .app 包内：openApplication 必须给 .app 的 URL，
            // 直接给内层可执行文件会被当“文档”用 Terminal 打开（实测复现）。
            let url = URL(fileURLWithPath: path)
            let contents = url.deletingLastPathComponent().deletingLastPathComponent()
            if contents.pathExtension == "app" {
                NSWorkspace.shared.openApplication(at: contents, configuration: configuration) { _, error in
                    DispatchQueue.main.async { result(error == nil) }
                }
                return
            }
            // 非 .app 内路径：直接拉起可执行文件（与 Electron exec 行为一致）。
            let proc = Process()
            proc.executableURL = url
            proc.standardInput = FileHandle.nullDevice
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            let ran = (try? proc.run()) != nil
            DispatchQueue.main.async { result(ran) }
            return
        }
        // 已知 bundle id 候选（本机实测 ZCode 客户端为 dev.zcode.app）
        for bundleId in ["dev.zcode.app", "com.zte.zcode", "com.zcode.ZCode"] {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                    DispatchQueue.main.async { result(error == nil) }
                }
                return
            }
        }
        // 兜底：按已知路径实例启动（lastPathComponent 含 ZCode）
        let candidates = NSWorkspace.shared.runningApplications.compactMap { $0.executableURL }
            .filter { $0.lastPathComponent.hasPrefix("ZCode") }
        if let url = candidates.first {
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                DispatchQueue.main.async { result(error == nil) }
            }
            return
        }
        result(false)
    }

    private func terminate(pids: [Int]) -> [String: Bool] {
        var out: [String: Bool] = [:]
        for pid in pids {
            guard let app = NSRunningApplication(processIdentifier: pid_t(pid)) else {
                out["\(pid)"] = false
                continue
            }
            out["\(pid)"] = app.terminate()
        }
        return out
    }
}

/// 应用内 OAuth 登录窗口。
///
/// WKWebView 加载授权页，在导航决策层直接拦截 `zcode://` 回调
/// （cancel 掉导航、取 URL 上报），不经过系统协议路由——因此登录
/// 无需关闭运行中的 ZCode，也无需接管 zcode:// 默认处理器。
///
/// 窗口常驻复用：isReleasedWhenClosed = false，关闭只 orderOut 隐藏。
/// （代码创建的 NSWindow 默认 isReleasedWhenClosed = true，close() 时
/// AppKit 会释放窗口；若在关闭动画进行中释放会触发
/// _NSWindowTransformAnimation dealloc 的 SIGSEGV，实测崩溃过两次。）
class OAuthWebWindowController: NSObject, WKNavigationDelegate, NSWindowDelegate {
    static let shared = OAuthWebWindowController()

    private var window: NSWindow?
    private var webView: WKWebView?
    private var onIntercept: ((String) -> Void)?
    private var onClosed: (() -> Void)?
    private var delivered = false

    /// 打开（或替换）登录窗口并加载授权页。
    func open(
        urlString: String,
        title: String,
        onIntercept: @escaping (String) -> Void,
        onClosed: @escaping () -> Void
    ) {
        // 上一轮窗口若还开着，先按“用户关闭”结算（回调旧会话的 onCancelled）。
        if window?.isVisible == true {
            close(notify: true)
        }
        guard let url = URL(string: urlString) else { return }
        delivered = false
        self.onIntercept = onIntercept
        self.onClosed = onClosed

        if window == nil {
            let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 700))
            wv.navigationDelegate = self
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 700),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = wv
            window = w
            webView = wv
        }
        window?.title = title
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        webView?.load(URLRequest(url: url))
    }

    /// 隐藏窗口。[notify] 为 true 且尚未交付结果时触发 onClosed（取消）。
    func close(notify: Bool = true) {
        guard let window else { return }
        window.orderOut(nil)
        if notify && !delivered {
            delivered = true
            onClosed?()
        }
        onIntercept = nil
        onClosed = nil
    }

    // MARK: - WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if let url = navigationAction.request.url, url.scheme?.lowercased() == "zcode" {
            decisionHandler(.cancel)
            guard !delivered else { return }
            delivered = true
            let intercepted = url.absoluteString
            DispatchQueue.main.async { [weak self] in
                self?.onIntercept?(intercepted)
                self?.close(notify: false)
            }
            return
        }
        decisionHandler(.allow)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // 用户点了关闭按钮（isReleasedWhenClosed=false，窗口仅隐藏可复用）。
        if !delivered {
            delivered = true
            onClosed?()
        }
        onIntercept = nil
        onClosed = nil
    }
}
