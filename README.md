# Podcast iOS15

面向 iOS 15 重新实现的播客语言学习 App。视觉和主要工作流参考 Aisten 6.3.5，但不包含原 App 的不兼容可执行代码。

## 已实现

- Apple Podcasts 搜索、RSS URL 订阅、订阅刷新和节目列表
- 网络音频、后台/锁屏播放、进度记忆、倍速、15 秒跳转和逐句循环
- Podcasting 2.0 transcript、SRT、WebVTT 和常见 JSON 文稿
- 无文稿节目可使用 whisper.cpp + `ggml-base-q5_1` 在设备上离线、分批生成逐句稿（模型已内置）
- Microsoft Edge Translator 无密钥翻译流程（与 `scribe2srt` 相同）
- 前一句 + 当前句 + 后一句的上下文翻译、全文翻译
- 在线英文释义、iOS 系统词典、生词库和句子收藏
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

如果 RSS 单集包含 `podcast:transcript`，App 会自动载入；没有文稿时，整集音频下载完成后会自动开始 Whisper 转录，不需要再点“自动生成逐句稿”。转录任务由 App 根节点持有，退出播放页后仍继续运行，完成的句子会持续缓存。也可以在“更多”页导入对应的 SRT/VTT/JSON。Whisper 模型约 60 MB，已作为 App 资源内置，不再运行时联网下载。

Anki APKG 的生词卡导出生词、生词所在句子、句子原声、句子释义，以及该词在当前上下文中的释义；不会导出系统词典释义或播客来源。

1.3.0 增加转录断点续跑、系统后台下载队列、自动下一集、睡眠定时、AB/逐句重复、文稿搜索与书签、字幕时间轴偏移、从当前位置重新转录以及封面磁盘缓存。播放页长按/拖动选词会等到松手后再打开查询面板；“回到当前播放”只在当前句离开可视区域时显示。

微软 Edge Translator 的公开令牌端点并非微软承诺长期稳定的正式 SDK。如果服务端策略变化，翻译会提示网络错误，不会导致 App 闪退。
