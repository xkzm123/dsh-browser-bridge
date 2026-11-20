# Changelog

## 1.6.2

- 设置页独立成页：配置进了设置侧边栏，和内置插件并列的独立页面。
- 目标浏览器三档开关：`existing`（只用你开的窗口）/ `new`（只用本插件启动的实例）/ `auto`（优先新实例，回退你的窗口）。
- 修复 `peerDependencies` 范围：`@deepseek-ai/dsh-tools` 原为 `>=0.1.0-rc.1`，在 node-semver 下不匹配任何 0.2.x 预发布（缺少同元组上的预发布比较符），0.2.2-rc.1 宿主安装会撞 `ERESOLVE`。改为显式 `||` 分支。
- 声明 `engines.dsh`，市场卡片据此显示宿主要求，而不是「未知」。
- 新增 `screenshots.json`：市场详情页截图由本仓库声明，之后换图不必再改清单。
- README 的版本号与工具数徽章与实际一致（1.6.2 / 22 tools）。

## 1.6.1

- 修复客户端卡片首帧无 state 时误报「未开放配置」。
- 客户端 manifest 只声明 `platform`，不再列 `inject` 包。

## 1.6.0

- 新增目标浏览器三档开关（`targetMode`）：`existing` / `new` / `auto`。
