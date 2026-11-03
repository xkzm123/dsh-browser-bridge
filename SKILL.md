---
name: dsh-browser-bridge
description: 操控用户已经打开、正在运行的 Edge/Chrome/Firefox（不重启、不开调试端口）。三条通道：UI Automation 无障碍树（读页面全文、枚举元素与坐标、按名字点击/填值）、SendInput 键鼠模拟（坐标点击、拖拽、滚轮、快捷键、Unicode 直输中文）、篡改猴 userscript 桥（在页面里跑任意 JS，拿真 DOM、Cookie、fetch）。当用户说"操作/控制我打开的浏览器""帮我点一下网页""在我浏览器里填个表""抓这个页面的数据""自动化 Edge/Chrome""不重启直接操控浏览器""browser automation without CDP"时使用。
---

# dsh-browser-bridge

让任意一个 DeepSeek Harness 会话，直接接管用户**当前已经打开**的浏览器窗口。
不重启浏览器，不要求开 `--remote-debugging-port`，不装 Playwright，没有 npm 依赖。

## 两种用法

- **插件模式**（推荐）：`dsh plugin --profile web add github:xkzm123/dsh-browser-bridge`，
  会话里直接多出 22 个 `browser_*` 工具，不需要命令行。
- **技能模式**（本文件）：`install.ps1` 装到 `~/.dsh/skills/`，用 `scripts/bctl.ps1` 下命令。

两种模式共用同一套 PowerShell 实现，行为一致。下面是命令与纪律。

## 选择通道（先想清楚再动手）

| 通道 | 命令 / 工具 | 用在什么场景 |
|---|---|---|
| UIA 无障碍树 | `uia` `find` `text` `clickel` `invoke` `setvalue` `tabs` `url` `title` | 首选。元素级、抗分辨率、能按名字点，不靠猜坐标 |
| 键鼠模拟 | `click` `move` `drag` `scroll` `type` `key` | UIA 够不着的地方：canvas、闭包 shadow DOM、拖拽、文件上传框、快捷键 |
| JS 桥（eval） | `js "<code>"` | 无 CSP 限制的站点上批量抓取、改样式、读 localStorage |
| JS 桥（词表） | `js --op <op>` | **CSP 严格站点**（github.com 等）唯一可用的 DOM 通道 |

优先级：**能 UIA 就不点坐标；要数据先看 CSP**。

## 标准作业流程

1. `bctl.ps1 doctor` —— 确认 UIA 可用、拿到浏览器 pid、看虚拟屏幕尺寸
2. `bctl.ps1 title <pid>` / `url <pid>` —— 确认目标标签页是不是对的那一个
3. `bctl.ps1 uia <pid> --pattern "<关键词>"` —— 定位目标元素，拿 `cx,cy`
4. `bctl.ps1 shot --file out.png` → 用图像能力看一眼，确认坐标落在正确位置
5. 执行：`clickel`（按名字）或 `click cx cy`（按坐标）或 `js`（按数据）
6. **再截一张图验证结果**，不要假设成功

## 证据链：文字 → 结构 → 截图（省 token 的核心）

判断一件事，永远从最便宜的一层开始，够了就停：

| 层 | 手段 | 什么情况下用 |
|---|---|---|
| 1 | `browser_page_query` / `browser_get_text` | 默认。状态、属性、标题、列表内容都在这一层解决 |
| 2 | `browser_snapshot` | 不知道为什么点不动、需要元素的**名字和坐标**时 |
| 3 | `browser_screenshot` | 布局问题、canvas 内容、用户明确要图。**这是最贵的一层** |

配套的三个省法：
- `browser_wait_for` —— 等结果出现，轮询在页面里做，**不花对话 token**；不要用「截图→看→再截图」来等
- `browser_batch` —— 多步合成一次往返（清空 → 输入 → 回车）
- `browser_click_text` —— 点完直接回传 `after` 状态（class / aria-pressed），大多数「点成功了吗」当场答完

## 铁律（每条都是踩过的坑）

