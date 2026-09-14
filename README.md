# Venera Netmatic

> **非官方修改版 / Unofficial modified derivative of Venera**

[![License: GPL v3](https://img.shields.io/badge/License-GPL%20v3-blue.svg)](LICENSE)
[![Flutter](https://img.shields.io/badge/Flutter-multiplatform-02569B?logo=flutter)](https://flutter.dev/)

Venera Netmatic 是基于开源漫画阅读器 [Venera](https://github.com/venera-app/venera) 的修改版本，支持阅读本地漫画和通过 JavaScript 漫画源访问网络内容。

本项目不是 Venera 官方版本，与原项目维护者不存在隶属、认可或支持关系。遇到本修改版的问题，请在本仓库反馈，不要向原项目维护者寻求支持。

本修改版目前保留了上游仓库随源码提供的应用图标。该图标随本项目继续在 GPL-3.0 条款下分发；本项目不主张对 “Venera” 名称或原图标拥有任何商标权，也不以它们暗示官方身份。

## 项目来源与修改声明

- 上游项目：[venera-app/venera](https://github.com/venera-app/venera)
- 上游状态：原仓库已于 2026 年 4 月 5 日归档，并在 README 中明确欢迎继续 fork。
- 本修改版维护者：[Piaomobai](https://github.com/Piaomobai)
- 修改时间：2026 年至今；具体修改以本仓库的 Git 历史为准。
- 仓库关系：本仓库最初从已经修改过的工作目录建立，因此当前 Git 历史不保留上游的完整提交历史。这里的“修改版”表示代码来源关系，不冒充上游官方发行版。

## 创建初衷

原版 Venera 已经提供了优秀的本地漫画阅读体验，但没有覆盖我实际需要的更多本地网络存储连接方式。在 Android、iOS、macOS、Windows 等多个平台分别下载相同内容，不仅需要重复操作，也会占用大量重复的存储空间。

因此，本项目加入了 NAS 连接、远程媒体库、上传与同步能力，并进一步增加定时任务，让漫画的下载、扫描、上传和整理能够按计划执行。目标是尽量只维护一份集中存放的漫画资源，让不同系统上的设备通过 NAS 共享和使用，减少重复下载与空间浪费。

相较上游版本，本仓库目前包含的主要修改包括：

- NAS 连接、远程媒体库及同步能力；
- 定时任务系统及任务执行历史；
- 排行监控、增量下载和下载计划功能；
- Android、iOS、macOS、Windows 和 Linux 的兼容性调整；
- 针对实际使用场景的界面、稳定性及启动时序修复。

## 功能

- 阅读本地漫画；
- 使用 JavaScript 创建和加载漫画源；
- 阅读网络漫画并管理收藏；
- 下载漫画；
- 在漫画源支持时查看评论、标签等信息；
- 在漫画源支持时登录、评论和评分；
- 连接 NAS、管理远程媒体库并执行同步任务；
- 创建定时扫描、排行监控和增量下载任务。

## 从源码构建

构建前需要安装 [Flutter](https://docs.flutter.dev/get-started/install) 和 [Rust](https://rustup.rs/)，并准备目标平台所需的工具链。

```bash
flutter pub get
flutter build apk
```

其他平台可使用对应的 Flutter 构建命令，例如 `flutter build macos`、`flutter build ios` 或 `flutter build windows`。

### 应用标识与升级说明

- Android、iOS、macOS 与 Linux 应用标识为 `com.piaomobai.veneranetmatic`；Dart/Linux 包名为 `venera_netmatic`，面向用户的名称仍为 **Venera Netmatic**。
- Android Debug 使用独立的 `com.piaomobai.veneranetmatic.debug`，可与使用发布密钥签名的 Release 版本同时安装。
- 本项目与上游 Venera 使用不同的应用标识和 Windows 安装器 GUID，因此可以并存，也不会删除或覆盖上游安装。

## 漫画源与文档

本仓库中的漫画源开发、漫画导入、Headless 模式等既有文档，主要继承自原项目 Venera 及相关社区衍生版本，并在本项目的功能演进中继续补充和修改。原始思想、接口设计与早期文档工作的功劳属于相应的原作者和贡献者；具体变更可参考本仓库文件内容与 Git 历史。

这些文档可能尚未完全覆盖本修改版的行为。如果在使用漫画源、开发接口或其他功能时发现文档错误、兼容性问题，或希望补充说明，可以直接在本项目的 [Issues](https://github.com/Piaomobai/venera-netmatic/issues) 中提出，无需向已经归档的上游项目反馈。

- [漫画源开发文档](doc/comic_source.md)
- [定时任务文档](doc/scheduled_tasks.md)
- [Headless 模式文档](doc/headless_doc.md)
- [导入漫画文档](doc/import_comic.md)

## AI 辅助开发声明

本项目在功能开发、代码修改、问题排查和文档整理过程中使用了 AI 辅助的 **vibe coding** 工作方式。AI 是开发工具之一，不改变本项目的开源许可证、来源说明及维护者对所提交修改承担的责任。维护者会尽力进行测试和审查，但无法保证所有实现均不存在错误或风险。

**如果你介意由 AI 辅助开发的软件，请勿使用本项目或其构建产物。**

## 许可证与版权

上游 Venera 及本修改版本均依据 **GNU General Public License v3.0（GPL-3.0）** 分发，完整条款见 [LICENSE](LICENSE)。

- 原始代码的版权归 Venera 原作者及其贡献者所有；
- 后续修改的版权归相应修改者和贡献者所有；
- 本修改版整体继续在 GPL-3.0 条款下提供，不附带任何明示或默示担保；
- 如果向他人分发 APK、安装包或其他二进制版本，必须同时以 GPL-3.0 允许的方式提供对应源代码，并保留许可证、版权与修改声明；
- 再分发或继续修改本项目时，派生作品仍须遵守 GPL-3.0 的相关要求。

本节是对项目来源和许可证义务的说明，不构成法律意见；发生疑问时应以 [GPL-3.0 正文](LICENSE)为准。

## 致谢

我个人长期且频繁地使用 Venera，也非常欣赏原作在跨平台漫画阅读、漫画源扩展能力和简洁体验上的设计。原项目被归档令人惋惜；Venera Netmatic 的维护初衷，正是希望在个人仍有实际使用需求的情况下，让这份优秀的开源作品能够继续运行、适配新的环境，并逐步补充我所需要的功能。

本项目能够继续存在，首先应归功于 Venera 原作者和历届贡献者所完成的大量基础工作。本修改版不会将上游成果据为己有，也无意取代或冒充原项目。

- [Venera](https://github.com/venera-app/venera) 的原作者与所有贡献者；
- 在 Venera 归档前后继续研究、维护、记录或分享相关实现与文档的社区衍生项目及其贡献者；
- [EhTagTranslation](https://github.com/EhTagTranslation/Database)，本项目使用了其漫画标签中文翻译数据；
- 所有为本修改版提供代码、测试与反馈的贡献者。
