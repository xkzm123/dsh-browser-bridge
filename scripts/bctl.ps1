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

function Out-Result {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline = $true, Position = 0)]
        $Data
    )
    process {
        if ($null -eq $Data) { return }
        if ($isJson) {
            $Data | ConvertTo-Json -Depth 8 -Compress
            return
        }
        if ($Data -is [string]) { Write-Output $Data; return }
        if ($Data -is [System.Collections.IEnumerable] -and -not ($Data -is [string])) {
            Write-Output ($Data | Format-Table -AutoSize | Out-String -Width 400)
            return
        }
        Write-Output ($Data | Format-List | Out-String -Width 400)
    }
}

function Fail {
    param([string]$Message)
    if ($isJson) { @{ ok = $false; error = $Message } | ConvertTo-Json -Compress }
    else { Write-Host "ERR: $Message" }
    exit 1
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
            $rows = @()
            foreach ($p in (Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^(chrome|msedge|brave|vivaldi|opera|chromium|Arc|firefox)$' -and $_.MainWindowHandle -ne 0 })) {
                $rows += [pscustomobject]@{
                    pid     = $p.Id
                    process = $p.ProcessName
                    title   = $p.MainWindowTitle
                }
            }
            if ($rows.Count -eq 0) { Fail 'no browser window found' }
            Out-Result $rows
        }

        'windows' {
            $all = Get-BctlWindows
            if (-not $flags['all']) { $all = $all | Where-Object { $_.w -gt 200 -and $_.h -gt 100 } }
            Out-Result ($all | Sort-Object pid | Select-Object pid, handle, className, x, y, w, h, title)
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
            if ($rest.Count -lt 1) { Fail 'usage: key <combo>' }
            Invoke-BctlKey -Combo ($rest -join '+')
            Out-Result ([pscustomobject]@{ ok = $true; combo = ($rest -join '+') })
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
            Out-Result $rows
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
            if ($rest.Count -lt 2) { Fail 'usage: nav <pid> <url>' }
            $w = Need-Pid $rest[0]
            $url = $rest[1]
            [void](Set-BctlForeground -Window $w)
            Invoke-BctlKey -Combo 'CTRL+L'
            Start-Sleep -Milliseconds 150
            Invoke-BctlKey -Combo 'CTRL+A'
            Invoke-BctlType -Text $url
            Start-Sleep -Milliseconds 120
            Invoke-BctlKey -Combo 'ENTER'
            Start-Sleep -Milliseconds 1200
            Out-Result ([pscustomobject]@{ ok = $true; pid = $w.pid; url = $url })
        }

        'uia' {
            $w = Need-Pid $rest[0]
            $root = Get-BctlUiaRoot -ProcessId $w.pid
            if (-not $root) { Fail 'UI Automation cannot see this window' }
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
            if ($isJson) { Out-Result $rows }
            else {
                Write-Host ("total=" + $all.Count + " shown=" + $rows.Count)
                $rows | Select-Object type, name, rect, cx, cy | Format-Table -AutoSize | Out-String -Width 400
            }
        }

        'find' {
            if ($rest.Count -lt 2) { Fail 'usage: find <pid> <regex>' }
            $w = Need-Pid $rest[0]
            $type = if ($flags['type']) { $flags['type'] } else { '' }
            $els = Find-BctlElements -ProcessId $w.pid -Pattern $rest[1] -Type $type
            $rows = @()
            foreach ($e in $els) { $rows += (Get-BctlElementInfo -Element $e) }
            if ($rows.Count -eq 0) { Fail "no element matched: $($rest[1])" }
            if ($isJson) { Out-Result $rows }
            else { $rows | Select-Object type, name, rect, cx, cy | Format-Table -AutoSize | Out-String -Width 400 }
        }

        'clickel' {
            if ($rest.Count -lt 2) { Fail 'usage: clickel <pid> <name>' }
            $w = Need-Pid $rest[0]
            $type = if ($flags['type']) { $flags['type'] } else { '' }
            $el = Find-BctlElement -ProcessId $w.pid -Name $rest[1] -Type $type
            if (-not $el) {
                $cands = Find-BctlElements -ProcessId $w.pid -Pattern ([regex]::Escape($rest[1])) -Type $type
                if ($cands.Count -gt 0) { $el = $cands[0] }
            }
            if (-not $el) { Fail "element not found: $($rest[1])" }
            $info = Get-BctlElementInfo -Element $el
            [void](Set-BctlForeground -Window $w)
            Invoke-BctlClick -X $info.cx -Y $info.cy
            Out-Result ([pscustomobject]@{ ok = $true; clicked = $info.name; type = $info.type; x = $info.cx; y = $info.cy })
        }

        'invoke' {
            if ($rest.Count -lt 2) { Fail 'usage: invoke <pid> <name>' }
            $w = Need-Pid $rest[0]
            $el = Find-BctlElement -ProcessId $w.pid -Name $rest[1]
            if (-not $el) { Fail "element not found: $($rest[1])" }
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
            $el = Find-BctlElement -ProcessId $w.pid -Name $rest[1]
            if (-not $el) { Fail "element not found: $($rest[1])" }
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
            $el = Find-BctlElement -ProcessId $w.pid -Name $rest[1]
            if (-not $el) { Fail "element not found: $($rest[1])" }
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
            $file = if ($flags['file']) { $flags['file'] } else { Join-Path (Get-Location) 'page.txt' }
            [System.IO.File]::WriteAllText($file, $txt, (New-Object System.Text.UTF8Encoding($false)))
            if ($isJson) { Out-Result ([pscustomobject]@{ ok = $true; chars = $txt.Length; file = (Resolve-Path $file).Path }) }
            else {
                Write-Host ("chars=" + $txt.Length + " -> " + (Resolve-Path $file).Path)
                $preview = if ($txt.Length -gt 1200) { $txt.Substring(0, 1200) } else { $txt }
                Write-Host '--- preview ---'
                Write-Host $preview
            }
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
            if (-not $code) { Fail 'usage: js <code> | js --file <path>' }
            $port = if ($flags['port']) { [int]$flags['port'] } else { 8737 }
            $timeoutSec = if ($flags['timeout']) { [int]$flags['timeout'] } else { 20 }
            $base = "http://127.0.0.1:$port"

            try { $null = Invoke-RestMethod -Uri "$base/ping" -TimeoutSec 2 } catch { Fail "bridge server not running (run: bctl.ps1 bridge start)" }

            $payload = @{ code = $code } | ConvertTo-Json -Compress
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
