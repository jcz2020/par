<!-- language: zh -->

[English](https://github.com/jcz2020/par/blob/main/docs/explanation/multimodal-completion.md) · **简体中文**

# 2026-10-19：补齐两种 SDK 的多模态输入

**变更前**：首轮多模态实现只向 OCaml SDK 开放富内容输入，尽管既有内容块编解码器
已经提供 JSON 表示。图片解码还强制要求新增的 `detail` 键，旧图片存档因此无法加载。
本地文件读取失败后，打开的通道会泄漏。

**变更后**：两种 SDK 均提供同步 `Runtime.invoke_content`。Python 辅助函数生成
既有的带标签数组内容块表示，`par_invoke_content` 通过既有分发和响应路径转发，
显式传递 `save` 与 `update_current`。格式错误的 JSON 或内容块在 provider I/O 前
失败。共享运行时只接受文本和图像用户块；工具协议块属于引擎。缺少的图片 `detail`
默认为 `None`。本地文件通道在成功和失败时均关闭。

**原因**：推迟 Python 不依赖尚未完成的上游，也不需要技术验证；那是范围妥协，
不是正确的架构边界。现在扩展此功能，可以避免跨版本维护能力不同的两套 SDK。

**决策性质**：架构正确，一次补齐（STRATEGY §11 R1/R3）。同步富内容输入不再保留
Python 延期项。复用既有 JSON 表示，避免引入第二套传输格式。

**影响范围**：OCaml 运行时校验、内容块 JSON 解码、消息文件辅助函数、OCaml/C 桥、
ctypes 声明、Python 内容辅助函数及导出、双语 SDK 文档和回归/集成测试。
已经发布的 v0.11 beta tag 不变。这些变更仍是开发中工作，本决策不授权 bump 版本号
或额外发布。

`lib/par.ml` 的公开门面导出运行时；用法示例位于 `docs/sdk/content_blocks.md`
和 `docs/sdk/agent.md`。

**验证约定**：测试覆盖完整 Python → C → OCaml → 本地 HTTP provider 调用链，
包括 URL/base64/本地图片、非法输入、旧 JSON、未知 agent 及持久化/当前状态开关。
OCaml 回归覆盖新旧图片解码和文件读取失败后的描述符清理。
最终本地运行收集到 1634 个 OCaml 测试，Python 174 个通过，另有 20 个既有跳过项
和两个既有回调内存警告。

**回退方式**：回退本次补齐变更，不改写已有 tag。新 C 符号、Python 辅助函数和方法
必须一起移除；若回退会导致已保存对话无法读取，应保留图片存档解码兼容性。
