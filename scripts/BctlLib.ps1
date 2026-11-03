# BctlLib.ps1 - core library for dsh-browser-bridge
# Pure PowerShell 5.1 + .NET Framework. No external dependency.
# Dot-source this file, then call the exported functions.

$script:BctlVersion = '1.5.0'

# 浏览器进程与窗口类白名单：全项目只此一份，bctl.ps1 直接复用。
# 之前 index.js / BctlLib / bctl 各写一遍，加一个浏览器要改三处，必然漂移。
$script:BrowserProcessNames = @('msedge', 'chrome', 'brave', 'vivaldi', 'opera', 'chromium', 'thorium', 'firefox', 'librewolf', 'arc')
$script:BrowserProcessRegex = '^(msedge|chrome|brave|vivaldi|opera|chromium|thorium|firefox|librewolf|arc)$'
$script:UiaWindowClasses = @('Chrome_WidgetWin_1', 'MozillaWindowClass')
$script:UiaDir = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\WPF\'
$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------- native layer
if (-not ('BctlNative' -as [type])) {
    $cs = @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class BctlNative {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X, Y; }

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }

    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }

    [StructLayout(LayoutKind.Explicit)]
    public struct INPUTUNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }

    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT { public uint type; public INPUTUNION u; }

    public delegate bool EnumProc(IntPtr h, IntPtr p);

    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int max);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int max);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr SetFocus(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool f);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] p, int sz);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra);
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int attr, out RECT r, int sz);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
    [DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int v);
    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);

    public const uint MWHEEL = 0x0800, MHWHEEL = 0x1000;
    public const uint LDOWN = 0x0002, LUP = 0x0004, RDOWN = 0x0008, RUP = 0x0010, MDOWN = 0x0020, MUP = 0x0040;
    public const uint KEYUP = 0x0002, UNICODE = 0x0004;

    public static bool Dpi() {
        try { if (SetProcessDpiAwarenessContext(new IntPtr(-4))) return true; } catch { }
        try { if (SetProcessDpiAwareness(2) == 0) return true; } catch { }
        try { return SetProcessDPIAware(); } catch { }
        return false;
    }

    static void MouseRaw(uint flags, int data) {
        INPUT[] a = new INPUT[1];
        a[0].type = 0;
        a[0].u.mi.dx = 0; a[0].u.mi.dy = 0;
        a[0].u.mi.mouseData = (uint)data;
        a[0].u.mi.dwFlags = flags;
        SendInput(1, a, Marshal.SizeOf(typeof(INPUT)));
    }

    public static void MouseDown(string btn) {
        if (btn == "right") MouseRaw(RDOWN, 0);
        else if (btn == "middle") MouseRaw(MDOWN, 0);
        else MouseRaw(LDOWN, 0);
    }

    public static void MouseUp(string btn) {
        if (btn == "right") MouseRaw(RUP, 0);
        else if (btn == "middle") MouseRaw(MUP, 0);
        else MouseRaw(LUP, 0);
    }

    public static void Wheel(int delta) { MouseRaw(MWHEEL, delta); }
    public static void HWheel(int delta) { MouseRaw(MHWHEEL, delta); }

    public static void TypeUnicode(string s) {
        foreach (char ch in s) {
            INPUT[] d = new INPUT[1];
            d[0].type = 1;
            d[0].u.ki.wVk = 0; d[0].u.ki.wScan = ch; d[0].u.ki.dwFlags = UNICODE;
            SendInput(1, d, Marshal.SizeOf(typeof(INPUT)));
            INPUT[] u = new INPUT[1];
            u[0].type = 1;
            u[0].u.ki.wVk = 0; u[0].u.ki.wScan = ch; u[0].u.ki.dwFlags = UNICODE | KEYUP;
            SendInput(1, u, Marshal.SizeOf(typeof(INPUT)));
            System.Threading.Thread.Sleep(4);
        }
    }

    public static void KeyEvent(ushort vk, bool up) {
        INPUT[] a = new INPUT[1];
        a[0].type = 1;
        a[0].u.ki.wVk = vk; a[0].u.ki.wScan = 0;
        a[0].u.ki.dwFlags = up ? KEYUP : 0;
        SendInput(1, a, Marshal.SizeOf(typeof(INPUT)));
    }

    public static bool ForceForeground(IntPtr h) {
        if (IsIconic(h)) ShowWindow(h, 9);
        IntPtr fg = GetForegroundWindow();
        if (fg == h) return true;
        uint pid;
        uint ft = GetWindowThreadProcessId(fg, out pid);
        uint ct = GetCurrentThreadId();
        bool attached = false;
        try { attached = AttachThreadInput(ct, ft, true); } catch { }
        // ALT 轻敲让 Windows 认为本次输入来自前台线程，随后 SetForegroundWindow 才被放行
        keybd_event(0x12, 0, 0, IntPtr.Zero);
        keybd_event(0x12, 0, 2, IntPtr.Zero);
        try { BringWindowToTop(h); } catch { }
        SetForegroundWindow(h);
        try { SetFocus(h); } catch { }
        // 刻意不调 ShowWindow(h, 5)：对隐藏窗口 SW_SHOW 会把 Edge 关窗后残留的
        // 空壳 HWND 重新显示出来，用户看到的就是「浏览器自己又开了一个窗口」。
        if (attached) { try { AttachThreadInput(ct, ft, false); } catch { } }
        return GetForegroundWindow() == h;
    }

    public static RECT Frame(IntPtr h) {
        RECT r;
        try {
            if (DwmGetWindowAttribute(h, 9, out r, Marshal.SizeOf(typeof(RECT))) == 0) return r;
        } catch { }
        GetWindowRect(h, out r);
        return r;
    }
}
"@
    # 冷启动实测：现场编译这段 C# 要 ~265ms，而每条 bctl 命令都是一个新进程，
    # 等于每次都重付一次。把编译产物缓存成 DLL，后续进程 Add-Type -Path 直接载入。
    # 缓存键 = 源码哈希 + PowerShell 版本，源码一改就自动失效。
    $script:BctlAssembly = $null
    $cacheDir = Join-Path $env:LOCALAPPDATA 'dsh-browser-bridge'
    $dll = $null
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($cs + '|' + $PSVersionTable.PSVersion.ToString())
        $key = -join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') })
        $sha.Dispose()
        if (-not (Test-Path $cacheDir)) { [void](New-Item -ItemType Directory -Path $cacheDir -Force) }
        $dll = Join-Path $cacheDir ('bctl-native-' + $key.Substring(0, 16) + '.dll')
    }
    catch { $dll = $null }

    $loaded = $false
    if ($dll -and (Test-Path $dll)) {
        try { Add-Type -Path $dll; $script:BctlAssembly = $dll; $loaded = $true }
        catch { try { Remove-Item $dll -Force -ErrorAction SilentlyContinue } catch { } }
    }
    if (-not $loaded) {
        # -OutputAssembly 只负责把程序集写到磁盘，不保证载入当前会话，
        # 所以编译完必须再 Add-Type -Path 一次，否则 [BctlNative] 依然找不到。
        try { Add-Type -TypeDefinition $cs -Language CSharp -OutputAssembly $dll | Out-Null }
        catch { $dll = $null }
        if ($dll -and (Test-Path $dll)) {
            try { Add-Type -Path $dll; $script:BctlAssembly = $dll }
            catch { $script:BctlAssembly = $null }
        }
        # 兜底：磁盘缓存不可用（只读盘 / 组策略）就直接在内存里编译，功能不受影响。
        if (-not ('BctlNative' -as [type])) {
            Add-Type -TypeDefinition $cs -Language CSharp
            $script:BctlAssembly = $null
        }
    }
    # 顺手清掉 7 天前的旧版本缓存，避免源码迭代把缓存目录堆满。
    if ($script:BctlAssembly -and $cacheDir) {
        try {
            Get-ChildItem -Path $cacheDir -Filter 'bctl-native-*.dll' -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -ne $script:BctlAssembly -and $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
                Remove-Item -Force -ErrorAction SilentlyContinue
        }
        catch { }
    }
}

