<#
.SYNOPSIS
    Free-Ram 便携包安装器 —— 拷到任意 Windows 10/11 上跑一次就装好。

.DESCRIPTION
    它做的事：
      1. 环境自检（Windows 版本 / PowerShell 版本 / 执行策略）
      2. 编译器自检（确认 Add-Type 能编译，也就是 EDR 有没有拦 csc.exe）
      3. 按「当前实际路径」写 ram / noauto 命令别名，装到 PowerShell 5.1 和 7 两套 profile
      4. 按「当前实际路径」在桌面建两个快捷方式
      5. 清掉从旧机器带过来的本机专属数据（备份 JSON / 移出的快捷方式）
      6. 打印这台机器的体检结论

    全过程不需要管理员。只有真正杀 SYSTEM 进程时才需要，那一步由「释放内存」快捷方式自己弹 UAC。

.PARAMETER Uninstall
    撤销安装：删掉 profile 里的别名块、删掉桌面快捷方式。脚本文件本身不动。

.PARAMETER NoShortcut
    不建桌面快捷方式。

.PARAMETER NoAlias
    不写 profile 别名。

.PARAMETER Quiet
    只输出结果，不输出过程。

.EXAMPLE
    .\Setup.ps1
    .\Setup.ps1 -SelfTest
    .\Setup.ps1 -Uninstall
#>

