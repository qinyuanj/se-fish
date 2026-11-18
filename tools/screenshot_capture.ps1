# 抓游戏/编辑器画面存 PNG。
#
# 两条通道：
#   后台（缺省）    PrintWindow + PW_RENDERFULLCONTENT 直接读窗口表面，目标窗口被遮挡也能取到当前帧
#   前台（-Screen） CopyFromScreen 读桌面合成，目标窗口必须在最前面；被盖住时抓到的是遮挡物
#
# 两种取景：
#   -Window <标题子串>  取标题包含该子串、面积最大的窗口（排除 WS_EX_LAYERED 辅助表面）
#                       省略或空串时自动选 client.exe 进程里面积最大的窗口（编辑器主窗口）
#   -Rect X,Y,W,H       直接给屏幕矩形，只能走前台通道
#
# -Info 不抓图，报告屏幕列表、目标窗口所在显示器与「虚拟屏 / 非虚拟屏 / 不确定」判定：
#   判据是该显示器适配器的枚举 ID 是否挂在 PCI 总线上（PCI\ 开头为真实显卡，其余为间接显示驱动）。
#
# 成功：RESULT=OK X,Y,W,H <窗口标题|rect> <bg|screen> <输出路径>
#      RESULT=OK INFO <判定>（-Info 模式，前面另有 INFO 行）
# 失败：RESULT=FAIL <错误码> <说明>（找不到窗口时附可见窗口标题），退出码 1
param(
  [string]$Out,
  [string]$Window,
  [string]$Rect,
  [switch]$Screen,
  [switch]$Auto,
  [switch]$Info
)
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class Sc {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr h, uint flags);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="GetMonitorInfoW")] public static extern bool GetMonitorInfoOf(IntPtr h, ref MONITORINFO mi);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="EnumDisplayDevicesW")] public static extern bool EnumAdapters(IntPtr dev, uint num, ref DISPLAY_DEVICE dd, uint flags);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int index);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
  [StructLayout(LayoutKind.Sequential)] public struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct DISPLAY_DEVICE {
    public int cb;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string DeviceName;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string DeviceString;
    public uint StateFlags;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string DeviceID;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string DeviceKey;
  }
}
"@

# PW_RENDERFULLCONTENT：让 PrintWindow 连同 DirectComposition / D3D 内容一起画出来。
$PW_RENDERFULLCONTENT = 2
$WS_EX_LAYERED = 0x00080000
$EDITOR_PROCESS = "client"   # 编辑器进程名（client.exe）

function Test-Layered([IntPtr]$h) {
  $ex = [int64][Sc]::GetWindowLong($h, -20)
  if ($ex -lt 0) { $ex = $ex + 4294967296 }
  return (($ex -band $WS_EX_LAYERED) -ne 0)
}

function Get-ProcessNameOf([IntPtr]$h) {
  $procId = [uint32]0
  [void][Sc]::GetWindowThreadProcessId($h, [ref]$procId)
  if ($procId -eq 0) { return "" }
  try { return (Get-Process -Id $procId -ErrorAction Stop).ProcessName } catch { return "" }
}

# 可见顶层窗口，按面积降序。排除最小化的、以及 WS_EX_LAYERED 辅助表面——
# Qt 的 Qt5QWindowToolSaveBits 这类窗口标题也叫 client，却什么都不画（#185）。
function Get-VisibleWindows {
  $script:found = @()
  $cb = {
    param($h, $l)
    if ([Sc]::IsWindowVisible($h) -and -not [Sc]::IsIconic($h) -and -not (Test-Layered $h)) {
      $sb = New-Object System.Text.StringBuilder 512
      [void][Sc]::GetWindowTextW($h, $sb, 512)
      $title = $sb.ToString()
      if ($title.Length -gt 0) {
        $r = New-Object Sc+RECT
        [void][Sc]::GetWindowRect($h, [ref]$r)
        $w = $r.Right - $r.Left
        $hh = $r.Bottom - $r.Top
        if ($w -ge 64 -and $hh -ge 64) {
          $script:found += [pscustomobject]@{
            hwnd = $h; title = $title; area = ($w * $hh); rect = $r; proc = (Get-ProcessNameOf $h)
          }
        }
      }
    }
    return $true
  }
  [void][Sc]::EnumWindows($cb, [IntPtr]::Zero)
  return @($script:found | Sort-Object -Property area -Descending)
}

# 选目标窗口。给了标题子串就按子串挑（仍排除 layered，取面积最大的一条）；
# 没给就在编辑器进程里挑面积最大的那个——试玩时游戏视口就在这颗窗口里。
function Select-Target($all, [string]$Pattern, [bool]$Auto) {
  if ($Pattern) {
    $hits = @($all | Where-Object { $_.title -like ("*" + $Pattern + "*") })
    if ($hits.Count -eq 0) { return $null }
    return $hits[0]
  }
  if (-not $Auto) { return $null }
  $editor = @($all | Where-Object { $_.proc -eq $EDITOR_PROCESS })
  if ($editor.Count -gt 0) { return $editor[0] }
  return $null
}

