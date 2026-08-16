## Purpose

Show current Coding Plan quota consumption for the active account and for any
snapshot, using the same billing endpoints and normalization as the original
tool.

## ADDED Requirements

### Requirement: Query active-account quota
The system SHALL derive candidate tokens from the current ZCode login and query
the provider-appropriate billing or monitor endpoint.

#### Scenario: BigModel active provider
- **WHEN** the active provider is `bigmodel`
- **THEN** the system queries `open.bigmodel.cn/api/monitor/usage/quota/limit`
  with the BigModel access token and normalizes the `limits[]` response

#### Scenario: Z.ai active provider
- **WHEN** the active provider is `zai`
- **THEN** the system first tries `api.z.ai/api/monitor/usage/quota/limit`, then
  falls back to the ZCode billing endpoints with the zcode JWT

### Requirement: Query snapshot quota
The system SHALL query quota for any stored snapshot without switching.

#### Scenario: Snapshot token present
- **WHEN** a snapshot contains a usable token
- **THEN** the system reports total, used, remaining, percent used, reset
  times, and formatted display strings

### Requirement: Tolerate missing plans
The system SHALL represent accounts without a Coding Plan distinctly.

#### Scenario: No plan exists
- **WHEN** the endpoint reports no plan
- **THEN** the system marks the quota result as `noPlan`/empty and shows
  "无 Coding Plan"
