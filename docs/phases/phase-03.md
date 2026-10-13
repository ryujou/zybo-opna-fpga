# Phase 3：六通道FM

## 步骤门控

| 步骤 | 状态 | 证据 |
| --- | --- | --- |
| A | 通过 | [检查结果](../../build/opna_sim/phase-03/gate-A.json) |
| B | 通过 | [检查结果](../../build/opna_sim/phase-03/gate-B.json) |
| C | 通过 | [检查结果](../../build/opna_sim/phase-03/gate-C.json) |
| D | 通过 | [检查结果](../../build/opna_sim/phase-03/gate-D.json) |

## 行为与依据

JT12/JT10B的六通道24算子配置作为波形运算基础。输入保持Phase 1真实引脚格式，全部控制继续经过Phase 2模块。参考版本不变。寄存器布局依据应用手册和LLE/ymfm源代码；严格PCM预期来自LLE串行DAC还原，ymfm用于静音、活动及声道选择的功能交叉检查。

CSM采用27 bit7=1、bit6=0，即80模式；依据两个固定模型的译码一致性。手册译文表格的CSM/效果模式排列不作为位定义依据。特殊频率寄存器A8/AC、A9/AD、AA/AE按芯片实际算子映射验证。

普通频率A4～A6与特殊频率AC～AE各自共享一份独立高位锁存；写A0～A2或A8～AA时分别提交对应锁存。依据固定LLE的reg_a4/reg_ac和ymfm的`0xb8 | bitfield(index, 3)`两份暂存。`frequency_latch`覆盖A4=22、AC=3F、A0=69交错写入，普通频率仍应为2269。

所有PCM样本保留左右声道各自的有效tick、有符号16位数值；不搜索固定偏移，不丢弃首个非零样本，不重采样或调幅以匹配。参考生成器的SSG幅值与FM PCM分别记录，SSG波形验收属于Phase 4。

## 必需用例

固定清单位于tools/opna_sim/fm_cases.py。

| 用例 | 覆盖行为 |
| --- | --- |
| silence | 复位后的FM数字静音 |
| pan_left/right/stereo | 左、右及双声道开关 |
| algorithms_feedback | 八算法×八反馈等级，运行中切换 |
| algorithm_0～algorithm_7 | 每个算法在key-on前配置，隔离静态调制连接与动态写入时序 |
| six_channels_slots | 六通道，每通道四个独立slot key及组合key，最终同时工作 |
| key_operator_isolation | TL隔离每个算子，分别执行全部key和对应单算子key，防止求和掩盖相位差异 |
| frequency_detune_multiplier | block 0～7、FNUM 0/1/2047、DT 0～7、MUL 0～15 |
| frequency_latch | 多次只写频率高位、低位提交，以及普通A4与特殊AC高位锁存的交错写入 |
| envelope_boundaries | KS 0～3、AR/DR/SR 0/1/31、SL/RR 0/1/15、key-off |
| attack_rounding | AR24攻击取整，四算子同频发声 |
| sustain_level_change | DR31进入SUSTAIN后运行中修改SL，验证不返回DECAY |
| decay_granularity | DR22低速衰减步长，四算子同频发声 |
| ssg_eg_shapes | 全部八种启用的SSG-EG形状 |
| lfo_am_pm | 八LFO速率、四AM深度、八PM深度、算子AM开关、停用 |
| channel3_special | 特殊模式40/C0及正常模式，独立算子频率 |
| csm_timer_a | Timer A驱动CSM key，启动、停止及清状态 |
| dynamic_writes_keys | 24起始相位、连续key、算法/反馈/TL/FNUM修改 |
| three_six_channel_switch | 29的SCH切换及高通道key映射 |
| fm_reset_active | 发声中复位及再次编程 |
| fm_reset_phase_001/005/006/011/012/024/036/048/060/072/144 | 在fm_reset_active基础上仅推迟第二次IC断言1/5/6/11/12/24/36/48/60/72/144个半周期；释放和重编程时刻不变 |
| sch_high_channel | 仅第4通道发声后清SCH，隔离高通道的运行中行为 |
| sch_key_alias | SCH=0、仅配置CH1，CH4的key写入作用到CH1 |
| sch_enable_after_key | SCH=0时锁存CH4 key，置SCH后持续译码触发CH4 |
| sch_enable_after_other_key | 以CH2 key-off覆盖最后key锁存后，置SCH不触发CH4 |

## 实现与证据

