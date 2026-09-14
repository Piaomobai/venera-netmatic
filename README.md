# Venera Netmatic

> **非官方修改版 / Unofficial modified derivative of Venera**

[![License: GPL v3](https://img.shields.io/badge/License-GPL%20v3-blue.svg)](LICENSE)
[![Flutter](https://img.shields.io/badge/Flutter-multiplatform-02569B?logo=flutter)](https://flutter.dev/)

Venera Netmatic 是基于开源漫画阅读器 [Venera](https://github.com/venera-app/venera) 的修改版本，支持阅读本地漫画和通过 JavaScript 漫画源访问网络内容。

本项目不是 Venera 官方版本，与原项目维护者不存在隶属、认可或支持关系。遇到本修改版的问题，请在本仓库反馈，不要向原项目维护者寻求支持。

## 项目来源与修改声明

- 上游项目：[venera-app/venera](https://github.com/venera-app/venera)
- 上游状态：原仓库已于 2026 年 4 月 5 日归档，并在 README 中明确欢迎继续 fork。
- 本修改版维护者：[Piaomobai](https://github.com/Piaomobai)
- 修改时间：2026 年至今；具体修改以本仓库的 Git 历史为准。
- 仓库关系：本仓库最初从已经修改过的工作目录建立，因此当前 Git 历史不保留上游的完整提交历史。这里的“修改版”表示代码来源关系，不冒充上游官方发行版。

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

## 漫画源与文档

- [漫画源开发文档](doc/comic_source.md)
- [定时任务文档](doc/scheduled_tasks.md)
- [Headless 模式文档](doc/headless_doc.md)
- [导入漫画文档](doc/import_comic.md)

## 许可证与版权

上游 Venera 及本修改版本均依据 **GNU General Public License v3.0（GPL-3.0）** 分发，完整条款见 [LICENSE](LICENSE)。本仓库保留原项目的许可证及已有版权声明。

- 原始代码的版权归 Venera 原作者及其贡献者所有；
- 后续修改的版权归相应修改者和贡献者所有；
- 本修改版整体继续在 GPL-3.0 条款下提供，不附带任何明示或默示担保；
- 如果向他人分发 APK、安装包或其他二进制版本，必须同时以 GPL-3.0 允许的方式提供对应源代码，并保留许可证、版权与修改声明；
- 再分发或继续修改本项目时，派生作品仍须遵守 GPL-3.0 的相关要求。

本节是对项目来源和许可证义务的说明，不构成法律意见；发生疑问时应以 [GPL-3.0 正文](LICENSE)为准。

## 致谢

- [Venera](https://github.com/venera-app/venera) 的原作者与所有贡献者；
- [EhTagTranslation](https://github.com/EhTagTranslation/Database)，本项目使用了其漫画标签中文翻译数据；
- 所有为本修改版提供代码、测试与反馈的贡献者。
