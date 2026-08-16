## Purpose

Discover running ZCode desktop instances and resolve the account each instance
is logged into.

## ADDED Requirements

### Requirement: Discover running instances
The system SHALL enumerate active ZCode desktop processes through the macOS
platform bridge.

#### Scenario: Multiple windows are running
- **WHEN** two ZCode desktop processes are active
- **THEN** the system reports both with name and PID and counts them

### Requirement: Resolve per-instance accounts
The system SHALL read each running instance's own login-state directory and
derive its account label and provider.

#### Scenario: Instances use different accounts
- **WHEN** active instances have separate login-state directories
- **THEN** each instance entry reports its own account label and provider

#### Scenario: Default (unmanaged) instance
- **WHEN** a running ZCode process is not a managed instance
- **THEN** the system reads the default ZCode directory and marks the entry as
  external and read-only

### Requirement: Manage instances outside the sandbox
In non-sandboxed builds the system SHALL create, start, stop, and delete
env-isolated ZCode instances.

#### Scenario: Non-sandboxed build
- **WHEN** the app is not sandboxed
- **THEN** instance start launches ZCode with isolated data-directory
  environment variables and stop terminates the recorded PID

#### Scenario: Sandboxed build
- **WHEN** the app is sandboxed
- **THEN** instance-management actions are disabled with an explanatory message
