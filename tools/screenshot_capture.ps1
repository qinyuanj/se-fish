# 抓桌面合成像素（CopyFromScreen）存 PNG。给虚拟屏用：UU 远程的 GameViewer Virtual Display Adapter
# 这类虚拟显示器上，3D 画面只存在于桌面合成里，窗口表面抓取（PrintWindow）拿到的永远是黑帧。
#
# 两种取景：
#   -Window <标题子串>  取标题包含该子串、面积最大的可见顶层窗口的客户区
#   -Rect X,Y,W,H       直接给屏幕矩形
# 前置条件：目标窗口必须真的显示在屏幕上（被别的窗口盖住时抓到的是遮挡物）。
#
# 成功：RESULT=OK X,Y,W,H <窗口标题|rect> <输出路径>
# 失败：RESULT=FAIL <错误码> <说明>（找不到窗口时附可见窗口标题），退出码 1
param(
  [Parameter(Mandatory=$true)][string]$Out,
  [string]$Window,
  [string]$Rect
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
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
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
          $script:found += [pscustomobject]@{ hwnd = $h; title = $title; area = ($w * $hh) }
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

try {
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