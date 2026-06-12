# Capture the client area of a window (by title pattern) to a BMP.
# Used by the e2e visual test on the self-hosted Windows runner (#13).
# Must run in an interactive session — window enumeration and screen
# capture see nothing from session 0.
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
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
}
"@
$proc = $null
foreach ($attempt in 1..20) {
  $proc = Get-Process | Where-Object { $_.MainWindowTitle -like $TitlePattern } | Select-Object -First 1
  if ($proc) { break }
  Start-Sleep -Milliseconds 250
}
if (-not $proc) { Write-Error "window matching '$TitlePattern' not found"; exit 1 }

[WinCap]::SetForegroundWindow($proc.MainWindowHandle) | Out-Null
Start-Sleep -Milliseconds 500

$r = New-Object WinCap+RECT
[WinCap]::GetClientRect($proc.MainWindowHandle, [ref]$r) | Out-Null
$origin = New-Object WinCap+POINT
[WinCap]::ClientToScreen($proc.MainWindowHandle, [ref]$origin) | Out-Null
$w = $r.R - $r.L; $h = $r.B - $r.T
if ($w -le 0 -or $h -le 0) { Write-Error "degenerate client rect ${w}x${h}"; exit 1 }

$bmp = New-Object System.Drawing.Bitmap $w, $h
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($origin.X, $origin.Y, 0, 0, (New-Object System.Drawing.Size $w, $h))
$bmp.Save($OutFile, [System.Drawing.Imaging.ImageFormat]::Bmp)
$g.Dispose(); $bmp.Dispose()
Write-Host "captured client area ${w}x${h} -> $OutFile"
