# 抓桌面合成像素（CopyFromScreen）存 PNG；-Info 只报显示路径，不抓屏。
# 给虚拟屏用：UU 远程的 GameViewer Virtual Display Adapter 这类虚拟显示器上，3D 画面只存在于
# 桌面合成里，窗口表面抓取（PrintWindow）拿到的可能是黑帧，也可能是校验通过的旧帧。
#
# 两种取景：
#   -Window <标题子串>  取标题包含该子串、面积最大的可见顶层窗口的客户区
#   -Rect X,Y,W,H       直接给屏幕矩形
# 前置条件：目标窗口必须真的显示在屏幕上（被别的窗口盖住时抓到的是遮挡物）。
#
# -Info 不抓图，报告屏幕列表、目标窗口所在显示器与「虚拟屏 / 非虚拟屏 / 不确定」判定：
#   判据是该显示器适配器的枚举 ID 是否挂在 PCI 总线上（PCI\ 开头为真实显卡，其余为间接显示驱动）。
#
# 成功：RESULT=OK X,Y,W,H <窗口标题|rect> <输出路径>
#      RESULT=OK INFO <判定>（-Info 模式，前面另有 INFO 行）
# 失败：RESULT=FAIL <错误码> <说明>（找不到窗口时附可见窗口标题），退出码 1
param(
  [string]$Out,
  [string]$Window,
  [string]$Rect,
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

function Get-VisibleWindows {
  $script:found = @()
  $cb = {
    param($h, $l)
    if ([Sc]::IsWindowVisible($h) -and -not [Sc]::IsIconic($h)) {
      $sb = New-Object System.Text.StringBuilder 512
      [void][Sc]::GetWindowTextW($h, $sb, 512)
      $title = $sb.ToString()
      if ($title.Length -gt 0) {
        $r = New-Object Sc+RECT
        [void][Sc]::GetWindowRect($h, [ref]$r)
        $w = $r.Right - $r.Left
        $hh = $r.Bottom - $r.Top
        if ($w -ge 64 -and $hh -ge 64) {
          $script:found += [pscustomobject]@{ hwnd = $h; title = $title; area = ($w * $hh); rect = $r }
        }
      }
    }
    return $true
  }
  [void][Sc]::EnumWindows($cb, [IntPtr]::Zero)
  return @($script:found | Sort-Object -Property area -Descending)
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

    $targetScreen = $null
    if ($Window) {
      $all = Get-VisibleWindows
      $hits = @($all | Where-Object { $_.title -like ("*" + $Window + "*") })
      if ($hits.Count -eq 0) {
        $names = ($all | Select-Object -First 6 | ForEach-Object { $_.title }) -join " | "
        Write-Output ("INFO 窗口 没有标题包含「" + $Window + "」的可见窗口；当前可见窗口: " + $names)
      } else {
        $rc = Get-WindowMonitorRect $hits[0].hwnd
        $targetScreen = Get-ScreenOfRect $screens $rc
        $where = if ($targetScreen) { $targetScreen.device } else { "未知显示器" }
        $adapterName = if ($targetScreen -and $adapters[$targetScreen.device]) { $adapters[$targetScreen.device].adapter } else { "未知" }
        Write-Output ("INFO 窗口 " + $Window + " 命中「" + $hits[0].title + "」在 " + $where + " 适配器=" + $adapterName)
      }
    }

    $isVirtual = Test-VirtualAdapterMap $adapters $targetScreen
    $verdict = "不确定"
    if ($isVirtual -eq $true) { $verdict = "虚拟屏" }
    elseif ($isVirtual -eq $false) { $verdict = "非虚拟屏" }
    Write-Output ("INFO 判定 " + $verdict)
    if ($verdict -eq "虚拟屏") {
      Write-Output "INFO 通道 虚拟屏上 editor-cli screenshot 取不到新内容，改用 lua tools/cli.lua screenshot"
    } elseif ($verdict -eq "非虚拟屏") {
      Write-Output "INFO 通道 editor-cli screenshot 可用；判帧新旧要连拍比 md5（先锁尺寸）"
    } else {
      Write-Output "INFO 通道 判不出显示路径：先让目标窗口出现在屏幕上再跑一次，或直接连拍验证"
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
  if (-not $Window -and -not $Rect) { Write-Result "FAIL ARGUMENT_ERROR 需要 -Window 或 -Rect"; exit 1 }

  $x = 0; $y = 0; $w = 0; $h = 0; $label = ""

  if ($Rect) {
    $parts = $Rect -split ","
    if ($parts.Count -ne 4) { Write-Result "FAIL ARGUMENT_ERROR -Rect 需要 X,Y,W,H"; exit 1 }
    $x = [int]$parts[0]; $y = [int]$parts[1]; $w = [int]$parts[2]; $h = [int]$parts[3]
    $label = "rect:" + $Rect
  } else {
    $all = Get-VisibleWindows
    $hits = @($all | Where-Object { $_.title -like ("*" + $Window + "*") })
    if ($hits.Count -eq 0) {
      $names = ($all | Select-Object -First 8 | ForEach-Object { $_.title }) -join " | "
      Write-Result ("FAIL WINDOW_NOT_FOUND 没有标题包含「" + $Window + "」的可见窗口；当前可见窗口: " + $names)
      exit 1
    }
    $target = $hits[0]
    $cr = New-Object Sc+RECT
    [void][Sc]::GetClientRect($target.hwnd, [ref]$cr)
    $pt = New-Object Sc+POINT
    $pt.X = 0; $pt.Y = 0
    [void][Sc]::ClientToScreen($target.hwnd, [ref]$pt)
    $x = $pt.X
    $y = $pt.Y
    $w = $cr.Right - $cr.Left
    $h = $cr.Bottom - $cr.Top
    $label = $target.title
  }

  if ($w -le 0 -or $h -le 0) { Write-Result ("FAIL WINDOW_NOT_FOUND 取景为空: " + $w + "x" + $h); exit 1 }

  Add-Type -AssemblyName System.Drawing
  $bmp = New-Object System.Drawing.Bitmap $w, $h
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($x, $y, 0, 0, (New-Object System.Drawing.Size $w, $h))
  $g.Dispose()
  $dir = Split-Path -Parent $Out
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()

  Write-Result ("OK " + $x + "," + $y + "," + $w + "," + $h + " " + $label + " " + $Out)
} catch {
  Write-Result ("FAIL CAPTURE_FAILED " + $_.Exception.Message)
  exit 1
}
