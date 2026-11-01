# dsh-browser-bridge

> 让 AI 接管你**已经打开、正在运行**的浏览器——不重启、不开调试端口、不装 Playwright。
> Drive the browser you already have open. No restart, no `--remote-debugging-port`, no CDP, no npm build.

一个 DeepSeek Harness 插件 + 技能包，完成这些事：读当前网页全文、按元素名点击、填表、
滚轮拖拽、执行 JavaScript、抓数据和 Cookie。

```
┌─────────────┐   UI Automation / SendInput   ┌──────────────────┐
│     DSH     │ ────────────────────────────► │  Edge / Chrome   │
│   session   │                               │  (already open)  │
│             │ ◄────── 127.0.0.1:8737 ───────┤  userscript 桥    │
└─────────────┘                               └──────────────────┘
```

---

## 为什么不用 CDP

Chromium 的调试端口**只在启动时能打开**，进程跑起来之后无法事后附加。
常见做法要么让用户重启浏览器，要么另起一个干净实例（丢掉登录态）。

本项目用三条系统级通道绕开这个限制：

| 通道 | 原理 | 能力 |
|---|---|---|
| **UI Automation** | Windows 无障碍树，Chromium 把 DOM 投影成 UIA 节点 | 读整页文本、枚举链接/按钮/输入框及屏幕坐标、按名字点击、读写信箱值 |
| **SendInput** | Win32 输入注入，`KEYEVENTF_UNICODE` 直送字符 | 任意坐标点击/拖拽/滚轮、快捷键、中文输入（绕过输入法） |
| **userscript 桥** | 篡改猴脚本轮询 `127.0.0.1:8737` | 真 DOM：查询、点击、填表、Cookie、localStorage、`fetch` |

---

## 安装

### 方式一：装进 DSH（推荐）

```sh
dsh plugin --profile web add github:xkzm123/dsh-browser-bridge
```

或者用打好的 tarball（不需要执行构建脚本）：

```sh
dsh plugin --profile web add https://github.com/xkzm123/dsh-browser-bridge/releases/download/v1.1.0/dsh-browser-bridge-1.1.0.tgz
```

装完重启一次 `dsh web`，会话里就会多出 16 个 `browser_*` 工具。

把 `web` 换成你自己 profile 的名字即可。装完可以用
`dsh --profile web --dump-config` 确认 `dsh-browser-bridge` 那一行在插件树里。

### 方式二：作为技能（没有插件系统时）

```powershell
git clone https://github.com/xkzm123/dsh-browser-bridge.git
cd dsh-browser-bridge
powershell -ExecutionPolicy Bypass -File install.ps1
```

装到 `%USERPROFILE%\.dsh\skills\dsh-browser-bridge`，之后每个 Harness 会话都能读到 `SKILL.md`，
并用 `scripts/bctl.ps1` 直接下命令。

### 方式三：只用命令行

```powershell
.\scripts\bctl.ps1 doctor
```

零依赖：Windows 10/11 + 自带 PowerShell 5.1，不需要 Python、Node、npm。

### JS 桥（可选，`browser_run_js` 需要）

```powershell
.\scripts\bctl.ps1 bridge start
.\scripts\bctl.ps1 nav <pid> http://127.0.0.1:8737/install.user.js
.\scripts\bctl.ps1 clickel <pid> "安装" --type Button
```

