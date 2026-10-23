# app-lib.ps1
# 共享逻辑库：图形版与命令行版都 dot-source 本文件。
# 内容：winget 定位/调用（超时+串流+重试）、错误分类与中文解释、安装路径校验、
#       目标程序占用检测、状态快照。
# 约定：调用方负责先加载 app-catalog.ps1（提供 $Catalog）。

# ---------------------------------------------------------------------------
# 日志：调用方注入 -Logger 脚本块；未注入时退化为 Write-Host
# ---------------------------------------------------------------------------
function Write-DefaultLog {
    param([string]$Message, [string]$Level = 'INFO')
    $color = switch ($Level) { 'OK' { 'Green' } 'WARN' { 'Yellow' } 'ERR' { 'Red' } 'SKIP' { 'DarkGray' } 'WG' { 'Cyan' } default { 'Gray' } }
    Write-Host ("[{0:HH:mm:ss}] [{1,-4}] {2}" -f (Get-Date), $Level, $Message) -ForegroundColor $color
}

function Invoke-Log {
    param([scriptblock]$Logger, [string]$Message, [string]$Level = 'INFO')
    if ($Logger) { & $Logger $Message $Level } else { Write-DefaultLog -Message $Message -Level $Level }
}

# ---------------------------------------------------------------------------
# 解析 winget 可执行路径
# ---------------------------------------------------------------------------
function Resolve-WingetExe {
    $c = Get-Command winget -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    return 'winget'
}

# ---------------------------------------------------------------------------
# 错误分类：HRESULT 解码 + 输出文本模式匹配 → 中文解释与处置建议
#   实测样例（本机 winget 1.29.380）：
#     exit=-2147012867 → 0x80072EFD  "InternetOpenUrl() failed."        （网络不可达）
#     exit=-1978335189 → 0x8A15002B  "No available upgrade found."      （无可用升级）
# ---------------------------------------------------------------------------
function ConvertTo-HResultText {
    param([int]$ExitCode)
    $u = [int64]$ExitCode -band 0xFFFFFFFFL
    return ('0x{0:X8}' -f $u)
}

