# Invocation levels

Invocation limits are admission ceilings, not worker creation targets.

| Level | Stable active | Burst | Nested agents | Startup | Idle |
|---|---:|---:|---:|---:|---:|
| low | 2 | 3 | 0 | 120s | 300s |
| medium | 4 | 6 | 2 | 120s | 600s |
| high | 6 | 10 | 4 | 180s | 900s |

`-ConcurrencyPolicy adaptive` is the default. After retryable failures, limits degrade as follows:

- low: 2 → 1 → 0;
- medium: 4 → 2 → 1 → 0 when the circuit opens;
- high: 6 → 3 → 1 → 0 when the circuit opens.

Burst requires both `-AllowBurst` and `-IndependentTask`, a closed circuit, and capacity below the burst ceiling. The task must not share mutable files, fixed ports, mutable services, large inputs, or rate-limited endpoints. `-BurstWindowSeconds` defaults to 300; completed workers must return to the stable ceiling.

`-AllowNestedAgents` is rejected at low. Medium and high expose their maximum nested-agent count in the worker contract and audit output.
