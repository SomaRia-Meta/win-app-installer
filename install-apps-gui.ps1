<#
.SYNOPSIS
    应用批量安装/升级（图形界面版）——选择弹窗 + 可指定安装路径 + 进度条 + 实时日志 + 异常处置。

.DESCRIPTION
    启动后弹出 WinForms 窗口，列出应用及状态（已装版本 / 可用版本 / 状态 / 安装位置）。
    可以：
      · 勾选要处理的应用（支持全选/全不选/反选/重新检测）
      · 选择模式（安装缺失 / 升级已安装）
      · 指定自定义安装路径（可选「每个应用建子文件夹」；清单里也可给单个应用固定路径）
        - 路径会先校验：绝对路径 / 盘符存在 / 可创建 / 可写 / 剩余空间
        - 不支持自定义位置的安装包（MSIX、商店类等）按策略处理：回退默认位置 或 跳过
      · 单项超时（默认 1800 秒）与自动重试次数（默认 1 次）
    执行期间：
      · 窗口内进度条 + 当前项 + 已用时；winget 每一行输出实时进入窗口日志区与控制台
      · 「打开调试终端」可再开一个持续 tail 日志的终端窗口
      · 出错时按原因分类给出中文说明与处置建议（网络/权限/占用/空间/位置/重启…）
      · 需要管理员权限时可点「以管理员身份重启」
    全部输出同时写入桌面 install-apps-<时间戳>.log。

.PARAMETER DryRun
    演练模式：只走流程，不真正安装/升级。

.PARAMETER NoGui
    不开窗口，控制台模式运行（调试用）。

.PARAMETER ScanOnly
    配合 -NoGui：只打印检测结果。

.PARAMETER AutoRun
    无人值守：开窗后自动检测 → 自动按当前模式执行 → 结束自动关窗。

.PARAMETER Mode
    auto（默认，无可安装项时自动切升级）/ install / upgrade。

.PARAMETER Only
    只处理指定项，支持逗号分隔（名称或包 ID 模糊匹配）。

.PARAMETER Location
    自定义安装路径（绝对路径）。留空 = 使用默认位置。

.PARAMETER LocationFallbackPolicy
    fallback（默认，回退默认位置）或 skip（跳过不装）。

.PARAMETER TimeoutSec
    单项超时秒数，默认 1800。

.PARAMETER MaxRetries
    可重试类错误（网络/占用/安装冲突）的自动重试次数，默认 1。

.EXAMPLE
    .\安装应用.cmd
    弹出界面（双击同效）。

.EXAMPLE
    .\安装应用.cmd -Location D:\Apps -Mode upgrade -AutoRun -DryRun
    演练：把 D:\Apps 作为安装位置跑一遍流程，不做实际改动。
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$NoGui,
    [switch]$ScanOnly,
    [switch]$AutoRun,
    [ValidateSet('auto', 'install', 'upgrade')][string]$Mode = 'auto',
    [string[]]$Only,
    [string]$Location = '',
    [ValidateSet('fallback', 'skip')][string]$LocationFallbackPolicy = 'fallback',
    [int]$TimeoutSec = 1800,
    [int]$MaxRetries = 1,
    [string]$LogPath
)