[void][BctlNative]::Dpi()

# ---------------------------------------------------------------- UIA layer
if (-not ('System.Windows.Automation.AutomationElement' -as [type])) {
    foreach ($dll in @('UIAutomationClient.dll', 'UIAutomationTypes.dll', 'UIAutomationClientsideProviders.dll')) {
        try { [void][System.Reflection.Assembly]::LoadFrom(($script:UiaDir + $dll)) } catch { }
    }
}

$script:AE = [System.Windows.Automation.AutomationElement]
$script:TS = [System.Windows.Automation.TreeScope]
$script:CT = [System.Windows.Automation.ControlType]

# ---------------------------------------------------------------- helpers
function Get-BctlWindows {
    param([switch]$IncludeHidden)
    $list = New-Object System.Collections.ArrayList
    $cb = [BctlNative+EnumProc] {
        param($h, $p)
        $vis = [BctlNative]::IsWindowVisible($h)
        if ($vis -or $IncludeHidden) {
            $sb = New-Object System.Text.StringBuilder 1024
            [void][BctlNative]::GetWindowTextW($h, $sb, 1024)
            $t = $sb.ToString()
            if ($t.Length -gt 0) {
                $cn = New-Object System.Text.StringBuilder 256
                [void][BctlNative]::GetClassNameW($h, $cn, 256)
                $wpid = [uint32]0
                [void][BctlNative]::GetWindowThreadProcessId($h, [ref]$wpid)
                $r = [BctlNative]::Frame($h)
                $null = $list.Add([pscustomobject]@{
                        pid       = $wpid
                        handle    = [int64]$h
                        className = $cn.ToString()
                        title     = $t
                        visible   = $vis
                        x         = $r.Left
                        y         = $r.Top
                        w         = $r.Right - $r.Left
                        h         = $r.Bottom - $r.Top
                    })
            }
        }
        return $true
    }
    [void][BctlNative]::EnumWindows($cb, [IntPtr]::Zero)
    return $list
}

