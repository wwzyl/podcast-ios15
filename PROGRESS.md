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
- [x] 15. 在 GitHub Actions/macOS 执行首次真实编译并成功产出 IPA
- [ ] 16. 对 APKG 用桌面 Anki 做导入验证
- [ ] 17. 在 iOS 15.8 真机验证启动、RSS、播放、翻译、转写和导出
- [ ] 18. 根据真机截图继续细调，达到更接近 6.3.5 的视觉和手势体验
- [x] 19. 修复迷你播放条位置并支持点击进入完整播放页
- [x] 20. 实现单集音频下载进度、本地缓存、失败重试和播放准备/缓冲状态
- [x] 21. 从 6.3.5 资源复用并内置 `ggml-base-q5_1.bin`，取消运行时模型下载
- [x] 22. 实现每约 30 秒一批的渐进 Whisper 转录、立即展示和增量缓存
- [x] 23. 补齐 RSS/Apple Podcasts 封面三层兜底
- [x] 24. 生词/短语保存音标、译义、词典释义、原句、原句翻译、来源和时间点
- [x] 25. 补齐 Anki 问答题、填空题和输入填空题三种 6.3.5 风格导出入口
- [x] 26. 按 6.3.5 分离整集缓存与生词原声片段，避免清理播客后丢失例句音频
- [x] 27. 实现 1周/15天/1个月/不删除的整集音频缓存策略和缓存管理页
- [x] 28. 将生词原声作为 Anki APKG 媒体和 `[sound:...]` 字段导出

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
- 第二次 Actions 已成功解析依赖并进入全部 17 个 Swift 文件的 Release 编译。仅发现 `PlayerManager` 两处弱引用 `self` 被并发 Task 再次捕获的错误；已修复这两处，并同步审计/修复锁屏播放、暂停、切换、前后跳转和进度拖动的全部同类回调。ZIPFoundation 已按本次成功解析结果固定为 0.9.20。
- 首个成功产出的 IPA 在 iPhone 7 / iOS 15.8.2 启动时被 dyld 终止：官方 whisper 1.9.1 XCFramework 引用了 iOS 15 Accelerate 中不存在的 `_cblas_sgemm$NEWLAPACK$ILP64`。已停止使用官方预编译框架，改由 Actions 从同版源码构建最低 iOS 15.0 的 arm64 XCFramework，明确关闭 BLAS 和 Accelerate、保留 Metal/CPU，并在打包前用 `nm`/`otool` 自动拒绝任何 `NEWLAPACK`、`ILP64` 或 Accelerate 动态依赖。新增 Actions 缓存避免每次重复编译。
- 因首次需要从源码编译 whisper，Actions 超时上限由 30 分钟提高到 60 分钟；缓存命中后后续构建不重复编译。
- 修复版应用版本已提升为 1.0.1 (2)，便于确认手机安装的不是仍含官方 whisper 框架的旧包。
- 播放与学习交互修订版提升为 1.1.0 (3)。迷你播放条改为各 Tab 内容内的安全区插入，不再遮挡“生词”标签，点击标题/封面可全屏进入播放页。
- 单集改为显式下载进度 → 本地播放 → 同一文件渐进转录；下载失败可重试，播放器显示准备和缓冲状态。
- 6.3.5 包内已有的 59,707,625 字节 `ggml-base-q5_1.bin` 已校验后复制为工程资源，App 优先从 Bundle 读取，不再依赖 Hugging Face 网络。
- RSS 封面新增标准 `<image><url>`、iTunes image、Media thumbnail、Atom logo/icon 和 Apple 搜索结果 fallback。
- 生词页及 APKG/CSV 字段已扩展为单词/短语、音标、上下文译义、词典释义、原句、原句翻译、节目来源和时间点；APKG 增加问答、Cloze 和输入答案三种模板。
- 进一步确认 6.3.5 使用 `AutoDeleteManager` 管理整集缓存，并用独立 `AudioClip` 保存生词原声。新 App 已实现同样分层：整集缓存按最后使用时间自动清理，转录文本和 `VocabularyAudioClips` 不受影响；删除对应生词时才删除片段。
- 缓存管理页已加入 6.3.5 同款 `1周后 / 15天后 / 1个月后 / 不删除` 策略、缓存大小和手动清理。默认 15 天。
- 从 6.3.5 二进制恢复出官方模型名和核心字段/HTML：`Aisten Word QA_2025-03-11`、`Aisten Word Cloze_2025-11-08`、`Aisten Word Type Cloze_2025-11-08`，以及 Word/WordAudio/Symbol/Sentence1/Audio1/Source1/Translation1/Definition 等字段。APKG 导出器已改用这些结构，并把独立原声片段写入 media 映射。
- ad-hoc IPA 适合 TrollStore或由侧载工具重新签名；普通未越狱设备仍需合法开发者签名。
- 1.1.0 (3) 的下载管理、渐进转录、内置模型、独立例句音频和官方风格 Anki 模板代码已完成静态校验，但尚待下一次 GitHub Actions 真实编译与真机验证。

