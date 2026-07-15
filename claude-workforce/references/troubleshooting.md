# Troubleshooting

## Dispatch is blocked

Run `reconcile` and inspect `dispatch_reason`:

- `duplicate-task-active`: use the returned worker instead of creating another.
- `completed-manifest-available`: reuse the stored result or pass `-ForceNewDispatch` only when repetition is intentional.
- `worker-capacity-exhausted`: wait, clean terminal workers, or use a justified independent burst.
- `api-circuit-open`: stop new dispatch and run `doctor`; wait for half-open probing.

## Cleanup is incomplete

Run `resources` and `ports`. A process is never force-stopped unless PID, start time, executable, session, and ownership fingerprint match. `pid-reused`, `session-mismatch`, `executable-mismatch`, and `missing-ownership-fingerprint` are safety stops, not reasons to kill broadly.

Do not end all `node`, `python`, `claude`, or browser processes. Do not kill from a port number alone.

## API connection failure

Check `api_retry_count`, `resume_used`, and `partial_output_recovered`. One retryable failure receives one same-session finalize attempt. Authentication, invalid model, TLS validation, DNS configuration, and unsupported endpoints require configuration repair; restarting workers repeatedly increases pressure and duplicate side effects.

## MCP failure

Separate HTTP/SSE from stdio. Check registered endpoint/port ownership before a one-time restart. Startup, idle, and tool timeouts are independent values; increasing the whole Claude process timeout does not repair an MCP-specific timeout.

## Daemon environment drift

Run `doctor`. If `environment_changed` is true after an intentional provider, endpoint, PATH, proxy, Claude, MCP, or TLS change, use `daemon-restart-keep-workers`. On Windows, never use `taskkill` unless Claude CLI returned the exact supervisor PID and the operator confirmed it.
