<#
.SYNOPSIS
    按桌面快捷方式批量安装/升级应用（命令行版，winget）。

.DESCRIPTION
    读取你桌面上实际存在的快捷方式，对照清单，用 winget 自动处理缺失/可升级的应用。
    图形版见 安装应用.cmd；本脚本适合脚本化、计划任务与无人值守。

    路径与容错参数：
      -Location          指定安装路径（绝对路径），例如 -Location D:\Apps
      -LocationSubfolder 是否为每个应用建子文件夹（默认开启）
      -LocationFallback  fallback（默认，回退默认位置）| skip（跳过不装）
      -TimeoutSec        单项超时秒数（默认 1800）
      -MaxRetries        可重试错误的自动重试次数（默认 1）
    出错时按原因分类给出中文说明与处置建议（网络/权限/占用/空间/位置/重启…）。

.EXAMPLE
    .\install-desktop-apps.cmd -DryRun
    先看计划，什么都不装。

.EXAMPLE
    .\install-desktop-apps.cmd -Location D:\Apps -FromDesktop
    把缺失的应用装到 D:\Apps 下的各自子文件夹。

.EXAMPLE
    .\install-desktop-apps.cmd -Upgrade -Only 微信,百度网盘
    只升级这两项。
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Force,
    [string[]]$Only,
    [string[]]$Exclude,
    [switch]$FromDesktop,
    [switch]$IncludeOptional,
    [switch]$Upgrade,
    [string]$Location = '',
    [bool]$LocationSubfolder = $true,
    [ValidateSet('fallback', 'skip')][string]$LocationFallback = 'fallback',
    [int]$TimeoutSec = 1800,
    [int]$MaxRetries = 1,
    [string]$LogPath
)

