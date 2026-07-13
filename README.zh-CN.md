# Claude Workforce

> 非官方项目。[English](./README.md)

用官方 `claude agents` 后台 supervisor 管持久员工。每个员工是一段独立的 Claude Code 对话，Codex（主管）负责派活、查状态、接回对话和验收成果。

## 它解决什么问题

不少 Codex → Claude Code 集成只做一次性调用：任务结束后，主管侧缺少统一的状态、日志和恢复入口。你很难自然地说「去查一下这个，过会儿我回来继续」。

Workforce 让 Codex 管理可恢复的 CC 后台会话：需要时查看日志、停止、重启或续接原对话。底层进程不保证永久存活，但 supervisor 会保存可恢复状态。适合调研、代码审查和阶段性后台任务。

## 怎么装

```powershell
# 装到 ~/.codex/skills/claude-workforce
pwsh -NoProfile -File Install.ps1
```

首次安装不需要 `-Force`。升级或替换已有安装时才加 `-Force`；安装器会先备份旧目录。装好后 skill 目录里会有 SKILL.md 和 `scripts/claude-workforce.ps1`。

装完后可以建一个私有配置文件 `~/.codex/claude-workforce.local.psd1`，只接受三个键：

```powershell
@{
    ClaudeExecutable   = "C:\path\to\claude.exe"
    ExpectedClaudeSha256 = "<64位十六进制哈希>"
    AllowBroadWebFetch = $true
}
```

这个文件不要提交到公开仓库。优先级：命令行参数 > 私有文件 > 环境变量 > PATH。

## 怎么用

先确认环境就绪：

```powershell
$workforce = Join-Path $HOME '.codex\skills\claude-workforce\scripts\claude-workforce.ps1'
pwsh -NoProfile -File $workforce -Action capabilities
```

通过了就启动员工：

```powershell
# 调研模式，flash 模型，中等推理
pwsh -NoProfile -File $workforce -Action start -Mode inspect `
  -Model "deepseek-v4-flash[1m]" -Effort medium -Role researcher `
  -Cwd "<项目路径>" -Prompt "调查失败原因并列出证据，不修改文件"

# 写代码模式，pro 模型，高推理
pwsh -NoProfile -File $workforce -Action start -Mode write `
  -Model "deepseek-v4-pro[1m]" -Effort high -Role implementer `
  -Cwd "<Git 项目路径>" -Prompt "实现 X 改动并跑目标测试"

# 纯连通测试（无工具，flash + low 省成本）
pwsh -NoProfile -File $workforce -Action start -Mode inspect `
  -NoTools -Effort low -Role smoke -Cwd "<项目路径>" -Prompt "只回复 WORKFORCE_SMOKE_READY"
```

后面查状态、看日志、接回对话、停掉或者删掉，看 SKILL.md 里的例子。

### 模型选哪个

日常初筛用 flash + medium，便宜够快。需要深入诊断、安全审查、架构判断的时候换 pro + high。max 只在多约束高风险时用。

选模型不只是改个名字——flash 适合批量试错，pro 更适合做最终判断。

### 权限怎么回事

公开知识搜索（WebSearch、Exa search、Tavily search/research）默认放行，不需要你点确认。

从任意 URL 抓内容（WebFetch、Exa fetch、Tavily extract/crawl/map、context-mode fetch）默认要你批准。如果你信任环境，可以在私有配置里设 `AllowBroadWebFetch = $true`。

Bash、Edit、Write、NotebookEdit 每次都问。凭据库（.env、.ssh、.aws、认证文件等）的读取、编辑和写入直接拒绝。

全局配置员工能读，但不能改。读到密钥也不能回显或外发。

嵌套 Agent（员工再开员工）默认禁止。你真需要并行的时候加 `-AllowNestedAgents`，Agent 从 deny 变成 ask，每次仍要你点头。

### Windows 安全性提醒

原生 Windows 没有 Claude Code 的完整 OS 沙箱。权限 deny 规则在工具层面有约束力，但不在 OS 层面阻止文件读取或进程执行。别指望它当沙箱用。

### 删员工要两下确认

```powershell
pwsh -NoProfile -File $workforce -Action remove -Id "<id>" `
  -ConfirmRemove -CheckedWorktree
```

`-ConfirmRemove` 确认你确实想删。`-CheckedWorktree` 确认你检查过员工状态和关联 worktree 有没有未提交的改动。两个缺一个都不让删。

而且只有 `stopped`、`completed`、`failed` 这些终态才能删。员工还在跑的时候得先 `stop`。

## 项目结构

```
claude-workforce/
  SKILL.md                 # Codex skill 定义
  agents/openai.yaml       # OpenAI-compatible agent 定义
  scripts/
    claude-workforce.ps1   # 核心 wrapper
Install.ps1                # 安装脚本
tests/
  Test-ClaudeWorkforce.ps1 # 解析检查 + 运行时权限探针
README.md                  # 英文说明
README.zh-CN.md            # 中文说明
SECURITY.md                # 安全策略
```

## 和其他方案的区别

Workforce 不是一次性 `claude -p` 调用：员工会话可恢复，进程退出后也能通过 supervisor 重新接回。它不是 MCP 代理，而是围绕官方 `agents` 子命令做的非官方 Codex skill。它也不是独立 CI/CD runner，仍需要 Codex 派单和验收。

## 不想用了

```powershell
$target = Join-Path $HOME '.codex\skills\claude-workforce'
if ((Split-Path -Leaf $target) -eq 'claude-workforce' -and (Test-Path -LiteralPath $target)) {
    Remove-Item -LiteralPath $target -Recurse -Force
}
```

如果装的时候生成了备份（`~/.codex/backups/claude-workforce-<日期>`），可以直接恢复。
