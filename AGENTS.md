# 仓库协作约定

本文件适用于本仓库（学习日程 / study-planner）的全部改动。面向使用者的说明见 [README.md](README.md)。

## DSH 自动委派规则

- 简单、重复、机械、低风险的任务优先交给 `delegate_to_dsh` 执行。
- 复杂推理、架构设计、调试和带风险的修改由主执行者自己处理。
- DSH 完成后，主执行者必须审查其结果，不能直接采信。
- 审查中发现明显问题时，先要求 DSH 修正；问题复杂或反复出错时，由主执行者接管。
- 不为了委派而委派：委派本身不产生价值，只在能降低风险或节省时间时才委派。

## 固定开发流程

### 一轮的定义

一轮指一个明确的修改目标，或一轮用户反馈；不是每次保存文件。

### 每轮步骤

1. 检查本轮的 diff，确认改动范围与目标一致。
2. 做与本次修改相关的必要验证，能自动验证的必须跑。
3. 明确添加本轮涉及的文件，使用包含具体信息的 commit message 提交。
4. 推送到已有 origin `https://github.com/DenseFLoe/study-planner.git` 的当前工作分支，并确认推送成功。
5. 推送失败时如实报告并保留本地提交；不强制推送，不覆盖用户工作。
6. 个人数据、密钥与签名材料、日志、构建产物一律不得提交。

### 打包与本地验收

代码改动推送后，按影响范围选择平台，用现有脚本打包：

| 平台 | 构建命令 | 产物 |
| --- | --- | --- |
| macOS | `./Scripts/build-dmg.sh` | `dist/学习日程-macOS-<短SHA>.dmg` 及 `.dmg.sha256` |
| Android | `./Android/build.sh` | `dist/学习日程-安卓版.apk` |

- macOS 受影响的每一轮代码改动，只向用户交付 `./Scripts/build-dmg.sh` 生成、可拖到「应用程序」安装的 DMG 及同名 SHA-256 校验文件，不单独交付 `.app`，也不提供 `.app` 下载链接或交付路径。`.app` 仅作为开发/打包的内部中间产物（DMG 内含 `.app` 供正常安装）。
- 每次成功生成并校验 macOS DMG 后，自动正常退出当前运行的「学习日程」，等待保存完成和进程退出，再挂载本轮 DMG，用其中的应用覆盖更新 `/Applications/学习日程.app`。这是用户已授权的固定本地安装流程，无需重复询问。
- 覆盖安装须保留课表数据、设置和本地凭证；安装后验证应用与本轮 DMG 内的版本一致，并卸载本轮挂载的镜像。若无法正常退出或覆盖失败，保留原安装并报告，不强制终止保存中的应用。
- Android 仍按影响范围决定是否生成 APK；只改动 macOS 时无需重新构建 Android APK。
- 本地验收从打包产物进行，而不是直接从源码目录运行。
- 能自动验证的自行验证；需要用户交互的，给出具体操作步骤，并如实说明哪部分尚未验证。
- 发现问题并修复后进入下一轮：独立 commit、push、build、test。
- 仅文档修改无需重新打包。

### 平台功能边界

- 学习监督（应用绑定、播放检测、后台监督、系统通知及提示音）仅限 macOS。Android 明确不加入这些能力；后续即使出现「全部同步 / 对齐 Mac 功能」这类宽泛指令，也不得据此改变本边界，除非用户明确重新授权。
- Android 的极限压缩方案只展示由 Mac 计算、经云同步传来的结果：不包含、不运行压缩算法，不提供算法参数，也不写入正式日程。手机上的输入发生变化后，旧结果必须标记为「待更新」。
- Android 已获授权补齐立即学习、继续上课和主页字号设置；监督与极限压缩仍遵守上述平台边界。

### 发布边界

默认不创建公开 GitHub Release，不上传 app/apk/dmg/zip，不做任何部署。

### 每轮报告

每轮结束报告：提交的简短 SHA、推送分支、测试结果、本地安装包路径。macOS 只列 DMG 和同名 `.dmg.sha256` 校验文件，不列 `.app`。

## 本机 Android 开发环境（用户约定，2026-11-13）

- 后续 Android 开发统一使用已安装的 Android Studio 及其共享 SDK。此 Mac 的 SDK 为 `$HOME/Library/Android/sdk`，用 `ANDROID_HOME` 指向该目录；兼容旧脚本需要 `ANDROID_SDK_ROOT` 时，两者必须一致。不要再在各项目内下载独立 SDK 副本。
- 按项目实际要求，在 Android Studio 的 SDK Manager 中为共享 SDK 补齐对应版本的 SDK Platform、Build-Tools，以及确有需要的 NDK/CMake。不要因为本机只装有较新平台就擅自升级项目的 compileSdk、targetSdk 或工具版本。
- JDK 优先检查 Android Studio 自带的 `/Applications/Android Studio.app/Contents/jbr/Contents/Home`；先确认与项目 Gradle、插件及脚本兼容，再设置 `JAVA_HOME`。不兼容时使用已有的兼容 JDK。
- 默认不创建或启动 Android 模拟器，不下载 AVD 或系统镜像；需要设备验收时使用连接的安卓真机。未做真机验收必须如实说明。
- 沿用项目现有构建和签名流程，把 SDK 路径接到共享安装。机器专属配置（如 Gradle 的 `local.properties`）须被 Git 忽略且确认未被跟踪；凭证仍从环境变量或密钥管理服务读取。
- 以上路径约定针对本机；CI 和其他主机保持各自兼容的工具配置，不硬编码此 Mac 的绝对路径。

本项目的 `Android/build.sh` 使用 `STUDYPLANNER_ANDROID_BUILD_TOOLS` 和 `STUDYPLANNER_ANDROID_PLATFORM_JAR`：分别指向共享 SDK 内匹配版本的 `build-tools/<版本>` 与 `platforms/android-<API>/android.jar`。旧的 `Android/tools/sdk*` 已清理，后续 Android 工作先接通共享 SDK 并验证，不恢复这些项目内副本。
