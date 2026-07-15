# Operations

## Routine checks

```powershell
pwsh -NoProfile -File $workforce -Action reconcile -Cwd $project -Role researcher -Prompt '<task>'
pwsh -NoProfile -File $workforce -Action doctor -Cwd $project
pwsh -NoProfile -File $workforce -Action resources
pwsh -NoProfile -File $workforce -Action ports
```

`reconcile` returns duplicate/reuse decisions, stable/burst limits, active workers, available slots, circuit state, cleanup counters, and `dispatch_allowed`.

## Cleanup

```powershell
pwsh -NoProfile -File $workforce -Action cleanup
pwsh -NoProfile -File $workforce -Action cleanup -ScopeCwd -Cwd $project
pwsh -NoProfile -File $workforce -Action stop -Id '<worker-id>' -GracefulShutdownSeconds 10 -PortReleaseTimeoutSeconds 15
```

Add `-ForceOwnedResources` only after graceful cleanup fails. Force is still fail-closed when PID/start-time/executable/session ownership does not match.

## Daemon

```powershell
pwsh -NoProfile -File $workforce -Action daemon-status
pwsh -NoProfile -File $workforce -Action daemon-stop
pwsh -NoProfile -File $workforce -Action daemon-restart
pwsh -NoProfile -File $workforce -Action daemon-restart-keep-workers
```

Use restart-keep-workers after a deliberate provider, endpoint, PATH, proxy, Claude version, MCP endpoint, or TLS/CA change. `doctor` stores only an environment fingerprint and reports when it changed.

Cross-thread resource views and cleanup require `-AllThreads`; default operations remain in the current namespace.
