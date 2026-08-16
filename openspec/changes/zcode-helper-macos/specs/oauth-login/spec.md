## Purpose

Let the user add a new account by logging in through either supported provider
(Z.ai global or BigModel China). The flow must not depend on the `zcode://`
custom scheme (ZCode claims it while running and a sandbox cannot re-register
it), so it uses a local loopback callback with a manual code-paste fallback,
then exchanges the code, writes the provider-specific login state, captures a
snapshot, and restores the previous live files.

## ADDED Requirements

### Requirement: Choose a login provider
The system SHALL offer distinct login entries for Z.ai (global) and BigModel
(China) and build a provider-specific authorization URL.

#### Scenario: The user picks Z.ai
- **WHEN** the user starts a login and picks Z.ai
- **THEN** the system opens an authorization page on `chat.z.ai`
- **AND** the state and redirect parameters match the official ZCode client

#### Scenario: The user picks BigModel
- **WHEN** the user starts a login and picks BigModel
- **THEN** the system opens a login page on `bigmodel.cn` with the ZCode app id

### Requirement: Receive the authorization code without the custom scheme
The system SHALL wait for the authorization code on a local loopback server
and SHALL allow pasting the code manually as a fallback when the browser cannot
return to the callback.

#### Scenario: Browser redirects to the local callback
- **WHEN** the browser hits `http://127.0.0.1:<port>/callback` with a matching
  state
- **THEN** the system accepts the code and continues the login

#### Scenario: The browser cannot redirect back
- **WHEN** the browser shows a `zcode://oauth/callback?code=...` URL or the
  user cannot return to the callback
- **THEN** the user can paste the code into the dialog and the system
  continues the login

#### Scenario: The user cancels or the login times out
- **WHEN** the user cancels the dialog or no code arrives within the timeout
- **THEN** the system aborts cleanly without modifying login files

### Requirement: Exchange the code per provider
The system SHALL call the ZCode token endpoint with the provider, code, state,
and redirect URI, and SHALL parse the provider-specific response shape.

#### Scenario: Z.ai response
- **WHEN** the token response contains `data.zai.access_token`
- **THEN** the system derives the Z.ai access token and performs the Z.ai
  business login so the billing plan initializes

#### Scenario: BigModel response
- **WHEN** the token response contains `data.bigmodel.access_token`, possibly
  without user info
- **THEN** the system fetches user info from
  `getCustomerInfo` (Authorization header without a Bearer prefix) and applies
  the BigModel coding-plan key when derivable

### Requirement: Save the account and keep the tool in sync with disk
The system SHALL write the provider login state to the live config files
(encrypted credentials, provider enablement, setting family), capture an
account snapshot, and then restore the login files to their pre-login
contents so the tool UI matches disk.

#### Scenario: Login succeeds
- **WHEN** the exchange and business-login steps succeed
- **THEN** the system stores a snapshot of the new account and reports the
  logged-in email or name

#### Scenario: The account already exists
- **WHEN** a snapshot with the same fingerprint exists
- **THEN** the system reports the existing account instead of failing

#### Scenario: Previous login files exist
- **WHEN** there were live login files before the login
- **THEN** those files are restored afterward and only the snapshot retains the
  new account

### Requirement: Keep capture reliable on macOS
The system SHALL register the platform bridge after the Flutter view
controller is ready and SHALL report clear errors (instead of silent no-ops)
when the login directory is missing or not granted.

#### Scenario: The user clicks capture without login files
- **WHEN** no `v2/credentials.json` is present and the app is sandboxed
- **THEN** the system guides the user to authorize the ZCode data directory
  and explains the missing login state
