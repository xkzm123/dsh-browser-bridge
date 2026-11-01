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

# ---------------------------------------------------------------- arg parsing
$flags = @{}
$pos = New-Object System.Collections.ArrayList
$i = 0
while ($i -lt $ArgList.Count) {
    $a = $ArgList[$i]
    if ($a -like '--*') {
        $k = $a.TrimStart('-')
        if ($k -in @('json', 'all', 'double', 'triple', 'help')) { $flags[$k] = $true }
        elseif ($i + 1 -lt $ArgList.Count) { $flags[$k] = $ArgList[$i + 1]; $i++ }
        else { $flags[$k] = $true }
    }
    else { $null = $pos.Add($a) }
    $i++
}

$cmd = if ($pos.Count -gt 0) { $pos[0].ToLower() } else { 'help' }
$rest = @()
if ($pos.Count -gt 1) {
    for ($j = 1; $j -lt $pos.Count; $j++) { $rest += [string]$pos[$j] }
}
$isJson = [bool]$flags['json']

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
        $rows = @($collected.ToArray())
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
    if ($isJson) { @{ ok = $false; error = $Message } | ConvertTo-Json -Compress }
    else { Write-Host "ERR: $Message" }
    exit 1
}

function Normalize-BctlUrl {
    # 只比 origin + path，忽略 query/fragment/末尾斜杠，用来判断「是不是已经开着」。
    param([string]$Url)
    if (-not $Url) { return '' }
    $u = $Url.Trim()
    # file:// 在地址栏里显示成 C:/... ，两边要比得了
    if ($u -match '^(?i)file:') {
        return (($u -replace '^(?i)file:/*', '').ToLower().TrimEnd('/'))
    }
    if ($u -match '^[a-zA-Z][a-zA-Z0-9+.\-]*://([^/?#]+)([^?#]*)') {
        $hostPart = $matches[1].ToLower()
        return ($hostPart + $matches[2].TrimEnd('/'))
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
        $hint = 'the browser process is alive but has no window. Windows cannot conjure one; ask the user to click the taskbar icon, or pass --reopen to start a window in the same profile (adds a window).'
        if ($Reopen) {
            $exe = ($procs | Select-Object -First 1).Path
            try {
                Start-Process -FilePath $exe | Out-Null
                Start-Sleep -Milliseconds 2500
                return [pscustomobject]@{ state = 'reopened'; exe = $exe }
            }
            catch { return [pscustomobject]@{ state = 'windowless'; processes = $procs.Count; hint = $hint; error = $_.Exception.Message } }
        }
        return [pscustomobject]@{ state = 'windowless'; processes = $procs.Count; hint = $hint }
    }
    $sort = @{ Expression = { [int64]$_.w * [int64]$_.h }; Descending = $true }
    $vis = @($rows | Where-Object { $_.visible })
    if ($vis.Count -gt 0) {
        $t = $vis | Sort-Object -Property $sort | Select-Object -First 1
        return [pscustomobject]@{ state = 'ok'; pid = $t.pid; handle = $t.handle; title = $t.title }
    }
    $t = $rows | Sort-Object -Property $sort | Select-Object -First 1
    [void][BctlNative]::ShowWindow([IntPtr]$t.handle, 9)
    [void][BctlNative]::ForceForeground([IntPtr]$t.handle)
    Start-Sleep -Milliseconds 350
    return [pscustomobject]@{
        state = 'hidden'; restored = $true; pid = $t.pid; handle = $t.handle
        nowVisible = [BctlNative]::IsWindowVisible([IntPtr]$t.handle); title = $t.title
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
  type <text> | --file <path>         type text (unicode, bypasses IME)
  key <combo>                         CTRL+L / CTRL+W / ENTER / F5 / PAGE_DOWN
  shot [file] [--region x,y,w,h]      capture virtual screen
  shot --win <pid> [--file path]      capture one window
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
  clip get | clip set <text>          clipboard

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
                if ($p.ProcessName -notmatch '^(msedge|chrome|brave|vivaldi|opera|chromium|thorium|firefox|librewolf)$') { continue }
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
            # 主窗口排前面：非弹窗优先，其次面积大的优先
            $rows = @($rows | Sort-Object -Property @{ Expression = { [int]$_.dialog } }, @{ Expression = { [int64]$_.w * [int64]$_.h }; Descending = $true })
            if ($rows.Count -eq 0) {
                # 进程在、窗口没有：这是「关掉窗口但后台常驻」的状态。
                # 这时重开浏览器只会多出一个新窗口/新标签，必须阻止。
                $procs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^(msedge|chrome|brave|vivaldi|opera|chromium|thorium|firefox|librewolf)$' })
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
            [void](Set-BctlForeground -Window $w)
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
            if (-not $text) { Fail 'usage: type <text> | type --file <path>' }
            Invoke-BctlType -Text $text
            Out-Result ([pscustomobject]@{ ok = $true; chars = $text.Length })
        }

        'key' {
            if ($rest.Count -lt 1) { Fail 'usage: key <combo> [--allow-close]' }
            $combo = (($rest -join '+').ToUpper()) -replace '\s', ''
            $closeCombos = @('CTRL+W', 'CTRL+F4', 'ALT+F4', 'CTRL+SHIFT+W', 'CTRL+Q')
            if (($closeCombos -contains $combo) -and -not $flags['allow-close']) {
                Write-BctlAudit 'key-refused' @{ combo = $combo }
                Fail ("'" + $combo + "' closes a tab or the window, so nothing was sent. Closing the last window leaves the browser running with no UI, which is exactly the vanished-browser state. Pass --allow-close only when ending the window is really the goal.")
            }
            Invoke-BctlKey -Combo $combo
            Write-BctlAudit 'key' @{ combo = $combo }
            Out-Result ([pscustomobject]@{ ok = $true; combo = $combo })
        }

        'shot' {
            $file = if ($rest.Count -ge 1) { $rest[0] } elseif ($flags['file']) { $flags['file'] } else { Join-Path (Get-Location) 'shot.png' }
            if ($flags['win']) {
                $w = Need-Pid $flags['win']
                Get-BctlScreenshot -Path $file -X $w.x -Y $w.y -W $w.w -H $w.h | Out-Null
            }
            elseif ($flags['region']) {
                $r = $flags['region'] -split ','
                Get-BctlScreenshot -Path $file -X ([int]$r[0]) -Y ([int]$r[1]) -W ([int]$r[2]) -H ([int]$r[3]) | Out-Null
            }
            else {
                Get-BctlScreenshot -Path $file | Out-Null
            }
            Out-Result ([pscustomobject]@{ ok = $true; file = (Resolve-Path $file).Path })
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
            $items = Find-BctlElements -ProcessId $w.pid -Pattern '' -Type 'TabItem' -Limit 100
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
            [void](Set-BctlForeground -Window $w)
            Invoke-BctlKey -Combo "CTRL+$n"
            Out-Result ([pscustomobject]@{ ok = $true; tab = $n })
        }

        'newtab' {
            $w = Need-Pid $rest[0]
            [void](Set-BctlForeground -Window $w)
            Invoke-BctlKey -Combo 'CTRL+T'
            Out-Result ([pscustomobject]@{ ok = $true })
        }

        'closetab' {
            $w = Need-Pid $rest[0]
            [void](Set-BctlForeground -Window $w)
            Invoke-BctlKey -Combo 'CTRL+W'
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
                        if ($t.name -notmatch [regex]::Escape($label)) { continue }
                        [void](Set-BctlForeground -Window $w)
                        Invoke-BctlKey -Combo ("CTRL+" + $t.index)
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
                if ($origIndex) {
                    [void](Set-BctlForeground -Window $w)
                    Invoke-BctlKey -Combo ("CTRL+" + $origIndex)
                    Start-Sleep -Milliseconds 300
                }
            }

            $before = Get-BctlWindowState -Handle $w.handle
            [void](Set-BctlForeground -Window $w)
            Invoke-BctlKey -Combo 'CTRL+L'
            Start-Sleep -Milliseconds 150
            Invoke-BctlKey -Combo 'CTRL+A'
            Invoke-BctlType -Text $url
            Start-Sleep -Milliseconds 120
            Invoke-BctlKey -Combo 'ENTER'
            Start-Sleep -Milliseconds 1200
            $after = Get-BctlWindowState -Handle $w.handle
            Write-BctlAudit 'nav' @{ pid = $w.pid; url = $url; reused = 'no'; before = $before; after = $after }
            if (-not $after.visible) {
                Fail 'the browser window disappeared during navigation. Run: bctl.ps1 ensure'
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
            $before = Get-BctlWindowState -Handle $w.handle
            [void](Set-BctlForeground -Window $w)
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
            if ($isJson) {
                # 只在显式给了 --file 时落盘，避免每次读取都产生文件
                $saved = $null
                if ($flags['file']) {
                    [System.IO.File]::WriteAllText($flags['file'], $txt, (New-Object System.Text.UTF8Encoding($false)))
                    $saved = (Resolve-Path $flags['file']).Path
                }
                Out-Result ([pscustomobject]@{ ok = $true; chars = $txt.Length; file = $saved; text = $txt })
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
            $ms = if ($rest.Count -ge 1) { [int]$rest[0] } else { 500 }
            Start-Sleep -Milliseconds $ms
            Out-Result ([pscustomobject]@{ ok = $true; waited = $ms })
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
                default { Fail "usage: bridge start|status|stop [--port N]" }
            }
        }

        'js' {
            $code = $null
            if ($flags['file']) { $code = [System.IO.File]::ReadAllText($flags['file'], [System.Text.Encoding]::UTF8) }
            elseif ($rest.Count -ge 1) { $code = ($rest -join ' ') }
            $op = $flags['op']
            if (-not $code -and -not $op) { Fail 'usage: js <code> | js --file <path> | js --op <name> [--args json]' }
            $port = if ($flags['port']) { [int]$flags['port'] } else { 8737 }
            $timeoutSec = if ($flags['timeout']) { [int]$flags['timeout'] } else { 20 }
            $base = "http://127.0.0.1:$port"

            try { $null = Invoke-RestMethod -Uri "$base/ping" -TimeoutSec 2 } catch { Fail "bridge server not running (run: bctl.ps1 bridge start)" }

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
                Fail "no result in ${timeoutSec}s (is the userscript installed and the target tab focused?)"
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
            Write-Host "unknown command: $cmd"
            Write-Host "run: bctl.ps1 help"
            exit 2
        }
    }
}
catch {
    Fail $_.Exception.Message
}
