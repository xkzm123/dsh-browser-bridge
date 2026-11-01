# 命令手册

所有命令通过 `scripts\bctl.ps1` 调用：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\bctl.ps1 <command> [args] [--json]
```

参数规则：

- `--json` 输出单行 JSON（`{"ok":true,...}` 或 `{"ok":false,"error":"..."}`）；
  非 ASCII 字符一律转成 `\uXXXX`，保证跨进程、跨代码页读取都不会被截断
- `--key value` 形式传参，`--flag` 形式传布尔
- 位置参数顺序见下表
- 中文参数建议用 `--file` 从 UTF-8 文件读入，避免控制台编码损失

---

## 环境

### `doctor`
环境体检。

```powershell
bctl.ps1 doctor
```

```
version     : 1.0.0
powershell  : 5.1.26100.7920
os          : Microsoft Windows NT 10.0.26100.0
dpiAware    : True
screen      : 3840x1080 @-1920,0
uiaLoaded   : True
browsers    : {@{pid=13008; process=msedge; uiaVisible=True; title=...; rect=1920x1040 @0,0}}
```

`screen` 的 `@x,y` 是多显示器虚拟屏幕原点，**可能是负数**。截图和坐标都基于这个空间。

### `windows [--all]`
顶层窗口列表。默认过滤掉小于 200x100 的窗口。

### `browsers`
只列**真正的浏览器窗口**（`Chrome_WidgetWin_1` / `MozillaWindowClass` + 进程白名单），
宿主自己的 Electron 窗口不会出现。字段：`pid handle process active hidden w h title`。

`hidden: true` 表示进程在、窗口被隐藏（关掉最后一个窗口后的后台常驻状态）。

没有任何窗口时会给出可行动的错误，而不是让上层去重开浏览器：

```
ERR: msedge is running in the background but has no window.
     Ask the user to restore it from the taskbar (or run: bctl.ps1 wake).
     Do not launch a new browser: ...
```

### `wake`
把后台常驻、窗口被隐藏的浏览器**重新显示出来**。

```powershell
bctl.ps1 wake
```

返回 `pid / process / wasHidden / nowVisible / title`。这是「浏览器不见了」的正确处理方式——
重开 `msedge.exe` 会多出一个窗口和一个新标签。

### `active`
当前前台窗口的 handle / pid / 标题。

### `focus <pid|标题片段>`
切前台。内部用 `AttachThreadInput` + 模拟 Alt 键绕过 Windows 前台锁。

---

## 页面信息

### `title <pid>`
取 `Document` 节点的名字，即页面标题。

### `url <pid>`
读地址栏。优先匹配名字里带 `address|search|地址|搜索` 的 `Edit`，退化到工具栏区域第一个 `Edit`。

### `text <pid> [--file out.txt]`
用 UIA `TextPattern.DocumentRange.GetText(-1)` 抽整页可见文本。默认写 `page.txt` 并打印前 1200 字。

### `tabs <pid>`
```
index selected name                                   rect
----- -------- ----                                   ----
    1    False 哔哩哔哩 (゜-゜)つロ 干杯~-bilibili              2,0 256x41
    2     True 账号与API计费区别 - DeepSeek                 241,0 256x41
