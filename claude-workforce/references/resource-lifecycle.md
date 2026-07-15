# Resource lifecycle

Every `run`, `start`, and `reply` is represented by a versioned resource manifest under `~/.codex/claude-workforce/manifests/`. The public wrapper follows this sequence:

1. **Preflight** verifies Claude capabilities, computes namespace/cwd/task fingerprints, reads the roster, and resolves the provider/model circuit key without storing the raw endpoint.
2. **Reconcile** prevents duplicate task dispatch, reuses completed manifests, cleans terminal owned resources, and computes the available worker slots.
3. **Acquire** creates the manifest and exposes its path only to the launched process through `CLAUDE_WORKFORCE_RESOURCE_MANIFEST`.
4. **Run** requires workers to register processes, ports, MCP endpoints, persistence, TTL, health checks, cleanup commands, and ownership fingerprints.
5. **Finalize** stores a redacted result summary, API/MCP error classes, and the resource deltas.
6. **Release** closes temporary resources. Persistent resources survive only when explicitly registered with a TTL.
7. **Verify** checks worker terminal state, PID start time, executable, session ownership, and port release.
8. **Retain or remove** applies `SessionRetentionPolicy`; a transcript can be retained while all running resources are released.

## Policies

`ResourcePolicy`:

- `cleanup`: release temporary resources and use for disposable work.
- `retain-session` (default): retain resumable session metadata but release processes and ports.
- `keep-resources`: keep only resources explicitly marked persistent with owner, TTL, cleanup command, and health check.

`SessionRetentionPolicy`:

- `stop-on-complete` (default): stop the worker and retain the session.
- `remove-on-complete`: remove an eligible Agent View worker after resource cleanup only when terminal state and a clean Git worktree are both verified.
- `idle-ttl`: stop immediately and retain until the configured TTL expires.
- `manual`: retain the session, but still release temporary resources.

Print-mode `run` sessions are not Agent View workers and remain persisted for same-session recovery. Use `-Ephemeral` only when that transcript is intentionally disposable.

Background Agent View jobs are not continuously polled by this script. Their worker contract performs in-session finalization; `reconcile`, `cleanup`, `stop`, and `doctor` provide the supported external postflight path.

## Manifest safety

Manifests store cwd/task/endpoint fingerprints rather than raw prompts or endpoints. A process resource's ownership fingerprint must exactly match its containing manifest's `manifest_id`; presence alone is not ownership proof. Resource records must not contain credentials. `resources` passes state through the same output redaction pipeline used for logs.
