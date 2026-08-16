## Purpose

Manage ZCode desktop login state as named, health-checked account snapshots and
switch between them reliably.

## ADDED Requirements

### Requirement: Capture the current login
The system SHALL read the active ZCode credentials and config files, derive a
stable fingerprint, and store a snapshot with metadata.

#### Scenario: A user is logged into ZCode
- **WHEN** the user requests a capture while ZCode login files exist
- **THEN** the system stores `credentials.json` and `config.json` as a snapshot
  and records provider, label, email, and user id

#### Scenario: The fingerprint is not extractable
- **WHEN** the current login files cannot be parsed
- **THEN** the system reports a clear error and stores nothing

### Requirement: Confirm snapshot health
The system SHALL statically validate a snapshot before it is switchable.

#### Scenario: Diagnostic checks run
- **WHEN** a snapshot is listed, created, or imported
- **THEN** the system reports status, summary, warnings, and errors covering
  JSON parseability, available tokens, decryptable user info, and provider
  API keys

### Requirement: Switch with rollback safety
The system SHALL back up the current login state before writing the target
snapshot and restore it if the write fails.

#### Scenario: Write fails mid-switch
- **WHEN** writing the target snapshot throws
- **THEN** the system restores the backed-up login state and reports the error

### Requirement: Roll back to the last login
The system SHALL restore the most recent backup on request.

#### Scenario: The user requests a rollback
- **WHEN** a `.last` backup exists
- **THEN** the system restores it and relaunches ZCode
