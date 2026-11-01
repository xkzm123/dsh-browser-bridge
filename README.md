# dsh-browser-bridge

> 让 AI 接管你**已经打开、正在运行**的浏览器——不重启、不开调试端口、不装 Playwright。
> Drive the browser you already have open. No restart, no `--remote-debugging-port`, no CDP, no npm.

用一个 DeepSeek Harness 会话就能完成：读当前网页全文、按元素名点击、填表、滚轮拖拽、
执行任意 JavaScript、抓数据和 Cookie。

```
┌─────────────┐   UIA / SendInput   ┌──────────────────┐
│     DSH     │ ──────────────────► │  Edge / Chrome   │
│   session   │                     │  (already open)  │
│             │ ◄── localhost:8737 ─┤  userscript 桥    │
└─────────────┘                     └──────────────────┘
```

---

## 为什么不是 CDP

Chromium 内核的调试端口**只能在启动时打开**，进程跑起来之后没法事后附加。
常见方案要么让用户重启浏览器，要么另起一个干净实例（丢掉登录态）。

本项目绕开这个限制，用三条系统级通道：

| 通道 | 原理 | 能力 |
|---|---|---|
| **UI Automation** | Windows 无障碍树。Chromium 把整个 DOM 投影成 UIA 节点 | 读页面全文、枚举链接/按钮/输入框及其屏幕坐标、按名字点击、读写信箱值 |
| **SendInput** | Win32 输入注入，`KEYEVENTF_UNICODE` 直送字符 | 任意坐标点击/拖拽/滚轮、快捷键、中文输入（绕过输入法） |
| **userscript 桥** | 篡改猴脚本轮询 `127.0.0.1:8737` | 真 DOM、任意 JS、fetch（带 Cookie）、localStorage、请求改写 |

---

## 安装

### 1. 装成 DSH skill（推荐，所有会话自动可用）

```powershell
git clone https://github.com/xkzm123/dsh-browser-bridge.git
cd dsh-browser-bridge
powershell -ExecutionPolicy Bypass -File install.ps1
```

装到 `%USERPROFILE%\.dsh\skills\dsh-browser-bridge`，之后每个 Harness 会话都能直接调用。

### 2. 只想要命令行

```powershell
.\scripts\bctl.ps1 doctor
```

零依赖：Windows 10/11 + 自带 PowerShell 5.1 即可，不需要 Python、Node、npm。

### 3. JS 桥（可选，但强烈建议）

```powershell
.\scripts\bctl.ps1 bridge start
.\scripts\bctl.ps1 nav <pid> http://127.0.0.1:8737/install.user.js
.\scripts\bctl.ps1 clickel <pid> "安装" --type Button     # 浏览器里点一下安装
.\scripts\bctl.ps1 js "document.title"                   # 通了
```

