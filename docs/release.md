# Android 正式发布

正式发布流程位于 `.github/workflows/stable_release.yml`。当前版本为 `1.4.1+14`，发布标签为 `v1.4.1`。推送到 `release/scholar-ui-v1.4.1` 会运行该流程，也可在同一分支手动运行。发布前确认当前提交就是预期发布内容；流程使用触发时的完整提交 SHA，不从其他分支获取应用源码。

## 固定签名

从 1.4.0 开始使用本次新建的固定发布签名：PKCS12、RSA 3072 位，别名 `celechron-release`，证书有效期 10000 天。私钥由维护者长期安全备份，后续版本复用同一密钥；CI 不负责生成签名密钥。公开证书 SHA-256：

```text
a7634b405b936d84326d368842beee9cac78ab17090dfec6d7363f07ae4fd546
```

在仓库 Settings → Secrets and variables → Actions 新增一个 Secret，名称为 `ANDROID_RELEASE_SIGNING_JSON`，值为私有备份包内 `ANDROID_RELEASE_SIGNING_JSON.json` 的完整内容。JSON 包含 `keystore_base64`、`store_password`、`key_password`、`key_alias` 四个字段；无需另建密码 Secret。它取代旧的 `ANDROID_KEYSTORE_BASE64` 配置，不能将新 JSON 放入旧名称。

私有备份包含 keystore、密码、该 JSON 和公开证书，请另行保存到维护者控制的安全位置，云工作区不是长期备份。不得把私有备份、keystore、密码或 JSON 放入 Git、日志、Actions artifact、Issue 或 Release 附件。GitHub Secret 只能写入或替换，不能从界面取回原值；APK 也无法还原签名私钥。

正式 CI 将签名文件恢复到受限临时目录，屏蔽密码输出，核验公开证书指纹，然后通过 `CELECHRON_RELEASE_KEYSTORE`、`CELECHRON_RELEASE_STORE_PASSWORD`、`CELECHRON_RELEASE_KEY_PASSWORD`、`CELECHRON_RELEASE_KEY_ALIAS` 传给 Gradle 的 `signingConfigs.release`。`CELECHRON_REQUIRE_RELEASE_SIGNING=true` 防止正式构建退回调试签名。缺失 Secret、解析失败、配置不全或指纹不匹配时必须停止；构建后再次验证 APK 的实际证书。

本地正式构建也使用上述环境变量。未配置发布变量的开发/预览构建保留原调试签名；它们不是正式发布包，不能用来替代固定签名。密码通过环境或受限文件传递，不能出现在命令参数或输出中。

1.4.1 沿用 1.4.0 的固定签名，可直接覆盖安装 1.4.0 并保留本地数据。1.4.0 之前使用不同签名的正式包或预发布包不能直接覆盖升级；首次迁移到固定签名时，先导出需要保留的数据再卸载旧版，卸载会清除本地数据。此后相同固定证书、相同包名且版本号更高的正式包可以覆盖升级。不要每次构建重新生成密钥，也不要通过移动标签替换已发布的正式版本。

## 校验与发布

1.4.1 的学业页分组调整已通过局部静态分析及 18 项现有相关测试。本地原生渲染检查另覆盖明暗主题、320 像素窄屏与 1.6 倍字号，以及成绩详情、课程列表和实践详情跳转；正文保留单层玻璃面板，分组标题直接显示在页面背景上。

液态玻璃改动还需运行原生渲染回归（默认软件渲染测试不能执行折射 shader）：

```sh
flutter test --no-pub --enable-impeller --concurrency=1 test/refractive_glass_test.dart test/refractive_glass_rendering_test.dart test/refractive_glass_overlap_test.dart test/refractive_glass_performance_test.dart
```

1.4.0 的本地对照覆盖 DPR 1、2、2.75、3、3.5、中文细字、玻璃重叠及滚动缩放。97 张截图中仅一个像素的单通道相差 1/255，其余一致。1000 次静止提交分别只复用一个折射滤镜和一个模糊滤镜；几何与光学参数变化时仍更新快照。测试只证明这些场景的视觉一致性和对象复用，未测量手机 GPU 帧耗时或功耗。

1. 检查 `pubspec.yaml` 与工作流的版本一致，且标签不存在于其他提交、Release 尚未创建。
2. 恢复并核验固定签名；安装 Flutter 3.38.1、Java 17 和 Gradle 8.13。
3. 用 `flutter pub get --enforce-lockfile` 安装依赖，运行完整 `flutter test --no-pub`，然后构建单个通用 APK。
4. 使用 `apksigner` 校验签名及固定证书指纹；使用 `aapt` 校验包名、版本、最低 Android 版本和三个 ABI；校验编译后的液态玻璃 shader 已包含在 APK 中。
5. 生成并复核 `SHA256SUMS` 和公开的 `BUILD_INFO.json`，然后创建正式 Release，标为 latest，并验证远端标签指向触发提交。工作流不会覆盖已有标签或 Release。

通用 APK 包含 `arm64-v8a`、`armeabi-v7a` 和 `x86_64`，支持 Android 9 及以上，无需分卷。Release 附件只包含 APK、校验值和不含机密的构建信息。发布说明在工作流的 `Publish the stable release` 步骤中维护，应描述实际实现和验证范围，不应将桌面渲染测试表述为手机实测。

恢复签名文件的步骤使用临时目录和仅所有者可读权限；工作流结束时清理该目录。构建产物保留 14 天，Release 附件长期保留。若发布失败，先检查远端是否已经创建标签或 Release，再决定重试；不可强制移动正式标签。