function Resolve-BctlWindow {
    # 选窗口的唯一定义。三条规则，顺序不能换：
    #   1. "pid:handle" 精确句柄优先。插件层传的就是这个形式，避免按 pid 二次解析时
    #      选到同一进程的另一个窗口（Edge 一个进程常常挂着 3 个顶层窗口）。
    #   2. 只有「可见」窗口才是候选。隐藏窗口是关窗后残留的空壳 HWND，
    #      对它激活会把后台空窗口复活——这正是「浏览器莫名被重开」的来源。
    #   3. 可见窗口里挑面积最大的，排除 146x21 的 helper。
    param([string]$Spec, [switch]$AllowHidden)
    if (-not $Spec) { return $null }

    if ($Spec -match '^(\d+):(\d+)$') {
        $wantPid = [uint32]$matches[1]
        $wantHandle = [int64]$matches[2]
        $hit = Get-BctlWindows -IncludeHidden |
            Where-Object { $_.pid -eq $wantPid -and [int64]$_.handle -eq $wantHandle } |
            Select-Object -First 1
        if ($hit -and ($hit.visible -or $AllowHidden)) { return $hit }
        # 句柄已失效（Edge 会重建顶层窗口）就退回按 pid 重新解析，而不是直接失败
        $Spec = [string]$wantPid
    }

    $all = @(Get-BctlWindows -IncludeHidden)
    if ($Spec -match '^\d+$') {
        $cands = @($all | Where-Object { $_.pid -eq [uint32]$Spec })
    }
    else {
        $cands = @($all | Where-Object { $_.title -like "*$Spec*" })
    }
    if ($cands.Count -eq 0) { return $null }

    $big = @($cands | Where-Object { $_.w -ge 300 -and $_.h -ge 200 })
    if ($big.Count -gt 0) { $cands = $big }

    if (-not $AllowHidden) {
        $vis = @($cands | Where-Object { $_.visible })
        if ($vis.Count -eq 0) { return $null }
        $cands = $vis
    }
    return ($cands | Sort-Object -Property @{ Expression = { [int64]$_.w * [int64]$_.h }; Descending = $true } | Select-Object -First 1)
}

