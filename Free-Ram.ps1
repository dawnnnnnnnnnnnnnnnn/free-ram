<#
.SYNOPSIS
    Free-Ram —— Windows 内存释放 / 无用进程回收工具（可复用）

.DESCRIPTION
    五件事：看清楚内存去哪了、把后台进程的工作集压回待机列表、清空待机缓存、
    按危险等级杀掉无用进程、低内存时自动守护。

    默认行为对「正在玩游戏」友好：
      · 游戏进程（>800MB 且路径像游戏目录，或命中 gamePatterns）自动进入保护名单
      · 前台有窗口的进程永不 trim / 永不杀
      · trim 默认跳过 >800MB 的大进程，避免触发页错误造成卡顿
      · 默认等级 light，只动明确的后台垃圾

.PARAMETER Mode
    report   只报告内存与进程占用（默认）
    suggest  列出所有「可回收」进程，按可回收内存排序，标出所属等级
    trim     压缩后台进程工作集（安全、可逆，等价 RAMMap 的 Empty Working Set）
    purge    清空系统待机缓存 / 文件缓存（需要管理员）
    kill     按等级杀无用进程
    full     trim + purge + kill（一键）
    watch    常驻守护：定时 trim，可用内存低于阈值时自动 kill

.PARAMETER Level
    light    后台垃圾（壁纸、资讯源、小组件、更新器、Xbox 覆盖）—— 游戏中可用
    normal   light + 华硕全家桶 helper、NVIDIA 覆盖、Steam 内置浏览器、WebView2、Electron
    heavy    normal + 浏览器、QQ、WPS、Steam、ArmouryCrate 主进程（会关掉你的窗口）

.PARAMETER DryRun
    只打印将要做什么，不真的做。

.EXAMPLE
    .\Free-Ram.ps1
    .\Free-Ram.ps1 -Mode suggest
    .\Free-Ram.ps1 -Mode full -Level light
    .\Free-Ram.ps1 -Mode kill -Level normal -DryRun
    .\Free-Ram.ps1 -Mode purge
    .\Free-Ram.ps1 -Mode watch -Interval 600 -MinAvailableGB 2

.NOTES
    兼容 Windows PowerShell 5.1 与 PowerShell 7+。
    配置覆盖文件（可选）：脚本同目录 free-ram.config.json
#>