## 下一步接续入口

1. 将整个 `podcast iOS15` 上传到 GitHub 仓库并运行 `Build iOS 15 IPA` Action。
2. 根据 Action 的首个编译日志修复所有错误，直到得到 IPA Artifact。
3. 用桌面 Anki 验证导出的 `.apkg`。
4. 安装到 iOS 15.8 真机测试，并根据崩溃日志/截图继续调整。

## 2026-07-15：1.2.0（4）本轮进度

- [x] 29. 将转录任务提升到 App 根节点持有；退出播放页后任务继续运行，回到页面自动接收进度和已完成句子。
- [x] 30. 无 RSS 文稿时，在整集音频下载完成后自动启动 Whisper，不再要求手动点击。
- [x] 31. Whisper 改为 20 秒低延迟分析窗 + 5 秒重叠上下文；显示节奏由完整句决定而非固定 30 秒批次，并跨窗口合并碎片。
- [x] 32. 修复 iPhone 7 被错误限制为单线程的问题；加入官方包中的 41,259,059 字节 Core ML encoder，并继续保留 Metal 与 iOS 15 安全回退。
- [x] 33. 播放页正文支持直接长按单词、拖动选择词组并打开上下文释义面板；保留右侧菜单作为备用入口。
- [x] 34. 上下文释义明确区分“所选词在这里的意思”和“完整例句翻译”；收藏时分字段保存两者、原句和独立原声。
- [x] 35. 主英文释义切换为 6.3.5 使用的 `fda.josscii.top` 接口并保留上游回退；增加官方同类 GPT Base URL/API Key/模型配置。
- [x] 36. 提取并内置官方 `words.sqlite` 的 COCA 60,023 词频表；释义面板、生词详情、CSV 和 APKG 保存/显示词频排名。
- [x] 37. Anki 导出增加牌组名称输入、稳定 model/deck/note/card ID 和稳定 GUID；重复导入用于保留既有调度进度并新增卡片，生成后校验 notes/cards 数量。
- [x] 38. 移除播放控制区波状图，只保留进度条并压缩控制区高度，给逐句文本留出更多空间。
- [x] 39. 增加“回到当前播放”浮动按钮，点击立即滚到当前句并恢复自动跟随。
- [x] 40. 版本提升为 1.2.0（4）；Plist、XcodeGen YAML、Actions YAML、资源哈希和 `git diff --check` 已完成静态检查。
- [ ] 41. 等待 GitHub Actions/Xcode 15.4 对本轮 23 个 Swift 文件做真实编译；如失败，以完整 `xcodebuild.log` 一次性修复。
- [ ] 42. 真机验证 Core ML 转录速度、完整句时间轴、离开页面继续转录、直接长按、词频与自动转录。
- [ ] 43. 用 AnkiDesktop/AnkiMobile 实际导入 1.2.0 APKG，确认指定牌组可见、第二次只新增卡片且旧卡学习进度不变。

### 本轮官方 6.3.5 新证据

- 包内 `words.sqlite` 只有 `COCA60000(RANK, PoS, word)` 表和 60,023 条词频数据，不是中英释义库。
- `dictionary-block.json` 证明官方词典页支持有道、Longman、Bing、Cambridge、Oxford、Collins、Merriam-Webster 等来源；二进制还直接包含 `https://fda.josscii.top/api/v2/entries/en/`。
- 二进制包含 `gptAPIKey`、`gptBaseURL`、`gptModel`、`enableGPT`、`useContextDefinition` 与 `WordAIExplainView`，说明高质量“语境中的词义”可走用户配置的 GPT 链路，而非普通整句机器翻译。
- 包内同时有 `ggml-base-encoder.mlmodelc`、Silero 256ms VAD 和 streaming 左右上下文参数；官方并非固定 30 秒无重叠硬切。

## 关键文件

