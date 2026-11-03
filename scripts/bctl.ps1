# bctl.ps1 - command line front-end for dsh-browser-bridge
# Drive an ALREADY RUNNING Edge/Chrome/Firefox window without restarting it.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File bctl.ps1 <command> [args]
#
# Run `bctl.ps1 help` for the command list.

[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ArgList
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$OutputEncoding = [System.Text.Encoding]::UTF8

. (Join-Path $PSScriptRoot 'BctlLib.ps1')

# ---------------------------------------------------------------- dispatcher
# 每条命令都是一个新的 powershell.exe：冷启动 ~800ms + 现场编译 C# ~265ms，
# 而真正干活只要 ~150ms。batch 模式把 dispatch 放回同一个进程里跑 N 次，
# 省掉 N-1 次启动开销（实测单命令 1250ms -> 73ms，17 倍）。
$script:BatchMode = $false
$script:flags = @{}
$script:pos = @()
$script:cmd = 'help'
$script:rest = @()
$script:isJson = $false
# 布尔开关的显式清单。解析器还额外把「下一个 token 本身就是 flag」当作布尔，
# 所以 --chrome --limit 120 不会再让 --chrome 把 --limit 吃掉。
$script:BoolFlags = @('json', 'all', 'double', 'triple', 'help', 'jpeg', 'keep-going', 'echo',
    'allow-close', 'force', 'chrome', 'new-tab', 'reopen', 'no-reuse', 'quiet')

function ConvertTo-AsciiJson {
    # --json 必须是 7-bit ASCII：调用方可能是别的进程、别的代码页，
    # 中文直接写进管道会在多字节边界被截断（实测 ConvertFrom-Json 直接报错）。
    param($Value)
    $json = ConvertTo-Json -InputObject $Value -Depth 8 -Compress
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $json.ToCharArray()) {
        if ([int]$ch -gt 127) { [void]$sb.AppendFormat('\u{0:x4}', [int]$ch) }
        else { [void]$sb.Append($ch) }
    }
    return $sb.ToString()
}

function Out-Result {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline = $true, Position = 0)]
        $Data
    )
    begin { $collected = New-Object System.Collections.ArrayList }
    process { if ($null -ne $Data) { $null = $collected.Add($Data) } }
    end {
        if ($collected.Count -eq 0) { return }
        $value = if ($collected.Count -eq 1) { $collected[0] } else { $collected.ToArray() }
        if ($isJson) {
            Write-Output (ConvertTo-AsciiJson $value)
            return
        }
        if ($value -is [string]) { Write-Output $value; return }
        if ($value -is [System.Collections.IEnumerable]) {
            Write-Output ($value | Format-Table -AutoSize | Out-String -Width 400)
            return
        }
        Write-Output ($value | Format-List | Out-String -Width 400)
    }
}

# Like Out-Result, but JSON output is always an array of rows so callers can
# iterate without special-casing the single-row case.
function Out-List {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline = $true, Position = 0)]
        $Data
    )
    begin { $collected = New-Object System.Collections.ArrayList }
    process { if ($null -ne $Data) { $null = $collected.Add($Data) } }
    end {
        # 空 ArrayList 的 ToArray() 会序列化成 {"value":[],"Count":0}，
        # 调用方解析会炸。@($collected) 保证空表就是真正的 []。
        $rows = @($collected)
        if ($isJson) {
            Write-Output (ConvertTo-AsciiJson $rows)
            return
        }
        if ($rows.Count -eq 0) { Write-Output '(empty)'; return }
        Write-Output ($rows | Format-Table -AutoSize | Out-String -Width 400)
    }
}

function Fail {
    param([string]$Message)
    # batch 模式下不能 exit：那会把整批步骤一起带走，只剩一个空输出。
    # 用异常让上层的 per-step try/catch 接住，后面的步骤（--keep-going）还能继续。
    if ($script:BatchMode) { throw [System.Exception]::new([string]$Message) }
    # 错误也要走 ASCII 转义：调用方读到的必须是纯 7-bit，否则中文/破折号会在管道里变乱码。
    if ($isJson) { Write-Output (ConvertTo-AsciiJson @{ ok = $false; error = $Message }) }
    else { Write-Host "ERR: $Message" }
    exit 1
}

function Normalize-BctlUrl {
    # 只做「无意义差异」的归一：大小写、末尾斜杠、file:// 前缀。
    # query 与 hash 必须保留 —— 旧实现把它们整个丢掉，于是
    #   /list?page=1 与 /list?page=2      -> 判为同一页，nav 静默不翻页
    #   /app#/inbox  与 /app#/settings    -> 判为同一页，SPA 路由永远打不开
    # 上层还会拿到 reused=true，以为导航成功，后续点击全落在错的页面上。
    param([string]$Url)
    if (-not $Url) { return '' }
    $u = $Url.Trim()
    # file:// 在地址栏里显示成 C:/... ，两边要比得了
    if ($u -match '^(?i)file:') {
        return (($u -replace '^(?i)file:/*', '').ToLower().TrimEnd('/'))
    }
    return $u.ToLower().TrimEnd('/')
}

function Get-BctlAddressBarValue {
    # 地址栏在窗口 chrome 里，不在页面子树内——这里必须用窗口根。
    param($Window)
    $root = Get-BctlUiaRoot -ProcessId $Window.pid
    if (-not $root) { return $null }
    $cond = New-Object System.Windows.Automation.PropertyCondition($script:AE::ControlTypeProperty, $script:CT::Edit)
    $edits = $root.FindAll($script:TS::Descendants, $cond)
    $target = $null
    foreach ($e in $edits) { if ($e.Current.Name -match '(?i)address|search|地址|搜索') { $target = $e; break } }
    if (-not $target) { foreach ($e in $edits) { if ($e.Current.BoundingRectangle.Y -lt 120) { $target = $e; break } } }
    if (-not $target) { return $null }
    try { return $target.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value } catch { return $null }
}

function Invoke-BctlEnsure {
    param([switch]$Reopen)
    $names = @('msedge', 'chrome', 'brave', 'vivaldi', 'opera', 'chromium', 'thorium', 'firefox', 'librewolf')
    $classes = @('Chrome_WidgetWin_1', 'MozillaWindowClass')
    $procs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $names -contains $_.ProcessName.ToLower() })
    if ($procs.Count -eq 0) {
        return [pscustomobject]@{ state = 'absent'; hint = 'no browser process. Ask the user to open one; this tool never launches a browser.' }
    }
    $rows = @()
    foreach ($w in (Get-BctlWindows -IncludeHidden)) {
        if ($w.w -lt 300 -or $w.h -lt 200) { continue }
        if ($classes -notcontains $w.className) { continue }
        $p = Get-Process -Id $w.pid -ErrorAction SilentlyContinue
        if (-not $p) { continue }
        if ($names -notcontains $p.ProcessName.ToLower()) { continue }
        $rows += $w
    }
    if ($rows.Count -eq 0) {
        # 这里刻意不提供「帮你打开一个」的能力。
        # 启动浏览器必然产生一个新窗口 + 一个新标签，破坏用户现场，
        # 而且会被上层误读成「浏览器状态异常，需要重启」。
        $hint = 'the browser process is alive but has no window. Ask the user to click the taskbar icon; this tool never launches a browser.'
        return [pscustomobject]@{ state = 'windowless'; processes = $procs.Count; hint = $hint }
    }
    $sort = @{ Expression = { [int64]$_.w * [int64]$_.h }; Descending = $true }
    $vis = @($rows | Where-Object { $_.visible })
    if ($vis.Count -gt 0) {
        $t = $vis | Sort-Object -Property $sort | Select-Object -First 1
        return [pscustomobject]@{ state = 'ok'; pid = $t.pid; handle = $t.handle; title = $t.title }
    }
    $t = $rows | Sort-Object -Property $sort | Select-Object -First 1
    # 只报告，不 ShowWindow。恢复隐藏窗口正是「浏览器自己又冒出来一个」的成因，
    # 而且 SW_SHOW 会把 Edge 关窗后残留的空壳窗口变成可见空窗口。
    return [pscustomobject]@{
        state = 'hidden'; restored = $false; pid = $t.pid; handle = $t.handle
        nowVisible = [BctlNative]::IsWindowVisible([IntPtr]$t.handle); title = $t.title
        hint = 'the window is hidden. Ask the user to restore it from the taskbar; this tool will not show it for you.'
    }
}

