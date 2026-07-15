# Port management

Port leases live in `~/.codex/claude-workforce/port-leases.json`. Each lease contains protocol, session, worker, optional PID/start time, purpose, persistence, creation time, expiry, and an ownership fingerprint.

Acquire a dynamically selected TCP port for a known worker:

```powershell
pwsh -NoProfile -File $workforce -Action ports -Id '<worker-id>' -Port 0 -Purpose preview -ResourceTtlSeconds 1800
```

List leases:

```powershell
pwsh -NoProfile -File $workforce -Action ports
```

Release only after the port is no longer listening:

```powershell
pwsh -NoProfile -File $workforce -Action ports -ReleaseLeaseId '<lease-id>'
```

The wrapper never kills by port alone. An unleased listening port is treated as another user's resource and acquisition fails. Force cleanup still requires a matching PID, process start time, executable, session, and ownership fingerprint.

Prefer dynamic port `0`. Fixed ports such as 3000, 5173, 8000, and 8080 should be used only when an external protocol requires them.