需要浏览器装了 [Tampermonkey](https://www.tampermonkey.net/)。

---

## 快速开始

```powershell
# 0. 体检：拿到浏览器 pid、确认 UIA 可见
.\scripts\bctl.ps1 doctor
#   browsers : {@{pid=13008; process=msedge; uiaVisible=True; ...

# 1. 现在这个标签页是什么
.\scripts\bctl.ps1 title 13008
.\scripts\bctl.ps1 url   13008

# 2. 列出所有标签页，切到第 2 个
.\scripts\bctl.ps1 tabs 13008
.\scripts\bctl.ps1 tab  13008 2

# 3. 把页面上的按钮列出来（只看 Button）
.\scripts\bctl.ps1 uia 13008 --type Button

# 4. 按名字点它（自动先切前台）
.\scripts\bctl.ps1 clickel 13008 "登录" --type Button

# 5. 读整页文字
.\scripts\bctl.ps1 text 13008 --file page.txt

# 6. 在页面里跑 JS（需要 JS 桥）
.\scripts\bctl.ps1 js "__qa('a').map(a => a.href).slice(0,10)"
```

---

## 命令总表

| 命令 | 说明 |
|---|---|
| `doctor` | 环境自检：DPI、虚拟屏幕、UIA 可用性、浏览器列表 |
| `windows [--all]` | 顶层窗口列表（pid / handle / 类名 / 尺寸 / 标题） |
| `browsers` | 只列浏览器进程 |
| `active` | 当前前台窗口 |
| `focus <pid\|标题>` | 切前台（AttachThreadInput 绕过前台锁） |
| `title <pid>` | 当前页面标题 |
| `url <pid>` | 地址栏里的 URL |
| `tabs <pid>` | 标签页列表 + 选中状态 |
| `tab <pid> <1-9>` | 切换标签页 |
| `newtab` / `closetab <pid>` | 开 / 关标签页 |
| `nav <pid> <url>` | 地址栏 → URL → 回车 |
| `uia <pid> [--type T] [--pattern re] [--limit N]` | 导出无障碍树（name/type/rect/中心坐标） |
| `find <pid> <正则>` | 按名字找元素 |
| `text <pid> [--file f]` | 抽取可见页面文本 |
| `clickel <pid> <名字> [--type T]` | 按元素名点击 |
| `invoke <pid> <名字>` | Invoke / Select / Toggle 模式调用 |
| `setvalue` / `value <pid> <名字> [值]` | 读写信箱值 |
| `click <x> <y> [left\|right\|middle] [--double]` | 坐标点击 |
| `move` / `drag` / `scroll` | 鼠标 |
| `type "<文本>" \| --file f` | Unicode 直送文本（中文可，绕输入法） |
| `key CTRL+L` | 组合键、功能键、导航键 |
| `shot [--win pid] [--region x,y,w,h] [--file f]` | 截图 |
| `js "<code>" [--timeout N]` | 在页面里执行 JS（JS 桥） |
| `bridge start\|status\|stop [--port N]` | 管理本地桥服务 |
| `wait <ms>` / `clip get\|set` | 等待 / 剪贴板 |

全部命令支持 `--json`。

---

## JS 桥执行环境

```powershell
.\scripts\bctl.ps1 js "__text().length"
.\scripts\bctl.ps1 js "const r = await fetch('/api/me'); return await r.json()"
.\scripts\bctl.ps1 js "__click('.submit'); await __sleep(500); return document.title"
```

注入环境自带：

| 名字 | 作用 |
|---|---|
| `__q(sel)` | `document.querySelector` |
| `__qa(sel)` | `querySelectorAll` → Array |
| `__text()` | `document.body.innerText` |
| `__click(sel)` | 点击元素，返回是否找到 |
| `__sleep(ms)` | 等待 |

顶层 `await` 可用；裸表达式自动取返回值；`return` 的复杂对象自动 JSON 化。

---

## 已知边界

- **Windows only.** UIA + SendInput 是 Win32 能力。
- **坐标系是物理像素。** 进程以 Per-Monitor-V2 感知启动，多显示器虚拟屏幕可能带负原点（`screen: 3840x1080 @-1920,0`）。
- **canvas / 闭包 shadow DOM** UIA 看不见，只能靠截图识图或 JS 桥。
- **JS 桥只对可见标签页生效**，后台标签页不抢活。
- **`type` 会打断正在进行的 IME 组合**，操作前确认输入框是空的或已全选。
- **弹窗级授权**（UAC、文件选择器）需要人工点了才有句柄。

---

## 排障

见 [`references/troubleshooting.md`](references/troubleshooting.md)。

最常见三条：

1. `window not found` → pid 变了，重新 `doctor` 拿 pid
2. `UI Automation cannot see this window` → 浏览器最小化了，先 `focus`
3. `no result in 20s` → JS 桥没装 / 当前标签页被切到后台 / server 没起

---

## 卸载

```powershell
powershell -ExecutionPolicy Bypass -File uninstall.ps1
```

浏览器里到 篡改猴 → 管理面板 → 删掉 `dsh-browser-bridge`。

---

## License

MIT
