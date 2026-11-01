# BctlLib.ps1 - core library for dsh-browser-bridge
# Pure PowerShell 5.1 + .NET Framework. No external dependency.
# Dot-source this file, then call the exported functions.

$script:BctlVersion = '1.0.0'
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

    public static void ForceForeground(IntPtr h) {
        if (IsIconic(h)) ShowWindow(h, 9);
        IntPtr fg = GetForegroundWindow();
        uint pid;
        uint ft = GetWindowThreadProcessId(fg, out pid);
        uint ct = GetCurrentThreadId();
        bool attached = AttachThreadInput(ct, ft, true);
        keybd_event(0x12, 0, 0, IntPtr.Zero);
        keybd_event(0x12, 0, 2, IntPtr.Zero);
        SetForegroundWindow(h);
        ShowWindow(h, 5);
        if (attached) AttachThreadInput(ct, ft, false);
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
    Add-Type -TypeDefinition $cs -Language CSharp
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
function Get-BctlBinding {
    # Browser process families we can drive through UIA (Chromium exposes
    # ClassName 'Chrome_WidgetWin_1'; Gecko is handled through the plain HWND).
    $browsers = @('chrome', 'msedge', 'brave', 'vivaldi', 'opera', 'thorium', 'chromium', 'Arc', 'firefox')
    $map = @{}
    foreach ($p in Get-Process -ErrorAction SilentlyContinue) {
        if ($browsers -contains $p.ProcessName) {
            $map[[uint32]$p.Id] = @{
                pid    = [uint32]$p.Id
                name   = $p.ProcessName
                handle = $p.MainWindowHandle
                title  = $p.MainWindowTitle
            }
        }
    }
    return $map
}

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
    # 同一个进程往往有多个顶层窗口（工具提示、隐藏的辅助窗口、真实窗口框架）。
    # 必须挑「面积最大的那个窗口」，否则会绑到 146x21 的 helper 上，
    # 截图/导航/无障碍查询全部落到错误的窗口，上层就会以为浏览器坏了。
    param([string]$Spec, [switch]$AllowHidden)
    $all = Get-BctlWindows -IncludeHidden:$AllowHidden
    if ($Spec -match '^\d+$') {
        $cands = @($all | Where-Object { $_.pid -eq [uint32]$Spec -and $_.w -ge 300 -and $_.h -ge 200 })
        if ($cands.Count -eq 0) { $cands = @($all | Where-Object { $_.pid -eq [uint32]$Spec }) }
        if ($cands.Count -eq 0) { return $null }
        return ($cands | Sort-Object -Property @{ Expression = { [int64]$_.w * [int64]$_.h }; Descending = $true } | Select-Object -First 1)
    }
    $cands = @($all | Where-Object { $_.title -like "*$Spec*" -and $_.w -ge 300 -and $_.h -ge 200 })
    if ($cands.Count -eq 0) { $cands = @($all | Where-Object { $_.title -like "*$Spec*" }) }
    if ($cands.Count -eq 0) { return $null }
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
        cx           = $(if ($x -lt 0 -or $w -lt 0) { -1 } else { $x + [int]($w / 2) })
        cy           = $(if ($y -lt 0 -or $h -lt 0) { -1 } else { $y + [int]($h / 2) })
        enabled      = $c.IsEnabled
        offscreen    = $c.IsOffscreen
    }
}

function Find-BctlElement {
    param(
        [uint32]$ProcessId,
        [string]$Name,
        [string]$Type
    )
    $root = Get-BctlUiaRoot -ProcessId $ProcessId
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
    param([uint32]$ProcessId, [string]$Pattern, [string]$Type, [int]$Limit = 200)
    $root = Get-BctlUiaRoot -ProcessId $ProcessId
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

function Get-BctlDocument {
    param([uint32]$ProcessId)
    $root = Get-BctlUiaRoot -ProcessId $ProcessId
    if (-not $root) { return $null }
    $c = New-Object System.Windows.Automation.PropertyCondition($script:AE::ControlTypeProperty, $script:CT::Document)
    return $root.FindFirst($script:TS::Descendants, $c)
}

# ---------------------------------------------------------------- actions
function Set-BctlForeground {
    param($Window)
    [void][BctlNative]::ForceForeground([IntPtr]$Window.handle)
    Start-Sleep -Milliseconds 250
    return [BctlNative]::GetForegroundWindow() -eq [IntPtr]$Window.handle
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
    param([string]$Combo)
    $parts = $Combo.ToUpper() -split '\+'
    $vks = New-Object System.Collections.ArrayList
    foreach ($p in $parts) {
        $k = $p.Trim()
        if ($k -eq '') { continue }
        if ($script:VkMap.ContainsKey($k)) { $null = $vks.Add([uint16]$script:VkMap[$k]) }
        elseif ($k.Length -eq 1) { $null = $vks.Add([uint16][int][char]$k) }
        else { throw "unknown key: $k" }
    }
    foreach ($v in $vks) { [BctlNative]::KeyEvent($v, $false); Start-Sleep -Milliseconds 25 }
    for ($i = $vks.Count - 1; $i -ge 0; $i--) { [BctlNative]::KeyEvent($vks[$i], $true); Start-Sleep -Milliseconds 25 }
}

function Invoke-BctlType {
    param([string]$Text)
    [BctlNative]::TypeUnicode($Text)
}

function Get-BctlScreenshot {
    param([string]$Path, [int]$X = 0, [int]$Y = 0, [int]$W = 0, [int]$H = 0)
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName System.Windows.Forms
    if ($W -le 0 -or $H -le 0) {
        $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $X = $vs.X; $Y = $vs.Y; $W = $vs.Width; $H = $vs.Height
    }
    $bmp = New-Object System.Drawing.Bitmap $W, $H
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($X, $Y, 0, 0, $bmp.Size)
    $g.Dispose()
    $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    return $Path
}
