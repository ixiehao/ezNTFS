# Contributing

For an issue, include the ezNTFS version, macOS version, processor architecture, and steps to reproduce. Redact device IDs, file contents, and personal paths. Use the [private security channel](SECURITY.md) for vulnerabilities.

Run `swift test` and `python3 scripts/check-localizations.py` from the repository root. For changes to mounting, ejection, or copying, describe failure behavior, cancellation, and device changes. Test with a disposable image and synthetic files. See the [developer guide](docs/DEVELOPMENT.md) for the fixture and packaging commands.

## 参与开发

欢迎通过 Issue 讨论问题和变更。提交前请说明 macOS 版本、处理器架构、ezNTFS 版本和复现步骤。分享日志前请移除个人路径、设备序列号与文件内容。

在项目根目录运行 `swift test`。临时 NTFS 镜像集成测试需要 macFUSE、NTFS-3G 和合成镜像，设置 `EZNTFS_TEST_IMAGE` 后执行测试。构建与测试方法见 [开发与构建](docs/DEVELOPMENT.md)。涉及挂载、弹出或复制的改动，请说明失败、取消和设备变化时的行为，并使用合成数据验证。