function Write-Result([string]$body) {
  Write-Output ("RESULT=" + $body)
}

# 适配器表：\\.\DISPLAY<n> → 适配器名 / 枚举 ID / 是否挂在桌面上。
function Get-AdapterMap {
  $map = @{}
  $i = 0
  while ($true) {
    $d = New-Object Sc+DISPLAY_DEVICE
    $d.cb = [System.Runtime.InteropServices.Marshal]::SizeOf($d)
    if (-not [Sc]::EnumAdapters([IntPtr]::Zero, [uint32]$i, [ref]$d, 0)) { break }
    $map[$d.DeviceName] = [pscustomobject]@{
      adapter   = $d.DeviceString
      adapterId = $d.DeviceID
      attached  = (($d.StateFlags -band 1) -eq 1)
    }
    $i++
  }
  return $map
}

function Get-Screens {
  Add-Type -AssemblyName System.Windows.Forms
  $list = @()
  foreach ($s in [System.Windows.Forms.Screen]::AllScreens) {
    $list += [pscustomobject]@{ device = $s.DeviceName; bounds = $s.Bounds; primary = $s.Primary }
  }
  return $list
}

function Get-WindowMonitorRect([IntPtr]$hwnd) {
  $mon = [Sc]::MonitorFromWindow($hwnd, 2)
  $mi = New-Object Sc+MONITORINFO
  $mi.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($mi)
  [void][Sc]::GetMonitorInfoOf($mon, [ref]$mi)
  return $mi.rcMonitor
}

function Get-ScreenOfRect($screens, $rc) {
  foreach ($s in $screens) {
    if ($s.bounds.Left -eq $rc.Left -and $s.bounds.Top -eq $rc.Top -and
        $s.bounds.Width -eq ($rc.Right - $rc.Left) -and $s.bounds.Height -eq ($rc.Bottom - $rc.Top)) {
      return $s
    }
  }
  $cx = [int](($rc.Left + $rc.Right) / 2)
  $cy = [int](($rc.Top + $rc.Bottom) / 2)
  foreach ($s in $screens) {
    if ($cx -ge $s.bounds.Left -and $cx -lt ($s.bounds.Left + $s.bounds.Width) -and
        $cy -ge $s.bounds.Top -and $cy -lt ($s.bounds.Top + $s.bounds.Height)) {
      return $s
    }
  }
  return $null
}