```

### `tab <pid> <1-9>` / `newtab` / `closetab`
内部发 `CTRL+1..9` / `CTRL+T` / `CTRL+W`，执行前自动 `focus`。

### `nav <pid> <url> [--new-tab]`
默认**幂等**：先看当前标签页是不是已经在目标地址，再按域名扫其它标签页的标题；
命中就切过去并返回 `reused: true`，什么都不重新加载。都不命中才走地址栏导航。

```powershell
bctl.ps1 nav 13008 "https://example.com"          # 已开着 → reused
bctl.ps1 nav 13008 "https://example.com" --new-tab # 强制真的导航
```

导航前后各记一次窗口状态；窗口中途消失会返回明确错误。

---

## 无障碍树

### `uia <pid> [--type T] [--pattern re] [--limit N] [--chrome]`
导出网页子树（`Document` 之下）的全部节点。字段：`name type automationId className rect x y w h cx cy enabled offscreen`。

**默认不含窗口 chrome**：标题栏的最小化/还原/关闭按钮既不出现也不能点。
加 `--chrome` 才会包含（只读排查用，点击仍受保护）。页面还没渲染好时会直接报错让你重试，**不会**回退到窗口树。

`--type` 取 `Button` `Edit` `Text` `Hyperlink` `Document` `TabItem` `ListItem` `ComboBox` `CheckBox` `Image` `Group` `Pane` `ToolBar` 等。

```powershell
bctl.ps1 uia 13008 --type Button --limit 30
bctl.ps1 uia 13008 --pattern "登录|Sign in"
```

`offscreen` 节点 `cx/cy` 为 `-1`，不可点。

### `find <pid> <正则>`
按 `Name` 正则过滤，等价于 `uia --pattern`，更短。

---

## 交互

### `clickel <pid> <名字> [--type T] [--chrome] [--force]`
按元素名找到元素 → 取包围盒中心 → `focus` → 点击。
名字先精确匹配，失败再按正则转义后模糊匹配。**只在网页内容里找**。

两道闸：

1. 元素必须位于 `Document` 子树内，否则拒绝——
   `'关闭' matched a browser window control ... Nothing was clicked.`
2. `--chrome` 模式下命中 `最小化/还原/关闭` 也拒绝，除非再加 `--force`。

点击前后各记一次窗口状态，点完窗口如果不见了会立刻报错。

```powershell
bctl.ps1 clickel 13008 "安装" --type Button
```

### `invoke <pid> <名字>`
不点坐标，直接调 `InvokePattern` / `SelectionItemPattern` / `TogglePattern`。后台窗口也能生效。

### `setvalue` / `value <pid> <名字> [值]`
走 `ValuePattern`。比 `click` + `type` 干净，但只对 Web 表单输入框有效。

### `click <x> <y> [left|right|middle] [--double] [--triple]`
物理像素坐标点击。

### `move <x> <y>` / `drag <x1> <y1> <x2> <y2>`
`drag` 分 20 步插值移动，模拟人手拖动。

### `scroll <x> <y> <±delta>`
把光标移到 `(x,y)` 再发滚轮事件。`120` 一格，负数向下。

### `type "<文本>" | --file <path>`
`KEYEVENTF_UNICODE` 逐字符注入。

- 中文、emoji、全角符号都能进
- **绕开输入法**，但会打断用户正在进行的 IME 组合
- 插入到当前光标处，不覆盖已有内容；要覆盖先 `key CTRL+A`

### `key <组合键> [--allow-close]`
`CTRL+W` / `CTRL+F4` / `ALT+F4` / `CTRL+SHIFT+W` / `CTRL+Q` 默认**拒绝执行**：
关掉最后一扇窗会让浏览器进入「进程在、窗口没了」的状态。要关得显式加 `--allow-close`。

### `key <组合键>`
```
CTRL+L  CTRL+W  CTRL+T  CTRL+A  CTRL+SHIFT+I
ENTER  ESC  TAB  SPACE  BACKSPACE  DELETE
UP  DOWN  LEFT  RIGHT  HOME  END  PAGEUP  PAGEDOWN
F1..F12  A..Z  0..9  COMMA  PERIOD  SLASH  BACKSLASH
```

---

## 截图

```powershell
bctl.ps1 shot --file out.png                       # 整个虚拟屏幕
bctl.ps1 shot --win 13008 --file win.png           # 单个窗口
bctl.ps1 shot --region 0,0,800,600 --file crop.png # 区域
bctl.ps1 shot --win 13008 --file win.jpg --jpeg --quality 80   # 小文件
```

默认保存到当前目录 `shot.png`。返回 `{file, bytes}`。

4K 整屏 PNG 约 3MB，JPEG 同画面约 150KB（实测 1.1MB → 163KB）。**判状态不需要图**，
用下面的 `pixel` 就够；只有在要看布局时才截图。

---

## 校验（判状态不用看图）

### `at <x> <y> [--pid <pid>] [--depth N]`

从坐标反查元素（UIA `ElementFromPoint`），返回命中元素及其祖先链，每行带 `inPage`。
点击前先证明这个坐标落在目标控件上，而不是点完再截图猜。

```powershell
bctl.ps1 at 220 978 --pid 13008 --json
# [{"type":"Text","name":"1.3万","rect":"239,974 34x16",...,"inPage":true}, ...]
```

`inPage=false` 的行是浏览器自己的窗口 chrome（标签栏、地址栏、控制按钮），点它等于操作浏览器。

### `pixel <x> <y>`

读一个物理像素的颜色，返回 `hex` / `rgb` / `r,g,b`。一次约 35ms，比截图便宜两个数量级。

```powershell
bctl.ps1 pixel 220 978 --json
# {"x":220,"y":978,"rgb":"0,174,236","hex":"#00aeec","r":0,"g":174,"b":236}
```

典型用法：点之前取样一次，点之后取样一次，颜色变了就是状态翻转——「点赞成功」的证据
是一条 `#00aeec`，不是一张 3MB 的图。


