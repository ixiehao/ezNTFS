# 第三方组件

- [Tabler Icons Outline 3.46.0](https://github.com/tabler/tabler-icons/tree/v3.46.0) 的 SVG 用于操作图标。完整 MIT 许可与版权声明见 [许可证](../Resources/Tabler/LICENSE)，构建时随 App 分发。
- [NTFS-3G 2026.9.28](https://github.com/tuxera/ntfs-3g/releases/tag/2026.9.28) 随 PKG 安装。版本目录的 `source/` 提供对应的上游源代码归档、构建脚本、GPL v2 文本 `COPYING` 和 GNU Library GPL v2 文本 `COPYING.LIB`。各文件适用条款以上游源码声明为准。ezNTFS 通过独立进程调用驱动。
- [macFUSE](https://macfuse.github.io/) 由官方安装器独立安装。ezNTFS 安装时从本机已安装的 macFUSE 复制经校验的 FUSE 动态库；ezNTFS 的 PKG 不含 macFUSE 二进制。
- DMG 构建工具及锁定版本见 [dmg-requirements.txt](../scripts/dmg-requirements.txt)，仅用于构建。
