# 智能客服：合成数据集成验证

这里的 `helper.cjs` / `--agent-prototype` 仍是可选合成实验，不是正式客服。入口在 `PlannerStore` 初始化前分流，不加载正式课表、同步配置、浏览器信息或钥匙串。该实验没有真实模型 HTTP 实现，也不接受 API 密钥。

同目录新增的 `assistant-helper.cjs` 使用独立协议 2，为主应用的只读助手提供 SDK 工具循环。它只通过管道向 Swift 请求查询和发送，自己不能联网，也不接收密钥；原生程序核对每份精确请求；正式助手先合并进行一次「课表内容确认」，普通必要工具数据随后自动发送，新增敏感或不确定内容需另行确认，疑似凭证直接阻止。协议 1 的 `syntheticOnly` 字段仅说明原验证入口；协议 2 用单独摘要校验。正式助手与纯合成的 `--assistant-preview` / `--assistant-check` 边界见仓库 README。本轮开发验证只用模拟服务，没有增加真实 API 请求。

以下三次审批说明仅指协议1的旧合成实验。协议2正式助手及其 `--assistant-preview` / `--assistant-check` 使用上述一次确认流程，记忆、隐私和界面详见仓库 README。

## 验证范围

- Swift 原生审批界面和 `StudyCore` 合成课表 → 本机 Node 辅助进程 → AI SDK `ToolLoopAgent`。
- OpenAI Chat Completions 与 Anthropic Messages 两种真实 SDK 序列化器，响应由 Swift 本机模拟器提供；每轮三次模拟模型请求、两次本地工具查询。
- 第一份问题、第一次工具结果、第二次工具结果分别审批。展开显示最终请求正文与请求头；空认证字段只是序列化占位，无密钥。
- 审批由 Swift 生成并绑定正文、接收方、快照和一次性 ID，两分钟过期；拒绝、取消、内容变化、版本变化和重放均停止。
- 合成课程的 120 分钟学习 + 至少 15 分钟休息无法装入 120 分钟窗口；未排入 60 分钟不当作客观缺口。证据由现有引擎产生。
- Node 26.7.0 权限模式禁止网络、文件写入、非辅助脚本文件读取、子进程；每轮启动用负向探针检查。子进程环境使用白名单，不继承凭据或 `NODE_OPTIONS`。

这是对受信任固定辅助程序的限制验证，**不是经审计的恶意代码安全沙箱**；尚未验证 XPC 独立沙箱、Developer ID 公证或真实模型的推理能力。当前模拟器返回固定顺序和固定回答；精确回答断言只用于合成测试，不能作为通用幻觉检测器。当前桥接验证非流式 JSON，流式传输另行验证。

## 运行和打包

需要 macOS、项目原有 Swift 工具链。准备脚本下载固定 SHA-256 的 Node 官方运行时，并按 lockfile 安装公开 npm 依赖；安装脚本、审计上报和私人 npm 配置均禁用。依赖与运行时只进入被忽略的构建目录，许可证随可选包附带。

```sh
bash Scripts/test-agent-prototype.sh
STUDYPLANNER_AGENT_PROTOTYPE=1 ./Scripts/build-dmg.sh
python3 Scripts/test-agent-prototype-package.py dist/学习日程-macOS-<短SHA>-agent-prototype.dmg
```

默认 `./Scripts/build-dmg.sh` 不下载、不包含该辅助运行时。实验 DMG 使用独立的 `-agent-prototype` 后缀和同名 `.dmg.sha256`，不会覆盖同一提交的常规 DMG。

按仓库安装流程装入实验 DMG 后，单独打开验证窗口：

```sh
open -n -a 学习日程 --args --agent-prototype
```

选择模拟协议并开始，先展开“查看实际发送内容”核对，再允许或拒绝。本轮只有模拟器，拒绝后不会出现后续工具证据。连续允许三次后出现最终回答和两张证据卡。中途“取消本轮”停止辅助程序，正常应用的数据不受影响。

无 UI 的打包探针为 `--agent-prototype-check`，仅用于此合成入口：自动检查两个协议的成功链、第一次拒绝、第二次拒绝以及审批前取消；不代表真实发送的用户审批。

## 进一步验证

真实 DeepSeek 测试必须单独完成安全凭据注入、精确合成请求审核和最多两次请求的硬上限，关闭自动重试；此实验入口不能切换到线上地址。没有测试结果时不得宣称真实 API、流式 UI、macOS 14 真机或 x64 成品已验证。

参考：[AI SDK Agent](https://ai-sdk.dev/docs/agents/overview)、[自定义传输](https://ai-sdk.dev/providers/ai-sdk-providers/openai)、[Node 权限模型](https://nodejs.org/api/permissions.html)。