0. **不要启动、关闭或重启浏览器。** 工具层已经硬拒绝 `CTRL+W/F4` 和窗口按钮，不要试图绕过（`allowClose` / `--force`）。
0.5 **只点网页内容，不点浏览器自己的按钮。** 所有按名字查找都限定在 `Document` 子树里；如果报「matched a browser window control」，说明页面里真的没有这个元素，换个名字或先 `snapshot` 看看。 工具只操作已经存在的窗口。浏览器"不见了"通常是关掉最后一个窗口后进程常驻（任务栏无图标），用 `browser_windows` 看 `(no window — will be restored)` 标记，或直接调工具让它自己 `wake`。**执行 `msedge.exe` / `chrome.exe` 是最严重的错误**——它会多开一个窗口和一个标签，破坏用户现场。
1. **点击前先拿到坐标。** 坐标来自 `browser_snapshot` 的 `cx,cy`（物理像素，虚拟屏幕可能是负原点），不要凭空算。
2. **搜索/列表页要按标题选，不要按位置猜。** 先 `browser_page_query` 的 `items` op 拿到「标题 + 链接」列表，逐条读标题再决定点哪个。标题和目标不符就换关键词或翻页——不要挑一个看起来像的就点。
3. **不要在用户正在输入的输入框里注入文字。** `type` 与 `key` 现在必须带 `--pid`，发键前会校验前台窗口确实是目标浏览器；校验失败一个字符都不发。如果报「refused to send」，先把浏览器切到前台，不要重试。 先用 `uia --type Edit` 看有没有占位符/草稿；`type` 会插在光标处而不是覆盖。真要写先 `key CTRL+A` 再写。
3. **每次操作都要能撤回。** 改人草稿、切标签页、关页面之前，先把原状态记下来（`text`、`url`、`tabs`）。
4. **`type` 是 Unicode 直送，绕开输入法**——中文能打进去，但会打断用户正在进行的拼音组合。
5. **切前台是必要的。** `click` 打在后台窗口上等于点在别的东西上；`focus` 失败就用 `clickel`（内部会先 focus）。
6. **JS 桥只对可见标签页生效**（userscript 里用 `visibilityState` 抢活），要指定页面就先 `tab <pid> <n>`。
7. **凭据不进日志。** `js` 可能读到 Cookie/Token，落盘前先脱敏。
8. **CSP 严格的页面禁用 `js "<code>"`。** 沙箱继承页面 CSP，`new AsyncFunction` 会抛
   `EvalError`。github.com、Google 系、多数银行站都这样。此时改用
   `js --op <op> --args <json>`，那套词表是直接 DOM 调用，不过 eval。

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
bctl.ps1 type "<文本>" --pid <pid>       # --pid 必填：没有目标，文字会打进用户当前的任意窗口
bctl.ps1 key CTRL+L --pid <pid>          # 同上，--pid 必填
bctl.ps1 shot [--win <pid>] [--region x,y,w,h] [--file out.png] [--jpeg]
bctl.ps1 at <x> <y> [--pid <pid>]      # 坐标反查元素，点之前先确认落点
bctl.ps1 pixel <x> <y>                 # 一个像素的颜色，判状态不用截图
bctl.ps1 nav <pid> <url>
bctl.ps1 wait <pid> --title|--url|--text <正则> [--timeout ms]
bctl.ps1 js "<code>" [--timeout 8]
bctl.ps1 bridge start|install|status|stop
bctl.ps1 batch --file plan.txt [--keep-going]   # N 条命令一个进程，17 倍快
```

所有命令加 `--json` 输出机器可解析的单行 JSON。

**多步任务优先用 `batch`。** 每条命令都是新进程（冷启动 ~1.2s，其中真正干活 ~150ms），
把「读→等→找→点→验」写进一个计划文件一次跑完，5 步从 ~6.2s 降到 ~1.8s。
验证状态翻转用 `pixel` 取样（35ms），不要为了一句「变蓝了吗」去读一张 3MB 的截图。

## 交付物

一次操作任务，交付三件：**做了什么**（命令序列）、**结果证据**（截图或 JS 返回值）、**现场恢复说明**（改动了什么、怎么还原）。