A检查每个用例的两个参考均能运行，PCM在16位范围，规定声道有活动/静音，并输出固定LLE逐边沿PCM预期。B必须逐项通过RTL比较才算波形实现通过。C重跑Phase 1～2以及本阶段全部用例，并对six_channels_slots、lfo_am_pm、dynamic_writes_keys和fm_reset_phase_011插入每tick三个half_ce=0的系统周期；数字样本及芯片tick仍须完整一致。D核对清单、完整比较证据和文档。

输出：build/opna_sim/phase-03。门控结果：[gate-A.json](../../build/opna_sim/phase-03/gate-A.json)。

B接入JT12的FULLFM六通道路径。ENABLE_FM=0仅供此前控制阶段独立回归，正常核心默认启用FM。全分辨率算子输出进入[原生两相累加与串行输出](../../hardware/rtl/opna_core/ym2608_control.sv)，按S/SH1/SH2还原各声道的PCM值与有效时刻，包括运行中IC截断的串行字。该接入必须通过严格比较，不能以可展开或有声作为通过依据。

固定JT12源码保持原样，Phase 3编译选用hardware/rtl/opna_core/jt12_opna中同名适配模块，保留上游许可证。FM运算使能与扫描位置来自原生分频/FSM；JT12算子调度比FSM线性槽号超前7槽，使14位算子结果在原生累加器采入前可用。key路径按真实比较时相保存24份状态，依照当前SCH持续译码最后一次28写入；CSM进入同一EG流水线。普通与特殊频率高位锁存独立。

OP2调制使用当前OP1结果，算法5的OP3调制使用保存的OP1结果。B0连接与反馈分别使用原生扫描的前一锁存和当前锁存，载波与声道使能由原生FSM及B0/B4抽头产生。AR/DR/SR/SL/RR/KS/SSG参数的CSR提交经过下一轮24算子扫描；TL及AM enable使用独立的原生寄存器环，在算子衰减输出级加入TL与AM并饱和。

左右18位累加器在原生clk1更新、clk2提交，按fsm_sel11/23建立相隔12个算子周期的窗口。算子样本显式符号扩展后除以2；原生串行器保留累加高位裁剪、移位及锁存顺序，不按曲目调幅或平移输出。LFO分频器、相位、输出锁存与EG全局计时器沿用原生两相时刻；频率、特殊频率、DT/MUL和PM的寄存器扫描与两相运算按LLE实现，相位增量提前十二算子槽传给JT12相位累加级。JT12保留相位环、包络反馈与波形查表。IC不额外清除相位存储；相位由Key/包络事件清零，启动存储值为零。SSG-EG释放使用倒置后的实际电平，静音钳位按保持与释放状态处理。

控制状态在系统时钟边沿统一提交，避免多个引擎同一边沿读取到部分更新的控制相位。B比较包含PCM和此前已验证的控制观察，确保接入FM后不损坏busy/IRQ/定时器时序。

## SCH工程契约

**SCH-LLE-2026-10-07：按用户确认，采用LLE机制作为项目实现预期。** 六通道持续计算；SCH只参与key通道选择，不直接屏蔽输出；保留最后一次28写入，并随通道扫描和当前SCH译码。RTL仍基于JT12/JT10B。四个SCH定向用例纳入本阶段固定清单，完整PCM与控制记录逐tick比较，不能只凭是否有声使B通过。

最小输入先写29=9F，单独配置第4通道、写28=F4，持续发声后只写29=1F，之后不改key。两个参考在切换后稳定4096半周期之后的输出不同：LLE仍有非零PCM，ymfm全为0。这是活动/静音的功能差异，不是采样率或数值精度差异。

