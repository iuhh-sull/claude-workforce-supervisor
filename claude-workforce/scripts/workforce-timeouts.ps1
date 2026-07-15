if ($null -eq ('ClaudeWorkforce.ProcessMonitor' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Text;
using System.Threading;

namespace ClaudeWorkforce
{
    public sealed class ProcessMonitorResult
    {
        public int ExitCode { get; set; }
        public string StandardOutput { get; set; } = "";
        public string StandardError { get; set; } = "";
        public bool TimedOut { get; set; }
        public string TimeoutKind { get; set; } = "none";
        public DateTimeOffset StartedAt { get; set; }
        public DateTimeOffset? FirstOutputAt { get; set; }
        public DateTimeOffset? LastOutputAt { get; set; }
    }

    public static class ProcessMonitor
    {
        public static ProcessMonitorResult Run(ProcessStartInfo startInfo, int startupTimeoutSeconds, int idleTimeoutSeconds, int hardTimeoutSeconds, int compatibilityTimeoutSeconds)
        {
            var output = new StringBuilder();
            var error = new StringBuilder();
            var outputLock = new object();
            long firstOutputTicks = 0;
            long lastOutputTicks = 0;
            var startedAt = DateTimeOffset.UtcNow;
            using var process = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
            process.OutputDataReceived += (_, args) =>
            {
                if (args.Data == null) return;
                lock (outputLock) output.AppendLine(args.Data);
                var ticks = DateTimeOffset.UtcNow.UtcTicks;
                Interlocked.CompareExchange(ref firstOutputTicks, ticks, 0);
                Interlocked.Exchange(ref lastOutputTicks, ticks);
            };
            process.ErrorDataReceived += (_, args) =>
            {
                if (args.Data == null) return;
                lock (outputLock) error.AppendLine(args.Data);
                var ticks = DateTimeOffset.UtcNow.UtcTicks;
                Interlocked.CompareExchange(ref firstOutputTicks, ticks, 0);
                Interlocked.Exchange(ref lastOutputTicks, ticks);
            };
            if (!process.Start()) throw new InvalidOperationException("Claude Code process did not start.");
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();
            string timeoutKind = "none";
            while (!process.WaitForExit(100))
            {
                var now = DateTimeOffset.UtcNow;
                var firstTicks = Interlocked.Read(ref firstOutputTicks);
                var lastTicks = Interlocked.Read(ref lastOutputTicks);
                if (hardTimeoutSeconds > 0 && now >= startedAt.AddSeconds(hardTimeoutSeconds))
                {
                    timeoutKind = "hard";
                    break;
                }
                if (compatibilityTimeoutSeconds > 0 && now >= startedAt.AddSeconds(compatibilityTimeoutSeconds))
                {
                    timeoutKind = "process";
                    break;
                }
                if (firstTicks == 0 && startupTimeoutSeconds > 0 && now >= startedAt.AddSeconds(startupTimeoutSeconds))
                {
                    timeoutKind = "startup";
                    break;
                }
                if (firstTicks != 0 && idleTimeoutSeconds > 0 && now >= new DateTimeOffset(lastTicks, TimeSpan.Zero).AddSeconds(idleTimeoutSeconds))
                {
                    timeoutKind = "idle";
                    break;
                }
            }
            var timedOut = timeoutKind != "none";
            if (timedOut && !process.HasExited)
            {
                try { process.Kill(true); } catch { }
            }
            process.WaitForExit();
            string stdout;
            string stderr;
            lock (outputLock)
            {
                stdout = output.ToString().Trim();
                stderr = error.ToString().Trim();
            }
            var first = Interlocked.Read(ref firstOutputTicks);
            var last = Interlocked.Read(ref lastOutputTicks);
            return new ProcessMonitorResult
            {
                ExitCode = process.ExitCode,
                StandardOutput = stdout,
                StandardError = stderr,
                TimedOut = timedOut,
                TimeoutKind = timeoutKind,
                StartedAt = startedAt,
                FirstOutputAt = first == 0 ? null : new DateTimeOffset(first, TimeSpan.Zero),
                LastOutputAt = last == 0 ? null : new DateTimeOffset(last, TimeSpan.Zero)
            };
        }
    }
}
'@
}

function Invoke-WorkforceMonitoredProcess {
    param(
        [Parameter(Mandatory = $true)][Diagnostics.ProcessStartInfo]$StartInfo,
        [ValidateRange(0, 3600)][int]$StartupTimeoutSeconds = 120,
        [ValidateRange(0, 86400)][int]$IdleTimeoutSeconds = 600,
        [ValidateRange(0, 604800)][int]$HardTimeoutSeconds = 0,
        [ValidateRange(0, 604800)][int]$CompatibilityTimeoutSeconds = 0
    )

    return [ClaudeWorkforce.ProcessMonitor]::Run(
        $StartInfo,
        $StartupTimeoutSeconds,
        $IdleTimeoutSeconds,
        $HardTimeoutSeconds,
        $CompatibilityTimeoutSeconds
    )
}