function Get-BctlUiaRoot {
    param([uint32]$ProcessId)
    $root = $script:AE::RootElement
    $c = New-Object System.Windows.Automation.PropertyCondition($script:AE::ClassNameProperty, 'Chrome_WidgetWin_1')
    $wins = $root.FindAll($script:TS::Children, $c)
    foreach ($w in $wins) { if ($w.Current.ProcessId -eq $ProcessId) { return $w } }
    # fallback: any top window of that pid
    $c2 = New-Object System.Windows.Automation.PropertyCondition($script:AE::ProcessIdProperty, [int]$ProcessId)
    return ($root.FindFirst($script:TS::Children, $c2))
}

function Format-BctlRect {
    param($R)
    if ([double]::IsInfinity($R.X) -or [double]::IsInfinity($R.Y)) { return 'offscreen' }
    return ('{0},{1} {2}x{3}' -f [int]$R.X, [int]$R.Y, [int]$R.Width, [int]$R.Height)
}

function Get-BctlSafeInt {
    param($Value)
    if ($null -eq $Value) { return -1 }
    try {
        $d = [double]$Value
    }
    catch { return -1 }
    if ([double]::IsNaN($d) -or [double]::IsInfinity($d)) { return -1 }
    if ($d -gt 2147483647 -or $d -lt -2147483648) { return -1 }
    return [int]$d
}

function Get-BctlElementInfo {
    param($Element)
    $c = $Element.Current
    $r = $c.BoundingRectangle
    $x = Get-BctlSafeInt $r.X
    $y = Get-BctlSafeInt $r.Y
    $w = Get-BctlSafeInt $r.Width
    $h = Get-BctlSafeInt $r.Height
    [pscustomobject]@{
        name         = ($c.Name -replace "\r?\n", ' ')
        type         = ($c.ControlType.ProgrammaticName -replace 'ControlType\.', '')
        automationId = $c.AutomationId
        className    = $c.ClassName
        rect         = (Format-BctlRect $r)
        x            = $x
        y            = $y
        w            = $w
        h            = $h
        # 用 UIA 自己的 IsOffscreen 判断，不要拿 x < 0 当判据：
        # 副屏摆在主屏左边时（虚拟屏幕原点为负），页面元素坐标本来就是负数，
        # 旧写法会把它们一律标成 offscreen，clickel 于是点到 (-1,cy) 上去。
        cx           = $(if ($c.IsOffscreen -or $w -le 0 -or $h -le 0) { -1 } else { $x + [int]($w / 2) })
        cy           = $(if ($c.IsOffscreen -or $w -le 0 -or $h -le 0) { -1 } else { $y + [int]($h / 2) })
        enabled      = $c.IsEnabled
        offscreen    = $c.IsOffscreen
    }
}


# 窗口自身按钮（标题栏 chrome）的名字。出现在窗口根下、页面之外，
# 点到它们等于关窗/最小化，必须结构性排除。
$script:DangerWindowNames = '^(最小化|最大化|还原|向下还原|关闭|关闭窗口|Close|Close window|Minimize|Maximize|Restore|×|✕|✖)$'

function Get-BctlPageRoot {
    # 网页内容的根节点。Chromium 把整个 DOM 投影到 ControlType.Document 之下，
    # 标题栏按钮在它外面——所有查找都从这里开始，就从结构上碰不到关窗按钮。
    param([uint32]$ProcessId)
    $root = Get-BctlUiaRoot -ProcessId $ProcessId
    if (-not $root) { return $null }
    $c = New-Object System.Windows.Automation.PropertyCondition($script:AE::ControlTypeProperty, $script:CT::Document)
    return $root.FindFirst($script:TS::Descendants, $c)
}

function Test-BctlInPageTree {
    # 元素是否位于页面根之下。用来在点击前做最后一道校验。
    param($Element, $PageRoot)
    if (-not $Element -or -not $PageRoot) { return $false }
    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    $cur = $Element
    $guard = 0
    while ($cur -and $guard -lt 200) {
        try {
            if ([System.Windows.Automation.Automation]::Compare($cur, $PageRoot)) { return $true }
            $cur = $walker.GetParent($cur)
        }
        catch { break }
        $guard++
    }
    return $false
}

function Test-BctlDangerName {
    param([string]$Name)
    if (-not $Name) { return $false }
    return ($Name.Trim() -match $script:DangerWindowNames)
}

