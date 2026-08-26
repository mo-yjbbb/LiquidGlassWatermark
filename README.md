# 液态玻璃水印

iOS 26 本地照片/Live Photo 水印工具。所有图像处理均在设备上完成，不上传照片。

## 功能

- 普通照片：生成新的带水印照片。
- Live Photo：对静态帧和配对视频逐帧统一渲染，重新写入标准配对标识并在保存后反查 `.photoLive` 与 `.pairedVideo`；声音保持在配对视频中。
- 自动读取拍摄时间、设备型号、焦距、光圈、快门、ISO 和位置（元数据存在时）。
- 输出保留原图 EXIF、TIFF、GPS 等拍摄元数据，仅重置已经烘焙到像素中的方向和尺寸字段。
- 提供“添加液态玻璃水印”App Shortcut，可在系统快捷指令中直接调用。
- 原 Live Photo 不修改，结果保存为新的照片图库资源。

## 生成未签名 IPA

1. 将本目录内容推送到 GitHub 仓库。
2. 打开 Actions，运行 **Build unsigned IPA**。
3. 在构建结果的 Artifacts 中下载 `LiquidGlassWatermark-signer-compatible`。
4. 爱思助手使用 `LiquidGlassWatermark-adhoc.ipa`；Sideloadly 使用 `LiquidGlassWatermark-clean.ipa`。

两个 IPA 均不包含开发者证书、Apple ID、设备 ID 或描述文件。ad-hoc 版只带可被重签工具替换的本地占位签名。

工作流不读取证书、Apple ID 或描述文件。

## 本地 Xcode 构建

需要 Xcode 26 和 XcodeGen：

```sh
brew install xcodegen
xcodegen generate
open LiquidGlassWatermark.xcodeproj
```

在 Xcode 中选择自己的 Team，并将 Bundle Identifier 改成个人唯一值后运行。

