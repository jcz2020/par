<!-- language: zh -->

**[English](../explanation/faq.md)** · 简体中文

# FAQ：常见问题

> **Note (v0.6.7):** PAR 的 CLI（`par`、`par ask`、`par config`）已移除；目前支持的入口是 OCaml SDK（`opam install par`）和 Python 绑定（`pip install par-runtime`）。如需基于此 SDK 的交互式编码 Agent 体验，请参阅 [par-code](https://github.com/jcz2020/par-code)。下方关于 CLI 的问答保留作为历史参考。

本页收集了用户评估 PAR、选择入口、或遇到预期之外行为时最常提出的问题。每个答案都指向更深入的参考页面，方便你继续阅读而无需回头查找。如果这里没有你的问题，[How-to 指南](../howto/) 覆盖了具体操作方法，[架构](architecture.md) 页面解释了设计原理。

## Q1. PAR 和 LangChain 有什么区别？

PAR 占据与 LangChain 相同的生态位：agent 运行时加编排原语。但设计优先级完全相反。LangChain 优化的是广度和 Python 易用性，PAR 优化的是类型严谨和结构化并发。区别体现在三个具体方面。

**编译期类型安全，不是运行时。** LangChain 工具是 Python callable，背后是一个字典形状的 `args_schema`。字段名拼错、参数缺失、类型错误，全部在 agent 循环深处以运行时崩溃的形式出现。PAR 工具是 OCaml record，背后是类型化的 `tool_descriptor`，每个调用点都经过编译器强制你覆盖的模式匹配。bash 工具是最突出的例子。LangChain 暴露的是 `subprocess.run` 加原始字符串。PAR 有 `Bash_safe_command` ADT（代数数据类型），没有 `Exec_raw_shell` 构造器，意味着 shell 注入在类型层不可表示。你写不出这个 bug。STRATEGY.md 第 3 节把这称为核心差异化能力，PAR 不可复制的属性。

**结构化并发，不是 asyncio。** LangChain 运行在 Python asyncio 上。每个 async 函数都带着颜色标记，每个 `await` 都是一个挂起点，工具处理器必须选 `async def` 或保持同步。PAR 运行在 OCaml 5.4 effect handlers 加 Eio 库之上。函数是直接风格（direct style），没有颜色区分。运行时给每个 `Runtime.create` 调用一个 `Eio.Switch.t`，运行时 fork 的每个 fiber 都是该 switch 的子 fiber。switch 退出时，子 fiber 全部被 join。一个泄漏的工具处理器持有数据库连接，不可能比它的运行时活得更久。Go 有 goroutine 和 context 模型，要求子任务协作式取消。asyncio 在 3.11 有 task groups。Eio 从第一天起就强制结构化。

**文件系统原生的 skill 系统。** LangChain 的 prompt 和工具子集定义在代码中。PAR 的 skill 层（v0.5.2 发布）从磁盘 `~/.par/skills/<name>/skill.md` 发现可复用的行为包。每个 skill 包含 `system_prompt_override`、类型化 `tool_filter` ADT（`All_tools`、`Only [...]`、`Except [...]`）和 `skill_trigger`（`Auto`、`Manual`、`Keyword [...]`）。3 级上下文加载模式（常驻元数据、延迟加载主体、永不加载的支撑文件）让 50+ 个 skill 安装后 token 预算仍然可控。没有 Python 框架能同时提供文件系统发现、类型化工具过滤和预算控制这三项能力。纤维（fiber）相关细节见 [并发模型](concurrency-model.md)，skill 接口详情见下方 Q6。

简短版本：当你需要 Python 生态最大广度时，选 LangChain。当类型保证、可预测并发和持久化的 skill 抽象比 LangChain 的长尾集成更重要时，选 PAR。

## Q2. 什么时候用 OCaml SDK、Python 绑定还是 CLI？

PAR 提供三个入口，共享同一个运行时。它们不是三个产品，而是同一引擎的三扇门，选哪扇取决于你在构建什么。

| 入口 | 适合场景 | 不适合场景 |
|------|----------|------------|
| OCaml SDK | 你在写生产级 OCaml 代码，需要每个公共 API 的端到端类型覆盖 | 你不想在构建中引入 OCaml 工具链 |
| Python 绑定（PyPI 上的 `par_runtime`） | 你有现有 Python 服务，想要类型安全的 agent 运行时但不想重写技术栈 | 你需要绑定尚未暴露的某些高级配置字段（部分字段仅 SDK 可用） |

决策矩阵主要看谁掌控部署。OCaml SDK 是规范入口。每个公共 API 先在这里定义，每个行为都基于 OCaml 类型文档化，其他入口都是薄封装。如果你在写 OCaml，没有理由选别的。`docs/sdk/` 下的 SDK 参考是类型签名的权威来源。

Python 绑定面向 PAR 最初设计的目标用户：想要类型安全 agent 基础设施但不想用 OCaml 重写技术栈的 Python 后端工程师。`pip install par-runtime`，导入 `Runtime`，调用 `invoke` 或 `invoke_stream`。绑定通过 ctypes FFI 桥接同一个 OCaml 运行时。一个持久化的 OCaml domain 拥有 `Runtime`，Python 线程把工作闭包分发到它上面。Python 侧线程安全，无需持有全局锁。SDK 和绑定不一致时以 SDK 参考为准，绑定会跟进更新。

如需交互式编码 Agent 体验（已移除 CLI 的替代品），请参阅 [par-code](https://github.com/jcz2020/par-code)，一个基于此 SDK 构建的独立项目。

合理的演进路径：先用 Python 绑定验证安装和 provider 配置。当你需要完整类型覆盖、OCaml 自定义工具处理器、或绑定尚未暴露的功能时，切换到 OCaml SDK。两边的运行时行为完全一致，后续切换入口是重构而非重写。

## Q3. 流式输出是增量推送 token 的吗？

**是的，从 v0.5.3 开始。** `invoke_stream` 在后台守护线程中运行 `par_invoke_stream`；OCaml SSE 解析器在 LLM 产出每个 chunk 时触发 ctypes 回调，推送到 `queue.Queue`。Python 迭代器并发消费队列，第一个 token 在毫秒级内到达调用方，而非等整个响应完成。30 秒的生成，感知延迟从"30 秒黑屏然后一下子全出来"变成"首个 token < 1 秒，然后持续输出"。

**历史。** v0.5.1–v0.5.2 发布的是*缓冲式*流：OCaml 工作循环把所有 chunk 收集到 ref list，结束时序列化为 JSON，Python 在首次 `__iter__` 时解析整个数组。缓冲消除了初始 ctypes 回调设计中的 domain-lock 崩溃，但代价是所有 chunk 在 LLM 完成后一次性到达。v0.5.3 重新设计了 FFI（`caml_dispatch_chunk_to_c` external + 后台线程 + `queue.Queue`），在不引入 domain-lock 问题的前提下实现实时 chunk 交付。

**已知限制（v0.5.3）。** 从迭代器提前 break 会留下后台线程持有进程全局的 `ocaml_lock`，直到 LLM 流自然完成。在此期间后续 `par_*` 调用会阻塞。如果需要进一步调用，请完全消费迭代器。`par_cancel_stream` FFI（v0.5.4-beta 发布）通过 flag-check 模式缓解了这个问题，取消在下一个 chunk 边界生效（典型延迟 50–300 ms）。详见 [Streaming API 参考](../sdk/streaming.md) 和 CHANGES.md。

**不变的部分。** `Event` tagged union（`TextDelta`、`ToolCallStart`、`ToolCallDelta`、`UsageUpdate`、`Done`）与 OCaml `llm_response_chunk` ADT 逐字段对应。从缓冲式到增量式，API 形态没有变化，只有交付节奏改进了。

## Q4. 生产环境如何配置持久化？

PAR 提供两个持久化后端，通过 `runtime_config` 的 `persistence` 字段选择。选哪个是一次性决策，取决于你是否需要磁盘上的审计轨迹。详细说明见 [持久化与持久性](persistence-and-durability.md)。

**SQLite 是唯一的持久化后端。** 默认且唯一的持久化层。磁盘上的单个文件（测试用 `:memory:`）。零外部依赖。`sqlite3` 库是 `par` 包的硬依赖。WAL 模式处理 PAR 典型的读多写少负载。默认保留 TTL 为 7 天，在后端打开时裁剪。按你的审计窗口要求的频率备份 `.db` 文件即可。单个 SQLite 运行时的批量写入器可以处理每秒数百个事件。LLM provider 几乎总是瓶颈，不是数据库。

**多实例水平扩展（当前）。** SQLite 的文件锁无法跨容器的多进程写入同一文件，所以多个 PAR 运行时不能并发写入同一个 `.db` 文件。如果你今天需要多个 PAR 进程，在应用层做分片：一个运行时，一个数据库文件，按租户或会话分区。跨实例共享状态在路线图上规划为未来的远程层（bd issue `PAR-4dt`，目标 v0.6+），SQLite 目前不支持。

**测试用 Noop。** 丢弃所有内容。无事件总线、无写入 fiber、无 I/O。只关心 agent 行为的测试运行更快且不留下文件。持久化为 noop 时运行时完全跳过事件总线的接线，不会有死总线喂给死写入器。

**重要的调优旋钮。** `Persistence_writer` 在 mutex 保护的列表中缓冲事件，容量 1000，每 50 毫秒刷新一次。缓冲溢出时事件路由到事件总线的死信队列而非静默丢弃。保留裁剪基于时间戳，仅针对 `events` 表。`task_states` 和 `workflow_states` 不自动裁剪，因为它们的行代表可恢复状态。如果在受监管环境中需要长保留期，在 `runtime_config` 中提高 `event_retention_seconds`，并按审计窗口要求备份 `.db` 文件。

**双层架构即将到来。** 当前模型是单层：事件去往一个后端，仅此而已。未来版本计划双层设计：快速本地层（SQLite，低延迟，短保留期）加远程层（对象存储或未来的持久化后端，持久化，长保留期）。本地层吸收突发流量，异步转发到远程层。在它落地之前，通过 `event_retention_seconds` 选择你的保留窗口，接受目前只有一层的事实。

## Q5. PAR 能用 provider X 吗？

大概率可以，只要 provider 支持 OpenAI Chat Completions API。PAR 内置四个 provider，并提供自定义注册路径。

| Provider | 文本 | 工具调用 | 流式输出 | Embeddings (RAG) | 备注 |
|----------|------|----------|----------|-------------------|------|
| `` `Openai `` | yes | yes | yes | yes | 一等公民，参考实现。 |
| `` `Anthropic `` | yes | yes | yes | **no** | Anthropic 没有 embeddings API。RAG 请用 OpenAI 或本地 embedder。 |
| `` `Ollama `` | yes | yes | yes | yes | 本地运行。通过 OpenAI 兼容端点访问。 |
| `` `Mock `` | yes | yes | yes | yes | 测试用。发出所有事件类型。 |
| 自定义 | yes | yes | 取决于 | 取决于 | 任何 OpenAI 兼容服务（Cohere、Mistral、vLLM、LM Studio 等） |

有趣的情况是 Anthropic 和自定义 provider。

**Anthropic 和 RAG。** Anthropic 的 API 没有 embeddings 端点。Claude 系列只支持聊天。如果你想用 Anthropic 做聊天模型同时做 RAG，需要单独的 embeddings 来源。常见模式是用 OpenAI 的 embeddings API 或本地 embedder（比如 Ollama 的 `nomic-embed-text`）做嵌入步骤，然后用 Anthropic 做生成步骤。PAR 的 RAG 管道就是这么设计的，`invoke_with_rag` 接受聊天 provider 和 embeddings provider 作为独立的配置字段。

**Ollama 和 OpenAI 兼容的本地服务器。** Ollama 在 `http://localhost:11434/v1` 暴露 OpenAI 兼容端点。把 PAR 的 `` `Ollama `` provider 指向它，或注册一个指向相同 URL 的自定义 provider，就能获得同样的接口。同样的技巧适用于 vLLM、LM Studio、LocalAI 以及任何模拟 OpenAI Chat Completions 格式的服务器。流式行为取决于服务器。PAR 的 streaming 参考文档记录了 provider 支持情况；在依赖增量交付（v0.5.3 发布）之前，请先确认你的本地服务器能发出 Server-Sent Events。

**自定义 provider。** 如果你的 provider 不在列表中，按照 [自定义 LLM provider how-to](../howto/custom-llm-provider.md) 操作。模式和 Cohere、Mistral、Ollama 用的相同：实现 provider 接口，通过 `Runtime.register_agent` 或配置注册，PAR 就会把 invoke 路由到它。provider 接口在 `docs/sdk/` 下有文档。任何支持 OpenAI Chat Completions 的服务，无论是否支持工具调用，都可以无需新代码直接使用。

PAR 目前不支持的 provider 类别是非 OpenAI 兼容的私有 API（比如 Google Gemini 的原生 API，区别于它的 OpenAI 兼容层）。对于这些，写一个自定义 provider 适配器。抽象层就是为此设计的。

## Q6. skill 系统是什么？什么时候用？

Skill 系统（v0.5.2 Track A 发布）是 PAR 对可复用 agent 行为包的类型化抽象。它解决的是一个反复出现的问题：你有一个 agent 在正常工作，想给它一个专注的能力（PDF 提取、SQL 查询、代码审查）而不重写它的 system prompt 或工具列表。Skill 让你把能力打包成磁盘上的目录，按需加载。

**Skill 是什么。** Skill 是 `~/.par/skills/<name>/` 下的目录，包含一个带 YAML frontmatter 的 `skill.md` 文件。Frontmatter 声明：

- `system_prompt_override` 或 `system_prompt_append`：skill 激活时注入的提示材料。
- `tool_filter`：类型化 ADT，`All_tools`、`Only ["read", "ls"]` 或 `Except ["bash"]`。替代其他框架使用的字符串列表白名单。
- `trigger`：`Auto`（总是加载描述，LLM 判断）、`Manual`（仅显式调用）或 `Keyword [...]`（确定性匹配，可选 LLM 确认）。
- `expected_output`：可选的类型化 JSON schema，定义成功标准。前瞻性设计，v0.5.2 中仅作信息性用途，未来版本由 LLM judge 消费。

**为什么类型化重要。** 其他发布类似 skill 抽象的框架（LangChain Hub、OpenAI Assistants、CrewAI Tasks、Claude Code Skills）都用字符串列表做过滤。PAR 用 ADT。`Only` 和 `Except` 在多 skill 同时激活时按交集语义组合：两个 skill 分别声明 `Only ["a", "b"]` 和 `Only ["b", "c"]`，同时激活时结果是 `Only ["b"]`。最严格者胜出，安全失败。这种属性是事后补丁字符串列表 API 拿不回来的。

**什么时候用。** 当你有需要跨 agent 复用的行为，不想复制粘贴 prompt 和工具子集时，用 skill。PDF 提取 skill、SQL 查询 skill、代码审查 skill、安全审计 skill。3 级上下文加载模式在规模上保持 token 预算可控。第 1 级是元数据块，始终驻留在上下文中，每个 skill 大约 100 token。第 2 级是主体，skill 触发时延迟加载。第 3 级是支撑文件，永不加载到上下文中。2048 token 的描述预算（可通过 `skill_token_budget` 覆盖），安装 20 个 Auto skill 后运行时仍在预算内。溢出优先级是显式匹配优先，然后关键字匹配，最后按声明顺序的 auto。

**什么时候不用。** Skill 不适合一次性 prompt。如果你的 system prompt 只在一个 agent 中使用，直接写在 `agent_config` 里。Skill 真正发挥作用的场景是：同一行为包组合进多个 agent、非工程师需要添加能力而不想改 OCaml 代码、或你想通过 skills 目录跨项目共享能力。

v0.5.2 版本发布了数据模型、文件系统发现、YAML frontmatter 格式和类型化 `tool_filter` 组合。未来版本将添加 `expected_output` 的 LLM judge、基于 mtime 重扫描的热重载、以及用于列出、安装和验证 skill 的 `par skill` CLI。路线图在 `docs/v0.5.2-ROADMAP.md`。Skill 设计研究（包括影响范式选择的 5 框架对比）与路线图一起记录。

## 另请参阅

- [架构](architecture.md) 模块映射以及 skill 如何融入更大的 Runtime 结构
- [并发模型](concurrency-model.md) skill 组合所用的纤维（fiber）机制
- [持久化与持久性](persistence-and-durability.md) 持久化后端决策矩阵
- [Streaming API](../sdk/streaming.md) 增量 chunk 交付路径（v0.5.3）
- [Agent API](../sdk/agent.md) `Runtime.invoke`、`agent_config` 和工具注册