function Need-Pid {
    param([string]$Spec)
    if (-not $Spec) { Fail 'missing pid/window spec' }
    $w = Resolve-BctlWindow -Spec $Spec
    if (-not $w) { Fail "window not found: $Spec" }
    return $w
}

# ---------------------------------------------------------------- commands
# 分发入口：解析一条命令的参数，然后进 switch。单命令模式和 batch 模式
# 都走这里，区别只是调用次数（batch 在同一个进程里连调 N 次）。
function Invoke-BctlCli {
    param([string[]]$ArgList)

    $script:flags = @{}
    $script:pos = New-Object System.Collections.ArrayList
    $i = 0
    while ($i -lt $ArgList.Count) {
        $a = $ArgList[$i]
        if ($a -like '--*') {
            $k = $a.TrimStart('-')
            $next = if ($i + 1 -lt $ArgList.Count) { [string]$ArgList[$i + 1] } else { '' }
            # 判定布尔开关：白名单内，或下一个 token 自己也是 flag，或没有下一个 token。
            # 旧实现只认白名单，于是 --chrome 把 --limit 当成自己的值吞掉，
            # limit 静默失效，位置参数里还多出一个孤儿数字。
            if (($script:BoolFlags -contains $k) -or $next -eq '' -or $next -like '--*') {
                $script:flags[$k] = $true
            }
            else {
                $script:flags[$k] = $next
                $i++
            }
        }
        else { $null = $script:pos.Add($a) }
        $i++
    }

    $script:cmd = if ($script:pos.Count -gt 0) { $script:pos[0].ToLower() } else { 'help' }
    $script:rest = @()
    if ($script:pos.Count -gt 1) {
        for ($j = 1; $j -lt $script:pos.Count; $j++) { $script:rest += [string]$script:pos[$j] }
    }
    $script:isJson = [bool]$script:flags['json']

try {
    switch ($cmd) {

        'help' {
            @'
dsh-browser-bridge / bctl  -  drive an already-running browser, no restart

  doctor                              environment + capability self-check
  browsers                            list running browser processes
  windows [--all]                     list top-level windows
  active                              print the foreground window
  focus <pid|title>                   bring window to front
  move <x> <y>                        move cursor
  click <x> <y> [left|right|middle]   click (--double / --triple)
  drag <x1> <y1> <x2> <y2>            drag
  scroll <x> <y> <delta>              wheel, 120 = one notch, negative = down
  type <text> --pid <pid>             type text (unicode, bypasses IME). --pid is required:
                                      without a target the text lands in whatever app has focus
  key <combo> --pid <pid>             CTRL+L / ENTER / F5 / PAGE_DOWN. --pid is required for the same reason
  shot [file] [--region x,y,w,h]      capture virtual screen (--jpeg [--quality N] = far smaller file)
  shot --win <pid> [--file path]      capture one window
  at <x> <y> [--pid <pid>]            what element sits at that point (UIA ElementFromPoint)
  pixel <x> <y>                       RGB at one point — judge "did it turn blue" without an image
  url <pid>                           current URL from the address bar
  title <pid>                         current page title
  tabs <pid>                          list tabs
  tab <pid> <n>                       switch to tab n (1-based)
  newtab <pid> / closetab <pid>       open / close tab
  nav <pid> <url>                     address bar -> url -> enter
  uia <pid> [--type <T>] [--limit N] [--pattern <regex>]
                                      dump the accessibility tree
  find <pid> <regex>                  find elements by name regex
  text <pid> [--file out.txt]         extract the visible page text
  clickel <pid> <name> [--type <T>]   click an element by its accessible name
  invoke <pid> <name>                 invoke/select an element
  setvalue <pid> <name> <value>       set an input's value
  value <pid> <name>                  read an input's value
  wait <ms>                           sleep
  wait <pid> --title <re> | --url <re> | --text <re> [--timeout ms] [--poll ms]
                                      poll until true, return the moment it is (no guessing sleeps)
  clip get | clip set <text>          clipboard
  js <code> | --op <name> [--timeout s]
                                      run JS via the userscript bridge (default 8s, fails fast)
  bridge start|install|status|stop    local userscript bridge (install = open the install page)

  batch --file <plan.txt> [--keep-going] [--echo] [--json]
  batch --steps '["title 123","url 123"]'
                                      run many commands in ONE process and return one aggregated
                                      answer. Same commands, ~17x faster than one process per call.
                                      seq / pipeline are aliases.
  plan.txt: one command per line, '#' comments allowed, quotes group arguments.

Global flags: --json (machine readable output)
'@
        }

        'doctor' {
            Add-Type -AssemblyName System.Windows.Forms
            Add-Type -AssemblyName System.Drawing
            $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
            $dpi = $null
            try {
                $bmp = New-Object System.Drawing.Bitmap 1, 1
                $g = [System.Drawing.Graphics]::FromImage($bmp)
                $dpi = $g.DpiX
                $g.Dispose(); $bmp.Dispose()
            } catch { }
            $uiaOk = [bool]('System.Windows.Automation.AutomationElement' -as [type])
            $root = if ($uiaOk) { $script:AE::RootElement } else { $null }
            $browsers = @()
            foreach ($w in (Get-BctlWindows)) {
                $p = Get-Process -Id $w.pid -ErrorAction SilentlyContinue
                if ($p -and ($p.ProcessName -match 'chrome|msedge|brave|vivaldi|oper|firefox|chromium|Arc')) {
                    $uia = Get-BctlUiaRoot -ProcessId $w.pid
                    $browsers += [pscustomobject]@{
                        pid        = $w.pid
                        process    = $p.ProcessName
                        uiaVisible = [bool]$uia
                        title      = $w.title
                        rect       = "$($w.w)x$($w.h) @$($w.x),$($w.y)"
                    }
                }
            }
            [pscustomobject]@{
                version      = $script:BctlVersion
                powershell   = $PSVersionTable.PSVersion.ToString()
                os           = [System.Environment]::OSVersion.VersionString
                dpiAware     = $true
                screen       = "$($vs.Width)x$($vs.Height) @$($vs.X),$($vs.Y)"
                uiaLoaded    = $uiaOk
                uiaRootName  = if ($root) { $root.Current.Name } else { $null }
                browsers     = $browsers
                bridge       = 'optional: see bridge/server.ps1'
            } | Out-Result
        }

        'browsers' {
            # 只列真正的浏览器窗口：主机自己的 Electron / WebView 窗口一律不出现，
            # 上层工具因此不可能误操作宿主窗口。
            $fg = [BctlNative]::GetForegroundWindow()
            $rows = @()
            $seen = @{}
            foreach ($w in (Get-BctlWindows -IncludeHidden)) {
                $p = Get-Process -Id $w.pid -ErrorAction SilentlyContinue
                if (-not $p) { continue }
                if ($p.ProcessName -notmatch $script:BrowserProcessRegex) { continue }
                if ($w.w -lt 300 -or $w.h -lt 200) { continue }
                if ($seen.ContainsKey([string]$w.handle)) { continue }
                $seen[[string]$w.handle] = $true
                # 有 owner 的是弹窗/浮层（翻译条、书签弹窗等），不能当成主窗口
                $owner = [BctlNative]::GetWindow([IntPtr]$w.handle, 4)
                $rows += [pscustomobject]@{
                    pid     = $w.pid
                    handle  = $w.handle
                    process = $p.ProcessName
                    active  = ([int64]$fg -eq [int64]$w.handle)
                    hidden  = (-not $w.visible)
                    dialog  = ($owner -ne [IntPtr]::Zero)
                    w       = $w.w
                    h       = $w.h
                    title   = $w.title
                }
            }
            # 主窗口排前面：非弹窗 → 可见 → 前台 → 面积大。
            # 「可见」必须参与排序：隐藏的是关窗后残留的空壳窗口，
            # 把它当默认目标会让后续 SetForeground 去激活一个不存在的窗口。
            $rows = @($rows | Sort-Object -Property @{ Expression = { [int]$_.dialog } },
                @{ Expression = { [int]$_.hidden } },
                @{ Expression = { [int](-not $_.active) } },
                @{ Expression = { [int64]$_.w * [int64]$_.h }; Descending = $true })
            if ($rows.Count -eq 0) {
                # 进程在、窗口没有：这是「关掉窗口但后台常驻」的状态。
                # 这时重开浏览器只会多出一个新窗口/新标签，必须阻止。
                $procs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match $script:BrowserProcessRegex })
                if ($procs.Count -gt 0) {
                    $names = ($procs | Select-Object -ExpandProperty ProcessName -Unique) -join ', '
                    Fail ("$names is running in the background but has no window. Ask the user to restore it from the taskbar (or run: bctl.ps1 wake). Do not launch a new browser: that opens an extra window and a new tab instead of using the session the user already has.")
                }
                Fail 'no browser is running. Ask the user to open Edge or Chrome.'
            }
            $rows | Out-List
        }

        'windows' {
            $all = Get-BctlWindows
            if (-not $flags['all']) { $all = $all | Where-Object { $_.w -gt 200 -and $_.h -gt 100 } }
            $all | Sort-Object pid | Select-Object pid, handle, className, x, y, w, h, title | Out-List
        }

        'ensure' {
            $r = Invoke-BctlEnsure -Reopen:([bool]$flags['reopen'])
            Write-BctlAudit 'ensure' @{ state = $r.state }
            Out-Result $r
        }

        'wake' {
            $r = Invoke-BctlEnsure
            Out-Result $r
        }

        'audit' {
            $sub = if ($rest.Count -ge 1) { $rest[0] } else { 'tail' }
            if ($sub -ne 'tail') { Fail 'usage: audit tail [n]' }
            $n = if ($rest.Count -ge 2) { [int]$rest[1] } else { 20 }
            $file = Join-Path (Join-Path $env:USERPROFILE '.dsh\browser-bridge') 'audit.log'
            if (-not (Test-Path $file)) { Out-Result @(); break }
            $lines = @(Get-Content -Path $file -Tail $n -Encoding UTF8)
            if ($isJson) { $lines | Out-List }
            else { foreach ($l in $lines) { Write-Output $l } }
        }

        'active' {
            $h = [BctlNative]::GetForegroundWindow()
            $sb = New-Object System.Text.StringBuilder 1024
            [void][BctlNative]::GetWindowTextW($h, $sb, 1024)
            $wpid = [uint32]0
            [void][BctlNative]::GetWindowThreadProcessId($h, [ref]$wpid)
            Out-Result ([pscustomobject]@{ handle = [int64]$h; pid = $wpid; title = $sb.ToString() })
        }

        'focus' {
            $w = Need-Pid $rest[0]
            $raised = Set-BctlForeground -Window $w
            Write-BctlAudit 'focus' @{ pid = $w.pid; raised = $raised }
            if (-not $raised) {
                Fail ("could not bring pid=" + $w.pid + " to the front. The window may be hidden, or Windows refused the change. Nothing else was done.")
            }
            Out-Result ([pscustomobject]@{ ok = $true; pid = $w.pid; title = $w.title })
        }

        'move' {
            if ($rest.Count -lt 2) { Fail 'usage: move <x> <y>' }
            [void][BctlNative]::SetCursorPos([int]$rest[0], [int]$rest[1])
            $p = New-Object BctlNative+POINT
            [void][BctlNative]::GetCursorPos([ref]$p)
            Out-Result ([pscustomobject]@{ ok = $true; x = $p.X; y = $p.Y })
        }

        'click' {
            if ($rest.Count -lt 2) { Fail 'usage: click <x> <y> [button]' }
            $btn = if ($rest.Count -ge 3) { $rest[2] } else { 'left' }
            $count = if ($flags['triple']) { 3 } elseif ($flags['double']) { 2 } else { 1 }
            Invoke-BctlClick -X ([int]$rest[0]) -Y ([int]$rest[1]) -Button $btn -Count $count
            Out-Result ([pscustomobject]@{ ok = $true; x = [int]$rest[0]; y = [int]$rest[1]; button = $btn; count = $count })
        }

        'drag' {
            if ($rest.Count -lt 4) { Fail 'usage: drag <x1> <y1> <x2> <y2>' }
            Invoke-BctlDrag -X1 ([int]$rest[0]) -Y1 ([int]$rest[1]) -X2 ([int]$rest[2]) -Y2 ([int]$rest[3])
            Out-Result ([pscustomobject]@{ ok = $true })
        }

        'scroll' {
            if ($rest.Count -lt 3) { Fail 'usage: scroll <x> <y> <delta>' }
            [void][BctlNative]::SetCursorPos([int]$rest[0], [int]$rest[1])
            Start-Sleep -Milliseconds 100
            [BctlNative]::Wheel([int]$rest[2])
            Out-Result ([pscustomobject]@{ ok = $true; x = [int]$rest[0]; y = [int]$rest[1]; delta = [int]$rest[2] })
        }

        'type' {
            $text = $null
            if ($flags['file']) { $text = [System.IO.File]::ReadAllText($flags['file'], [System.Text.Encoding]::UTF8) }
            elseif ($rest.Count -ge 1) { $text = ($rest -join ' ') }
            if (-not $text) { Fail 'usage: type <text> --pid <pid|pid:handle>' }
            # 打字必须有目标：SendInput 是全局的，没有目标就会插进用户当前所在的任意窗口
            if (-not $flags['pid']) {
                Fail 'refusing to type without --pid: the text would land in whatever app the user has focused. Pass --pid <pid|pid:handle>.'
            }
            $w = Need-Pid $flags['pid']
            if (-not (Set-BctlForeground -Window $w)) {
                Fail ("could not bring the target browser window to the front (pid=" + $w.pid + "). Nothing was typed.")
            }
            Invoke-BctlType -Text $text -GuardHandle ([int64]$w.handle) -GuardPid ([uint32]$w.pid)
            Write-BctlAudit 'type' @{ pid = $w.pid; chars = $text.Length }
            Out-Result ([pscustomobject]@{ ok = $true; chars = $text.Length })
        }

        'key' {
            if ($rest.Count -lt 1) { Fail 'usage: key <combo> --pid <pid|pid:handle> [--allow-close]' }
            $combo = (($rest -join '+').ToUpper()) -replace '\s', ''
            $closeCombos = @('CTRL+W', 'CTRL+F4', 'ALT+F4', 'CTRL+SHIFT+W', 'CTRL+Q')
            if (($closeCombos -contains $combo) -and -not $flags['allow-close']) {
                Write-BctlAudit 'key-refused' @{ combo = $combo }
                Fail ("'" + $combo + "' closes a tab or the window, so nothing was sent. Closing the last window leaves the browser running with no UI, which is exactly the vanished-browser state. Pass --allow-close only when ending the window is really the goal.")
            }
            # 同上：没有目标窗口就不发键，否则快捷键会落到用户正在用的软件上
            if (-not $flags['pid']) {
                Fail 'refusing to send keys without --pid: they would land in whatever app the user has focused. Pass --pid <pid|pid:handle>.'
            }
            $w = Need-Pid $flags['pid']
            if (-not (Set-BctlForeground -Window $w)) {
                Fail ("could not bring the target browser window to the front (pid=" + $w.pid + "). No keys were sent.")
            }
            Invoke-BctlKey -Combo $combo -GuardHandle ([int64]$w.handle) -GuardPid ([uint32]$w.pid)
            Write-BctlAudit 'key' @{ combo = $combo; pid = $w.pid }
            Out-Result ([pscustomobject]@{ ok = $true; combo = $combo })
        }

        'shot' {
            $file = if ($rest.Count -ge 1) { $rest[0] } elseif ($flags['file']) { $flags['file'] } else { Join-Path (Get-Location) 'shot.png' }
            $useJpeg = [bool]($flags['jpeg'] -or ($flags['quality']))
            $quality = if ($flags['quality']) { [int]$flags['quality'] } else { 80 }
            if ($flags['win']) {
                $w = Need-Pid $flags['win']
                Get-BctlScreenshot -Path $file -X $w.x -Y $w.y -W $w.w -H $w.h -Jpeg:$useJpeg -Quality $quality | Out-Null
            }
            elseif ($flags['region']) {
                $r = $flags['region'] -split ','
                Get-BctlScreenshot -Path $file -X ([int]$r[0]) -Y ([int]$r[1]) -W ([int]$r[2]) -H ([int]$r[3]) -Jpeg:$useJpeg -Quality $quality | Out-Null
            }
            else {
                Get-BctlScreenshot -Path $file -Jpeg:$useJpeg -Quality $quality | Out-Null
            }
            $info = Get-Item $file
            Out-Result ([pscustomobject]@{ ok = $true; file = $info.FullName; bytes = $info.Length })
        }

        'at' {
            # 坐标 -> 元素。点击之前先证明这个点落在谁身上，比点完再截图猜便宜得多。
            if ($rest.Count -lt 2) { Fail 'usage: at <x> <y> [--pid <pid>] [--depth N]' }
            $x = [int]$rest[0]
            $y = [int]$rest[1]
            $depth = if ($flags['depth']) { [int]$flags['depth'] } else { 3 }
            $pageRoot = $null
            if ($flags['pid']) {
                $w = Need-Pid $flags['pid']
                $pageRoot = Get-BctlPageRoot -ProcessId $w.pid
            }
            $chain = @(Get-BctlElementAt -X $x -Y $y -Depth $depth -PageRoot $pageRoot)
            if ($chain.Count -eq 0) { Fail "nothing at $x,$y — no UI Automation element reports that point" }
            if ($isJson) { $chain | Out-List }
            else {
                Write-Host ("hit=" + $chain[0].type + ' "' + $chain[0].name + '"')
                $chain | Select-Object type, name, rect, inPage | Format-Table -AutoSize | Out-String -Width 400
            }
        }

        'pixel' {
            # 一个像素就能判「按钮变蓝了吗」。整屏截图 3MB 是为了看布局，不是为了判状态。
            if ($rest.Count -lt 2) { Fail 'usage: pixel <x> <y>' }
            Out-Result (Get-BctlPixel -X ([int]$rest[0]) -Y ([int]$rest[1]))
        }

        'url' {
            $w = Need-Pid $rest[0]
            $root = Get-BctlUiaRoot -ProcessId $w.pid
            if (-not $root) { Fail 'UI Automation cannot see this window' }
            $cond = New-Object System.Windows.Automation.PropertyCondition($script:AE::ControlTypeProperty, $script:CT::Edit)
            $edits = $root.FindAll($script:TS::Descendants, $cond)
            $target = $null
            foreach ($e in $edits) {
                $c = $e.Current
                if ($c.Name -match '(?i)address|search|地址|搜索') { $target = $e; break }
            }
            if (-not $target) {
                foreach ($e in $edits) { if ($e.Current.BoundingRectangle.Y -lt 120) { $target = $e; break } }
            }
            if (-not $target) { Fail 'address bar not found' }
            try {
                $vp = $target.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
                Out-Result ([pscustomobject]@{ ok = $true; url = $vp.Current.Value })
            }
            catch { Fail 'address bar does not expose ValuePattern' }
        }

        'title' {
            $w = Need-Pid $rest[0]
            $doc = Get-BctlDocument -ProcessId $w.pid
            if ($doc) { Out-Result ([pscustomobject]@{ ok = $true; title = $doc.Current.Name }) }
            else { Out-Result ([pscustomobject]@{ ok = $true; title = $w.title }) }
        }

        'tabs' {
            $w = Need-Pid $rest[0]
            # 标签页在窗口 chrome 里，不在 Document 子树内——必须用 window 作用域，
            # 否则永远返回空列表（v1.3.0 的回归：page 作用域看不到 TabItem）。
            $items = Find-BctlElements -ProcessId $w.pid -Pattern '' -Type 'TabItem' -Limit 100 -Scope 'window'
            $rows = @()
            $n = 0
            foreach ($e in $items) {
                $n++
                $info = Get-BctlElementInfo -Element $e
                $sel = $false
                try {
                    $sp = $e.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
                    $sel = $sp.Current.IsSelected
                }
                catch { }
                $rows += [pscustomobject]@{ index = $n; selected = $sel; name = $info.name; rect = $info.rect }
            }
            $rows | Out-List
        }

        'tab' {
            if ($rest.Count -lt 2) { Fail 'usage: tab <pid> <n>' }
            $w = Need-Pid $rest[0]
            $n = [int]$rest[1]
            if ($n -lt 1 -or $n -gt 9) { Fail 'tab index must be 1..9 (use tabs to enumerate)' }
            if (-not (Set-BctlForeground -Window $w)) { Fail ("could not bring the target window to the front (pid=" + $w.pid + "). Nothing was switched.") }
            Invoke-BctlKey -Combo "CTRL+$n" -GuardHandle ([int64]$w.handle) -GuardPid ([uint32]$w.pid)
            Out-Result ([pscustomobject]@{ ok = $true; tab = $n })
        }

        'newtab' {
            $w = Need-Pid $rest[0]
            if (-not (Set-BctlForeground -Window $w)) { Fail ("could not bring the target window to the front (pid=" + $w.pid + "). Nothing was opened.") }
            Invoke-BctlKey -Combo 'CTRL+T' -GuardHandle ([int64]$w.handle) -GuardPid ([uint32]$w.pid)
            Write-BctlAudit 'newtab' @{ pid = $w.pid }
            Out-Result ([pscustomobject]@{ ok = $true })
        }

        'closetab' {
            # 这个命令以前直接发 CTRL+W，绕过了 key 分支的关闭拦截，也不写审计。
            # 现在与 key 同一套门槛：默认拒绝，需要 --allow-close。
            if (-not $flags['allow-close']) {
                Write-BctlAudit 'closetab-refused' @{ pid = $rest[0] }
                Fail 'closetab closes a tab, so nothing was sent. Closing the last tab leaves the browser running with no window. Pass --allow-close only when ending it is really the goal.'
            }
            $w = Need-Pid $rest[0]
            if (-not (Set-BctlForeground -Window $w)) { Fail ("could not bring the target window to the front (pid=" + $w.pid + "). Nothing was closed.") }
            Invoke-BctlKey -Combo 'CTRL+W' -GuardHandle ([int64]$w.handle) -GuardPid ([uint32]$w.pid)
            Write-BctlAudit 'closetab' @{ pid = $w.pid }
            Out-Result ([pscustomobject]@{ ok = $true })
        }

        'nav' {
            if ($rest.Count -lt 2) { Fail 'usage: nav <pid> <url> [--new-tab]' }
            $w = Need-Pid $rest[0]
            $url = $rest[1]
            $target = Normalize-BctlUrl $url

            # 默认复用：先看当前标签页是不是已经在目标地址，再看其它标签页的标题。
            # 只有都不是才真正导航——避免「反复打开」。
            if (-not $flags['new-tab']) {
                $cur = Get-BctlAddressBarValue -Window $w
                if ($cur -and (Normalize-BctlUrl $cur) -eq $target) {
                    Write-BctlAudit 'nav' @{ pid = $w.pid; url = $url; reused = 'current-tab' }
                    Out-Result ([pscustomobject]@{ ok = $true; reused = $true; reason = 'already-open'; url = $cur })
                    break
                }

                $tabs = @()
                $items = Find-BctlElements -ProcessId $w.pid -Pattern '' -Type 'TabItem' -Limit 100 -Scope 'window'
                $n = 0
                foreach ($e in $items) {
                    $n++
                    $sel = $false
                    try { $sel = $e.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Current.IsSelected } catch { }
                    $tabs += [pscustomobject]@{ index = $n; selected = $sel; name = $e.Current.Name }
                }
                $origIndex = ($tabs | Where-Object { $_.selected } | Select-Object -First 1).index

                $label = $null
                try {
                    $hostPart = (($url -split '//')[1] -split '/')[0]
                    $hostPart = $hostPart -replace '^(www|m)\.', ''
                    $label = ($hostPart -split '\.')[0]
                }
                catch { $label = $null }

                $hit = $null
                if ($label -and $label.Length -ge 2) {
                    foreach ($t in ($tabs | Where-Object { -not $_.selected })) {
                        # CTRL+n 只到 9。以前对第 10 个标签会拼出 CTRL+10，
                        # Invoke-BctlKey 直接抛 unknown key，整条 nav 于是失败。
                        if ($t.index -lt 1 -or $t.index -gt 9) { continue }
                        if ($t.name -notmatch [regex]::Escape($label)) { continue }
                        if (-not (Set-BctlForeground -Window $w)) { break }
                        Invoke-BctlKey -Combo ("CTRL+" + $t.index) -GuardHandle ([int64]$w.handle) -GuardPid ([uint32]$w.pid)
                        Start-Sleep -Milliseconds 400
                        $u2 = Get-BctlAddressBarValue -Window $w
                        if ($u2 -and (Normalize-BctlUrl $u2) -eq $target) { $hit = $t; break }
                    }
                }
                if ($hit) {
                    Write-BctlAudit 'nav' @{ pid = $w.pid; url = $url; reused = ("tab " + $hit.index) }
                    Out-Result ([pscustomobject]@{ ok = $true; reused = $true; reason = 'existing-tab'; tab = $hit.index; title = $hit.name })
                    break
                }
                if ($origIndex -and $origIndex -le 9) {
                    [void](Set-BctlForeground -Window $w)
                    Invoke-BctlKey -Combo ("CTRL+" + $origIndex) -GuardHandle ([int64]$w.handle) -GuardPid ([uint32]$w.pid)
                    Start-Sleep -Milliseconds 300
                }
            }

            $before = Get-BctlWindowState -Handle $w.handle
            # 前台必须切成功。切不过去还继续敲 CTRL+L 和 URL，这些按键就会
            # 打进用户当前的任意窗口里——这正是「输入跑到别的软件」的成因。
            if (-not (Set-BctlForeground -Window $w)) {
                Fail ("could not bring the target browser window to the front (pid=" + $w.pid + "). Nothing was navigated: the address-bar keystrokes would have gone to another app.")
            }
            $gh = [int64]$w.handle
            $gp = [uint32]$w.pid
            Invoke-BctlKey -Combo 'CTRL+L' -GuardHandle $gh -GuardPid $gp
            Start-Sleep -Milliseconds 150
            Invoke-BctlKey -Combo 'CTRL+A' -GuardHandle $gh -GuardPid $gp
            Invoke-BctlType -Text $url -GuardHandle $gh -GuardPid $gp
            Start-Sleep -Milliseconds 120
            Invoke-BctlKey -Combo 'ENTER' -GuardHandle $gh -GuardPid $gp
            Start-Sleep -Milliseconds 1200
            $after = Get-BctlWindowState -Handle $w.handle
            if (-not $after.visible) {
                # Edge 会重建顶层窗口，句柄失效并不等于浏览器没了。重新解析一次再判。
                $w2 = Resolve-BctlWindow -Spec ([string]$w.pid)
                if ($w2) { $after = Get-BctlWindowState -Handle $w2.handle; $w = $w2 }
            }
            Write-BctlAudit 'nav' @{ pid = $w.pid; url = $url; reused = 'no'; before = $before; after = $after }
            if (-not $after.visible) {
                Fail 'the browser window disappeared during navigation. Run: bctl.ps1 ensure to see whether the process still has a window.'
            }
            $title = ''
            try { $doc = Get-BctlDocument -ProcessId $w.pid; if ($doc) { $title = $doc.Current.Name } } catch { }
            Out-Result ([pscustomobject]@{ ok = $true; reused = $false; url = $url; title = $title })
        }

        'uia' {
            $w = Need-Pid $rest[0]
            # 默认只看网页子树：标题栏的最小化/还原/关闭按钮不在里面，
            # 这样上层连「看到」这些名字的机会都没有。
            $root = if ($flags['chrome']) { Get-BctlUiaRoot -ProcessId $w.pid } else { Get-BctlPageRoot -ProcessId $w.pid }
            if (-not $root) {
                if ($flags['chrome']) { Fail 'UI Automation cannot see this window' }
                Fail 'the page is not exposed yet (still loading?). Wait a moment and retry; pass --chrome only when you really need window buttons.'
            }
            $cond = [System.Windows.Automation.Condition]::TrueCondition
            if ($flags['type']) {
                $ct = $script:CT::($flags['type'])
                if ($ct) { $cond = New-Object System.Windows.Automation.PropertyCondition($script:AE::ControlTypeProperty, $ct) }
            }
            $all = $root.FindAll($script:TS::Descendants, $cond)
            $limit = if ($flags['limit']) { [int]$flags['limit'] } else { 300 }
            $pattern = if ($flags['pattern']) { $flags['pattern'] } else { '' }
            $rows = @()
            foreach ($e in $all) {
                $info = Get-BctlElementInfo -Element $e
                if ($pattern -eq '' -or $info.name -match $pattern) {
                    $rows += $info
                    if ($rows.Count -ge $limit) { break }
                }
            }
            if ($isJson) { $rows | Out-List }
            else {
                Write-Host ("total=" + $all.Count + " shown=" + $rows.Count)
                $rows | Select-Object type, name, rect, cx, cy | Format-Table -AutoSize | Out-String -Width 400
            }
        }

        'find' {
            if ($rest.Count -lt 2) { Fail 'usage: find <pid> <regex>' }
            $w = Need-Pid $rest[0]
            $type = if ($flags['type']) { $flags['type'] } else { '' }
            $scope = if ($flags['chrome']) { 'window' } else { 'page' }
            $els = Find-BctlElements -ProcessId $w.pid -Pattern $rest[1] -Type $type -Scope $scope
            $rows = @()
            foreach ($e in $els) { $rows += (Get-BctlElementInfo -Element $e) }
            if ($rows.Count -eq 0) { Fail "no element matched: $($rest[1])" }
            if ($isJson) { $rows | Out-List }
            else { $rows | Select-Object type, name, rect, cx, cy | Format-Table -AutoSize | Out-String -Width 400 }
        }

        'clickel' {
            if ($rest.Count -lt 2) { Fail 'usage: clickel <pid> <name> [--chrome] [--force]' }
            $w = Need-Pid $rest[0]
            $type = if ($flags['type']) { $flags['type'] } else { '' }
            $scope = if ($flags['chrome']) { 'window' } else { 'page' }
            $pageRoot = Get-BctlPageRoot -ProcessId $w.pid

            $el = Find-BctlElement -ProcessId $w.pid -Name $rest[1] -Type $type -Scope $scope
            if (-not $el) {
                $cands = Find-BctlElements -ProcessId $w.pid -Pattern ([regex]::Escape($rest[1])) -Type $type -Scope $scope
                if ($cands.Count -gt 0) { $el = $cands[0] }
            }
            if (-not $el) { Fail "element not found in the page: $($rest[1])" }

            # 最后一道闸：元素必须真的在网页子树里，否则就是在动浏览器自己的窗口按钮
            if ($scope -eq 'page' -and -not (Test-BctlInPageTree -Element $el -PageRoot $pageRoot)) {
                Write-BctlAudit 'clickel-refused' @{ pid = $w.pid; name = $rest[1]; reason = 'outside-page-tree' }
                Fail ("'" + $rest[1] + "' matched a browser window control, not page content, so the click was refused. Nothing was clicked. Browser chrome is never a valid target: closing it ends the session you are working in.")
            }
            if ($scope -eq 'window' -and (Test-BctlDangerName -Name $rest[1]) -and -not $flags['force']) {
                Write-BctlAudit 'clickel-refused' @{ pid = $w.pid; name = $rest[1]; reason = 'danger-window-button' }
                Fail ("'" + $rest[1] + "' is a window button (close/minimize). Refused. Add --force only if you really mean to end the browser window.")
            }

            $info = Get-BctlElementInfo -Element $el
            if ($info.cx -lt 0 -or $info.cy -lt 0) {
                Fail ("the element '" + $info.name + "' reports no on-screen coordinates (offscreen), so there is nothing to click.")
            }
            $before = Get-BctlWindowState -Handle $w.handle
            # 点击是绝对坐标：窗口不在前台时，落在那个坐标上的是别的窗口
            if (-not (Set-BctlForeground -Window $w)) {
                Fail ("could not bring the target browser window to the front (pid=" + $w.pid + "). Nothing was clicked.")
            }
            Invoke-BctlClick -X $info.cx -Y $info.cy
            $after = Get-BctlWindowState -Handle $w.handle
            Write-BctlAudit 'clickel' @{ pid = $w.pid; name = $info.name; x = $info.cx; y = $info.cy; before = $before; after = $after }
            if (-not $after.visible) {
                Fail 'the browser window disappeared right after this click. Run: bctl.ps1 ensure'
            }
            Out-Result ([pscustomobject]@{ ok = $true; clicked = $info.name; type = $info.type; x = $info.cx; y = $info.cy })
        }

        'invoke' {
            if ($rest.Count -lt 2) { Fail 'usage: invoke <pid> <name>' }
            $w = Need-Pid $rest[0]
            $scope = if ($flags['chrome']) { 'window' } else { 'page' }
            $el = Find-BctlElement -ProcessId $w.pid -Name $rest[1] -Scope $scope
            if (-not $el) { Fail "element not found in the page: $($rest[1])" }
            $done = $false
            try {
                $pat = $el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
                $pat.Invoke()
                $done = $true
            }
            catch { }
            if (-not $done) {
                try {
                    $pat = $el.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
                    $pat.Select()
                    $done = $true
                }
                catch { }
            }
            if (-not $done) {
                try {
                    $pat = $el.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
                    $pat.Toggle()
                    $done = $true
                }
                catch { }
            }
            if (-not $done) { Fail 'element exposes no invokable pattern; use clickel instead' }
            Out-Result ([pscustomobject]@{ ok = $true; invoked = $rest[1] })
        }

        'setvalue' {
            if ($rest.Count -lt 3) { Fail 'usage: setvalue <pid> <name> <value>' }
            $w = Need-Pid $rest[0]
            $scope = if ($flags['chrome']) { 'window' } else { 'page' }
            $el = Find-BctlElement -ProcessId $w.pid -Name $rest[1] -Scope $scope
            if (-not $el) { Fail "element not found in the page: $($rest[1])" }
            $val = ($rest[2..($rest.Count - 1)] -join ' ')
            try {
                $vp = $el.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
                $vp.SetValue($val)
            }
            catch { Fail 'element does not support ValuePattern' }
            Out-Result ([pscustomobject]@{ ok = $true; name = $rest[1]; value = $val })
        }

        'value' {
            if ($rest.Count -lt 2) { Fail 'usage: value <pid> <name>' }
            $w = Need-Pid $rest[0]
            $scope = if ($flags['chrome']) { 'window' } else { 'page' }
            $el = Find-BctlElement -ProcessId $w.pid -Name $rest[1] -Scope $scope
            if (-not $el) { Fail "element not found in the page: $($rest[1])" }
            try {
                $vp = $el.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
                Out-Result ([pscustomobject]@{ ok = $true; name = $rest[1]; value = $vp.Current.Value })
            }
            catch { Fail 'element does not support ValuePattern' }
        }

        'text' {
            $w = Need-Pid $rest[0]
            $doc = Get-BctlDocument -ProcessId $w.pid
            if (-not $doc) { Fail 'no Document node found (page still loading?)' }
            $tp = $doc.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern)
            $txt = $tp.DocumentRange.GetText(-1)
            $cut = $false
            if ($txt.Length -gt $script:MaxTextChars) {
                $txt = $txt.Substring(0, $script:MaxTextChars)
                $cut = $true
            }
            if ($isJson) {
                # 只在显式给了 --file 时落盘，避免每次读取都产生文件
                $saved = $null
                if ($flags['file']) {
                    [System.IO.File]::WriteAllText($flags['file'], $txt, (New-Object System.Text.UTF8Encoding($false)))
                    $saved = (Resolve-Path $flags['file']).Path
                }
                Out-Result ([pscustomobject]@{ ok = $true; chars = $txt.Length; truncated = $cut; file = $saved; text = $txt })
                break
            }
            $file = if ($flags['file']) { $flags['file'] } else { Join-Path (Get-Location) 'page.txt' }
            [System.IO.File]::WriteAllText($file, $txt, (New-Object System.Text.UTF8Encoding($false)))
            Write-Host ("chars=" + $txt.Length + " -> " + (Resolve-Path $file).Path)
            $preview = if ($txt.Length -gt 1200) { $txt.Substring(0, 1200) } else { $txt }
            Write-Host '--- preview ---'
            Write-Host $preview
        }

        'wait' {
            # 两种用法：wait <ms> 是老的固定睡眠；给了 --title/--url/--text 就变成
            # 条件轮询——命中即返回，不再靠猜「页面到底加载完了没有」。
            $hasPredicate = $flags['title'] -or $flags['url'] -or $flags['text']
            if (-not $hasPredicate) {
                $ms = if ($rest.Count -ge 1) { [int]$rest[0] } else { 500 }
                Start-Sleep -Milliseconds $ms
                Out-Result ([pscustomobject]@{ ok = $true; waited = $ms })
                break
            }
            if ($rest.Count -lt 1) { Fail 'usage: wait <pid> --title <regex> | --url <regex> | --text <regex> [--timeout ms] [--poll ms]' }
            $w = Need-Pid $rest[0]
            $timeout = if ($flags['timeout']) { [int]$flags['timeout'] } else { 10000 }
            $poll = if ($flags['poll']) { [int]$flags['poll'] } else { 150 }
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $seen = ''
            $matched = $false
            $tries = 0
            while ($sw.ElapsedMilliseconds -lt $timeout) {
                $tries++
                if ($flags['title']) {
                    try { $doc = Get-BctlDocument -ProcessId $w.pid; if ($doc) { $seen = [string]$doc.Current.Name } } catch { }
                    if ($seen -match $flags['title']) { $matched = $true }
                }
                elseif ($flags['url']) {
                    $seen = [string](Get-BctlAddressBarValue -Window $w)
                    if ($seen -match $flags['url']) { $matched = $true }
                }
                else {
                    $hit = @(Find-BctlElements -ProcessId $w.pid -Pattern $flags['text'] -Limit 1)
                    $seen = if ($hit.Count -gt 0) { [string]$hit[0].Current.Name } else { '' }
                    if ($hit.Count -gt 0) { $matched = $true }
                }
                if ($matched) { break }
                Start-Sleep -Milliseconds $poll
            }
            $out = [pscustomobject]@{
                ok = $matched; matched = $matched; elapsedMs = [int]$sw.ElapsedMilliseconds
                tries = $tries; seen = ($seen -replace '\s+', ' ')
            }
            if (-not $matched) {
                $out | Add-Member -NotePropertyName error -NotePropertyValue ("condition not met within {0}ms" -f $timeout)
                $out | Add-Member -NotePropertyName hint -NotePropertyValue 'the page may still be loading, or this predicate never becomes true on that page'
            }
            Out-Result $out
        }

        'clip' {
            $sub = if ($rest.Count -ge 1) { $rest[0] } else { 'get' }
            if ($sub -eq 'set') {
                $val = ($rest[1..($rest.Count - 1)] -join ' ')
                Set-Clipboard -Value $val
                Out-Result ([pscustomobject]@{ ok = $true; chars = $val.Length })
            }
            else {
                $val = Get-Clipboard -Raw
                Out-Result ([pscustomobject]@{ ok = $true; text = $val })
            }
        }

        'bridge' {
            $sub = if ($rest.Count -ge 1) { $rest[0] } else { 'status' }
            $port = if ($flags['port']) { [int]$flags['port'] } else { 8737 }
            $base = "http://127.0.0.1:$port"
            switch ($sub) {
                'start' {
                    $ping = $null
                    try { $ping = Invoke-RestMethod -Uri "$base/ping" -TimeoutSec 2 } catch { }
                    if ($ping) { Out-Result ([pscustomobject]@{ ok = $true; already = $true; port = $port }); break }
                    $server = Join-Path (Split-Path -Parent $PSScriptRoot) 'bridge\server.ps1'
                    if (-not (Test-Path $server)) { Fail "server.ps1 not found at $server" }
                    $argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$server`" -Port $port -Quiet"
                    Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList $argLine | Out-Null
                    $ok = $false
                    for ($k = 0; $k -lt 25; $k++) {
                        Start-Sleep -Milliseconds 200
                        try { $null = Invoke-RestMethod -Uri "$base/ping" -TimeoutSec 1; $ok = $true; break } catch { }
                    }
                    if (-not $ok) { Fail "server did not come up on port $port" }
                    Out-Result ([pscustomobject]@{ ok = $true; port = $port; url = $base })
                }
                'install' {
                    # 一条命令串完「起服务 + 打开用户脚本安装页」。脚本没装时，
                    # 上层只能干等到超时——先把装的位置递到眼前再说别的。
                    $running = $false
                    try { $null = Invoke-RestMethod -Uri "$base/ping" -TimeoutSec 2; $running = $true } catch { }
                    if (-not $running) {
                        $server = Join-Path (Split-Path -Parent $PSScriptRoot) 'bridge\server.ps1'
                        if (-not (Test-Path $server)) { Fail "server.ps1 not found at $server" }
                        $argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$server`" -Port $port -Quiet"
                        Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList $argLine | Out-Null
                        for ($k = 0; $k -lt 25; $k++) {
                            Start-Sleep -Milliseconds 200
                            try { $null = Invoke-RestMethod -Uri "$base/ping" -TimeoutSec 1; $running = $true; break } catch { }
                        }
                        if (-not $running) { Fail "server did not come up on port $port" }
                    }
                    $url = "$base/install.user.js"
                    Start-Process $url | Out-Null
                    Out-Result ([pscustomobject]@{
                            ok = $true; opened = $url; server = $running
                            hint = 'click 安装 in the userscript prompt, then reload the page. The bridge only runs on the visible tab.'
                        })
                }
                'status' {
                    try { $p = Invoke-RestMethod -Uri "$base/ping" -TimeoutSec 2 } catch { $p = $null }
                    if (-not $p) { Out-Result ([pscustomobject]@{ running = $false; port = $port }); break }
                    $s = $null
                    try { $s = Invoke-RestMethod -Uri "$base/stats" -TimeoutSec 2 } catch { }
                    Out-Result ([pscustomobject]@{ running = $true; port = $port; stats = $s })
                }
                'stop' {
                    $conn = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
                    if (-not $conn) { Out-Result ([pscustomobject]@{ ok = $true; running = $false }); break }
                    Stop-Process -Id $conn.OwningProcess -Force -ErrorAction SilentlyContinue
                    Out-Result ([pscustomobject]@{ ok = $true; killed = $conn.OwningProcess })
                }
                default { Fail "usage: bridge start|install|status|stop [--port N]" }
            }
        }

        'js' {
            $code = $null
            if ($flags['file']) { $code = [System.IO.File]::ReadAllText($flags['file'], [System.Text.Encoding]::UTF8) }
            elseif ($rest.Count -ge 1) { $code = ($rest -join ' ') }
            $op = $flags['op']
            if (-not $code -and -not $op) { Fail 'usage: js <code> | js --file <path> | js --op <name> [--args json]' }
            $port = if ($flags['port']) { [int]$flags['port'] } else { 8737 }
            $timeoutSec = if ($flags['timeout']) { [int]$flags['timeout'] } else { 8 }
            $base = "http://127.0.0.1:$port"

            # 两级探活：/ping 只证明服务在；/stats 的 lastPollUtc 才证明有页面在领任务。
            # 用户脚本没装时，「等满 20 秒再报 timeout」是纯浪费——现在 200ms 内说清楚。
            $health = Get-BctlBridgeHealth -Port $port
            if (-not $health.running) { Fail "bridge server not running (run: bctl.ps1 bridge start)" }
            if (-not $health.client) {
                $age = if ($null -ne $health.lastPollSec) { ('last poll {0}s ago' -f $health.lastPollSec) } else { 'never polled' }
                Fail ("no userscript client is polling the bridge (" + $age + "). Install it with: bctl.ps1 bridge install — then reload the tab. Nothing was executed.")
            }

            $payloadObj = @{}
            if ($code) { $payloadObj['code'] = $code }
            if ($op) { $payloadObj['op'] = $op }
            if ($flags['args']) {
                try { $payloadObj['args'] = ($flags['args'] | ConvertFrom-Json) }
                catch { Fail 'invalid --args json' }
            }
            $payload = $payloadObj | ConvertTo-Json -Compress -Depth 6
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
            try {
                $resp = Invoke-RestMethod -Uri "$base/cmd" -Method Post -Body $bytes -ContentType 'application/json; charset=utf-8' -TimeoutSec 5
            }
            catch { Fail "enqueue failed: $($_.Exception.Message)" }
            $id = $resp.id

            $deadline = (Get-Date).AddSeconds($timeoutSec)
            $result = $null
            while ((Get-Date) -lt $deadline) {
                Start-Sleep -Milliseconds 250
                try { $r = Invoke-RestMethod -Uri "$base/result?id=$id" -TimeoutSec 3 } catch { continue }
                if ($r.status -eq 'done') { $result = $r; break }
            }
            if (-not $result) {
                # 超时的两种原因要分开说：没人领 vs 领了没回。否则调用方只能瞎猜。
                $h = Get-BctlBridgeHealth -Port $port
                $why = if ($h.pending -gt 0) {
                    ('the job was claimed by a tab but never returned (' + $h.pending + ' still pending) — focus that tab, or the page blocks script execution')
                }
                else { 'no userscript client picked it up — check the userscript is installed and the target tab is in front' }
                Fail ('no result in ' + $timeoutSec + 's: ' + $why)
            }
            if ($result.ok -eq $false -and $result.error -match 'Content Security Policy') {
                Write-Host ('NOTE: ' + $result.error)
            }
            if ($isJson) { Out-Result $result }
            else {
                if ($result.ok) { Write-Output $result.value }
                else { Write-Output ("JS ERROR: " + $result.error); exit 1 }
                Write-Host ("// " + $result.title + "  <" + $result.url + ">")
            }
        }

        default {
            if ($script:BatchMode) { throw [System.Exception]::new("unknown command: $cmd") }
            Write-Host "unknown command: $cmd"
            Write-Host "run: bctl.ps1 help"
            exit 2
        }
    }
}
catch {
    if ($script:BatchMode) { throw }
    Fail $_.Exception.Message
}
}   # end Invoke-BctlCli