[CmdletBinding()]
param(
    [ValidateSet('report', 'suggest', 'trim', 'purge', 'kill', 'full', 'watch')]
    [string]$Mode = 'report',

    [ValidateSet('light', 'normal', 'heavy')]
    [string]$Level = 'light',

    [int]$Top = 15,

    [int[]]$KillPid = @(),
    [string[]]$KillNames = @(),
    [string[]]$KeepNames = @(),

    [switch]$DryRun,
    [switch]$AggressiveTrim,
    [switch]$NoGameGuard,
    [switch]$IncludeGame,
    [switch]$IncludeWindowed,
    [switch]$Elevate,

    [int]$Interval = 300,
    [double]$MinAvailableGB = 1.5,

    [string]$ConfigPath,
    [switch]$Quiet,
    [switch]$Pause
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# ============================================================
#  内置名单（JSON 可覆盖/追加）
# ============================================================

$script:DefaultProtect = @(
    # 系统内核 / 会话
    'System', 'Idle', 'Registry', 'smss', 'csrss', 'wininit', 'winlogon', 'services', 'lsass',
    'lsaiso', 'dwm', 'fontdrvhost', 'svchost', 'WmiPrvSE', 'audiodg', 'MemCompression',
    'Memory Compression', 'TrustedInstaller', 'TiWorker', 'spoolsv', 'taskhostw',
    # 安全
    'MsMpEng', 'NisSrv', 'SecurityHealthService', 'SecurityHealthSystray', 'SgrmBroker',
    # 桌面 / 外壳
    'explorer', 'sihost', 'conhost', 'ctfmon', 'ShellExperienceHost', 'StartMenuExperienceHost',
    'TextInputHost', 'RuntimeBroker', 'dllhost', 'LockApp', 'LogonUI', 'userinit',
    'ApplicationFrameHost', 'backgroundTaskHost', 'ShellHost', 'AppActionsHost',
    # 输入法本体（杀了就打不了字）
    'wetype_server', 'wetype_renderer', 'wetype_ime', 'SogouInput', 'QQPinyin',
    # 当前工具链
    'powershell', 'pwsh', 'WindowsTerminal', 'wt', 'OpenConsole', 'conhost'
)

$script:DefaultLevels = @{
    light  = @(
        'BingWallpaper',
        'PhoneExperienceHost', 'YourPhone',
        'MicrosoftStartFeedProvider', 'SportsWidgets', 'WeatherWidgets',
        'WidgetService', 'Widgets', 'WidgetBoard',
        'GameBar', 'GameBarFTServer', 'GameBarPresenceWriter', 'XboxPcApp',
        'XboxGameBarWidgets', 'XboxGameCallableUI', 'XboxGameBarSpotify',
        'wetype_update',
        'MicrosoftEdgeUpdate', 'GoogleUpdate', 'GoogleCrashHandler', 'GoogleCrashHandler64',
        'AdobeUpdate', 'AdobeARM', 'wkndlserv', 'UpdaterAll',
        'Teams', 'ms-teams', 'OneDriveStandaloneUpdater',
        'promecefpluginhost', 'SearchIndexer'
    )
    normal = @(
        'ArmouryCrate.UserSessionHelper', 'ArmouryCrate.Service', 'ArmouryCrate.ControlCenter',
        'AsusAppService', 'AsusCertService', 'AsusOptimization', 'AsusSoftwareManager',
        'ASUSFrameworkService', 'asusmgr', 'AsusUpdateCheck', 'ArmouryCrate.UserSession',
        'NVIDIA Overlay', 'NVIDIA Share',
        'steamwebhelper',
        'msedgewebview2',
        'nvcontainer', 'NVDisplay.Container',
        'IntelGraphicsSoftware', 'igfxEM', 'IntelCpHDCPSvc',
        'SystemSettings', 'SystemSettingsBroker'
    )
    heavy  = @(
        'msedge',
        'electron',
        'QQ', 'WeChat', 'Tim',
        'wps', 'et', 'wpp', 'wpscloudsvr', 'wpsupdate', 'ksolaunch',
        'steam',
        'ArmouryCrate',
        'SearchHost', 'SearchApp',
        'nvcplui', 'nvsphelper64',
        'OfficeClickToRun', 'EXCEL', 'WINWORD', 'POWERPNT'
    )
}

# 这些路径/进程名一律不动（游戏、反作弊、驱动 UI）
$script:DefaultGamePatterns = @(
    'RelicCardinal', '*RelicCardinal*', 'AoE*', 'Age of Empires*',
    'EasyAntiCheat*', 'BEService', 'BattlEye*', 'Vanguard*', 'vgc', 'ACE-*', 'SGuard*',
    'Steam', 'steam', 'steamwebhelper'      # 见下方：游戏运行时 Steam 全家保护
)

$script:GamePathHint = 'steamapps|\\Games\\|\\Epic Games\\|Battle\.net|\\Riot Games\\|XboxGames|WeGameApps'

$script:ResidueHint = '360|qihoo|zhudongfangyu|qhsafe|QHActiveDefense|QHSafeTray|360se|360sd|360tray'

# ============================================================
#  原生 API
# ============================================================

function Initialize-Native {
    if ('MemNative' -as [type]) { return }
    $code = @'
using System;
using System.Runtime.InteropServices;

public static class MemNative
{
    [StructLayout(LayoutKind.Sequential)]
    public struct LUID { public uint LowPart; public int HighPart; }
    [StructLayout(LayoutKind.Sequential)]
    public struct LUID_AND_ATTRIBUTES { public LUID Luid; public uint Attributes; }
    [StructLayout(LayoutKind.Sequential)]
    public struct TOKEN_PRIVILEGES { public uint PrivilegeCount; public LUID_AND_ATTRIBUTES Privilege; }

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr h);
    [DllImport("psapi.dll", SetLastError = true)]
    public static extern bool EmptyWorkingSet(IntPtr h);
    [DllImport("ntdll.dll")]
    public static extern int NtSetSystemInformation(int cls, ref int info, int len);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool OpenProcessToken(IntPtr h, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool LookupPrivilegeValueW(string sys, string name, out LUID luid);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool AdjustTokenPrivileges(IntPtr token, bool disable, ref TOKEN_PRIVILEGES newState, int len, IntPtr prev, IntPtr retLen);
    [DllImport("kernel32.dll")]
    static extern IntPtr GetCurrentProcess();

    public const uint PROCESS_QUERY_INFORMATION = 0x0400;
    public const uint PROCESS_SET_QUOTA = 0x0100;
    public const uint TOKEN_ADJUST_PRIVILEGES = 0x0020;
    public const uint TOKEN_QUERY = 0x0008;
    public const uint SE_PRIVILEGE_ENABLED = 0x0002;
    public const int SystemMemoryListInformation = 80;
    public const int MemoryPurgeStandbyList = 4;

    public static bool EnablePrivilege(string name)
    {
        IntPtr token;
        if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, out token)) return false;
        LUID luid;
        if (!LookupPrivilegeValueW(null, name, out luid)) { CloseHandle(token); return false; }
        TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES();
        tp.PrivilegeCount = 1;
        tp.Privilege.Luid = luid;
        tp.Privilege.Attributes = SE_PRIVILEGE_ENABLED;
        bool ok = AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
        CloseHandle(token);
        return ok;
    }

    public static bool Trim(int pid)
    {
        IntPtr h = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_SET_QUOTA, false, pid);
        if (h == IntPtr.Zero) return false;
        bool ok = EmptyWorkingSet(h);
        CloseHandle(h);
        return ok;
    }

    public static int PurgeStandby()
    {
        int cmd = MemoryPurgeStandbyList;
        return NtSetSystemInformation(SystemMemoryListInformation, ref cmd, sizeof(int));
    }
}
'@
    # 不写 -Language：PS 6+ 已移除该参数（见 SO: -CompilerParameters 被 -CompilerOptions 取代），
    # 省略时 5.1 和 7 都默认按 C# 编译
    Add-Type -TypeDefinition $code -ErrorAction Stop | Out-Null
}

