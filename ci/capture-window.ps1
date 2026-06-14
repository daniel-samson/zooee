# Capture the client area of a window (by title pattern) to a BMP.
# Used by the e2e visual test on the self-hosted Windows runner (#13).
#
# Uses PrintWindow (PW_CLIENTONLY | PW_RENDERFULLCONTENT) rather than
# screen copy: the window renders its own contents into our bitmap, so
# the capture is immune to occlusion — SetForegroundWindow from another
# process routinely fails (foreground-lock), and a screen copy then
# photographs whatever window happens to cover that rect (this exact
# failure produced black 12,12,12 Windows Terminal pixels in CI).
#
# Must run in an interactive session — window enumeration sees nothing
# from session 0.
#
# -Maximize (#97): before capturing, maximize the window and let the
# present loop re-lay-out at the new size. The on-hardware resize guard:
# a swapchain that wasn't ResizeBuffers'd would stretch a stale frame or
# go blank, and the window would freeze/crash. Pair two runs (default +
# -Maximize) and assert the maximized client rect is strictly larger and
# still non-blank. The client size is written to "<OutFile>.size" (WxH)
# so the caller can compare across runs without parsing stdout.
param(
  [Parameter(Mandatory)][string]$TitlePattern,
  [string]$OutFile = "window.bmp",
  [switch]$Maximize
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class WinCap {
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
}
"@
$proc = $null
foreach ($attempt in 1..20) {
  $proc = Get-Process | Where-Object { $_.MainWindowTitle -like $TitlePattern } | Select-Object -First 1
  if ($proc) { break }
  Start-Sleep -Milliseconds 250
}
if (-not $proc) { Write-Error "window matching '$TitlePattern' not found"; exit 1 }
Start-Sleep -Milliseconds 500  # let the first paint land

if ($Maximize) {
  # 3 = SW_MAXIMIZE. Drives WM_SIZE through the real present loop so the
  # swapchain ResizeBuffers / re-layout path runs on actual hardware.
  [WinCap]::ShowWindow($proc.MainWindowHandle, 3) | Out-Null
  Start-Sleep -Milliseconds 800  # let the resize re-lay-out and present
}

$r = New-Object WinCap+RECT
[WinCap]::GetClientRect($proc.MainWindowHandle, [ref]$r) | Out-Null
$w = $r.R - $r.L; $h = $r.B - $r.T
if ($w -le 0 -or $h -le 0) { Write-Error "degenerate client rect ${w}x${h}"; exit 1 }

$bmp = New-Object System.Drawing.Bitmap $w, $h
$g = [System.Drawing.Graphics]::FromImage($bmp)
$hdc = $g.GetHdc()
# 1 = PW_CLIENTONLY, 2 = PW_RENDERFULLCONTENT (DWM-composed content)
$ok = [WinCap]::PrintWindow($proc.MainWindowHandle, $hdc, 3)
$g.ReleaseHdc($hdc)
if (-not $ok) { Write-Error "PrintWindow failed"; exit 1 }
$bmp.Save($OutFile, [System.Drawing.Imaging.ImageFormat]::Bmp)
$g.Dispose(); $bmp.Dispose()
Set-Content -Path "$OutFile.size" -Value "${w}x${h}" -NoNewline
Write-Host "captured client area ${w}x${h} -> $OutFile"
