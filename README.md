# Free-Ram

Windows 内存回收 + 开机自启管理，纯 PowerShell，零依赖，中文。

通用内存清理请用 [Mem Reduct](https://github.com/henrypp/memreduct)，成熟、有 GUI、有托盘。
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

## 不用配名单：给进程打分

`EmptyWorkingSet` 和 `NtSetSystemInformation(SystemMemoryListInformation)` 是 Windows 20 年前就有的内部接口，谁都能调。这个项目不提供任何新技术。

判断一个进程该不该杀，别的清理脚本靠「进程名白名单」——写死 `chrome.exe`、`QQ.exe` 该不该动。换个软件就失效，换台电脑就得从头配一遍。

这里改成**给每个进程打分**，判据是行为特征，不是名字。规则在任何 Windows 机器上成立。

| 特征 | 分 | 依据 |
|---|---|---|
| 名字含 `update` / `setup` / `install` / `patch` | **+50** | 更新器跑完就该退出 |
| 装在 `\update` 目录 | +35 | 同上 |
| 跑在 `\Temp\` / `\Tmp\` 目录 | +30 | 临时目录里的东西 |
| 名字含 `crashpad` / `telemetry` / `reporter` / `analytics` | +30 | 上报与遥测 |
| 父进程已退出且活了 30 分钟以上 | +12 | 孤儿进程 |
| 名字含 `helper` / `overlay` / `widget` / `tray` / `watchdog` | +15 | 辅助壳 |
| 没有主窗口 | +8 | |
| CPU 空转（<0.5%） | +8 | 闲着 |
| 私有内存 | 最多 +20 | 800MB 封顶 |
| 在自启列表里 | +6 | |
| 浏览器内核子进程（`--type=renderer`） | +6 | |

### 否决级保护（命中直接排除）

- **会话 0** —— 服务会话里的东西不归这工具管
- **系统关键进程** —— `csrss` `lsass` `svchost` `dwm` `explorer` `MsMpEng` 等
- **输入法 / 音频** —— `ime` `input` `audio` `mic` `speech` `ctfmon`
- **游戏与反作弊** —— `steam` `epic` `battleye` `vanguard` `EasyAntiCheat` `ACE` `SGuard`
- **数据库 / 容器** —— `mysqld` `postgres` `redis` `mongo` `sqlservr` `dockerd`
- **有主窗口**（窗口标题含「更新/升级」的除外）
- **微软签名**，或装在 `C:\Windows\` 下
- **当前进程自己的整条父链**

### 裁决

| 分数 | 裁决 | 含义 |
|---|---|---|
| **≥70 且命中「强证据」** | **可杀** | `ram -Mode auto` 只动这些 |
| 45 – 69 | 谨慎 | 加 `-IncludeCautious` 才动 |
| 15 – 44 | 观察 | 只列出来给你看 |
| < 15 | 别动 | 不显示 |

**「强证据」= 命中更新器 / 遥测 / 临时目录 / 孤儿 中的至少一条。**

一个只是「安静、占内存」的进程永远进不了「可杀」。所以 QQ、微信、你的编辑器、
正开着的浏览器不会被自动干掉——它们没有「本来就该退出」的证据。

实际输出：

```
   分  裁决       私有     工作集  进程                    pid     依据
   75  可杀     373MB     67MB  wetype_update          50512   373MB 私有内存、名字像更新器、CPU 空转
   48  谨慎    3013MB     39MB  python                 36308   3,013MB 私有内存、父进程已退出、CPU 空转
   40  观察     106MB     18MB  NVIDIA Overlay         43844   106MB 私有内存、辅助/托管类、CPU 空转
   29  观察     293MB    211MB  QQ                     42180   293MB 私有内存、CPU 空转、浏览器内核子进程
```

### 另外还有两件事

**游戏保护。** 检测到有 `>700MB` 且路径落在 `steamapps` / `Epic Games` / `XboxGames` 的进程在跑时，自动进入保护模式——Steam 全家、游戏本体、反作弊全部排除。

**自启管理和内存清理在同一个包里。** 实际场景就是「这台电脑变慢了」，两件事一起做，而不是装两个工具。


---

## 快速开始

```powershell
# 方式一：便携包（推荐）
# 下载 ZIP，解压到任意位置，双击 Setup.cmd，之后双击桌面「释放内存」

# 方式二：手动
git clone https://github.com/dawnnnnnnnnnnnnnnnn/free-ram.git
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
| `auto` | **按评分自动杀**——只动 ≥70 分且有强证据的进程 | 否 |

### 等级（老的分名单模式，仍然保留）

| `-Level` | 杀什么 |
|---|---|
| `light` | 壁纸、资讯源、小组件、Xbox 覆盖、各类更新器 |
| `normal` | light + 华硕 helper、NVIDIA 覆盖、Steam 内置浏览器、WebView2 |
| `heavy` | normal + 浏览器、QQ、WPS、Steam、Electron、搜索 |

`light` / `normal` / `heavy` 都**不碰有主窗口的进程**。要真的关窗口，加 `-IncludeWindowed`。

> `-Mode auto` 不需要 `-Level`。评分引擎自己判断，换机器不用改任何东西。

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
-KeepNames msedge,QQ     # 本次额外保护（评分时直接排除）
-KillNames notepad       # 本次额外要杀（按等级名单）
-KillPid 1234            # 按 PID 精确杀（绕过白名单和窗口保护）
-IncludeWindowed         # 连有窗口的也杀
-IncludeGame             # 连游戏也杀
-IncludeCautious         # auto 模式连「谨慎」（45 分以上）一起杀
-MinScore 70             # 改 auto 的分数阈值
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

**评分是启发式的，不认识你的具体软件。** 它靠「更新器 / 遥测 / 临时目录 / 孤儿 / 辅助壳」这些通用特征判断，不依赖进程名，所以换机器零配置。但反过来说，一个你不想要、又不具备这些特征的常驻程序（比如某个纯后台的采集服务）它认不出来，会停在「观察」档。这种情况用 `-KillNames` 或改 `$script:DefaultLevels` 补。

**EDR 可能让 trim 静默失效。** `Add-Type` 要在运行时调 `csc.exe` 编译一小段 C#。SentinelOne、CrowdStrike 这类会拦它——结果是脚本照跑、报告照出、一个进程都没压（[相关 issue](https://github.com/Nailuu/wsl-screenshot-cli/issues/3)）。`Setup.ps1` 的自检会明确报告这一项能不能用。`kill` 和 `purge` 不依赖编译器，不受影响。

**处理待机缓存不一定有意义。** Windows 把文件缓存留在 standby 列表是设计如此，清空它不会让程序变快，反而可能让刚用过的程序变慢。真正有用的场景是「可用内存见底、系统开始频繁换页」的时候。

**`purge` 需要管理员。** 普通权限下会提示并以普通模式继续。

**从网上下载的 ZIP 会带「来自其他计算机」标记。** 浏览器/微信/QQ 传过来的压缩包，解压后每个文件都被打上 `Zone.Identifier=3`，PowerShell 可能拒绝加载。两个 `.cmd` 入口的第一行就是递归 `Unblock-File`，正常双击不会遇到；如果手动跑 `.ps1` 报错，先解压后右键 zip → 属性 → 勾「解除锁定」。

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
