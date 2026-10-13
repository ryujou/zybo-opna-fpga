# 当前验证状态

验证日期：2026-10-08。原版 Zybo / XC7Z010，Windows 11，Vivado/Vitis 2025.2。

- 交付：`firmware/usb_dual` 中匹配的 FPGA/PS/启动镜像；FPGA 接口 `0x26080008`、USB 协议 `2.2`。SW0 在 MIDI 与原曲模式间切换。
- 播放器：`StartPlayer.cmd` 在独立仓库中启动浏览器；Python/Vue 页面、共用 VGM 音量解析、PMD 解码及 FM/SSG/节奏/ADPCM 软件参考波形。源码及预编译组件均在 `pc_player`，无需旁边的 OPL3 工程或本机缓存。
- [音量与混音验收](../verification/volume-mix/acceptance.json)：13 首原始文件完整播放 1602.327 秒，左右削波 0；39 个探针窗口、1664 次起始寄存器写入及 589376 字节样本回读通过。
- RTL 宽整数模型 2160 组检查、AXI/PS 协议边界、原曲/MIDI 切换通过；WNS +0.070 ns、WHS +0.053 ns，DRC/关键 CDC 为 0。
- [浏览器实板](../verification/browser-player/hardware.json)：CT、Counterattack 上传和暂停/继续/切曲通过；《少女绮想曲》PMD 完整 77.916916 秒，flags=0、queued=0、左右削波=0，最大调度迟到 823 µs。
- 独立发布目录测试：15 项主机检查，12 项通过、3 项需私有音乐/参考载荷而跳过；合成 SSG 输入的 VGM/VGZ、音量、分路波形和设备身份检查通过。Windows 波形 DLL/PMD 工具从固定源码构建成功。
- 数据边界：统一使用 1/8 输出余量，不做逐曲归一化，不补写 0x29。SSG 噪声/快速包络和部分 ADPCM 存在跨模型波形差异。
- 本轮板端使用 JTAG 易失加载；结束恢复物理 SW0 控制，未写 SD/QSPI。独立冷启动、模拟录音和真实芯片电气比对不属于已通过验收。

原生核心累计门控见 [Phase 7](../verification/phase-07/)，MIDI 基线见 [USB MIDI](../verification/usb-midi/)。使用与构建入口见 [README](../README.md)。
