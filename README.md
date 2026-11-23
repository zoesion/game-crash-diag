# BF6监控器

> 战地6 运行时 GPU / CPU 实时监控与崩溃取证工具 —— 专治 `DXGI_ERROR_DEVICE_HUNG` 这类 DX 报错。

一个 PowerShell + WinForms 写的桌面小工具，**零依赖、不需安装运行时**，Windows 自带 PowerShell 就能跑。
游戏运行时自动记录显卡和处理器状态，崩溃时自动生成带现场数据的报告，用来定位到底是超频、散热、驱动还是硬件的问题。

![界面](preview.png)

---

## 为什么做这个

战地6 的 DX 崩溃（`0x887A0006` / `0x887A0005`）最恶心的地方在于：崩完什么都没留下。
系统事件日志只说"驱动出错了"，游戏只给你一个弹窗，**崩溃前那一刻的功耗、频率、温度全部丢失**。

这个工具做的就是补上这段空白：

1. 每 0.5 秒采一次 GPU + CPU 状态，落盘成 CSV
2. 游戏进程消失时，自动判定是崩溃还是正常退出
3. 崩溃则生成报告：崩溃前 40 条遥测 + 前后 10 分钟系统事件 + 应用错误 + 系统配置

---

## 特性

| 能力 | 说明 |
|---|---|
| **GPU 实时监控** | 温度 / 功耗 / 核心频率 / 占用率 / 显存 / 降频原因 |
| **CPU 实时监控** | 温度 / 实际频率 / 占用率 / 活跃核心数 |
| **双走势图** | 上图 GPU（青=温度 灰=功耗），下图 CPU（青=温度 橙=频率），带颜色图例 |
| **一万点缓存** | 每张图保留 10,000 个采样点，500ms 采样 ≈ 1.4 小时 |
| **自动记录** | 检测到 `bf6.exe` 自动开始，退出自动结算 |
| **日志分流** | 游戏时写 `logs\bf6\`，不打游戏时写 `logs\system\`，互不污染 |
| **崩溃取证** | 自动区分「崩溃」和「正常退出」，只对真崩溃告警 |
| **通用模式** | 没有 N 卡也能跑（AMD / Intel 核显），自动降级 |
| **进阶脚本** | 取证包收集、minidump 解析、功耗墙调节、系统修复 |

---

## 环境要求

- Windows 10 / 11
- PowerShell 5.1（系统自带，无需安装）
- **NVIDIA 显卡**可获完整数据；AMD / Intel 走通用模式（只有占用率和显存）

---

## 安装

### 方式一：安装脚本（推荐）

1. 下载或解压本仓库
2. 双击 **`安装.cmd`**
3. 装到 `%LOCALAPPDATA%\Programs\BF6Monitor`，**不需要管理员权限**

会自动创建桌面和开始菜单快捷方式，在「设置 → 应用」里可以正常卸载。

### 方式二：免安装

直接双击 `启动监控器.vbs`，就地运行。

---

## 使用

双击桌面上的 **BF6监控器**，然后该干嘛干嘛：

- **打游戏时** → 自动切到 `logs\bf6\`，记录对局数据
- **不打游戏时** → 自动记录到 `logs\system\`，当普通电脑监控用
- **游戏崩溃** → 弹窗提示，报告写入 `reports\crash-*.txt`
- **正常退出** → 静默生成 `reports\session-*.txt`，不打扰

窗口可以最小化，也可以放副屏。

---

## 界面说明

**八个卡片**：上排 GPU（温度/功耗/核心频率/占用），下排 CPU（温度/频率/占用/活跃核心）。

颜色阈值：

| 指标 | 黄色 | 红色 |
|---|---|---|
| GPU 温度 | ≥ 75°C | ≥ 85°C |
| CPU 温度 | ≥ 85°C | ≥ 95°C |
| CPU 占用 | ≥ 70% | ≥ 90% |

**两张曲线图**的颜色含义直接标在左上角图例里，不用记。

**底部信息行**：显存占用 / 内存占用 / GPU 降频原因 / 电源状态。

---

## 数据在哪

```
BF6Monitor\
├─ logs\
│  ├─ bf6\       游戏对局遥测（bf6-*.csv）
│  └─ system\    日常监控（sys-*.csv）
├─ reports\      崩溃报告 crash-*.txt / 对局记录 session-*.txt
└─ backup\       注册表与超频配置备份
```

### CSV 字段

```
time, temp_c, power_w, clock_sm_mhz, clock_mem_mhz, util_gpu_pct, util_mem_pct,
mem_used_mb, pstate, event_reason, power_cap, hw_slowdown, thermal_throttle,
throttle_text, cpu_temp_c, cpu_mhz, cpu_load_pct, cpu_cores_active,
cpu_cores_total, ram_pct
```

Excel 直接打开即可。

---

## 崩溃后怎么分析

1. 打开 `reports\crash-*.txt`
2. 看**崩溃前最后 40 条遥测**：功耗有没有突然拉满？频率有没有断崖？温度是否异常？
3. 看**系统事件**里有没有 `nvlddmkm` 的 Event 13 / 153
4. 有 BF6 自己的转储的话，用 `tools\analyze-dump.ps1` 解析：

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\analyze-dump.ps1 `
  -DumpPath "$env:USERPROFILE\Documents\Battlefield 6\CrashDumps\xxx.mdmp" -ShowModules
