# Zybo / XC7Z010 离线构建

目标为原 Zybo Rev. B 的 `xc7z010clg400-1`，工具为 Vivado 2025.2。先初始化固定子模块并运行 `scripts/prepare_reference_assets.py`，生成本地节奏 ROM。

完整核心容量检查：

```powershell
& "$env:OPNA_VIVADO_ROOT/bin/vivado.bat" -mode batch -source hardware/vivado/phase7_core_probe.tcl
```

板级构建入口为 `phase7_board.tcl`，使用同一份 `opna_sources.tcl` 核心清单以及 `hardware/rtl/board`。PS GP0 连接四个原生总线字节端口和控制状态，HP0 连接完整 256 KiB 样本空间。系统时钟为 100 MHz，芯片半周期使能每 25 个系统周期产生 4 次。

音频使用独立的 12.2880025126 MHz codec 时钟，I2S 为 48 kHz 标称采样率、16 位立体声。原生 PCM 完整左右帧按最近帧保持转换至 I2S，SSG 在板级按固定幅度表混合；原生核心的样本和时序接口保持独立。

```powershell
& "$env:OPNA_VIVADO_ROOT/bin/vivado.bat" -mode batch -source hardware/vivado/phase7_board.tcl
```

构建在综合后插入原生与音频两组 ILA，再检查包含 debug hub 的整板容量；超限立即停止。布线、setup/hold/pulse 时序、DRC 和 CDC 满足后才生成 `build/opna_phase7/board/zybo_opna.bit`、`zybo_opna.xsa` 与 `zybo_opna.ltx`。实际端口时序也属于离线验收。器件编程及实际 ILA 采集单独执行。

当前已实测整板实现为 11,576 / 17,600 LUT、12,343 / 35,200 FF、38.5 / 60 BRAM、0 / 80 DSP；布线 WNS +0.262 ns、TNS 0、WHS +0.051 ns。八组实际原生 ILA、音频 ILA、USB 与 DDR 检查通过，交付目录为 `build/opna_phase7/pipeline-board`。Phase 1–7 A–D 累计离线门控全部通过。证据与板测命令见 [Phase 7](../../docs/phases/phase-07.md)。

PS7 配置及引脚依据 Digilent 原 Zybo Rev. B 资料，来源和 MIT 许可见 `zybo_ps7.tcl`、`hardware/rtl/constraints/zybo.xdc` 和 `LICENSE.digilent`。厂家 preset 的四个负 DQS-to-CLK 延迟保持原值；PSU1～4 配置提示与实现时序、DRC 检查分别核对。

完整累计门控从项目根目录执行：

```powershell
.\scripts\run_opna_gate.ps1 -Phase 7 -Step D -Offline
```

离线通过不代表 USB 枚举、DDR 实际训练、codec 模拟输出或板上音频已验证。
