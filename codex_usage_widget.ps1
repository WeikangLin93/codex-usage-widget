Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# 修复 WinForms 事件线程偶发“无可用 Runspace”异常
$script:MainRunspace = $Host.Runspace
[System.Management.Automation.Runspaces.Runspace]::DefaultRunspace = $script:MainRunspace

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class Win32 {
  [StructLayout(LayoutKind.Sequential)]
  public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
  public struct MONITORINFO {
    public int cbSize;
    public RECT rcMonitor;
    public RECT rcWork;
    public uint dwFlags;
  }

  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
  [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint dwFlags);
  [DllImport("user32.dll", CharSet = CharSet.Auto)] public static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFO lpmi);
}
"@

function Get-AppDataDir {
  $base = [Environment]::GetFolderPath("LocalApplicationData")
  if (-not $base) { $base = [Environment]::GetFolderPath("ApplicationData") }
  if (-not $base) { $base = $PSScriptRoot }
  $dir = Join-Path $base "CodexUsageWidget"
  if (-not (Test-Path $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
  return $dir
}

$appDataDir = Get-AppDataDir
$configPath = Join-Path $appDataDir "widget_config.json"
$legacyConfigPath = Join-Path $PSScriptRoot "widget_config.json"
$defaultConfig = @{
  opacity = 0.90
  layer_mode = "topmost"
  game_mode_enabled = $true
  manual_visibility = "none"   # none|force_hide|force_show
}

function Merge-Config($base, $incoming) {
  $m = @{}
  foreach ($k in $base.Keys) { $m[$k] = $base[$k] }
  if ($incoming) {
    foreach ($p in $incoming.PSObject.Properties.Name) {
      $m[$p] = $incoming.$p
    }
  }
  return $m
}

function Load-Config {
  if ((-not (Test-Path $configPath)) -and (Test-Path $legacyConfigPath)) {
    try { Copy-Item -Path $legacyConfigPath -Destination $configPath -Force } catch {}
  }
  if (Test-Path $configPath) {
    try {
      $obj = Get-Content $configPath -Raw | ConvertFrom-Json
      $cfg = Merge-Config $defaultConfig $obj
      return @{
        opacity = [double]$cfg.opacity
        layer_mode = [string]$cfg.layer_mode
        game_mode_enabled = [bool]$cfg.game_mode_enabled
        manual_visibility = [string]$cfg.manual_visibility
      }
    } catch {}
  }
  return $defaultConfig.Clone()
}

function Save-Config($cfg) {
  $cfg | ConvertTo-Json | Set-Content -Path $configPath -Encoding UTF8
}

function Get-TaskbarLikeColor {
  try {
    $v = Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" -Name SystemUsesLightTheme -ErrorAction Stop
    if ([int]$v.SystemUsesLightTheme -eq 0) {
      return [System.Drawing.Color]::FromArgb(32,32,32)
    } else {
      return [System.Drawing.Color]::FromArgb(242,242,242)
    }
  } catch {
    return [System.Drawing.Color]::FromArgb(32,32,32)
  }
}

$script:cfg = Load-Config
$script:usage = @{
  ok = $false
  from_cache = $false
  error_kind = ""
  plan = "unknown"
  allowed = $false
  limit_reached = $false
  primary = @{ used = 0; left = 100; reset_seconds = 0 }
  secondary = @{ used = 0; left = 100; reset_seconds = 0 }
  error = ""
  ts = 0
}
$script:hovering = $false
$script:lastAutoFullscreen = $false
$script:pendingRestoreAt = $null
$script:refreshJob = $null
$script:nextRefreshAt = Get-Date
$script:isRefreshing = $false

function Format-Remaining([int]$seconds) {
  if ($seconds -lt 0) { $seconds = 0 }
  $d = [math]::Floor($seconds / 86400)
  $h = [math]::Floor(($seconds % 86400) / 3600)
  $m = [math]::Floor(($seconds % 3600) / 60)
  if ($d -gt 0) { return "${d}天${h}小时" }
  return "${h}小时${m}分钟"
}

function Set-LayerMode([string]$mode) {
  if ($mode -eq "topmost") {
    $form.TopMost = $true
  } else {
    $form.TopMost = $false
  }
  $script:cfg.layer_mode = $mode
  Save-Config $script:cfg
}

function Set-OpacityValue([double]$val) {
  $v = [Math]::Min(1.0, [Math]::Max(0.20, $val))
  $form.Opacity = $v
  $script:cfg.opacity = $v
  Save-Config $script:cfg
}

function Start-UsageRefresh {
  if ($script:refreshJob -and $script:refreshJob.State -eq "Running") { return }
  if ($script:refreshJob) {
    try { Remove-Job -Job $script:refreshJob -Force -ErrorAction SilentlyContinue } catch {}
    $script:refreshJob = $null
  }

  $fetchExe = Join-Path $PSScriptRoot "tools\codex_usage_fetch.exe"
  $fetchScript = Join-Path $PSScriptRoot "codex_usage_fetch.py"
  $script:isRefreshing = $true
  Update-NotifyText
  $form.Invalidate()

  $script:refreshJob = Start-Job -ArgumentList $fetchExe, $fetchScript -ScriptBlock {
    param($exePath, $scriptPath)
    if (Test-Path $exePath) {
      & $exePath 2>$null
    } else {
      $py = Get-Command py -ErrorAction SilentlyContinue
      if ($py) {
        & py -3 $scriptPath 2>$null
      } else {
        & python $scriptPath 2>$null
      }
    }
  }
}

function Complete-UsageRefresh {
  if (-not $script:refreshJob) { return }
  if ($script:refreshJob.State -eq "Running") { return }

  try {
    $json = Receive-Job -Job $script:refreshJob -ErrorAction Stop
    if (-not $json) { throw "Python 没有返回数据" }
    $obj = ($json | Select-Object -Last 1) | ConvertFrom-Json
    if ($obj) { $script:usage = $obj }
  } catch {
    $script:usage.ok = $false
    $script:usage.error = $_.Exception.Message
    $script:usage.error_kind = "widget"
  } finally {
    try { Remove-Job -Job $script:refreshJob -Force -ErrorAction SilentlyContinue } catch {}
    $script:refreshJob = $null
    $script:isRefreshing = $false
    $script:nextRefreshAt = (Get-Date).AddSeconds(60)
  }

  Update-NotifyText
  $form.Invalidate()
}

function Get-GameModeText {
  if (-not $script:cfg.game_mode_enabled) { return "OFF" }
  switch ($script:cfg.manual_visibility) {
    "force_hide" { return "MANUAL-HIDE" }
    "force_show" { return "MANUAL-SHOW" }
    default { return "AUTO" }
  }
}

function Update-NotifyText {
  $mode = Get-GameModeText
  $status = if ($script:isRefreshing) { "刷新中" } elseif ($script:usage.ok) { if ($script:usage.from_cache) { "缓存" } else { "正常" } } else { "异常" }
  $notify.Text = "Codex用量 [$mode/$status] 5h:$([int]$script:usage.primary.used)% 7d:$([int]$script:usage.secondary.used)%"
}

function Is-ForegroundFullscreen {
  try {
    $hwnd = [Win32]::GetForegroundWindow()
    if ($hwnd -eq [IntPtr]::Zero) { return $false }

    $rect = New-Object Win32+RECT
    if (-not [Win32]::GetWindowRect($hwnd, [ref]$rect)) { return $false }

    $hmon = [Win32]::MonitorFromWindow($hwnd, 2)
    if ($hmon -eq [IntPtr]::Zero) { return $false }

    $mi = New-Object Win32+MONITORINFO
    $mi.cbSize = [Runtime.InteropServices.Marshal]::SizeOf([type]"Win32+MONITORINFO")
    if (-not [Win32]::GetMonitorInfo($hmon, [ref]$mi)) { return $false }

    $w = $rect.Right - $rect.Left
    $h = $rect.Bottom - $rect.Top
    $mw = $mi.rcMonitor.Right - $mi.rcMonitor.Left
    $mh = $mi.rcMonitor.Bottom - $mi.rcMonitor.Top

    # 更严格判定：接近“整屏显示”才算全屏，避免把普通最大化窗口误判成游戏全屏
    $sizeMatch = ($w -ge ($mw - 8) -and $h -ge ($mh - 8))
    $posMatch = ([Math]::Abs($rect.Left - $mi.rcMonitor.Left) -le 8 -and [Math]::Abs($rect.Top - $mi.rcMonitor.Top) -le 8)
    return ($sizeMatch -and $posMatch)
  } catch {
    return $false
  }
}

function Apply-VisibilityPolicy {
  $now = Get-Date

  if (-not $script:cfg.game_mode_enabled) {
    $form.Visible = $true
    return
  }

  if ($script:cfg.manual_visibility -eq "force_hide") {
    $form.Visible = $false
    return
  }
  if ($script:cfg.manual_visibility -eq "force_show") {
    $form.Visible = $true
    return
  }

  $isFs = Is-ForegroundFullscreen
  if ($isFs) {
    $script:lastAutoFullscreen = $true
    $script:pendingRestoreAt = $null
    $form.Visible = $false
    return
  }

  if ($script:lastAutoFullscreen) {
    if (-not $script:pendingRestoreAt) {
      $script:pendingRestoreAt = $now.AddSeconds(2)
      return
    }
    if ($now -lt $script:pendingRestoreAt) {
      return
    }
    $script:lastAutoFullscreen = $false
    $script:pendingRestoreAt = $null
    $form.Visible = $true
    return
  }

  $form.Visible = $true
}

$form = New-Object System.Windows.Forms.Form
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$form.Size = New-Object System.Drawing.Size(230, 152)
$form.BackColor = Get-TaskbarLikeColor
$form.TopMost = $true
$form.ShowInTaskbar = $false
$form.Opacity = [Math]::Min(1.0, [Math]::Max(0.20, [double]$script:cfg.opacity))

$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.Location = New-Object System.Drawing.Point(($wa.Right - $form.Width - 16), ($wa.Bottom - $form.Height - 16))

if ($script:cfg.layer_mode -eq "normal") { $form.TopMost = $false }

$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Icon = [System.Drawing.SystemIcons]::Information
$notify.Visible = $true
$notify.Text = "Codex用量"

$menu = New-Object System.Windows.Forms.ContextMenuStrip

$layerTop = New-Object System.Windows.Forms.ToolStripMenuItem("图层：桌面最顶端")
$layerNormal = New-Object System.Windows.Forms.ToolStripMenuItem("图层：活动窗口后")
$layerTop.Add_Click({ Set-LayerMode "topmost" })
$layerNormal.Add_Click({ Set-LayerMode "normal" })

$opacityMenu = New-Object System.Windows.Forms.ToolStripMenuItem("透明度")
foreach ($pct in @(100, 95, 90, 85, 80, 70, 60, 50, 40, 30, 20)) {
  $item = New-Object System.Windows.Forms.ToolStripMenuItem("$pct%")
  $item.Tag = ([double]$pct / 100.0)
  $item.Add_Click({
    param($sender, $e)
    Set-OpacityValue ([double]$sender.Tag)
  })
  [void]$opacityMenu.DropDownItems.Add($item)
}

$gameModeMenu = New-Object System.Windows.Forms.ToolStripMenuItem("游戏模式")
$gmOn = New-Object System.Windows.Forms.ToolStripMenuItem("自动检测：开")
$gmOff = New-Object System.Windows.Forms.ToolStripMenuItem("自动检测：关")
$gmManualHide = New-Object System.Windows.Forms.ToolStripMenuItem("手动：强制隐藏")
$gmManualShow = New-Object System.Windows.Forms.ToolStripMenuItem("手动：强制显示")
$gmManualAuto = New-Object System.Windows.Forms.ToolStripMenuItem("手动：恢复自动")

$gmOn.Add_Click({ $script:cfg.game_mode_enabled = $true; Save-Config $script:cfg; Update-NotifyText; $form.Invalidate() })
$gmOff.Add_Click({ $script:cfg.game_mode_enabled = $false; Save-Config $script:cfg; Update-NotifyText; $form.Invalidate() })
$gmManualHide.Add_Click({ $script:cfg.manual_visibility = "force_hide"; Save-Config $script:cfg; Update-NotifyText; Apply-VisibilityPolicy; $form.Invalidate() })
$gmManualShow.Add_Click({ $script:cfg.manual_visibility = "force_show"; Save-Config $script:cfg; Update-NotifyText; Apply-VisibilityPolicy; $form.Invalidate() })
$gmManualAuto.Add_Click({ $script:cfg.manual_visibility = "none"; Save-Config $script:cfg; Update-NotifyText; Apply-VisibilityPolicy; $form.Invalidate() })

[void]$gameModeMenu.DropDownItems.Add($gmOn)
[void]$gameModeMenu.DropDownItems.Add($gmOff)
[void]$gameModeMenu.DropDownItems.Add("-----------")
[void]$gameModeMenu.DropDownItems.Add($gmManualHide)
[void]$gameModeMenu.DropDownItems.Add($gmManualShow)
[void]$gameModeMenu.DropDownItems.Add($gmManualAuto)

$exitItem = New-Object System.Windows.Forms.ToolStripMenuItem("退出")
$exitItem.Add_Click({ $form.Close() })

[void]$menu.Items.Add($layerTop)
[void]$menu.Items.Add($layerNormal)
[void]$menu.Items.Add($opacityMenu)
[void]$menu.Items.Add($gameModeMenu)
[void]$menu.Items.Add("-----------")
[void]$menu.Items.Add($exitItem)
$form.ContextMenuStrip = $menu
$notify.ContextMenuStrip = $menu

$dragging = $false
$dragStart = New-Object System.Drawing.Point(0,0)
$form.Add_MouseDown({
  if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
    $script:dragging = $true
    $script:dragStart = $_.Location
  }
})
$form.Add_MouseMove({
  if ($script:dragging) {
    $p = [System.Windows.Forms.Control]::MousePosition
    $form.Location = New-Object System.Drawing.Point(($p.X - $script:dragStart.X), ($p.Y - $script:dragStart.Y))
  }
})
$form.Add_MouseUp({ $script:dragging = $false })
$form.Add_DoubleClick({ $form.Close() })
$form.Add_MouseEnter({ $script:hovering = $true; $form.Invalidate() })
$form.Add_MouseLeave({ $script:hovering = $false; $form.Invalidate() })

$form.Add_Paint({
  param($sender, $e)
  try {
    if (-not [System.Management.Automation.Runspaces.Runspace]::DefaultRunspace) {
      [System.Management.Automation.Runspaces.Runspace]::DefaultRunspace = $script:MainRunspace
    }
  } catch {}
  $g = $e.Graphics
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

  $bg = $form.BackColor
  $luma = (0.299 * $bg.R) + (0.587 * $bg.G) + (0.114 * $bg.B)
  $isLightBg = $luma -gt 150

  if ($isLightBg) {
    $titleColor = [System.Drawing.Color]::FromArgb(36, 39, 44)
    $subColor = [System.Drawing.Color]::FromArgb(88, 94, 104)
    $trackOuterColor = [System.Drawing.Color]::FromArgb(92, 96, 104)
    $trackInnerColor = [System.Drawing.Color]::FromArgb(132, 137, 146)
    $okColor = [System.Drawing.Color]::FromArgb(23, 132, 83)
    $cacheColor = [System.Drawing.Color]::FromArgb(156, 103, 18)
    $badColor = [System.Drawing.Color]::FromArgb(178, 48, 48)
    $modeColor = [System.Drawing.Color]::FromArgb(54, 104, 210)
  } else {
    $titleColor = [System.Drawing.Color]::FromArgb(236, 238, 242)
    $subColor = [System.Drawing.Color]::FromArgb(176, 181, 190)
    $trackOuterColor = [System.Drawing.Color]::FromArgb(72, 76, 84)
    $trackInnerColor = [System.Drawing.Color]::FromArgb(92, 96, 104)
    $okColor = [System.Drawing.Color]::FromArgb(138, 214, 170)
    $cacheColor = [System.Drawing.Color]::FromArgb(214, 198, 138)
    $badColor = [System.Drawing.Color]::FromArgb(217, 150, 150)
    $modeColor = [System.Drawing.Color]::FromArgb(176, 203, 255)
  }

  $titleBrush = New-Object System.Drawing.SolidBrush($titleColor)
  $subBrush = New-Object System.Drawing.SolidBrush($subColor)
  $okBrush = New-Object System.Drawing.SolidBrush($okColor)
  $cacheBrush = New-Object System.Drawing.SolidBrush($cacheColor)
  $badBrush = New-Object System.Drawing.SolidBrush($badColor)
  $modeBrush = New-Object System.Drawing.SolidBrush($modeColor)

  $fontTitle = New-Object System.Drawing.Font("Microsoft YaHei", 9.5, [System.Drawing.FontStyle]::Bold)
  $fontBody = New-Object System.Drawing.Font("Microsoft YaHei", 8.5)

  $g.DrawString("Codex 用量", $fontTitle, $titleBrush, 10, 8)

  $statusText = "异常"
  $statusBrush = $badBrush
  if ($script:isRefreshing) {
    $statusText = "刷新中"
    $statusBrush = $modeBrush
  } elseif ($script:usage.ok) {
    if ($script:usage.from_cache) {
      $statusText = "缓存"
      $statusBrush = $cacheBrush
    } else {
      $statusText = "正常"
      $statusBrush = $okBrush
    }
  }

  $modeText = Get-GameModeText
  $g.DrawString("状态: $statusText", $fontBody, $statusBrush, 145, 10)
  $g.DrawString($modeText, $fontBody, $modeBrush, 145, 28)

  $outerRect = New-Object System.Drawing.Rectangle(16, 34, 82, 82)
  $innerRect = New-Object System.Drawing.Rectangle(32, 50, 50, 50)

  $trackPenOuter = New-Object System.Drawing.Pen($trackOuterColor, 9)
  $progressPenOuter = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(84,184,255), 9)
  $trackPenInner = New-Object System.Drawing.Pen($trackInnerColor, 7)
  $progressPenInner = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255,178,80), 7)

  $p = [math]::Min(1.0, [math]::Max(0.0, ($script:usage.primary.used / 100.0)))
  $s = [math]::Min(1.0, [math]::Max(0.0, ($script:usage.secondary.used / 100.0)))

  $g.DrawArc($trackPenOuter, $outerRect, -90, 359.9)
  $g.DrawArc($progressPenOuter, $outerRect, -90, (360.0 * $p))
  $g.DrawArc($trackPenInner, $innerRect, -90, 359.9)
  $g.DrawArc($progressPenInner, $innerRect, -90, (360.0 * $s))

  $g.DrawString(("5h 已用{0}% 剩余{1}%" -f [int]$script:usage.primary.used, [int]$script:usage.primary.left), $fontBody, $titleBrush, 108, 52)
  $g.DrawString(("7d 已用{0}% 剩余{1}%" -f [int]$script:usage.secondary.used, [int]$script:usage.secondary.left), $fontBody, $titleBrush, 108, 72)

  $pRemain = Format-Remaining([int]$script:usage.primary.reset_seconds)
  $sRemain = Format-Remaining([int]$script:usage.secondary.reset_seconds)
  $g.DrawString(("5h重置: {0}" -f $pRemain), $fontBody, $subBrush, 108, 94)
  $g.DrawString(("7d重置: {0}" -f $sRemain), $fontBody, $subBrush, 108, 112)

  if ($script:hovering) {
    $g.DrawString("右键调设置 / 双击关闭", $fontBody, $subBrush, 10, 132)
  } elseif ($script:isRefreshing) {
    $g.DrawString("正在后台刷新...", $fontBody, $modeBrush, 10, 132)
  } else {
    if ($script:usage.ok -and -not $script:usage.from_cache) {
      $tsText = if ($script:usage.ts) { ([DateTimeOffset]::FromUnixTimeSeconds([int64]$script:usage.ts).ToLocalTime().ToString("HH:mm:ss")) } else { "--:--:--" }
      $g.DrawString(("最近刷新: {0}" -f $tsText), $fontBody, $subBrush, 10, 132)
    } elseif ($script:usage.from_cache) {
      $g.DrawString("刷新失败（使用缓存）", $fontBody, $cacheBrush, 10, 132)
    } else {
      $g.DrawString("刷新失败（无缓存）", $fontBody, $badBrush, 10, 132)
    }
  }

  $trackPenOuter.Dispose(); $progressPenOuter.Dispose(); $trackPenInner.Dispose(); $progressPenInner.Dispose()
  $titleBrush.Dispose(); $subBrush.Dispose(); $okBrush.Dispose(); $cacheBrush.Dispose(); $badBrush.Dispose(); $modeBrush.Dispose()
  $fontTitle.Dispose(); $fontBody.Dispose()
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
  Apply-VisibilityPolicy
  Complete-UsageRefresh
  if ((Get-Date) -ge $script:nextRefreshAt) { Start-UsageRefresh }
})
$timer.Start()

$form.Add_FormClosing({
  if ($script:refreshJob) {
    try { Remove-Job -Job $script:refreshJob -Force -ErrorAction SilentlyContinue } catch {}
    $script:refreshJob = $null
  }
  $notify.Visible = $false
  $notify.Dispose()
})

Start-UsageRefresh
Apply-VisibilityPolicy
[System.Windows.Forms.Application]::Run($form)
