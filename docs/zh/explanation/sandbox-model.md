# Bash 执行与隔离

`bash` 工具执行模型要求的命令。本页明确说明 PAR 对它有**哪些**约束、**没有**哪些约束，以及
边界为什么画在这里。刻意写得直白：如果 agent 以为自己被关住了、其实没有，它就会被托付
超出应有范围的东西。

## 一次 bash 调用经过什么

`Runtime.create` 之后调用 `Runtime.install_bash_tool` 注册 handler。此后每次调用按顺序经过这些阶段：

| # | 阶段 | 作用 |
|---|------|------|
| 1 | 只收 argv | 工具接受 `argv : string list`。没有 shell 字符串，因此在 PAR 看到命令之前不存在引号解析或 `;` 拼接。 |
| 2 | Workspace 准入 | `cwd` 由 `Workspace.admit` 校验：拒绝 `..`、`:` 与敏感前缀（`/etc`、`~/.ssh` 等）；绝对路径只有在某个 workspace 根之下才被接受。 |
| 3 | 策略过滤 | `Coder`（默认）、`ReadOnly`、`ReadOnlyNoNet` 或自定义 `POLICY` 决定放行/拒绝，并可改写命令。`Coder` 会拒绝 `Bash_blacklist` 中的条目。 |
| 4 | 环境净化 | `Bash_policy.sanitize_env` 去掉 `*secret*` / `*key*` / `*token*` / `*password*` / `*credential*` 名称，以及 `AWS_*`、`AZURE_*`、`GCP_*`、`OPENAI_API_KEY`、`ANTHROPIC_API_KEY`、`GITHUB_TOKEN` 系列。**子进程实际收到的就是过滤后的集合。** |
| 5 | 超时 | 每次调用默认 30 秒，并被钳制在 600 秒以内。到期杀死子进程并返回 `Timeout`。 |
| 6 | 输出处理 | stdout/stderr 上限 50KB / 2000 行，并剥离 ANSI 转义。 |
| 7 | 审计 | `Bash_invoked` 与 `Bash_completed` 事件携带 argv、cwd、风险评级、退出码与耗时。 |

## 不保证的事情

- **文件系统隔离。** `cwd` 是命令的起点，不是牢笼。命令可以 `cd /`，也可以读取 PAR 进程
  能读的任何路径。`Workspace` 保护的是文件工具（它们通过 `Workspace.sandboxed_path`
  构造路径），它约束不了已经启动的进程。
- **网络隔离。** `ReadOnlyNoNet` 会拒绝它识别出的网络客户端命令。那是分类器，不是防火墙：
  脚本不调用 `curl` 也能开 socket。
- **进程组清理。** 超时只杀死直接子进程，它派生的后代不会被回收。
- **CPU 与内存上限。** `POLICY.max_cpu_seconds` 与 `max_memory_kb` 有声明、会上报，但今天
  没有任何东西强制执行。把它们当意图，不要当控制手段。
- **权限降级。** 子进程以 PAR 的 uid/gid 运行。

## 缺口为什么存在

PAR 要跑在 Linux、macOS 与 Windows 上，而填补这些缺口的机制都是平台专属的：Linux 上的
bubblewrap 或 landlock、macOS 上的 seatbelt（`sandbox-exec`）、Windows 上的 job object。
一个在不同平台上悄悄降低隔离强度的库，比一个把边界讲清楚的库更糟——调用方无法知道自己
拿到的是哪种行为。

还有第二个原因：PAR 没有 pre-exec 钩子。在 `fork` 与 `exec` 之间安装 landlock 规则集或
新建进程组，需要一个 PAR 所依赖的进程 API 并未提供的参考 monad。

## 可插拔设计（尚未实现）

预期形态是可选的包装器，而不是隐藏的默认值：

```ocaml
type sandbox = {
  name : string;
  (* 包装即将 spawn 的 argv。 *)
  wrap : argv:string list -> cwd:string -> (string list, error_category) result;
  (* 该实现真正提供了什么，便于调用方上报。 *)
  provides : [ `Filesystem | `Network | `Process_group | `Rlimits ] list;
}

val install_bash_tool : ?sandbox:sandbox -> ... -> (unit, error_category) result
```

候选实现：

| 平台 | 机制 | 提供 |
|------|------|------|
| Linux | `bwrap --unshare-all --ro-bind / / --bind <cwd> <cwd> -- <argv>` | 文件系统、网络、进程组 |
| Linux | 在 `exec` 前安装 landlock 规则集 | 文件系统（需要 pre-exec 钩子或小型 C stub） |
| macOS | `sandbox-exec -p <profile> <argv>` | 文件系统、网络 |
| Windows | 用 job object 限制 CPU/内存 | 仅资源上限 |

选择将是显式且**失败即关闭**的：请求的沙箱能力探测失败时返回错误，而不是悄悄以无沙箱方式运行。

## 什么时候会做

触发条件是出现「执行不可信或多租户命令」的部署。在那之前，对不可信输入的诚实答案是在 PAR
之外做隔离——容器、虚拟机或专用用户——那是部署决策，不是库特性。

## 另请参阅

- `docs/sdk/` 下的 SDK 页面，先从[「工具」](../sdk/tools.md)看 bash 参数与安全机制表
- [并发模型](concurrency-model.md) — 取消与超时