function Get-ErrorPatternTable {
    # Pattern 用 ASCII 片段，避免中文编码差异导致匹配失败
    return @(
        [pscustomobject]@{ Kind = 'NO_UPGRADE';            Retryable = $false; NeedsAdmin = $false; LocationIssue = $false; Reboot = $false; Pattern = 'No applicable upgrade found|No newer package versions|No available upgrade found'; Message = '没有可用的升级版本（已是最新）' }
        [pscustomobject]@{ Kind = 'ALREADY_INSTALLED';     Retryable = $false; NeedsAdmin = $false; LocationIssue = $false; Reboot = $false; Pattern = 'Found an existing package already installed'; Message = '该应用已安装' }
        [pscustomobject]@{ Kind = 'LOCATION_UNSUPPORTED';  Retryable = $false; NeedsAdmin = $false; LocationIssue = $true;  Reboot = $false; Pattern = 'does not support.*location|location.*not supported|support a custom install location'; Message = '该安装包不支持自定义安装位置' }
        [pscustomobject]@{ Kind = 'LOCATION_INVALID';      Retryable = $false; NeedsAdmin = $false; LocationIssue = $true;  Reboot = $false; Pattern = 'invalid.*install location|install location.*invalid|cannot create.*location|The specified path is invalid'; Message = '指定的安装位置无效' }
        [pscustomobject]@{ Kind = 'NET_UNREACHABLE';       Retryable = $true;  NeedsAdmin = $false; LocationIssue = $false; Reboot = $false; Pattern = 'InternetOpenUrl\(\) failed|0x80072efd|WININET_E_CANNOT_CONNECT'; Message = '无法连接下载服务器（网络/代理问题）' }
        [pscustomobject]@{ Kind = 'NET_DNS';               Retryable = $true;  NeedsAdmin = $false; LocationIssue = $false; Reboot = $false; Pattern = '0x80072ee7|name resolution|No such host is known'; Message = '域名解析失败（DNS 问题）' }
        [pscustomobject]@{ Kind = 'NET_TIMEOUT';           Retryable = $true;  NeedsAdmin = $false; LocationIssue = $false; Reboot = $false; Pattern = '0x80072ee2|timed out|timeout'; Message = '网络超时' }
        [pscustomobject]@{ Kind = 'NEEDS_ADMIN';           Retryable = $false; NeedsAdmin = $true;  LocationIssue = $false; Reboot = $false; Pattern = 'requires administrator|requires elevation|must be run.*elevated|Access is denied|0x80070005'; Message = '需要管理员权限' }
        [pscustomobject]@{ Kind = 'UAC_CANCELLED';         Retryable = $false; NeedsAdmin = $true;  LocationIssue = $false; Reboot = $false; Pattern = 'operation was canceled by the user|0x800704c7|User cancelled'; Message = '授权被取消（UAC 被拒绝）' }
        [pscustomobject]@{ Kind = 'DISK_FULL';             Retryable = $false; NeedsAdmin = $false; LocationIssue = $false; Reboot = $false; Pattern = 'not enough space|insufficient disk|disk full|0x80070070'; Message = '磁盘空间不足' }
        [pscustomobject]@{ Kind = 'FILE_IN_USE';           Retryable = $true;  NeedsAdmin = $false; LocationIssue = $false; Reboot = $false; Pattern = 'being used by another process|file is in use|0x80070020|close the application'; Message = '目标程序正在运行，文件被占用' }
        [pscustomobject]@{ Kind = 'INSTALL_IN_PROGRESS';   Retryable = $true;  NeedsAdmin = $false; LocationIssue = $false; Reboot = $false; Pattern = 'another installation is in progress|0x80070652|installations are in progress'; Message = '另一个安装正在进行' }
        [pscustomobject]@{ Kind = 'REBOOT_REQUIRED';       Retryable = $false; NeedsAdmin = $false; LocationIssue = $false; Reboot = $true;  Pattern = 'restart.*required|reboot.*required|3010'; Message = '需要重启后生效' }
        [pscustomobject]@{ Kind = 'HASH_MISMATCH';         Retryable = $false; NeedsAdmin = $false; LocationIssue = $false; Reboot = $false; Pattern = 'hash.*mismatch|0x8a150014|Installer hash'; Message = '安装包哈希校验失败' }
        [pscustomobject]@{ Kind = 'PACKAGE_NOT_FOUND';     Retryable = $false; NeedsAdmin = $false; LocationIssue = $false; Reboot = $false; Pattern = 'No package found|0x8a150014|does not exist in the configured sources'; Message = '在 winget 源中找不到该包' }
        [pscustomobject]@{ Kind = 'MSI_FATAL';             Retryable = $false; NeedsAdmin = $false; LocationIssue = $false; Reboot = $false; Pattern = '0x80070643|fatal error during installation'; Message = '安装程序内部错误（MSI 1603）' }
        [pscustomobject]@{ Kind = 'TIMEOUT_LOCAL';         Retryable = $true;  NeedsAdmin = $false; LocationIssue = $false; Reboot = $false; Pattern = '__never_matches__'; Message = '超过单项超时，已终止' }
        [pscustomobject]@{ Kind = 'STOPPED';               Retryable = $false; NeedsAdmin = $false; LocationIssue = $false; Reboot = $false; Pattern = '__never_matches__'; Message = '已被用户中断' }
    )
}

function Get-HResultHintTable {
    # 只有把握的 HRESULT 才登记；不确定的一律靠上面的文本匹配
    return @{
        '0x80070005' = @{ Kind = 'NEEDS_ADMIN';         Message = '拒绝访问（需要管理员权限）' }
        '0x800704C7' = @{ Kind = 'UAC_CANCELLED';       Message = '用户取消了授权（UAC）' }
        '0x80070070' = @{ Kind = 'DISK_FULL';           Message = '磁盘空间不足' }
        '0x80070020' = @{ Kind = 'FILE_IN_USE';         Message = '文件被占用（目标程序可能正在运行）' }
        '0x80072EFD' = @{ Kind = 'NET_UNREACHABLE';     Message = '无法连接下载服务器（网络/代理问题）' }
        '0x80072EE7' = @{ Kind = 'NET_DNS';             Message = '域名解析失败（DNS）' }
        '0x80072EE2' = @{ Kind = 'NET_TIMEOUT';         Message = '网络超时' }
        '0x80070643' = @{ Kind = 'MSI_FATAL';           Message = 'MSI 安装程序内部错误（1603）' }
        '0x80070652' = @{ Kind = 'INSTALL_IN_PROGRESS'; Message = '另一个安装正在进行' }
        '0x8A15002B' = @{ Kind = 'NO_UPGRADE';          Message = '没有可用的升级版本' }
        # 注意：winget 的「需要重启」返回的是十进制 3010（ERROR_SUCCESS_REBOOT_REQUIRED），
        # 它的十六进制是 0x0BC2，不是 0x3010（测试用例 E1 抓过这个错误）
        '0x00000BC2' = @{ Kind = 'REBOOT_REQUIRED';     Message = '需要重启后生效' }
    }
}