function Test-Admin {
    try {
        return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

# ============================================================
#  输出小工具
# ============================================================

function Write-Head($text) {
    if ($Quiet) { return }
    Write-Host ''
    Write-Host "── $text " -ForegroundColor DarkCyan -NoNewline
    Write-Host ('─' * [Math]::Max(0, 62 - $text.Length)) -ForegroundColor DarkGray
}

function Write-Line($label, $value, $color = 'Gray') {
    if ($Quiet) { return }
    Write-Host ('  {0,-12}' -f $label) -ForegroundColor DarkGray -NoNewline
    Write-Host $value -ForegroundColor $color
}

function Format-MB([double]$mb) {
    if ($mb -ge 1024) { return ('{0:N2} GB' -f ($mb / 1024)) }
    return ('{0:N0} MB' -f $mb)
}

# ============================================================
#  内存快照
# ============================================================

function Get-MemSnapshot {
    # 计数源优先级：Raw（同一时刻、字节精度、自洽）→ Formatted → 只剩 OS 粗值
    $raw = $null
    $fmt = $null
    $os = $null
    try { $raw = Get-CimInstance -ClassName Win32_PerfRawData_PerfOS_Memory -ErrorAction Stop } catch { }
    try { $fmt = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Memory -ErrorAction Stop } catch { }
    try { $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop } catch { }

    $snap = [ordered]@{
        TotalMB     = 0
        AvailableMB = 0
        InUseMB     = 0
        FreeZeroMB  = 0
        StandbyMB   = 0
        ModifiedMB  = 0
        CommitMB    = 0
        UsedPct     = 0
        Time        = Get-Date
    }

    if ($os) {
        $snap.TotalMB = [double]$os.TotalVisibleMemorySize / 1KB
        $snap.CommitMB = ([double]$os.TotalVirtualMemorySize - [double]$os.FreeVirtualMemory) / 1KB
    }

    $src = if ($raw) { $raw } else { $fmt }
    if ($src) {
        $names = $src.PSObject.Properties.Name
        $standby = 0.0
        foreach ($f in 'StandbyCacheNormalPriorityBytes', 'StandbyCacheReserveBytes', 'StandbyCacheCoreBytes') {
            if ($names -contains $f) { $standby += [double]$src.$f / 1MB }
        }
        $snap.StandbyMB = $standby

        if ($names -contains 'FreeAndZeroPageListBytes') {
            $snap.FreeZeroMB = [double]$src.FreeAndZeroPageListBytes / 1MB
        } elseif ($os) {
            $snap.FreeZeroMB = [double]$os.FreePhysicalMemory / 1KB
        }
        if ($names -contains 'ModifiedPageListBytes') {
            $snap.ModifiedMB = [double]$src.ModifiedPageListBytes / 1MB
        }
        if ($names -contains 'AvailableBytes') {
            $snap.AvailableMB = [double]$src.AvailableBytes / 1MB
        } elseif ($names -contains 'AvailableMBytes') {
            $snap.AvailableMB = [double]$src.AvailableMBytes
        }
    }
    if ($snap.AvailableMB -le 0 -and $os) {
        $snap.AvailableMB = [double]$os.FreePhysicalMemory / 1KB
        if ($snap.FreeZeroMB -le 0) { $snap.FreeZeroMB = $snap.AvailableMB }
    }
    # 统一口径：可用 = 空闲页 + 待机缓存 + 待写出（自洽，与任务管理器同源）
    $computed = $snap.FreeZeroMB + $snap.StandbyMB + $snap.ModifiedMB
    if ($computed -gt 0) { $snap.AvailableMB = $computed }

    if ($snap.TotalMB -gt 0) {
        $snap.InUseMB = [Math]::Max(0, $snap.TotalMB - $snap.AvailableMB)
        $snap.UsedPct = 100 * $snap.InUseMB / $snap.TotalMB
    }
    return [pscustomobject]$snap
}

function Show-Memory($snap) {
    Write-Head '内存总览'
    Write-Line '物理总量' (Format-MB $snap.TotalMB) 'White'
    Write-Line '正在使用' ("{0}  ({1:N1}%)" -f (Format-MB $snap.InUseMB), $snap.UsedPct) $(if ($snap.UsedPct -ge 90) { 'Red' } elseif ($snap.UsedPct -ge 75) { 'Yellow' } else { 'Green' })
    Write-Line '可用' (Format-MB $snap.AvailableMB) $(if ($snap.AvailableMB -lt 1024) { 'Red' } else { 'Green' })
    Write-Line '  ├ 空闲页' (Format-MB $snap.FreeZeroMB) 'DarkGray'
    Write-Line '  └ 待机缓存' ("{0}   可清空" -f (Format-MB $snap.StandbyMB)) 'DarkGray'
    Write-Line '已提交' (Format-MB $snap.CommitMB) 'Gray'
    if ($snap.ModifiedMB -gt 0) { Write-Line '待写出' (Format-MB $snap.ModifiedMB) 'DarkGray' }
}

# ============================================================
#  名单解析
# ============================================================

function Get-Config {
    $cfg = @{
        Protect      = $script:DefaultProtect
        Levels       = $script:DefaultLevels
        GamePatterns = $script:DefaultGamePatterns
    }
    $path = $ConfigPath
    if (-not $path) { $path = Join-Path $PSScriptRoot 'free-ram.config.json' }
    if ($path -and (Test-Path -LiteralPath $path)) {
        try {
            $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
            $json = $raw | ConvertFrom-Json
            if ($json.protect) { $cfg.Protect = @($cfg.Protect) + @($json.protect) }
            if ($json.levels) {
                foreach ($k in 'light', 'normal', 'heavy') {
                    if ($json.levels.$k) { $cfg.Levels[$k] = @($cfg.Levels[$k]) + @($json.levels.$k) }
                }
            }
            if ($json.gamePatterns) { $cfg.GamePatterns = @($cfg.GamePatterns) + @($json.gamePatterns) }
            if ($json.replaceLevels -eq $true -and $json.levels) {
                foreach ($k in 'light', 'normal', 'heavy') {
                    if ($json.levels.$k) { $cfg.Levels[$k] = @($json.levels.$k) }
                }
            }
        } catch {
            Write-Warning "配置文件解析失败，使用内置名单：$($_.Exception.Message)"
        }
    }
    return $cfg
}

function Get-CommittedLevels($cfg, $level) {
    $out = New-Object System.Collections.Generic.List[string]
    $order = @('light', 'normal', 'heavy')
    $upto = [array]::IndexOf($order, $level)
    for ($i = 0; $i -le $upto; $i++) {
        foreach ($n in $cfg.Levels[$order[$i]]) { if (-not $out.Contains($n)) { $out.Add($n) } }
    }
    return $out
}

# ============================================================
#  进程分类
# ============================================================

function Get-ProcIndex {
    $map = @{}
    try {
        Get-CimInstance -ClassName Win32_Process -ErrorAction Stop | ForEach-Object {
            $map[[int]$_.ProcessId] = $_
        }
    } catch { }
    return $map
}

function Get-SelfTree {
    # 当前进程 + 父链，绝不触碰
    $ids = New-Object System.Collections.Generic.HashSet[int]
    $cursor = $PID
    $guard = 0
    while ($cursor -and $cursor -gt 0 -and $guard -lt 12) {
        if (-not $ids.Add([int]$cursor)) { break }
        $parent = 0
        try {
            $ci = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$cursor" -ErrorAction Stop
            if ($ci) { $parent = [int]$ci.ParentProcessId }
        } catch { }
        $cursor = $parent
        $guard++
    }
    return $ids
}

function Test-IsGame($proc, $cmdMap, $cfg) {
    foreach ($pat in $cfg.GamePatterns) {
        if ($proc.ProcessName -like $pat) { return $true }
    }
    $path = $null
    try { $path = $proc.Path } catch { }
    if ($path -and $path -match $script:GamePathHint -and $proc.WorkingSet64 -gt 700MB) { return $true }
    if ($proc.WorkingSet64 -gt 1500MB) {
        $ci = $cmdMap[[int]$proc.Id]
        if ($ci -and $ci.CommandLine -and $ci.CommandLine -match 'steamapps|Epic|Battle\.net|Riot|XboxGames') { return $true }
    }
    return $false
}

function Test-IsMine($proc, $cmdMap) {
    # 只对「运行时」进程看命令行：浏览器把 URL 塞在命令行里，宽匹配会误伤
    if ($proc.ProcessName -notmatch '^(node|python|pythonw|electron|pwsh|powershell|bun|deno)$') { return $false }
    $ci = $cmdMap[[int]$proc.Id]
    if (-not $ci) { return $false }
    $cl = $ci.CommandLine
    if (-not $cl) { return $false }
    return [bool]($cl -match 'dsh[\\/]lib[\\/]bin\.js|@deepseek-ai|_npx\\[0-9a-f]{16}|vscode-server|claude-code|cursor-agent|deepseek')
}

function Test-IsSteam($proc) {
    return [bool]($proc.ProcessName -match '^(steam|steamwebhelper|steamservice|gameoverlayui)')
}

# ============================================================
#  候选解析
# ============================================================

function Resolve-Targets {
    param(
        [Parameter(Mandatory)] $Cfg,
        [Parameter(Mandatory)] [string]$LevelName,
        [string[]]$Names = @(),
        [int[]]$Pids = @(),
        [switch]$SkipWindowed
    )

    $names = @()
    if ($Names.Count -gt 0) { $names = $Names }
    else { $names = @(Get-CommittedLevels $Cfg $LevelName) }

    $selfTree = Get-SelfTree
    $cmdMap = Get-ProcIndex
    $protectSet = @($Cfg.Protect) + @($KeepNames)
    $all = @(Get-Process)

    $gameRunning = $false
    if (-not $NoGameGuard) {
        foreach ($p in $all) {
            if ($p.WorkingSet64 -gt 700MB -and (Test-IsGame $p $cmdMap $Cfg)) { $gameRunning = $true; break }
        }
    }

    $list = New-Object System.Collections.Generic.List[object]
    foreach ($p in $all) {
        if ($p.Id -le 8) { continue }
        if ($selfTree.Contains([int]$p.Id)) { continue }
        if ($p.SessionId -eq 0 -and $Pids.Count -eq 0) { continue }   # 服务会话，不碰

        $explicit = ($Pids -contains $p.Id)
        if (-not $explicit) {
            $hit = $false
            foreach ($n in $names) { if ($p.ProcessName -like $n) { $hit = $true; break } }
            if (-not $hit) { continue }
        }

        $protected = $false
        foreach ($n in $protectSet) { if ($p.ProcessName -like $n) { $protected = $true; break } }
        if ($protected -and -not $explicit) { continue }

        if (Test-IsMine $p $cmdMap) { continue }

        $isGame = Test-IsGame $p $cmdMap $Cfg
        if ($isGame -and -not $IncludeGame) { continue }

        # 游戏中：不杀 Steam 全家、不杀有前台窗口的
        if ($gameRunning -and -not $IncludeGame) {
            if ($p.ProcessName -match '^(steam|steamwebhelper|steamservice)$') { continue }
            if ($isGame) { continue }
        }

        $mbtxt = 0.0
        try { $mbtxt = [double]$p.WorkingSet64 / 1MB } catch { }
        $privMB = 0.0
        try { $privMB = [double]$p.PrivateMemorySize64 / 1MB } catch { }
        $title = ''
        try { $title = [string]$p.MainWindowTitle } catch { }

        # light / normal 不动「有窗口、你正在用」的进程；heavy 默认也不动，除非 -IncludeWindowed
        if ($SkipWindowed -and $title -and -not $explicit) { continue }

        $list.Add([pscustomobject]@{
            Id      = $p.Id
            Name    = $p.ProcessName
            MB      = [Math]::Round($mbtxt, 0)
            PrivMB  = [Math]::Round($privMB, 0)
            Title   = $title
            IsGame  = $isGame
            HasUI   = [bool]$title
        })
    }

    return [pscustomobject]@{
        Targets     = @($list | Sort-Object PrivMB -Descending)
        GameRunning = $gameRunning
    }
}

# ============================================================
#  动作
# ============================================================

function Invoke-Trim {
    param($Cfg)

    Initialize-Native | Out-Null
    $selfTree = Get-SelfTree
    $cmdMap = Get-ProcIndex

    $gameRunning = $false
    $all = @(Get-Process)
    if (-not $NoGameGuard) {
        foreach ($p in $all) {
            if ($p.WorkingSet64 -gt 700MB -and (Test-IsGame $p $cmdMap $Cfg)) { $gameRunning = $true; break }
        }
    }

    $skipped = 0
    $targets = New-Object System.Collections.Generic.List[object]
    foreach ($p in $all) {
        if ($p.Id -le 8) { continue }
        if ($selfTree.Contains([int]$p.Id)) { continue }
        if ($p.SessionId -eq 0) { continue }

        $ws = 0.0
        try { $ws = [double]$p.WorkingSet64 / 1MB } catch { continue }
        if ($ws -lt 20) { continue }

        # 游戏与前台窗口：不 trim（会触发页错误，体感就是卡一下）
        if (Test-IsGame $p $cmdMap $Cfg) { $skipped++; continue }
        $hasUI = $false
        try { $hasUI = [bool]$p.MainWindowTitle } catch { }
        if ($hasUI -and -not $AggressiveTrim) { $skipped++; continue }
        if (-not $AggressiveTrim -and $ws -gt 800) { $skipped++; continue }
        if (Test-IsMine $p $cmdMap) { $skipped++; continue }

        $pn = $p.ProcessName
        $isProtected = $false
        foreach ($n in @($Cfg.Protect) + @($KeepNames)) { if ($pn -like $n) { $isProtected = $true; break } }
        if ($isProtected) { $skipped++; continue }

        $targets.Add([pscustomobject]@{ Id = $p.Id; Name = $pn; MB = [Math]::Round($ws, 0) })
    }

    $before = Get-MemSnapshot
    if ($DryRun) {
        Write-Head "TRIM 预览（DryRun，共 $($targets.Count) 个进程，$skipped 个跳过）"
        $targets | Sort-Object MB -Descending | Select-Object -First $Top |
            ForEach-Object { Write-Host ("  {0,7} MB  {1,-28} pid {2}" -f $_.MB, $_.Name, $_.Id) }
        return $before
    }

    $ok = 0
    foreach ($t in $targets) { if ([MemNative]::Trim($t.Id)) { $ok++ } }
    Start-Sleep -Milliseconds 400
    $after = Get-MemSnapshot

    Write-Head 'TRIM 结果'
    Write-Line '处理进程' ("{0} 个  跳过 {1} 个" -f $ok, $skipped) 'White'
    Write-Line '可用内存' ("{0}  →  {1}" -f (Format-MB $before.AvailableMB), (Format-MB $after.AvailableMB)) 'Green'
    Write-Line '待机缓存' ("{0}  →  {1}" -f (Format-MB $before.StandbyMB), (Format-MB $after.StandbyMB)) 'Gray'
    return $after
}

function Invoke-Purge {
    Initialize-Native | Out-Null
    $before = Get-MemSnapshot

    if (-not (Test-Admin)) {
        Write-Head 'PURGE 需要管理员'
        Write-Host '  清空待机缓存要 SeProfileSingleProcessPrivilege。' -ForegroundColor Yellow
        Write-Host '  用管理员身份重跑：' -ForegroundColor Gray
        Write-Host ('  Start-Process powershell -Verb RunAs -ArgumentList ''-NoProfile'',''-ExecutionPolicy'',''Bypass'',''-File'',''"{0}"'',''-Mode'',''purge''' -f $PSCommandPath) -ForegroundColor DarkCyan
        return $before
    }

    if ($DryRun) {
        Write-Head 'PURGE 预览（DryRun）'
        Write-Host ('  将清空待机列表，当前待机缓存 {0}，预计可释放 {1}' -f (Format-MB $before.StandbyMB), (Format-MB ($before.StandbyMB * 0.8))) -ForegroundColor Gray
        return $before
    }

    foreach ($priv in 'SeProfileSingleProcessPrivilege', 'SeIncreaseQuotaPrivilege', 'SeDebugPrivilege') {
        [void][MemNative]::EnablePrivilege($priv)
    }

    $rc = [MemNative]::PurgeStandby()
    Start-Sleep -Milliseconds 600
    $after = Get-MemSnapshot

    Write-Head 'PURGE 结果'
    if ($rc -ne 0) {
        Write-Line '状态' ("NTSTATUS 0x{0:X8}（未生效）" -f $rc) 'Yellow'
    } else {
        Write-Line '状态' '待机列表已清空' 'Green'
    }
    Write-Line '可用内存' ("{0}  →  {1}" -f (Format-MB $before.AvailableMB), (Format-MB $after.AvailableMB)) 'Green'
    Write-Line '空闲页' ("{0}  →  {1}" -f (Format-MB $before.FreeZeroMB), (Format-MB $after.FreeZeroMB)) 'Gray'
    return $after
}

function Invoke-Kill {
    param($Cfg, [string]$LevelName, [string[]]$Names, [int[]]$Pids)

    $skipWin = -not $IncludeWindowed
    $res = Resolve-Targets -Cfg $Cfg -LevelName $LevelName -Names $Names -Pids $Pids -SkipWindowed:$skipWin
    $targets = $res.Targets

    if ($res.GameRunning) {
        Write-Head '游戏保护生效'
        Write-Host '  检测到游戏进程，Steam 与游戏相关进程已排除。' -ForegroundColor DarkCyan
    }

    if (-not $targets -or $targets.Count -eq 0) {
        Write-Head 'KILL'
        Write-Host '  没有匹配的进程（都已在保护名单内，或本来就没跑）。' -ForegroundColor Green
        return 0
    }

    $sum = ($targets | Measure-Object PrivMB -Sum).Sum
    Write-Head ("KILL 目标 [{0}]  {1} 个进程 / 私有内存 {2}" -f $LevelName, $targets.Count, (Format-MB $sum))
    foreach ($t in $targets) {
        $extra = ''
        if ($t.HasUI) { $extra = '  「' + $t.Title + '」' }
        Write-Host ('  {0,7} MB  {1,-26} pid {2,-7}{3}' -f $t.PrivMB, $t.Name, $t.Id, $extra) -ForegroundColor Gray
    }

    if ($DryRun) {
        Write-Host '  (DryRun：以上均未执行)' -ForegroundColor Yellow
        return 0
    }

    $before = Get-MemSnapshot
    $killed = 0
    foreach ($t in $targets) {
        try {
            Stop-Process -Id $t.Id -Force -ErrorAction Stop
            $killed++
        } catch { }
    }
    Start-Sleep -Milliseconds 800
    $after = Get-MemSnapshot

    $bAvail = [double]$before.AvailableMB
    $aAvail = [double]$after.AvailableMB
    $delta = $aAvail - $bAvail
    if ($delta -lt 0) { $delta = 0 }

    Write-Head 'KILL 结果'
    Write-Line '已结束' ("{0} / {1} 个进程" -f $killed, $targets.Count) 'White'
    Write-Line '可用内存' ("{0}  →  {1}   (+{2})" -f (Format-MB $bAvail), (Format-MB $aAvail), (Format-MB $delta)) 'Green'
    Write-Line '使用率' ("{0:N1}%  →  {1:N1}%" -f $before.UsedPct, $after.UsedPct) 'Green'
    if ($IncludeGame) { Write-Host '  注意：-IncludeGame 已开启，游戏进程也在可杀范围内。' -ForegroundColor Yellow }
    return $after
}

# ============================================================
#  报告 / 建议
# ============================================================

function Show-Top {
    $snap = Get-MemSnapshot
    Write-Head "TOP $Top 内存进程"
    $rows = Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First $Top
    foreach ($p in $rows) {
        $mb = 0.0
        try { $mb = [double]$p.WorkingSet64 / 1MB } catch { }
        $title = ''
        try { $title = [string]$p.MainWindowTitle } catch { }
        $color = if ($mb -gt 1000) { 'Red' } elseif ($mb -gt 300) { 'Yellow' } else { 'Gray' }
        $line = '  {0,7} MB  {1,-26} pid {2,-7}' -f [int]$mb, $p.ProcessName, $p.Id
        Write-Host $line -ForegroundColor $color -NoNewline
        if ($title) { Write-Host ('  ' + $title) -ForegroundColor DarkGray } else { Write-Host '' }
    }
    return $snap
}

function Show-Suggest {
    param($Cfg)

    $lines = New-Object System.Collections.Generic.List[object]
    $selfTree = Get-SelfTree
    $cmdMap = Get-ProcIndex
    $protectSet = @($Cfg.Protect) + @($KeepNames)
    $gameRunning = $false
    foreach ($p in Get-Process) {
        if ($p.WorkingSet64 -gt 700MB -and (Test-IsGame $p $cmdMap $Cfg)) { $gameRunning = $true; break }
    }

    $light = @(Get-CommittedLevels $Cfg 'light')
    $normal = @(Get-CommittedLevels $Cfg 'normal')
    $heavy = @(Get-CommittedLevels $Cfg 'heavy')

    foreach ($p in (Get-Process | Sort-Object PrivateMemorySize64 -Descending)) {
        if ($p.Id -le 8) { continue }
        if ($selfTree.Contains([int]$p.Id)) { continue }
        if ($p.SessionId -eq 0) { continue }
        $mb = 0.0
        $ws = 0.0
        try { $mb = [double]$p.PrivateMemorySize64 / 1MB } catch { continue }
        try { $ws = [double]$p.WorkingSet64 / 1MB } catch { }
        if ($mb -lt 30) { continue }

        $pn = $p.ProcessName
        $prot = $false
        foreach ($n in $protectSet) { if ($pn -like $n) { $prot = $true; break } }
        $isGame = Test-IsGame $p $cmdMap $Cfg

        $tag = ''
        if (Test-IsGame $p $cmdMap $Cfg) {
            if (Test-IsSteam $p) { $tag = 'steam 保护' } else { $tag = 'GAME 保护' }
        }
        elseif ($prot) { $tag = 'system 保护' }
        elseif (Test-IsMine $p $cmdMap) { $tag = 'dsh 保护' }
        elseif ($light -contains $pn -or (& { foreach ($n in $light) { if ($pn -like $n) { return $true } } return $false })) { $tag = 'light' }
        elseif (& { foreach ($n in $normal) { if ($pn -like $n) { return $true } } return $false }) { $tag = 'normal' }
        elseif (& { foreach ($n in $heavy) { if ($pn -like $n) { return $true } } return $false }) { $tag = 'heavy' }
        else { $tag = '-' }

        $title = ''
        try { $title = [string]$p.MainWindowTitle } catch { }

        $lines.Add([pscustomobject]@{ MB = [Math]::Round($mb, 0); WS = [Math]::Round($ws, 0); Name = $pn; Id = $p.Id; Tag = $tag; Title = $title })
    }

    Write-Head '可回收进程（按私有内存排序，仅列 ≥30MB）'
    Write-Host ('  {0,7}  {1,6}  {2,-30} {3,-8} {4}' -f '私有', '工作集', '进程', 'pid', '分类') -ForegroundColor DarkGray
    foreach ($l in ($lines | Sort-Object MB -Descending)) {
        $color = switch -Wildcard ($l.Tag) {
            'GAME*' { 'DarkCyan' }
            'steam*' { 'DarkCyan' }
            'system*' { 'DarkGray' }
            'dsh*' { 'DarkGray' }
            'light' { 'Green' }
            'normal' { 'Yellow' }
            'heavy' { 'Magenta' }
            default { 'DarkGray' }
        }
        $line = '  {0,5} MB  {1,5} MB  {2,-30} {3,-8} {4,-13}' -f $l.MB, $l.WS, $l.Name, $l.Id, $l.Tag
        Write-Host $line -ForegroundColor $color -NoNewline
        if ($l.Title) { Write-Host ('  ' + $l.Title) -ForegroundColor DarkGray } else { Write-Host '' }
    }
    Write-Host ''
    Write-Host '  绿色=light 可直接杀   黄色=normal   洋红=heavy 会关掉窗口   ' -NoNewline -ForegroundColor DarkGray
    Write-Host '青色/灰色=保护，不会被碰' -ForegroundColor DarkGray
    if ($gameRunning) { Write-Host '  当前检测到游戏在跑：Steam 全家已保护。' -ForegroundColor DarkCyan }
}

function Show-Residue {
    $found = @()
    try {
        Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match $script:ResidueHint } | ForEach-Object {
            $found += "进程 $($_.ProcessName) (pid $($_.Id))"
        }
    } catch { }
    try {
        Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $script:ResidueHint -or $_.DisplayName -match $script:ResidueHint } | ForEach-Object {
            $found += "服务 $($_.Name) [$($_.Status)]"
        }
    } catch { }
    if ($found.Count -gt 0) {
        Write-Head '360 残留'
        $found | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
        Write-Host '  卸载残留服务可跑：sc.exe delete <服务名>（需管理员）' -ForegroundColor DarkGray
    }
}

