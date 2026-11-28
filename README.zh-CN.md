# ezNTFS

[English](README.md) · 简体中文 · [日本語](README.ja.md)

**ezNTFS 是一款原生的 macOS 外置 NTFS 硬盘读写工具，免费开源。** 把 Windows 用过的 NTFS 移动硬盘或 U 盘接到 Mac，点「挂载读写」，就能在访达里拷文件。硬盘格式和已有文件都照旧。

常用的盘可以单独开启自动挂载。拷重要素材时，可用「复制并校验」逐个读回副本，核对 SHA-256。底层读写由 NTFS-3G 和 macFUSE 提供。

## 下载 0.5.4 正式版

| Mac | 最低系统 | 安装包 |
| --- | --- | --- |
| Apple 芯片 | macOS 14 | [下载 Apple 芯片版](https://github.com/ixiehao/ezNTFS/releases/download/v0.5.4/ezNTFS-0.5.4-arm64-Setup.zip) |
| Intel Mac | macOS 12.7 Monterey | [下载 Intel 正式版](https://github.com/ixiehao/ezNTFS/releases/download/v0.5.4/ezNTFS-0.5.4-x86_64-Monterey-Setup.zip) |

[发布说明与校验和](https://github.com/ixiehao/ezNTFS/releases/tag/v0.5.4) · [ezNTFS 中文官网](https://ixiehao.github.io/ezNTFS/zh/)

<img src="website/assets/ezntfs-zh-Hans.png" width="660" alt="ezNTFS 的三块演示硬盘及挂载状态">

## 安装

[Intel Mac 图文安装教程](docs/INSTALL-INTEL.zh-CN.md)

解压下载的安装包后打开 `Install ezNTFS.app`，按提示安装或升级。已装兼容的 macFUSE 时会跳过，缺少时会下载并验证官方安装包。管理员授权、扩展许可和重启按 macOS 提示操作。

如果下载的是独立 PKG：

1. 关闭外置硬盘上的文件，安全弹出硬盘后再安装或升级。
2. macFUSE 5.5.0 只需安装一次。已经装好就可以直接打开 ezNTFS 安装包。[下载 macFUSE 5.5.0](https://github.com/macfuse/macfuse/releases/tag/macfuse-5.5.0)
3. 打开 ezNTFS 的 PKG，按 macOS 提示授权安装。

应用和随附的可执行文件使用 ad-hoc 签名。PKG 未签名、未公证。

修复依赖时，可从「环境检查 → 安装或修复依赖」进入。硬盘正在使用时，先安全弹出再重试。

## 使用

- **挂载读写**后，就可以在访达里往盘上拷贝文件。如果硬盘由其他 NTFS 驱动接管，先正常卸载。
- 在设置里开启「插盘后自动挂载」，再打开这块盘的「自动挂载」。缺少稳定标识的硬盘可手动挂载。
- **复制并校验**会读回副本，逐个核对 SHA-256。整批通过后，文件会放进一个新文件夹。支持普通文件和目录，包括空文件和空目录。日期和扩展属性取决于驱动支持。完整的 macOS 权限、硬链接关系和特殊文件超出此功能的范围。
- 关闭盘上的文件，再点**安全弹出**。这会弹出整块硬盘及其所有卷。如果硬盘仍被占用，关掉相关窗口或应用后重试。

关闭窗口后，ezNTFS 仍在菜单栏运行。点「打开 ezNTFS」就能回到主窗口。

## 帮助

- 如果 macOS 拒绝访问硬盘，打开「帮助 → 检查依赖」，在权限提示中点「打开权限设置」。如果列表里没有 Service.app，点「在访达中显示」定位后添加。开启后点「重试挂载」。[隐私与权限](docs/PRIVACY.md)
- 在「帮助 → 检查更新」查看最新正式版，在「语言」菜单切换界面语言。[反馈问题](https://github.com/ixiehao/ezNTFS/issues)

## 开发

[文档](docs/README.md) · [构建](docs/DEVELOPMENT.md) · [测试](docs/QA.md) · [发布](docs/RELEASING.md) · [参与开发](CONTRIBUTING.md) · [安全](SECURITY.md)

[MIT 许可证](LICENSE) · [第三方组件](docs/THIRD_PARTY.md)
