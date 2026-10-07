# Phase 2：总线与控制逻辑

## 步骤门控

| 步骤 | 状态 | 证据 |
| --- | --- | --- |
| A | 通过 | [检查结果](../../verification/phase-02/gate-A.json) |
| B | 通过 | [检查结果](../../verification/phase-02/gate-B.json) |
| C | 通过 | [检查结果](../../verification/phase-02/gate-C.json) |
| D | 通过 | [检查结果](../../verification/phase-02/gate-D.json) |

## 行为与依据

参考源码版本继承Phase 1。YM2608-LLE的prescaler_sel、reg_sch/reg_irq、busy、timer_a/b_status以及read0/read2状态锁存构成严格参考观察点。ymfm用于稳定寄存器读值和定时器功能交叉检查，其回调时间不替代LLE边沿。

共用Phase 1输入格式。新增mode观察：index 0为分频选择(2默认、0为2F、2为随后2D、3为随后2E)，index 1为SCH，index 2为IRQ使能掩码。timer观察index 0/1为Timer A/B溢出信号，仅用于验证周期。比较前只过滤与当前功能无关的音频输出，不改变保留记录的值或时刻。

所有用例的严格比较窗口从tick 3456开始，即首次IC释放后再稳定576主时钟；起点强制记录状态快照。未经过复位的上电状态不作为芯片契约。后续运行中复位仍完整比较，不重新移动窗口。

## 参考模型差异的裁决

SSG读回采用有效位掩码。应用手册第37页（PDF第36页）定义音调高位为4位，后续噪声/音量/包络分别为5/5/4位；LLE在写入时按这些位宽保存，读回给出对应有效位。固定ymfm的ymfm_ssg.h第119–120行直接存取完整8位，ymfm_ssg.cpp的read直接返回它，因此写FF后读回FF是该软件模型的已定位限制。ymfm这项检查固定预期为FF，仅验证模型限制；RTL的预期仍为LLE有效位，不对RTL放宽掩码。

