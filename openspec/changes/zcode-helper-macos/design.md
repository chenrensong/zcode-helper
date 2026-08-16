## Context

The Electron tool stores ZCode login state at `~/.zcode/v2/{credentials.json,
config.json, setting.json}` with `enc:v1` AES-256-GCM ciphertext derived from a
machine-bound secret. Switching works by snapshotting those files and replacing
them under a stopped ZCode, then relaunching. The Mac App Store requires App
Sandbox, which forbids terminating other applications and unrestricted access
to the user's home directory. Two parallel distribution targets therefore
share one codebase.

## Goals / Non-Goals

**Goals**

- Byte-compatible with the existing snapshot format and crypto so old snapshots
  remain usable and the new quota logic matches.
- A Mac App Store build that is functionally complete for capture, switch
  (guided quit), quota, rollback, and read-only instance status.
- A Developer ID build that additionally offers auto-restart and managed
  multi-instances.

**Non-Goals**

- An iOS/Windows port.
- A networkless offline quota cache.
- WebView-based embedded login (browser + loopback keeps the App Store audit
  surface small and the flow immune to ZCode claiming `zcode://`).

## Decisions

### Dart crypto port with `cryptography`

`package:cryptography` provides AES-GCM (12-byte nonce, 16-byte MAC) and
SHA-256 in pure Dart. The wire format stays `enc:v1:<nonce>.<tag>.<cipher>` in
base64url, keyed by `sha256(ZCODE_CREDENTIAL_SECRET || fallback secret)`, so
cross-version round-trips with the Electron tool are verified by a fixture
test generated from the Node implementation.

### Sandbox detection via environment

The Swift bridge reports `isSandboxed` by reading
`APP_SANDBOX_CONTAINER_ID`. All behavior branches on that single flag:
auto-restart + instance management only when false.

### Scoped folder access with security-scoped bookmarks

The sandboxed app asks the user to select the ZCode data directory
(`~/.zcode`). The chosen URL is stored as a base64 bookmark in `UserDefaults`;
before every login-associated read/write the app calls `startAccessingSecurityScopedResource`.
If the selected folder directly contains `credentials.json` it is treated as
the `v2` level, otherwise `v2/` is appended.

### Process discovery and control via NSWorkspace

`NSWorkspace.shared.runningApplications` is sandbox-friendly and returns
PIDs/names for running instances; matching uses localized name `ZCode` or
`ZCode [<label>]` and excludes the helper app itself. `NSRunningApplication.terminate()`
is used only in non-sandboxed builds; in the sandbox the switch flow polls
until the user quits ZCode.

### Provider config normalization ported verbatim

`PROVIDERS`, `updateConfigProviders`, settings-domain writes, and the BigModel
native profile migration replicate `src/oauth.js`/`src/switcher.js`, including
the in-memory legacy `user_info` migration that keeps tokens untouched.

### Services are plain Dart, UI observes them

No state-management package: one `Services` bundle (paths, store, switcher,
quota, instances, platform bridge) is constructed in `main` and passed to the
widget tree. Pure logic (crypto, fingerprint, merges, config normalization)
takes explicit paths so tests run on temporary directories without a sandbox.

## Risks / Trade-offs

