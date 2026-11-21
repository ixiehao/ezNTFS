# 开发与构建

## 环境

CI 使用 Xcode 26.3 的 Swift 工具链，SwiftPM 最低运行版本为 macOS 14。本次安装包基于 NTFS-3G 2026.9.28 和 macFUSE 5.5.0。构建需预装官方 macFUSE，安装时会校验本机 macFUSE 签名、版本和动态库摘要。

## 构建

从 [NTFS-3G 发行页](https://github.com/tuxera/ntfs-3g/releases/tag/2026.9.28) 获取源码归档。从项目根目录运行以下命令，构建脚本会按上游公布的 SHA-256 校验归档。

```zsh
swift test
python3 scripts/check-localizations.py
scripts/package-installer.sh /path/to/ntfs-3g_ntfsprogs-2026.9.28.tgz
```

PKG 安装主 App、按需启动的系统服务和版本化驱动。安装器会从本机官方 macFUSE 安装中校验并复制必要的动态库到系统目录。输出写入 `dist/ezNTFS-<版本>-<架构>/`，脚本拒绝覆盖已存在的正式产物。仅构建应用用于调试时可用 `scripts/build-app.sh`。原有拖放式 DMG 脚本用于界面预览，完整部署从 PKG 入口安装。

PKG 默认按当前架构构建。可以为 App、系统服务、安装辅助程序和 NTFS-3G 指定同一个目标架构。下例构建 Intel 原生包，要求构建机已安装官方 macFUSE 5.5.0，并能运行 Intel 命令行程序。在 Apple 芯片 Mac 上，这项构建验证使用 Rosetta。Intel Mac 使用 Xcode 26.3 等同时支持 Swift 6 和 Intel 的工具链。

```zsh
EZNTFS_ARCHITECTURE=x86_64 scripts/package-installer.sh /path/to/ntfs-3g_ntfsprogs-2026.9.28.tgz
```

两个架构使用独立的默认构建缓存。安装器在写入系统目录前检查架构，Intel 包仅安装到 Intel Mac，最低版本为 macOS 14。交叉编译和 Rosetta 测试之外，Intel 版正式发布前还需在 Intel 实机验证挂载服务、NTFS 读写和安全弹出。

## 本地化

0.5.1 起，安装与驱动修复包在打开时检查 macFUSE。需要的版本来自随包驱动清单。已有兼容版本时可以继续。缺装时显示对应的官方发布地址，版本不符和安装不完整各有提示。真正写入系统目录前，安装器还会复核签名和动态库摘要。运行 `node --test scripts/check-installer.mjs` 检查三语提示和各分支。

App 文案位于 `Sources/EzNTFSApp/Resources/*.lproj`，安装器文案位于 `scripts/installer/Resources/*.lproj`。语言使用稳定键，运行状态在显示时根据当前 App 语言渲染。macOS 安装器按自己的系统语言选择资源。驱动和系统返回的原始信息留在「技术详情」。提交文案改动前运行本地化检查，并在最窄窗口核对各语言的按钮、标题和错误提示。

## 实现

- 磁盘状态使用 Disk Arbitration、IOKit 和系统挂载事件驱动。状态读取来自 I/O Registry、Disk Arbitration 缓存描述和内核缓存挂载表。刷新与身份检查均不调用 `diskutil list` 或 `diskutil info`。每次读写挂载、复制或弹出前以当前设备身份复核。
- 安全弹出成功后保存本次开机的 USB 设备标识。驱动卷节点在同一连接下重新出现时继续保留弹出状态。按物理设备保存多条弹出记录。拔下时解除对应设备的暂停，其他外置卷继续接收磁盘事件。
- 识别依据 macOS 缓存确认的 NTFS 格式及外置物理设备属性，覆盖 MBR、GPT 和系统可识别的整盘 NTFS。GPT 类型标识本身不足以确认文件系统。保存的指纹命中多个卷时暂停该指纹的自动挂载。缺少稳定标识的硬盘只支持手动操作。Nigate 正在运行时先提示用户；授权失败可手动重试。正常卸载失败、硬盘重连、驱动拒绝读写或设备身份不符会终止本次操作。
- 管理员通过系统安装器安装按需启动的 launchd 服务。XPC 核对 App 和服务的代码签名身份，服务重新确认外置 NTFS 分区及当前登录用户，从受保护的绝对路径运行已校验的驱动。挂载使用 `norecover` 并保留 Windows 兼容文件名约束。macFUSE 的 `iosize=1048576` 与复制块大小一致，最终交付仍经过逐文件同步和整批 SHA‑256 回读。
- 复制在待交付位置独占创建批次暂存目录。所有写入和元数据操作结束后再逐个读回校验，只有整批通过才交付。遇到存在同名冲突的独立 AppleDouble 伴随文件时会拒绝该批，避免无声丢失。普通失败会尝试清理本次暂存。意外拔盘后如留下 `.ezntfs-….partial`，可在重新连接并确认无复制任务时处理该批次。

## 临时镜像回归

设置 `EZNTFS_TEST_IMAGE` 为本机合成 NTFS 镜像的绝对路径再运行 `swift test`，可执行真实 macFUSE 回归。测试写入私有克隆。App 包内的 `ezntfs-tool verify-image <路径>` 也使用私有克隆，验证重挂后文件内容。

可使用已安装的 NTFS-3G `mkntfs` 生成测试镜像。以下命令只适用于新建的临时普通文件，运行前应确认 `mkntfs` 可用。

```zsh
fixture_dir=$(mktemp -d)
truncate -s 768m "$fixture_dir/fixture.img"
mkntfs -F -Q -s 512 -L EZNTFS-QA "$fixture_dir/fixture.img"
EZNTFS_TEST_IMAGE="$fixture_dir/fixture.img" swift test
```

未设置 `EZNTFS_TEST_IMAGE` 时镜像集成测试会跳过。安装前验证本地构建的驱动时，可指定 `EZNTFS_TEST_DRIVER`，或者给 `verify-image` 传入 `--driver <路径>`。测试完成后可删除自己创建的临时目录。

## 图标

复制、访达、弹出和设置等操作图标使用 Tabler Icons Outline 3.46.0。原始 SVG 放在 `Resources/Tabler.xcassets`，完整 MIT 许可证随包分发。原创 NTFS Dock 图标和单色硬盘标志分别放在 `Resources/Brand` 与 `Resources/Brand.xcassets`。菜单栏另用 19 × 15 pt 的单色模板标记，实际轮廓约 17 pt 宽。构建从品牌 SVG 导出 App 图标的各个尺寸。[Tabler Icons 3.46.0](https://github.com/tabler/tabler-icons/releases/tag/v3.46.0)