$ErrorActionPreference = 'Continue'
if (-not $LogPath) { $LogPath = Join-Path ([Environment]::GetFolderPath('Desktop')) ("install-apps-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date)) }

# 共享数据与逻辑库
. (Join-Path $PSScriptRoot 'app-catalog.ps1')
. (Join-Path $PSScriptRoot 'app-lib.ps1')

$Only = @($Only | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

$script:LogBox = $null
$script:StatusLabel = $null
$script:StatusPrefix = ''
$script:StopRequested = $false
$script:WingetExe = Resolve-WingetExe

function Write-Both {
    param([string]$Message, [string]$Level = 'INFO', [switch]$Raw)
    $color = switch ($Level) { 'OK' { 'Green' } 'WARN' { 'Yellow' } 'ERR' { 'Red' } 'SKIP' { 'DarkGray' } 'WG' { 'Cyan' } default { 'Gray' } }
    $line = if ($Raw) { $Message } else { "[{0:HH:mm:ss}] [{1,-4}] {2}" -f (Get-Date), $Level, $Message }
    Write-Host $line -ForegroundColor $color
    if ($script:LogBox) {
        try {
            $script:LogBox.AppendText($line + "`r`n")
            $script:LogBox.SelectionStart = $script:LogBox.TextLength
            $script:LogBox.ScrollToCaret()
        }
        catch { }
    }
    try { Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 } catch { }
}

$script:Logger = { param($m, $l) Write-Both -Message $m -Level $l }

# ---------------------------------------------------------------------------
# 无界面模式
# ---------------------------------------------------------------------------
if ($NoGui) {
    Write-Both '检测中（一次 winget list）…'
    $snap = Get-StatusSnapshot -Logger $script:Logger -WingetExe $script:WingetExe
    foreach ($app in $Catalog) {
        $s = $snap[$app.Id]
        $state = if (-not $s.Installed) { '未安装' } elseif ($s.Available) { '可升级' } else { '已是最新' }
        $loc = Get-EffectiveLocation -App $app -Root $Location -PerAppSubfolder $true
        if (-not $loc) { $loc = '默认' }
        Write-Both ("{0,-22} {1,-34} 已装={2,-12} 可用={3,-12} {4,-8} 位置={5}" -f $app.Name, $app.Id, $s.Version, $s.Available, $state, $loc)
    }
    if ($Location) {
        $chk = Test-InstallLocationPath -Path $Location
        Write-Both ("自定义路径校验：{0} {1}" -f $(if ($chk.Ok) { '通过' } else { '不通过' }), $(if ($chk.Ok) { "剩余 $($chk.FreeGB) GB" } else { $chk.Reason })) $(if ($chk.Ok) { 'OK' } else { 'ERR' })
    }
    Write-Both "日志：$LogPath"
    return
}

# ---------------------------------------------------------------------------
# 图形界面
# ---------------------------------------------------------------------------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text = '应用批量安装 / 升级  —  winget'
$form.Size = New-Object System.Drawing.Size(960, 800)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object System.Drawing.Size(960, 800)
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$form.BackColor = [System.Drawing.Color]::FromArgb(246, 247, 249)

# ---- ① 应用列表 ----
$grpList = New-Object System.Windows.Forms.GroupBox
$grpList.Text = '① 选择要处理的应用'
$grpList.Location = New-Object System.Drawing.Point(12, 8)
$grpList.Size = New-Object System.Drawing.Size(920, 330)
$grpList.Anchor = 'Top,Left,Right'

$lv = New-Object System.Windows.Forms.ListView
$lv.Location = New-Object System.Drawing.Point(12, 24)
$lv.Size = New-Object System.Drawing.Size(896, 262)
$lv.View = 'Details'
$lv.CheckBoxes = $true
$lv.FullRowSelect = $true
$lv.GridLines = $true
$lv.HideSelection = $false
$lv.ShowItemToolTips = $true
$lv.Anchor = 'Top,Left,Right,Bottom'
[void]$lv.Columns.Add('应用', 150)
[void]$lv.Columns.Add('winget 包 ID', 205)
[void]$lv.Columns.Add('已装版本', 90)
[void]$lv.Columns.Add('可用版本', 90)
[void]$lv.Columns.Add('状态', 105)
[void]$lv.Columns.Add('安装位置', 240)
$grpList.Controls.Add($lv)

$btnAll = New-Object System.Windows.Forms.Button
$btnAll.Text = '全选'; $btnAll.Location = New-Object System.Drawing.Point(12, 292); $btnAll.Size = New-Object System.Drawing.Size(80, 30)
$btnNone = New-Object System.Windows.Forms.Button
$btnNone.Text = '全不选'; $btnNone.Location = New-Object System.Drawing.Point(100, 292); $btnNone.Size = New-Object System.Drawing.Size(80, 30)
$btnInvert = New-Object System.Windows.Forms.Button
$btnInvert.Text = '反选'; $btnInvert.Location = New-Object System.Drawing.Point(188, 292); $btnInvert.Size = New-Object System.Drawing.Size(80, 30)
$btnRescan = New-Object System.Windows.Forms.Button
$btnRescan.Text = '重新检测'; $btnRescan.Location = New-Object System.Drawing.Point(276, 292); $btnRescan.Size = New-Object System.Drawing.Size(96, 30)
$lblHint = New-Object System.Windows.Forms.Label
$lblHint.Text = '灰色=可选包；蓝=未安装，橙=可升级，绿=已最新'
$lblHint.Location = New-Object System.Drawing.Point(384, 298); $lblHint.Size = New-Object System.Drawing.Size(540, 20)
$lblHint.ForeColor = [System.Drawing.Color]::DimGray
$grpList.Controls.AddRange(@($btnAll, $btnNone, $btnInvert, $btnRescan, $lblHint))

# ---- ② 模式 / 路径 / 容错 ----
$grpMode = New-Object System.Windows.Forms.GroupBox
$grpMode.Text = '② 操作模式 / 安装位置 / 容错'
$grpMode.Location = New-Object System.Drawing.Point(12, 344)
$grpMode.Size = New-Object System.Drawing.Size(920, 132)
$grpMode.Anchor = 'Top,Left,Right'

$rbInstall = New-Object System.Windows.Forms.RadioButton
$rbInstall.Text = '安装缺失的项'; $rbInstall.Location = New-Object System.Drawing.Point(16, 26); $rbInstall.Size = New-Object System.Drawing.Size(140, 24); $rbInstall.Checked = $true
$rbUpgrade = New-Object System.Windows.Forms.RadioButton
$rbUpgrade.Text = '升级已安装的项'; $rbUpgrade.Location = New-Object System.Drawing.Point(160, 26); $rbUpgrade.Size = New-Object System.Drawing.Size(150, 24)
$chkOptIn = New-Object System.Windows.Forms.CheckBox
$chkOptIn.Text = '包含可选包'; $chkOptIn.Location = New-Object System.Drawing.Point(316, 26); $chkOptIn.Size = New-Object System.Drawing.Size(110, 24)
$chkDry = New-Object System.Windows.Forms.CheckBox
$chkDry.Text = '演练模式（只看不装）'; $chkDry.Location = New-Object System.Drawing.Point(430, 26); $chkDry.Size = New-Object System.Drawing.Size(170, 24); $chkDry.Checked = [bool]$DryRun
$lblTo = New-Object System.Windows.Forms.Label
$lblTo.Text = '单项超时(秒)'; $lblTo.Location = New-Object System.Drawing.Point(608, 29); $lblTo.Size = New-Object System.Drawing.Size(84, 20)
$numTimeout = New-Object System.Windows.Forms.NumericUpDown
$numTimeout.Location = New-Object System.Drawing.Point(694, 26); $numTimeout.Size = New-Object System.Drawing.Size(76, 24)
$numTimeout.Minimum = 30; $numTimeout.Maximum = 7200; $numTimeout.Value = [Math]::Max(30, [Math]::Min(7200, $TimeoutSec)); $numTimeout.Increment = 60
$lblRetry = New-Object System.Windows.Forms.Label
$lblRetry.Text = '自动重试'; $lblRetry.Location = New-Object System.Drawing.Point(782, 29); $lblRetry.Size = New-Object System.Drawing.Size(60, 20)
$numRetry = New-Object System.Windows.Forms.NumericUpDown
$numRetry.Location = New-Object System.Drawing.Point(844, 26); $numRetry.Size = New-Object System.Drawing.Size(60, 24)
$numRetry.Minimum = 0; $numRetry.Maximum = 5; $numRetry.Value = [Math]::Max(0, [Math]::Min(5, $MaxRetries))

$chkUseLoc = New-Object System.Windows.Forms.CheckBox
$chkUseLoc.Text = '使用自定义安装位置'; $chkUseLoc.Location = New-Object System.Drawing.Point(16, 60); $chkUseLoc.Size = New-Object System.Drawing.Size(160, 24)
$chkUseLoc.Checked = [bool]$Location
$txtLoc = New-Object System.Windows.Forms.TextBox
$txtLoc.Location = New-Object System.Drawing.Point(180, 60); $txtLoc.Size = New-Object System.Drawing.Size(300, 24); $txtLoc.Text = $Location
$txtLoc.Enabled = [bool]$Location
$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Text = '浏览…'; $btnBrowse.Location = New-Object System.Drawing.Point(486, 59); $btnBrowse.Size = New-Object System.Drawing.Size(70, 26); $btnBrowse.Enabled = [bool]$Location
$chkPerApp = New-Object System.Windows.Forms.CheckBox
$chkPerApp.Text = '每个应用建子文件夹'; $chkPerApp.Location = New-Object System.Drawing.Point(566, 60); $chkPerApp.Size = New-Object System.Drawing.Size(170, 24); $chkPerApp.Checked = $true
$rbFallback = New-Object System.Windows.Forms.RadioButton
$rbFallback.Text = '不支持时回退默认位置'; $rbFallback.Location = New-Object System.Drawing.Point(16, 92); $rbFallback.Size = New-Object System.Drawing.Size(200, 24)
$rbSkip = New-Object System.Windows.Forms.RadioButton
$rbSkip.Text = '不支持时跳过不装'; $rbSkip.Location = New-Object System.Drawing.Point(222, 92); $rbSkip.Size = New-Object System.Drawing.Size(160, 24)
if ($LocationFallbackPolicy -eq 'skip') { $rbSkip.Checked = $true } else { $rbFallback.Checked = $true }
$lblLocHint = New-Object System.Windows.Forms.Label
$lblLocHint.Text = '仅对声明支持自定义位置的安装包生效（MSIX/商店类不支持）；路径会先校验盘符/可写/剩余空间'
$lblLocHint.Location = New-Object System.Drawing.Point(392, 96); $lblLocHint.Size = New-Object System.Drawing.Size(520, 20)
$lblLocHint.ForeColor = [System.Drawing.Color]::DimGray
$grpMode.Controls.AddRange(@($rbInstall, $rbUpgrade, $chkOptIn, $chkDry, $lblTo, $numTimeout, $lblRetry, $numRetry,
        $chkUseLoc, $txtLoc, $btnBrowse, $chkPerApp, $rbFallback, $rbSkip, $lblLocHint))

# ---- ③ 执行 ----
$grpRun = New-Object System.Windows.Forms.GroupBox
$grpRun.Text = '③ 执行与实时日志（winget 输出实时串流到这里，同时打到控制台窗口）'
$grpRun.Location = New-Object System.Drawing.Point(12, 482)
$grpRun.Size = New-Object System.Drawing.Size(920, 266)
$grpRun.Anchor = 'Top,Left,Right,Bottom'

$pb = New-Object System.Windows.Forms.ProgressBar
$pb.Location = New-Object System.Drawing.Point(16, 26); $pb.Size = New-Object System.Drawing.Size(620, 22); $pb.Minimum = 0; $pb.Maximum = 100
$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = '就绪'; $lblStatus.Location = New-Object System.Drawing.Point(644, 29); $lblStatus.Size = New-Object System.Drawing.Size(260, 20)
$script:StatusLabel = $lblStatus

$btnStart = New-Object System.Windows.Forms.Button
$btnStart.Text = '开始执行'; $btnStart.Location = New-Object System.Drawing.Point(16, 56); $btnStart.Size = New-Object System.Drawing.Size(104, 32)
$btnStart.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215); $btnStart.ForeColor = [System.Drawing.Color]::White; $btnStart.FlatStyle = 'Flat'
$btnStop = New-Object System.Windows.Forms.Button
$btnStop.Text = '中断'; $btnStop.Location = New-Object System.Drawing.Point(128, 56); $btnStop.Size = New-Object System.Drawing.Size(72, 32); $btnStop.Enabled = $false
$btnTerm = New-Object System.Windows.Forms.Button
$btnTerm.Text = '打开调试终端'; $btnTerm.Location = New-Object System.Drawing.Point(208, 56); $btnTerm.Size = New-Object System.Drawing.Size(120, 32)
$btnLog = New-Object System.Windows.Forms.Button
$btnLog.Text = '打开日志文件'; $btnLog.Location = New-Object System.Drawing.Point(336, 56); $btnLog.Size = New-Object System.Drawing.Size(114, 32)
$btnElevate = New-Object System.Windows.Forms.Button
$btnElevate.Text = '以管理员身份重启'; $btnElevate.Location = New-Object System.Drawing.Point(458, 56); $btnElevate.Size = New-Object System.Drawing.Size(140, 32)
$btnClose = New-Object System.Windows.Forms.Button
$btnClose.Text = '关闭'; $btnClose.Location = New-Object System.Drawing.Point(816, 56); $btnClose.Size = New-Object System.Drawing.Size(88, 32); $btnClose.Anchor = 'Top,Right'

$script:LogBox = New-Object System.Windows.Forms.TextBox
$script:LogBox.Location = New-Object System.Drawing.Point(16, 96); $script:LogBox.Size = New-Object System.Drawing.Size(888, 156)
$script:LogBox.Multiline = $true; $script:LogBox.ReadOnly = $true; $script:LogBox.ScrollBars = 'Vertical'
$script:LogBox.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30); $script:LogBox.ForeColor = [System.Drawing.Color]::Gainsboro
$script:LogBox.Font = New-Object System.Drawing.Font('Consolas', 8.5)
$script:LogBox.Anchor = 'Top,Left,Right,Bottom'
$grpRun.Controls.AddRange(@($pb, $lblStatus, $btnStart, $btnStop, $btnTerm, $btnLog, $btnElevate, $btnClose, $script:LogBox))

$form.Controls.AddRange(@($grpList, $grpMode, $grpRun))

# ---------------------------------------------------------------------------
$script:Rows = New-Object System.Collections.Generic.List[object]

function Add-CatalogRows {
    $lv.Items.Clear(); $script:Rows.Clear()
    $apps = if ($Only.Count) {
        @($Catalog | Where-Object { $n = $_.Name; $i = $_.Id; @($Only | Where-Object { $n -like "*$_*" -or $i -eq $_ }).Count -gt 0 })
    }
    else { @($Catalog) }
    foreach ($app in $apps) {
        $it = New-Object System.Windows.Forms.ListViewItem($app.Name)
        [void]$it.SubItems.Add($app.Id)
        [void]$it.SubItems.Add(''); [void]$it.SubItems.Add(''); [void]$it.SubItems.Add('检测中…'); [void]$it.SubItems.Add('')
        if ($app.OptIn) { $it.ForeColor = [System.Drawing.Color]::Gray }
        $it.Tag = $app
        [void]$lv.Items.Add($it)
        $script:Rows.Add([pscustomobject]@{ App = $app; Item = $it; Installed = $false; Version = ''; Available = '' })
    }
}

function Update-RowStatus {
    param($row, $snap)
    $s = $snap[$row.App.Id]
    $row.Installed = [bool]$s.Installed; $row.Version = $s.Version; $row.Available = $s.Available
    $row.Item.SubItems[2].Text = if ($s.Version) { $s.Version } else { '—' }
    $row.Item.SubItems[3].Text = if ($s.Available) { $s.Available } else { '—' }
    if (-not $s.Installed) {
        $row.Item.SubItems[4].Text = if ($row.App.OptIn) { '未安装(可选)' } else { '未安装' }
        $row.Item.ForeColor = [System.Drawing.Color]::FromArgb(0, 90, 158)
    }
    elseif ($s.Available) {
        $row.Item.SubItems[4].Text = '可升级'
        $row.Item.ForeColor = [System.Drawing.Color]::FromArgb(176, 96, 0)
    }
    else {
        $row.Item.SubItems[4].Text = '已是最新'
        $row.Item.ForeColor = if ($row.App.OptIn) { [System.Drawing.Color]::Gray } else { [System.Drawing.Color]::FromArgb(0, 110, 60) }
    }
}

function Get-SelectedRoot { if ($chkUseLoc.Checked) { return $txtLoc.Text.Trim() } else { return '' } }

function Update-LocationColumn {
    $root = Get-SelectedRoot
    $per = [bool]$chkPerApp.Checked
    foreach ($row in $script:Rows) {
        $loc = Get-EffectiveLocation -App $row.App -Root $root -PerAppSubfolder $per
        $row.Item.SubItems[5].Text = if (-not $loc) { '默认' } else { $loc }
    }
}

function Set-AllChecks { param([bool]$Value) foreach ($row in $script:Rows) { $row.Item.Checked = $Value } }

function Set-ActionableChecks {
    $upgrade = $rbUpgrade.Checked
    foreach ($row in $script:Rows) {
        if ($row.App.OptIn -and -not $chkOptIn.Checked) { $row.Item.Checked = $false; continue }
        if ($upgrade) { $row.Item.Checked = ($row.Installed -and $row.Available) }
        else { $row.Item.Checked = (-not $row.Installed) }
    }
}

function Invoke-Scan {
    $btnStart.Enabled = $false; $btnRescan.Enabled = $false
    $pb.Style = 'Marquee'; $lblStatus.Text = '正在检测…'
    [System.Windows.Forms.Application]::DoEvents()
    Write-Both '开始检测：一次 winget list 读取全部已安装项与可用升级…'
    $snap = Get-StatusSnapshot -Logger $script:Logger -WingetExe $script:WingetExe
    foreach ($row in $script:Rows) { Update-RowStatus -row $row -snap $snap }
    Update-LocationColumn
    $missAll = @($script:Rows | Where-Object { -not $_.Installed }).Count
    $missAct = @($script:Rows | Where-Object { -not $_.Installed -and -not $_.App.OptIn }).Count
    $up = @($script:Rows | Where-Object { $_.Installed -and $_.Available }).Count
    if ($Mode -eq 'upgrade') { $rbUpgrade.Checked = $true }
    elseif ($Mode -eq 'install') { $rbInstall.Checked = $true }
    elseif ($missAct -eq 0 -and $up -gt 0) { $rbUpgrade.Checked = $true }
    Set-ActionableChecks
    $pb.Style = 'Continuous'; $pb.Value = 0
    $lblStatus.Text = "检测完成：未安装 $missAll 项（可选包 $($missAll - $missAct)），可升级 $up 项"
    $btnStart.Enabled = $true; $btnRescan.Enabled = $true
    Write-Both ("检测完成：未安装 {0} 项（可选包 {1}），可升级 {2} 项；当前模式={3}" -f $missAll, ($missAll - $missAct), $up, $(if ($rbUpgrade.Checked) { '升级' } else { '安装' })) 'OK'
}

# ---------------------------------------------------------------------------
$btnAll.Add_Click({ Set-AllChecks -Value $true })
$btnNone.Add_Click({ Set-AllChecks -Value $false })
$btnInvert.Add_Click({ foreach ($row in $script:Rows) { $row.Item.Checked = -not $row.Item.Checked } })
$btnRescan.Add_Click({ Invoke-Scan })
$rbInstall.Add_CheckedChanged({ Set-ActionableChecks })
$rbUpgrade.Add_CheckedChanged({ Set-ActionableChecks })
$chkOptIn.Add_CheckedChanged({ Set-ActionableChecks })
$btnClose.Add_Click({ $form.Close() })
$btnStop.Add_Click({ $script:StopRequested = $true; Write-Both '已请求中断，正在结束当前项…' 'WARN' })

$chkUseLoc.Add_CheckedChanged({
    $txtLoc.Enabled = $chkUseLoc.Checked
    $btnBrowse.Enabled = $chkUseLoc.Checked
    Update-LocationColumn
})
$txtLoc.Add_TextChanged({ Update-LocationColumn })
$chkPerApp.Add_CheckedChanged({ Update-LocationColumn })
$btnBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = '选择安装位置（例如 D:\Apps）'
    $dlg.ShowNewFolderButton = $true
    if ($txtLoc.Text -and (Test-Path -LiteralPath $txtLoc.Text)) { $dlg.SelectedPath = $txtLoc.Text }
    if ($dlg.ShowDialog() -eq 'OK') { $txtLoc.Text = $dlg.SelectedPath }
})

