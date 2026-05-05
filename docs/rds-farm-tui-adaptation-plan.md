# External Deployment Scheduled-Renewal Resilience — TUI Adaptation Plan

## Goal
Generalize the scheduled-renewal-safe pattern from your reference (`install.cmd` + `deploy-rds-farm.ps1`) so it applies to **all deployment targets that require external system details** (RDS farm, firewalls, switches, HAProxy, Apache, mail gateways, etc.), while keeping local-only targets lightweight.

## Scope decision

### In scope (needs persisted external deployment context)
Any script target that needs details outside local machine state, such as:
- Remote host lists or endpoints.
- Remote auth user/account hints.
- Remote file paths / temp folders.
- Device API endpoints, ports, tenant IDs, profile names.
- Target-specific mapping metadata (listener names, virtual services, cert bindings).

Examples in this repo model:
- `rds-farm`
- `firewall`
- `waf`
- `mail`
- any custom script that deploys to non-local systems.

### Out of scope (not required)
Local-only targets where renewal can resolve everything from local machine state and wacs placeholders, such as single-machine local bindings without external inventories.

---

## Current-state observations

1. TUI setup currently emits script parameters at configuration time; renewals rely on those serialized values.
2. Some connectors already implement partial fallback behavior, but there is no **uniform cross-target external-context persistence contract**.
3. This creates renewal fragility when external details evolve, when scheduled tasks run under a different context, or when setup is not rerun.

---

## Target architecture (cross-target)

### A. Introduce a shared persisted external deployment config contract
Create per-target config artifacts under a managed location (recommended `runtime/deployment/`):
- `runtime/deployment/rds-farm.env`
- `runtime/deployment/firewall.env`
- `runtime/deployment/waf.env`
- etc.

For JSON-heavy targets, allow `.json` alongside `.env`.

Minimum common keys (where applicable):
- `TARGET_TYPE`
- `HOSTS` (CSV or JSON array)
- `PFX_STORE_PATH`
- `PFX_PASSWORD` (or secure reference token)
- `REMOTE_TEMP_DIRECTORY`
- `UPDATED_UTC`

Target-specific keys extend this baseline.

### B. Standard parameter contract for external deploy scripts
For each external deployment script, support:
- `-ConfigFile` (optional)
- explicit runtime args (existing behavior)
- fallback resolution from config file

Resolution precedence:
1. Explicit invocation arguments.
2. Persisted config file values.
3. Existing script-native fallback behavior.
4. Fail fast with actionable error.

### C. TUI write/read integration
When configuring an external target in TUI:
1. Collect external deployment details.
2. Persist/update target config file.
3. Include `-ConfigFile '<path>'` in `ACME_SCRIPT_PARAMETERS`.
4. Preserve explicit args for deterministic first-run behavior.

For local-only targets:
- Do **not** require config-file persistence.
- Keep current lightweight parameter model.

### D. Secret handling policy
- Phase 1: allow plaintext compatibility if required for backward compatibility.
- Phase 2: migrate sensitive values to encrypted storage (DPAPI/repo crypto abstraction) and persist only references in config files.
- Continue masking secrets in logs and previews.

---

## Implementation phases

### Phase 1 — Framework and contract (all external targets)
1. Define shared external config schema guidance (`.env` + optional `.json`).
2. Add helper(s) for config parsing/loading in common module(s).
3. Add `-ConfigFile` support pattern documentation for script authors.

### Phase 2 — RDS farm first (reference implementation)
1. Add `-ConfigFile` and fallback loading in `Scripts/deploy-rds-farm.ps1`.
2. Persist `rds-farm` external config from TUI save path.
3. Emit `-ConfigFile` in `ACME_SCRIPT_PARAMETERS` for `rds-farm`.
4. Keep backward compatibility for existing installs.

### Phase 3 — Rollout to remaining external connectors
Apply the same pattern to each external target script category:
- firewall connectors
- switch/device connectors
- WAF/reverse proxy connectors (HAProxy/Apache/etc.)
- mail/security appliance connectors
- custom external connectors

Each connector should document required keys and validation rules.

### Phase 4 — Validation and regression tests
1. Add cross-target contract tests ensuring `-ConfigFile` support where target is external.
2. Add TUI wiring tests ensuring config persistence and parameter emission.
3. Add precedence tests (args > config > fallback).
4. Add negative tests for missing required external details.

### Phase 5 — Docs and runbooks
1. Update `README.md` / `install.md` with "external target renewal resilience" model.
2. Document per-target config file locations and key sets.
3. Add secret rotation and backup/restore guidance.

---

## Engineering task breakdown

1. **Classify targets**
   - Add a target metadata map in setup layer: `isExternalDeploymentTarget` boolean.
2. **Config persistence abstraction**
   - Add shared writer/reader utilities (env/json).
3. **Script contract upgrade**
   - Add `-ConfigFile` + fallback in each external script.
4. **TUI update**
   - Persist config for external targets on save.
   - Emit `-ConfigFile` in generated script parameters.
5. **Hardening**
   - Add schema/key validation and actionable errors.
6. **Tests**
   - Contract, parser, and wiring tests across external targets.

---

## Acceptance criteria

- Scheduled renewals succeed for external targets **without rerunning TUI setup**, provided connectivity/permissions are valid.
- Local-only targets continue to work without mandatory external config files.
- All external deploy scripts support `-ConfigFile` fallback.
- TUI emits and maintains external deployment config per external target.
- Tests verify precedence and failure modes consistently.

---

## Rollout notes

- Roll out as backward-compatible: config fallback is additive.
- Start with `rds-farm` as pilot, then expand connector-by-connector.
- Prefer introducing shared helper utilities before broad connector migration to avoid drift.
