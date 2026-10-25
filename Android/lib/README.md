# Android 扫码依赖

`zxing-core-3.5.3.jar` 是 ZXing Core 3.5.3，仅用于在设备内存中识别 QR Code。上游项目：<https://github.com/zxing/zxing>；许可证：Apache License 2.0。当前文件 SHA-256：`8d8064c1636fdaef7189dd9055c7d59950a8940a12f2293956446ec3c109fd82`。

`androidx-webkit-1.12.1.jar` 来自 AndroidX WebKit 1.12.1，仅从中提取 `classes.jar`，用于 document-start JS 注入。原始来源：<https://dl.google.com/dl/android/maven2/androidx/webkit/webkit/1.12.1/webkit-1.12.1.aar>；许可证：Apache License 2.0。当前仓库内文件（由此 AAR 提取 `classes.jar` 得到的 `androidx-webkit-1.12.1.jar`，不是 AAR 本身）SHA-256：`b03291b19348fdb4e7c5a97b316a19d71a583f45e68fd2b9ea2ea0a867e25cad`。

## SSH 同步依赖

- JSch 2.28.8（维护分支）：https://github.com/mwiede/jsch ，Maven Central 原始 JAR `https://repo.maven.apache.org/maven2/com/github/mwiede/jsch/2.28.8/jsch-2.28.8.jar`，SHA-256 `2afca1357d816028f2ac33f22407d2488a68406682973949cebb1b8ea6688a8b`，BSD 许可证（包含 jBCrypt、JZlib 通知）。
- Bouncy Castle 1.86：https://www.bouncycastle.org/download/bouncy-castle-java/ ，Maven Central 原始 JAR `https://repo.maven.apache.org/maven2/org/bouncycastle/bcprov-jdk18on/1.86/bcprov-jdk18on-1.86.jar`，SHA-256 `2af190b300cbb0b35e248ccf5f4a06b6072030aeb3da7a98ec73abe5b4cb371f`，Bouncy Castle（MIT）许可证。仅用于旧版 Android 的现代 SSH 算法支持。

两个原始 JAR 均与 Maven Central 提供的 SHA-256 核对；构建前由 `Scripts/verify-ssh-dependencies.py` 再次校验。完整许可证随 APK 的 `assets/ssh-licenses.txt` 分发。