# ============================================================
#  Watch
# ============================================================

function Invoke-Watch {
    param($Cfg)

    Write-Head 'WATCH 守护'
    Write-Host ("  间隔 {0}s   阈值 {1:N1} GB   等级 {2}   游戏保护 {3}" -f $Interval, $MinAvailableGB, $Level, (-not $NoGameGuard)) -ForegroundColor DarkCyan
    Write-Host '  Ctrl+C 退出' -ForegroundColor DarkGray

    while ($true) {
        $snap = Get-MemSnapshot
        $stamp = (Get-Date).ToString('HH:mm:ss')
        $msg = '  [{0}] 可用 {1}  使用率 {2:N1}%' -f $stamp, (Format-MB $snap.AvailableMB), $snap.UsedPct
        Write-Host $msg -ForegroundColor $(if ($snap.UsedPct -ge 90) { 'Red' } elseif ($snap.UsedPct -ge 75) { 'Yellow' } else { 'Green' }) -NoNewline

        if (-not $DryRun) {
            Initialize-Native | Out-Null
            $n = 0
            foreach ($p in Get-Process) {
                if ($p.Id -le 8 -or $p.SessionId -eq 0) { continue }
                $ws = 0.0
                try { $ws = [double]$p.WorkingSet64 / 1MB } catch { continue }
                if ($ws -lt 60 -or $ws -gt 800) { continue }
                $hasUI = $false
                try { $hasUI = [bool]$p.MainWindowTitle } catch { }
                if ($hasUI) { continue }
                if ([MemNative]::Trim($p.Id)) { $n++ }
            }
            Write-Host "   trim $n" -ForegroundColor DarkGray -NoNewline
        }

        if ($snap.AvailableMB -lt ($MinAvailableGB * 1024)) {
            Write-Host '   → 低于阈值，执行 KILL' -ForegroundColor Yellow
            [void](Invoke-Kill -Cfg $Cfg -LevelName $Level -Names @() -Pids @())
        } else {
            Write-Host ''
        }
        Start-Sleep -Seconds $Interval
    }
}

