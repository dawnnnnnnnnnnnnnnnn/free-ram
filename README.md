# Free-Ram

Windows 内存回收 + 开机自启管理，纯 PowerShell，零依赖，中文。

**它不是通用的内存清理器。** 通用清理器请用 [Mem Reduct](https://github.com/henrypp/memreduct)，成熟、有 GUI、有托盘。
这个项目只解决两个具体场景：

1. **正在玩游戏的时候想腾内存**，但不能把游戏、Steam、反作弊、你正开着的窗口杀掉
2. **这台机器为什么开机就这么卡**，把一堆全家桶自启清掉

---

## 什么时候你不需要它

| 你的情况 | 用什么 |
|---|---|
| 只想定期清一下缓存，接受 GUI 常驻 | [Mem Reduct](https://github.com/henrypp/memreduct) |
| 只要一个命令行清 standby list | [RAMMap](https://learn.microsoft.com/sysinternals/downloads/rammap) 或 EmptyStandbyList |
| 想看清内存到底被谁吃了 | 任务管理器 / [RAMMap](https://learn.microsoft.com/sysinternals/downloads/rammap) 的物理内存视图 |
| 打游戏卡，想要游戏自动保护式的清理 | **这个** |
| 想把钉钉 / WPS / 夸克的更新器从自启里清掉 | **这个** |

---

## 和别的工具真正的差别

`EmptyWorkingSet` 和 `NtSetSystemInformation(SystemMemoryListInformation)` 是 Windows 20 年前就有的内部接口，谁都能调。这个项目不提供任何新的技术。

不一样的是**判断逻辑**：

**游戏保护。** 检测到有 `>700MB` 且路径落在 `steamapps` / `Epic Games` / `XboxGames` 之类的进程在跑时，自动进入保护模式——Steam 全家、游戏本体、反作弊进程全部排除，「有主窗口的进程」一律跳过。杀进程类的工具通常没有这一层，会在你打一半的时候把游戏干掉。

**双列内存视图。** `suggest` 模式同时显示私有内存（杀进程能省多少）和工作集（trim 能压多少），并标出每个进程被保护的原因。市面上的工具大多只给一个总数。

```
       私有     工作集  进程                    pid      分类
   8786 MB   4262 MB  RelicCardinal          8456     GAME 保护
    895 MB    819 MB  msedge                 42360    heavy
    617 MB    119 MB  msedge                 22656    heavy
    358 MB    289 MB  wetype_update          2280     light
    175 MB    104 MB  NVIDIA Overlay         17828    normal
```

**自启管理和内存清理在同一个包里。** 实际场景就是「这台电脑变慢了」，两件事一起做，而不是装两个工具。

---

## 快速开始

```powershell
# 方式一：便携包（推荐）
# 下载 ZIP，解压到任意位置，双击 Setup.cmd，之后双击桌面「释放内存」

# 方式二：手动
git clone https://github.com/<you>/free-ram.git
cd free-ram
.\Setup.ps1                 # 装别名 + 桌面快捷方式
```

装完在任意 PowerShell 窗口：

```powershell
ram                          # 看内存报告
ram -Mode suggest            # 列出这台机器上什么能被收走
ram -Mode full               # trim + purge + kill 一条龙
noauto                       # 列出所有开机自启项
```

> `Setup.ps1` 会把 `ram` / `noauto` 别名写进 PowerShell 5.1 和 7 两套 profile，
> 路径按脚本当时的实际位置生成，可以整包挪到别处再跑一次。

---

## Free-Ram.ps1

### 模式

| `-Mode` | 说明 | 需要管理员 |
|---|---|---|
| `report` | 内存总览 + TOP N 进程 + 残留检测 | 否 |
| `suggest` | 列出可回收进程（私有 / 工作集 / 等级 / 保护原因），不动手 | 否 |
| `trim` | 对后台进程调 `EmptyWorkingSet` | 否 |
| `purge` | 清空系统待机缓存 | **是** |
| `kill` | 按等级杀无用进程 | 否 |
| `full` | trim + purge + kill | purge 部分需要 |
| `watch` | 常驻守护：定时 trim，低于阈值自动 kill | 否 |

### 等级

| `-Level` | 杀什么 |
|---|---|
| `light` | 壁纸、资讯源、小组件、Xbox 覆盖、各类更新器 |
| `normal` | light + 华硕 helper、NVIDIA 覆盖、Steam 内置浏览器、WebView2 |
| `heavy` | normal + 浏览器、QQ、WPS、Steam、Electron、搜索 |

`light` / `normal` / `heavy` 都**不碰有主窗口的进程**。要真的关窗口，加 `-IncludeWindowed`。

### 安全设计

默认永不触碰：

- **游戏**：命中 `$script:DefaultGamePatterns` 或路径像游戏目录的进程。检测到游戏在跑时自动进入保护模式
- **前台窗口**：`MainWindowTitle` 非空的进程，除非 `-IncludeWindowed`
- **系统**：`csrss` `lsass` `svchost` `dwm` `explorer` `MsMpEng` 等全套
- **输入法**：`wetype_server` / `wetype_renderer`（杀了就打不了字）
- **自己**：当前进程的整条父链 + 命令行含 `dsh` / `deepseek` 的 node
- **trim 额外跳过**：`>800MB` 的大进程（避免页错误造成卡顿）

### 参数

```powershell
-Top 15                  # report 显示行数
-DryRun                  # 只打印不执行
-KeepNames msedge,QQ     # 本次额外保护
-KillNames notepad       # 本次额外要杀
-KillPid 1234            # 按 PID 精确杀（绕过白名单和窗口保护）
-IncludeWindowed         # 连有窗口的也杀
-IncludeGame             # 连游戏也杀
-AggressiveTrim          # trim 不跳过大进程和窗口进程（会卡）
-NoGameGuard             # 关掉游戏自动保护
-Elevate                 # 自动弹 UAC 以管理员重开
-Interval 600            # watch 间隔
-MinAvailableGB 2        # watch 阈值
```

### 自定义名单

改脚本顶部 `$script:DefaultLevels`，或者在同目录建 `free-ram.config.json` 追加（不覆盖）：

```json
{
  "protect": ["我的进程"],
  "levels": {
    "light":  ["someupdater"],
    "normal": ["vendorhelper"],
    "heavy":  ["chrome"]
  },
  "gamePatterns": ["*Minecraft*"],
  "replaceLevels": false
}
```

---

## Disable-Autostart.ps1

覆盖四类自启：注册表 `Run`（HKLM / HKCU / WOW6432Node）、启动文件夹、计划任务、自动服务。

```powershell
.\Disable-Autostart.ps1                     # 只读：列出全部自启 + 命中规则的
.\Disable-Autostart.ps1 -Disable -DryRun    # 预览
.\Disable-Autostart.ps1 -Disable            # 真禁用（先写备份）
.\Disable-Autostart.ps1 -Restore            # 按备份全部还原
```

默认命中常见全家桶：WPS、钉钉、WorkBuddy、夸克、百度网盘、必应壁纸、Edge 自启、Google 推广任务、微软 SoftLanding 推广任务等。

有一份**硬保护名单**（`$hardProtect`），`ctfmon` / `SecurityHealth` / `aTrust` / 华硕 / NVIDIA / 输入法服务等命中即跳过。要越过它必须显式加 `-OverrideProtect`。

备份写到同目录 `autostart-backup.json`，`-Restore` 逆操作还原。这个文件已被 `.gitignore` 排除。

---

## 已知限制

**杀进程名单是为作者那台机器调的。** `ArmouryCrate`、`wetype_update`、`RelicCardinal` 这些在别的机器上不命中，**不会误杀，只是没效果**。换机器先跑 `ram -Mode suggest`，把标 `-`（未分类）的进程挑出来加进名单。

**EDR 可能让 trim 静默失效。** `Add-Type` 要在运行时调 `csc.exe` 编译一小段 C#。SentinelOne、CrowdStrike 这类会拦它——结果是脚本照跑、报告照出、一个进程都没压（[相关 issue](https://github.com/Nailuu/wsl-screenshot-cli/issues/3)）。`Setup.ps1` 的自检会明确报告这一项能不能用。`kill` 和 `purge` 不依赖编译器，不受影响。

**处理待机缓存不一定有意义。** Windows 把文件缓存留在 standby 列表是设计如此，清空它不会让程序变快，反而可能让刚用过的程序变慢。真正有用的场景是「可用内存见底、系统开始频繁换页」的时候。

**`purge` 需要管理员。** 普通权限下会提示并以普通模式继续。

**只在 Windows 10 1809+ / Windows 11 上验证过。** build 低于 17763 的系统 `purge` 可能无效。

---

## 环境

- Windows 10 1809+ / Windows 11
- 系统自带的 PowerShell 5.1 即可，PowerShell 7 也支持
- 不需要 .NET SDK、Python、管理员权限（`purge` 除外）

---

## 致谢

接口用法参考：[RAMMap](https://learn.microsoft.com/sysinternals/downloads/rammap)（微软官方）、
[Mem Reduct](https://github.com/henrypp/memreduct)、EmptyStandbyList（WJ32）。

## License

MIT