- `project.yml`：工程配置和 iOS 15 Deployment Target
- `.github/workflows/build-ios.yml`：GitHub Actions 构建/打包
- `PodcastIOS15/Services/PlayerManager.swift`：播放器
- `PodcastIOS15/Services/MicrosoftTranslator.swift`：微软翻译
- `PodcastIOS15/Services/WhisperTranscriber.swift`：离线自动转写
- `PodcastIOS15/Services/AnkiExporter.swift`：CSV/APKG 导出
- `PodcastIOS15/Views/PlayerView.swift`：6.3.5 风格逐句播放页
- `README.md`：构建和使用说明

## 2026-07-15：1.2.1（5）真机反馈修复

- [x] 44. 将下载完成后的自动 Whisper 触发提升到 `RootView`：根视图监听整集音频进入 ready 状态并启动 `TranscriptionManager`，播放页同时保留显式兜底，不再依赖用户点击“转录”。
- [x] 45. 转录任务继续由 App 根节点持有，并增加 iOS 后台任务保护；退出播放页不会取消任务。App 真正切到系统后台时，播放中的后台音频模式与系统授予的后台执行时间共同决定可连续运行时长。
- [x] 46. Anki 新模型缩减为 `Word / Sentence / SentenceTranslation / ContextMeaning` 四字段；移除系统词典释义、播客/单集来源、时间点、回链、音标、词频和音频，只导出生词、例句、例句释义和页面生成的上下文释义。
- [x] 47. Anki 导出排除“★ 收藏句子”伪生词；四字段模型使用新的稳定 model ID，避免与旧 11 字段模型冲突。
- [x] 48. 首页封面修复旧收藏数据：优先验证已有频道封面，再尝试单集封面，最后按 feed URL/标题从 Apple Podcasts CN/US 搜索结果补齐并保存。
- [x] 49. 修复 RSS `media:content` 图片被误当音频的问题，并支持带 `href/url` 属性的频道 `<image>`。
- [x] 50. 版本提升为 1.2.1（5）；Plist/Assets JSON、资源尺寸、iOS 16+ API 扫描和 `git diff --check` 已通过静态检查。
- [ ] 51. 上传 GitHub 后等待 Xcode 15.4 Actions 完成 23 个 Swift 文件的真实 Release 编译与 IPA 打包。
- [ ] 52. 真机确认：下载完成无需点击即开始转录、退出播放页继续增长进度、旧收藏封面被补齐，以及 APKG 四字段内容正确。

## 2026-07-15：1.3.0（6）6.3.5 高优先级能力补齐

- [x] 53. Whisper 从最后一条完整缓存句子的结束时间继续读取本地音频；App 重启后不再从头转录，并支持从当前播放位置截断后重新转录。
- [x] 54. 音频下载改用带稳定 session identifier 的系统后台 `URLSessionDownloadTask`；支持多任务队列、系统后台传输、App 重启重新挂接、进度恢复、失败重试与从单集列表左滑入队。
- [x] 55. 播放器加入播客单集队列、自动下一集、上一集/下一集、单集循环、队列循环、10–60 分钟睡眠定时和 AB 重复。
- [x] 56. 逐句循环增加 1/2/3/5 次或一直重复；AB 重复与逐句重复互斥，避免两个时间循环互相抢占。
- [x] 57. 文稿加入系统搜索、持久书签/只看书签、整体提前或延后 0.5 秒，以及从当前位置重新转录。
- [x] 58. 首页、详情页、搜索结果和迷你播放器统一使用内存 + 磁盘两级封面缓存，离线或重复打开时无需重新下载封面。
- [x] 59. “回到当前播放”根据当前句相对滚动视口的实际位置显示；当前句可见时自动隐藏，离开屏幕后出现。
- [x] 60. 修复长按选词过早弹窗：选区变化期间只记录，长按/拖动结束并松手后才提交完整词组或句子。
- [x] 61. 版本提升为 1.3.0（6）；继续保持 iOS 15.0 deployment target。
- [x] 62. 单集列表改为全屏打开播放学习页；底部“音频 / 生词 / 更多”Tab 栏只在主界面显示，不再占用文稿高度。
- [x] 63. Anki 在四项文字学习内容之外恢复独立句子原声音频；继续排除播客来源和系统词典释义，并使用新的五字段模型 ID 防止与四字段模型冲突。
- [x] 64. 移除主界面手动 RSS URL 输入入口：该入口只支持播客 Feed、不能订阅 YouTube 视频；Apple Podcasts 搜索仍在底层使用 RSS 加载和刷新单集。
- [x] 65. 添加页并行加载 Apple Podcasts 中国区与美国区热门榜单、合并并按 Feed 去重；两边都失败时回退到“英语学习”搜索结果，页面不再空白。
- [ ] 66. 等待 GitHub Actions Xcode 15.4 完整编译、IPA 打包并在真机验证后台下载恢复、转录续跑和文本选择手势。