```

会输出异常代码、出错地址所属模块、以及崩溃时进程里加载了哪些模块（能看出有没有 DLSS、叠加层注入）。

### 判读速查

| 现象 | 含义 |
|---|---|
| 数据一切正常，然后突然没了 | 电压/频率不稳或驱动缺陷，不是散热问题 |
| 崩溃前温度冲到 85°C+ | 散热导致，查硅脂/风扇/积灰 |
| 崩溃前频率掉到 1000MHz 以下 | 硬件降频，供电或温度撑不住 |
| `nvlddmkm` Event 13 `Graphics SM Global Exception` | GPU 流处理器执行出错，硬件级，重点查超频和驱动 |

---

## 进阶脚本（tools\）

| 脚本 | 用途 |
|---|---|
| `collect-forensics.ps1` | 一键抓取证包（事件日志 + WER + 配置 + 转储索引），3 秒出 zip |
| `analyze-dump.ps1` | 不依赖 WinDbg 解析 minidump，提取异常码和模块表 |
| `apply-fixes.ps1` | 关 HAGS、放宽 TDR、重置超频（需 UAC，自动备份） |
| `power-cap.ps1` | 调整 GPU 功耗墙，削平功耗尖峰 |
| `gpu-watch.ps1` / `crash-watch.ps1` | 无界面版的后台记录 / 崩溃抓取 |

> `apply-fixes.ps1` 会改注册表，跑之前自动备份到 `backup\<时间>\`，
> 还原就是 `reg import` 那个 .reg 文件。

---

## 显卡兼容性

| 显卡 | 支持程度 |
|---|---|
| NVIDIA 独显 | 完整：温度 / 功耗 / 频率 / 占用 / 显存 / 降频原因 |
| AMD 独显 / Intel 核显 | 通用模式：只有 GPU 占用 和 显存 |
| 任意 CPU | 完整：温度（看主板）/ 频率 / 占用 / 活跃核心 |

通用模式用 Windows 自带的性能计数器：

```
\GPU Engine(*engtype_3D)\Utilization Percentage
\GPU Adapter Memory(*)\Dedicated Usage
```

强制测试通用模式：`BF6Monitor.ps1 -ForceGeneric`

---

## 命令行参数

```powershell
BF6Monitor.ps1                     # 正常启动
BF6Monitor.ps1 -Minimized          # 最小化启动
BF6Monitor.ps1 -IntervalMs 250     # 改成 250ms 采样（更细，更费 CPU）
BF6Monitor.ps1 -ForceGeneric       # 强制通用模式
BF6Monitor.ps1 -SelfTest           # 采集自检
BF6Monitor.ps1 -UiTest             # 界面自检（不弹窗）
BF6Monitor.ps1 -Shot out.png       # 离屏截图
```

---

## 常见问题

**Q: 窗口显示「读取失败」**
`nvidia-smi` 没响应，多半是驱动刚崩了正在恢复，等几秒自动恢复。

**Q: 记录中但数据不涨**
确认 `bf6.exe` 在跑。系统监控模式下也会记录，只是写到 `logs\system\`。

**Q: 游戏崩了但没生成报告**
程序必须开着才有效。没开的话只能用 `tools\collect-forensics.ps1` 事后捞事件日志（没有秒级遥测）。

**Q: 怎么开机自启**
把桌面快捷方式拖进 `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\`。

---

## 技术说明

- 界面：PowerShell + WinForms，深色主题
- 绘图：C# 编译的渲染器（`ChartRenderer.cs`），1 万点重绘 ~30ms
- 采样：`nvidia-smi` / Windows 性能计数器，Timer 驱动
- 无外部依赖，不联网，不上传任何数据

---

## 更新日志

### v1.3
- 新增 CPU 四张卡片：温度 / 频率 / 占用 / 活跃核心
- 两张曲线图增加颜色图例标注
- 日志按场景分流：`logs\bf6\` 与 `logs\system\`
- CSV 新增 `cpu_cores_active` / `cpu_cores_total` / `ram_pct`
- 新增通用模式（AMD / Intel 显卡可运行）
- 崩溃与正常退出自动区分

### v1.2
- 新增 CPU 走势图
- 采样率可配置（默认 500ms）

### v1.1
- 新增曲线图、崩溃自动取证
- 一万点缓存

### v1.0
- 首个版本

---

## 许可

[MIT License](LICENSE)