function Get-WingetErrorInfo {
    param([int]$ExitCode = 0, [string]$Output = '')
    $hex = ConvertTo-HResultText -ExitCode $ExitCode
    $kind = 'UNKNOWN'; $msg = '未知错误'; $retry = $false; $admin = $false; $loc = $false; $reboot = $false

    # 1) 输出文本优先（最贴近真实原因）
    if ($Output) {
        foreach ($p in Get-ErrorPatternTable) {
            if ($p.Pattern -ne '__never_matches__' -and $Output -match $p.Pattern) {
                $kind = $p.Kind; $msg = $p.Message; $retry = $p.Retryable; $admin = $p.NeedsAdmin; $loc = $p.LocationIssue; $reboot = $p.Reboot
                break
            }
        }
    }
    # 2) 再看 HRESULT
    if ($kind -eq 'UNKNOWN') {
        $hint = (Get-HResultHintTable)[$hex]
        if ($hint) {
            $kind = $hint.Kind; $msg = $hint.Message
            foreach ($p in Get-ErrorPatternTable) { if ($p.Kind -eq $kind) { $retry = $p.Retryable; $admin = $p.NeedsAdmin; $loc = $p.LocationIssue; $reboot = $p.Reboot; break } }
        }
    }
    # 3) 都没有：如果输出里提到 location，按位置问题处理
    if ($kind -eq 'UNKNOWN' -and $Output -match 'location') {
        $kind = 'LOCATION_UNSUPPORTED'; $msg = '安装位置相关错误'; $loc = $true
    }

    return [pscustomobject]@{
        HResult = $hex; ExitCode = $ExitCode; Kind = $kind; Message = $msg
        Retryable = $retry; NeedsAdmin = $admin; LocationIssue = $loc; RebootRequired = $reboot
    }
}

