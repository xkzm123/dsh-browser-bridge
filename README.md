<p align="center">
  <img src="assets/cover.svg" width="100%" alt="dsh-browser-bridge — 让 AI 接管你已经开着的浏览器">
</p>

<p align="center">
  <a href="https://github.com/xkzm123/dsh-browser-bridge/releases"><img alt="version" src="https://img.shields.io/badge/version-1.1.0-2f81f7"></a>
  <a href="LICENSE"><img alt="license" src="https://img.shields.io/badge/license-MIT-2ea043"></a>
  <img alt="platform" src="https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-8957e5">
  <img alt="tools" src="https://img.shields.io/badge/tools-16-d29922">
  <img alt="deps" src="https://img.shields.io/badge/dependencies-0-2ea043">
</p>

**一句话**：装好之后，你可以在 DeepSeek Harness 里说「帮我点那个按钮」，它就去点你屏幕上**真的那个浏览器**——不是另开一个空白浏览器，就是你正在用的那个。

不用重启浏览器，不用装 Python 或 Node 环境，不用记命令。

---

## 目录

- [它到底能干什么](#它到底能干什么)
- [三步装好](#三步装好)
- [要不要装油猴脚本](#要不要装油猴脚本)
- [油猴脚本怎么装](#油猴脚本怎么装)
- [它是怎么做到的](#它是怎么做到的)
- [16 个工具](#16-个工具)
- [常见问题](#常见问题)
- [卸载](#卸载)

---

## 它到底能干什么

以前的 AI 只能告诉你「你应该点这里」。现在它能自己点。

| 你说的话 | 它做的事 |
|---|---|
| 「看看我浏览器现在开着什么」 | 读出所有窗口和标签页的标题 |
| 「把这个页面的正文念给我听」 | 抽取整页可见文字 |
| 「把那个登录按钮点了」 | 找到叫「登录」的按钮，把鼠标移过去真点一下 |
| 「搜索框里填上显卡价格，回车」 | 点进输入框，输入中文，按回车 |
| 「把这个页面截图给我」 | 截一张 PNG，存成文件 |
| 「把页面上所有链接收集起来」 | 返回全部链接地址（需要油猴脚本那步） |

它操作的是**你已经登录的浏览器**。所以那些需要登录才能看到的页面、买了会员才能看的视频，它都看得到——你不用把账号密码交给任何人。

---

## 三步装好

<p align="center">
  <img src="assets/diagrams/install-flow.svg" width="100%" alt="三步装好：装插件、重启、说一句话">
</p>

### 第一步：装插件

打开一个终端（开始菜单搜「PowerShell」也行），粘这一条回车：

```powershell
dsh plugin --profile web add github:xkzm123/dsh-browser-bridge
```

> **`web` 是什么？** 你的 DSH 运行配置的名字。多数人就是 `web`，照抄即可。
> 不知道的话，看一眼 `C:\Users\你\.dsh\profiles\` 下面有哪个文件夹，把它填进去。

**用桌面版 DSH 的看这里**：直接打开 **设置 → 插件**，搜 `dsh-browser-bridge` 装上就行，不用命令行。

装完会显示类似这样：

```
+ dsh-browser-bridge 1.1.0
Done in 3.2s
```

### 第二步：重启一次 DSH

插件只在 DSH 启动的时候加载，所以装完要重启一次。

- `dsh web` 用户：关掉终端里的进程，再 `dsh web` 开一次
- 桌面版用户：退出应用再打开

浏览器不用重启，标签页和登录状态都还在。

### 第三步：跟它说一句话

回到对话里，直接说：

> 看看我浏览器现在开着什么

它会调用 `browser_list_windows`，把窗口列表念给你听，比如：

```
pid=13008 1920x1040 @0,0 哔哩哔哩 - 个人 - Microsoft Edge
pid=12424 1920x1030 @-1920,0 DeepSeek Harness
```

看到这种输出，就说明装好了。

### 怎么确认装得对不对

不想靠猜的话，跑这一条：

```powershell
dsh --profile web --dump-config | Select-String -Context 0,3 browser-bridge
```

看到下面这几行就是对的：

```yaml
- id: dsh-browser-bridge
  name: dsh-browser-bridge
  config:
    timeoutMs: 60000
    bridgePort: 8737
```

---

## 要不要装油猴脚本

**答案：不装能用，装了更强。先看这张对比图。**

<p align="center">
  <img src="assets/diagrams/userscript-decision.svg" width="100%" alt="装与不装油猴脚本的能力对比">
</p>

- **只装插件** → 14 个工具。读页面、点按钮、打字、滚动、截图、切标签，够日常用。
- **再装油猴脚本** → 16 个工具。多出来的是「在页面里跑 JavaScript」，也就是能读 Cookie、读 localStorage、调页面内部接口、批量抓数据。

**油猴（Tampermonkey）是什么**：一个浏览器扩展，专门用来跑「用户脚本」——就是一小段注入到网页里运行的代码。我们要装的那个脚本，作用是把 AI 的指令送进页面里执行。

只有两个工具依赖它：

| 工具 | 作用 |
|---|---|
| `browser_run_js` | 在页面里跑任意 JavaScript |
| `browser_page_query` | 用固定词表查询页面（不需要 eval，CSP 严格的站点也能用） |

**结论**：先装插件，用几天。哪天需要抓数据了，再回来补这一步，随时可以加。

---

## 油猴脚本怎么装

### 1. 装 Tampermonkey 扩展（装过的跳过）

- Edge：[microsoftedge.microsoft.com/addons](https://microsoftedge.microsoft.com/addons/detail/tampermonkey/iikmkjmpaadaobahmlepeloendndfphd)
- Chrome：[chrome.google.com/webstore](https://chromewebstore.google.com/detail/tampermonkey/dhdgffkkebhmkfjojejmpbldmpobfkfo)

如果装不上（国内网络常见），也可以直接从 [tampermonkey.net](https://www.tampermonkey.net/) 下载 crx 手动拖进扩展页。

### 2. 启动本地桥

在终端里跑：

```powershell
bctl.ps1 bridge start
```

脚本在哪？装好的插件里自带一份：

```
C:\Users\你\.dsh\profiles\web\node_modules\dsh-browser-bridge\scripts\bctl.ps1
```

（`web` 换成你自己的 profile 名。）

看到 `bridge running on port 8737` 就成了。这个服务只监听 `127.0.0.1`，也就是只有你这台电脑能连，不需要管理员权限，也不会弹防火墙。

> 不想开终端也行：在对话里说「启动浏览器桥」，它会调 `browser_bridge` 工具帮你起。

### 3. 打开安装页，点确认

在浏览器地址栏输入：

```
http://127.0.0.1:8737/install.user.js
```

Tampermonkey 会弹出一个确认页：

<p align="center">
  <img src="assets/screenshots/tampermonkey-install.png" width="720" alt="Tampermonkey 安装确认页：脚本名、作者、来源地址、包含的 URL 范围">
</p>

图上能看到四件事，装之前扫一眼就行：

| 位置 | 内容 | 含义 |
|---|---|---|
| 左上 | `dsh-browser-bridge v1.1.0` | 脚本名和版本 |
| 作者 | `xkzm123` | 谁写的 |
| 源 | `http://127.0.0.1:8737/install.user.js` | 从你自己电脑上取的，没走外网 |
| 包含 URL | `*://*/*` | 在所有网页上生效——它需要能在任何页面里干活 |

点 **「安装」** 按钮。

> 图里显示的是「重新安装」和「即将重新安装用户脚本」。这是因为演示机器上已经装过一次了；**你第一次装会显示「安装」**，效果一样。

### 4. 验证

等一秒钟，然后随便开一个网页，在对话里说：

> 在这个页面上执行：document.title

能返回标题就成了。

如果没反应，看 [常见问题](#常见问题) 第五条。

---

## 它是怎么做到的

<p align="center">
  <img src="assets/diagrams/architecture.svg" width="100%" alt="三条通道：UI Automation、SendInput、篡改猴桥">
</p>

### 为什么不用最常见的「调试端口」方案

多数浏览器自动化工具（Playwright、Puppeteer）靠 Chrome 的**调试端口**（`--remote-debugging-port=9222`）。这条路有个死结：

**调试端口只能在浏览器启动的那一刻打开。** 浏览器已经跑起来了，就没法再从外面接进去。

所以那些工具要么让你**重启浏览器**（还得改快捷方式参数），要么**另开一个干净的浏览器实例**——后者意味着你的登录状态、会员、Cookie 全都没有，很多页面直接看不到。

这个插件换了个思路：**不接浏览器的调试接口，而是操作 Windows 本身。**

### 三条通道

| 通道 | 白话解释 | 负责什么 |
|---|---|---|
| **① UI Automation** | Windows 系统自带的「无障碍接口」。它是给读屏软件用的，能把屏幕上任何程序的界面结构念出来——包括浏览器里的网页 | 读页面文字、列出按钮/**元素位置**、按名字点 |
| **② SendInput** | Windows 系统自带的「模拟输入」接口。可以把鼠标移动、点击、按键注入进系统，效果和你自己动手一样 | 坐标点击、拖拽、滚轮、快捷键、中文输入 |
| **③ 篡改猴桥** | 一个跑在页面内部的脚本，通过 `127.0.0.1:8737` 和你电脑上的小服务通信 | 在页面里跑 JS、读 DOM 和 Cookie |

前两条操作的是「窗口」，第三条操作的是「页面内部」。三条一起，基本没有够不着的地方。

### 具体怎么跑

1. 你在对话里说一句话
2. 模型选一个工具，比如 `browser_click_element`
3. 插件把参数变成一个命令，交给本机的 `bctl.ps1`（一个 PowerShell 脚本）
4. 脚本按需选通道：查无障碍树拿到「登录」按钮的坐标 → 把鼠标移过去 → 真的点下去
5. 结果变成一段文字（或一张截图）回到对话里

整个过程不联网，全在你自己的电脑上完成。

### 一个真实的技术细节

无障碍接口和模拟输入都是 Win32 的老接口，返回的是**物理像素坐标**。多显示器的时候虚拟屏幕的原点可能是负的（比如左边那块屏幕是 `-1920,0`），所以脚本启动时会主动把进程设成「DPI 感知」，否则坐标会整体偏掉——这是这类工具最常见的翻车点。

---

## 16 个工具

| 工具 | 一句话 | 需要油猴 |
|---|---|---|
| `browser_list_windows` | 列出所有可见窗口 | |
| `browser_tabs` | 列出标签页 | |
| `browser_page_info` | 当前页的标题和网址 | |
| `browser_snapshot` | 导出页面元素清单（类型、名字、坐标） | |
| `browser_get_text` | 抽整页文字 | |
| `browser_click_element` | 按名字点击元素 | |
| `browser_click_at` | 按坐标点击 | |
| `browser_type_text` | 输入文本（中文可直接输入） | |
| `browser_press_key` | 发送快捷键 | |
| `browser_scroll` | 滚轮 | |
| `browser_navigate` | 打开网址 | |
| `browser_switch_tab` | 切换标签页 | |
| `browser_screenshot` | 截图存成 PNG | |
| `browser_bridge` | 启动/查看/停止本地桥 | |
| `browser_run_js` | 在页面里跑 JavaScript | ✅ |
| `browser_page_query` | 用固定词表查询页面 | ✅ |

不用记住它们——正常说话就行，模型会自己挑。

**想用命令行？** 同一套能力也有 CLI：

```powershell
bctl.ps1 doctor                       # 体检
bctl.ps1 windows                      # 列窗口
bctl.ps1 tabs 13008                   # 列标签页
bctl.ps1 uia 13008 --type Button      # 列页面按钮
bctl.ps1 clickel 13008 "登录"          # 按名字点
bctl.ps1 text 13008                   # 抽整页文字
bctl.ps1 js "document.title"          # 跑 JS
```

详见 [`references/commands.md`](references/commands.md)。

---

## 常见问题

**1. 能用在 Mac 或 Linux 上吗？**

不能。底层用的是 Windows 专有的无障碍接口和输入注入。`package.json` 里写了 `os: win32`，在别的系统上装不上。

**2. 会不会很危险？它能看到我所有东西吗？**

能看到**界面上显示出来的**东西，看不到你的密码明文，也读不到别的程序的数据。

建议：任务做完了，把 `browser_bridge` 停掉；不用了就把插件删掉。都有对应命令（见[卸载](#卸载)）。

**3. 它会不会自己乱点？**

不会自己动。每次都是你在对话里提出要求，它才调工具。而且改状态的操作（点击、输入）你可以要求它先截图确认。

**4. 点了没反应 / 点错位置**

先让它截个图看看：说「截个图我看下」。多数是窗口最小化了，或者你切到别的窗口去了——点击是全局注入的，打在后台窗口上等于点在别的东西上。

**5. 油猴装了，但是「执行 JS」一直超时**

按顺序查三件事：

1. 桥还在跑吗？`bctl.ps1 bridge status`
2. 篡改猴里能看到 `dsh-browser-bridge` 这个脚本吗？（点扩展图标 → 管理面板）
3. 那个标签页是**当前可见**的那个吗？后台标签页不抢任务

**6. GitHub 这种网站上「执行 JS」报 CSP 错误**

正常。GitHub、Google 这类站点禁止页面里执行动态代码，任何浏览器扩展都绕不过去。

插件的处理是：`browser_run_js` 明确告诉你被拦了，并让你改用 `browser_page_query`——它用一套固定的查询词表（读文字、查属性、点数、点击、填表），不经过 eval，这些站上照样能用。

**7. 输入中文变成了乱码？**

插件用 Unicode 直接送字符，不经过输入法，正常不会乱码。如果乱，多半是目标输入框还在输入法组合状态——先按一次 `Esc` 再输入。

**8. 装完插件 DSH 起不来了？**

删掉再起：

```powershell
dsh plugin --profile web remove dsh-browser-bridge
```

把报错贴到 [Issues](https://github.com/xkzm123/dsh-browser-bridge/issues) 里。

---

## 卸载

```powershell
# 1. 停掉本地桥
bctl.ps1 bridge stop

# 2. 删插件
dsh plugin --profile web remove dsh-browser-bridge

# 3. 删油猴脚本（如果装过）
#    浏览器 → 篡改猴图标 → 管理面板 → 找到 dsh-browser-bridge → 删除
```

---

## 给开发者

```
├── package.json          # dsh.bundle manifest，dsh plugin add 靠它识别
├── cordis.patch.yml      # 插件在 profile 里的那一行
├── lib/index.js          # 16 个工具的定义，纯 ESM，无构建步骤
├── scripts/
│   ├── bctl.ps1          # CLI 主程序
│   ├── BctlLib.ps1       # Win32 P/Invoke + UI Automation + DPI 感知
│   └── bctl.cmd
├── bridge/
│   ├── server.ps1        # 本地 TCP 桥（TcpListener，不需要管理员）
│   └── bridge.user.js    # 篡改猴脚本
├── assets/               # README 的图
└── references/           # 命令手册、排障
```

- 工具注册：`defineTool({...})` + `ctx.tools.register()`，见 `lib/index.js`
- 协议：`GET /poll` 取任务，`POST /result` 回传，见 `bridge/server.ps1` 顶部注释
- 已知边界：见 [`references/troubleshooting.md`](references/troubleshooting.md)

欢迎 PR 和 Issue。

---

## License

MIT
