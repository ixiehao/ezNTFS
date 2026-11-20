# 发布准备

## 首次公开源码

1. 预定仓库为 `ixiehao/ezNTFS`，与 App 的更新入口一致。正式公开前检查 Git 暂存清单，保留项目源码、三语 README、构建脚本、测试、公开文档及许可证。构建缓存、安装包、临时镜像、原始日志、本机维护记录和签名凭据留在仓库之外。
2. 在 GitHub 默认分支确认 macOS CI 通过。按仓库安全策略启用 GitHub 私密漏洞报告，并验证 [SECURITY.md](../SECURITY.md) 中的入口。版本标签采用 `v<主版本>.<次版本>.<修订版本>`。
3. 在 Release 正文列明 macOS 版本、架构、macFUSE 版本、安装与磁盘权限步骤、已验证范围和签名状态。预览包标记为 Prerelease。应用「检查更新」只读取 GitHub 的公开稳定版，发布草稿和预览包不会成为更新候选。

## 正式安装包

1. 用拟发布的 Git 提交构建，并记录提交、标签、架构和 SHA-256。通过 `EZNTFS_APP_SIGN_IDENTITY` 与 `EZNTFS_INSTALLER_SIGN_IDENTITY` 指定 Developer ID Application 和 Developer ID Installer。签名凭据保存在 Keychain 或 CI Secrets。正式构建重新编译并签名 NTFS-3G，使用签名后的字节计算驱动校验值。NTFS-3G 需要载入 macFUSE 官方安装的动态库，因此仅该可执行文件获得相应的 Hardened Runtime 例外。 [Apple 文档](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation)
2. 校验主应用、辅助程序和后台服务的签名。PKG 需经 Apple 公证并附加票据。在默认安全设置的干净环境验证安装、升级、驱动修复、后台挂载、安全弹出和移除。为每个对外标注支持的架构记录实际覆盖情况。
3. 核对两种 PKG 都包含对应的 NTFS-3G 完整源码归档、构建脚本、`COPYING` 和 `COPYING.LIB`，并且不包含 macFUSE 动态库。稳定版 Release 附上 SHA-256 和对应源码归档，供下载者直接取得。[第三方组件](THIRD_PARTY.md)
4. 从公开地址无认证下载每个附件，核对 SHA-256、签名及公证票据。用较旧的 App 点「检查更新」，确认能发现稳定版并打开同一发布页。

本机 ad-hoc 试用 PKG 用于安装流程和界面测试。它尚未使用 Developer ID 签名或公证。
