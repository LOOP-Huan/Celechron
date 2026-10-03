# Android 正式发布

正式发布流程位于 `.github/workflows/stable_release.yml`。当前版本为 `1.4.0+13`，发布标签为 `v1.4.0`。推送到 `release/liquid-glass-v1.4.0` 会运行该流程，也可在同一分支手动运行。发布前确认当前提交就是预期发布内容；流程使用触发时的完整提交 SHA，不从其他分支获取应用源码。

## 固定签名

流程沿用项目原有签名身份。仓库的 Actions secret `ANDROID_KEYSTORE_BASE64` 必须包含原签名 keystore 的 Base64 编码；不得把 keystore、编码内容或私钥放入 Git、构建日志、Actions artifact 或 Release 附件。维护者应另行安全备份原始 keystore。

当前 Gradle 配置使用 `signingConfigs.debug`。为保持与已有安装包的兼容性，工作流将原 keystore 恢复到独立的 `ANDROID_USER_HOME/debug.keystore`，使用原有 `androiddebugkey` 别名和 `android` 密码。证书身份由下列 SHA-256 指纹严格锁定，不能用每次构建自动生成的测试证书代替：

```text
20ebb2a729fb56f041f49b95cabb63d6cfa85e85890c1037f13c1bad2483367c
```

缺少 secret、解码失败或指纹不符时，工作流在安装 Flutter 和构建 APK 前停止，不能生成或发布替代签名的正式包。构建后再次检查 APK 的实际签名。若确实需要更换签名身份，应先明确安装迁移方案，配置并备份新密钥，同时审查更新工作流的固定指纹和签名配置；仅改标签或版本号不能让不同证书的 APK 覆盖安装。

GitHub Actions 的 secret 页面只能写入或替换机密，不能取回原值。已有 APK 仅含公钥证书，无法还原签名私钥。缺少原密钥时，不要从公开构件寻找或发布私钥。

## 校验与发布

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

此前预发布包使用每次 CI 新建的测试证书，正式包不能直接覆盖它们。安装前应先导出需保留的数据，再卸载预发布包；卸载会清除本地数据。使用相同固定证书且版本号满足升级要求的正式包可以正常覆盖升级。

恢复签名文件的步骤使用临时目录和仅所有者可读权限；工作流结束时清理该目录。构建产物保留 14 天，Release 附件长期保留。若发布失败，先检查远端是否已经创建标签或 Release，再决定重试；不可强制移动正式标签。