# ---------------------------------------------------------------- pipeline mode
function Split-BctlLine {
    # 按空格切分，双/单引号成组（引号内的空格不切）——计划文件里的写法要跟命令行一致。
    param([string]$Line)
    $out = New-Object System.Collections.ArrayList
    $cur = New-Object System.Text.StringBuilder
    $quote = $null
    foreach ($ch in $Line.ToCharArray()) {
        if ($quote) {
            if ($ch -eq $quote) { $quote = $null } else { [void]$cur.Append($ch) }
        }
        elseif ($ch -eq '"' -or $ch -eq "'") { $quote = $ch }
        elseif ([char]::IsWhiteSpace($ch)) {
            if ($cur.Length -gt 0) { $null = $out.Add($cur.ToString()); [void]$cur.Clear() }
        }
        else { [void]$cur.Append($ch) }
    }
    if ($cur.Length -gt 0) { $null = $out.Add($cur.ToString()) }
    return $out.ToArray()
}

function Invoke-BctlBatch {
    # 一个进程跑完整条流水线。每步都强制 --json，回一个聚合结果，
    # 调用方一次往返拿到全部证据（命令 / 成败 / 耗时 / 数据）。
    param([string[]]$ArgList)

    $script:BatchMode = $true
    $file = $null
    $stepsJson = $null
    $cmds = New-Object System.Collections.ArrayList
    $keepGoing = $false
    $echo = $false
    $asJson = $false
    $port = ''
    $i = 0
    while ($i -lt $ArgList.Count) {
        $a = [string]$ArgList[$i]
        switch -Regex ($a) {
            '^--file$' { if ($i + 1 -lt $ArgList.Count) { $file = $ArgList[$i + 1]; $i++ } }
            '^--steps$' { if ($i + 1 -lt $ArgList.Count) { $stepsJson = $ArgList[$i + 1]; $i++ } }
            # --cmd 可以重复给：Windows 上层层转义 JSON 很容易被吃掉引号，
            # 直接一条 --cmd 一步最稳，不需要任何 JSON 语法。
            '^--cmd$' { if ($i + 1 -lt $ArgList.Count) { $null = $cmds.Add([string]$ArgList[$i + 1]); $i++ } }
            '^--port$' { if ($i + 1 -lt $ArgList.Count) { $port = [string]$ArgList[$i + 1]; $i++ } }
            '^--keep-going$' { $keepGoing = $true }
            '^--echo$' { $echo = $true }
            '^--json$' { $asJson = $true }
        }
        $i++
    }

    $lines = @()
    if ($file) {
        if (-not (Test-Path $file)) { $script:BatchMode = $false; Fail "plan file not found: $file" }
        $lines = [System.IO.File]::ReadAllLines($file, [System.Text.Encoding]::UTF8)
    }
    elseif ($cmds.Count -gt 0) {
        $lines = @($cmds)
    }
    elseif ($stepsJson) {
        # JSON 数组是首选；引号在多层转发里被吃掉时退化成 | 或 ; 分隔，别让调用方卡死。
        $parsed = $null
        try { $parsed = $stepsJson | ConvertFrom-Json } catch { $parsed = $null }
        if ($null -ne $parsed -and $parsed -isnot [string]) {
            $lines = @($parsed | ForEach-Object { [string]$_ })
        }
        elseif ($stepsJson -match '\|') {
            $lines = @($stepsJson -split '\|')
        }
        elseif ($stepsJson -match ';') {
            $lines = @($stepsJson -split ';')
        }
        else {
            $script:BatchMode = $false
            Fail 'invalid --steps: pass a JSON array of command strings, or use --cmd "<one command>" (repeatable), or --file <plan.txt>'
        }
    }
    if ($lines.Count -eq 0) {
        $script:BatchMode = $false
        Fail 'usage: batch --file <plan.txt> | batch --steps ''["title 123","url 123"]'' [--keep-going] [--echo] [--json]'
    }

    $results = New-Object System.Collections.ArrayList
    $started = Get-Date
    $n = 0
    foreach ($line in $lines) {
        $trim = ([string]$line).Trim()
        if ($trim -eq '' -or $trim.StartsWith('#')) { continue }
        $n++
        $argv = @(Split-BctlLine $trim)
        if ($argv -notcontains '--json') { $argv += '--json' }
        # 外层 --port 要落到每一步上，否则 steps 里的 js 会退回默认 8737，
        # 而插件配置改过端口时就整个跑不通。
        if ($port -and ($argv -notcontains '--port')) { $argv += '--port'; $argv += $port }
        if ($echo) { Write-Host ("[{0}] {1}" -f $n, $trim) }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try {
            $raw = @(Invoke-BctlCli -ArgList $argv)
            $sw.Stop()
            $payload = $null
            for ($k = $raw.Count - 1; $k -ge 0; $k--) {
                $candidate = $raw[$k]
                if (($candidate -is [string]) -and $candidate.Trim()) {
                    try { $payload = $candidate | ConvertFrom-Json; break } catch { continue }
                }
            }
            $ok = $true
            if ($null -ne $payload -and $payload.PSObject.Properties['ok']) { $ok = [bool]$payload.ok }
            $null = $results.Add([pscustomobject]@{
                    n = $n; cmd = $trim; ok = $ok; ms = [int]$sw.ElapsedMilliseconds; data = $payload; error = $null
                })
        }
        catch {
            $sw.Stop()
            $null = $results.Add([pscustomobject]@{
                    n = $n; cmd = $trim; ok = $false; ms = [int]$sw.ElapsedMilliseconds; data = $null; error = $_.Exception.Message
                })
            if (-not $keepGoing) { break }
        }
    }
    $script:BatchMode = $false

    $total = [int]((Get-Date) - $started).TotalMilliseconds
    $failed = @($results | Where-Object { -not $_.ok }).Count

    if ($asJson) {
        Out-Result ([pscustomobject]@{
                ok = ($failed -eq 0); count = $results.Count; failed = $failed
                totalMs = $total; steps = $results.ToArray()
            })
        return
    }
    if ($results.Count -eq 0) { Write-Host 'no steps ran'; return }
    foreach ($r in $results) {
        $mark = if ($r.ok) { 'ok  ' } else { 'FAIL' }
        $detail = if ($r.error) { 'error: ' + $r.error }
        elseif ($null -ne $r.data) { ($r.data | ConvertTo-Json -Depth 4 -Compress) }
        else { '' }
        if ($detail.Length -gt 160) { $detail = $detail.Substring(0, 160) + '…' }
        Write-Output ("{0} [{1,2}] {2,6}ms  {3}  {4}" -f $mark, $r.n, $r.ms, $r.cmd, $detail)
    }
    Write-Host ("--- {0} steps, {1} failed, {2}ms total" -f $results.Count, $failed, $total)
}

# ---------------------------------------------------------------- entry point
if ($ArgList.Count -ge 1 -and $ArgList[0] -match '^(?i)(batch|seq|pipeline)$') {
    if ($ArgList.Count -ge 2) { Invoke-BctlBatch -ArgList @($ArgList[1..($ArgList.Count - 1)]) }
    else { Invoke-BctlBatch -ArgList @() }
}
else {
    Invoke-BctlCli -ArgList @($ArgList)
}
