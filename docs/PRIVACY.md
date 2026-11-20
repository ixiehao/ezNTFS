# 隐私与权限

ezNTFS 在本机读取磁盘状态，并使用用户选择的文件执行复制与校验。自动挂载设置会在本机保存设备标识、分区范围和偏好设置，用于重新识别硬盘。系统日志可能记录分区编号及错误详情，分享日志前请检查其中的个人信息。

安装系统服务时需要 macOS 管理员授权。服务仅接受签名匹配的本机 ezNTFS 客户端请求，并再次确认磁盘和当前登录用户。macOS 可能另外要求为应用或挂载服务启用完全磁盘访问权限。关闭窗口后，应用可继续通过菜单栏运行。

环境检查仅在本机验证安装和依赖；驱动修复通过随包提供的 macOS 安装器执行。应用提供 macFUSE 官方网站入口。

只有你选择「检查更新」时，应用才会访问 `api.github.com` 的公开 Releases 接口。请求没有登录凭证，也不包含文件、磁盘信息、已安装版本或本机设置。版本比较在本机完成。选择「查看发布页」会在默认浏览器打开 GitHub。GitHub 可看到网络请求通常带有的连接信息。应用没有自动更新检查或遥测。

## English summary

Disk settings, files, and integrity checks stay on your Mac. The mount service is a local system process. Update checks run only on request and read the public GitHub Releases API without credentials, files, disk identifiers, preferences, or your installed version. Version comparison runs locally. Choosing **View Release** opens GitHub in your browser.
