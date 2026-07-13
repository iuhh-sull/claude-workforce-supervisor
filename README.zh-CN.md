# Claude Workforce

> 非官方项目。[English](./README.md)

Claude Workforce 让 Codex 通过官方 `claude agents` supervisor 管理 Claude Code 后台员工。Codex 负责派活、查状态、看日志和验收；任务中断后，还能通过 supervisor 接回原来的对话。

这是一个围绕官方 `agents` 子命令编写的非官方 Codex skill，适合调研、代码审查和分阶段执行的后台任务。

## 安装

```powershell
pwsh -NoProfile -File Install.ps1
```

首次安装不加 `-Force`。升级或替换已有安装时才加 `-Force`，安装器会先备份旧目录。

装完可以建私有配置文件 `~/.codex/claude-workforce.local.psd1`，只接受这三个键：

```powershell
@{
    ClaudeExecutable   = "C:\path\to\claude.exe"
    ExpectedClaudeSha256 = "<64位十六进制哈希>"
    AllowBroadWebFetch = $true
}
```

不要提交到公开仓库。优先级：命令行参数 > 私有文件 > 环境变量 > PATH。

## 快速开始

先确认环境：

```powershell
$workforce = Join-Path $HOME '.codex\skills\claude-workforce\scripts\claude-workforce.ps1'
pwsh -NoProfile -File $workforce -Action capabilities
```

启动员工：

```powershell
# 调研模式，flash 模型，中等推理
pwsh -NoProfile -File $workforce -Action start -Mode inspect `
  -Model "deepseek-v4-flash[1m]" -Effort medium -Role researcher `
  -Cwd "<项目路径>" -Prompt "调查失败原因并列出证据，不修改文件"

# 写代码模式，pro 模型，高推理
pwsh -NoProfile -File $workforce -Action start -Mode write `
  -Model "deepseek-v4-pro[1m]" -Effort high -Role implementer `
  -Cwd "<Git 项目路径>" -Prompt "实现 X 改动并跑目标测试"

# 连通测试（无工具，flash + low 省成本）
pwsh -NoProfile -File $workforce -Action start -Mode inspect `
  -NoTools -Effort low -Role smoke -Cwd "<项目路径>" -Prompt "只回复 WORKFORCE_SMOKE_READY"
```

status、log、reply、stop、remove 的完整用法见 [SKILL.md](./claude-workforce/SKILL.md)。

## 模型选择

初筛用 flash + medium，够快够便宜。深入诊断、安全审查、架构判断换 pro + high。max 留给多约束高风险场景。

flash 适合批量试错，pro 更适合做最终判断。

## 权限机制

公开搜索（WebSearch、Exa search、Tavily search/research）默认放行，不需要确认。

URL 抓取（WebFetch、Exa fetch、Tavily extract/crawl/map、context-mode fetch）默认要你批准。信任环境的话在私有配置设 `AllowBroadWebFetch = $true` 可以省掉确认。

Bash、Edit、Write、NotebookEdit 每次都要确认。

凭据存储（.env、.ssh、.aws、认证文件、私钥、.npmrc、.pypirc、.netrc、.docker/config.json、gh 配置、`*credentials.json`、`*secrets.yaml`、`*.pem`、`*.key`）直接拒绝读写。

全局配置员工可读不可改。读到密钥不回显不外发。

嵌套 Agent 默认禁止。加 `-AllowNestedAgents` 后改为每次询问。真需要并行再开。

## Windows 说明

原生 Windows 没有 Claude Code 的完整 OS 沙箱。权限 deny 在工具层面有约束力，但不在 OS 层面阻止文件读取或进程执行。别当沙箱用。

## 删除员工

```powershell
pwsh -NoProfile -File $workforce -Action remove -Id "<id>" `
  -ConfirmRemove -CheckedWorktree
```

`-ConfirmRemove` 表示你确认删除，`-CheckedWorktree` 表示你已经检查员工状态、日志和关联 worktree 中未提交或未合并的改动。两个参数缺一不可。只有终态（stopped、completed、failed、error、dead、cancelled、exited）才能删；还在运行的员工要先 stop。

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

## 卸载

```powershell
$target = Join-Path $HOME '.codex\skills\claude-workforce'
if ((Split-Path -Leaf $target) -eq 'claude-workforce' -and (Test-Path -LiteralPath $target)) {
    Remove-Item -LiteralPath $target -Recurse -Force
}
```

安装器产生过备份的话（`~/.codex/backups/claude-workforce-<日期>`），可以直接恢复。
