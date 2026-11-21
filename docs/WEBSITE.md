# 官网维护

[English](https://ixiehao.github.io/ezNTFS/) · [简体中文](https://ixiehao.github.io/ezNTFS/zh/) · [日本語](https://ixiehao.github.io/ezNTFS/ja/)

从仓库根目录生成站点并核对静态输出。

```sh
python3 scripts/build-website.py
python3 scripts/build-website.py --check
python3 -m http.server 8000 --bind 127.0.0.1 --directory dist/website
```

`website/content.json` 集中维护版本、系统要求、依赖和三语正文。发布新的安装包后更新版本与对应的真实 App 截图。网页、Markdown、站点地图和结构化数据均从同一份内容生成。截图来自隔离 App 的演示磁盘模式。窗口以及 Tabler 操作图标和原始许可证随站点提供。

验收运行 `npm ci --prefix website --ignore-scripts` 和 `npx --prefix website playwright install chromium webkit`，然后运行 `npm test --prefix website`。检查覆盖三语、320 / 768 / 1440 像素、无 JavaScript 访问、语言链接、FAQ 键盘操作、可见截图和横向溢出。

GitHub Actions 仅将 `dist/website` 发布到 Pages。推送主分支前先核对下载附件和签名说明。成功部署后逐语回读网页，并检查下载、样式、截图、站点地图、Markdown 和 `llms.txt`。域名根路径的爬虫规则由该域名的主页仓库管理。

IndexNow 仅提交确实更新的项目标准网址。先确认公开的项目子路径验证文件与 `website/indexnow-key.txt` 一致，再通过 `keyLocation` 指定该文件。HTTP 200 和 202 分别表示通知已接收和已接收待验证。 [IndexNow 文档](https://www.indexnow.org/documentation)
