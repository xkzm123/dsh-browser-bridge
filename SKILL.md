---
name: dsh-browser-bridge
description: 操控用户已经打开、正在运行的 Edge/Chrome/Firefox（不重启、不开调试端口）。三条通道：UI Automation 无障碍树（读页面全文、枚举元素与坐标、按名字点击/填值）、SendInput 键鼠模拟（坐标点击、拖拽、滚轮、快捷键、Unicode 直输中文）、篡改猴 userscript 桥（在页面里跑任意 JS，拿真 DOM、Cookie、fetch）。当用户说"操作/控制我打开的浏览器""帮我点一下网页""在我浏览器里填个表""抓这个页面的数据""自动化 Edge/Chrome""不重启直接操控浏览器""browser automation without CDP"时使用。
---

# dsh-browser-bridge

让任意一个 DeepSeek Harness 会话，直接接管用户**当前已经打开**的浏览器窗口。
不重启浏览器，不要求开 `--remote-debugging-port`，不装 Playwright，没有 npm 依赖。

## 选择通道（先想清楚再动手）

| 通道 | 命令 | 用在什么场景 |
|---|---|---|
| UIA 无障碍树 | `uia` `find` `text` `clickel` `invoke` `setvalue` `value` `tabs` `url` `title` | 首选。元素级、抗分辨率、能按名字点，不靠猜坐标 |
| 键鼠模拟 | `click` `move` `drag` `scroll` `type` `key` | UIA 够不着的地方：canvas、闭包 shadow DOM、拖拽、文件上传框、快捷键 |
| JS 桥 | `js` | 要真 DOM/真数据：批量抓取、改样式、拦截请求、读 localStorage、调页面 API |

优先级：**能 UIA 就不点坐标；要数据就走 JS 桥**。

## 标准作业流程

1. `bctl.ps1 doctor` —— 确认 UIA 可用、拿到浏览器 pid、看虚拟屏幕尺寸
2. `bctl.ps1 title <pid>` / `url <pid>` —— 确认目标标签页是不是对的那一个
3. `bctl.ps1 uia <pid> --pattern "<关键词>"` —— 定位目标元素，拿 `cx,cy`
4. `bctl.ps1 shot --file out.png` → 用图像能力看一眼，确认坐标落在正确位置
5. 执行：`clickel`（按名字）或 `click cx cy`（按坐标）或 `js`（按数据）
6. **再截一张图验证结果**，不要假设成功

## 铁律（每条都是踩过的坑）

1. **点击前先截图。** 屏幕坐标是物理像素，虚拟屏幕可能是负原点（多显示器左侧屏）。不要凭空算坐标。
2. **不要在用户正在输入的输入框里注入文字。** 先用 `uia --type Edit` 看有没有占位符/草稿；`type` 会插在光标处而不是覆盖。真要写先 `key CTRL+A` 再写。
3. **每次操作都要能撤回。** 改人草稿、切标签页、关页面之前，先把原状态记下来（`text`、`url`、`tabs`）。
4. **`type` 是 Unicode 直送，绕开输入法**——中文能打进去，但会打断用户正在进行的拼音组合。
5. **切前台是必要的。** `click` 打在后台窗口上等于点在别的东西上；`focus` 失败就用 `clickel`（内部会先 focus）。
6. **JS 桥只对可见标签页生效**（userscript 里用 `visibilityState` 抢活），要指定页面就先 `tab <pid> <n>`。
7. **凭据不进日志。** `js` 可能读到 Cookie/Token，落盘前先脱敏。

## 通道三：JS 桥的安装与自检

```powershell
# 1. 起本地服务（127.0.0.1:8737，纯 TCP，不需要管理员）
bctl.ps1 bridge start

# 2. 让浏览器装 userscript：打开安装页，点「安装」
bctl.ps1 nav <pid> http://127.0.0.1:8737/install.user.js
bctl.ps1 clickel <pid> "安装" --type Button

# 3. 自检
bctl.ps1 js "document.title + ' | ' + location.href"
```

`js` 里的执行环境自带 `__q(sel)` `__qa(sel)` `__text()` `__click(sel)` `__sleep(ms)`，
支持顶层 `await`；裸表达式会自动取返回值。

## 命令

完整手册见 `references/commands.md`，排障见 `references/troubleshooting.md`。

```powershell
bctl.ps1 doctor
bctl.ps1 windows
bctl.ps1 title|url|tabs|tab|newtab|closetab <pid> ...
bctl.ps1 uia <pid> [--type Button] [--pattern "正则"] [--limit N]
bctl.ps1 find <pid> <正则>
bctl.ps1 text <pid> [--file page.txt]
bctl.ps1 clickel <pid> "<元素名>" [--type T]
bctl.ps1 click <x> <y> [left|right|middle] [--double]
bctl.ps1 drag <x1> <y1> <x2> <y2>
bctl.ps1 scroll <x> <y> <±delta>
bctl.ps1 type "<文本>" | type --file txt
bctl.ps1 key CTRL+L
bctl.ps1 shot [--win <pid>] [--region x,y,w,h] [--file out.png]
bctl.ps1 nav <pid> <url>
bctl.ps1 js "<code>" [--timeout 20]
bctl.ps1 bridge start|status|stop
```

所有命令加 `--json` 输出机器可解析的单行 JSON。

## 交付物

一次操作任务，交付三件：**做了什么**（命令序列）、**结果证据**（截图或 JS 返回值）、**现场恢复说明**（改动了什么、怎么还原）。
