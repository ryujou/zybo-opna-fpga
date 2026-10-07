# Zybo OPNA / YM2608B FPGA

以 JT12/JT10B 为基础的 YM2608B 数字播放核心，目标器件为 Zybo 的 XC7Z010clg400-1。芯片数据手册优先，YM2608-LLE 提供原生运算和时序对照，ymfm 提供独立功能检查。

范围包含六通道 FM、LFO、SSG-EG、通道 3 特殊模式、CSM、三通道 SSG、六种节奏音、ADPCM-B 播放与样本内存访问、定时器、IRQ、busy 和原生立体声数字输出。

## 验证状态

Phase 1～6 的 A～D 门控全部通过。Phase 6 包含 14 个正常用例和 14 个时钟暂停用例，共 15,296,856 条原始观察的数字值及 tick 完整一致。验收规则见 [Phase 6](docs/phases/phase-06.md)，已完成的结果见 [数字验收证据](verification/phase-06/gate-D.json)。

完整数字核心的独立综合为 6096 LUT、5776 FF、1 BRAM、0 DSP。包含 PS/DDR 接入和音频接口的整板综合使用 **18,734 / 17,600 LUT（106.44%）**，超出 XC7Z010 容量，Phase 7 已按容量门停止。板级定向仿真和准备 XSA 的软件构建通过；布局布线、时序/CDC、最终 bit/XSA 和实板验收未完成。容量证据见 [Phase 7](docs/phases/phase-07.md)。

SCH 沿用已确认的工程契约，其实片边界尚未核验。录音编码、模拟电气特性和 PC-98 C-bus/BIOS 不在本项目范围内。

## 获取与验证

验证环境为 Windows、PowerShell 7、Python 3、Git 和 Vivado 2025.2。参考程序使用 Vivado 随附的 MinGW 10.0.0，无需另装 Python 依赖。

```powershell
git clone --recurse-submodules https://github.com/ryujou/zybo-opna-fpga.git
Set-Location zybo-opna-fpga
$env:OPNA_VIVADO_ROOT = 'J:/FPGA/2025.2/Vivado'
py -3 -X utf8 scripts/prepare_reference_assets.py
.\scripts\run_opna_gate.ps1 -Phase 6 -Step D
```

上游版本固定在 [sources.json](tools/opna_sim/sources.json)。准备脚本在本地从固定 LLE 源码生成节奏 ROM，并取得 Furnace 0.6.8.3 官方示例供本地音乐测试。ROM、原曲和导出 VGM 均不随本仓库分发，保留各自原始权利。已有该版本 Furnace 时可传入 `--furnace 路径/furnace.exe`。

完整门控会重新执行 Phase 1～5，再执行 Phase 6 A～D。同阶段 XSim 用例默认八路并行，可用 `OPNA_SIM_WORKERS` 调整；长时用例保留完整连续仿真。`verification/` 保存已完成的 JSON 验收记录，重跑的日志与完整输出写入 `build/`。

板级综合入口见 [Vivado 构建说明](hardware/vivado/README.md)，其容量超限检查返回失败并停止。PS 软件使用 Vitis 2025.2 生成真实 BSP，源码和本地构建命令见 [PS 软件说明](software/ps_baremetal/README.md)。

## 代码

- `hardware/rtl/opna_core/`：独立核心及 JT12 适配；总线和样本存储接口保留在核心外部。
- `hardware/sim/`：数字核心 testbench。
- `tools/opna_sim/`：固定参考、用例、严格比较与并行门控。
- `hardware/rtl/board/`：原生总线、DDR 样本供数和立体声 I2S 接口。
- `hardware/vivado/`：XC7Z010 完整核心及板级工程构建。
- `software/ps_baremetal/`：PS 传输、事件播放、样本上传及 codec 配置。
- `docs/`：芯片行为、阶段规则和验证边界。

项目自有数字核心、工具及 RTL 适配采用 GPL-3.0-or-later；PS 软件中显式标注的 LGPL-3.0-or-later 和 MIT 文件沿用各自许可，上游文件保留原许可证和版权。详见 [LICENSE](LICENSE) 与 [第三方来源](THIRD_PARTY_NOTICES.md)。