function Protect-BctlText {
    # 审计日志会记录元素名和 URL。凭据、token、cookie 一律先抹掉再落盘。
    param([string]$Text, [int]$Max = 120)
    if (-not $Text) { return $Text }
    $out = $Text -replace '(?i)(token|passw(?:or)?d|pwd|secret|api[_-]?key|cookie|authorization|session[_-]?id|sid)=([^&\s]+)', '$1=***'
    if ($out.Length -gt $Max) { $out = $out.Substring(0, $Max) + "…" }
    return $out
}

function Write-BctlAudit {
    # 每个动作一行 JSON，落在 ~/.dsh/browser-bridge/audit.log，出问题能回溯。
    param([string]$Action, [hashtable]$Data)
    try {
        $dir = Join-Path $env:USERPROFILE '.dsh\browser-bridge'
        if (-not (Test-Path $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
        $file = Join-Path $dir 'audit.log'
        if ((Test-Path $file) -and ((Get-Item $file).Length -gt 1048576)) {
            Move-Item -Path $file -Destination ($file + '.1') -Force -ErrorAction SilentlyContinue
        }
        $rec = [ordered]@{ ts = (Get-Date).ToString('o'); action = $Action }
        if ($Data) {
            foreach ($k in $Data.Keys) {
                $v = $Data[$k]
                if ($v -is [string]) { $v = Protect-BctlText -Text $v }
                $rec[$k] = $v
            }
        }
        Add-Content -Path $file -Value ($rec | ConvertTo-Json -Compress -Depth 4) -Encoding UTF8 -ErrorAction SilentlyContinue
    }
    catch { }
}

function Get-BctlWindowState {
    param([int64]$Handle)
    if (-not $Handle) { return $null }
    $h = [IntPtr]$Handle
    $r = [BctlNative]::Frame($h)
    return [pscustomobject]@{
        handle  = $Handle
        visible = [BctlNative]::IsWindowVisible($h)
        iconic  = [BctlNative]::IsIconic($h)
        rect    = ('{0},{1} {2}x{3}' -f $r.Left, $r.Top, ($r.Right - $r.Left), ($r.Bottom - $r.Top))
    }
}

function Find-BctlElement {
    param(
        [uint32]$ProcessId,
        [string]$Name,
        [string]$Type,
        [ValidateSet('page', 'window')][string]$Scope = 'page'
    )
    $root = if ($Scope -eq 'window') { Get-BctlUiaRoot -ProcessId $ProcessId } else { Get-BctlPageRoot -ProcessId $ProcessId }
    # 页面作用域下绝不回退到窗口根：窗口根里有最小化/关闭按钮，
    # 回退等于把危险目标重新放进射程。页面没就绪就让调用方等一等。
    if (-not $root) { return $null }
    $conds = New-Object System.Collections.ArrayList
    if ($Name) { $null = $conds.Add((New-Object System.Windows.Automation.PropertyCondition($script:AE::NameProperty, $Name))) }
    if ($Type) {
        $ct = $script:CT::$Type
        if ($ct) { $null = $conds.Add((New-Object System.Windows.Automation.PropertyCondition($script:AE::ControlTypeProperty, $ct))) }
    }
    if ($conds.Count -eq 0) { return $null }
    $cond = if ($conds.Count -eq 1) { $conds[0] } else { New-Object System.Windows.Automation.AndCondition($conds.ToArray()) }
    return $root.FindFirst($script:TS::Descendants, $cond)
}

function Find-BctlElements {
    param([uint32]$ProcessId, [string]$Pattern, [string]$Type, [int]$Limit = 200, [ValidateSet('page', 'window')][string]$Scope = 'page')
    $root = if ($Scope -eq 'window') { Get-BctlUiaRoot -ProcessId $ProcessId } else { Get-BctlPageRoot -ProcessId $ProcessId }
    if (-not $root) { return @() }
    $cond = [System.Windows.Automation.Condition]::TrueCondition
    if ($Type) {
        $ct = $script:CT::$Type
        if ($ct) { $cond = New-Object System.Windows.Automation.PropertyCondition($script:AE::ControlTypeProperty, $ct) }
    }
    $all = $root.FindAll($script:TS::Descendants, $cond)
    $out = New-Object System.Collections.ArrayList
    foreach ($e in $all) {
        $c = $e.Current
        $nm = $c.Name
        if ($Pattern -eq '' -or $nm -match $Pattern) {
            $null = $out.Add($e)
            if ($out.Count -ge $Limit) { break }
        }
    }
    return $out
}

# 页面文本上限：一个几 MB 的 JSON 会撑爆调用方 stdout 缓冲，也会白烧上下文。
$script:MaxTextChars = 200000

function Get-BctlDocument {
    param([uint32]$ProcessId)
    $root = Get-BctlUiaRoot -ProcessId $ProcessId
    if (-not $root) { return $null }
    $c = New-Object System.Windows.Automation.PropertyCondition($script:AE::ControlTypeProperty, $script:CT::Document)
    return $root.FindFirst($script:TS::Descendants, $c)
}

# ---------------------------------------------------------------- actions
function Assert-BctlFocus {
    # 键盘/文字输入前的最后一道闸：前台不是目标窗口就抛异常，一个字符都不发。
    # 没有这道检查时，SendInput 会打进用户当前正在用的编辑器/聊天框里。
    param([int64]$Handle = 0, [uint32]$ProcessId = 0, [string]$What = 'input')
    $fg = [int64][BctlNative]::GetForegroundWindow()
    if ($Handle -and $fg -eq $Handle) { return }
    # 同一浏览器进程的其它顶层窗口也算安全：翻译气泡、下载面板、权限提示
    # 都是独立 HWND，但按键仍然落在浏览器里，不会跑进用户别的软件。
    # 这里要拦的是「前台根本不是这个浏览器」，不是「不是那一个 HWND」。
    if ($ProcessId) {
        $wpid = [uint32]0
        [void][BctlNative]::GetWindowThreadProcessId([IntPtr]$fg, [ref]$wpid)
        if ($wpid -eq $ProcessId) { return }
    }
    throw ("refused to send ${What}: the target browser window is not in the foreground. " +
        'Bring it to the front first; otherwise the keystrokes would land in whatever app the user has focused. Nothing was sent.')
}

function Set-BctlForeground {
    # 返回 $true 才算真的把目标窗口调到了前台。所有调用方都必须检查返回值。
    param($Window)
    if (-not $Window) { return $false }
    $h = [IntPtr][int64]$Window.handle
    # 隐藏窗口不接受激活：SW_SHOW 会把它显示出来，等于凭空多一个浏览器窗口
    if (-not [BctlNative]::IsWindowVisible($h)) { return $false }
    # 夺前台本来就会被系统拦，一次不成很正常（另一个应用刚拿到焦点时尤甚），
    # 所以重试三次；仍然失败就明确返回 $false，让调用方停手而不是盲发按键。
    for ($i = 0; $i -lt 3; $i++) {
        $ok = $false
        try { $ok = [BctlNative]::ForceForeground($h) } catch { $ok = $false }
        Start-Sleep -Milliseconds 180
        if ($ok -or ([int64][BctlNative]::GetForegroundWindow() -eq [int64]$h)) { return $true }
    }
    return $false
}

function Invoke-BctlClick {
    param([int]$X, [int]$Y, [string]$Button = 'left', [int]$Count = 1)
    [void][BctlNative]::SetCursorPos($X, $Y)
    Start-Sleep -Milliseconds 80
    for ($i = 0; $i -lt $Count; $i++) {
        [BctlNative]::MouseDown($Button)
        Start-Sleep -Milliseconds 30
        [BctlNative]::MouseUp($Button)
        if ($Count -gt 1) { Start-Sleep -Milliseconds 60 }
    }
}

function Invoke-BctlDrag {
    param([int]$X1, [int]$Y1, [int]$X2, [int]$Y2, [string]$Button = 'left')
    [void][BctlNative]::SetCursorPos($X1, $Y1)
    Start-Sleep -Milliseconds 120
    [BctlNative]::MouseDown($Button)
    Start-Sleep -Milliseconds 120
    $steps = 20
    for ($i = 1; $i -le $steps; $i++) {
        $nx = [int]($X1 + ($X2 - $X1) * $i / $steps)
        $ny = [int]($Y1 + ($Y2 - $Y1) * $i / $steps)
        [void][BctlNative]::SetCursorPos($nx, $ny)
        Start-Sleep -Milliseconds 15
    }
    Start-Sleep -Milliseconds 100
    [BctlNative]::MouseUp($Button)
}

$script:VkMap = @{
    'CTRL' = 0x11; 'CONTROL' = 0x11; 'SHIFT' = 0x10; 'ALT' = 0x12; 'WIN' = 0x5B; 'LWIN' = 0x5B; 'RWIN' = 0x5C
    'ENTER' = 0x0D; 'RETURN' = 0x0D; 'ESC' = 0x1B; 'ESCAPE' = 0x1B; 'TAB' = 0x09; 'SPACE' = 0x20
    'BACKSPACE' = 0x08; 'BACK' = 0x08; 'DELETE' = 0x2E; 'DEL' = 0x2E; 'INSERT' = 0x2D; 'INS' = 0x2D
    'UP' = 0x26; 'DOWN' = 0x28; 'LEFT' = 0x25; 'RIGHT' = 0x27
    'HOME' = 0x24; 'END' = 0x23; 'PAGEUP' = 0x21; 'PAGEDOWN' = 0x22; 'PGUP' = 0x21; 'PGDN' = 0x22
    'PRTSC' = 0x2C; 'PAUSE' = 0x13; 'CAPSLOCK' = 0x14; 'NUMLOCK' = 0x90; 'SCROLLLOCK' = 0x91
    'MINUS' = 0xBD; 'PLUS' = 0xBB; 'COMMA' = 0xBC; 'PERIOD' = 0xBE; 'SLASH' = 0xBF
    'SEMICOLON' = 0xBA; 'QUOTE' = 0xDE; 'LBRACKET' = 0xDB; 'RBRACKET' = 0xDD; 'BACKSLASH' = 0xDC
    'GRAVE' = 0xC0; 'EQUAL' = 0xBB
}
foreach ($i in 1..24) { $script:VkMap['F' + $i] = 0x6F + $i }
foreach ($ch in [char[]]'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789') { $script:VkMap[$ch.ToString()] = [int]$ch }
foreach ($n in 0..9) { $script:VkMap['NUMPAD' + $n] = 0x60 + $n }

function Invoke-BctlKey {
    param([string]$Combo, [int64]$GuardHandle = 0, [uint32]$GuardPid = 0)
    $parts = $Combo.ToUpper() -split '\+'
    $vks = New-Object System.Collections.ArrayList
    foreach ($p in $parts) {
        $k = $p.Trim()
        if ($k -eq '') { continue }
        if ($script:VkMap.ContainsKey($k)) { $null = $vks.Add([uint16]$script:VkMap[$k]) }
        elseif ($k.Length -eq 1) { $null = $vks.Add([uint16][int][char]$k) }
        else { throw "unknown key: $k" }
    }
    if ($GuardHandle -or $GuardPid) {
        Assert-BctlFocus -Handle $GuardHandle -ProcessId $GuardPid -What ("keys '" + $Combo + "'")
    }
    foreach ($v in $vks) { [BctlNative]::KeyEvent($v, $false); Start-Sleep -Milliseconds 25 }
    for ($i = $vks.Count - 1; $i -ge 0; $i--) { [BctlNative]::KeyEvent($vks[$i], $true); Start-Sleep -Milliseconds 25 }
}

function Invoke-BctlType {
    param([string]$Text, [int64]$GuardHandle = 0, [uint32]$GuardPid = 0)
    if ($GuardHandle -or $GuardPid) {
        Assert-BctlFocus -Handle $GuardHandle -ProcessId $GuardPid -What 'text'
    }
    [BctlNative]::TypeUnicode($Text)
}

function Get-BctlScreenshot {
    param([string]$Path, [int]$X = 0, [int]$Y = 0, [int]$W = 0, [int]$H = 0, [switch]$Jpeg, [int]$Quality = 80)
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName System.Windows.Forms
    if ($W -le 0 -or $H -le 0) {
        $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $X = $vs.X; $Y = $vs.Y; $W = $vs.Width; $H = $vs.Height
    }
    # 4K 整屏 PNG 约 3MB，视觉模型读一次要好几百毫秒到数秒。同画面 JPEG 约 1/20。
    if (-not $Jpeg -and $Path -match '(?i)\.jpe?g$') { $Jpeg = $true }
    $bmp = New-Object System.Drawing.Bitmap $W, $H
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($X, $Y, 0, 0, $bmp.Size)
    $g.Dispose()
    if ($Jpeg) {
        $q = [Math]::Min([Math]::Max($Quality, 10), 100)
        $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' } | Select-Object -First 1
        $encParams = New-Object System.Drawing.Imaging.EncoderParameters 1
        $encParams.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter ([System.Drawing.Imaging.Encoder]::Quality, [int64]$q)
        $bmp.Save($Path, $codec, $encParams)
    }
    else {
        $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    $bmp.Dispose()
    return $Path
}

function Get-BctlPixel {
    # 读屏幕上一个点的颜色。比整屏截图便宜两个数量级——
    # 「按钮变蓝了吗」这类状态翻转只需要 1 个像素，不需要一张 3MB 的图。
    param([int]$X, [int]$Y)
    Add-Type -AssemblyName System.Drawing
    $bmp = New-Object System.Drawing.Bitmap 1, 1
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($X, $Y, 0, 0, (New-Object System.Drawing.Size 1, 1))
    $c = $bmp.GetPixel(0, 0)
    $g.Dispose()
    $bmp.Dispose()
    return [pscustomobject]@{
        x   = $X
        y   = $Y
        rgb = ('{0},{1},{2}' -f $c.R, $c.G, $c.B)
        hex = ('#{0:x2}{1:x2}{2:x2}' -f $c.R, $c.G, $c.B)
        r   = $c.R
        g   = $c.G
        b   = $c.B
    }
}

function Get-BctlElementAt {
    # 从坐标反查元素（UIA ElementFromPoint），向上一直给到页面根。
    # 用途：点击之前先证明这个坐标真的落在目标控件上，而不是点完再截图猜。
    param([int]$X, [int]$Y, [int]$Depth = 3, $PageRoot = $null)
    $pt = New-Object System.Windows.Point ([double]$X), ([double]$Y)
    $el = $script:AE::FromPoint($pt)
    if (-not $el) { return @() }
    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    $chain = New-Object System.Collections.ArrayList
    $cur = $el
    $i = 0
    while ($cur -and $i -le $Depth) {
        $info = Get-BctlElementInfo -Element $cur
        $inPage = $null
        if ($PageRoot) { $inPage = Test-BctlInPageTree -Element $cur -PageRoot $PageRoot }
        $info | Add-Member -NotePropertyName inPage -NotePropertyValue $inPage -Force
        $null = $chain.Add($info)
        try { $cur = $walker.GetParent($cur) } catch { break }
        $i++
    }
    return $chain.ToArray()
}

function Get-BctlBridgeHealth {
    # 桥的活性判定分两级：/ping 证明服务在，/stats 的 lastPollUtc 才证明
    # 「有页面在领任务」。没有客户端时立刻返回，别让调用方白等 20 秒。
    param([int]$Port = 8737, [int]$StaleSec = 5)
    $base = "http://127.0.0.1:$Port"
    $ping = $null
    try { $ping = Invoke-RestMethod -Uri "$base/ping" -TimeoutSec 2 } catch { }
    if (-not $ping) { return [pscustomobject]@{ running = $false; client = $false; port = $Port } }
    $stats = $null
    try { $stats = Invoke-RestMethod -Uri "$base/stats" -TimeoutSec 2 } catch { }
    $client = $false
    $age = $null
    if ($stats -and $stats.lastPollUtc) {
        try {
            $last = [datetime]::Parse([string]$stats.lastPollUtc, [System.Globalization.CultureInfo]::InvariantCulture)
            $age = [math]::Round(((Get-Date) - $last).TotalSeconds, 1)
            $client = ($age -le $StaleSec)
        }
        catch { }
    }
    return [pscustomobject]@{
        running     = $true
        client      = $client
        port        = $Port
        lastPollSec = $age
        pending     = $ping.pending
        stats       = $stats
    }
}