参考：[Yamaha应用手册译本](https://csclub.uwaterloo.ca/~pbarfuss/YM2608J_Translated.PDF)、固定版本ymfm和LLE源码。Timer A/B的首次IRQ时刻也不同：ymfm使用回调调度，LLE包含内部相位和寄存器同步；稳定读值交叉核对，严格时刻采用LLE。

0x110的Timer A/B屏蔽同时作用于状态0和1，依据手册第51页及LLE计数器标志电路。ymfm的read_status未应用m_flag_control，故flag_control用例其低状态首读为1；RTL仍要求0。跨溢出保持RD的status_read_hold用例，LLE在状态读取期间保持标志锁存，ymfm的瞬时read调用无RD保持过程；该项ymfm预期为[1,1]，RTL严格预期为[0,1]。

默认分频下，Timer A周期为144×(1024−NA)主时钟，Timer B为2304×(256−NB)主时钟。依据是固定LLE的24槽位计数器和ymfm独立的OPERATORS(24)×DEFAULT_PRESCALE(6)定时调度，两者均给出相同周期。门控固定检查最大装载值的溢出间隔分别为288/4608半周期。译本第35页给出72/1152，与两个模型及默认1/6、24槽位推导不符；本轮YM2608B数字参考采用144/2304，不能把译本公式直接套作验收周期。该裁决是模型和计数结构交叉核对，不声称已对实物测量。

## 必需用例

| 用例 | 固定预期 | 依据 |
| --- | --- | --- |
| reset_status | 复位后低状态busy/TA/TB为0 | 手册复位语义、LLE/ymfm |
| ssg_masks | 音调高位0F、噪声1F、音量1F、包络形状0F等读回掩码 | SSG寄存器位宽 |
| busy_window | FM数据写后busy出现并释放，稳定后状态为0 | busy为32个内部合成时钟、LLE边沿 |
| timer_a | 最大装载值溢出，读TA=1；停止/清除后为0 | Timer A寄存器与27控制 |
| timer_b | 最大装载值溢出，读TB=1；停止/清除后为0 | Timer B寄存器与27控制 |
| irq_mask | 屏蔽IRQ不抹掉TA状态；重新使能后IRQ出现 | 29的IRQ使能语义 |
| prescaler | 仅写地址产生2→0→2→3→0→2的选择变化 | 2D/2E/2F地址副作用 |
| channel_mode | SCH复位0，写29切换0→1→0 | 29 bit7 |
| bank_isolation | 高端口的27/29不修改低端口控制 | 两端口寄存器布局 |
| reset_active | 活动定时器/忙状态在复位稳定后清除 | IC复位 |
| extended_status_id | 高状态复位0，芯片标识1 | 状态1、FF标识 |
| timer_a/b_minimum | 装载0的完整计数周期；A低位寄存器保留位不参与计数 | 10/8位定时器 |
| timer_enable_stop | load与enable独立；停止不清标志，reset清标志 | 27各位语义 |
| flag_control | 110屏蔽清状态，解除后重新置位；全局清除 | 手册第51页、LLE |
| status_read_hold | 持续状态读跨溢出时保持旧标志，释放后更新 | LLE状态锁存、ymfm接口限制 |
| timers_prescaler | 两个计数器运行中切换全部分频并清除 | LLE各内部相位 |
| bus_phase_sweep | 24种起始相位、SCH/SSG写入和跨bank数据隔离 | LLE总线同步 |

分频测试按主时钟周期比较逻辑比例，不作为高于芯片额定频率时的电气验证。ADPCM状态产生在Phase 5；本阶段不得将其假定为完整实现。

## 实现与证据

门控输出位于build/opna_sim/phase-02。每个用例生成LLE完整观察及控制投影，保留原时间用于RTL比较。进入B前必须先通过A及Phase 1累计回归。

控制入口为hardware/rtl/opna_core/ym2608.sv，时序控制位于ym2608_control.sv。系统时钟的half_ce有效上升沿执行一次chip_clk指定的芯片半周期，因而保留两个内部透明相位、总线写入同步、定时器装载同步及状态读锁存。IC通过芯片时钟传播；配置初始化不替代IC复位。

该控制部分按固定LLE控制电路转换为定宽SystemVerilog，保留GPL-2.0-or-later归属。波形运算仍采用JT12/JT49后续适配。ADPCM输入为已生成的EOS/BRDY/ZERO标志及数据读回，输出为状态掩码与清除控制；本阶段测试将这些输入保持为0，不代表ADPCM已实现。

独立testbench逐半周期采集读值、busy、IRQ、分频选择、SCH、IRQ掩码与定时器溢出，非复位稳定期之后出现X值直接失败。

flag_control固定将ADPCM掩码位维持为1，只检查本阶段的定时器标志。解除ADPCM掩码会使参考器件的BRDY参与IRQ，这属于Phase 5的状态产生验证，不能在本阶段将其误解为定时器IRQ未清除。

C累计重跑18个参考及RTL用例、Phase 1全套检查，并在bus_phase_sweep和timers_prescaler中每个芯片半周期插入3个half_ce=0的系统时钟，要求所有芯片时间观察仍逐位逐边沿一致。

证据：[阶段门控](../../verification/phase-02/gate-D.json)、[定时器边界](../../verification/phase-02/compare-timer_a_minimum.json)、[IRQ控制](../../verification/phase-02/compare-flag_control.json)、[暂停使能](../../verification/phase-02/compare-paused-timers_prescaler.json)。输出缺失时不得视为通过。

## 当前结论

控制RTL的验收结论以B/C/D实时门控为准。D通过只表示总线、寄存器控制、分频、定时器和已定义状态接口通过本阶段契约；FM/SSG波形、ADPCM标志产生和整芯片混音不属于本阶段通过声明。
