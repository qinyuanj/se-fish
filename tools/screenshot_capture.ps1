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
#   -Hwnd <十进制句柄>  按精确句柄取一个窗口（本地多人测试的多客户端窗口，ADR-0044）
#
# 候选窗口：-Window 给标题子串时为标题命中的窗口，-Auto 时为 client.exe 的窗口；
#   顺序固定为 pid 升序、面积降序、句柄升序，-List 的序号与 -All 的 {n} 一一对应。
# -List 不抓图，逐个输出 WIN <hwnd> <pid> X,Y,W,H <进程名|?> <标题>，最后 RESULT=OK LIST <个数>。
# -All 按候选顺序逐个抓，-Out 里的 {n} 换成序号；每张输出一行 SHOT=OK ...（格式同单张成功行），
#   最后 RESULT=OK ALL <张数>；任何一张失败即 RESULT=FAIL 并停。
# -Info 不抓图，报告屏幕列表、目标窗口所在显示器、候选窗口数与「虚拟屏 / 非虚拟屏 / 不确定」判定：
#   判据是该显示器适配器的枚举 ID 是否挂在 PCI 总线上（PCI\ 开头为真实显卡，其余为间接显示驱动）。
#
# 成功：RESULT=OK X,Y,W,H <窗口标题|rect> <bg|screen> <输出路径>
#      RESULT=OK INFO <判定>（-Info 模式，前面另有 INFO 行）
# 失败：RESULT=FAIL <错误码> <说明>（找不到窗口时附可见窗口标题），退出码 1
param(
  [string]$Out,
  [string]$Window,
  [string]$Rect,
  [string]$Hwnd,
  [switch]$Screen,
  [switch]$Auto,
  [switch]$Info,
  [switch]$List,
  [switch]$All
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
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
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

function Get-WindowTitle([IntPtr]$h) {
  $sb = New-Object System.Text.StringBuilder 512
  [void][Sc]::GetWindowTextW($h, $sb, 512)
  return ($sb.ToString() -replace "[\r\n]+", " ")
}

# 窗口记录：句柄、标题、矩形、面积、所属进程 id 与进程名（取不到进程名时为空串）。
function New-WindowRecord([IntPtr]$h, [string]$title) {
  $r = New-Object Sc+RECT
  [void][Sc]::GetWindowRect($h, [ref]$r)
  $procId = [uint32]0
  [void][Sc]::GetWindowThreadProcessId($h, [ref]$procId)
  $name = ""
  if ($procId -ne 0) {
    try { $name = (Get-Process -Id $procId -ErrorAction Stop).ProcessName } catch { $name = "" }
  }
  return [pscustomobject]@{
    hwnd = $h; title = $title; rect = $r; pid = $procId; proc = $name
    area = ([int64]($r.Right - $r.Left) * ($r.Bottom - $r.Top))
  }
}

# 可见顶层窗口，按面积降序。排除最小化的、以及 WS_EX_LAYERED 辅助表面——
# Qt 的 Qt5QWindowToolSaveBits 这类窗口标题也叫 client，却什么都不画（#185）。
function Get-VisibleWindows {
  $script:found = @()
  $cb = {
    param($h, $l)
    if ([Sc]::IsWindowVisible($h) -and -not [Sc]::IsIconic($h) -and -not (Test-Layered $h)) {
      $title = Get-WindowTitle $h
      if ($title.Length -gt 0) {
        $rec = New-WindowRecord $h $title
        if (($rec.rect.Right - $rec.rect.Left) -ge 64 -and ($rec.rect.Bottom - $rec.rect.Top) -ge 64) {
          $script:found += $rec
        }
      }
    }
    return $true
  }
  [void][Sc]::EnumWindows($cb, [IntPtr]::Zero)
  return @($script:found | Sort-Object -Property area -Descending)
}

# 候选窗口：给了标题子串为标题命中的窗口，否则（-Auto）为编辑器进程的窗口。
# 返回顺序固定：pid 升序（编辑器与各客户端按启动先后）、面积降序、句柄升序。
function Get-Candidates($wins, [string]$Pattern, [bool]$Auto) {
  if ($Pattern) {
    $hits = @($wins | Where-Object { $_.title -like ("*" + $Pattern + "*") })
  } elseif ($Auto) {
    $hits = @($wins | Where-Object { $_.proc -eq $EDITOR_PROCESS })
  } else {
    return @()
  }
  return @($hits | Sort-Object -Property @{ Expression = { [int64]$_.pid } },
    @{ Expression = { $_.area }; Descending = $true },
    @{ Expression = { $_.hwnd.ToInt64() } })
}

# 选目标窗口。给了标题子串就按子串挑（仍排除 layered，取面积最大的一条）；
# 没给就在编辑器进程里挑面积最大的那个——试玩时游戏视口就在这颗窗口里。
# $wins 已按面积降序，过滤后取第一条即面积最大。
function Select-Target($wins, [string]$Pattern, [bool]$Auto) {
  if ($Pattern) {
    $hits = @($wins | Where-Object { $_.title -like ("*" + $Pattern + "*") })
    if ($hits.Count -eq 0) { return $null }
    return $hits[0]
  }
  if (-not $Auto) { return $null }
  $editor = @($wins | Where-Object { $_.proc -eq $EDITOR_PROCESS })
  if ($editor.Count -gt 0) { return $editor[0] }
  return $null
}

# 按精确句柄取窗口记录；句柄无效或窗口已最小化时抛错。
function Get-WindowByHandle([string]$text) {
  $value = [int64]0
  if (-not [int64]::TryParse($text, [ref]$value) -or $value -le 0) { throw ("-Hwnd 需要正的十进制句柄: " + $text) }
  $h = [IntPtr]::new($value)
  if (-not [Sc]::IsWindow($h)) { throw ("句柄 " + $text + " 不是现存窗口（窗口可能已关闭，先用 --list 重新枚举）") }
  if ([Sc]::IsIconic($h)) { throw ("句柄 " + $text + " 的窗口已最小化，PrintWindow 取不到画面；先还原窗口") }
  $title = Get-WindowTitle $h
  $rec = New-WindowRecord $h $title
  if (-not $title) { $rec.title = ("hwnd=0x{0:X}" -f $value) }
  return $rec
}

# 抓一个窗口：-Screen 走桌面合成取客户区，缺省后台抓整窗。返回单张成功行的正文（不含 RESULT=）。
function Capture-Target($target, [string]$path) {
  if ($Screen) {
    $cr = New-Object Sc+RECT
    [void][Sc]::GetClientRect($target.hwnd, [ref]$cr)
    $pt = New-Object Sc+POINT
    $pt.X = 0; $pt.Y = 0
    [void][Sc]::ClientToScreen($target.hwnd, [ref]$pt)
    $w = $cr.Right - $cr.Left
    $h = $cr.Bottom - $cr.Top
    Capture-Screen $pt.X $pt.Y $w $h $path
    return ("OK " + $pt.X + "," + $pt.Y + "," + $w + "," + $h + " " + $target.title + " screen " + $path)
  }
  $g = Capture-Background $target.hwnd $path
  return ("OK " + $g.x + "," + $g.y + "," + $g.w + "," + $g.h + " " + $target.title + " bg " + $path)
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
  $screenList = @()
  foreach ($s in [System.Windows.Forms.Screen]::AllScreens) {
    $screenList += [pscustomobject]@{ device = $s.DeviceName; bounds = $s.Bounds; primary = $s.Primary }
  }
  return $screenList
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

    $wins = Get-VisibleWindows
    $target = Select-Target $wins $Window $Auto.IsPresent
    $targetScreen = $null
    if ($target) {
      $rc = Get-WindowMonitorRect $target.hwnd
      $targetScreen = Get-ScreenOfRect $screens $rc
      $where = if ($targetScreen) { $targetScreen.device } else { "未知显示器" }
      $adapterName = if ($targetScreen -and $adapters[$targetScreen.device]) { $adapters[$targetScreen.device].adapter } else { "未知" }
      $w = $target.rect.Right - $target.rect.Left
      $hh = $target.rect.Bottom - $target.rect.Top
      Write-Output ("INFO 窗口 " + $target.title + " [" + $target.proc + " pid=" + $target.pid + " hwnd=0x" +
        ("{0:X}" -f $target.hwnd.ToInt64()) + " " + $w + "x" + $hh + "] 在 " + $where + " 适配器=" + $adapterName)
    } else {
      $seen = ($wins | Select-Object -First 6 | ForEach-Object { $_.title + " [" + $_.proc + "]" }) -join " | "
      $who = if ($Window) { "标题包含「" + $Window + "」的" } else { "编辑器进程的" }
      Write-Output ("INFO 窗口 找不到" + $who + "窗口；当前可见窗口: " + $seen)
    }
    $candidates = @(Get-Candidates $wins $Window $Auto.IsPresent)
    Write-Output ("INFO 候选 " + $candidates.Count + " 个匹配窗口")
    if ($candidates.Count -gt 1) {
      Write-Output ("INFO 提示 匹配到多个窗口（本地多人测试会开多个客户端），缺省只抓面积最大的一个；" +
        "--list 列出全部、--all 全部抓取、--hwnd <句柄> 精确抓取")
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

if ($List) {
  try {
    $candidates = @(Get-Candidates (Get-VisibleWindows) $Window $Auto.IsPresent)
    foreach ($c in $candidates) {
      $r = $c.rect
      $proc = if ($c.proc) { $c.proc } else { "?" }
      Write-Output ("WIN " + $c.hwnd.ToInt64() + " " + $c.pid + " " + $r.Left + "," + $r.Top + "," +
        ($r.Right - $r.Left) + "," + ($r.Bottom - $r.Top) + " " + $proc + " " + $c.title)
    }
    Write-Result ("OK LIST " + $candidates.Count)
    exit 0
  } catch {
    Write-Result ("FAIL LIST_FAILED " + $_.Exception.Message)
    exit 1
  }
}

function Write-NotFound($wins) {
  $seen = ($wins | Select-Object -First 8 | Select-Object -ExpandProperty title) -join " | "
  $who = if ($Window) { "标题包含「" + $Window + "」的" } else { "编辑器进程（" + $EDITOR_PROCESS + ".exe）" }
  Write-Result ("FAIL WINDOW_NOT_FOUND 找不到" + $who + "可见窗口；当前可见窗口: " + $seen)
}

try {
  if (-not $Out) { Write-Result "FAIL ARGUMENT_ERROR 需要 -Out"; exit 1 }
  if ([string]::IsNullOrEmpty($Window) -and -not $Rect -and -not $Auto -and -not $Hwnd) {
    Write-Result "FAIL ARGUMENT_ERROR 需要 -Auto、-Window、-Hwnd 或 -Rect"; exit 1
  }

  if ($Rect) {
    $parts = $Rect -split ","
    if ($parts.Count -ne 4) { Write-Result "FAIL ARGUMENT_ERROR -Rect 需要 X,Y,W,H"; exit 1 }
    $x = [int]$parts[0]; $y = [int]$parts[1]; $w = [int]$parts[2]; $h = [int]$parts[3]
    Capture-Screen $x $y $w $h $Out
    Write-Result ("OK " + $x + "," + $y + "," + $w + "," + $h + " rect: " + $Rect + " screen " + $Out)
    exit 0
  }

  if ($All) {
    $wins = Get-VisibleWindows
    $candidates = @(Get-Candidates $wins $Window $Auto.IsPresent)
    if ($candidates.Count -eq 0) { Write-NotFound $wins; exit 1 }
    $i = 0
    foreach ($c in $candidates) {
      $i++
      try {
        $path = $Out.Replace("{n}", [string]$i)
        Write-Output ("SHOT=" + (Capture-Target $c $path))
      } catch {
        Write-Result ("FAIL CAPTURE_FAILED 第 " + $i + " 个窗口（" + $c.title + "）: " + $_.Exception.Message)
        exit 1
      }
    }
    Write-Result ("OK ALL " + $i)
    exit 0
  }

  if ($Hwnd) {
    $target = Get-WindowByHandle $Hwnd
  } else {
    $wins = Get-VisibleWindows
    $target = Select-Target $wins $Window $Auto.IsPresent
    if (-not $target) { Write-NotFound $wins; exit 1 }
  }
  Write-Result (Capture-Target $target $Out)
  exit 0
} catch {
  Write-Result ("FAIL CAPTURE_FAILED " + $_.Exception.Message)
  exit 1
}

