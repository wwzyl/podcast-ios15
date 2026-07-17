# Podcast iOS15

面向 iOS 15 重新实现的播客语言学习 App。视觉和主要工作流参考 Aisten 6.3.5，但不包含原 App 的不兼容可执行代码。

## 已实现

- Apple Podcasts 搜索、底层 RSS 刷新和节目列表
- 网络音频、后台/锁屏播放、进度记忆、倍速、15 秒跳转和逐句循环
- Podcasting 2.0 transcript、SRT、WebVTT、TTML 和常见 JSON 文稿
- 无文稿节目由用户选择 Scribe v2、Whisper 极速/均衡、英语专用 Whisper 或 Apple 系统语音识别，不再自动开始转录
- Whisper 极速内置 `ggml-base-q5_1`；其他档位首次选择时由 App 自动下载 GGML 和配套 Core ML encoder 并缓存，官方 Hugging Face 不可达时自动切换镜像，支持 Metal 和 Silero VAD 动态语音分段
- DeepL、GPT 和 Microsoft 翻译路由，可关闭故障自动回退
- 前一句 + 当前句 + 后一句的上下文翻译、全文翻译
- GPT 驱动的句子 AI 分析和词组 AI 解释
- 在线英文释义、欧路词典、iOS 系统词典、生词库和句子收藏
- CSV 和 Anki `.apkg` 导出
- 最低部署版本 iOS 15.0

## GitHub Actions 构建

1. 把此文件夹的全部内容上传到一个 GitHub 仓库，保持 `.github/workflows/build-ios.yml` 路径不变。
2. 打开仓库的 **Actions → Build iOS 15 IPA → Run workflow**。
3. 构建完成后，从 `PodcastIOS15-iOS15` Artifact 下载 IPA。

工作流产出的是 ad-hoc IPA，适合 TrollStore，或者交给你使用的签名工具重新签名。普通未越狱设备不能直接安装 ad-hoc 包，需要开发者证书/描述文件或侧载工具签名。

## 在 Mac 上开发

```sh
brew install xcodegen
xcodegen generate
open PodcastIOS15.xcodeproj
```

工程通过 `project.yml` 生成，依赖 ZIPFoundation 来生成 APKG。第一次构建需要网络下载 Swift Package。

## 文稿说明

如果 RSS 单集包含 `podcast:transcript`，App 会自动载入；没有文稿时只显示转录引擎选择，不会自动开始。完成句子和断点会持续缓存，失败后可以从最后断点继续。转录任务由 App 根节点持有，离开播放页或切换到生词页不会取消。也可以在“更多”页导入 SRT、VTT、TTML、XML 或 JSON。极速模型约 60 MB，已作为 App 资源内置；均衡和英语专用模型首次选择时自动下载到 App 私有缓存。

Anki APKG 的生词卡导出生词、生词所在句子、句子原声、句子释义，以及该词在当前上下文中的释义；不会导出系统词典释义或播客来源。

1.6.1 不再使用会产生 `CFNetworkDownload.tmp` 的后台 `URLSessionDownloadTask` 保存整集音频。网络数据直接写入当前 App 的系统 Caches 暂存文件，完成后在同一目录原子改名；升级时会取消旧后台 session 中残留的任务。音频缓存和转录缓存互相独立，转录失败不会删除已下载音频，再次进入同一单集会直接复用本地文件。

1.6.2 修复 iOS 15 在播客详情和播放器之间复用旧页面状态的问题；手动滚动文稿后暂停自动跟随，只有点击“回到当前播放”才恢复；长按拖选仅在松手后提交最终词组。Scribe v2 改用面向学习文稿的完整句/段落断句，不再套用 SRT 的 7 秒和两行限制。

1.6.3 在拖选松手时用系统语言分词器补齐首尾完整单词；查词页原句按全部内容自动增高；GPT 上下文释义开启后不再静默降级到微软翻译，失败会自动重试一次并显示明确错误和实际释义来源。

微软 Edge Translator 的公开令牌端点并非微软承诺长期稳定的正式 SDK。如果服务端策略变化，翻译会提示网络错误，不会导致 App 闪退。