需要浏览器装了 [Tampermonkey](https://www.tampermonkey.net/)。桥只监听 `127.0.0.1`，
用 `TcpListener` 实现，普通权限即可运行，不需要管理员，也不需要 `netsh http add urlacl`。

---

## 16 个工具

| 工具 | 作用 |
|---|---|
| `browser_list_windows` | 列出可见窗口（pid / 尺寸 / 位置 / 标题）。先调这个拿 pid |
| `browser_tabs` | 列出标签页和当前选中项 |
| `browser_page_info` | 当前页的标题和地址栏 URL |
| `browser_snapshot` | 无障碍树：控件类型、可访问名、中心坐标。可按类型/正则收窄 |
| `browser_get_text` | 抽取整页可见文本 |
| `browser_click_element` | 按可访问名点击（先切前台，点元素中心） |
| `browser_click_at` | 按物理像素坐标点击（canvas 等无节点区域） |
| `browser_type_text` | Unicode 直输文本，中文无需输入法 |
| `browser_press_key` | 组合键：`CTRL+L` `ENTER` `PAGE_DOWN` `F5` … |
| `browser_scroll` | 在指定坐标滚轮 |
| `browser_navigate` | 走地址栏打开 URL |
| `browser_switch_tab` | 按 1–9 切换标签页 |
| `browser_screenshot` | 截全屏或单窗口，返回 PNG 路径 |
| `browser_run_js` | 在页面里执行 JavaScript（需 JS 桥） |
| `browser_page_query` | 固定的 DOM 操作词表（不需要 eval，CSP 页可用） |
| `browser_bridge` | 启动 / 查看 / 停止本地桥服务 |

### 两条 JS 路径

`browser_run_js` 用 `new AsyncFunction` 执行任意代码，自带 `__q` `__qa` `__text` `__click` `__sleep`
和顶层 `await`。

**但 GitHub 这类 CSP 严格的站点会禁止 eval**——沙箱继承页面 CSP。这种情况下
`browser_run_js` 会明确报错，并提示改用 `browser_page_query`：

| op | 参数 | 返回 |
|---|---|---|
| `title` `url` `text` `links` `cookies` | — | 页面基本信息 |
| `html` | `selector?` | outerHTML |
| `query` | `selector` `attr?` `prop?` | 逐个元素的属性或文本 |
| `count` | `selector` | 匹配数量 |
| `click` `submit` | `selector` | 执行结果 |
| `fill` | `selector` `value` | 触发 input/change 事件 |
| `meta` | `name` | meta content |
| `storage` | `store?` | localStorage / sessionStorage |
| `scrollTo` `scrollBy` | `x` `y` | — |

这套词表全部是直接 DOM 调用，不经过 eval，任何 CSP 下都能跑。

---

## 命令行

```powershell
bctl.ps1 doctor                                   # 体检：DPI、虚拟屏幕、UIA、浏览器列表
bctl.ps1 windows / browsers / active
bctl.ps1 title|url|tabs|tab|newtab|closetab <pid> ...
bctl.ps1 uia <pid> [--type Button] [--pattern 正则] [--limit N]
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
bctl.ps1 js --op query --args '{"selector":"a","attr":"href"}'
bctl.ps1 bridge start|status|stop [--port N]
```

所有命令加 `--json` 输出机器可解析的单行 JSON；列表类命令恒为数组。

---

## 仓库结构

```
dsh-browser-bridge/
├── package.json          # dsh.bundle manifest，dsh plugin add 靠它识别
├── cordis.patch.yml      # 插件在 profile 里的那一行
├── lib/index.js          # 16 个工具的定义（无构建步骤，直接 ESM）
├── scripts/
│   ├── bctl.ps1          # CLI 主程序
│   ├── BctlLib.ps1       # Win32 P/Invoke + UIA 封装 + DPI 感知
│   └── bctl.cmd
├── bridge/
│   ├── server.ps1        # 本地 TCP 桥
│   └── bridge.user.js    # 篡改猴脚本（eval + op 词表）
├── SKILL.md              # 作为 DSH 技能使用时的入口
├── references/           # 命令手册、排障
├── install.ps1 / uninstall.ps1
└── examples/demo.ps1
```

---

## 已知边界

- **仅 Windows。** UIA 与 SendInput 是 Win32 能力；非 Windows 上插件只打一条警告，不注册工具。
- **坐标是物理像素。** 多显示器虚拟屏幕可能带负原点（例如 `3840x1080 @-1920,0`）。
- **canvas / 闭包 shadow DOM** 在无障碍树里看不到，只能靠截图识图或 JS 桥。
- **JS 桥只对可见标签页生效**，后台标签页不抢任务。
- **`browser_type_text` 会在光标处插入**，不覆盖已有内容；要覆盖先 `CTRL+A`。
- **CSP 严格的站点禁用 `browser_run_js`**，改用 `browser_page_query`。

---

## 排障

见 [`references/troubleshooting.md`](references/troubleshooting.md)。三条最常见：

1. `window not found` → pid 变了，重新 `doctor`
2. `UI Automation cannot see this window` → 窗口最小化，先 `focus`
3. `no result in 20s` → JS 桥没装 / 标签页被切到后台 / 桥服务没起

---

## License

MIT