# 虚拟屏判定：适配器挂在 PCI 总线上的是真实显卡，其余（Idd/Share/USB 显示等）都按间接显示处理。
function Test-VirtualAdapterMap($adapters, $screen) {
  if (-not $screen) { return $null }
  $a = $adapters[$screen.device]
  if (-not $a -or [string]::IsNullOrWhiteSpace($a.adapterId)) { return $null }
  return -not $a.adapterId.StartsWith("PCI\")
}

# 后台通道：PrintWindow 直接读窗口表面，不需要窗口在最前面。
function Capture-Background([IntPtr]$hwnd, [string]$path) {
  $r = New-Object Sc+RECT
  [void][Sc]::GetWindowRect($hwnd, [ref]$r)
  $w = $r.Right - $r.Left
  $h = $r.Bottom - $r.Top
  if ($w -le 0 -or $h -le 0) { throw ("取景为空: " + $w + "x" + $h) }

  Add-Type -AssemblyName System.Drawing
  $bmp = New-Object System.Drawing.Bitmap $w, $h
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $hdc = $g.GetHdc()
  try {
    $ok = [Sc]::PrintWindow($hwnd, $hdc, $PW_RENDERFULLCONTENT)
  } finally {
    $g.ReleaseHdc($hdc)
    $g.Dispose()
  }
  if (-not $ok) { $bmp.Dispose(); throw "PrintWindow 拒绝了这颗窗口（可能已销毁或无渲染表面）" }
  $dir = Split-Path -Parent $path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
  return @{ x = $r.Left; y = $r.Top; w = $w; h = $h }
}

# 前台通道：桌面合成。被遮挡时抓到的是遮挡物，只能用于窗口确实在最前面的场合。
function Capture-Screen([int]$x0, [int]$y0, [int]$w, [int]$h, [string]$path) {
  if ($w -le 0 -or $h -le 0) { throw ("取景为空: " + $w + "x" + $h) }
  Add-Type -AssemblyName System.Drawing
  $bmp = New-Object System.Drawing.Bitmap $w, $h
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($x0, $y0, 0, 0, (New-Object System.Drawing.Size $w, $h))
  $g.Dispose()
  $dir = Split-Path -Parent $path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
}

if ($Info) {
  try {
    $adapters = Get-AdapterMap
    $screens = @(Get-Screens)
    if ($screens.Count -eq 0) { Write-Result "FAIL INFO_UNAVAILABLE 读不到屏幕列表"; exit 1 }

    foreach ($s in $screens) {
      $a = $adapters[$s.device]
      $name = if ($a) { $a.adapter } else { "未知" }
      $primary = if ($s.primary) { " 主屏" } else { "" }
      Write-Output ("INFO 屏幕 " + $s.device + " " + $s.bounds.X + "," + $s.bounds.Y + " " +
        $s.bounds.Width + "x" + $s.bounds.Height + $primary + " 适配器=" + $name)
    }

    $all = Get-VisibleWindows
    $target = Select-Target $all $Window $Auto.IsPresent
    $targetScreen = $null
    if ($target) {
      $rc = Get-WindowMonitorRect $target.hwnd
      $targetScreen = Get-ScreenOfRect $screens $rc
      $where = if ($targetScreen) { $targetScreen.device } else { "未知显示器" }
      $adapterName = if ($targetScreen -and $adapters[$targetScreen.device]) { $adapters[$targetScreen.device].adapter } else { "未知" }
      $w = $target.rect.Right - $target.rect.Left
      $hh = $target.rect.Bottom - $target.rect.Top
      Write-Output ("INFO 窗口 " + $target.title + " [" + $target.proc + " " + $w + "x" + $hh +
        "] 在 " + $where + " 适配器=" + $adapterName)
    } else {
      $seen = ($all | Select-Object -First 6 | ForEach-Object { $_.title + " [" + $_.proc + "]" }) -join " | "
      $who = if ($Window) { "标题包含「" + $Window + "」的" } else { "编辑器进程的" }
      Write-Output ("INFO 窗口 找不到" + $who + "窗口；当前可见窗口: " + $seen)
    }

    $isVirtual = Test-VirtualAdapterMap $adapters $targetScreen
    $verdict = "不确定"
    if ($isVirtual -eq $true) { $verdict = "虚拟屏" }
    elseif ($isVirtual -eq $false) { $verdict = "非虚拟屏" }
    Write-Output ("INFO 判定 " + $verdict)
    if ($target) {
      Write-Output "INFO 通道 缺省后台抓屏（PrintWindow），窗口被遮挡也能取到当前帧；判帧新旧仍要连拍比 md5（先锁尺寸）"
    } else {
      Write-Output "INFO 通道 找不到目标窗口：先用 --window 指定标题子串，或 --drag 把目标窗口显示出来"
    }
    Write-Result ("OK INFO " + $verdict)
    exit 0
  } catch {
    Write-Result ("FAIL INFO_FAILED " + $_.Exception.Message)
    exit 1
  }
}

try {
  if (-not $Out) { Write-Result "FAIL ARGUMENT_ERROR 需要 -Out"; exit 1 }
  if ([string]::IsNullOrEmpty($Window) -and -not $Rect -and -not $Auto) {
    Write-Result "FAIL ARGUMENT_ERROR 需要 -Auto、-Window 或 -Rect"; exit 1
  }

  if ($Rect) {
    $parts = $Rect -split ","
    if ($parts.Count -ne 4) { Write-Result "FAIL ARGUMENT_ERROR -Rect 需要 X,Y,W,H"; exit 1 }
    $x = [int]$parts[0]; $y = [int]$parts[1]; $w = [int]$parts[2]; $h = [int]$parts[3]
    Capture-Screen $x $y $w $h $Out
    Write-Result ("OK " + $x + "," + $y + "," + $w + "," + $h + " rect: " + $Rect + " screen " + $Out)
    exit 0
  }

  $all = Get-VisibleWindows
  $target = Select-Target $all $Window $Auto.IsPresent
  if (-not $target) {
    $seen = ($all | Select-Object -First 8 | Select-Object -ExpandProperty title) -join " | "
    $who = if ($Window) { "标题包含「" + $Window + "」的" } else { "编辑器进程（" + $EDITOR_PROCESS + ".exe）" }
    Write-Result ("FAIL WINDOW_NOT_FOUND 找不到" + $who + "可见窗口；当前可见窗口: " + $seen)
    exit 1
  }

  if ($Screen) {
    $cr = New-Object Sc+RECT
    [void][Sc]::GetClientRect($target.hwnd, [ref]$cr)
    $pt = New-Object Sc+POINT
    $pt.X = 0; $pt.Y = 0
    [void][Sc]::ClientToScreen($target.hwnd, [ref]$pt)
    $w = $cr.Right - $cr.Left
    $h = $cr.Bottom - $cr.Top
    Capture-Screen $pt.X $pt.Y $w $h $Out
    Write-Result ("OK " + $pt.X + "," + $pt.Y + "," + $w + "," + $h + " " + $target.title + " screen " + $Out)
  } else {
    $g = Capture-Background $target.hwnd $Out
    Write-Result ("OK " + $g.x + "," + $g.y + "," + $g.w + "," + $g.h + " " + $target.title + " bg " + $Out)
  }
  exit 0
} catch {
  Write-Result ("FAIL CAPTURE_FAILED " + $_.Exception.Message)
  exit 1
}
