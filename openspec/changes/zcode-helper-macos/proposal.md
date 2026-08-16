## Why

The existing Electron/Node tool manages ZCode
desktop account logins: capture snapshots of `~/.zcode/v2` login state, switch
between them with a verified full restart, monitor Coding Plan quotas, and run
isolated multi-instance ZCode. The user wants a clean Flutter macOS rewrite
("ZCode Helper") that targets the **Mac App Store** as its primary
distribution channel.

## What Changes

Build a new Flutter macOS application from scratch in a new directory:

- Port the login-state cryptography, fingerprint, snapshot management, health
  checks, quota queries, and multi-instance logic from the Electron tool to
  idiomatic Dart with the same on-disk format.
- Introduce a platform bridge (Swift + MethodChannel) for sandbox-aware
  capabilities: running-instance discovery via `NSWorkspace`, app launch,
  folder-scoped access via security-scoped bookmarks, and (in non-sandboxed
  builds) process termination.
- Ship two build profiles from one codebase:
  - **Mac App Store (sandboxed)**: switching uses a guided "quit ZCode, wait,
    write, relaunch" flow; multi-instance creation (env-isolated) is omitted
    and surfaced honestly as a limitation.
  - **Developer ID (not sandboxed)**: retains automatic full restart and
    env-isolated multi-instance management.
- Provide a native-feeling macOS UI (account cards, quota meters, instance
  status, settings) built with Flutter's Material/Cupertino components.

## Capabilities

### New Capabilities

- `account-snapshot-management`: capture, list, health-check, switch, rollback,
  rename, delete, export, and import ZCode account snapshots.
- `quota-overview`: query and display Coding Plan / BigModel / Z.ai quota
  consumption with reset counts.
- `runtime-instance-monitor`: discover all running ZCode desktop instances and
  resolve each instance's bound account.
- `mas-app-store-readiness`: sandboxed entitlement model, security-scoped
  folder access to the ZCode data directory, and the guided-quit switch flow
  that complies with App Store sandbox rules.
- `oauth-login`: browser-based login for the two distinct providers
  (Z.ai global / BigModel China) via a local loopback OAuth callback with a
  manual authorization-code fallback, token exchange, per-provider login-state
  write, snapshot capture, and restore of the previous live files.

## Impact

- New Flutter project with macOS platform code and entitlements.
- Dart ports of existing crypto/fingerprint/manager/switcher/quota/instance
  behavior; no changes to the original Electron project.
