# v6（C# 重写版）进度与待办

> 记录时间：2026-11-27
> 当前状态：**可安装、可日常使用**，功能约为 v5.97 的 85%

## 已完成

| 模块 | 文件 | 状态 |
|---|---|---|
| NVML 直连采样（0.09 ms/次） | `src/Nvml.cs` | ✅ |
| CPU 采样（性能计数器） | `src/CpuSampler.cs` | ✅ |
| CPU 温度（LHM → ACPI 回退） | `src/LhmBridge.cs` + `MainForm.ReadAcpiTemp` | ✅ |
| 主界面（卡片/双曲线/滚动条/悬停） | `src/MainForm.cs` | ✅ |
| 双缓冲渲染（无拖影） | `src/ChartRenderer.cs` | ✅ |
| 数据落盘（CSV / 历史 / 标记） | `src/Storage.cs` | ✅ |
| 重启接续 6 小时曲线 | `Storage.LoadHistory` | ✅ |
| 游戏识别 + 自动切目录 | `src/GameDetect.cs` | ✅ |
| 崩溃判定 + 报告 + 快照 | `src/CrashReport.cs` | ✅ |
| 崩溃卡片（非模态） | `src/CrashCard.cs` | ✅ |
| 诊断报告 / DirectX 检查 | `src/Diagnosis.cs` + `TextDialog.cs` | ✅ |
| 中英双语 | `lang/*.ini` + `src/I18n.cs` | ✅ |
| 托盘 / 自启 / 单实例 / 身份隔离 | `MainForm` / `Program` | ✅ |
| 安装向导 | `setup/Setup6.cs` + `install6.ps1` | ✅ |

## 待办（按优先级）

### ~~1. 错误码解读~~ ✅ 已完成（2026-11-27）
- 数据：`data/error-codes.txt`（中）、`data/error-codes.en.txt`（英），各 25 条
- 格式：`代码|名称|含义|原因|建议`
- 要做：报告里遇到 0x887A0006 这类代码时，附上解读；诊断弹窗里也能查
- 工作量：约 2 轮

### ~~2. 温度基线对比~~ ✅ 已完成（2026-11-27）
- 逻辑：记录空闲时的温度/频率基线，游戏内对比，报告里写「+30°C」
- v5 实现：`Get-TempProfile`（在 `GameCrashDiag.ps1` 里搜这个名字）
- 工作量：约 2 轮

### ~~3. 卸载流程~~ ✅ 已完成（2026-11-27）
- 现在只有注册表里的卸载项，点了只是启动程序
- 要做：`uninstall6.ps1`（关进程、删文件、删快捷方式、删自启、删注册项）
- 工作量：约 1 轮

### ~~4. 与 v5 的差异收尾~~ ✅ 分界线时长已补（2026-11-27），其余待查
- v5 的「会话分界线间隔时长」文字（隔 2.3 小时）v6 只有竖线没有时长
- 清空全部历史后 v6 不重建 marker 文件（小问题）

### 5. 长期：切默认版本
- 目标：v6 跑稳一周后，把桌面快捷方式和开机自启切到 v6
- 前提：上述 1~3 完成 + 实际游戏验证过崩溃报告

## 构建方式

```powershell
# 主程序（输出到 D:\Program Files\GameCrashDiag6\GameCrashDiag6.exe）
D:\AI_Work\game-crash-diag\构建v6.ps1

# 安装程序（输出到 setup\setup6.exe，再复制成中文名）
D:\AI_Work\game-crash-diag\构建安装程序-v6.ps1
```

编译器：系统自带 `C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe`（C# 5.0，无需装 SDK）

## 自检开关

```powershell
GameCrashDiag6.exe -SelfTest           # 采样一次并测速
GameCrashDiag6.exe -UiTest             # 界面构建自检 + DPI 信息
GameCrashDiag6.exe -Collect 30         # 无界面采集 30 秒写 CSV
GameCrashDiag6.exe -TestDetect         # 游戏识别测试
GameCrashDiag6.exe -TestReport         # 报告生成测试（假数据）
GameCrashDiag6.exe -TestCrashFlow      # 完整崩溃流程测试
GameCrashDiag6.exe -TestDiagnosis      # 诊断文本输出
GameCrashDiag6.exe -Shot out.png       # 窗口渲染成图片
GameCrashDiag6.exe -Tray               # 启动即进托盘
```

## 关键数字

| 指标 | v5（PowerShell） | v6（C#） |
|---|---|---|
| 主程序 | 636 KB 安装包 | **99 KB exe** |
| 安装包 | 636 KB | 844 KB（含 885 KB 传感器库） |
| 内存 | 220 MB | **88~106 MB** |
| 采样耗时 | 106 ms | **0.09 ms** |
| 启动 | ~1 秒 | ~0.2 秒 |

## 目录

```
D:\Program Files\GameCrashDiag      v5.97 正式版（开机自启指向这里）
D:\Program Files\GameCrashDiag6     v6.0 开发副本（instance.txt = v6-test）
D:\AI_Work\game-crash-diag\         源码仓库（GitHub: zoesion/game-crash-diag）
D:\AI_Work\游戏崩溃诊断器-v6-安装程序.exe   最新安装包
```