# ============================================================
#  主流程
# ============================================================

# 自提权：purge/full 需要管理员时自动弹 UAC 重开自己
if ($Elevate -and -not (Test-Admin)) {
    $argList = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $PSCommandPath),
        '-Mode', $Mode, '-Level', $Level,
        '-Interval', $Interval, '-MinAvailableGB', $MinAvailableGB
    )
    if ($DryRun) { $argList += '-DryRun' }
    if ($Pause) { $argList += '-Pause' }
    Write-Host '请求管理员权限（UAC 弹窗请点「是」）...' -ForegroundColor Yellow
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList | Out-Null
    } catch {
        Write-Host '提权被取消，普通权限继续。' -ForegroundColor DarkYellow
    }
    return
}

$Cfg = Get-Config

switch ($Mode) {
    'report' {
        Write-Head 'Free-Ram'
        $snap = Show-Top
        Show-Memory $snap
        Show-Residue
        if (-not (Test-Admin)) {
            Write-Host ''
            Write-Host '  提示：purge（清待机缓存）需要管理员，trim / kill 不需要。' -ForegroundColor DarkGray
        }
    }
    'suggest' {
        Show-Suggest -Cfg $Cfg
    }
    'trim' {
        [void](Invoke-Trim -Cfg $Cfg)
    }
    'purge' {
        [void](Invoke-Purge)
    }
    'kill' {
        [void](Invoke-Kill -Cfg $Cfg -LevelName $Level -Names $KillNames -Pids $KillPid)
    }
    'full' {
        $s = Get-MemSnapshot
        Show-Memory $s
        [void](Invoke-Trim -Cfg $Cfg)
        [void](Invoke-Purge)
        [void](Invoke-Kill -Cfg $Cfg -LevelName $Level -Names $KillNames -Pids $KillPid)
        $e = Get-MemSnapshot
        Write-Head '收尾'
        Write-Line '可用内存' ("{0}  →  {1}" -f (Format-MB $s.AvailableMB), (Format-MB $e.AvailableMB)) 'Green'
        Write-Line '使用率' ("{0:N1}%  →  {1:N1}%" -f $s.UsedPct, $e.UsedPct) 'Green'
    }
    'watch' {
        Invoke-Watch -Cfg $Cfg
    }
}

if ($Pause) { Write-Host ''; Read-Host '按回车退出' | Out-Null }