- [MAS review may question managing another app's user data] → the app touches
  only files the user explicitly grants access to; help screens explain this.
- [Guided quit is slower than auto-restart] → progress is surfaced and cancel
  is always available; Developer ID build keeps the fast path.
- [`cryptography` is pure Dart and slower than CommonCrypto] → only run on
  small JSON blobs at capture/switch time; acceptable.
- [ZCode changes process naming] → discovery matches conservatively and the
  status card reports fewer instances rather than wrong ones.

### OAuth login without the custom scheme

ZCode registers `zcode://oauth/callback` while running and a sandbox cannot
re-register it, so login must not rely on it. Instead the app starts a local
loopback server (`127.0.0.1:<random port>`), opens the provider authorize page
in the system browser with `response_type=code` and a CSRF `state`, and
receives the callback locally (`network.server` entitlement), with a manual
code-paste fallback for browsers that capture the redirect. The method channel
also exposes `openUrl` and `hostIdentity`; the latter reads `getpwuid` so the
crypto fallback secret binds to the **real** home directory even when the
sandboxed `$HOME` is a container path. Two providers share one token endpoint
but differ in authorize URL and response shape (Z.ai: `data.zai.access_token`
+ business login; BigModel: `data.bigmodel.access_token` +
`getCustomerInfo` with a non-Bearer header + coding-plan key derivation).
Write → capture snapshot → restore prior live files keeps the tool UI in sync
with disk.

### Bridge registration timing fix

Capturing used to be a silent no-op because the bridge was registered from
`applicationDidFinishLaunching`, where `contentViewController` can still be
nil. Registration now lives in `MainFlutterWindow.awakeFromNib` right after
`RegisterGeneratedPlugins`, with `ZcodeBridge.shared` as a singleton.

## Migration Plan

1. Ship `zcode-helper` v1 for macOS (MAS sandboxed profile first).
2. Publish Developer ID build profile with auto-restart + managed instances.
3. OAuth add-account flow ships for both providers (Z.ai / BigModel) using the
   browser + loopback design above; an iOS companion is optional backlog.

## 验证结果（2026-08-15）

- `flutter analyze`：0 issues。
- `flutter test`：36/36 通过（加密交叉夹具、指纹/健康、快照存储、切换/回滚、
  沙箱引导式切换与超时/取消、BigModel profile 迁移与 coding-plan key 派生、
  quota 三分支（thumb/usage/billing）、实例合并、组件冒烟）。
- `flutter build macos --release` 成功，产物
  `build/macos/Build/Products/Release/zcode_helper.app`（约 44MB）。
- 产物 entitlements 复核：`com.apple.security.app-sandbox=true`、
  `com.apple.security.network.client=true`、
  `com.apple.security.files.user-selected.read-write=true`。
  Info.plist：`CFBundleDisplayName=ZCode Helper`、
  `CFBundleIdentifier=com.zcodehelper.zcodehelper`。
- 实现要点：Swift 桥为 `macos/Runner/ZcodeBridge.swift`（NSWorkspace 进程枚举/
  结束、安全作用域目录选择与 bookmark 持久化），Android 无关；UI 三个页面
  （账号/实例/设置）由 `lib/ui/*` 实现，切换进度对话框支持沙箱引导式退出与取消。
- 已知限制：沙箱版不自动拉起 ZCode（用户手动启动）；bigmodel-api-key 派生
  依赖 open.bigmodel.cn 网络，离线时保留原 key 不动；OAuth 需要
  `network.client` + `network.server` 权限（已加入 MAS entitlements）。

## 验证结果 2（2026-08-15，OAuth 登录 + 捕获修复）

- `flutter analyze`：0 issues。
- `flutter test`：51/51 通过（新增 15 个：双 provider 授权 URL 构建、
  zai/bigmodel 交换响应形状与请求体、business login、getCustomerInfo 带
  非 Bearer 头、手动授权码端到端登录×2、写盘产物（加密/语义/setting 族）、
  restoreLive、取消→SwitchAborted、profile 规整；修正了几处过时断言以匹配
  Electron 版语义）。
- `flutter build macos --release`：成功，无 Swift 警告。
  （Swift `launchApplication` 弃用告警改用 `openApplication(at:configuration:)`。）
- 真实运行：a）`openUrl`/`hostIdentity` 原生方法加入并注册于
  MainFlutterWindow，修复捕获静默失败；b）loopback 回调服务器修复
  （start 不再关闭回调控制器，否则监听立即 onDone 被误判为取消）；c）密钥
  override 让沙箱版用真实 home 派生 enc:v1 密钥。
- 已知限制见上文；`zcode://` 自定义协议方案因 ZCode 占用 + 沙箱无法注册而
  放弃，采用 loopback + 手动粘贴授权码（已按 spec 场景覆盖测试）。