$ErrorActionPreference = 'Continue'
if (-not $LogPath) { $LogPath = Join-Path ([Environment]::GetFolderPath('Desktop')) ("install-apps-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date)) }

. (Join-Path $PSScriptRoot 'app-catalog.ps1')
. (Join-Path $PSScriptRoot 'app-lib.ps1')

$script:WingetExe = Resolve-WingetExe

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $color = switch ($Level) { 'OK' { 'Green' } 'WARN' { 'Yellow' } 'ERR' { 'Red' } 'SKIP' { 'DarkGray' } 'WG' { 'Cyan' } default { 'Gray' } }
    $line = "[{0:HH:mm:ss}] [{1,-4}] {2}" -f (Get-Date), $Level, $Message
    Write-Host $line -ForegroundColor $color
    try { Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 } catch { }
}
$script:Logger = { param($m, $l) Write-Log -Message $m -Level $l }

function Split-ArgList {
    param([string[]]$Values)
    if (-not $Values) { return @() }
    return @($Values | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
$Only = Split-ArgList $Only
$Exclude = Split-ArgList $Exclude

function Get-DesktopShortcutNames {
    $dirs = @([Environment]::GetFolderPath('Desktop'), (Join-Path $env:PUBLIC 'Desktop')) | Select-Object -Unique
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($d in $dirs) {
        if (-not (Test-Path -LiteralPath $d)) { continue }
        Get-ChildItem -LiteralPath $d -Force -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in '.lnk', '.url' } |
            ForEach-Object { $names.Add([IO.Path]::GetFileNameWithoutExtension($_.Name)) }
    }
    return $names
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Log "日志文件：$LogPath"
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Log 'winget 不存在。请先安装「应用安装程序」(App Installer)。' 'ERR'
    exit 1
}
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Log ("winget {0} | 管理员={1} | 模式={2}" -f ((& $script:WingetExe --version) -replace '\s', ''), $isAdmin, $(if ($Upgrade) { if ($DryRun) { '演练(升级)' } else { '实际升级' } } elseif ($DryRun) { '演练(不安装)' } else { '实际安装' }))

# 自定义路径校验（提前失败，避免跑到一半才发现路径不可用）
if ($Location) {
    $chk = Test-InstallLocationPath -Path $Location
    if (-not $chk.Ok) {
        Write-Log "自定义安装位置不可用：$($chk.Reason)" 'ERR'
        exit 2
    }
    Write-Log ("安装位置：{0}（剩余 {1} GB{2}，子文件夹={3}）" -f $Location, $chk.FreeGB, $(if ($chk.Created) { '，已创建' } else { '' }), $LocationSubfolder) 'OK'
}

$desktopNames = Get-DesktopShortcutNames
Write-Log ("桌面快捷方式 {0} 个：{1}" -f $desktopNames.Count, (($desktopNames | Sort-Object) -join '、'))

$snap = Get-StatusSnapshot -Logger $script:Logger -WingetExe $script:WingetExe

$targets = $Catalog
if ($Only) {
    $targets = $targets | Where-Object { $n = $_.Name; $i = $_.Id; @($Only | Where-Object { $n -like "*$_*" -or $i -eq $_ }).Count -gt 0 }
}
elseif (-not $IncludeOptional) {
    $targets = $targets | Where-Object { -not $_.OptIn }
}
if ($Exclude) {
    $targets = $targets | Where-Object { $n = $_.Name; @($Exclude | Where-Object { $n -like "*$_*" }).Count -eq 0 }
}
if ($FromDesktop) {
    $targets = $targets | Where-Object { $s = $_.Shortcut; $s -and @($desktopNames | Where-Object { $_ -like "*$s*" }).Count -gt 0 }
}
$targets = @($targets)

$result = New-Object System.Collections.Generic.List[object]
Write-Host ''
Write-Log ("待处理 {0} 项" -f $targets.Count)
Write-Host ('-' * 78)

$ok = 0; $skipped = 0; $failed = 0; $timeouts = 0; $fallbacks = 0
$failList = New-Object System.Collections.Generic.List[string]
$adminNeeded = $false

# 目标程序占用预检
$busy = @()
try {
    $map = Get-DesktopShortcutTargetMap
    foreach ($app in $targets) {
        foreach ($p in (Get-RunningProcessForApp -App $app -ShortcutMap $map)) { $busy += "$($app.Name)($($p.ProcessName))" }
    }
} catch { }
if ($busy.Count) { Write-Log ("注意：以下程序正在运行，可能影响安装：" + ($busy -join '、')) 'WARN' }

foreach ($app in $targets) {
    $s = $snap[$app.Id]
    $mode = if ($Upgrade) { 'upgrade' } else { 'install' }
    $line = [pscustomobject]@{ Name = $app.Name; Id = $app.Id; Status = ''; Detail = '' }

    if ($Upgrade -and -not $s.Installed) {
        $line.Status = '未安装(跳过)'; Write-Log ("{0,-24} 未安装，升级模式跳过" -f $app.Name) 'SKIP'; $skipped++; $result.Add($line); continue
    }
    if ($Upgrade -and -not $s.Available) {
        $line.Status = '已是最新'; Write-Log ("{0,-24} 已是最新版本" -f $app.Name) 'SKIP'; $skipped++; $result.Add($line); continue
    }
    if (-not $Upgrade -and $s.Installed -and -not $Force) {
        $line.Status = '已安装(跳过)'; Write-Log ("{0,-24} 已安装，跳过" -f $app.Name) 'SKIP'; $skipped++; $result.Add($line); continue
    }

    $loc = Get-EffectiveLocation -App $app -Root $Location -PerAppSubfolder $LocationSubfolder
    if ($DryRun) {
        $line.Status = '将处理(演练)'
        Write-Log ("{0,-24} [演练] winget {1} --id {2}{3}" -f $app.Name, $mode, $app.Id, $(if ($loc) { " --location `"$loc`"" } else { '' })) 'INFO'
        $result.Add($line); continue
    }

    Write-Log ("{0,-24} {1}中…{2}" -f $app.Name, $(if ($mode -eq 'upgrade') { '升级' } else { '安装' }), $(if ($loc) { " 位置：$loc" } else { '' }))
    $extra = @()
    if ($Force -and -not $Upgrade) { $extra += '--force' }
    $task = $null
    try {
        $task = Invoke-AppTask -App $app -Mode $mode -Location $loc -LocationFallbackPolicy $LocationFallback `
            -TimeoutSec $TimeoutSec -MaxRetries $MaxRetries -Logger $script:Logger -WingetExe $script:WingetExe -ExtraArgs $extra
    }
    catch {
        Write-Log ("{0,-24} [X] 执行异常：{1}" -f $app.Name, $_.Exception.Message) 'ERR'
        $task = [pscustomobject]@{ Status = '失败'; Info = [pscustomobject]@{ Kind = 'EXCEPTION'; Message = $_.Exception.Message; HResult = '-'; NeedsAdmin = $false }; Result = [pscustomobject]@{ Seconds = 0 }; Attempts = 1 }
    }

    if ($task.Info -and $task.Info.NeedsAdmin) { $adminNeeded = $true }

    switch ($task.Status) {
        '成功' {
            $line.Status = '成功'; Write-Log ("{0,-24} [OK] 完成（{1}s）" -f $app.Name, $task.Result.Seconds) 'OK'; $ok++
        }
        '回退成功' {
            $line.Status = '已装(默认位置)'; Write-Log ("{0,-24} [OK] 已安装，但该包不支持自定义位置，装到默认位置" -f $app.Name) 'WARN'; $ok++; $fallbacks++
        }
        '跳过' {
            $line.Status = '跳过'; Write-Log ("{0,-24} 跳过：{1}" -f $app.Name, $task.Info.Message) 'SKIP'; $skipped++
        }
        '超时' {
            $line.Status = '超时终止'; Write-Log ("{0,-24} [超时] {1}（{2}s）" -f $app.Name, $task.Info.Message, $task.Result.Seconds) 'ERR'; $failed++; $timeouts++
            $failList.Add(("{0}（{1}）超时：调大 -TimeoutSec 或改善网络" -f $app.Name, $app.Id))
        }
        default {
            $info = $task.Info
            $line.Status = "失败($($info.Kind))"
            Write-Log ("{0,-24} [X] 失败：{1}（{2}）" -f $app.Name, $info.Message, $info.HResult) 'ERR'
            $failList.Add(("{0}（{1}）{2} [{3}]" -f $app.Name, $app.Id, $info.Message, $info.HResult))
            $failed++
        }
    }
    $result.Add($line)
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host ('=' * 78)
Write-Log '结果汇总'
$table = $result | Format-Table Name, Id, Status -AutoSize | Out-String -Width 200
Write-Host $table
try { Add-Content -LiteralPath $LogPath -Value $table -Encoding UTF8 } catch { }
Write-Log ("成功 {0}（回退默认位置 {1}），跳过 {2}，失败 {3}（超时 {4}）" -f $ok, $fallbacks, $skipped, $failed, $timeouts) $(if ($failed) { 'WARN' } else { 'OK' })

if ($failed -and -not $isAdmin) { Write-Log '有失败项；若属权限问题，请用「以管理员身份运行」的终端重试。' 'WARN' }
if ($failList.Count) {
    Write-Host ''
    Write-Log '需要处理的项目：'
    foreach ($f in $failList) { Write-Log ("  " + $f) 'ERR' }
}

Write-Host ''
Write-Log '以下项目脚本不自动安装，需手动处理：'
foreach ($m in $Manual) {
    Write-Host ("  - {0}" -f $m.Name) -ForegroundColor DarkYellow
    Write-Host ("      {0}" -f $m.Reason) -ForegroundColor DarkGray
    try { Add-Content -LiteralPath $LogPath -Value ("  - {0} :: {1}" -f $m.Name, $m.Reason) -Encoding UTF8 } catch { }
}
Write-Host ''
Write-Log "完成。日志：$LogPath"