## 2026-07-16：1.4.0（7）ElevenLabs 默认转录

- [x] 67. 参考 `scribe2srt` 接入 ElevenLabs Scribe v2：约 40 分钟 M4A 分片、词级时间戳、标点断句、短句合并、指数退避重试和逐批缓存。
- [x] 68. 无 RSS 文稿时默认自动使用 ElevenLabs，无需在 App 中填写 API Key；转录管理器仍由 App 根节点持有，离开播放页或切到生词页不会取消。
- [x] 69. ElevenLabs 失败后保留已完成分片，页面提供“重试 ElevenLabs”和“改用 Whisper”；更多菜单可指定任一引擎从头或从当前播放位置重新转写。
- [x] 70. Whisper 模型、Core ML 编码器和断点转录流程完整保留，作为无网络或 ElevenLabs 失败时的离线兜底。
- [x] 71. 版本提升为 1.4.0（7），XcodeGen 会自动把新增转录器纳入 application target。
- [x] 72. GitHub Actions `29431124310` 已通过 Xcode 15.4 Release 编译、IPA 打包和 Artifact 上传；产物确认为 1.4.0（7）、最低 iOS 15.0，并包含 Whisper framework、离线模型和 Core ML encoder。
- [x] 73. 第一次 1.4.0 Actions 已通过工程生成和依赖解析；修复 `SelectableTranscriptText` 中待提交选区变量被同名 `guard let` 遮蔽导致的 Swift 编译错误后重新构建。
- [ ] 74. 真机验证 ElevenLabs 匿名端点可用性、40 分钟以上节目分片、断点切换引擎、切到生词页继续转录，以及 Anki 五字段与原句音频。

### 1.4.0 构建产物

- 本地 IPA：`D:\codex\aisten\PodcastIOS15-1.4.0-build7\PodcastIOS15-iOS15.ipa`
- Artifact 备份：`D:\codex\aisten\PodcastIOS15-1.4.0-build7-artifact.zip`
- IPA SHA-256：`B1A350191380961F04BB59BFE9C794B7E42B4F220E7DE8D915B17EDEF23ED793`

### 完成后再对照官方 6.3.5

- 官方资源文案明确说明本地转录只能在前台执行；本项目的转录任务由根节点持有，切换播放页/生词页不会中断，已经覆盖本轮真机反馈。App 被系统真正挂起时仍受 iOS 15 后台执行时限约束。
- 当前用户要求的高优先级闭环已具备：自动转录、断点续跑、ElevenLabs/Whisper 切换、文本选择松手提交、播放页扩容、条件显示回到当前播放、上下文释义 Anki、原句音频、热门播客和封面修复。
- 后续值得借鉴但暂不提高优先级：为 Whisper 加 Silero VAD 降低静音耗时；允许手工修正文稿/译文；按播客设置自动下载规则；章节与 show notes 浏览。
- 本轮继续不做低优先级外围能力：OPML、iCloud 同步、欧路词典跳转、CarPlay 和视频播放。

## 2026-07-16：1.4.1（8）后台音频落盘权限修复

- [x] 75. 定位“未能移动 CFNetworkDownload 临时文件，因为没有访问 EpisodeAudio 的权限”：后台任务描述符持久化了旧 App 沙盒的绝对目标路径，更新/重装后恢复任务会写入已失效容器。
- [x] 76. 新任务仅保存目标文件名；下载完成时始终从当前 App 的 Application Support 重新生成 `EpisodeAudio` 路径，并兼容仍携带旧绝对路径的已排队任务。
- [x] 77. `EpisodeAudio` 目录和下载文件使用首次解锁后可访问的文件保护等级，降低锁屏完成后台下载时的落盘失败概率。
- [x] 78. GitHub Actions `29432328208` 已通过 Xcode 15.4 Release 编译、IPA 打包和 Artifact 上传；产物确认为 1.4.1（8）、最低 iOS 15.0。
- [x] 79. 明确整集音频缓存与转录缓存互相独立，转录失败不会删除音频；本地查找增加稳定 episode id 摘要前缀回退，RSS 改变 mp3/m4a/无扩展名写法时仍复用已下载文件。
- [ ] 80. 真机重新下载同一集，确认音频成功落盘、再次进入不重复下载，并且自动 ElevenLabs 转录能够紧接下载启动。

### 1.4.1 构建产物

