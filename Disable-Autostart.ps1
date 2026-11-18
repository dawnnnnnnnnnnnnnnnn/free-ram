<#
.SYNOPSIS
    禁用开机自启项（注册表 Run / 启动文件夹 / 计划任务 / 自动服务），带完整备份与一键恢复。

.DESCRIPTION
    默认只做「列出」。加 -Disable 才动手，动手前把每一项原始状态写进备份 JSON，
    -Restore 可原样还原（注册表值、启动文件夹快捷方式、计划任务状态、服务启动类型）。

    内置规则命中常见国产全家桶的更新器与自启壳，同时有一份硬保护名单：
    dsh-web / napcat / ctfmon / SecurityHealth / aTrust / 输入法服务 等永远不会被选中。

.PARAMETER Match
    命中规则（正则，匹配「名称 + 命令」）。默认是一条常见的全家桶清单。

.PARAMETER Protect
    额外保护名单（正则），优先级高于 Match。

.PARAMETER Scope
    只处理某几类：Reg / Startup / Task / Service。默认 Reg + Startup + Task（不动服务）。

.PARAMETER Restore
    按备份文件还原。

.EXAMPLE
    .\Disable-Autostart.ps1
    .\Disable-Autostart.ps1 -Disable -DryRun
    .\Disable-Autostart.ps1 -Disable
    .\Disable-Autostart.ps1 -Match 'wps|dingtalk|workbuddy' -Disable
    .\Disable-Autostart.ps1 -Restore
    .\Disable-Autostart.ps1 -Restore -WhatIf
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Match,

    [string[]]$Protect = @(),

    [string[]]$Scope = @('Reg', 'Startup', 'Task'),

    [switch]$Disable,
    [switch]$Restore,
    [switch]$OverrideProtect,
    [switch]$DryRun,
    [string]$BackupPath
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# -Scope 支持 "Reg,Startup" 这种单参数逗号写法（-File 调用时 PowerShell 不会自动拆分）
$Scope = @($Scope | ForEach-Object { $_ -split '[,;]' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
foreach ($sc in $Scope) {
    if ($sc -notin @('Reg', 'Startup', 'Task', 'Service', 'All')) {
        Write-Host "未知 Scope：$sc（可选 Reg / Startup / Task / Service / All）" -ForegroundColor Red
        return
    }
}

if (-not $BackupPath) { $BackupPath = Join-Path $PSScriptRoot 'autostart-backup.json' }

# 默认命中：常见全家桶的更新器 / 自启壳 / 推广任务
if (-not $Match) {
    $Match = @(
        'wps', 'kingsoft', 'ksolaunch', 'wpscloud', 'wpsoffice',
        'dingtalk', 'dingtalklauncher', 'dingtalkupdate', 'alibaba',
        'workbuddy',
        'quark',
        'baidunetdisk', 'yundetect', 'baidu',
        'bingwallpaper', 'uninstdaemon',
        'edgeautolaunch', 'microsoftedgeautolaunch',
        'softlanding',
        'googleuserpeh', 'platformexperiencehelper',
        'wetype_update', 'wetypeupdate',
        '360', 'qihoo',
        'iqiyi', 'tencentvideo', 'youku', 'thunder', 'xunlei',
        'sogou', 'haozip', '2345', 'liebao', 'hpcommy'
    ) -join '|'
}

# 硬保护：这些东西被禁了用户会骂人。
# 注意 'ROG' 是这台机器的用户名，不能当保护词（会命中 C:\Users\ROG\... 的一切）
$hardProtect = @(
    'dsh-web', 'deepseek', 'napcat',
    'ctfmon', 'securityhealth', 'windefend', 'mdcoresvc',
    'atrust', 'sangfor', 'eaio',
    'wetype_service', 'wetype_server', 'wetype_renderer',
    'nvcontainer', 'nvdisplay', 'nvidia',
    'armoury', 'asus', 'lighting', 'aura',
    'onedrive',
    'intelgraphics', 'realtek', 'rtkaud',
    'xbox', 'gamingservices',
    'mysql', 'steam',
    'explorer', 'sysmain', 'defrag'
) -join '|'
if ($Protect.Count -gt 0) { $hardProtect = $hardProtect + '|' + ($Protect -join '|') }

$doReg = ($Scope -contains 'Reg' -or $Scope -contains 'All')
$doStartup = ($Scope -contains 'Startup' -or $Scope -contains 'All')
$doTask = ($Scope -contains 'Task' -or $Scope -contains 'All')
$doService = ($Scope -contains 'Service' -or $Scope -contains 'All')

# ============================================================
#  采集
# ============================================================

function Get-AutostartItems {
    $items = New-Object System.Collections.Generic.List[object]

    if ($doReg) {
        $runKeys = @(
            @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Root = 'HKLM' },
            @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Root = 'HKLM' },
            @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Root = 'HKCU' },
            @{ Path = 'HKCU:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Root = 'HKCU' }
        )
        foreach ($rk in $runKeys) {
            if (-not (Test-Path -LiteralPath $rk.Path)) { continue }
            try {
                $props = Get-ItemProperty -LiteralPath $rk.Path -ErrorAction Stop
                foreach ($p in $props.PSObject.Properties) {
                    if ($p.Name -like 'PS*') { continue }
                    $items.Add([pscustomobject]@{
                        Kind    = 'Reg'
                        Where   = $rk.Path
                        Root    = $rk.Root
                        Name    = $p.Name
                        Command = [string]$p.Value
                    })
                }
            } catch { }
        }
    }

    if ($doStartup) {
        $folders = @(
            (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'),
            (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Startup')
        )
        foreach ($f in $folders) {
            if (-not (Test-Path -LiteralPath $f)) { continue }
            try {
                Get-ChildItem -LiteralPath $f -File -ErrorAction Stop | ForEach-Object {
                    $items.Add([pscustomobject]@{
                        Kind    = 'Startup'
                        Where   = $f
                        Root    = 'Folder'
                        Name    = $_.Name
                        Command = $_.FullName
                    })
                }
            } catch { }
        }
    }

    if ($doTask) {
        try {
            Get-ScheduledTask -ErrorAction Stop | Where-Object {
                $_.State -ne 'Disabled' -and $_.TaskPath -notmatch '^\\Microsoft\\Windows\\(AppID|DataIntegrity|CertificateServices)'
            } | ForEach-Object {
                $cmd = ''
                try {
                    $cmd = (@($_.Actions) | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join ' ; '
                } catch { }
                $items.Add([pscustomobject]@{
                    Kind    = 'Task'
                    Where   = $_.TaskPath
                    Root    = 'TaskScheduler'
                    Name    = $_.TaskName
                    Command = $cmd
                    TaskObj = $_
                })
            }
        } catch { }
    }

    if ($doService) {
        try {
            Get-CimInstance -ClassName Win32_Service -ErrorAction Stop | Where-Object { $_.StartMode -eq 'Auto' } | ForEach-Object {
                $items.Add([pscustomobject]@{
                    Kind    = 'Service'
                    Where   = 'services'
                    Root    = 'SCM'
                    Name    = $_.Name
                    Command = [string]$_.PathName
                    StartMode = $_.StartMode
                })
            }
        } catch { }
    }

    return $items
}

# ============================================================
#  选择
# ============================================================

$all = @(Get-AutostartItems)
$hit = @()
foreach ($it in $all) {
    $probe = "$($it.Name) $($it.Command)"
    if (-not $OverrideProtect) {
        if ($probe -match $hardProtect) { continue }
    }
    if ($probe -match $Match) { $hit += $it }
}

function Show-List {
    param($Items, $Title, $Color)

    Write-Host ''
    Write-Host "── $Title " -ForegroundColor $Color -NoNewline
    Write-Host ('─' * [Math]::Max(0, 60 - $Title.Length)) -ForegroundColor DarkGray

    if ($Items.Count -eq 0) {
        Write-Host '   （无）' -ForegroundColor DarkGray
        return
    }
    foreach ($g in ($Items | Group-Object Kind)) {
        Write-Host ("  [{0}]" -f $g.Name) -ForegroundColor $Color
        foreach ($it in $g.Group) {
            $cmd = $it.Command
            if ($cmd.Length -gt 78) { $cmd = $cmd.Substring(0, 75) + '...' }
            Write-Host ('   {0,-42} {1}' -f $it.Name, $cmd) -ForegroundColor Gray
        }
    }
}

# ============================================================
#  还原
# ============================================================

function Invoke-Restore {
    if (-not (Test-Path -LiteralPath $BackupPath)) {
        Write-Host "没有备份文件：$BackupPath" -ForegroundColor Yellow
        return
    }
    $data = Get-Content -LiteralPath $BackupPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Host ''
    Write-Host "── 从备份还原 ($($data.items.Count) 项) ──" -ForegroundColor Cyan

    foreach ($it in $data.items) {
        try {
            switch ($it.Kind) {
                'Reg' {
                    if ($DryRun) { Write-Host "  [预览] 还原注册表值 $($it.Name)" -ForegroundColor DarkGray; break }
                    if (-not (Test-Path -LiteralPath $it.Where)) { New-Item -Path $it.Where -Force | Out-Null }
                    Set-ItemProperty -LiteralPath $it.Where -Name $it.Name -Value $it.Command -Force -ErrorAction Stop
                    Write-Host "  ✓ 注册表值 $($it.Name)" -ForegroundColor Green
                }
                'Startup' {
                    if ($DryRun) { Write-Host "  [预览] 放回启动文件夹 $($it.Name)" -ForegroundColor DarkGray; break }
                    if (Test-Path -LiteralPath $it.BackedUpTo) {
                        Copy-Item -LiteralPath $it.BackedUpTo -Destination (Join-Path $it.Where $it.Name) -Force -ErrorAction Stop
                        Write-Host "  ✓ 启动项 $($it.Name)" -ForegroundColor Green
                    }
                }
                'Task' {
                    if ($DryRun) { Write-Host "  [预览] 启用计划任务 $($it.Name)" -ForegroundColor DarkGray; break }
                    Enable-ScheduledTask -TaskName $it.Name -TaskPath $it.Where -ErrorAction Stop | Out-Null
                    Write-Host "  ✓ 计划任务 $($it.Where)$($it.Name)" -ForegroundColor Green
                }
                'Service' {
                    if ($DryRun) { Write-Host "  [预览] 服务 $($it.Name) 恢复为 $($it.OldStartMode)" -ForegroundColor DarkGray; break }
                    Set-Service -Name $it.Name -StartupType $it.OldStartMode -ErrorAction Stop
                    Write-Host "  ✓ 服务 $($it.Name) → $($it.OldStartMode)" -ForegroundColor Green
                }
            }
        } catch {
            Write-Host ("  × {0}：{1}" -f $it.Name, $_.Exception.Message) -ForegroundColor DarkYellow
        }
    }
}

# ============================================================
#  禁用
# ============================================================

function Invoke-Disable {
    param($Items)

    $backup = [ordered]@{
        version = 1
        time    = (Get-Date).ToString('s')
        host    = $env:COMPUTERNAME
        user    = $env:USERNAME
        items   = @()
    }
    $backupDir = Join-Path $PSScriptRoot 'autostart-backup-files'
    if (-not $DryRun -and -not (Test-Path -LiteralPath $backupDir)) {
        New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    }

    $ok = 0
    $fail = 0
    foreach ($it in $Items) {
        $label = "$($it.Name)"
        try {
            switch ($it.Kind) {
                'Reg' {
                    if ($DryRun) {
                        Write-Host "  [预览] 删除注册表 Run 值 $label" -ForegroundColor DarkGray
                        $ok++
                        break
                    }
                    $backup.items += [ordered]@{
                        Kind = 'Reg'; Where = $it.Where; Root = $it.Root; Name = $it.Name; Command = $it.Command
                    }
                    Remove-ItemProperty -LiteralPath $it.Where -Name $it.Name -Force -ErrorAction Stop
                    Write-Host "  ✓ 注册表 $label" -ForegroundColor Green
                    $ok++
                }
                'Startup' {
                    $dest = Join-Path $backupDir $it.Name
                    if ($DryRun) {
                        Write-Host "  [预览] 移出启动文件夹 $label" -ForegroundColor DarkGray
                        $ok++
                        break
                    }
                    $backup.items += [ordered]@{
                        Kind = 'Startup'; Where = $it.Where; Name = $it.Name; Command = $it.Command; BackedUpTo = $dest
                    }
                    Move-Item -LiteralPath $it.Command -Destination $dest -Force -ErrorAction Stop
                    Write-Host "  ✓ 启动项 $label" -ForegroundColor Green
                    $ok++
                }
                'Task' {
                    if ($DryRun) {
                        Write-Host "  [预览] 禁用计划任务 $($it.Where)$label" -ForegroundColor DarkGray
                        $ok++
                        break
                    }
                    $backup.items += [ordered]@{
                        Kind = 'Task'; Where = $it.Where; Name = $it.Name; Command = $it.Command
                    }
                    Disable-ScheduledTask -TaskName $it.Name -TaskPath $it.Where -ErrorAction Stop | Out-Null
                    Write-Host "  ✓ 计划任务 $($it.Where)$label" -ForegroundColor Green
                    $ok++
                }
                'Service' {
                    if ($DryRun) {
                        Write-Host "  [预览] 服务 $label 启动类型 Auto → Manual" -ForegroundColor DarkGray
                        $ok++
                        break
                    }
                    $backup.items += [ordered]@{
                        Kind = 'Service'; Name = $it.Name; Command = $it.Command; OldStartMode = $it.StartMode
                    }
                    Set-Service -Name $it.Name -StartupType Manual -ErrorAction Stop
                    Write-Host "  ✓ 服务 $label → Manual" -ForegroundColor Green
                    $ok++
                }
            }
        } catch {
            Write-Host ("  × {0}：{1}" -f $label, $_.Exception.Message) -ForegroundColor DarkYellow
            $fail++
        }
    }

    if (-not $DryRun) {
        # 追加到已有备份，方便多次禁用后一次全恢复
        $existing = @()
        if (Test-Path -LiteralPath $BackupPath) {
            try {
                $old = Get-Content -LiteralPath $BackupPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $existing = @($old.items)
            } catch { }
        }
        $merged = @($existing) + @($backup.items)
        $obj = [ordered]@{ version = 1; time = $backup.time; host = $backup.host; user = $backup.user; items = $merged }
        ($obj | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $BackupPath -Encoding UTF8
    }

    Write-Host ''
    if ($DryRun) {
        Write-Host "  预览完成：$ok 项将被处理（未执行）" -ForegroundColor Yellow
    } else {
        Write-Host "  完成：成功 $ok 项，失败 $fail 项" -ForegroundColor $(if ($fail -gt 0) { 'Yellow' } else { 'Green' })
        if ($ok -gt 0) {
            Write-Host "  备份已写入：$BackupPath" -ForegroundColor DarkGray
            Write-Host "  想全部还原：.\Disable-Autostart.ps1 -Restore" -ForegroundColor DarkGray
        }
    }
}

# ============================================================
#  主流程
# ============================================================

if ($Restore) {
    Invoke-Restore
    return
}

if (-not $Disable) {
    Write-Host ''
    Write-Host '── 开机自启项清单 ──' -ForegroundColor DarkCyan
    Show-List -Items $all -Title "全部自启（$($all.Count) 项）" -Color Cyan
    Show-List -Items $hit -Title "命中规则、可禁用（$($hit.Count) 项）" -Color Yellow
    Write-Host ''
    Write-Host '  只读模式。真正禁用加 -Disable，先预览用 -Disable -DryRun。' -ForegroundColor DarkGray
    Write-Host '  例：.\Disable-Autostart.ps1 -Match "wps|dingtalk|workbuddy" -Disable -DryRun' -ForegroundColor DarkGray
    return
}

Write-Host ''
Write-Host "── 禁用自启 ($($hit.Count) 项) ──" -ForegroundColor Cyan
if ($hit.Count -eq 0) {
    Write-Host '  没有命中项。' -ForegroundColor DarkGreen
    return
}
Invoke-Disable -Items $hit
