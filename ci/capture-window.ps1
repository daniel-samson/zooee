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
param(
  [Parameter(Mandatory)][string]$TitlePattern,
  [string]$OutFile = "window.bmp"
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class WinCap {
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
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
Write-Host "captured client area ${w}x${h} -> $OutFile"