- 本地 IPA：`D:\codex\aisten\PodcastIOS15-1.4.1-build8\PodcastIOS15-iOS15.ipa`
- Artifact 备份：`D:\codex\aisten\PodcastIOS15-1.4.1-build8-artifact.zip`
- IPA SHA-256：`734F1B16CFC4A79C3DBA761C91810D51857E3B9C0ACE62B1F65A037581A7FADE`

## 2026-07-16：1.5.0（9）恢复 Whisper 与重做音频落盘

- [x] 81. 按真机反馈删除 ElevenLabs 转录器、匿名网络请求、双引擎状态和所有产品界面入口；自动转录、断点续跑、从当前位置重录统一恢复为离线 Whisper。
- [x] 82. 不再使用 `Application Support/EpisodeAudio` 子目录；音频改存为系统 Caches 根目录中的 `PodcastEpisodeAudio-*` 文件，彻底绕开持续出现权限错误的目录。
- [x] 83. 下载完成后不再跨沙盒 `moveItem` CFNetwork 临时文件；改为 512 KB 分块读取并写入当前 Caches 的临时文件，再在同一目录内原子改名。
- [x] 84. 恢复旧后台任务时忽略其中保存的绝对路径，只用 episode id 和扩展名生成当前容器文件名；运行时完全不再读取、写入或清理旧 `EpisodeAudio` 目录。
- [x] 85. 音频与转录继续独立缓存；Whisper 失败不删除整集音频，已成功落盘的同一 episode 再次打开不会重新下载。
- [ ] 86. 立即推送 GitHub Actions 构建 1.5.0（9），下载并校验新版 IPA。

## 2026-07-16：1.6.1（11）彻底移除 CFNetwork 下载临时文件依赖

- [x] 87. 确认权限故障由 `5b7ab46` 引入的后台 `URLSessionDownloadTask` 路径导致；后续仅调整 `CFNetworkDownload.tmp` 的移动和复制目标，没有消除临时文件访问根因。
- [x] 88. 整集音频恢复为 `URLSessionDataTask` 流式写入当前 Caches 的隐藏 `.partial` 文件，完成后只在同一目录原子改名，不再读取、复制或移动 `CFNetworkDownload.tmp`。
- [x] 89. App 启动时接管并取消旧 session identifier 下的遗留后台任务，旧任务即使回调也直接丢弃临时文件，不再尝试写入失效的 `EpisodeAudio` 或旧沙盒路径。
- [x] 90. 保留稳定 episode id 文件名和扩展名回退查找；转录失败只影响转录缓存，完整音频继续保留，退出后再次进入不会重复下载。
- [x] 91. GitHub Actions `29472450548` 已通过 Xcode 15.4 Release 编译、IPA 打包和 Artifact 上传；包内确认为 1.6.1（11）、最低 iOS 15.0，内置 Whisper 模型完整。
- [ ] 92. 真机进行“下载成功、转录失败、退出重进不重复下载”验证，并确认升级后不再出现 `CFNetworkDownload.tmp` 目录权限错误。

### 1.6.1 构建产物

- 本地 IPA：`D:\codex\aisten\PodcastIOS15-1.6.1-build11\PodcastIOS15-iOS15.ipa`
- Artifact 备份：`D:\codex\aisten\PodcastIOS15-1.6.1-build11-artifact.zip`
- IPA SHA-256：`A6843E0586A47F33E99CD9994991BF48D1939564D7587AA62CCEBA19DAAFD945`

## 2026-07-16：1.6.2（12）导航、文稿跟随、拖选与段落断句修复

- [x] 93. 播客列表改用显式 selection，详情目标按 podcast id 隔离；播放器忽略打开新单集时旧播放器 publisher 的首次值，直到请求的 episode 真正加载后才接受上一集/下一集切换。
- [x] 94. 用户手动拖动文稿后立即暂停自动跟随；“回到当前播放”按钮不再依赖已被 LazyVStack 回收的当前句坐标，远离当前位置后仍保持显示，只有点击按钮才恢复跟随。
- [x] 95. 删除文本选择被系统取消时的提前提交路径；播放页和查词页都只在长按拖选手势真正结束、用户松手后提交最终单词或词组。
- [x] 96. Scribe v2 移除 scribe2srt 的 7 秒、两行和 CPS 分段约束；完整句优先，按说话人变化或 1.8 秒长停顿分段，30 秒以上超长句才优先在从句标点或自然停顿处分割，并合并同一说话人的相邻短句。
- [ ] 97. 通过 GitHub Actions Xcode 15.4 编译 1.6.2（12），下载 IPA 并进行真机导航、拖选、手动滚动和重新转录验证。
