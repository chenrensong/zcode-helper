## 1. Foundation

- [x] 1.1 Scaffold Flutter macOS project and add `http` + `cryptography`.
- [x] 1.2 Port crypto (`enc:v1` AES-GCM) with a Node-generated fixture test.
- [x] 1.3 Port paths, JWT decode, fingerprint extraction.

## 2. Account management

- [x] 2.1 Port snapshot store: capture, list, load, remove, rename, export, import.
- [x] 2.2 Port health validation and BigModel native-profile migration.
- [x] 2.3 Port switch/rollback with backup, atomic writes, cache clear, relaunch.

## 3. Quota

- [x] 3.1 Port token-candidate reading and billing/monitor quota queries.
- [x] 3.2 Port quota normalization (BigModel limits, plans, balances) and display helpers.

## 4. Runtime instances + platform bridge

- [x] 4.1 Swift MethodChannel bridge: sandbox flag, running apps, launch,
  terminate, folder picker, bookmark save/restore.
- [x] 4.2 Port instance meta store, merge logic, per-instance account resolution.
- [x] 4.3 Managed instance actions guarded by sandbox state.

## 5. UI + App Store profiles

- [x] 5.1 App shell with tabs, status header listing running instances + accounts.
- [x] 5.2 Accounts page (cards, health, quota, switch/rollback/capture dialogs).
- [x] 5.3 Instances and settings pages, guided-quit switch flow.
- [x] 5.4 Entitlements (MAS + Developer ID), Info.plist, xcconfig bundle ids.

## 6. Verification

- [x] 6.1 Unit tests green (`flutter test`), `flutter analyze` clean.
- [x] 6.2 `flutter build macos --release` succeeds; `openspec validate --strict` passes.

## 7. OAuth login (Z.ai / BigModel) + capture reliability

- [x] 7.1 Bridge refactor: singleton `ZcodeBridge` registered in
  `MainFlutterWindow` (fixes silent no-op capture), `openUrl`/`hostIdentity`
  methods, `network.server` entitlement for the loopback callback.
- [x] 7.2 OAuth service: per-provider authorize URLs, token exchange with
  provider-specific response shapes, Z.ai business login, BigModel
  `getCustomerInfo` fallback with non-Bearer header.
- [x] 7.3 Login writer: encrypted credentials write, provider enablement,
  setting family, coding-plan key apply, backup/restore of live files.
- [x] 7.4 Login controller + loopback server: CSRF state, browser open, manual
  code fallback, timeout/cancel handling, snapshot capture, live-file restore.
- [x] 7.5 UI: provider picker + progress dialog with code-paste fallback;
  login entry on the accounts page; capture shows clear errors.
- [x] 7.6 Tests: URL building, per-provider exchange shapes, end-to-end
  manual-code login for both providers, writer round-trip, cancel, restore,
  secret override; `flutter analyze` clean and `flutter test` green.
- [x] 7.7 `flutter build macos --release` succeeds with no warnings.