[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$NoShortcut,
    [switch]$NoAlias,
    [switch]$SelfTest,
    [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$Root = $PSScriptRoot
if (-not $Root) { $Root = Split-Path -Parent $MyInvocation.MyCommand.Path }

$Marker = 'free-ram tools'
$BlockBegin = "# >>> $Marker >>>"
$BlockEnd = "# <<< $Marker <<<"

# ============================================================
#  输出
# ============================================================

function Say($text, $color = 'Gray') {
    if ($Quiet -and $color -eq 'DarkGray') { return }
    Write-Host $text -ForegroundColor $color
}
function Head($text) {
    if ($Quiet) { return }
    Write-Host ''
    Write-Host "── $text " -ForegroundColor DarkCyan -NoNewline
    Write-Host ('─' * [Math]::Max(0, 58 - $text.Length)) -ForegroundColor DarkGray
}
function Row($k, $v, $c = 'White') {
    if ($Quiet) { return }
    Write-Host ('  {0,-14}' -f $k) -ForegroundColor DarkGray -NoNewline
    Write-Host $v -ForegroundColor $c
}

# ============================================================
#  撤销安装
# ============================================================

function Get-ProfilePaths {
    $docs = [Environment]::GetFolderPath('MyDocuments')
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($d in 'WindowsPowerShell', 'PowerShell') {
        $list.Add((Join-Path $docs "$d\profile.ps1"))
    }
    return $list
}

function Remove-Block($path) {
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    if (-not $raw) { return $false }
    if ($raw -notmatch [regex]::Escape($BlockBegin)) { return $false }
    $new = [regex]::Replace($raw, "(?s)\r?\n?" + [regex]::Escape($BlockBegin) + ".*?" + [regex]::Escape($BlockEnd), '')
    [IO.File]::WriteAllText($path, $new, (New-Object System.Text.UTF8Encoding($true)))
    return $true
}

if ($Uninstall) {
    Head '撤销安装'
    foreach ($p in Get-ProfilePaths) {
        if (Remove-Block $p) { Say "  ✓ 已移除别名块：$p" 'Green' }
    }
    $desk = [Environment]::GetFolderPath('Desktop')
    foreach ($n in '释放内存.lnk', '管理开机自启.lnk') {
        $f = Join-Path $desk $n
        if (Test-Path -LiteralPath $f) {
            Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
            Say "  ✓ 已删除快捷方式：$n" 'Green'
        }
    }
    Say ''
    Say '  脚本文件没有删，需要的话手动删掉整个文件夹。' 'DarkGray'
    return
}

# ============================================================
#  环境自检
# ============================================================

Head '环境自检'

$psVer = $PSVersionTable.PSVersion
$psKind = if ($PSVersionTable.PSEdition -eq 'Core') { 'PowerShell 7+' } else { 'Windows PowerShell' }
Row 'PowerShell' ("{0}.{1}  ({2})" -f $psVer.Major, $psVer.Minor, $psKind) 'White'

$build = 0
try { $build = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop).CurrentBuildNumber } catch { }
$winName = if ($build -ge 22000) { "Windows 11 (build $build)" } elseif ($build -ge 10240) { "Windows 10 (build $build)" } else { "Windows (build $build)" }
$winOK = ($build -ge 17763)
Row '系统' $winName $(if ($winOK) { 'White' } else { 'Red' })
if (-not $winOK) {
    Say '  ! build 低于 17763，standby 缓存清理（purge）可能无效，其余功能正常。' 'Yellow'
}

$ep = 'Unknown'
$epPersist = ''
try {
    $epM = (Get-ExecutionPolicy -Scope LocalMachine).ToString()
    $epU = (Get-ExecutionPolicy -Scope CurrentUser).ToString()
    $ep = "本机=$epM / 当前用户=$epU"
    $epPersist = "$epM $epU"
} catch {
    try { $ep = (Get-ExecutionPolicy).ToString(); $epPersist = $ep } catch { }
}
Row '执行策略' $ep $(if ($epPersist -match 'Restricted|AllSigned') { 'Yellow' } else { 'White' })
if ($epPersist -match 'Restricted|AllSigned') {
    Say '  ! 需要放行：用 Run-FreeRam.cmd 启动（内部已带 -ExecutionPolicy Bypass），或跑一次' 'Yellow'
    Say '    Set-ExecutionPolicy -Scope CurrentUser RemoteSigned' 'DarkGray'
}

$isAdmin = $false
try { $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { }
Row '当前权限' $(if ($isAdmin) { '管理员' } else { '普通用户（够用）' }) 'White'

# ============================================================
#  编译器自检（EDR 检测）
# ============================================================

Head '功能自检'

$compileOK = $false
$compileErr = ''
try {
    if ('FRProbe' -as [type]) {
        $compileOK = $true
    } else {
        $probe = @'
using System;
using System.Runtime.InteropServices;
public static class FRProbe
{
    [DllImport("psapi.dll", SetLastError = true)]
    public static extern bool EmptyWorkingSet(IntPtr h);
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetCurrentProcess();
    public static bool SelfTest() { return EmptyWorkingSet(GetCurrentProcess()); }
}
'@
        Add-Type -TypeDefinition $probe -ErrorAction Stop | Out-Null
        $compileOK = [bool][FRProbe]::SelfTest()
    }
} catch {
    $compileErr = $_.Exception.Message
}

if ($compileOK) {
    Row '工作集压缩' '可用（Add-Type 编译通过）' 'Green'
} else {
    Row '工作集压缩' '不可用' 'Red'
    if ($compileErr) { Say ("  ! 原因：" + $compileErr.Split("`n")[0]) 'Yellow' }
    Say '  ! 这一步要调用系统自带的 C# 编译器 csc.exe。杀软/EDR（SentinelOne、CrowdStrike 之类）' 'Yellow'
    Say '    会拦它，结果是 trim 静默失效。杀进程（kill）和清缓存（purge）不受影响。' 'DarkGray'
}

# 待机缓存清理能力
$purgeOK = $false
try {
    if ('FRNative2' -as [type]) { $purgeOK = $true }
    else {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class FRNative2
{
    [DllImport("ntdll.dll")]
    public static extern int NtSetSystemInformation(int cls, ref int info, int len);
    public static int Ping()
    {
        int probe = 4;
        return NtSetSystemInformation(80, ref probe, 0);   // len=0 只探路，不真正清
    }
}
'@ -ErrorAction Stop | Out-Null
        [void][FRNative2]::Ping()
        $purgeOK = $true
    }
} catch { $purgeOK = $false }

Row '清待机缓存' $(if ($purgeOK) { '接口可用' } else { '接口不可用' }) $(if ($purgeOK) { 'Green' } else { 'Yellow' })
if ($purgeOK -and -not $isAdmin) {
    Say '  · 需要管理员才生效，「释放内存」快捷方式会自动弹 UAC。' 'DarkGray'
}

# ============================================================
#  清掉旧机器带来的数据
# ============================================================

Head '清理本机专属数据'

$removed = 0
$bk = Join-Path $Root 'autostart-backup.json'
if (Test-Path -LiteralPath $bk) {
    Remove-Item -LiteralPath $bk -Force -ErrorAction SilentlyContinue
    Say '  ✓ 已删除 autostart-backup.json（那是别的机器的自启备份）' 'Green'
    $removed++
}
$bkdir = Join-Path $Root 'autostart-backup-files'
if (Test-Path -LiteralPath $bkdir) {
    Remove-Item -LiteralPath $bkdir -Recurse -Force -ErrorAction SilentlyContinue
    Say '  ✓ 已删除 autostart-backup-files\' 'Green'
    $removed++
}
if ($removed -eq 0) { Say '  · 没有需要清理的旧数据' 'DarkGray' }

# ============================================================
#  装别名
# ============================================================

$ramPath = Join-Path $Root 'Free-Ram.ps1'
$noautoPath = Join-Path $Root 'Disable-Autostart.ps1'

if (-not $NoAlias) {
    Head '安装命令别名'

    # 路径必须写死进函数体：用变量的方案在 profile 执行完后变量就没了，
    # 函数体里的变量会解析成 $null（动态作用域），别名看着在、调用就炸。
    $rootEsc = $Root.Replace("'", "''")
    $ramEsc = (Join-Path $Root 'Free-Ram.ps1').Replace("'", "''")
    $noautoEsc = (Join-Path $Root 'Disable-Autostart.ps1').Replace("'", "''")

    $block = @"
$BlockBegin
# 由 Setup.ps1 生成，路径已写死；重装会整体覆盖本块
if (Test-Path -LiteralPath '$ramEsc') {
    function global:ram    { & '$ramEsc' @args }
}
if (Test-Path -LiteralPath '$noautoEsc') {
    function global:noauto { & '$noautoEsc' @args }
}
$BlockEnd
"@

    foreach ($p in Get-ProfilePaths) {
        $dir = Split-Path $p -Parent
        try {
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
            $cur = ''
            if (Test-Path -LiteralPath $p) { $cur = Get-Content -LiteralPath $p -Raw -Encoding UTF8 }
            if (-not $cur) { $cur = '' }
            $cur = [regex]::Replace($cur, "(?s)\r?\n?" + [regex]::Escape($BlockBegin) + ".*?" + [regex]::Escape($BlockEnd), '')
            # 顺手清掉早期版本留下的坏块（用变量的那版）
            $cur = [regex]::Replace($cur, "(?s)\r?\n?\`$__frRoot\s*=.*?Remove-Variable __frRoot[^\r\n]*", '')
            $new = $cur.TrimEnd() + "`r`n`r`n" + $block.TrimEnd() + "`r`n"
            [IO.File]::WriteAllText($p, $new, (New-Object System.Text.UTF8Encoding($true)))
            Say "  ✓ $p" 'Green'
        } catch {
            Say ("  × $p :: " + $_.Exception.Message) 'Yellow'
        }
    }
    Say '  · 新开一个 PowerShell 窗口后生效：ram / noauto' 'DarkGray'
}

# ============================================================
#  建快捷方式
# ============================================================

if (-not $NoShortcut) {
    Head '创建桌面快捷方式'

    $desk = [Environment]::GetFolderPath('Desktop')
    if (-not (Test-Path -LiteralPath $desk)) {
        Say '  ! 找不到桌面目录，跳过' 'Yellow'
    } else {
        try {
            $ws = New-Object -ComObject WScript.Shell

            # 1) 释放内存：cmd 包装，内部自带 -Elevate
            $cmdPath = Join-Path $Root 'Run-FreeRam.cmd'
            $s1 = $ws.CreateShortcut((Join-Path $desk '释放内存.lnk'))
            $s1.TargetPath = $cmdPath
            $s1.WorkingDirectory = $Root
            $s1.IconLocation = 'C:\Windows\System32\taskmgr.exe,0'
            $s1.Description = 'Free-Ram：压缩工作集 + 清待机缓存 + 杀无用进程'
            $s1.Save()
            Say '  ✓ 释放内存.lnk' 'Green'

            # 2) 管理开机自启：先列出，不改动
            $s2 = $ws.CreateShortcut((Join-Path $desk '管理开机自启.lnk'))
            $s2.TargetPath = 'C:\Windows\System32\cmd.exe'
            $s2.Arguments = '/k powershell -NoProfile -ExecutionPolicy Bypass -File "' + $noautoPath + '"'
            $s2.WorkingDirectory = $Root
            $s2.IconLocation = 'C:\Windows\System32\shell32.dll,21'
            $s2.Description = '列出自启项 / 禁用 / 还原'
            $s2.Save()
            Say '  ✓ 管理开机自启.lnk' 'Green'
        } catch {
            Say ('  × 建快捷方式失败：' + $_.Exception.Message) 'Yellow'
        }
    }
}

# ============================================================
#  结束
# ============================================================

Head '完成'

if (-not $Quiet) {
    Say ''
    Say '  下次怎么用：' 'White'
    Say '    双击桌面「释放内存」          → 自动提权，一条龙清理' 'Gray'
    Say '    ram -Mode suggest            → 先看这台机器上什么能被收走' 'Gray'
    Say '    noauto -Disable -DryRun      → 先看哪些自启会被禁' 'Gray'
    Say ''
    Say "  脚本位置：$Root" 'DarkGray'
    Say '  想彻底移除：.\Setup.ps1 -Uninstall' 'DarkGray'
    Say ''
}

if ($SelfTest) {
    Head '本机可回收概况'
    & $ramPath -Mode suggest
}
