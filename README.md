# 液态玻璃水印

iOS 26 本地照片/Live Photo 水印工具。所有图像处理均在设备上完成，不上传照片。

## 功能

- 普通照片：生成新的带水印照片。
- Live Photo：先复制原始实况，再通过 `PHLivePhotoEditingContext` 对副本的静态帧和视频帧统一渲染；声音由系统编辑管线保留。
- 自动读取拍摄时间、设备型号、焦距、光圈、快门、ISO 和位置（元数据存在时）。
- 提供“添加液态玻璃水印”App Shortcut，可在系统快捷指令中直接调用。
- 原 Live Photo 不修改；生成的副本属于可撤销编辑，可在照片 App 恢复。

## 生成未签名 IPA

1. 将本目录内容推送到 GitHub 仓库。
2. 打开 Actions，运行 **Build unsigned IPA**。
3. 在构建结果的 Artifacts 中下载 `LiquidGlassWatermark-unsigned`。
4. 解压得到 `LiquidGlassWatermark-unsigned.ipa`，自行签名后安装。

工作流不读取证书、Apple ID 或描述文件。

## 本地 Xcode 构建

需要 Xcode 26 和 XcodeGen：

```sh
brew install xcodegen
xcodegen generate
open LiquidGlassWatermark.xcodeproj
```

在 Xcode 中选择自己的 Team，并将 Bundle Identifier 改成个人唯一值后运行。

