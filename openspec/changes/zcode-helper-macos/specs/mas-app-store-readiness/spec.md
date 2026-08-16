## Purpose

Behave correctly and honestly under the Mac App Store sandbox.

## ADDED Requirements

### Requirement: Request scoped data access
The system SHALL access the ZCode data directory only through a user-selected
folder grant persisted as a security-scoped bookmark.

#### Scenario: First run in the sandbox
- **WHEN** no bookmark exists and a login-dependent operation is requested
- **THEN** the system prompts the user to select the ZCode data directory and
  persists the grant

#### Scenario: Bookmark restore
- **WHEN** the app launches with a stored bookmark
- **THEN** the system resolves and starts security-scoped access before reading
  or writing login files

### Requirement: Guided-quit switching in the sandbox
The system SHALL not terminate other applications; switching SHALL wait for the
user to quit ZCode, then write the target state and relaunch.

#### Scenario: ZCode is running during a sandboxed switch
- **WHEN** the user confirms a switch and ZCode is running
- **THEN** the system explains that ZCode must be quit, polls until it exits,
  writes the target login state, and relaunches ZCode

### Requirement: Terminate only outside the sandbox
Non-sandboxed builds SHALL terminate ZCode automatically before switching and
launch it afterwards.

#### Scenario: Auto-restart mode
- **WHEN** the app is not sandboxed
- **THEN** the switch kills all ZCode processes, writes the target state, and
  relaunches ZCode