---

## JS 桥

### `bridge start|install|status|stop [--port 8737]`
起停本地 TCP 服务（`127.0.0.1`，纯 `TcpListener`，**不需要管理员权限**，也不占用 HTTP URL ACL）。

`bridge install` 会顺手把 `<port>/install.user.js` 在默认浏览器里打开，装油猴脚本不用手拼 URL。

### `js "<code>" [--file x.js] [--timeout 8]`
入队 → 等可见标签页取走 → 执行 → 回传。

失败分两种，报错会直说属于哪一种，不用猜：

```text
no userscript client is polling the bridge (never polled)      ← 脚本没装，200ms 内返回
the job was claimed by a tab but never returned (1 still pending) ← 领了没回，页面/CSP 的问题
```

```powershell
bctl.ps1 js "document.title"
bctl.ps1 js "__qa('a').map(a => a.href)"
bctl.ps1 js "const r = await fetch('/api/user'); return await r.json()"
bctl.ps1 js "__click('.next'); await __sleep(800); return document.title"
```

返回值处理：先按「语句块」执行，返回 `undefined` 时再按「表达式」执行一次，所以裸表达式也能拿到值。

### `js --op <op> [--args <json>]`
固定操作词表，**不经过 eval**，因此在 CSP 严格的页面（github.com、Google 系、多数银行站）上仍然可用。

```powershell
bctl.ps1 js --op title
bctl.ps1 js --op count --args '{"selector":"a"}'
bctl.ps1 js --op query --args '{"selector":"h2","attr":"id"}'
bctl.ps1 js --op click --args '{"selector":".next-button"}'
bctl.ps1 js --op fill  --args '{"selector":"#q","value":"hello"}'
bctl.ps1 js --op cookies
```

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
| `waitFor` | `selector` 或 `text`、`timeoutMs` | 等元素/文字出现，出现即返回 |
| `batch` | `steps: [{op,args}]`、`stopOnError` | 依次执行多步，返回每步结果 |
| `clickText` | `text`、`selector?`、`exactly?` | 按文字点击，**并回传点击后的 class/aria 状态** |

```powershell
# 等搜索结果出现（轮询在页面里做，不消耗对话 token）
bctl.ps1 js --op waitFor --args '{"selector":".video-list","timeoutMs":8000}'

# 多步合成一次调用
bctl.ps1 js --op batch --args '{"steps":[{"op":"fill","args":{"selector":"#q","value":"白丝"}},{"op":"submit","args":{"selector":"#q"}}]}'

# 按文字点赞，返回值里直接带 after 状态
bctl.ps1 js --op clickText --args '{"text":"点赞"}'
```

页面禁用 eval 时 `js "<code>"` 会返回一条说明，列出上面这些 op。

### 协议（自己接客户端时用）

