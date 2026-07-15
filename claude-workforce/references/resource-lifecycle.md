# Resource lifecycle

## Authoritative state

Schema-v2 Manifest files under `~/.codex/claude-workforce/manifests/` are the only authoritative lifecycle state. The supervisor owns every Manifest write and serializes state changes with a cross-process mutex, atomic replace, backup, revision CAS, and an explicit transition table. A derived index must never become a second source of truth.

Workers do not receive write access to the authoritative Manifest. They may write only the path in `CLAUDE_WORKFORCE_WORKER_REPORT`. Worker reports are untrusted audit input: the supervisor validates the Manifest ID and a small status/result allowlist, but never accepts reported resources, ownership, cleanup, or arbitrary fields as trusted state.

Legacy schema-v1 state is migrated under the global state lock. Migration creates a backup beneath the workforce backup root, marks unverifiable legacy ownership as `legacy-unverified`, removes the obsolete resource index, and emits a migration report. `rollback-migration` only accepts a backup path inside that root.

## Broker trust boundary

Processes, ports, and MCP endpoints become trusted only through `workforce-resource-broker.ps1`. Each session receives a capability token bound to its Manifest; the token must never appear in output, prompts, reports, or persisted state. Broker records and port leases are signed with HMAC using the local 32-byte `broker.key`.

Registration validates the capability, Manifest/session binding, process identity and descendant chain. Port registration also resolves the actual listener PID and requires it to match the trusted process resource. A worker report or plain Manifest text cannot create ownership.

Cleanup verifies the HMAC plus resource/session/Manifest identity before acting. Force cleanup additionally checks PID, start time, executable, descendant ownership and listener PID. Invalid signatures, missing/unsafe broker ACLs, PID reuse, listener mismatch, or unverifiable ownership fail closed.

## Lifecycle

1. **Preflight** validates capabilities, namespace, source fingerprint, state version and circuit.
2. **Reaper** converges terminal or stale Manifests and retries eligible `cleanup-incomplete` records.
3. **Reconcile** blocks duplicates, corrupt state, open circuits and unresolved cleanup.
4. **Acquire** creates a locked schema-v2 Manifest and session capability.
5. **Run** accepts worker reports only as untrusted progress/result evidence; resources use broker registration.
6. **Finalize** enters `finalizing`, classifies success/failure/cancellation/limit, and preserves partial output.
7. **Cleanup** releases broker-verified temporary resources and verifies process/port zero.
8. **Retain/remove** applies session retention only after cleanup reaches a safe terminal result.

`cleanup-incomplete` is a terminal blocker, not success. Conflicting dispatch remains disabled until reaper, explicit cleanup, or a reviewed force-cleanup attempt resolves the trusted resources.

## Policies

- `cleanup`: release temporary resources and use a disposable session.
- `retain-session` (default): retain resumable transcript metadata but release temporary processes and ports.
- `keep-resources`: retain only broker-registered persistent resources with TTL and health/cleanup metadata.
- `stop-on-complete` (default): stop the worker and retain the session.
- `remove-on-complete`: remove only after terminal roster state, complete cleanup, and a clean Git worktree are verified.
- `idle-ttl`: stop and retain until the configured TTL expires.
- `manual`: retain the session, but still clean temporary resources.

Reaper is globally locked and idempotent. Wrapper actions such as list, reply, doctor and reconcile may run it opportunistically; explicit `reap` remains available for operations.
