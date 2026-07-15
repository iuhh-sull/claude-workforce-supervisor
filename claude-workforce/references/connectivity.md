# Connectivity and recovery

## Provider API

Retryable failures are `ECONNREFUSED`, `ECONNRESET`, `ETIMEDOUT`, connection closure, and HTTP 408/429/500/502/503/504/529. The wrapper preserves partial output and performs at most one `--resume` against the original session. It never creates a replacement session for this recovery.

HTTP 400/401/403/404, invalid or missing authentication, invalid model, TLS validation, DNS configuration, and unsupported endpoints are configuration failures. They stop automatic recovery and do not open a retry loop.

Circuit breakers are keyed by provider, endpoint fingerprint, and model:

- three retryable failures within five minutes open the circuit;
- open circuits reject new dispatch for 60 seconds;
- half-open permits one worker slot;
- a successful probe closes the circuit;
- adaptive concurrency degrades before the circuit opens.

Use `doctor` to inspect circuit state and `reconcile` to see whether dispatch is allowed. Raw endpoints are never returned.

## MCP

MCP startup, idle, and tool timeouts are separate from the wrapper-enforced Claude process startup, idle, and hard timeouts. Each output distinguishes `configured`, `enforced`, and `reported-only`; environment configuration alone is not proof of enforcement.

- HTTP/SSE: wait for Claude Code's internal reconnect, check endpoint/lease/circuit state, and restart only a confirmed dead service once.
- stdio: verify the registered owned child exited, restart it once, then mark failure.

The wrapper does not discover or kill unregistered MCP services. Register long-lived MCP processes, endpoints, and listener ports through the resource broker. Worker reports and Manifest text are not ownership proof; recovery or cleanup requires a broker HMAC and matching process/listener identity.

## Partial output

Recovery prompts prohibit new tools and repeated side effects. Result JSON reports `api_retry_count`, `resume_used`, `partial_output_recovered`, and `new_session_created` so callers can audit the path taken.