$btnTerm.Add_Click({
    $ps = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
    $cmd = "`$Host.UI.RawUI.WindowTitle='winget 调试终端'; chcp 65001 > `$null; Write-Host '实时日志：$LogPath' -ForegroundColor Cyan; Get-Content -LiteralPath '$LogPath' -Wait -Tail 60"
    Start-Process -FilePath $ps -ArgumentList '-NoProfile', '-NoExit', '-Command', $cmd | Out-Null
    Write-Both '已打开调试终端窗口（持续 tail 日志）。'
})
$btnLog.Add_Click({ Start-Process notepad.exe -ArgumentList "`"$LogPath`"" | Out-Null })

$btnElevate.Add_Click({
    $ans = [System.Windows.Forms.MessageBox]::Show(
        "将以管理员身份重新打开本程序（会弹出 UAC 授权窗口）。`n`n当前窗口会被关闭，已勾选的内容需要重新选择。是否继续？",
        '以管理员身份重启', 'YesNo', 'Question')
    if ($ans -ne 'Yes') { return }
    try {
        $ps = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
        $extra = @()
        if ($chkUseLoc.Checked -and $txtLoc.Text.Trim()) { $extra += @('-Location', $txtLoc.Text.Trim()) }
        Start-Process -FilePath $ps -Verb RunAs -ArgumentList (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath) + $extra) | Out-Null
        Write-Both '已请求以管理员身份重启（请在 UAC 窗口确认）。' 'WARN'
        $form.Close()
    }
    catch {
        Write-Both "提权启动失败：$($_.Exception.Message)" 'ERR'
        [void][System.Windows.Forms.MessageBox]::Show("提权启动失败：`n$($_.Exception.Message)`n`n你可以手动右键以管理员身份运行 安装应用.cmd", '失败', 'OK', 'Error')
    }
})

