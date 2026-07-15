# Operations

## Routine checks

```powershell
pwsh -NoProfile -File $workforce -Action doctor -Cwd $project
pwsh -NoProfile -File $workforce -Action reconcile -Cwd $project -Role researcher -Prompt '<task>'
pwsh -NoProfile -File $workforce -Action reap
pwsh -NoProfile -File $workforce -Action resources
pwsh -NoProfile -File $workforce -Action ports
```

`doctor` reports schema and migration status, lock/corruption health, broker key/ACL state, stale and cleanup-incomplete counts, port conflicts, pricing freshness, environment drift and recommended actions. `reconcile` returns duplicate/reuse decisions, stable/burst limits, circuit state, cleanup blockers and `dispatch_allowed`.

## State migration and rollback

```powershell
pwsh -NoProfile -File $workforce -Action migrate
pwsh -NoProfile -File $workforce -Action rollback-migration -MigrationBackupPath '<backup-path>'
```

Migration is lock-protected and creates a rollback backup. Review the returned `backup_path` and migration report. Rollback fails closed when the path is absent or outside the workforce backup root.

`Install.ps1` runs the idempotent migration after installing the new skill unless `-SkipStateMigration` is supplied. It returns `state_migration` and a ready-to-copy `rollback_command` when a migration occurred. Skill backup and workforce state backup are separate.

## Cleanup

```powershell
pwsh -NoProfile -File $workforce -Action cleanup
pwsh -NoProfile -File $workforce -Action cleanup -ScopeCwd -Cwd $project
pwsh -NoProfile -File $workforce -Action stop -Id '<worker-id>' -GracefulShutdownSeconds 10 -PortReleaseTimeoutSeconds 15
pwsh -NoProfile -File $workforce -Action reap
```

Add `-ForceOwnedResources` only after graceful cleanup fails. Force cleanup still requires a valid broker HMAC, safe broker-key ACL, Manifest/session binding, PID/start-time/executable identity, descendant ownership and listener PID. A failed proof returns `cleanup-incomplete`; never broaden the kill target by process name or port.

## Daemon

```powershell
pwsh -NoProfile -File $workforce -Action daemon-status
pwsh -NoProfile -File $workforce -Action daemon-stop
pwsh -NoProfile -File $workforce -Action daemon-restart
pwsh -NoProfile -File $workforce -Action daemon-restart-keep-workers
```

Use restart-keep-workers only after a reviewed provider, endpoint, PATH, proxy, Claude version, MCP endpoint, or TLS/CA change. Existing workers do not inherit new profile, permission, hook, or wrapper semantics automatically.

Cross-thread views and cleanup require `-AllThreads`. Removal requires a verified terminal worker plus `-ConfirmRemove -CheckedWorktree`.
