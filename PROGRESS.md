# Podcast iOS15 开发进度

最后更新：2026-07-15（Asia/Shanghai）

## 项目目标

在 `D:\codex\aisten\podcast iOS15` 从零实现一个最低支持 iOS 15 的播客语言学习 App。功能和交互以用户提供的 Aisten 6.3.5 IPA 为基准，包括播客播放、逐句文稿、上下文翻译、词典、生词库、句子收藏以及 Anki 导出。使用 GitHub Actions/macOS 构建，不链接原 6.3.5 的不兼容可执行文件。

## 总任务框架

- [x] 1. 分析两个下载目录，确认它们只是官网而非 iOS 源码
- [x] 2. 审计 6.3.5 IPA 的功能、资源和 iOS 15 不兼容原因
- [x] 3. 建立 XcodeGen + SwiftUI 工程骨架，Deployment Target = iOS 15.0
- [x] 4. 实现播客搜索、RSS 订阅、刷新、播客和单集列表
- [x] 5. 实现 AVPlayer 播放、后台音频、锁屏控制、进度、倍速、跳转和逐句循环
- [x] 6. 实现 Podcasting 2.0/SRT/VTT/JSON 文稿解析与导入
- [x] 7. 移植 scribe2srt 的 Microsoft Edge Translator 令牌和批量请求流程
- [x] 8. 实现前一句 + 当前句 + 后一句参与的上下文翻译和全文翻译
- [x] 9. 实现在线英文释义、iOS 系统词典、生词库和句子收藏
- [x] 10. 实现 CSV 导出和 Anki APKG 数据库/压缩包生成
- [x] 11. 接入 whisper.cpp 设计：官方 XCFramework、按需模型下载、音频解码、逐句时间戳和缓存
- [x] 12. 实现 Aisten 6.3.5 风格三栏首页、逐句播放页、底部波形控制和生词统计页第一版
- [x] 13. 添加 GitHub Actions 的 XcodeGen、whisper.cpp 准备、iPhone Release 构建和 IPA 打包流程
- [x] 14. 补齐 App Icon 全套 iPhone/iPad/App Store 尺寸资源
- [ ] 15. 在 GitHub Actions/macOS 执行首次真实编译，逐项修复 Swift/Xcode 错误
- [ ] 16. 对 APKG 用桌面 Anki 做导入验证
- [ ] 17. 在 iOS 15.8 真机验证启动、RSS、播放、翻译、转写和导出
- [ ] 18. 根据真机截图继续细调，达到更接近 6.3.5 的视觉和手势体验

## 已确认的 6.3.5 功能证据

- 二进制包含 `AudioTranscriber`、`WhisperContext`、`WhisperModelManager` 和 `ggml-base-q5_1.bin`，证明有离线自动转写。
- 二进制包含 `Dictionary`、`Translator`、`UIReferenceLibraryViewController` 相关调用，证明有词典和翻译链路。
- 二进制包含 `ExportToAnkiNoteView.swift`、`ExportVocabularyPanel.swift`、`collection.anki2`、`Aisten_Sentences.apkg` 和多套 Anki 模板，证明支持 APKG 导出。
- 官网旧更新日志还明确写有 CSV 导出并导入 Anki。

## 当前技术决定

- UI：原生 SwiftUI，避免使用任何仅 iOS 16/17 可用的 SwiftUI API。
- 播放：AVPlayer + AVAudioSession + MPRemoteCommandCenter。
- 翻译：与 `D:\codex\scribe2srt` 相同的 Edge Microsoft Translator 授权端点；上下文由前后句拼接后参与请求。
- 转写：whisper.cpp 1.9.1 官方 XCFramework；`ggml-base-q5_1.bin` 首次使用时按需下载约 60 MB。
- 文稿：优先 RSS 的 `podcast:transcript`；支持手动 SRT/VTT/JSON；无文稿时使用 Whisper。
- 数据：目前使用本地 JSON 原子写入，不依赖 iOS 16 SwiftData。
- Anki：SQLite3 生成 `collection.anki2`，ZIPFoundation 打包为 `.apkg`。
- 工程：`project.yml` 由 XcodeGen 生成 `.xcodeproj`；GitHub Actions 使用 Xcode 15.4 构建 iOS 15 目标。

## 当前已知限制/风险

- 当前机器是 Windows，没有 Xcode，因此现阶段完成的是代码与静态检查，尚未完成真实 Swift 编译。首次 GitHub Actions 构建预计可能暴露少量 SDK 类型或签名错误。
- 本地下载 whisper.cpp XCFramework 时网络极慢并超时；已改为让 GitHub Actions 运行 `scripts/prepare-whisper.sh` 下载完整依赖。
- Microsoft Edge Translator 的公开授权端点不是长期稳定承诺的正式 SDK，服务策略改变时翻译会失败，但应显示错误而不是闪退。
- APKG 结构已经按 Anki 2.1 collection schema 生成，但尚未用桌面 Anki 做实际导入验证。
- App Icon 已按官方图标素材生成全套尺寸；仍需由 Xcode 的 asset compiler 做最终校验。
- 静态校验发现 ZIPFoundation 0.9.19 的 `Archive` 初始化器已改为 `throws`，已按实际 API 修正；whisper XCFramework 为动态 framework，工程已改为 Embed & Sign。
- 已检查并移除 Swift 5.7 可能不支持的 tuple key-path 写法，改为普通闭包，降低首次编译风险。
- 工程静态校验已通过：17 个 Swift 文件；所有 Assets JSON、Info.plist、`project.yml` 和 GitHub Actions YAML 均可解析；源码扫描未发现 NavigationStack、SwiftData、Charts、TranslationSession 等 iOS 16+ API。
- Windows 下载依赖产生的残缺 whisper ZIP 已清理，仓库不会误带损坏文件；完整 XCFramework 由 Actions 自动下载。
- 首次 Actions 在 `resolvePackageDependencies` 前失败：最新版 Homebrew XcodeGen 生成 `objectVersion = 77`，Xcode 15.4 无法读取。已参考 `cbrain ios15` 的旧格式工程，将 XcodeGen 固定为 2.41.0、工程目标版本改为 Xcode 15.4，并增加 `objectVersion <= 60` 自动校验及失败日志 Artifact。该次失败没有进入 Swift 编译阶段。
- ad-hoc IPA 适合 TrollStore或由侧载工具重新签名；普通未越狱设备仍需合法开发者签名。

## 下一步接续入口

1. 将整个 `podcast iOS15` 上传到 GitHub 仓库并运行 `Build iOS 15 IPA` Action。
2. 根据 Action 的首个编译日志修复所有错误，直到得到 IPA Artifact。
3. 用桌面 Anki 验证导出的 `.apkg`。
4. 安装到 iOS 15.8 真机测试，并根据崩溃日志/截图继续调整。

## 关键文件

- `project.yml`：工程配置和 iOS 15 Deployment Target
- `.github/workflows/build-ios.yml`：GitHub Actions 构建/打包
- `PodcastIOS15/Services/PlayerManager.swift`：播放器
- `PodcastIOS15/Services/MicrosoftTranslator.swift`：微软翻译
- `PodcastIOS15/Services/WhisperTranscriber.swift`：离线自动转写
- `PodcastIOS15/Services/AnkiExporter.swift`：CSV/APKG 导出
- `PodcastIOS15/Views/PlayerView.swift`：6.3.5 风格逐句播放页
- `README.md`：构建和使用说明