# ---------------------------------------------------------------------------
# 开始执行（前置检查 + 异常处置）
# ---------------------------------------------------------------------------
$btnStart.Add_Click({
    $selected = @($script:Rows | Where-Object { $_.Item.Checked })

    $mode = if ($rbUpgrade.Checked) { 'upgrade' } else { 'install' }
    $dry = $chkDry.Checked
    $timeout = [int]$numTimeout.Value
    $retries = [int]$numRetry.Value
    $verb = if ($mode -eq 'upgrade') { '升级' } else { '安装' }
    $root = Get-SelectedRoot
    $perApp = [bool]$chkPerApp.Checked
    $policy = if ($rbSkip.Checked) { 'skip' } else { 'fallback' }

    # 前置检查 1：自定义路径校验
    if ($root) {
        $chk = Test-InstallLocationPath -Path $root
        if (-not $chk.Ok) {
            Write-Both "自定义安装位置不可用：$($chk.Reason)" 'ERR'
            if (-not $AutoRun) { [void][System.Windows.Forms.MessageBox]::Show("自定义安装位置不可用：`n$($chk.Reason)`n`n请修改路径，或取消勾选「使用自定义安装位置」。", '路径不可用', 'OK', 'Error') }
            return
        }
        Write-Both ("自定义安装位置校验通过：{0}（剩余 {1} GB{2}）" -f $root, $chk.FreeGB, $(if ($chk.Created) { '，已创建目录' } else { '' })) 'OK'
    }

    # 前置检查 2：有没有勾选项（放在路径校验之后，保证路径问题优先被指出）
    if ($selected.Count -eq 0) {
        if ($AutoRun) { Write-Both '没有可处理的勾选项，AutoRun 结束（未弹窗）。' 'WARN'; $form.Close(); return }
        [void][System.Windows.Forms.MessageBox]::Show('请先勾选至少一项。', '没有选择', 'OK', 'Warning'); return
    }

    # 前置检查 2：目标程序是否正在运行
    $busy = New-Object System.Collections.Generic.List[string]
    try {
        $map = Get-DesktopShortcutTargetMap
        foreach ($row in $selected) {
            foreach ($p in (Get-RunningProcessForApp -App $row.App -ShortcutMap $map)) { $busy.Add("$($row.App.Name)（$($p.ProcessName)，PID $($p.Id)）") }
        }
    }
    catch { Write-Both "检测运行中程序时出错（忽略）：$($_.Exception.Message)" 'WARN' }
    if ($busy.Count -gt 0) {
        Write-Both ("以下程序正在运行，可能导致安装/升级失败或被占用：" + ($busy -join '、')) 'WARN'
        if (-not $AutoRun) {
            $ans = [System.Windows.Forms.MessageBox]::Show(
                ("以下程序正在运行，安装/升级可能失败或需要先关闭：`n`n" + ($busy -join "`n") + "`n`n是否仍然继续？"),
                '程序正在运行', 'YesNo', 'Warning')
            if ($ans -ne 'Yes') { Write-Both '用户选择先关闭程序，已取消本次执行。' 'WARN'; return }
        }
    }

    # 前置检查 3：系统盘空间提醒（未指定自定义位置时）
    if (-not $root) {
        try {
            $sys = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($env:SystemDrive + '\'))
            $freeGB = [math]::Round($sys.AvailableFreeSpace / 1GB, 2)
            if ($freeGB -lt 2) { Write-Both "系统盘可用空间仅 $freeGB GB，可能不足" 'WARN' }
        }
        catch { }
    }

    # 执行
    $btnStart.Enabled = $false; $btnRescan.Enabled = $false; $btnStop.Enabled = $true
    $grpList.Enabled = $false; $grpMode.Enabled = $false
    $script:StopRequested = $false
    $pb.Value = 0
    $dryTag = if ($dry) { '（演练模式）' } else { '' }
    Write-Both ("开始{0}：共 {1} 项，单项超时 {2} 秒，自动重试 {3} 次，安装位置={4}{5}" -f $verb, $selected.Count, $timeout, $retries, $(if ($root) { $root } else { '默认' }), $dryTag)

    $done = 0; $ok = 0; $skipped = 0; $failed = 0; $timeouts = 0; $fallbacks = 0
    $failList = New-Object System.Collections.Generic.List[string]
    $adminNeeded = $false

    try {
        foreach ($row in $selected) {
            if ($script:StopRequested) { Write-Both '已中断，剩余项不再处理。' 'WARN'; break }
            $app = $row.App
            $pct = [int](100 * $done / $selected.Count)
            $pb.Value = [Math]::Min(99, $pct)
            $script:StatusPrefix = "{0}/{1}  {2} {3}" -f ($done + 1), $selected.Count, $verb, $app.Name
            $lblStatus.Text = $script:StatusPrefix
            Write-Progress -Activity 'winget 批量处理' -Status $script:StatusPrefix -PercentComplete $pct
            [System.Windows.Forms.Application]::DoEvents()

            if ($mode -eq 'upgrade' -and -not $row.Installed) {
                Write-Both ("{0,-22} 未安装，升级模式跳过" -f $app.Name) 'SKIP'; $skipped++; $done++
                $row.Item.SubItems[4].Text = '跳过(未安装)'; $pb.Value = [int](100 * $done / $selected.Count); [System.Windows.Forms.Application]::DoEvents(); continue
            }
            if ($mode -eq 'upgrade' -and -not $row.Available) {
                Write-Both ("{0,-22} 已是最新，跳过" -f $app.Name) 'SKIP'; $skipped++; $done++
                $row.Item.SubItems[4].Text = '跳过(已最新)'; $pb.Value = [int](100 * $done / $selected.Count); [System.Windows.Forms.Application]::DoEvents(); continue
            }
            if ($mode -eq 'install' -and $row.Installed) {
                Write-Both ("{0,-22} 已安装，跳过" -f $app.Name) 'SKIP'; $skipped++; $done++
                $row.Item.SubItems[4].Text = '跳过(已装)'; $pb.Value = [int](100 * $done / $selected.Count); [System.Windows.Forms.Application]::DoEvents(); continue
            }

            $loc = Get-EffectiveLocation -App $app -Root $root -PerAppSubfolder $perApp
            if ($dry) {
                Write-Both ("{0,-22} [演练] winget {1} --id {2}{3} （不实际执行）" -f $app.Name, $mode, $app.Id, $(if ($loc) { " --location `"$loc`"" } else { '' })) 'WARN'
                $row.Item.SubItems[4].Text = '演练'
                $ok++; $done++
                $pb.Value = [int](100 * $done / $selected.Count); [System.Windows.Forms.Application]::DoEvents(); continue
            }

            Write-Both ("{0,-22} {1}中…{2}" -f $app.Name, $verb, $(if ($loc) { " 目标位置：$loc" } else { '' }))
            $pb.Style = 'Marquee'; [System.Windows.Forms.Application]::DoEvents()

            $task = $null
            try {
                $task = Invoke-AppTask -App $app -Mode $mode -Location $loc -LocationFallbackPolicy $policy `
                    -TimeoutSec $timeout -MaxRetries $retries -Logger $script:Logger -WingetExe $script:WingetExe `
                    -Progress { param($s) if ($script:StatusLabel -and $script:StatusPrefix) { $script:StatusLabel.Text = "{0}  （已用时 {1} 秒）" -f $script:StatusPrefix, $s } } `
                    -ShouldStop { $script:StopRequested }
            }
            catch {
                Write-Both ("{0,-22} [X] 执行时发生异常：{1}" -f $app.Name, $_.Exception.Message) 'ERR'
                $task = [pscustomobject]@{ Status = '失败'; Info = [pscustomobject]@{ Kind = 'EXCEPTION'; Message = $_.Exception.Message; NeedsAdmin = $false; HResult = '-' }; Result = [pscustomobject]@{ Seconds = 0 }; Attempts = 1; UsedLocation = $loc; LocationFallback = $false }
            }
            finally { $pb.Style = 'Continuous' }

            if ($task.Info -and $task.Info.NeedsAdmin) { $adminNeeded = $true }

            switch ($task.Status) {
                '成功' {
                    Write-Both ("{0,-22} [OK] {1}完成（{2}s，尝试 {3} 次）" -f $app.Name, $verb, $task.Result.Seconds, $task.Attempts) 'OK'
                    $row.Item.SubItems[4].Text = "$verb 成功"; $row.Item.ForeColor = [System.Drawing.Color]::FromArgb(0, 110, 60); $ok++
                    if ($task.UsedLocation) { $row.Item.SubItems[5].Text = $task.UsedLocation }
                }
                '回退成功' {
                    $fallbacks++
                    Write-Both ("{0,-22} [OK] 已安装，但该安装包不支持自定义位置，装到了默认位置" -f $app.Name) 'WARN'
                    $row.Item.SubItems[4].Text = '已装(默认位置)'; $row.Item.ForeColor = [System.Drawing.Color]::FromArgb(176, 96, 0); $ok++
                    $row.Item.SubItems[5].Text = '默认（不支持自定义）'
                }
                '跳过' {
                    $msg = if ($task.Info) { $task.Info.Message } else { '跳过' }
                    Write-Both ("{0,-22} 跳过：{1}" -f $app.Name, $msg) 'SKIP'
                    $row.Item.SubItems[4].Text = "跳过($msg)"; $skipped++
                }
                '超时' {
                    $timeouts++; $failed++
                    Write-Both ("{0,-22} [超时] {1}（用时 {2}s）" -f $app.Name, $task.Info.Message, $task.Result.Seconds) 'ERR'
                    $row.Item.SubItems[4].Text = '超时终止'; $row.Item.ForeColor = [System.Drawing.Color]::Firebrick
                    $failList.Add(("{0}（{1}）超时：调大「单项超时」或改善网络后重试" -f $app.Name, $app.Id))
                }
                '已中断' {
                    Write-Both ("{0,-22} 已被中断" -f $app.Name) 'WARN'
                    $row.Item.SubItems[4].Text = '已中断'
                    $done++; break
                }
                default {
                    $failed++
                    $info = $task.Info
                    $hint = switch ($info.Kind) {
                        'NEEDS_ADMIN' { '→ 点「以管理员身份重启」后重试' }
                        'UAC_CANCELLED' { '→ 重试并在 UAC 窗口点「是」' }
                        'NET_UNREACHABLE' { '→ 检查网络/代理（代理会显著拖慢或阻断下载）' }
                        'NET_DNS' { '→ 检查 DNS 设置' }
                        'NET_TIMEOUT' { '→ 调大超时或改善网络' }
                        'DISK_FULL' { '→ 清理目标盘空间或改安装位置' }
                        'FILE_IN_USE' { '→ 先关闭该应用再重试' }
                        'INSTALL_IN_PROGRESS' { '→ 等其它安装完成后再试' }
                        'REBOOT_REQUIRED' { '→ 重启后生效' }
                        'HASH_MISMATCH' { '→ 清源缓存后重试：winget source reset --force' }
                        'PACKAGE_NOT_FOUND' { '→ 源里没有该包，请核对包 ID' }
                        'LOCATION_UNSUPPORTED' { '→ 该包不支持自定义位置，可改为「回退默认位置」' }
                        'LOCATION_INVALID' { '→ 换一个安装路径' }
                        'MSI_FATAL' { '→ 查看 %TEMP% 下 MSI 日志，或手动安装' }
                        'EXCEPTION' { '→ 见日志详情' }
                        default { '' }
                    }
                    Write-Both ("{0,-22} [X] {1}失败：{2}（{3}，{4}s）{5}" -f $app.Name, $verb, $info.Message, $info.HResult, $task.Result.Seconds, $hint) 'ERR'
                    $row.Item.SubItems[4].Text = "失败($($info.Kind))"; $row.Item.ForeColor = [System.Drawing.Color]::Firebrick
                    $failList.Add(("{0}（{1}）{2} [{3}] {4}" -f $app.Name, $app.Id, $info.Message, $info.HResult, $hint))
                }
            }
            $done++
            $pb.Value = [int](100 * $done / $selected.Count)
            [System.Windows.Forms.Application]::DoEvents()
        }
    }
    catch {
        Write-Both "执行过程中出现未预期的异常：$($_.Exception.Message)" 'ERR'
        try { Add-Content -LiteralPath $LogPath -Value $_.ScriptStackTrace -Encoding UTF8 } catch { }
    }
    finally {
        Write-Progress -Activity 'winget 批量处理' -Completed
        $pb.Style = 'Continuous'
        $pb.Value = 100
        $lblStatus.Text = "完成：成功 $ok / 跳过 $skipped / 失败 $failed"
        $btnStart.Enabled = $true; $btnRescan.Enabled = $true; $btnStop.Enabled = $false
        $grpList.Enabled = $true; $grpMode.Enabled = $true
    }

    Write-Both ("全部结束：成功 {0}（其中回退默认位置 {1}），跳过 {2}，失败 {3}（超时 {4}）" -f $ok, $fallbacks, $skipped, $failed, $timeouts) $(if ($failed) { 'WARN' } else { 'OK' })
    if ($adminNeeded) { Write-Both '有项目因权限不足失败：可点「以管理员身份重启」后再试。' 'WARN' }

    $msg = "成功 $ok 项（其中 $fallbacks 项回退到默认位置），跳过 $skipped 项，失败 $failed 项（超时 $timeouts）。`n`n日志：$LogPath"
    if ($failList.Count) { $msg += "`n`n需要处理的项目：`n" + (($failList | Select-Object -First 8) -join "`n") }
    if ($adminNeeded) { $msg += "`n`n提示：有权限类失败，可点「以管理员身份重启」。" }
    if (-not $AutoRun) {
        [void][System.Windows.Forms.MessageBox]::Show($msg, '执行结果', 'OK', $(if ($failed) { 'Warning' } else { 'Information' }))
    }
    else { Write-Both '（AutoRun：跳过结果弹窗，直接关窗）' 'WARN' }

    if ($AutoRun) { $form.Close() }
})

$form.Add_Shown({
    Add-CatalogRows
    Write-Both "窗口已就绪。日志：$LogPath"
    Write-Both ("winget {0} | 管理员={1} | 单项超时={2}s | 自动重试={3} | 自定义位置={4}" -f `
        ((& $script:WingetExe --version) -replace '\s', ''), `
        ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator), `
        $numTimeout.Value, $numRetry.Value, $(if ($chkUseLoc.Checked) { $txtLoc.Text } else { '无' }))
    Invoke-Scan
    if ($AutoRun) { $btnStart.PerformClick() }
})

[void]$form.ShowDialog()
Write-Both '窗口已关闭。'
