# YM2608B / OPNA 数字逻辑

## 目标与边界

在 Zybo / XC7Z010clg400-1 实现 YM2608B 完整播放路径。首先完成独立核心的数字逻辑仿真验收，再优化资源、接入 PS 和上板。

范围：六通道四算子 FM、LFO、SSG-EG、通道3特殊模式、CSM、三通道SSG、六种节奏音、ADPCM-B播放与样本内存读写、分频、Timer A/B、IRQ、busy、状态、原生立体声数字输出。

不包含录音编码、模拟DAC电气特性、PC-98 C-bus/BIOS、独立86 PCM和未定义测试模式。

## 实现与参考

- 硬件基础：JT12的JT10B六通道配置和JT49；YM2610B与YM2608B的寄存器、时序和解码差异必须适配。
- 芯片数据手册优先；参考模型与手册冲突时，在项目侧修正参考和RTL，固定上游源码保持原样。
- ymfm：快速功能和音频回归，不是逐边沿时序的唯一真值。
- YM2608-LLE：YM2608B低层时序、数字串行音频及SSG数字状态参考。
- 固定源码版本见 tools/opna_sim/sources.json，保留上游版权和许可证。
- 默认主时钟8 MHz。模型分歧必须定位，不通过放宽容差消除。

ZERO按[YM2608应用手册第52页](https://csclub.uwaterloo.ca/~pbarfuss/YM2608J_Translated.PDF)执行持续静音约290 ms后置位、非静音复位计数。项目侧LLE参考修正固定源码的静音计数极性，RTL采用相同手册契约；验证范围见[Phase 5](phases/phase-05.md)。

SCH工程契约（SCH-LLE-2026-10-07，用户确认）：采用固定LLE的key锁存与扫描译码。六通道持续运算，SCH不直接屏蔽高通道输出；SCH=0时key通道高位失效，切换SCH会改变最后一次锁存key的译码目标。JT12/JT10B仍为RTL基础；ymfm和旧MAME用于交叉检查。四组边界用例必须通过LLE逐样本、逐时刻比较，ymfm的已知差异单独断言，不能忽略。该决定固定了实现预期，未将模型推断升级为实片事实；Phase 6结论必须保留此项实片验证限制。证据和适用范围见[Phase 3](phases/phase-03.md#sch工程契约)。

来源：https://github.com/jotego/jt12 、https://github.com/jotego/jt49 、https://github.com/aaronsgiles/ymfm 、https://github.com/nukeykt/YM2608-LLE 。

## PS / PL 分工

PS管理USB/preload、播放控制、事件准备、DDR样本和传输。PL保留芯片寄存器、精确定时、所有声音运算、混音和音频输出。PS不生成PCM，不替代芯片寄存器译码。

独立核心总线保留A1:A0、CS/WR/RD、8位数据和IRQ；地址写与数据写分别执行。样本存储在核心外。原生数字输出与重采样、I2S分离。

控制RTL使用系统clk及half_ce、chip_clk：half_ce有效的系统上升沿推进一个芯片半周期，chip_clk给出该半周期的高低电平。暂停half_ce不会推进芯片时间。控制模块连接JT12/JT49波形运算、节奏音及ADPCM-B原生扫描模块；ADPCM标志、CPU读数据和外部存储引脚由ADPCM模块产生，状态读取和IRQ保持原生锁存时刻。

## 一致性契约

- 时间单位为主时钟半周期tick：偶数低边沿，奇数高边沿，每tick 62.5 ns。输入在对应边沿计算前生效。
- 使用真实低有效IC复位，并包含复位及释放稳定时间。
- 微秒preload格式不承担严格时序验收。
- 比较读返回、IRQ/busy变化时刻、原生数字音频及SSG数字门控/音量码。
- 输出格式在Phase 1固定；不允许按用例调整时间偏移、增益或误差容限。
- 软件参考通过不等于RTL通过，仿真通过不等于板测通过。

## 平台与连续性

工程位于 J:/lumia/FPGA/PC98。Vivado 2025.2位于 J:/FPGA/2025.2。仿真使用XSim，参考程序使用随附MinGW C/C++，辅助检查使用Python 3标准库。

现有PS baremetal、USB/preload、I2S、SSM2603初始化和板级约束在Phase 7接入。既有mtrberzi包装器和位流不作为YM2608一致性依据。

阶段和门控见todo.md，当前状态见progress.md，已进入阶段的行为与证据见phases/phase-NN.md。