| 方法 | 路径 | 作用 |
|---|---|---|
| GET | `/ping` | 存活探测 |
| GET | `/poll` | 取一条待执行任务 `{id, code}`，无任务返回 `{id:0}` |
| POST | `/cmd` | 入队 `{code}` → `{id}` |
| POST | `/result` | 回传 `{id, ok, value, error, url, title}` |
| GET | `/result?id=N` | `{status:"pending"}` 或 `{status:"done",...}` |
| GET | `/stats` | 计数统计 |
| GET | `/install.user.js` | 让篡改猴自动识别安装的 userscript 本体 |

---

## 杂项

### `ensure [--reopen]`
浏览器状态机，四种结果：`absent` / `windowless` / `hidden`（自动恢复）/ `ok`。
`--reopen` 是唯一会启动浏览器的路径，且必须人工显式加。

### `audit tail [n]`
打印 `~\.dsh\browser-bridge\audit.log` 最后 n 条（默认 20）。每条动作带
`before/after` 的窗口 handle 与可见性，用来定位「哪一步之后窗口没了」。

### `wait <ms>` / `wait <pid> --title <re> | --url <re> | --text <re> [--timeout ms] [--poll ms]`

不带谓词时是老行为：睡固定毫秒。带谓词就变成条件轮询——命中立刻返回，返回
`{ok, matched, elapsedMs, tries, seen}`；没命中时 `ok=false` 并给出 `hint`。

```powershell
bctl.ps1 wait 13008 --title "哔哩哔哩" --timeout 5000 --json
bctl.ps1 wait 13008 --text "热门" --poll 200 --json
```

比 `Start-Sleep 3` 好在：页面已经好了就立刻走，通常省一半以上等待，而且「等到了没有」
是返回值，不是猜。

### `clip get` / `clip set <文本>`

---

## 流水线 `batch`（一次往返跑完整条链）

```powershell
bctl.ps1 batch --file plan.txt [--keep-going] [--echo] [--json]
bctl.ps1 batch --cmd "title 13008" --cmd "pixel 220 978" --json
bctl.ps1 batch --steps '["title 13008","url 13008"]' --json
```

每条命令都是一个新的 `powershell.exe`：冷启动 ~800ms + 现场编译 C# ~265ms，
而真正干活只有 ~150ms。`batch` 把这些命令放进**同一个进程**里连着跑，
只付一次启动成本。

实测（同一台机器、同一页面）：

| 方式 | 5 条命令耗时 |
|---|---|
| 5 次独立调用 | ~6250 ms（1250 ms/条） |
| `batch --file` | ~1800 ms（进程启动 1200 + 内部 798） |

计划文件一行一条命令，`#` 开头是注释，引号内的空格不切分：

```text
# 打开 B 站搜索页并点赞
title 13008
url 13008
wait 13008 --title "哔哩哔哩" --timeout 4000
uia 13008 --type Edit --limit 4
pixel 220 978
```

输出是一个聚合结果，每步都带命令、成败、耗时和数据：

```json
{"ok":true,"count":5,"failed":0,"totalMs":798,"steps":[
  {"n":1,"cmd":"title 13008","ok":true,"ms":323,"data":{"ok":true,"title":"…"}},
  {"n":2,"cmd":"url 13008","ok":true,"ms":135,"data":{"ok":true,"url":"…"}}
]}
```

默认遇到失败就停；加 `--keep-going` 继续跑完剩下的步骤，失败的那步在结果里带 `error`。

`seq` / `pipeline` 是 `batch` 的别名。

### 什么时候用哪条通道

| 目标 | 走什么 | 为什么 |
|---|---|---|
| 多步 UI 操作（读→等→找→点→验） | `batch --file/--cmd` | 一个进程，17 倍快 |
| 判某个按钮状态变了没 | `pixel` | 35ms，一张图都不用 |
| 点之前确认坐标落在谁身上 | `at` | 反查元素，不靠猜 |
| 抓 DOM 数据、改样式、调页面 API | `js` | 真 DOM 在页面里 |
| 看布局 / 交截图给人看 | `shot --region/--jpeg` | 只在真需要时付图像成本 |