# ---------------------------------------------------------------------------
# 安装路径校验与计算
# ---------------------------------------------------------------------------
function Test-InstallLocationPath {
    param([string]$Path, [double]$MinFreeGB = 2.0)

    $res = [pscustomobject]@{ Ok = $false; Reason = ''; Drive = ''; FreeGB = 0; Created = $false }
    if ([string]::IsNullOrWhiteSpace($Path)) { $res.Reason = '路径为空'; return $res }
    if ($Path -match '[<>"|?*\x00-\x1F]') { $res.Reason = "路径含非法字符（< > `" | ? * 或控制字符）"; return $res }
    if (-not [IO.Path]::IsPathRooted($Path)) { $res.Reason = '必须是绝对路径（例如 D:\Apps）'; return $res }

    $qualifier = ''
    try { $qualifier = [IO.Path]::GetPathRoot($Path) } catch { $res.Reason = '无法解析盘符'; return $res }
    $res.Drive = $qualifier
    if (-not (Test-Path -LiteralPath $qualifier)) { $res.Reason = "盘符不存在：$qualifier"; return $res }

    if (Test-Path -LiteralPath $Path) {
        if (-not (Get-Item -LiteralPath $Path).PSIsContainer) { $res.Reason = '该路径已存在且是一个文件，不是文件夹'; return $res }
    }
    else {
        try { [void](New-Item -ItemType Directory -Force -Path $Path -ErrorAction Stop); $res.Created = $true }
        catch { $res.Reason = "无法创建目录：$($_.Exception.Message)"; return $res }
    }

    # 可写性
    try {
        $probe = Join-Path $Path ('.write-test-{0}' -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
        [IO.File]::WriteAllText($probe, 'x')
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
    }
    catch { $res.Reason = '目录不可写（可能需要管理员权限）'; return $res }

    # 剩余空间
    try {
        $d = [IO.DriveInfo]::new($qualifier)
        $res.FreeGB = [math]::Round($d.AvailableFreeSpace / 1GB, 2)
    }
    catch { $res.FreeGB = -1 }
    if ($res.FreeGB -ge 0 -and $res.FreeGB -lt $MinFreeGB) {
        $res.Reason = ("可用空间不足：{0} GB（建议至少 {1} GB）" -f $res.FreeGB, $MinFreeGB); return $res
    }

    $res.Ok = $true
    return $res
}

function Get-SafeFolderName {
    param([string]$Name)
    if (-not $Name) { return 'App' }
    $s = $Name -replace '[\\/:*?"<>|]', '_'
    $s = $s.Trim().TrimEnd('.')
    if ($s.Length -gt 60) { $s = $s.Substring(0, 60) }
    return $s
}

function Get-EffectiveLocation {
    param($App, [string]$Root, [bool]$PerAppSubfolder = $true)
    # 清单里按应用固定的路径优先级最高
    if ($App.PSObject.Properties.Name -contains 'Location' -and $App.Location) { return [string]$App.Location }
    if ([string]::IsNullOrWhiteSpace($Root)) { return '' }
    if ($PerAppSubfolder) { return [IO.Path]::Combine($Root, (Get-SafeFolderName -Name $App.Name)) }
    return $Root
}

# ---------------------------------------------------------------------------
# 目标程序是否正在运行（用桌面快捷方式解析出的目标 exe 名来判断）
# ---------------------------------------------------------------------------
function Get-DesktopShortcutTargetMap {
    $map = @{}
    $dirs = @([Environment]::GetFolderPath('Desktop'), (Join-Path $env:PUBLIC 'Desktop')) | Select-Object -Unique
    try { $sh = New-Object -ComObject WScript.Shell } catch { return $map }
    foreach ($d in $dirs) {
        if (-not (Test-Path -LiteralPath $d)) { continue }
        foreach ($f in (Get-ChildItem -LiteralPath $d -Force -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -eq '.lnk' })) {
            try {
                $t = $sh.CreateShortcut($f.FullName)
                if ($t.TargetPath) { $map[[IO.Path]::GetFileNameWithoutExtension($f.Name)] = $t.TargetPath }
            }
            catch { }
        }
    }
    return $map
}

function Get-RunningProcessForApp {
    param($App, [hashtable]$ShortcutMap)
    $result = @()
    if (-not $ShortcutMap -or -not $App.Shortcut) { return $result }
    $key = @($ShortcutMap.Keys | Where-Object { $_ -like "*$($App.Shortcut)*" } | Select-Object -First 1)
    if (-not $key) { return $result }
    $target = $ShortcutMap[$key[0]]
    if (-not $target) { return $result }
    $exe = [IO.Path]::GetFileNameWithoutExtension($target)
    if (-not $exe) { return $result }
    $result = @(Get-Process -Name $exe -ErrorAction SilentlyContinue)
    return $result
}

# ---------------------------------------------------------------------------
# 状态快照：一次 winget list 得到全部条目的已装/可用版本
# ---------------------------------------------------------------------------
function Get-StatusSnapshot {
    param([scriptblock]$Logger, [string]$WingetExe)
    if (-not $WingetExe) { $WingetExe = Resolve-WingetExe }
    $out = ''
    try { $out = & $WingetExe list --accept-source-agreements --disable-interactivity 2>&1 | Out-String }
    catch { Invoke-Log -Logger $Logger -Message "winget list 失败：$($_.Exception.Message)" -Level 'ERR' }

    $lines = @($out -split "`r?`n" | Where-Object { $_ -match '\S' })
    $map = @{}
    foreach ($app in $Catalog) {
        # 精确匹配包 ID（按空白边界），避免 Microsoft.Office 命中 Microsoft.Office.ActionsServer 这类前缀条目
        $idPattern = '(^|\s)' + [regex]::Escape($app.Id) + '(\s|$)'
        $hit = $lines | Where-Object { $_ -match $idPattern } | Select-Object -First 1
        if (-not $hit) { $map[$app.Id] = [pscustomobject]@{ Installed = $false; Version = ''; Available = '' }; continue }
        $idx = $hit.IndexOf($app.Id)
        $rest = $hit.Substring($idx + $app.Id.Length).Trim()
        $tok = @($rest -split '\s+' | Where-Object { $_ })
        $ver = if ($tok.Count -ge 1) { $tok[0] } else { '' }
        $avail = ''
        if ($tok.Count -ge 2 -and $tok[1] -notin @('winget', 'msstore')) { $avail = $tok[1] }
        $map[$app.Id] = [pscustomobject]@{ Installed = $true; Version = $ver; Available = $avail }
    }
    return $map
}

# ---------------------------------------------------------------------------
# 调用一次 winget：输出实时串流 + 超时终止 + 中断支持
#   -Logger    : 日志回调 (Message, Level)
#   -Progress  : 进度回调 (StatusText)  用于更新「已用时」等
#   -ShouldStop: 返回 $true 时中断
# ---------------------------------------------------------------------------
function Invoke-WingetTask {
    param(
        [string[]]$WgArgs,
        [int]$TimeoutSec = 1800,
        [scriptblock]$Logger,
        [scriptblock]$Progress,
        [scriptblock]$ShouldStop,
        [string]$WingetExe
    )
    if (-not $WingetExe) { $WingetExe = Resolve-WingetExe }
    $outFile = Join-Path $env:TEMP ("wg-out-{0}.txt" -f ([guid]::NewGuid().ToString('N')))
    $errFile = Join-Path $env:TEMP ("wg-err-{0}.txt" -f ([guid]::NewGuid().ToString('N')))
    $proc = $null
    $timedOut = $false; $stopped = $false; $launchError = ''
    $sw = [Diagnostics.Stopwatch]::StartNew()

    try {
        $proc = Start-Process -FilePath $WingetExe -ArgumentList $WgArgs -NoNewWindow -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile -ErrorAction Stop
        # 关键：PS 5.1 下不打开 EnableRaisingEvents 就读不到 ExitCode（会被误判为失败）
        $proc.EnableRaisingEvents = $true
    }
    catch {
        $launchError = $_.Exception.Message
        Invoke-Log -Logger $Logger -Message "无法启动 winget：$launchError" -Level 'ERR'
    }

    if ($proc) {
        $readOut = 0; $readErr = 0
        while (-not $proc.HasExited) {
            Start-Sleep -Milliseconds 400
            foreach ($pair in @(@($outFile, 'out'), @($errFile, 'err'))) {
                $f = $pair[0]
                if (-not (Test-Path -LiteralPath $f)) { continue }
                $all = @(Get-Content -LiteralPath $f -ErrorAction SilentlyContinue)
                if ($pair[1] -eq 'out') {
                    if ($all.Count -gt $readOut) {
                        for ($i = $readOut; $i -lt $all.Count; $i++) { Invoke-Log -Logger $Logger -Message ("   winget| " + $all[$i]) -Level 'WG' }
                        $readOut = $all.Count
                    }
                }
                else {
                    if ($all.Count -gt $readErr) {
                        for ($i = $readErr; $i -lt $all.Count; $i++) { Invoke-Log -Logger $Logger -Message ("   stderr| " + $all[$i]) -Level 'WARN' }
                        $readErr = $all.Count
                    }
                }
            }
            if ($Progress) { & $Progress ([math]::Round($sw.Elapsed.TotalSeconds)) }
            if ($ShouldStop -and (& $ShouldStop)) { $stopped = $true; break }
            if ($sw.Elapsed.TotalSeconds -gt $TimeoutSec) { $timedOut = $true; break }
            try { $proc.Refresh() } catch { }
        }

        if ($timedOut -or $stopped) {
            try { & taskkill /T /F /PID $proc.Id 2>&1 | Out-Null } catch { }
            Start-Sleep -Milliseconds 600
        }
        try { [void]$proc.WaitForExit(8000) } catch { }
    }

    $text = ''
    foreach ($f in @($outFile, $errFile)) {
        if (Test-Path -LiteralPath $f) { $text += (Get-Content -LiteralPath $f -Raw -ErrorAction SilentlyContinue) + "`n" }
        Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
    }

    $code = 0
    if ($launchError) { $code = -1 }
    elseif ($timedOut -or $stopped) { $code = -1 }
    else { try { $code = [int]$proc.ExitCode } catch { $code = -1 } }

    return [pscustomobject]@{
        Code = $code; TimedOut = $timedOut; Stopped = $stopped
        Output = $text; Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        LaunchError = $launchError
    }
}

# ---------------------------------------------------------------------------
# 执行一个应用的安装/升级：参数组装 + 错误分类 + 可重试退避 + 位置回退
#   返回 Status ∈ 成功 / 回退成功 / 跳过 / 失败 / 超时 / 已中断
# ---------------------------------------------------------------------------
function Invoke-AppTask {
    param(
        $App,
        [ValidateSet('install', 'upgrade')][string]$Mode,
        [string]$Location = '',
        [ValidateSet('fallback', 'skip')][string]$LocationFallbackPolicy = 'fallback',
        [int]$TimeoutSec = 1800,
        [int]$MaxRetries = 1,
        [string[]]$ExtraArgs = @(),
        [scriptblock]$Logger,
        [scriptblock]$Progress,
        [scriptblock]$ShouldStop,
        [string]$WingetExe
    )
    if (-not $WingetExe) { $WingetExe = Resolve-WingetExe }
    $verb = if ($Mode -eq 'upgrade') { '升级' } else { '安装' }
    $baseArgs = @($Mode, '--id', $App.Id, '--exact', '--source', 'winget',
                  '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity', '--silent')
    if ($ExtraArgs) { $baseArgs += $ExtraArgs }

    $usedLocation = ''
    $locationFallback = $false
    $attempt = 0
    $last = $null
    $lastInfo = $null

    while ($true) {
        $attempt++
        $wgArgs = @($baseArgs)
        if ($Location) { $wgArgs += @('--location', $Location); $usedLocation = $Location }
        else { $usedLocation = '' }

        if ($Progress) { & $Progress 0 }
        $last = Invoke-WingetTask -WgArgs $wgArgs -TimeoutSec $TimeoutSec -Logger $Logger -Progress $Progress -ShouldStop $ShouldStop -WingetExe $WingetExe

        if ($last.Stopped) { return [pscustomobject]@{ Status = '已中断'; Info = $null; Result = $last; Attempts = $attempt; UsedLocation = $usedLocation; LocationFallback = $locationFallback } }
        if ($last.TimedOut) {
            $info = Get-WingetErrorInfo -ExitCode -1 -Output 'timeout'
            $info.Kind = 'TIMEOUT_LOCAL'; $info.Message = "超过单项超时（$TimeoutSec 秒），已终止"; $info.Retryable = $true
            $lastInfo = $info
            if ($attempt -le $MaxRetries) { Invoke-Log -Logger $Logger -Message ("{0} 超时，{1} 秒后重试（第 {2} 次）" -f $App.Name, 5, $attempt) -Level 'WARN'; Start-Sleep -Seconds 5; continue }
            return [pscustomobject]@{ Status = '超时'; Info = $info; Result = $last; Attempts = $attempt; UsedLocation = $usedLocation; LocationFallback = $locationFallback }
        }
        if ($last.LaunchError) {
            $info = Get-WingetErrorInfo -ExitCode -1 -Output $last.LaunchError
            return [pscustomobject]@{ Status = '失败'; Info = $info; Result = $last; Attempts = $attempt; UsedLocation = $usedLocation; LocationFallback = $locationFallback }
        }

        $info = Get-WingetErrorInfo -ExitCode $last.Code -Output $last.Output
        $lastInfo = $info

        if ($last.Code -eq 0) {
            return [pscustomobject]@{ Status = $(if ($locationFallback) { '回退成功' } else { '成功' }); Info = $info; Result = $last; Attempts = $attempt; UsedLocation = $usedLocation; LocationFallback = $locationFallback }
        }

        # 位置「不支持」才回退（或跳过）；位置「无效」属于用户配置错误，必须报错——
        # 不能在用户明确要求路径的情况下偷偷装到别处
        if ($info.Kind -eq 'LOCATION_UNSUPPORTED' -and $usedLocation -and -not $locationFallback) {
            if ($LocationFallbackPolicy -eq 'skip') {
                Invoke-Log -Logger $Logger -Message ("{0} 不支持自定义安装位置，按策略跳过（未安装）" -f $App.Name) -Level 'WARN'
                return [pscustomobject]@{ Status = '跳过'; Info = $info; Result = $last; Attempts = $attempt; UsedLocation = $usedLocation; LocationFallback = $false }
            }
            Invoke-Log -Logger $Logger -Message ("{0} 不支持自定义安装位置，回退到默认位置重试" -f $App.Name) -Level 'WARN'
            $locationFallback = $true
            $attempt--
            $Location = ''
            continue
        }

        # 无可用升级 / 已安装：不算失败
        if ($info.Kind -in @('NO_UPGRADE', 'ALREADY_INSTALLED')) {
            return [pscustomobject]@{ Status = '跳过'; Info = $info; Result = $last; Attempts = $attempt; UsedLocation = $usedLocation; LocationFallback = $locationFallback }
        }

        # 可重试错误：退避后重试
        if ($info.Retryable -and $attempt -le $MaxRetries) {
            $wait = [math]::Min(30, 5 * $attempt)
            Invoke-Log -Logger $Logger -Message ("{0} {1}，{2} 秒后重试（第 {3} 次，共 {4} 次）" -f $App.Name, $info.Message, $wait, $attempt, $MaxRetries) -Level 'WARN'
            Start-Sleep -Seconds $wait
            continue
        }

        return [pscustomobject]@{ Status = '失败'; Info = $info; Result = $last; Attempts = $attempt; UsedLocation = $usedLocation; LocationFallback = $locationFallback }
    }
}
