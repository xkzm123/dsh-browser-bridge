# 排障

## 一、找不到窗口

```
ERR: window not found: 13008
```

pid 会变（浏览器重启、多进程架构的主进程切换）。重新拿：

```powershell
bctl.ps1 doctor | Select-String browsers
```

或者直接按标题片段找：`bctl.ps1 focus "Microsoft Edge"`。

`windows` 里同一进程可能有多个 `Chrome_WidgetWin_1`（比如桌宠、DevTools、PWA 窗口）。
挑 **标题是网页标题**、`w` 接近屏幕宽度的那一个。

---

## 一·五、浏览器整窗消失了（进程在、任务栏没图标、声音还在放）

这是 **Windows 上关掉最后一扇窗口后进程常驻** 的状态：窗口对象没了，任务栏自然也没图标。

先跑：

```powershell
bctl.ps1 ensure
```

| 输出 | 含义 | 怎么办 |
|---|---|---|
| `state: ok` | 窗口正常 | 你看到的消失可能是别的进程 |
| `state: hidden` | 窗口被隐藏，已自动恢复 | 已经帮你拉回来了 |
| `state: windowless` | 进程在、零窗口 | 点任务栏图标；或 `ensure --reopen`（会在原 profile 开窗，登录态不丢） |
| `state: absent` | 进程都没有 | 自己打开浏览器 |

**为什么会变成这样**：多半是某一步点到了标题栏的关闭按钮，或发了 `CTRL+W`。旧版本按名字找元素时会搜整个窗口树，页面里一个叫「关闭」的按钮和标题栏那个同名——`FindFirst` 按深度优先返回第一个，命中的是标题栏。

现在已从结构上修掉：查找只限 `Document` 子树，且点击前还会再校验一次祖先链。想复现验证就跑：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\test-guard.ps1
```

想看是哪一步出事：

```powershell
bctl.ps1 audit tail 20
```

## 二、UIA 看不见页面

```
ERR: UI Automation cannot see this window
```

原因与对策：

| 现象 | 原因 | 处理 |
|---|---|---|
| 只返回窗口按钮，没有 Document | 窗口最小化 / 被隐藏 | 先 `focus <pid>`，再 `uia` |
| 整棵树只有 Pane | Chromium 还没构建无障碍树 | 连查两次（第一次触发构建，第二次才有内容），中间 `wait 800` |
| 浏览器刚启动 | 渲染进程未就绪 | `wait 2000` 重试 |

Chromium 系在**第一个 UIA 客户端请求时**才开启完整无障碍树，所以「第一次查询结果很少」是正常的。

---

## 三、点击落在错误位置

排查顺序：

1. **看截图。** `bctl.ps1 shot --file s.png`，确认目标真的在那个像素上。
2. **确认坐标来源。** `uia` 输出的 `cx,cy` 已经是**屏幕绝对物理像素**，不要再加上窗口偏移。
3. **确认缩放。** `doctor` 里 `dpiAware: True` 表示进程已 Per-Monitor-V2 感知。如果外部传入的是浏览器里读到的 CSS 像素，要乘缩放比（125% → ×1.25）。
4. **确认虚拟屏幕原点。** `screen: 3840x1080 @-1920,0` 表示主屏在 0，左屏是负坐标。负坐标完全正常。
5. **确认前台。** 点击是全局注入的，打在后台窗口上等于点在桌面。

---

## 四、文字打不进去 / 变成乱码

| 现象 | 原因 | 处理 |
|---|---|---|
| 中文变成问号 | 控制台编码 | 用 `type --file utf8.txt`，文件以 UTF-8 无 BOM 保存 |
| 只进了第一个字 | 输入法还在组合状态 | 先 `key ESC` 或 `key CTRL+A` 取消组合 |
| 打断了用户的输入 | 注入到光标处 | 这是预期行为。改人草稿前先备份：`text` + `value` |
| 密码框不响应 | 部分安全控件屏蔽合成事件 | 只能 `click` 聚焦后 `key` 逐键 |

---

## 五、JS 桥没反应

```
ERR: no result in 20s (is the userscript installed and the target tab focused?)
```

按顺序查：

```powershell
# 1. 服务活着吗
bctl.ps1 bridge status

# 2. 篡改猴里有没有这个脚本
#    浏览器 → 篡改猴图标 → 管理面板 → 找 dsh-browser-bridge

# 3. 当前标签页是不是可见状态
#    注入只在 visibilityState === 'visible' 的标签页里生效

# 4. 手动触发一次
bctl.ps1 js "1+1"
```

| 现象 | 原因 | 处理 |
|---|---|---|
| `pending` 一直涨 | 没有标签页在轮询 | 脚本未安装，或页面是 `file://`（默认不匹配） |
| 装了但不轮询 | `@connect` 缺 `127.0.0.1` | 重装脚本（本仓库自带） |
| 有结果但 `value: undefined` | 代码是语句块且无 return | 用 `return ...`，或写成裸表达式 |
| 报 CORS | 用的是页面 `fetch` 而非 `GM_xmlhttpRequest` | 走 `__` 系列或 `GM_xmlhttpRequest` |

### 页面禁止 eval（CSP）

```
JS ERROR: this page's Content Security Policy blocks eval, so arbitrary JavaScript cannot run here.
```

userscript 的沙箱是页面的子 frame，会继承页面的 CSP。`script-src` 里没有 `unsafe-eval` 的站点
（github.com、Google 系、大多数银行和政府站）会直接抛 `EvalError`。

这不是坏掉，是设计好的降级：

```powershell
bctl.ps1 js --op title
bctl.ps1 js --op query --args '{"selector":"a","attr":"href"}'
bctl.ps1 js --op click --args '{"selector":".btn"}'
```

`--op` 那套是直接 DOM 调用，不经过 eval，任何 CSP 下都能跑。完整词表见
[`commands.md`](commands.md#js---op-op---args-json)。

判断一个站点能不能跑任意 JS：`bctl.ps1 js "1+1"`，返回 `2` 就没问题。

**服务起不来看这里**：`server.ps1` 用的是 `TcpListener`，不是 `HttpListener`，所以**不需要管理员权限，也不需要 `netsh http add urlacl`**。如果仍然起不来，检查端口占用：

```powershell
Get-NetTCPConnection -LocalPort 8737 -State Listen
```

换端口：`bctl.ps1 bridge start --port 8899`，同时改 userscript 里的 `PORT` 常量并重新安装。

---

## 六、篡改猴安装页卡在「This page is not intended to be viewed directly」

正常现象。**多等 1–3 秒**，安装对话框会浮出来（首次安装是「安装」按钮，覆盖安装是「更新」按钮）。

自动化点它：

```powershell
bctl.ps1 uia <pid> --pattern "安装|Install|更新"
bctl.ps1 clickel <pid> "安装" --type Button
bctl.ps1 clickel <pid> "更新" --type Button
```

装完之后**必须重新导航一次**页面，脚本才会注入到新文档。

---

## 七、性能与稳定性

- `uia` 全量导出大页面可能上万节点，用 `--type` 和 `--limit` 收窄
- 轮询间隔 400ms，`js` 默认超时 20s，长任务用 `--timeout 120`
- 单线程 TCP 服务足够用；要并发大量请求就先改成连接池或换 HTTP 框架

---

## 八、自检清单

出任何问题，先跑这三条，把输出贴出来就能定位：

```powershell
bctl.ps1 doctor
bctl.ps1 windows --all
bctl.ps1 uia <pid> --limit 20
```
