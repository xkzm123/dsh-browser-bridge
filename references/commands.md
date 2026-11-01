# 命令手册

所有命令通过 `scripts\bctl.ps1` 调用：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\bctl.ps1 <command> [args] [--json]
```

参数规则：

- `--json` 输出单行 JSON（`{"ok":true,...}` 或 `{"ok":false,"error":"..."}`）
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

### `nav <pid> <url>`
`CTRL+L` → `CTRL+A` → 输入 URL → `ENTER`。

---

## 无障碍树

### `uia <pid> [--type T] [--pattern re] [--limit N]`
导出全部后代节点。字段：`name type automationId className rect x y w h cx cy enabled offscreen`。

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

### `clickel <pid> <名字> [--type T]`
按元素名找到元素 → 取包围盒中心 → `focus` → 点击。
名字先精确匹配，失败再按正则转义后模糊匹配。

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
```

默认保存到当前目录 `shot.png`。

---

## JS 桥

### `bridge start|status|stop [--port 8737]`
起停本地 TCP 服务（`127.0.0.1`，纯 `TcpListener`，**不需要管理员权限**，也不占用 HTTP URL ACL）。

### `js "<code>" [--file x.js] [--timeout 20]`
入队 → 等可见标签页取走 → 执行 → 回传。

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

### `wait <ms>`
### `clip get` / `clip set <文本>`