- 可重放输入：[sch_high_channel.bus](../../build/opna_sim/phase-03/sch_high_channel.bus)。
- 四组契约断言：[sch-contract.json](../../build/opna_sim/phase-03/sch-contract.json)。
- 固定LLE的fmopna_impl.c第943行把reg_sch用于key通道的高位选择；该信号没有连接到FM输出屏蔽。
- 固定ymfm的ymfm_opn.cpp第1392行选择3F/07输出掩码，第1406行将它应用于FM混音。
- [原始手册](https://nemesis.hacking-cult.org/MegaDrive/Documentation/YM2608J.PDF)第18～19页定义SCH的三/六通道及key分配限制，但没有明确给出已发声高通道在清SCH瞬间的状态转移。尚无该具体序列的实片证据。

门控依据为已确认的工程契约及下列源码与重放证据。A必须检查LLE和ymfm各自已知的活动窗口，不要求它们在已定位的SCH差异上输出相同；出现契约以外的差异仍失败。B对全部43个用例保持LLE原生样本与时刻的严格比较。SCH缺乏独立实片验证的限制必须延续到Phase 6结论，不将本项工程选择表述为原片行为已获证实。

### SCH公开证据与裁决

截至2026-10-07，现有公开资料不足以独立证实本用例的实片行为。项目没有可用的YM2608B原片或PC-98声卡；该限制与已经确认的项目实现预期分别记录。

| 资料 | 可支持的结论 | 对当前分歧的限制 |
| --- | --- | --- |
| [Yamaha原始应用手册](https://nemesis.hacking-cult.org/MegaDrive/Documentation/YM2608J.PDF)，印刷页18～19 | SCH=0时不能给CH4～6分配key；六通道使用前应置SCH=1 | 未明确规定先key-on、再清SCH时是否屏蔽已有输出。仅据“三通道模式”推断立即静音不充分 |
| [YM2608-LLE说明](https://github.com/nukeykt/YM2608-LLE/blob/7a2aca7b6830b96e48e3a4e1a40d15525993fa60/README.md)及[reg_sch路径](https://github.com/nukeykt/YM2608-LLE/blob/7a2aca7b6830b96e48e3a4e1a40d15525993fa60/fmopna_impl.c#L943) | 作者说明模型源于开盖芯片照片；当前代码只在key通道选择处使用SCH | 该仓库未提供可独立核对这条连线的YM2608B标注电路图或本用例实测记录；模型的来源说明不能替代对具体分歧的核验 |
| [hyano/opna-analyze实片分析范围](https://github.com/hyano/opna-analyze/blob/main/undocumented_spec/01_overview.md)及[实测笔记](https://github.com/hyano/opna-analyze/blob/main/doc/OPNA.md) | 有ADPCM-B、外部内存和状态标志的实片观察；作者向[ymfm提交过实测相关修正](https://github.com/aaronsgiles/ymfm/pull/38) | 所核对资料的范围不含FM的SCH运行中切换，不能用ADPCM验证替FM作裁决 |
| [OPN2BankEditor讨论](https://github.com/Wohlstand/OPN2BankEditor/discussions/116)，2018-11-16的SCH说明 | 为模拟器设置29 bit7后，六通道可以发声 | 说明的是初始化与开启，并非YM2608B已发声后关闭SCH的实测 |
| [openMSX Makoto实现说明](https://github.com/maxiwamoto/openMSX/blob/e34f671e61dbf7c2462b4432310315658ed4ae56/doc/internal/makoto.md)及[PR 2209](https://github.com/openMSX/openMSX/pull/2209) | 有基于实体Makoto的ADPCM传送验证，FM复用ymfm | 未提供本次SCH序列的独立验证，复用同一软件引擎不能构成第二份芯片证据 |

上述证据支持LLE工程契约的选择，但不支持宣布任一模型已被实片证实。后续独立核验必须区分key译码、已有高通道输出和最后key锁存，不能只证明复位后默认三通道。

### 复现与观测

`sch_high_channel`以8 MHz时钟、正常寄存器和真实总线写入执行；只让CH4工作，不启用CSM或测试模式。地址写与数据写不合并：tick 44864写地址29，tick 44928写数据1F，tick 44960释放WR。统计窗口从tick > 48960开始，用于确认稳定的活动/静音差异；完整输出仍保留全部样本和时刻，严格RTL比较不裁掉该窗口前的数据。

| 模型 | 窗口内样本数（左右合计） | 非零样本数 | 最小值 | 最大值 |
| --- | --- | --- | --- | --- |
| LLE | 170 | 170 | -16336 | 800 |
| ymfm | 3062 | 0 | 0 | 0 |

两模型原生输出频率不同，所以此项只比较是否持续发声；数字样本和有效时刻的严格比较仍使用LLE原生输出。固定源码、复现输入和JSON证据共同限定结论，不能外推为全部FM行为已经验证。

在工程根目录执行以下命令会先重跑Phase 1～2累计回归，再生成本阶段43个用例的参考结果。四个SCH用例按固定工程契约检查，任一参考偏离规定窗口则返回非零：

```powershell
.\scripts\run_opna_gate.ps1 -Phase 3 -Step A
```

### 成熟软件音源与PC-98模拟器对照

固定源码版本和文件清单见[sources.json](../../build/opna_sim/phase-03/software-review/sources.json)。下表区分源码检查与实际重放；没有运行完整PC-98模拟器。SCH均指寄存器29的bit7，通道编号为CH1～CH6。

| 实现 | SCH=0时的逻辑 | 证据方式及范围 |
| --- | --- | --- |
| [libvgm旧MAME核心](https://github.com/ValleyBell/libvgm/blob/c8b998b606895990c409a512b86c5509070f9f0d/emu/cores/fmopn.c#L2993) | 29控制TYPE_6CH；28的通道高位仅在六通道模式下有效，因此CH4～6的key写入映射到CH1～3。六通道始终参加计算和混音，清SCH不立即静音 | 源码检查及四组重放。key译码1758～1766行，六通道计算/包络/混音3038～3146行 |
| [libOPNMIDI的MAME OPNA后端](https://github.com/Wohlstand/libOPNMIDI/blob/8e228213756f741533ef3f5d80cb7ec778479749/src/chips/mamefm/fm.cpp#L2754) | 同样用TYPE_6CH限制key通道高位，不按SCH屏蔽高通道混音；封装初始化写29=9F | 源码检查。与libvgm属于旧MAME实现家族，不能作为第二个独立参考；结论仅适用于此后端 |
| [NP2kai的可选FMGEN后端](https://github.com/AZO234/NP2kai/blob/5939e0c6d5985c4c08fc70f289a83290e5d3e6f7/sound/fmgen/fmgen_opna.cpp#L1282) | key仍可写入CH4～6；FMMix不把高三通道放入active集合，跳过这些通道的Calc/CalcL调用 | 源码检查。高三通道没有输出，其逐样本运算也暂停，不等同于仅在末端混音屏蔽 |
| [PMDWinS036的FMGEN实现](https://github.com/pbarfuss/PMDWinS036/blob/fadd5a0e8482e277adbc9645411c97f8b8759b76/fmgen/opna.c#L1192) | key不受SCH限制；FMMix按SCH选择高三通道是否参与计算 | 源码检查及四组重放。清SCH后静音，SCH=0期间写入的CH4 key在开启SCH后可发声 |
| [ymfm](https://github.com/aaronsgiles/ymfm/blob/81aec25ccbb98f4873a255f7551ac4dadac59b4a/src/ymfm_opn.cpp#L1392) | 六通道继续clock，FM output使用07掩码屏蔽高三通道；key通道选择不受SCH限制 | 固定参考及四组重放。[当前MAME的YM2608封装](https://github.com/mamedev/mame/blob/master/src/devices/sound/ymopn.h)复用ymfm，不能算独立交叉依据 |
| [NP2kai原生OPNGen路径](https://github.com/AZO234/NP2kai/blob/5939e0c6d5985c4c08fc70f289a83290e5d3e6f7/sound/opna.c#L430)及[DOSBox-X的PC-98路径](https://github.com/joncampbell123/dosbox-x/blob/478c860050b20afdb58bce28f1b43163952fc541/src/hardware/snd_pc98/cbus/board86.c#L20) | 所检查路径没有将29的SCH接入FM通道计算控制；播放通道数由声卡扩展功能选择 | 源码检查。NP2kai原生路径与可选FMGEN路径不同；PC-98声卡扩展开关也不同于芯片SCH，不能混为一个控制 |
| [98fmplayer/libopna](https://github.com/myon98/98fmplayer/blob/4fa914e4b2b994cb3ccf92d571a20a7cdf1fe36a/libopna/opnafm.c#L490) | FM写寄存器函数未处理29；key、包络、相位及混音按六通道执行 | 源码检查及四组重放。SCH=0也可让CH4发声；它的通道mute API不等于SCH |

libopna的[v0.1.8说明](https://github.com/myon98/98fmplayer/releases/tag/v0.1.8)声称在限定条件下与实片输出逐位一致，并说明包络仅AR≥21的条件已达到该目标。这使它适合辅助核对部分FM波形，但不能外推为SCH、全部包络或总线时序的完整参考。旧MAME源码中的实片测试记录涉及LFO、寄存器寻址、节奏音等；未找到对应本次SCH状态转移的实测记录。

#### 五个核心的同序列重放

[重放脚本](../../tools/opna_sim/sch_review.py)构建libvgm、PMDWinS036、libopna三个未修改的上游核心，并调用固定LLE与ymfm参考。四个输入共20组重放均已生成观察结果，完整输入、输出CSV和构建日志位于build/opna_sim/phase-03/software-review；统计见[results.json](../../build/opna_sim/phase-03/software-review/results.json)。

| 探针 | 输入与观察目标 |
| --- | --- |
| running_clear | SCH=1，只配置CH4并写28=F4；运行后清SCH，观察是否继续发声。与正式sch_high_channel用例相同 |
| key_alias | SCH=0，只配置CH1，然后写28=F4，观察高通道key是否实际触发CH1 |
| enable_after_key | SCH=0，只配置CH4并写28=F4；运行后置SCH=1，不再写28，分别观察切换前后 |
| enable_after_other_key | 同上一项，但在F4之后先写28=01（CH2 key-off），再置SCH=1；区分最后一次key写入锁存与每通道key状态 |

下表“有声”只表示规定窗口内存在非零FM输出；箭头表示SCH切换前→后。

| 实际运行核心 | running_clear | key_alias | enable_after_key | enable_after_other_key |
| --- | --- | --- | --- | --- |
| LLE | 有声→有声 | 有声 | 静音→有声 | 静音→静音 |
| libvgm旧MAME | 有声→有声 | 有声 | 静音→静音 | 静音→静音 |
| PMDWinS036 | 有声→静音 | 静音 | 静音→有声 | 静音→有声 |
| ymfm | 有声→静音 | 静音 | 静音→有声 | 静音→有声 |
| libopna | 有声→有声 | 静音 | 有声→有声 | 有声→有声 |

LLE的[594～600行](https://github.com/nukeykt/YM2608-LLE/blob/7a2aca7b6830b96e48e3a4e1a40d15525993fa60/fmopna_impl.c#L594)锁存最后一次28写入的通道与四个key位；[659～679行](https://github.com/nukeykt/YM2608-LLE/blob/7a2aca7b6830b96e48e3a4e1a40d15525993fa60/fmopna_impl.c#L659)配合SCH参与的reg_kon_match持续更新对应通道。因此，最后写入为F4时，开启SCH会把持续译码的目标改到CH4；若最后写入已经换成01，则不会触发CH4。旧MAME只在CPU写28时执行key操作，没有这项持续译码。这解释了两者在前两项一致、第三项不同的源码原因；该解释属于模型行为分析，尚非实片验证。

重放保留各核心原始数值，不调增益、不平移波形。三个软件API核心每144个主时钟生成一次FM帧，其寄存器API不表达引脚边沿；libvgm和PMD采样率参数为整数8000000/144，PMD输出为单声道，其他核心为双声道，ymfm使用原参考的MAX精度。这里只比较持续活动/静音，不将采样数量、幅度、相位或有效tick视为一致性结果，不将这些探针替代严格RTL比较。

已完成Phase 1参考构建后，在工程根目录执行：

```powershell
py -3 -X utf8 tools/opna_sim/sch_review.py
```

该命令下载固定版本、构建并记录观察；返回0仅表示重放完成，不代表模型一致或Phase 3 A通过。正式四个参考版本保持不变。现有软件证据支持“不立即静音”并非LLE独有行为，同时明确暴露了key锁存分歧；工程契约采用完整LLE机制，实片验证限制仍保留。

## B验证结果

全部43个正式FM用例通过完整PCM与控制记录比较。Phase 1（21项）、Phase 2（42项）及Phase 3 A（92项）累计回归通过；B共136项检查通过，[完整结果](../../build/opna_sim/phase-03/gate-B.json)。原有32项、八个静态算法及三个包络探针全部通过。

代表性证据：[algorithms_feedback](../../build/opna_sim/phase-03/compare-algorithms_feedback.json)（4221条）、[frequency_detune_multiplier](../../build/opna_sim/phase-03/compare-frequency_detune_multiplier.json)（3617条）、[envelope_boundaries](../../build/opna_sim/phase-03/compare-envelope_boundaries.json)（8142条）、[ssg_eg_shapes](../../build/opna_sim/phase-03/compare-ssg_eg_shapes.json)（3508条）、[lfo_am_pm](../../build/opna_sim/phase-03/compare-lfo_am_pm.json)（6497条）、[dynamic_writes_keys](../../build/opna_sim/phase-03/compare-dynamic_writes_keys.json)（1437条）。所有附加复位相位完整一致，观察数包含控制记录。

C检查时钟暂停及累计回归，D核对全部必需项的比较结果、观察数量、仿真结束标记和阶段文档。执行以下命令会按A→B→C→D顺序重新运行，失败立即停留在相应步骤：

```powershell
.\scripts\run_opna_gate.ps1 -Phase 3 -Step D
```

## 当前结论

Phase 3 A～D全部通过。43个FM正式用例完整一致，四个时钟暂停回归通过，D共141项检查通过：[gate-D.json](../../build/opna_sim/phase-03/gate-D.json)。本阶段没有未通过必需项，下一项允许工作为Phase 4 A。完整YM2608数字逻辑验收仍属于Phase 6，XC7Z010资源与板测属于Phase 7。当前证据限定于正式FM用例及已确认的SCH工程契约，未完成独立实片核验。
