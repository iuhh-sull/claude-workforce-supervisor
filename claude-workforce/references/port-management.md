# Port management

Port leases live in `~/.codex/claude-workforce/port-leases.json`. Each lease contains protocol, Manifest/session, worker, process identity, listener PID, purpose, persistence, creation/expiry, broker signature, and a released/active status.

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

The broker resolves the actual listener PID before binding a lease and requires it to match a trusted registered process. A worker report, claimed PID, Manifest field, or port number alone is never sufficient.

The wrapper never kills by port alone. An unleased or listener-mismatched port is treated as another user's resource and acquisition fails. Force cleanup requires a valid broker HMAC, safe broker-key ACL, Manifest/session binding, matching PID/start time/executable/descendant chain, and the listener PID. Release keeps an auditable terminal lease record after the listener disappears.

Prefer dynamic port `0`. Fixed ports such as 3000, 5173, 8000, and 8080 should be used only when an external protocol requires them.
