# 开发者手册

面向修改固件的人。用户侧用法见 [USER.md](USER.md)。

目录：[架构与不变式](#架构与不变式) · [标定](#标定) ·
[endpoint 协议](#endpoint-协议) ·
[params.json 与代码生成](#paramsjson-与代码生成) · [配置持久化](#配置持久化) ·
[Flash 布局与 OTA 契约](#flash-布局与-ota-契约) · [CAN：协议选择与 CYBERBEAST](#can协议选择与-cyberbeast) ·
[测试](#测试) · [发布检查表](#发布检查表) · [接口变更规则](#接口变更规则)

## 架构与不变式

N32H473CE，Cortex-M4F，裸机。控制环 **40 kHz**（`DT = 25 µs`），由
`ATIM1_UP_IRQHandler`（优先级 0）驱动；ATIM1 的 update 同时硬件触发三路注入
ADC，采样点在 PWM 峰值、低侧采样窗口内。

```
上位机 ──USB CDC──────> endpoint_serial.c  中断累积 0xAA 帧，主循环解析/应答 ┐
上位机 ──vendor i/f───> endpoint_usb.c     中断只搬 64 B 包，主循环解析/应答 ┤
                              └─ endpoint_process() → endpoint_handler(id, op, in, out)
                                    [endpoint_defs.c 生成，直接读写 params.json 的 C 变量]
主循环 ──> run_fsm_slow() ──> save_preferences() ──> prefs_codec (TLV+CRC32)
                                                     └─ 0x0807C000 / 0x0807E000 ping-pong
控制 ISR ──> analog_sample → ps_sample(+PLL) → check_faults → run_fsm(motion_control) → can_tx_rx
```

| 文件 | 职责 | 可在 ISR 里跑 |
|---|---|---|
| `n32h47x_48x_it.c` | 控制 ISR 调度、`fault_shutdown()` | 是 |
| `foc.c` | 电流环/`torque_control`/`check_faults` | 是 |
| `motion.c` | 控制律分发 + 分频的速度环/位置环（CSP/CSV） | 是 |
| `motion_law.h` | 外环纯数学（PI/斜率/故障/PLL，可主机测试） | 是（纯计算） |
| `position_sensor.c` | SPI1+DMA2 读编码器、速度 PLL | 是（唯一允许阻塞等 DMA） |
| `fsm.c` | 状态机：`run_fsm`（ISR）/`run_fsm_slow`（主循环） | 分开 |
| `endpoint.c` | CRC、LE 编解码、endpoint 0 描述符、请求分发 `endpoint_process()` | 是（纯计算） |
| `endpoint_serial.c` | CDC 帧收发（0xAA/CRC 外层） | `feed()` 是，`poll()` 否 |
| `endpoint_usb.c` | vendor interface 收发（一个 USB 包 = 一帧，USB 流控） | `*_isr()` 是，`poll()` 否 |
| `endpoint_defs.c` | 生成的 handler | 是（只读写变量/置标志） |
| `prefs_codec.c` | TLV 编解码（纯逻辑，可主机测试） | 否 |
| `preference_writer.c` | 擦/写/校验 flash | 否 |
| `main.c` | 初始化、主循环、`myprintf`/`console_write_raw` | 否 |

必须保持：

- **ISR 不 printf、不写 flash、不阻塞**（唯一例外：`ps_sample` 的编码器 SPI+DMA）。
- **handler 只读写变量/置标志**：它将来会在 CAN 中断上下文里被调用。
- **动作端点（`type: void`，线上 `"type":"function"`）读和写都会触发**，与 ODrive
  一致（它的 endpoint 协议没有读写位，function 端点被“读”也会执行）。⚠ `require`
  只是状态前置条件，不是读写判别：`action.idle_mode` / `action.clear_fault` /
  `action.reboot` / `action.reset_timing` 连 `require` 都没有，一次读就会停机/复位，
  所以遍历参数的上位机必须跳过 `function` 类型。标量端点仍必须由传输层显式给出
  读/写意图，不能从 "payload 为空"推断。
- **`save_preferences()` 只在主循环、门极关闭时调用**；它内部关中断覆盖整个
  擦写序列（N32 的 64-bit 编程在两次写之间被中断会死锁）。
- **IWDG 由控制 ISR kick**；不要制造 > 4 s 的停顿。
- **配置页只由 `preference_writer.c` 访问**。
- **参数表只改 `params.json`**，不手改 `endpoint_defs.*` / `prefs_defs.*`。

加一个参数：`params.json` 加条目（要持久化再加 `persist: true` + `default`）→
`make endpoints` → `make check` → `make` → `make hosttest`。

## 标定

`CALIBRATION_MODE` 的 ISR 链路是 `order_phases()` → `calibrate_encoder()` →
`measure_lr()`（`Core/Src/calibration.c`），全程在 40 kHz 控制中断里跑，所以
**不能 printf**；阶段进度用 `cal_msg_push()` 交给主循环的 `cal_print_flush()`。
`run_fsm_slow()` 只在 `done_ordering && done_cal && done_rl` 都置位后退出到菜单
并保存。

`order_phases()` 用"电压矢量转 `CAL_ORDER_CYCLES`（3）个电周期 ÷ 机械行程"求极对数。
行程**不在斜坡两端取**，而是在匀速段取两个采样点（斜坡的 20% 与 90%）相减、再按
0.7 外推：转子同步旋转时负载角恒定，在差分里抵消。前两版的做法与失败原因：

| 做法 | 结果 |
|---|---|
| 斜坡结束瞬间取角度 | 读到"动态负载角"偏短；14 极对理想行程 0.449 rad，滞后 0.95° 机械就舍入成 15 |
| 保持末相位 0.75 s 后比较两个**静止**点（各平均 0.1 s） | 静摩擦让转子停在离平衡点 `T_fric/k_spring` 处（本机 0.075 N·m / 1.82 N·m/rad ≈ ±0.04 rad，占单周期 0.571 rad 的 7%），11 极对随机算成 **12**，`e_zero` 与 LUT 随之全错，现象是"标定完电机不出力矩" |

⇒ 最终方案：`CAL_ORDER_CYCLES`=3 个电周期 + 匀速段两点采样；`CAL_ORDER_HOLD_S`
只用于让转子在 `calibrate_encoder()` 之前停稳，不再参与测量。改这里必须连跑几轮
标定确认极对数稳定、LUT 幅值回到 ±100 counts 量级（错极对数时 LUT 会变成 ±2800 的锯齿）。

`measure_lr()` 是 ODrive `Motor::measure_phase_resistance` /
`measure_phase_inductance` / `measure_ld_lq` / `measure_flux_linkage` 及其
控制律的 C 移植：

| 阶段 | 方法 | 时长 |
|---|---|---|
| R | alpha 轴积分电流源，两步 `I_CAL/2` → `I_CAL`；用**实测的**两步电流和电压做 `R = (V2-V1)/(I2-I1)`，死区项相消 | 2 × 1.5 s |
| L | alpha 轴每拍翻转 ±2 V，累加带符号的 ΔIα 并取幅值 | 1.25 s |
| Ld / Lq | 先在 alpha/beta 上锁住转子，再翻转电压测该轴电感 | 2 × 1.25 s |
| 磁链 | 开环升速到 60 rad/s（电角度），稳态采样 `Vq/Id/Iq`：`λ = (Vq - R·Iq - ω·Ld·Id)/ω`，再 `Kt = 1.5·pole_pairs·λ` | 4.5 s |

- **两类电压上限要分开**：`CAL_V_MAX`（2 V）是电感测量的翻转幅值，决定电流纹波；
  `CAL_LOCK_V_MAX`（12 V）只是 R 积分器和 Ld/Lq 锁转子的直流钳位。用小钳位会让
  高阻电机（1 Ω 级：4 A × 1 Ω ≈ 4 V 物理电压）永远到不了测试电流 —— 台架上
  4.00 A 时 R 阶段在 2 V 饱和就是这么发生的。
- R 用**实测电流**而不是目标电流，所以高阻电机第二步即使被 12 V 钳位、或积分器
  还没完全稳定，只要两步电流差足够大（≥ 0.2·I_low）结果仍然成立；两步电流差
  太小（开路、母线过低）才失败。`CAL_KI_R`/`CAL_KI_LOCK` 用 4.0 而不是 ODrive 的
  1.0：ODrive 的 1.0 对 50 mΩ 电机没问题，但对 1 Ω 电机 1.5 s 只能稳定到约
  84 %（R 会低 17 %）。
- **电感公式用幅值**：PWM 比较值是预装载的，ISR 里 ADC 采到的电流对应两个控制
  周期前写入的占空比，比本周期 `test_voltage` 的翻转晚一拍，所以台架上用有符号
  累加会得到负 delta。`cal_ripple_inductance()` 用 `|delta_i|`（`L = V·dt/|ΔI|`），
  不要"修正"回有符号形式，也不要在分子里加 R·I 项（采样点在纹波拐点，Ld/Lq 锁
  转子的直流压降已被 lock 电压抵消，剩余阻尼是二阶小量）。
- 串口会在两步之间打印 `R step 1: <V> @ <A>`，失败信息带阶段名、失败值和辅助值
  （R 阶段是两步电流差），便于判断是"电流没到"还是"接线/母线问题"。
- 测试电流 = `min(config.i_cal, config.i_max)`（`i_cal` 和编码器标定共用；
  这几段要持续通直流，不能超过板级限流）。过流硬件/软件保护照常在
  `check_faults()` 里生效。
- 结果直接写 `R_PHASE` / `L_D` / `L_Q` / `KT`（都持久化，ID 17/133/134/15）。
  `L_D`/`L_Q` 从 `hw_config.h` 的固定宏改成了 `user_config.h` 的 `__float_reg[11]/[12]`。
  `controller.flux_linkage` 在 `init_controller_params()` 里按 `KT/(1.5·PPAIRS)`
  重算，所以重启后 `telemetry.flux_linkage` 仍能反映标定值；
  `telemetry.ld_lq_diff = L_D - L_Q` 是只读计算值。
- **电压单位换算**：控制环里的 dq 电压并不是物理伏特。`svm()` 把
  `(u - v_offset)` 变成 `0.5/v_scale` 的占空比偏移，而
  `v_scale = v_bus·(DTC_MAX-DTC_MIN)·√(1/3)`，所以实际相电压 = `CAL_V_PER_CMD ×
  指令电压`，`CAL_V_PER_CMD = V_PER_CMD = 0.5/((DTC_MAX-DTC_MIN)·√(1/3))`（当前 DTC 0…0.7
  时约 1.237；定义在 `hw_config.h`，母线功率估算也用它）。`measure_lr()` 在计算 R/L/λ
  前把电压项乘上这个因子，落盘的都是
  SI 值；**改 `svm()`、`DTC_MAX/DTC_MIN` 或 `OVERMODULATION` 时必须一起改它**，
  否则 R/L/Kt 会按比例失准。台架上可用万用表量相电阻做一次核对。
- 任何一段失败（电流差太小、母线/过调制限制、`Iβ` 不平衡、λ 超范围）都会置
  `comm_encoder_cal.failed`，回到菜单并且**不写 flash**；已有参数保持不变。
- 标定顺序有依赖：Ld/Lq 用同一测试电流把转子锁在 alpha/beta 上，磁链公式要用
  刚测出的 R 和 L_D（以及极对数算 Kt）。因此 `measure_lr()` 必须排在
  `order_phases()` 之后；失败会中止整轮标定。

### `config.pre_calibrated`（进电机模式的前置条件）

- `run_fsm_slow()` 在 `done_ordering && done_cal && done_rl` 全部完成后先置
  `PRE_CALIBRATED = 1` 再存盘，三段的产物（相序、`e_zero`+LUT、R/L/Kt）一起落盘。
- **进入 `CALIBRATION_MODE` 时立刻清 0**：中途失败会回菜单，此时"已标定"不再成立。
  `action.reset_config` 走 `config_apply_defaults()`，也会清 0。
- 门禁有三层，缺一不可：`action.motor_mode` / `action.measure_inertia` /
  `action.tune_gains` 的 `require` 直接返回 `EP_ERR_STATE`；`cb_start_motor()`
  （CYBERBEAST `0x61`）直接忽略；`run_fsm()` 里对所有入口（含 ASCII 菜单）兜底，
  拒绝后把 `next_state` 改回当前状态，并置 `state.motor_refused` 由主循环打印一次。
- 只能在门极关闭时写（`require: "!controller.gate_drive_enabled"`），避免运行中把
  自己和自己的标定数据"注销"。

## 齿轮式双编（断电记忆输出轴位置）

单圈绝对编码器只知道"转到单圈内的哪个角度"，转了第几圈只能靠 flash 记。齿轮式双编
在转子齿轮旁再啮合一个齿数不同的齿轮、装第二颗绝对编码器，**两路单圈读数合起来就能
解出转子在第几圈** —— 于是断电再上电，输出轴位置（`telemetry.position`）直接
接上，不需要"回零"动作。

- 数学在 [`Core/Inc/dual_gear.h`](../Core/Inc/dual_gear.h)（纯函数、不含固件头文件），
  硬件侧在 [`Core/Src/position_sensor.c`](../Core/Src/position_sensor.c) 的
  `ps_sec_read()` / `ps_dual_gear_*()`。host 回归：`tools/test_dual_gear.c`
  （`make hosttest`），覆盖 k = ±1、k = 3、读数反向（镜像）、±2 count 噪声、窗口边缘。
- **原理**：设转子（相对某参考）转过的圈数为 θ，两路单圈归一化读数
  `f = frac(θ + φf)`、`s = frac(θ·T1/T2 + φs)`，则韦尼尔相位
  `Δ = (s − f) mod 1 = frac(k·θ/T2 + const)`，`k = T1 − T2`。Δ 每转子一圈只变化
  `|k|/T2`，所以**两次读数的 Δ 之差**给出转过的整圈数；单圈内的小数部分仍然用
  主编码器自己的计数（那一路是精确的，韦尼尔只负责"第几圈"，两者的误差量级差
  三个数量级）。
- **读数方向**：如果副编码器读数随正转变小（磁铁反装，或外啮合让副轴反转），
  Δ 对 θ 的斜率会变成 `−(T1+T2)/T2`（每转一圈相位跑两圈多），无歧义窗口缩到
  ±T2/(2(T1+T2))（34/33 只有 ±0.25 圈，等于没用）。此时要置
  `config.gear_sec_reversed = true`：固件先做 `SEC_ENC_CPR − raw` 镜像
  （ODrive `abs_spi_sec_enc_cb()` 里的同一件事），镜向后斜率回到 `+T1/T2`，
  窗口恢复 ±T2/2 —— 这比"把方向解释成 k = T1+T2"正确得多。
- **量程/约束**：无歧义窗口是 **±T2/(2|T1−T2|) 转子圈**（相位斜率 `k/T2` 的倒数
  的一半），断电期间转子移动超过它就差整整一个相位周期 `T2/|T1−T2|`。所以齿数要
  接近但不等：34/33 给 ±16.5 圈，本机（MZW55，30/27）只给 ±4.5 圈。
  `gcd(|k|, T2)` 是否等于 1 **不影响**本模块的"最近候选"解码（那是 ODrive 查表法
  才需要的），齿数成比例（10/9 = 20/18 = 30/27）行为完全相同 —— 现场直接填真实的
  物理齿数即可。
  **这个窗口就是断电记忆的量程**：本机 GR = 9，±4.5 转子圈 = **±0.5 输出圈**（±π）。
  超过就会差整整一个相位周期（30/27 时是 9 转子圈 = 1 输出圈），和 ODrive 分支里
  "停机点 |R − Z0| < GR/2"的机械假设是同一件事，不是 bug（台架实测：把轴挪到
  +7.4 转子圈再重启，正好差 −9.0004 圈）。
- **标定不需要转电机**（ODrive 59e2ad0dc 的做法）：Δ 的绝对值里含一个与安装位置
  有关的常数，单次读数解不出绝对圈数，所以把"当前这一刻"整体定义成参考：
  `config.gear_zero_phase` = 当时的 Δ，`config.gear_zero_count` =
  `turns·ENC_CPR + count_wrapped`，`config.gear_ref_valid = 1`。上电时算的是
  **相对参考的圈数差**，常数项自动消掉。
  - **标定开始时就探测副编码器**（`run_fsm_slow()` 的 `CALIBRATION_MODE` 分支，
    只做一次）：`ps_sec_probe()` 连读两帧，两帧都有效才算在线，然后打印
    "GEAR: second encoder found (raw …, teeth …)" 或 "no second encoder …" ——
    用户在校准跑起来的头一刻就知道位置记忆这次会不会生效。探测会挡住控制中断
    （在线约 4 µs；没插时两帧各等到上限，最坏约 2×16 µs），发生在标定最开头的
    开环慢速段，最多推迟一个控制周期，无影响（菜单 'c' 走的是 USART 中断，
    不在这里读 SPI，探测统一放在主循环）。
  - **标定收尾顺带 capture**（`run_fsm_slow()` 的标定收尾块，转子静止、门极已关），
    结果和标定数据一起存盘。capture 失败时**保留旧参考**（参考是相位+计数成对的，
    只要主编码器多圈计数没断，旧参考就一直有效），并打印原因。
  - 想单独重取就调 `action.gear_capture` + `action.save`；更换齿轮/编码器安装位置后
    必须重新 capture，否则参考不再对应。
  - **台架实测（2026-11-05，CBL89 + Keil 镜像）**：本机（MZW55）副编码器实测传动比
    `r = d(s)/d(θ) = -1.1111`（副轴反向），即 **T1/T2 = 30/27 且 `gear_sec_reversed = true`**
    （30/27 与 10/9 同比值，现场按真实齿数填）；GR = 9，量程 ±4.5 转子圈 = ±0.5 输出圈。
    13 个位置（转子 −4.30…+4.30 圈）上解码与固件多圈之差 ≤ 0.0002 圈（≈10 count，
    就是编码器抖动），相对第一点的累计偏差 ≤ 0.00027 圈；5 个位置的断电重启偏差
    ≤ 0.0006 圈。验收判据照这个来：**差值必须是"几十分之一 count 级"的抖动，任何
    整圈级偏差都是齿数/方向配错或超出窗口**。
  - ✅ **GR 修正后增益已重算（2026-11-06）**：上面提到的 `vel_gain 2.469` / `pos_gain 15`
    是在 GR = 7.75 的配置下整定的，而实际 GR = 9 —— 同一条 MIT 律里
    `i_q = torque_des/(KT·GR)`，所以同样的增益会少 7.75/9 ≈ 14% 的电流、环路变软。
    现在已按 GR = 9 重测惯量、重算增益（见"单位"一节的增益记录与"`tune_margin`"一节），
    以后再改 GR 仍要走同一条路：`action.measure_inertia` → `action.tune_gains`。
- **上电恢复**（`ps_dual_gear_restore()`，`main()` 里、`TIM_ConfigInt(...ENABLE)`
  之前调用）：读副编码器 → 按参考解出整圈数 → 置 `abs_turns_valid`，由**下一帧**
  `ps_finish_sample()` 覆盖 `turns` 并填满速度历史（直接在主循环里改 `turns` 会被
  第一帧的 `first_sample` 逻辑清零，还会留下一个假速度尖峰）。`gear_ref_valid = 0`
  （默认、恢复默认值、没做过 capture 的板子）时这一步什么都不做，行为与改动前一致
  —— 出厂默认 `gear_ref_valid = false`，必须跑一次标定或 `action.gear_capture` 才启用。
- **副编码器的 SPI**：与主编码器同一颗 KTH7823、同一个 SPI1 + DMA2，只有 NSS
  （`SEC_ENC_SPI_NSS` = PD1）独立。它**不进 40 kHz 中断**（上电 / 标定入口 / 标定收尾 /
  诊断各一次就够），读的时候 `NVIC_DisableIRQ(PWM_ISR)` 挡住控制中断（只关 ATIM1，
  USB/串口照常），一帧 2.13 µs + `PS_WAIT_ITERS` 有界等待，读不到只累加
  `telemetry.sec_enc_lost_frames`，不会卡死启动。`0x0000`/`0xFFFF` 视为"没有芯片
  应答"，`ps_sec_probe()` 连读两帧才判在线，结果在 `telemetry.sec_enc_present`。
- **和机械零点的耦合**：`count_wrapped = (count − M_ZERO) mod CPR` 既定义了主编码器
  单圈零点，也是参考里 `count_wrapped` 的坐标系。所以改 `M_ZERO` 必须走
  `ps_set_m_zero()`（`action.zero` 与 `config.m_zero` 的写入口都走它）：
  - 它把 `turns`、`count_wrapped` 一起换成新坐标（当前位姿 = `(count − v) mod CPR`），
    所以 `action.zero` 之后 `telemetry.position` **读到 0**。只改 `M_ZERO` 不清 `turns`
    会让读数留在整圈上（台架旧行为：+1.43 转处清零读到 +1.00 转），用户没法分辨是
    "清零没生效"还是"位置本来就那样"。
  - `old_angle` 同步成新角度，否则下一帧的 rollover 检测会把这次跳变当成转子转了
    一整圈（又差一圈）。整段关控制中断，`count_buff` + PLL 重新播种（速度不从跳变里算）。
  - 参考按"新坐标位置 − 旧坐标位置"平移（纯算术，全程不碰 SPI）。
  - ⚠ **不要在这里顺手重取双编参考**（`ps_dual_gear_capture()`）：参考是"相位 + 多圈
    计数"成对的东西，清零这一刻转子未必静止（滑行、回差都可能），在这种时刻采一次
    参考有过整整差一圈的记录。参考重取是独立动作（要求转子静止、门极关闭），由
    `action.gear_capture` 显式触发。
  - 推论：清零后记忆窗口不再以零点为中心（窗口中心 = `gear_zero_count/CPR`，
    ±T2/(2|k|) 转子圈），需要居中时再跑一次 `gear_capture`。
    `tools/gear_test.py check` 会打印当前窗口区间。
  - `config.m_zero` 写成别的值时只做坐标平移（此时零点不是当前位姿）。
  - `action.zero` **会立即写 flash**（含 `gear_zero_*` 与当时的 `i_max`/`accel_limit`），
    所以台架脚本必须先把临时限流恢复再调它。
- **参数/接口**：`config.gear_teeth_first`（30）、`config.gear_teeth_sec`（27）、
  `config.gear_sec_reversed`（副编码器读数是否反向，本机实测默认 true）、
  `config.gear_zero_phase`、`config.gear_zero_count`、`config.gear_ref_valid`；
  动作 `action.gear_capture`（定参考）、`action.gear_read`（只读一次并刷新遥测，
  不写 flash）；结果看 `system.gear_status`（1 成功 / -1 齿数配置非法 / -2 还没参考 /
  -3 副编码器没响应 / -4 门极使能时被拒绝）；遥测 `telemetry.sec_enc_raw` /
  `sec_enc_present` / `sec_enc_phase` / `sec_enc_lost_frames` / `gear_abs_turns`。
- **台架验收**（必须做，纯算术之外的误差都来自齿隙/偏心）：用
  [`tools/gear_test.py`](../tools/gear_test.py)（依赖 `pyserial`，走 endpoint 协议）：
  ```bash
  python tools/gear_test.py --port COMx check           # 配置/副编在线/量程/当前差值（不动电机）
  python tools/gear_test.py --port COMx verify          # 多位置一致性（默认输出轴 ±3 rad）
  python tools/gear_test.py --port COMx powercycle      # 每个位置断电重启后比对
  python tools/gear_test.py --port COMx ratio           # 反推实际传动比（齿数/方向不确定时）
  python tools/gear_test.py --port COMx capture --at 0  # 重取参考（只写 RAM，要 action.save）
  python tools/gear_test.py --port COMx zero            # action.zero 后参考是否同步平移
  ```
  位置列表用 `--positions=…`（负号开头的第一个值必须写成 `--positions=-1.5,0,1.5`，
  否则 argparse 当它是选项），或者 `--start/--stop/--step`。工具会先把
  `i_max` / `accel_limit` 临时压到 2 A / 20 rad/s²（只改 RAM），退出时恢复，所有路径
  都回 MENU；超判据（默认 `--max-diff 0.01` 转子圈）退出码为 1。
  `ratio` 用斜率 `dΔ/dθ = k/T2` 反推 `T1/T2 = 1 + slope`（`reversed` 打开时；关掉时
  是 `1 − slope`），本机实测 0.1103（rms 0.0026 圈）→ 反推 first ≈ 29.98 → 30；
  短跨度会被齿隙/偏心带偏，求平均值要用 `--start -3 --stop 3`（约 8.6 圈）。

  手工核对（没装工具时）：
  ```
  set config.gear_teeth_first=30 ; set config.gear_teeth_sec=27 ; set config.gear_sec_reversed=1
  call action.gear_capture ; call action.save
  get system.gear_status            # 1
  get telemetry.sec_enc_raw         # 非 0xFF/0x00 的跳变值
  # 用手（或上位机）把输出轴转 X 圈，再读一次：
  call action.gear_read
  get telemetry.gear_abs_turns      # 与 telemetry.position_motor 的增量一致（±半个 count）
  # 断电再上电：位置应当接上（开机横幅会打印 "Gear encoder: restored ... turns"）
  ```
  若上电位置系统性差**整整一圈**，先看 `config.gear_zero_phase` 是否被手改过、
  `M_ZERO` 是否绕过 `ps_set_m_zero` 改过；差**半圈/比例错**则是齿数或
  `config.gear_sec_reversed` 配错（副编码器方向不对）。判方向的快捷办法：正转时
  看 `telemetry.sec_enc_raw` 与 `telemetry.encoder_raw` 是同增还是此增彼减，同时用
  `action.gear_read` 看 `telemetry.gear_abs_turns` 的增量是否等于
  `telemetry.position_motor` 的增量。

## 保护与限幅

四类限制，全部由 `config.*` 参数控制，**默认行为与改动前一致**（温度保护默认关，
OV 阈值仍是 67 V，UV / 母线电流 / 转矩上限默认关）：

| 参数 | 默认 | 作用点 | 行为 |
|---|---|---|---|
| `config.vbus_ov_trip` | 67 V | `check_faults()` | 超过即锁 `FAULT_OV`（原编译期常量 `V_BUS_FAULT`，已删除）。**任何状态都检查**：门极关断时母线也可能被外部推高 |
| `config.vbus_uv_trip` | 0 = 关 | `check_faults()` | **只在门极使能时**检查，~10 ms 去抖（400 拍）后锁 `FAULT_UV`。若在任何状态都查，USB 单独供电（`v_bus = 0`）会一上电就锁故障、把人挡在菜单外 |
| `config.i_dc_max` | 0 = 关 | `commutate()` | 母线电流**软限幅**：估算值超过上限时按比例回压 `i_d_des`/`i_q_des`。只压不抬，**不锁故障**——没有直流分流器，估算值不足以当保护用 |
| `config.torque_lim` | 0 = 关 | `commutate()` | **输出端** N·m，换算 `i_q_lim = torque_lim/(KT·GR)` 后并入电流上限。与 `command.t_ff`/`telemetry.torque` 同量纲 |
| `config.fet_temp_en` / `_lo` / `_hi` | 关 / 75 / 95 °C | `commutate()` + `check_faults()` | 在 `[lo, hi]` 间线性降流（到 `hi` 时电流上限为 0），超过 `hi + 5 °C` 锁 `FAULT_FET_OT`（与 ODrive 的 `do_checks()` 一致，避免在阈值上抖动） |
| `config.mot_temp_en` / `_lo` / `_hi` | 关 / 75 / 95 °C | 同上 | 同上，锁 `FAULT_MOT_OT` |

新增故障位：`FAULT_UV (1<<4)`、`FAULT_FET_OT (1<<5)`、`FAULT_MOT_OT (1<<6)`。
CYBERBEAST 侧 `FAULT_UV` 与 `FAULT_OV` 都映射 `CB_ERR_VOLTAGE`；过温没有专用错误码，
归 `CB_ERR_MULTIPLE`（精确原因读 `telemetry.fault` 或 `0x45 QUERY_ERROR`）。

### NTC 温度（照搬 ODrive）

`foc.c` 的 `update_thermistors()` 移植自 ODrive 的 `ThermistorCurrentLimiter`：

- 归一化 `x = adc_measurements_[ch]/4096`，四阶 Horner 多项式换算 °C。
  MOS = `adc_measurements_[0]`（ADC2_CH2/PA7），系数 `{296.7, -385.7, 257.1, -26.81}`；
  电机 = `adc_measurements_[2]`（ADC3_CH6/PE8），系数 `{-296.7, 504.3, -375.8, 141.3}`。
  ⚠ **系数顺序是 ODrive 的 `horner_poly_eval` 约定：`c[0]` 是最高次幂**（与
  `numpy.polyfit` 一致），`thermistor_celsius()` 必须从 `c[0]` 开始乘。反过来乘
  （把 `c[0]` 当常数项）编译器和自检都不会报错，但室温下 MOS 会读到 200 °C 以上、
  电机读到 -100 °C 以下——早期版本就是这样错的。
- 两级一阶低通，每级 `tau = 0.1 s`。**在主循环里更新**（`run_fsm_slow()` 第一件事），
  `dt` 由 `controller.loop_count` 的差算出：主循环没有固定周期（打印、擦 flash 都会
  拉长一拍），用固定 dt 会让滤波时间常数随固件行为漂移。
- ⚠ 系数和分压网络都是从 ODrive 板子搬来的。CBL89 若不同，读数会系统性偏移——
  **上台架必须先用室温核对一次**，偏差大就改这两组系数（换算结构不变）。
- 换算是 `isfinite` 保护的：通道/系数异常时写 0 并清掉滤波状态（否则 NaN 会留在
  状态里，读数永远停在 0），不会把 NaN 灌进比较。
- 温度**只上报 +（默认关闭的）保护**，不参与电流环；`telemetry.temperature` 现在
  等于 MOS 温度（原来是恒 0 的温度观测器输出，`update_observer()` 整个函数体是被
  注释掉的）。

### 母线电流 / 功率估算

没有直流分流器，`commutate()` 用上一拍的 dq 量反推：

```
P_elec = 1.5 · V_PER_CMD · (v_d·i_d + v_q·i_q)      [W]
i_bus  = P_elec / v_bus_filt                        [A]
mech_power = i_q_filt · KT · GR · dtheta_mech       [W]
```

`V_PER_CMD` 现在定义在 `hw_config.h`（`calibration.c` 的 `CAL_V_PER_CMD` 也改用它，
只有一处定义）。`v_d/v_q` 是上一拍的输出，误差在一个控制周期内——对监控与软限幅
足够，**不能当保护**。遥测见 `telemetry.i_bus` / `telemetry.mechanical_power`；
CYBERBEAST 的 `0x44 QUERY_BUS`（第二字段）与 `0x47 QUERY_POWER`（电/机械功率）
也已填上。

## 电流环增益（k / ki 由标定的 R/L 推导）

`current_loop_retune()`（`foc.c`）按**标定出来**的 `config.r_phase` / `config.l_d` /
`config.l_q` 做极点对消，把 `config.i_bw` 变成真正的穿越频率：

```
k_d  = 2π·i_bw·L_D / V_PER_CMD          [指令 V/A]  →  |k·V_PER_CMD/(jωL)| = 1 @ ω = 2π·i_bw
k_q  = 2π·i_bw·L_Q / V_PER_CMD
ki_d = 1 - exp(-R_PHASE·DT/L_D)          →  PI 零点 = R/L（每拍），与 i_bw 无关
ki_q = 1 - exp(-R_PHASE·DT/L_Q)          （1-e^-x 用 Padé 12x/(12+6x+x²)，不引 libm）
ki_fw = 0.1·ki_d
```

**为什么不能写死常数**：`k` 正比于 `L`、`ki` 只取决于 `R/L`，两者都是电机参数。
以前的 `K_SCALE`（= 假设 L≈24 µH）+ `KI_D`（= 假设 R/L≈1800 rad/s）只对那一台
电机成立，同样的常数换台电机差异极大（同一 `i_bw=1000`，按各机标定 R/L 代入）：

| 电机 | R | L | 实际穿越（旧常数） | 相位裕度 |
|---|---|---|---|---|
| 本机 CBL89（q / d） | 0.414 Ω | 45.3 / 22.8 µH | 110 Hz | >100°（R 主导，P 路径到不了 0 dB） |
| 大疆 M3508 类 | 0.10 Ω | 60 µH | 404 Hz | 81° |
| 小云台电机 | 5 Ω | 300 µH | **9 Hz** | 91° |
| 小穿越机 | 0.03 Ω | 10 µH | **2332 Hz** | 53° |

改成推导后，各机的穿越频率就约等于 `i_bw`（离散闭环，含 ADC→占空比 2 拍 = 50 µs 延迟；
CBL89 的 q/d 轴，300~2000 Hz 范围内 d 轴略好）：

| `config.i_bw` | 300 | 500 | 1000 | 1500 | 2000 |
|---|---|---|---|---|---|
| 实际穿越 | 218 Hz | 367 Hz | 762 Hz | 1193 Hz | 1645 Hz |
| 相位裕度 | 87° | 85° | 78° | 69° | 59° |

⇒ **默认 1000（实际 762 Hz、PM 78°），300~800 是甜点，2000 是硬上限**（1650 Hz、
PM 59°，再高就是在跟 2 拍延迟赛跑）。离散闭环的阶跃响应在 1500 Hz 以内都无超调，
2000 Hz 时 q 轴约 9%。

调用时机（全部是纯浮点、几十条指令，状态切换时执行一次）：

1. 上电：`init_controller_params()`（`main.c`，在 prefs 载入之后）；
2. 每次进 `MOTOR_MODE`：`reset_foc()` —— 所以改了 `config.i_bw` 或重新标定，
   下一次进电机模式一定用的是新值；
3. 标定收尾：`run_fsm_slow()` 里，`measure_lr()` 刚写出 R/L 就重算，并打印一行
   `Current loop: i_bw …, R …, Ld …, Lq … -> k_d …, k_q …, ki_d …, ki_q …`
   （台架上可直接核对）；
4. 写 `config.i_bw` 时：endpoint 的 `set` 里直接调 `current_loop_retune()`
   （**不需要重启**）。

保底与钳位：`r_phase<=0` 或 `L<=0`（出厂默认 R=0）时退回 `hw_config.h` 的
`K_SCALE` / `KI_D` / `KI_Q`，行为与引入推导前一致；推导出的 `k` 钳在
`I_LOOP_K_MAX`（10 指令 V/A），防止 `l_d`/`l_q` 被写成量级错误的值时增益大 100 倍
直接失稳。`i_bw` 本身由 `config_apply_limits()` 钳在 [100, 2000] Hz。

台架验收（锁转子或带载，`csv` 子命令）：

1. `get config.r_phase` / `l_d` / `l_q` 必须非 0（否则走的是常量兜底），并对照
   只读的 `telemetry.current_k_d/k_q/ki_d/ki_q` —— 它们就是 `commutate()` 正在用的
   系数（`k ≈ 2π·i_bw·L/V_PER_CMD`，`ki ≈ R·DT/L`），可以逐个手算核对；
2. 扫 `i_bw` 300 / 500 / 800 / 1000，看 `telemetry.i_q` 跟随、听噪声、确认
   `fault` 不锁存（`i_max` 3 A 时 OC 门限 4.5 A）；
3. 电流环变快以后外环会显得"更冲"，`action.tune_gains` 需要重跑一次；
4. 纹波：48 V / 45 µH / 25 µs 的 PWM 纹波约 3 A pk-pk，采样固定在 PWM 峰值，
   带宽越高混叠越明显 —— 出现电流啸叫就回退一档。

## 速度环与位置环（CSV / CSP）

三条环都跑在控制中断里、相位锁在 PWM 更新（update/TRGO）上：

| 环 | 频率 | 实现 | 周期 |
|---|---|---|---|
| 电流环 | **固定 40 kHz** | `commutate()`（`foc.c`） | 25 µs |
| 速度环 | 40 kHz / `config.vel_loop_prescaler`（默认 5 → **8 kHz**） | `ml_vel_pi()` | 125 µs |
| 位置环 | 速度环 / `config.pos_loop_prescaler`（默认 2 → **4 kHz**） | `ml_pos_p()` | 250 µs |

`motion_control()`（`motion.c`）在 `MOTOR_MODE` 里取代了原来对 `torque_control()` 的
直接调用，按 `controller.ctrl_mode` 分发：

| `ctrl_mode` | 来源 | 行为 |
|---|---|---|
| `CTRL_IMPEDANCE`（默认） | MIT `0x00/0x80`、旧 11-bit 协议、`0x03`、`0x04`、`command.mode=0` | 原样调用 `torque_control()`，**每拍都算**，与改动前逐字节一致 |
| `CTRL_VELOCITY` | CSV `0x02/0x82`、`command.mode=1` | 速度 PI → `i_q` |
| `CTRL_POSITION` | CSP `0x01/0x81`、`command.mode=2` | 位置 P → 速度指令 → 速度 PI → `i_q` |

纯数学部分在 `Core/Inc/motion_law.h`（零固件依赖），host 测试
`tools/test_motion_law.c` 直接包含它，见“测试”一节。

### 位置软限位（允许区间 + 方向闸 + CSP 界外冻结）

`config.p_min`/`p_max` 是**设定值**的软限位，但允许的目标区间不是固定的
`[P_MIN,P_MAX]`，而是"界内 + 一条通向当前位置的走廊"：

| 实测位置 | 允许的目标区间 | 例子（限位 0..10） |
|---|---|---|
| 界内 | `[P_MIN, P_MAX]` | 当前 5 → 只能给 0..10 |
| 正限位外 | `[P_MIN, p_meas]` | 当前 15 → 可以给 12（仍在界外但朝界内），不能给 16；退到 12 之后就只能给 ≤12 |
| 负限位外 | `[p_meas, P_MAX]` | 当前 −5 → 可以给 −2，不能给 −6 |

判据在纯函数 `ml_pos_cmd_range()` / `ml_pos_cmd_clamp()`（`motion_law.h`，host 可测），
两个使用点：

- **通信层**（写 `p_des` 时）：旧协议 `SET_PV`、CYBERBEAST CSP、endpoint `command.p_des`
  都走 `foc.c` 的 `pos_cmd_limit()`（endpoint 生成代码的 min/max 用 `pos_cmd_lo()` /
  `pos_cmd_hi()`），所以 `command.p_des` 存的就是**这一刻可达到**的目标；
- **控制层**：CSP 每拍用 `ml_pos_cmd_clamp()` 重算 —— 位置在动，写入口那一刻的界
  可能已经变了，这也正是"退到 12 之后再写 13 不会往外走"的原因。

`P_MAX <= P_MIN`（实际只有 `p_max = 0`，因为 endpoint 与 `config_apply_limits()` 保证
`P_MAX >= 0 >= P_MIN`）时区间是 ±FLT_MAX，**完全不限制**。

CSP 有位置目标，钳 `p_des` 就够了；CSV 和纯力矩没有位置目标，`p_des` 钳不到它们，
所以另外有一道**方向闸** `ml_pos_dir_gate()`（`motion_law.h`，host 可测）。它作用在
"正号 = 使位置增大"的任何指令上，两个调用点只是单位不同：

| 控制律 | 闸的对象 | 位置 | 说明 |
|---|---|---|---|
| CSV / CSP | `v_setpoint`（rad/s） | 斜坡之后、速度 PI 之前，**就地写回** | 它同时是斜率限制器的状态，不回写的话限位解除时会从旧的正向设定值突然冲出去 |
| 阻抗 / MIT / TORQUE / CURRENT | `i_q_des`（A，电机端） | `torque_control()` 之后、镜像到 `i_q_ref` 之前 | 覆盖 **CST 纯力矩**（`kp = kd = 0`，0x03/0x04/`command.t_ff`）；MIT 有 kp，`p_des` 已被钳在限位内，通常不触发 |

判据：

- 用**实测位置**（`encoder.angle_multiturn × 1/GR`，输出轴），不是设定值；
- `p_meas >= p_max` 时只放行负方向（回转），`p_meas <= p_min` 时只放行正方向 ——
  即**允许回转、不允许继续超限**；界内两个方向都原样通过；
- 无滞环：停在边界上时越界方向每拍压成 0，回转立刻放行；
- 指令本身（`v_des` / `t_ff`）**不改**，只丢越界方向的那一拍。

**CSP 的界外冻结**（`controller.pos_hold`）：切到 `CTRL_POSITION` 时如果实测位置已经
在 `[P_MIN,P_MAX]` 外，`p_des` 很可能是个陈旧值（进电机模式时被 `zero_commands()` 清成
0，或上一次的目标在另一侧），追它就等于"强制把关节拉回界内"（表现为一进 CSP 就自己往
回冲）。所以 `motion_seed()` 在切换那一拍置 `pos_hold`，位置环改为：

- 不追 `p_des`、不跑输入整形，`v_target = 0` —— 零速保持原地，两个方向都不主动驱动；
- 不参与 `FAULT_POS`（冻结不是跟随失败）；
- 解除条件二选一：主站写入**不同**的 `p_des`（与冻结快照 `pos_hold_des` 比较），或
  关节自己回到界内。解除时清掉轨迹/滤波状态，从当前位置重新起步；
- `zero_commands()` 一并清 `pos_hold`（超时/离开电机模式后不会带着旧冻结回来）。

⚠ 触发冻结有个例外：切换时 `p_des` **本身也在界外**（例如当前 15、目标 12）——这只可能
是在界外时写下的"往回收"目标，属于明确指令，直接跟踪、不冻结。所以界外两种顺序都能用：
先写 12 再切模式 = 直接退到 12；先切模式（冻结）再写 12 = 同样退到 12。

⚠ 冻结的解除靠"目标变化"：界外**同一个值重复写不算新目标**（比较的是快照值）。主站持续
发流式 CSP 帧时，切换后第一帧不同目标就会解除冻结 —— 那是主站自己下的命令。

⚠ 闸只改本拍采用的指令：`telemetry.v_setpoint` / `telemetry.i_q_des` 才是被闸过的
值（`command.v_des` / `command.t_ff` 仍是主站写的）。限位关闭（`p_max = 0`）时闸
也不生效。`cogging_apply()` 在闸之后叠加前馈（默认关闭、幅值受 `config.cogging_max`
限制），弱磁只会减小 `|i_q|`，两者都不会把越界方向的力矩重新放大。

### 为什么这样不损失电流环带宽

- 外环**只产生 `i_q_des` 这个参考**。`commutate()` 的增益、采样相位、`svm()`
  预装载顺序、`v_max` 计算、`d/q` 积分器一个字节都没改。
- 外环在更新拍插在 `commutate()` 之前，多花约 0.3–0.8 µs（25 µs 的 1–3%），
  对电流环相位裕度的影响 < 1°；分频后绝大多数拍完全不执行外环。
- 外环的可用带宽由**速度估计**决定，不由控制频率决定：PLL 带宽默认 2000 rad/s
  （约 318 Hz，200 Hz 处只吃 -13° 相位）+ 8 kHz 采样的 62.5 µs 零阶保持，
  比电流环（推导增益后 ~1 kHz）低一个数量级。
  所以“降外环频率”换不到电流环的任何好处，反过来也一样。
- ⚠ **`i_q_des` 必须每拍从 `controller.i_q_ref` 重新赋值**：`field_weaken()` 是
  *就地累加* `i_q_des`（`i_q_des += fw_int`）。分频等待期间若直接沿用 `i_q_des`，
  弱磁会一拍接一拍地叠加下去。

### 单位

全部是**输出轴**量（与 `torque_control()` 同口径），输出是**电机端安培**：

| 参数 | 单位 | 说明 |
|---|---|---|
| `config.pos_gain` | (rad/s)/rad | 位置误差 → 速度指令 |
| `config.vel_gain` | A/(rad/s) | 速度误差 → 电流指令（电机端） |
| `config.vel_integrator_gain` | A/(rad/s)/s | 速度积分 |
| `config.accel_limit` | rad/s² | 速度设定值斜率限制，0 = 关闭 |
| `config.pos_error_fault` | rad | 跟随误差故障阈值，0 = 关闭 |
| `config.pll_bandwidth` | rad/s | 编码器速度 PLL 带宽 |

2026-11-06 那组（**历史记录，已不是默认值**；GR 9、`i_bw 1000` 的推导电流环）：`pos_gain 15` /
`vel_gain 2.158` / `vel_integrator_gain 38.85` / `accel_limit 50` / `inertia 0.00096` /
`tune_margin 1.5` / `omega_c 450` / `pos_error_fault 0` / `pll_bandwidth 2000`。
这一组正是 `tune_gains(ω_c 450, margin 1.5)` 的输出，当时自洽；实测（同一台架、`csv_csp_test.py`）：
1 rad/s 速度阶跃超调 3~7%、峰值 0.4~0.5 A；0.2 rad 位置阶跃最终 `|pos_err| ≤ 0.4 mrad`。
其中 `accel_limit 50` 曾是 CSP 不过冲的前提（10 时 1 rad 阶跃过冲 49%），但后来发现
`accel_limit 50` 在 2 rad 这类大阶跃上自身就会带来 22.9% 过冲，**现在的默认值是 200**
（见下面的 2026-11-16 整定）。⚠ 任何一组都只是**起点**：换电机/换关节必须重新
`action.measure_inertia` + `tune_gains`，尤其是 `config.inertia` 的默认值只是本台架的
实测值，**不代表任何其他机构**。

历史（2026-11-02，旧电流环、GR 被误配成 7.75）：`vel_gain 2.469` / `vel_integrator_gain 44.44` /
`inertia 0.0006` / `tune_margin 2.2`。那组数字仍保留在下面的实测表里作为**记录**，
不要再当作默认值。

### 2026-11-16 出货前整定（MZW55 + Keil 镜像，J 0.000996，KT 0.0335，GR 9）

同一台架重测后**偏离了上面那组 11-06 的记录**，原因是速度环的瓶颈找到了：反馈 PLL。
把 `vel_gain` 推高到 6~20（P only、`v_des` 阶跃）会自激，振荡频率随
`config.pll_bandwidth` 走（1000/2000/4000/5000 → 109/157/206/224 Hz），说明限制
相位裕度的是速度估计的滤波，不是机械或延迟。据此定的一组（存进 flash，`action.save`）：

| 参数 | 值 | 依据 |
|---|---|---|
| `i_bw` | 1000 Hz | 500~2000 Hz 静止电流噪声都在 std ≈ 0.012 A，无差别；1000 是文档已验证的穿越点（762 Hz / PM 78°） |
| `pll_bandwidth` | 3000 | 2000 时 P-only 环路在 `vel_gain 2.23` 下过冲 51%；3000 降到 38%，噪声只涨 20% |
| `vel_gain` | 1.397（`tune_margin 0.94`） | P-only 5 rad/s 阶跃过冲：1.0 → 2.4%、1.3 → 7.3%、1.6 → 20%、2.23 → 38%。取 1.4 兼顾阻尼与 ~65 Hz 穿越 |
| `vel_integrator_gain` | 25.15（= vel_gain·18） | `tune_gains` 的 `clamp(ω_c/25,5,30)`；再大低速 stick-slip |
| `pos_gain` | 20（高于 `tune_gains` 的 ω_c/30=15） | `accel_limit 200` 下 0.05/0.2/0.5/1/2 rad 阶跃过冲 3.2/0.4/0.1/0.1/1.5% |
| `accel_limit` = `decel_limit` | 200 | 50 时 1 rad 阶跃 4.8%、2 rad 22.9%；200 时分别 0.1% / 1.5% |
| `mit_tau_max` | 5.0 | 见上（`__float_reg[54]`） |
| MIT kp/kd | `kd = 0.044·√kp`（ζ≈0.7） | kp 10/20/40/100 配 kd 0.14/0.2/0.28/0.44：过冲 0.2~0.8%、稳定 39~68 ms |

复测（同一套脚本）：CSV 1 rad/s 过冲 5.4%、稳态误差 0.05%、t90 55 ms；5 rad/s 过冲
0.9%；CSP 0.5 rad 过冲 0.1%、304 ms；MIT kp 20 / kd 0.2 过冲 0.5%、57 ms。
⚠ 这一组**就是现在的编译期默认值**（`params.json` + `Core/Src/prefs_defs.c`），
`action.reset_config` 也回到它；`action.tune_gains` 在 ω_c 450 / margin 0.94 下算出的
`vel_gain` 1.40、`vel_integrator_gain` 25.2 与表一致，但 `pos_gain` 会给 15（`ω_c/30`），
所以**直接把 pos_gain 设成 20**——它和 `accel_limit 200` 是一对，见上表。

为什么在安培域而不在 N·m 域：CSP/CSV 帧的限幅本来就是电流（A），
`limit_norm()`、`field_weaken()`、过流阈值也都在安培域。省掉每拍 2 次乘法 +
1 次除法，增益也不依赖标定出来的 `KT`。MIT 路径仍然是 N·m 域，不受影响。

帧到环的换算（`can_cyberbeast.c`）：

| 帧字段 | 线上单位 | 环内 |
|---|---|---|
| CSP 目标位置 | deg（输出端） | `× π/180` → `p_des`，再经 `pos_cmd_limit()` 钳到允许区间（界内 `[P_MIN,P_MAX]`，界外放宽到当前位置，见上一节） |
| CSP `vel_limit` | RPM（输出端） | `× 2π/60` → `controller.v_limit`；0/NaN 退回 `V_MAX` |
| CSP/CSV `cur_limit` | A（**电机端**） | → `controller.i_cmd_max`，钳到 `[0, I_MAX]` |
| CSV 目标速度 | RPM（输出端） | `× 2π/60` → `v_des`，再钳到 `[V_MIN,V_MAX]` |

`vel_limit` 收到 0 一律按“未指定”处理并退回 `config.v_max`：位置模式配一个 0 限速
会让关节在重力下直接垮掉。要“别动”请用速度模式给 0。

### 抗饱和与限幅

```c
i_unlim = vel_gain*v_err + vel_integ;
i_q     = clamp(i_unlim, ±i_cmd_max);
if (i_q != i_unlim) { vel_integ *= 0.99f; }       /* 饱和 → 衰减，不累积 */
else                { vel_integ += vel_integrator_gain*v_err*dt; }
vel_integ = clamp(vel_integ, ±i_cmd_max);
```

与 ODrive 的 `vel_integrator_torque_ *= 0.99f` 同款。位置环没有积分器，所以不存在
位置积分饱和；位置误差通过 `v_limit` 钳位转成“按速度上限追赶”。

### 输入整形（`config.input_mode`）

`config.input_mode` 只整形**喂给控制环的设定值**，不选控制环（那是
`command.mode`）。编号与 ODrive 的 `InputMode` 一致：

| 值 | 名称 | 行为 | 适用控制环 |
|---|---|---|---|
| 0 | INACTIVE | 忽略输入，保持上一拍的设定值 | 任意 |
| 1 | PASSTHROUGH | 设定值直通，不做斜率限制 | 任意 |
| **2** | **VEL_RAMP** | **速度设定值按 `accel_limit`/`decel_limit` 限斜率（默认 = 旧行为）** | CSV / CSP |
| 3 | POS_FILTER | 二阶位置跟踪滤波（`config.input_bw`），速度作前馈 | CSP |
| 4 | MIX_CHANNELS | 不支持 → 按 PASSTHROUGH | — |
| 5 | TRAP_TRAJ | 梯形位置规划（`trap_vel_limit`/`trap_accel_limit`/`trap_decel_limit`，未配置时退回 `v_max`/`accel_limit`/`decel_limit`），速度作前馈 | CSP |
| 6 | TORQUE_RAMP | `t_ff` 按 `config.torque_ramp_rate`（N·m/s）限斜率 | 阻抗/MIT |
| 7/8 | MIRROR / TUNING | 不支持 → 按 PASSTHROUGH | — |
| 9 | MIT | 等同 PASSTHROUGH（阻抗律本来就是 MIT 语义） | 阻抗/MIT |

实现要点：

- 3/5 是**轨迹发生器**：在位置环频率上产生 `(pos_setpoint, vel_setpoint)`，位置环
  对它做 `pos_gain*误差 + pos_ff_gain*轨迹速度`。轨迹速度**取代**帧间差分前馈
  （`pos_ff`），两者叠加会过冲 —— 所以这两个模式下 `pos_ff` 不参与。
- 轨迹模式自己就是平滑的，**不再叠加** `accel_limit` 的斜率限制；只有 VEL_RAMP 走。
- 模式改变或进/出电机模式时，`motion_seed()` 把滤波/规划状态清掉，下一拍从
  **实测位置**起步（`ml_posf_reset()` / `planned = 0`），不会从 0 跳过去。
- 纯数学在 `motion_law.h`（`ml_trap_*` / `ml_posf_*` / `ml_slew2`），
  `tools/test_motion_law.c` 覆盖：梯形/三角形规划、时长与终点精度、时间冻结、
  中途改目标不跳变、滤波收敛不过冲、带宽过大时自动压低增益。

**TRAP_TRAJ 是 ODrive `trapTraj.cpp` 的逐行移植**：按"当前速度的最小制动距离"
决定巡航方向 `s`，行程够就走梯形（加速/匀速/减速），不够就退化成三角形；
起始速度高于巡航速度时先减速（"double deceleration move"）。规划结束时间冻结在
`tf`，避免 float32 长时间累加丢精度。

### 斜坡 / 轨迹的限值从哪来（ODrive 对齐）

ODrive 把"设定值限幅"拆成了几组独立参数，我们按同样结构补齐。**新参数默认全 0 =
沿用通用值，行为与改动前完全一致**（`ml_limit_or()` / `ml_trap_vel()` 负责回退）：

| 场景 | ODrive | 本工程 | 默认 | 回退链 |
|---|---|---|---|---|
| 速度斜坡（VEL_RAMP）的速率 | `controller.config.vel_ramp_rate` | `config.vel_ramp_rate` | 0 | `>0` 时**加速与减速都用它**（对称，等同 ODrive）；`0` 时用 `accel_limit` / `decel_limit` |
| 速度设定值上限（CSV/CSP） | `controller.config.vel_limit` | `config.v_max` | 65 | — |
| 加速斜率（VEL_RAMP） | `controller.config.vel_ramp_rate` | `config.accel_limit` | 50 | `vel_ramp_rate = 0` 时才用它 |
| 减速斜率（VEL_RAMP） | 同上（对称） | `config.decel_limit` | 50 | `vel_ramp_rate = 0` 时才用它 |
| 梯形规划的巡航速度 | `trap_traj.config.vel_limit` | `config.trap_vel_limit` | 0 | `0` → 运行期限速（`controller.v_limit`，即帧内 vel_limit 或 `config.v_max`）；`>0` → **与运行期限速取 min**（与 ODrive 的"先轨迹限速、再被 controller.vel_limit 夹"等价） |
| 梯形规划的加速度 | `trap_traj.config.accel_limit` | `config.trap_accel_limit` | 0 | `0` → `config.accel_limit` |
| 梯形规划的减速度 | `trap_traj.config.decel_limit` | `config.trap_decel_limit` | 0 | `0` → `config.decel_limit`（再为 0 → `accel_limit`） |

要点：

- **想"轨迹慢慢爬、手动高速点动"**：把 `trap_*` 三个配上即可，`v_max` /
  `accel_limit` / `decel_limit` 保持高速值不动。反过来也想让 CSV 的斜坡和轨迹不同，
  配 `vel_ramp_rate` 即可。
- **`trap_vel_limit` 只能收紧、不能放宽**：运行期限速（帧内 `vel_limit` 或
  `config.v_max`）始终是上限，这是为了避免"轨迹要求 5 rad/s、位置环只被允许 1 rad/s"
  那种必然触发 `FAULT_POS` 的矛盾。
- 位置环的 `v_cmd` 夹取仍然用运行期的 `v_lim`（`config.enable_vel_limit` 关闭时
  不夹），与轨迹限速是两回事：前者限制**位置环输出的速度指令**，后者限制
  **轨迹规划的巡航速度**。
- 参数改完立刻生效（每拍读取），不需要重启。

### 速度限制的两个开关

- `config.enable_vel_limit`（默认 **true**）：关掉后 CSV/CSP 与 CYBERBEAST 帧解析
  都不再把速度压到 `config.v_max`。`command.v_des` 端点的范围也随之放开成固定的
  ±200 rad/s（不再是动态的 `V_MIN..V_MAX`），否则"关掉限速"仍然写不进去。
- `config.enable_torque_vel_lim`（默认 **false** = 与改动前一致）：在**阻抗/力矩/
  电流模式**下也限制速度，做法与 ODrive 的 `limitVel()` 相同，只是直接在安培域：
  `i_q = clamp(i_q, (v_max − v)·vel_gain, (−v_max − v)·vel_gain)`。
  我们的 `vel_gain` 正好是 A/(rad/s)，量纲天然成立。高速时它会把推力压向"刹车"
  一侧，超过 `v_max` 就没有继续往超速方向推的余量。

### 编码器速度 PLL

`ps_update_pll()`（`position_sensor.c`）用 `ml_pll_step()` 在**单圈计数**上做临界阻尼
PLL（`kp = 2·bw`、`ki = 0.25·kp²`，与 ODrive `Encoder::update()` 一致），输出
`comm_encoder.pll_velocity`（电机端 rad/s）。

- 用单圈计数而不是多圈浮点位置：`|count|` 超过 2^24 后 float32 已经丢掉整数分辨率，
  位置一大相位检测就变成台阶。
- 丢帧（`ps_finish_sample()` 返回 0）时不预测，否则估计会一路漂。
- 第一个有效样本直接对齐（`pll_seeded`），不追赶 —— 半圈相位差经 `ki` 会变成
  几十 rad/s 的速度尖峰，再进电流环就是一下冲车。
- **MIT 与旧协议继续用 `comm_encoder.velocity`**（475 µs 整数差分），
  这条路径没有改动；`telemetry.velocity` 与新增的 `telemetry.velocity_pll`
  可以并排看噪声差别。

**带宽怎么选**（`config.pll_bandwidth`，默认 **2000 rad/s ≈ 318 Hz**）：
估计器的滞后是叠加在速度环“被控对象积分器固有的 -90°”之上的，所以要按穿越频率挑。
噪声列是 **2026-11-06 台架实测**（转子静止、门极开/关一致，输出轴量，电机侧 = ×GR 9）：

| `pll_bandwidth` | 100 Hz 处相位 | 200 Hz 处相位 | 静止速度噪声 σ | 峰值 |
|---|---|---|---|---|
| 500 (80 Hz) | -8° | -58° | 0.0086 / 0.077 rad/s | ±0.032 |
| 1000 (160 Hz) | -2° | -35° | 0.020 / 0.18 rad/s | ±0.07 |
| **2000 (318 Hz)** | **-2°** | **-13°** | **0.044 / 0.40 rad/s** | **±0.18** |
| 3000 (477 Hz) | -1° | -5.5° | 0.062 / 0.56 rad/s | ±0.23 |

**噪声是哪来的**（同一轮实测，证据链）：

- `telemetry.encoder_raw` 在静止时就有 **σ≈6 count、pp≈40 count** 的抖动（16 bit 编码器，
  即 0.033°，有效分辨率约 13.4 bit；偏差呈高斯、无 2^k 尖峰、低 4 位均匀 ⇒ 不是 SPI
  位错；`lost_frames = 0`）。门极开/关、沿电周期 8 个位置、在线性化前后都是同一量级
  ⇒ **不是 PWM/EMI、不是 LUT、不是位置相关**；副编码器（同型号）σ≈8.6 count，同族特性。
- 该抖动自相关 ρ(1)=0.67 @186 µs，τ≈0.46 ms（编码器内部有低通/更新率限制）。
  用 `σ=6 count + τ=0.46 ms` 的模型重跑 `ml_pll_step()`，四档带宽的预测值
  0.19 / 0.41 / 0.61（电机侧 @1000/2000/3000）与实测 0.18 / 0.40 / 0.56 相差 <10%
  ⇒ **PLL 结构/增益没问题，它已经是这个噪声下的近优估计器**。
- 所以"1 rev/s 时 0.05%"的旧估算是错的（那是按纯量化 0.5 count 算的）。真实值是
  电机侧 0.40/6.28 = **6.5%**；任何估计器都逃不掉 σ_v·T ≳ √2·σ_θ 这条线
  （想要 1% 就得平均 ~80 ms）。

⚠ **不要为了降噪而降带宽**（台架实测，同一 `vel_gain 2.158 / ki 38.85`）：

| `pll_bandwidth` | 1 rad/s 阶跃超调 | 匀速段速度纹波 σ | 静止 \|i_q\| |
|---|---|---|---|
| 500 | 失稳（abort） | — | — |
| 1000 | 34.5% / 43.1% | 0.29 / 0.33 | 0.36–0.59 A |
| **2000** | **5.7% / 7.2%** | **0.059 / 0.079** | **0.10–0.14 A** |
| 3000 | 7.4% / 13.5% | 0.077 / 0.091 | 0.12–0.17 A |

低带宽省下的那点噪声，远不如它带来的反馈滞后有害（1000 时纹波里绝大部分是环路自己
在振）。**2000 是对的，噪声不是当前的主要矛盾**：它对控制的实际影响只有
`vel_gain × σ = 2.158 × 0.044 ≈ 0.10 A` 的静止电流抖动（电角度只差 0.34°、
输出轴位置只差 1.1e-5 rad，可忽略），也是 `vel_gain` 到 2.5 附近就到边界的部分原因。

想真正更干净只有三条路，都不是调参：换低噪声/高分辨率编码器；给 KTH7823 开内部
滤波/分辨率寄存器（需查手册）；或上**模型化观测器**（用 `i_q` 与 `KT/J` 预测加速度，
`update_observer()` 目前整段被注释掉，`telemetry.observer_*` 端点还在）。

⚠ 上面这张表是 2026-11-06 在 `vel_gain 2.158`、**带输入整形**的 1 rad/s 阶跃下测的，
所以 2000 与 3000 都"够用"。2026-11-16 用**裸阶跃**（`input_mode=1`，P only）复测，
结论变了：相位裕度的限制就来自这个 PLL —— 同一 `vel_gain 6~20` 推到自激，振荡频率
随 `pll_bandwidth` 走（1k/2k/4k/5k → 109/157/206/224 Hz），而 `vel_gain 2.23` 的
5 rad/s 阶跃过冲 2000 时 52%、3000 时 38%。因此**默认改成 3000 + `vel_gain 1.397`**：
噪声按 σ ∝ `vel_gain` 折算只剩 11-06 那组的约 65%（静止 |i_q| ≈ 0.07 A），阻尼却实打实
变好了。如果客户只用带整形的 CSV/MIT，2000 也仍然是安全的。

对照：19 点整数差分（`comm_encoder.velocity`，475 µs 窗口）在同条件下是
**0.15 rad/s（输出轴）**、200 Hz 处还吃掉 -34° 相位 —— PLL 在噪声和相位上都更好。

### 惯量标定与增益推荐值

外环的增益其实只有三个未知量：`J_out`、`KT`（已标定）、`GR`（配置）。给定目标穿越
频率 `ω_c`，其余都能算出来；**`action.tune_gains`** 就按下面这套算并直接写进 RAM：

```
J_out   = KT·GR·Δi / Δa                          （惯量标定直接给）
vel_gain            = tune_margin·J_out·ω_c/(KT·GR)      [A/(rad/s)]
vel_integrator_gain = vel_gain·clamp(ω_c/25, 5, 30)      [A/(rad/s)/s]   （ω_i ≈ 18 rad/s @ ω_c=450）
pos_gain            = ω_c/30                             [(rad/s)/rad]
```

输入是 `config.inertia`（必须先标定）、`config.omega_c`（默认 450）、
`config.tune_margin`（默认 1.0）。要求菜单态 + `KT>0` + `GR>0`，**只写 RAM**，
不落盘；写完用 `csv`/`csp` 子命令验证，满意再 `action.save`。

⚠ 这里的 25 和 30 不是教科书取值（线性串级设计会说 `ω_c/5`），是台架上试出来的：

| 试过的值 | 结果 |
|---|---|
| `vel_integrator_gain = vel_gain·ω_c/5`（= 246 @ ω_c 450） | stick-slip 极限环，速度误差从 −0.8% 涨到 **+13.6%**，过冲 58% |
| `vel_integrator_gain = vel_gain·18`（= 49 / 44） | 误差 +0.3% / +3.9%，干净 —— ω_i ≈ 18 rad/s 是上限 |
| `pos_gain = ω_c/5 = 90` | 0.1 rad 阶跃过冲 **65%** |
| `pos_gain = 60` / `45` | 过冲 47% / 33%（齿隙 + 摩擦引起的极限环，不是线性失稳） |
| `pos_gain = 22.5`（原来的 `ω_c/20`） | 0.1 rad 阶跃还行，0.2 rad 阶跃过冲 **29%**（accel_limit 10） |
| `pos_gain = 15`（`ω_c/30`） | 0.2 rad / 1 rad 阶跃过冲 0.2% / 4.2%，`\|pos_err\|` ≤ 0.1 mrad |

**位置环的过冲主要不是相位裕度问题，而是 `config.accel_limit` 太小**：位置环是纯 P，
它给出的速度设定值要经过斜率限制，限得太慢就出现"位置一直追、速度却上不去，
等追上了速度还没降下来"的过冲。把 `accel_limit` 放到 200 后，`pos_gain` 45 也只有
0.1% 过冲、0.10 s 稳定。所以：

| `accel_limit` | `pos_gain=15` 的 1 rad 阶跃过冲 |
|---|---|
| 10 | 48.7% |
| 30 | 20.2% |
| 50 | **4.1%** |
| 200 | 0.1% |

⇒ **CSP 想要快，先放开 `accel_limit`（30~100 rad/s² 对小惯量关节很温和），
不要靠加 `pos_gain`。**

**`tune_margin` 补的是线性公式的低估**：公式假设纯惯性负载，实测库仑摩擦把有效
对象增益压低，同一台关节要把速度环放大才跟得上指令；它只放大速度环，位置环不跟着放大。
1 = 纯公式（保守）。⚠ 这个系数**跟着 `config.inertia` 的测量值走**：2026-11-02 用
`J 0.0006` 时台架最优是 2.2（`vel_gain` 1.12 → 2.47）；2026-11-06 按 GR 9 重测
`J 0.00096` 后，同一个工作点只需 `margin 1.5`（`vel_gain 2.158`）。也就是说
**换一次惯量标定就要重扫一次 margin**，不要跨关节照搬。台架实测（`i_bw 1000`、
`J 0.00096`、`ω_c 450`）：

| `tune_margin` | `vel_gain` | 1 rad/s 速度阶跃超调 | 备注 |
|---|---|---|---|
| 1.4 | 2.014 | 6~11% | 偏软 |
| 1.5 | 2.158 | 3~7% | 2026-11-06 的出厂值（**现已被 0.94 / 1.397 取代**，见上） |
| 1.6 | 2.302 | 5~12% | |
| 1.7 | 2.803 | 26~33% | |
| 2.2 | 3.627 | 失稳（两次都 abort） | |

最终值仍以 `csv --sweep` 为准（见"台架整定步骤"）。

**`action.measure_inertia`** —— 一条指令完成，不需要先手动进电机模式。
`run_fsm_slow()` 负责编排（`fsm.c` 的 `inertia_phase`）：请求 → `MOTOR_MODE`
→ 门极一开就触发 ISR 里的状态机 → 等它结束 → **自动回菜单**。
自动回菜单是必须的：测完若停在 MOTOR_MODE，门极还开着而转矩是 0，有重力负载的
关节会直接垮下来；回菜单后紧接着就能 `action.save`（save 要求门极关闭）。

状态机本身（`Core/Src/motion.c` 的 `inertia_step()`）在 MOTOR_MODE 里跑，单轮约
0.5 s；**每个 `action.measure_inertia` 连跑 3 轮取中位数**（单轮读数受齿隙/摩擦与
突破电流档位影响，台架实测离散 ±50%，只有中位数稳定），全过程约 3 s、全部在控制
ISR 内，不 printf、不写 flash：

| 阶段 | 时长 | 做什么 |
|---|---|---|
| `INERTIA_SETTLE` | 150 ms | 零电流，确认关节是静止的（窗内最大 \|ω\| 超过 0.35 rad/s 就直接失败） |
| `INERTIA_BREAKAWAY` | ≤600 ms | 每 8 ms 加 0.05 A，直到 \|ω\| > 0.35 rad/s → 得到"摩擦+重力"等效电流 `i_break` |
| `INERTIA_BRAKE` | 20–150 ms | **主动刹车**（`i = -ω`，限幅到 `0.5·I_MAX`）而不是零电流滑行 —— 滑行会让关节多走几倍行程，有限位的关节直接撞限位 |
| `INERTIA_TEST_LO` | ≤60 ms | 电流台阶 `1.5·i_break`，跳过前 8 ms（电流环建立时间）后流式最小二乘拟合 `dω/dt` |
| `INERTIA_BRAKE` | 20–150 ms | 同上 |
| `INERTIA_TEST_HI` | ≤60 ms | 电流台阶 `2.5·i_break`（都钳在 `0.5·I_MAX` 以内） |
| `INERTIA_BRAKE` → `INERTIA_DONE` | 20–150 ms | `J = KT·GR·(ī_hi − ī_lo)/(a_hi − a_lo)`，写 `config.inertia` |

单个台阶会在**位移超过 0.10 rad** 或速度超过 5 rad/s 时提前结束。⚠ 速度上限从
2 rad/s 提到 5 rad/s 是为了让拟合窗口够长：原来 1.9 ms 就到 2 rad/s、13 ms 撞上限，
而前面还要跳过 8 ms 建立时间 ⇒ 每个台阶只剩 ~5 ms(200 点) 数据，齿隙/摩擦的瞬态
全进来（台架单次 J 离散 ±50%）。现在窗口 ~26 ms。代价是**每轮净行程从 ~0.03 rad
涨到 ~0.17 rad，一个 action（3 轮）约 0.5 rad** —— 行程受限的关节先把它挪到中间。

⚠ 那三个速度阈值（`INERTIA_V_IDLE` / `INERTIA_V_BREAK` / `INERTIA_V_STOP` =
0.35 / 0.35 / 0.25 rad/s）是按**实测的 PLL 噪声峰值 ±0.18 rad/s** 定的（见
"编码器速度 PLL"）。2026-11-06 之前它们写的是 0.15 / 0.15 / 0.05，**低于噪声**，
于是突破电流经常被误判成最小档 0.05 A、测试台阶只有 0.075/0.125 A，加速度全是
噪声 —— 表现为 `status=6`（激励不足）。改编码器或大幅改 `pll_bandwidth` 时要重新
核这三个值（余量至少 1.5x 噪声峰值）。

`system.inertia_status` 的失败码是分段的，方便定位：3 = 关节本来就在动，4 = 加电流到
上限还不动（卡住/摩擦过大），5 = 台阶太短（样本不足）/超时/状态机卡住，6 = 激励不足
/斜率不可信，7 = 进不了电机模式。

⚠ **多轮取中位的语义**：整个 action 期间 `system.inertia_status` **一直是 1**；中间
某一轮失败**不会**把它写成失败码（编排会自动再跑一轮，最多 3 轮），只有整个动作结束
才发布最终结果 —— 2 = 成功（此时 `config.inertia` 是各成功轮的中位数），否则是最近
一次的失败码（`>2`），此时 `config.inertia` 保持原值（`action.measure_inertia` 打印
`keeping J = ...`）。单轮的结果码放在 `controller.inertia_run_code`（ISR 写，不对外
暴露），所以上位机只要"轮询到 `status != 1`"就是真的结束了。

诊断遥测（只读）：`telemetry.inertia_state`（状态机停在哪）、
`telemetry.inertia_break_current`（本轮认定的突破电流）、
`telemetry.inertia_accel_lo` / `inertia_accel_hi`（两个台阶各自拟合出的加速度）。
`J` 由 `(ī_hi − ī_lo)` 和 `(a_hi − a_lo)` 算出来，所以这两个加速度**必须明显不同**；
它们相等而 `status` 仍是 2，就说明读到的不是这一轮的数（旧镜像 / 烧录没成功，见
"烧录）。台架典型值（48 V、裸关节、GR 7.75、KT 0.125）：`break = 0.10 A`、
`a_lo ≈ 15.6`、`a_hi ≈ 37.3`、`J ≈ 0.0023 kg·m²`。

**为什么是两个同向台阶，而不是 ODrive 的 ±对称法**：模型是 `J·a = KT·GR·i − c`，
`c`（重力 + 库仑摩擦）是常值。两个同向台阶拟合出的斜率天然把 `c` 消掉；而 ±对称法
里库仑摩擦的方向随运动反向，相加抵不掉，会把 `J` 高估 —— 台架上摩擦占到力矩的
30% 时就是 30% 的增益偏差。

- 拟合只累计 5 个和（`ml_fit_t`），ISR 里不需要缓存样本。
- 结果**只写 RAM**，不会自动 `action.save`；`system.inertia_status` 报
  0 未跑 / 1 运行中 / 2 成功 / 3..7 失败原因。
- 打断路径：`zero_commands()`（超时、回菜单、故障）会把状态机复位成 IDLE 并置
  失败 —— 否则下次进电机模式会从半个台阶续跑，测出来的 J 是错的。
- 标定期间 `run_fsm` **跳过命令超时检查**（它自己就是命令来源），并且
  **跳过 `inertia_req` 待处理的周期**（否则 `zero_commands()` 会在
  `motion_control()` 采纳请求之前把它清掉 —— 这是实现时踩过的坑）。
- 前提：`KT > 0`、`GR > 0`（endpoint 的 `require` 就挡在这里）、关节能自由转
  一小段（净行程约 0.5 rad，3 轮合计）、齿隙已经消除。卡住/欠激励会返回失败码，不会写垃圾值。

**`ω_c` 的上限由延迟决定，不由惯量决定**：电流环 ≈40 µs + PLL（2000 rad/s）+
速度环零阶保持（125 µs）+ 采样 ≈ 0.3–1 ms ⇒ `ω_c` 超过约 1000 rad/s（160 Hz）
实际就是在跟延迟赛跑。

台架实测（2026-10-30，48 V，裸关节，`prescaler 5/2`，`pll_bandwidth 2000`）：

| 项目 | 实测 |
|---|---|
| 标定出的 `config.inertia` | **0.00206 / 0.00237 / 0.00289**（连续 3 次，均值 0.0024，离散 ±17%；重标电机后 0.00227，`break 0.10 A`、`a_lo 15.6`、`a_hi 37.3`） |
| 标定耗时 / 关节行程 | 3 轮约 3 s / 净行程 ~0.5 rad（旧版 2 rad/s 上限时单轮 ~1.3 s / 0.10 rad，但离散 ±50%） |
| `vel_gain = 3` | 稳定（`ω_c = 3·KT·GR/J ≈ 1100 rad/s`），超调 26% |
| `vel_gain = 4` | 失稳（`ω_c ≈ 1500 rad/s`） |

⇒ 反推出的延迟约 1 ms（含摩擦/齿隙造成的等效滞后），与 `vel_gain 3` 的 26% 超调吻合。
**注意这个台架是"小惯量 + 大摩擦"**：按公式 `vel_gain = J·ω_c/(KT·GR)` 取 `ω_c=450`
只有 1.15，实测却要到 3 才跟得上指令 —— 因为库仑摩擦把有效对象增益压低了，线性公式
给的是**惯性主导**时的值。所以用法是：**公式给起点（并用来卡 `ω_c` 上限），
`config.tune_margin` 补摩擦（≈2.6），`sweep` 给最终值**。

台架实测（2026-11-02，新板 + 新电机，48 V，裸关节，GR 7.75、11 极对、
`KT 0.0311`、`R 0.414 Ω`、`Ld/Lq 22.8/45.3 µH`、`i_max 3 A`、`prescaler 5/2`）：

| 项目 | 实测 |
|---|---|
| 惯量标定 | **0.000536 / 0.000563 / 0.000601 / 0.000612**（`break 0.15~0.20 A`）⇒ 取 0.0006。⚠ 5 次里有 3 次 `status=3`（上一次的残余摆动被"静止判定"挡下），重测前要等 1 s 以上 |
| MIT `kp=1.5` / `4` / `10` / `20`（`kd = 2√(kp·J)`） | 上升(90%) 126 / 56 / 43 / 30 ms；稳态误差 **17 / 3.0 / 0.1 / 0.1 mrad** ⇒ 摩擦死区 ≈ `T_fric/kp`，`kp` 小时误差明显 |
| MIT `kp=10, kd=0.155` | 43 ms 上升、55 ms 稳定、0.1 mrad、峰值 0.96 A ⇒ **推荐工作点** |
| CSV `vel_gain` 1 / 2 / 3 / 4 | P-only 误差 −12.5 / −7.2 / −4.7 / −3.9%；**4 开始过冲 128%**（≈极限环） |
| CSV `vel_gain 2.5 + vel_integrator_gain 30` | 1 / 10 / 40 rad/s 误差 −0.1 / −0.1 / −0.6%，纹波 ≤2.6%；40 rad/s 峰值 2.6 A（`i_max 3 A`） |
| CSV 60~65 rad/s | 也能跟（−0.3%/−0.7%），峰值 2.65 A ≈ `i_max` |
| CSP `pos_gain` 10 / 15 / 22.5 / 30 / 45（accel 10） | 0.2 rad 阶跃过冲 0.5 / 4.3 / 29 / 44 / 62% |
| CSP `pos_gain 15`（accel 50） | 0.2 rad：0.2%、0.26 s；1 rad：4.2%、0.34 s ⇒ **推荐工作点** |

⇒ 新板/新电机的结论与旧板一致（`tune_margin ≈ 2.2`、`ω_i ≈ 18 rad/s`），
但 `pos_gain` 的甜点从 `ω_c/20` 下移到 **`ω_c/30`**（两块板上 22.5 都会过冲）。
⚠ 两个坑：① `config.p_max`（默认 ±12.5 rad）会把 `p_des` **钳位而不是拒绝**，
反复跑 CSV 后位置会漂到边界，之后 CSP 看起来"完全不动"（`set config.p_max 0`
可临时关掉这个软限位，见 `motion_law.h` 的 `ml_pos_cmd_range()`）；② `accel_limit` 200
做 0→65 rad/s 的猛冲会偶发 `FAULT_OC` 锁存（`accel_limit 100` 正常），
而 `i_max` 已按新电机降到 3 A（OC 门限 = 1.5×`i_max` = 4.5 A）。

### 位置跟随误差故障

`config.pos_error_fault > 0` 时，位置环在**没有被 `v_limit` 饱和**的情况下，
`|pos_err|` 连续超过阈值 100 ms 就锁存 `FAULT_POS`（`foc.h`）→ FAULT_MODE 关栅，
需要显式回菜单才能清除。

只用“未饱和”判定的原因是：目标离得很远（上电对齐、长距离移动）时位置环本来就
会顶在速度上限上追，这时误差大是正常的。**因此阈值必须小于 `v_max / pos_gain`**，
否则该条件永远不成立（误差一到 `v_max/pos_gain` 就饱和了，计时被清零）。

**推荐值**：固件直接算好一个上限放在 `telemetry.pos_error_fault_suggest`：

```
e_recover = ½ · a_max · T²            a_max = KT·GR·I_MAX/J_out，T = 100 ms
e_limit   = ½ · v_max / pos_gain
suggest   = min(e_recover, e_limit)
```

`e_recover` 是"驱动器在 100 ms 内能把静止的关节拉回来多少"，`e_limit` 是"再大就
必然饱和"。惯量未标定时（`config.inertia = 0`）只用 `e_limit`。它给的是**上限**：
机械行程小的关节应取更小的值（例如行程的 1/4）。

上报：MIT 响应帧 `CB_ERR_CONTROLLER(0x3)`；`QUERY_ERROR` 的 `type=3/5`。


### 分频怎么选

- 默认 5 / 2（8 kHz / 4 kHz）。ODrive 在 12 kHz FOC 上用的是 2 / 4（6 kHz / 1.5 kHz），
  所以这个量级完全够用。
- 全部设 1（两个环都 40 kHz）可以作为“带宽上限”对照，用来判断限制来自
  增益还是来自采样。
- 速度环不要低于 ~1 kHz：外环的相位裕度会开始被零阶保持吃掉。
  `MOTION_PRESCALER_MAX = 100` 就是这条线的硬上限（40 kHz/100 = 400 Hz 是允许的
  边界）。
- 两个环都必须留在控制 ISR 里。放主循环（`run_fsm_slow`，1 ms + 抖动）会让
  速度环带宽掉到 10 Hz 量级。

### 台架测试脚本

`tools/csv_csp_test.py`（USB endpoint，不需要 CAN 主站；`--port COMx` 走 CDC，
`--usb` 走 vendor interface，后者往返更短）。**它自己负责命令租约刷新**——
`command.*` 的租约只有 `config.can_timeout`（默认 100 ms），用 `mc_ep.py set` 一条条
敲根本无法维持，测出来的“环路不工作”其实是保护动作。

| 子命令 | 作用 |
|---|---|
| `plain` | 进 MOTOR_MODE，用 MIT 律（`--kp/--kd`）顶住当前位置 → 重构回归 |
| `csv` | 速度阶跃 `0 → +v → 0 → −v → 0` |
| `csp` | 位置阶跃 `保持 → +step → 保持 → 回原位 → 保持` |
| `timeout` | 刷新 0.6 s 后停手，验证租约到期后确实卸力 |
| `sweep` | 扫 `config.vel_gain`（纯 P），打印稳态误差/超调，结束后恢复原值 |

```bash
python tools/csv_csp_test.py --port COM6 csv --vel 1.0 --log run.csv
```

- 三重中止闸：`telemetry.fault` 非 0、`|velocity_pll| > --abort-vel`（默认 3 rad/s）、
  `|pos_err| > --abort-pos-err`（默认 0.5 rad）。任一触发都立刻退出并在 `finally`
  里 `action.idle_mode` 关门极。
- `--min-bus`（默认 15 V）挡住“主电源没上电还以为环路坏了”的情况；
  `--allow-low-bus` 可以在无功率级时只验证逻辑/遥测（此时 `i_q_des` 会顶到限幅而
  `i_q_filt` 恒为 0，这是正常的）。
- `--log` 输出 UTF-8 CSV，可以直接画曲线。
- ⚠ 它会**真的转电机**；纯速度/位置环没有行程保护（除非开 `config.pos_error_fault`），
  调试时手放急停上。

`tools/cogging_test.py` 是齿槽补偿的专用工具（`status` / `calibrate` / `dump` /
`on` / `off` / `reset`），用法与判读见本文"齿槽转矩补偿"一节。

### 台架整定步骤

按下面顺序走，每一步都用上一节的脚本（它自带租约刷新与中止闸）：

```bash
# 0) 先看基线：MIT 律能不能顶住（kp/kd 走的是 CTRL_IMPEDANCE，不经过外环）
python tools/csv_csp_test.py --port COM6 plain --hold 2 --kp 20 --kd 1

# 1) 速度环 P：扫描 vel_gain（脚本内部把 vel_integrator_gain 临时置 0，结束后恢复）
python tools/csv_csp_test.py --port COM6 sweep --vel 1.0 --gains 1,2,3,4,6

# 2) 选定 vel_gain 后加积分，再跑一次完整阶跃看正反转
python tools/mc_ep.py --port COM6 set config.vel_integrator_gain 10
python tools/csv_csp_test.py --port COM6 csv --vel 1.0 --hold 0.8 --move 2.5 --log csv.csv

# 3) 位置环：从 ω_c/20 起试（台架上 ω_c/5 会因齿隙/摩擦过冲，见"惯量标定"一节）
python tools/mc_ep.py --port COM6 set config.pos_gain 22
python tools/csv_csp_test.py --port COM6 csp --step 0.2 --hold 1.2 --move 2.0 --log csp.csv

# 4) 惯量标定 —— 一条指令，自动进出电机模式（结束自动回菜单）
python tools/mc_ep.py --port COM6 call action.measure_inertia
python tools/mc_ep.py --port COM6 get system.inertia_status     # 1 运行中 / 2 成功 / 3..7 失败原因
python tools/mc_ep.py --port COM6 get config.inertia            # kg·m^2（只写 RAM，未保存）
python tools/mc_ep.py --port COM6 get telemetry.pos_error_fault_suggest

# 5) 由惯量算三个增益（只写 RAM；不满意就改 omega_c / tune_margin 重算）
python tools/mc_ep.py --port COM6 set config.omega_c 450
python tools/mc_ep.py --port COM6 set config.tune_margin 2.6     # 摩擦主导的关节从 2~3 起试
python tools/mc_ep.py --port COM6 call action.tune_gains
python tools/mc_ep.py --port COM6 get config.vel_gain            # 确认写进去了
python tools/csv_csp_test.py --port COM6 csv --vel 1.0           # 验证
python tools/csv_csp_test.py --port COM6 csp --step 0.2
python tools/mc_ep.py --port COM6 call action.save               # 满意后再保存
```

`action.tune_gains` 的输入只有 `config.inertia`、`config.omega_c`、
`config.tune_margin`（公式见"惯量标定与增益推荐值"），`ω_c` 取 300–600 rad/s
起步（上限由延迟预算决定）。**摩擦主导的台架实测需要 `tune_margin ≈ 2.6`** ——
公式给起点、margin 补摩擦、`sweep` 给最终值。标定/整定结果**都不会自动保存**。
```

判读方法：

| 现象 | 含义 | 动作 |
|---|---|---|
| `sweep` 的 `err%` 很大（>20%） | 该增益下力矩不足以克服摩擦 | 加大 `vel_gain`，或靠积分补 |
| `sweep` 的 `overshoot%` > 30% 或出现 `UNSTABLE` | 相位裕度不足（延迟/惯量） | 用该增益的 1/2.5 作为工作点 |
| `vel_integral` 持续爬升不收敛 | 积分太强或机械卡住 | 降 `vel_integrator_gain`，查机构 |
| CSP `|pos_err|max` 收敛但末端有极限环 | 低速干摩擦 + 量化（机械层面） | 开 `pos_error_fault`，或加大 `accel_limit` 平滑 |
| `i_q_des` 顶在限幅而速度不动 | 电压/电流不足或堵转 | 查母线、`config.i_max`、机械 |

**实机参考数据**（2026-10-30，48 V，裸关节：低惯量 + 干摩擦，GR 7.75、
KT 0.123 N·m/A）：

| `vel_gain`（纯 P，1.0 rad/s 阶跃） | 结果 |
|---|---|
| 1 | 稳定，稳态 ≈0.73 rad/s（−27%） |
| 2 | 稳定，稳态 ≈0.86–0.90，有超调 |
| 3 | 稳定 |
| 4 / 6 | **失稳**：速度冲到 3.6+ rad/s、电流限幅 |

该台架上 `vel_gain 2` + `vel_integrator_gain 10` 把稳态误差压到 −5…−9%，
`pos_gain 2` 的 0.2 rad 阶跃超调 12%、静止误差 2–3 mrad。
（这张表是旧电机 KT 0.123、J 0.0023 的数据；新电机见"惯量标定与增益推荐值"
里的 2026-11-02 表，出厂值按新电机定。）

**编码器 PLL 的真机校验**（用精确整数位置差分当参考，同区间均值）：
PLL 误差 ≤4%，19 点差分 9–16%。这也解释了为什么外环必须用 PLL：低速时差分
只有 ±1 LSB 的台阶（输出轴 0.026 rad/s/bit）。

### ISR 预算判据

改动前后各读一次：

| 端点 | 判据 |
|---|---|
| `timing.overrun` | 必须保持 0 |
| `timing.period_max` | < 0.6 × `timing.isr_period`（6000 cycles） |
| `timing.seg_fsm_max` | 外环更新那拍会变高；对比 1/1 与 5/2 两种配置 |

## 齿槽转矩补偿（anti-cogging）

齿槽力矩是转子磁钢与定子齿相互作用产生的、随**转子机械位置**周期变化的力矩
脉动。它在低速时表现为速度波动/爬行，在位置保持时表现为周期性误差。补偿方式
是**前馈**：按转子位置查一张"需要的 i_q"表，直接加在 `i_q_des` 上。

代码分两层：

| 文件 | 内容 |
|---|---|
| `Core/Inc/cogging_law.h` | 纯数学：定点量化、Catmull-Rom 插值、两遍合并、去均值、RMS。host 可测（`tools/test_cogging.c`） |
| `Core/Src/cogging.c` | 标定状态机 + 运行时前馈 + 主循环的合并/质检 |

### 表

- `COG_N = 1024` 个点，覆盖**一个转子机械周期**（= 编码器一整圈 65536 计数，
  每点 64 计数），`int16` 定点，`COG_SCALE = 4096` counts/A（±8 A、0.244 mA）。
- 索引用**编码器原始计数** `encoder->count`（线性化后、未减 `M_ZERO`），所以
  `action.zero` 改机械零点不会让表失效；换编码器/重新标定编码器才会。
- 为什么按转子而不按输出轴：齿槽基波是 `1/LCM(槽数, 2·极对数)` 个机械周期，
  比输出轴快 GR 倍。按输出轴做表要么把高次谐波丢掉，要么表长乘 GR。
- 台架实测（本机 24 槽 / 22 极，GR=9）：有效成分在 **11/22/24/33/44/48/66/72/88/120
  次/转**，最大是 22 次（0.049 A）和 24 次（0.044 A）；132/264 次只有 0.003 A 以下。
  表 RMS 0.052 A、峰值 0.13 A。所以 1024 点足够（最关心的 22~24 次有 40+ 点/周期）。
- 插值用 Catmull-Rom（4 点三次）：线性插值在 12 点/周期时会削 3% 以上幅值，
  三次插值误差 <1%，代价只有几次乘加。
- 存储：`internal.cogging_lut`（`hidden` blob，2048 B，进 TLV 但不进设备描述符）。
  `PREFS_MAX_VALUE` 因此从 512 提到 4096。payload 是 3536 B / 4096（records 82），
  再加参数前先跑 `make endpoints` 看容量检查。

### 标定（`action.cogging_calibrate`）

自动进 `MOTOR_MODE`；`motion_control()` 里 `cogging_cal_step()` 接管控制权
（与惯量标定同构，外环分频/整形/故障判定都不参与）。标定用的就是**用户自己的
外环增益**（`pos_gain`/`vel_gain`/`vel_integrator_gain`），所以先 `action.tune_gains`。

两种方法由 `config.cogging_method` 选：

**1. `COG_METHOD_SWEEP = 1`（默认，推荐）** —— 匀速扫两圈，约 `2 × cogging_sweep_ms`

1. 位置目标做**匀速斜坡**（`rate = 2π/(GR·sweep_ms)`），先正转一个转子圈、再反转
   一圈，用位置 P + 速度 PI（`cog_hold()`）跟踪；
2. 每拍把速度环输出（P+I，即"维持这个速度所需的全部 i_q"）按**转子位置**分箱
   累加到 1024 格里（每圈每格 150~160 个样本）；
3. 分箱前先过**两级 90 Hz 一阶低通**：台架实测噪声集中在速度环穿越频率（~100 Hz）
   附近、幅值可达 0.1 A，正好落在表的高空间频率上；齿槽只有 3~15 Hz，两级低通对
   它是 0.9、对振铃是 0.3。低通在正反两遍里引入的相位滞后符号相反，平均时抵消；
4. 换向前后各丢掉 0.25 s 过渡；两遍**各自**去均值 + 多项式去趋势后取平均。

为什么这样比"逐点停住"好：匀速时是**动摩擦**（常值，正反两遍符号相反，去均值 +
平均后抵消），几乎没有静摩擦的粘滞误差；而且一圈 4~16 s 就把 1024 个点各平均了
150 次以上。

**2. `COG_METHOD_HOLD = 0`（保留，不推荐）** —— 逐点停住

逐点把转子保持住、读速度环积分器，测的是纯静态力矩。缺点是慢（台架 564 s）
且每点都被静摩擦污染：实测两遍差异 0.021 A（信号 0.052 A 的 40%）。它的
**幅值本身是对的**（0.052 A，与 sweep 法一致）。

⚠ 早期版本的 hold 法有一个坐标系 bug：`cog_record()` 用"从起点数起的点号"当表
索引，而表是按**绝对计数**存的，于是整张表被旋转了一个随机的 `k0` 格（`k0` 是
标定开始时转子的位置）。质检看不出来（两遍比的是同一套旋转坐标），但补偿的相位
全错 —— 这是台架上 hold 法"补偿无效"的直接原因。现在两种方法都用
`cog_bin_of_count()`/`start_bin` 这同一套约定，`tools/test_cogging.c` 里有专门的
回归测试（从任意起点 `c0` 出发，第 i 个点必须落在 `(bin(c0)+i) mod COG_N`）。

**后处理**（主循环 `cogging_publish_result()`）：

- 每遍去均值（去掉重力/平均摩擦的直流）+ 多项式去趋势。**为什么要去趋势**：
  正反两遍抵消不了重力（它对两遍是同一个方向）。重力随输出轴角度变化，而一个
  转子圈只走 `2π/GR` 的输出角（本机 40°），在表里是一条慢变趋势；三次多项式就能
  拟合掉（残差是四次项，约 1%），而齿槽是 20~120 次/转，三次多项式表达不出来。
  `config.cogging_detrend` 是阶数（默认 3；直接驱动 GR=1 用 5~6；确认无外载可设 0）。
- 两遍取平均 → 坏点用相邻有效点插值 → 再整体去均值/去趋势 → 量化；
- 质检：坏点 > 1/4、或两遍 RMS 差异 > 0.5×信号 + 5 mA → 判失败，**旧表保持原样，
  但补偿被停用**（`cogging_valid = 0`）；
- 成功才置 `config.cogging_valid = 1`。**不自动保存**，也**不自动打开**
  `config.cogging_en`。

台架实测（2026-11-07，48 V，空载）：

| `cogging_sweep_ms` | 两遍差异 (A) | 表 RMS (A) |
|---|---|---|
| 2000 | 0.243 | 0.123 |
| 4000 | 0.111 | 0.079 |
| 8000（默认，加 90 Hz 低通） | **0.025** | **0.052** |
| 16000 | 0.032 | 0.055 |

（未加低通时 8000 是 0.043；16000 那一轮没有低通数据。差异随扫描时间下降，
说明残余噪声是速度环振铃、被每格的样本平均掉的。）

**验证**（同一张表，匀速 0.175 输出 rad/s，按转子角分箱比较补偿开/关）：

| 阶次 | 速度纹波 关 → 开 | 变化 |
|---|---|---|
| 22 | 2.76 → 0.28 mrad/s | **−90%** |
| 24 | 2.31 → 0.67 | **−71%** |
| 44 | 1.96 → 0.57 | **−71%** |
| 72 | 0.92 → 0.14 | **−84%** |
| 66 | 1.07 → 0.87 | −18%（该轮本身的噪声就大） |
| 总 RMS | 12.1 → 12.2 mrad/s | ±0 |

总 RMS 不变是因为**剩下的纹波不是齿槽**：同一速度下把 `velocity_pll` 按转子角
分频，能量分布是 1–10 阶 0.0044、11–40 阶 0.0036、41–100 阶 0.0049、
101–200 阶 0.0062、201–350 阶 0.0076、**351–511 阶 0.0089 mrad/s**（总 0.0108），
另外还有一个明显的 **4 阶**分量（0.005 mrad/s）。也就是说本机低速纹波主要是
速度估计/速度环的宽带振铃（高空间频率）和 4 次/转的机械/编码器成分，齿槽只占
一小部分。判据一定要看**阶次**，不要只看总 RMS；想继续降纹波要去查编码器/速度
估计，而不是加长齿槽表。

### 运行时

`fsm.c` 的 ISR 链里，`cogging_apply()` 紧跟 `motion_control()`、**在
`field_weaken()` 之前**：查一次表（4 点三次插值）、乘 `cogging_gain`、钳到
`cogging_max`，加到 `i_q_des`。之后弱磁和 `commutate()` 的 `limit_norm` 仍按原
顺序收尾，所以补偿永远不可能绕过电流/电压限幅。标定期间它自己什么都不做。
`telemetry.cogging_ff` 是本拍实际叠加的量；`system.cogging_amp` 在表从 flash
读回后会按需重算一次。

`zero_commands()` 会调 `cogging_abort()`：离开电机模式、故障、CAN 超时都会把
标定停在 IDLE，不会下次进电机模式"续跑"。

### 台架

```bash
python tools/cogging_test.py --port COM10 status       # 状态/幅值/是否启用
python tools/cogging_test.py --port COM10 calibrate    # 约 2~4 分钟，进度每 256 点一行
python tools/cogging_test.py --port COM10 dump --csv cog.csv   # 读表 + 主要谐波
python tools/cogging_test.py --port COM10 on           # 打开补偿（RAM）
# 低速 CSV 走一段（tools/csv_csp_test.py）比较打开前后的速度波动，再决定 action.save
```

判读：

- `system.cogging_amp`：本机（22 极、行星减速）实测 0.052 A RMS、峰值 0.13 A。
  接近 0 说明电机齿槽确实很弱，或者转子根本没动（检查 `system.cogging_bad`）。
  有重力负载的关节会混进重力矩的残余趋势，`cogging_amp` 会偏大（去趋势阶数不够
  时可以调大 `config.cogging_detrend`，直到 `dump` 的 1~3 阶谱几乎为 0）。
- `system.cogging_mismatch` 与 `amp` 同量级 ⇒ 重复性差：扫描太快
  （`cogging_sweep_ms` 太小）、外环增益不对、标定期间有人碰了关节，或编码器丢帧。
  台架参考：本机 8000 ms 时 0.025 A（信号 0.052 A）。
- `dump` 的前几个谐波应该落在极对数（22 极 → 11、22、33…）和槽数（24、48、72…）
  的倍数上。落在别处（尤其 350 阶以上）说明表被噪声污染。
- `telemetry.cogging_pass1/2`（配合 `config.cogging_index`）能逐点对比正反两遍的
  原始测量，是排查重复性问题最直接的入口。

⚠ 与 ODrive 的差别：ODrive 默认 3600 点/圈、**逐点停住**、单遍扫描、减一次均值；
我们是 1024 点/圈 + 三次插值 + **匀速扫描正反两遍**（台架上逐点停住会被静摩擦
污染，见上）。没有做谐波模式与 LMS 在线自适应（ISR 里每拍算十几个谐波的正弦
代价太高），需要时按"变更规则"另开。

## endpoint 协议

与 ODrive fibre v0.1 同构，三条传输共用同一份参数表，但外层不同
（USB 的两条共用 `endpoint_process()` 的 payload 编解码）：

| 传输 | 端点 | 外层 | 实现 |
|---|---|---|---|
| CAN（CYBERBEAST SDO） | 29-bit 扩展帧 | `PARAM_READ(0x20)` / `PARAM_WRITE(0x21)` + 描述符 `0x24/0x25`，**没有 status 字节**（见 "CAN：协议选择与 CYBERBEAST"） | `can_cyberbeast.c` |
| CDC 虚拟串口 | EP1 IN / EP3 OUT | `AA` + `LEN` + `CRC8` + payload + `CRC16`（和 ASCII 菜单共用数据流） | `endpoint_serial.c` |
| vendor interface 2（fibre） | EP3 IN / EP1 OUT | 一个 USB bulk 包 = 一个 PAYLOAD（无外层、无 CRC） | `endpoint_usb.c` |

**出货的板子没有 USB 座，客户只有 CAN 这一条路**（`mc_ep.py --can`），
USB 的两条是开发/台架用的。

CAN 那条直接调 `endpoint_handler()`，不经过 `endpoint_process()`：因此没有
描述符 CRC 的版本校验（描述符要自己用 `0x24/0x25` 拉一遍），也**没有状态码** ——
只写端点/`require` 不满足/被限幅，写 ACK 一律照常返回，主站必须读回校验。

USB 描述符是复合设备：interface 0/1 是 CDC（`bDeviceClass=0xEF` + IAD），
interface 2 是 vendor specific（EP1 OUT / EP3 IN），见
`Core/Src/usb_desc.c`、`usb_conf.h` 的 PMA 布局。CDC 的端点分配和以前完全一样。

> **不是 odrivetool 的线上协议**：本固件保留 `EP_REQ_WRITE`（bit14）显式区分
> 读写、响应多一个 `status` 字节、endpoint 0 的版本探测是 `[crc][len]`。标量
> 端点严格区分读写；动作端点（线上 `"type":"function"`）**读和写都会执行**——
> ODrive 的协议没有读写位，function 端点被“读”也会执行，这里跟随它，好让
> 按 ODrive 语义调用动作的上位机（JointSDK）直接可用。
> 上位机请用 `tools/mc_ep.py`（`--can`，或开发板上的 `--port`/`--usb`）。

### CDC 帧

```
AA | LEN | CRC8 | PAYLOAD[LEN] | CRC16_HI CRC16_LO
```

- `LEN`：payload 长度，1..64。
- CRC8 对 `AA, LEN`；CRC16 对 payload，**高字节在前**。
- CRC8 多项式 `0x37` / 初值 `0x42`；CRC16 `0x3D65` / `0x1337`（MSB-first、
  无反射、无最终异或），与 ODrive `crc.hpp` 逐位一致。

### 请求 payload

```
seq(2) | id|flags(2) | rxlen(2) | tx_data... | trailer(2)
```

- `id|flags`：bit15 `EP_REQ_REPLY`（必须置位，不置位设备丢弃请求）；
  bit14 `EP_REQ_WRITE`（写/执行；不置位是读）；低 14 位是 ID。
- `rxlen`：主机希望的返回字节数（超出被截断）。
- `trailer`：endpoint 0 是 `EP_PROTOCOL_VERSION`（2），其它是描述符 CRC16
  （每次改参数表都会变）。
- 一次只有一个未完成请求。CDC 是字节流：`req_pending` 未清时新帧被丢弃；
  vendor interface 有 USB 流控：收到后端点保持 NAK，主循环处理完再 arm，
  请求不会丢。
- vendor 传输的响应 ≤ 63 字节（短包），主机一次 64 字节 bulk 读即可收全。

### 响应

```
seq|0x8000(2) | status(1) | data...
```

| 状态 | 含义 |
|---|---|
| 0 `EP_OK` | 成功 |
| 1 `EP_ERR_UNKNOWN_ID` | 没有这个 endpoint |
| 2 `EP_ERR_BAD_LEN` | 长度不够/缓冲区太小 |
| 3 `EP_ERR_BAD_VALUE` | NaN / 无法表示 |
| 4 `EP_ERR_READ_ONLY` | 写了 `r` 端点 |
| 5 `EP_ERR_WRITE_ONLY` | 读了只写标量端点（动作端点不再返回它） |
| 6 `EP_ERR_STATE` | 状态不允许（如门极使能时保存） |
| 7 `EP_ERR_VERSION` | 描述符 CRC 不匹配，主机应重新下载 |

### 读 / 写

**由传输层显式给出**：USB 用 bit14，CyberBeast CAN 用 `0x20`/`0x21` 操作码。
生成的 handler 按 `access` 统一校验：`r` 拒绝写、`w` 拒绝读、`rw` 写后回读新值。

**动作端点例外**：`action.*`（线上描述符 `"type":"function"`）不看 op——读和写
都执行。ODrive 的 endpoint 协议没有读写标志，`endpoint_handler()` 对 function
端点无论从哪个方向进来都会调用它，JointSDK 也按 `PARAM_READ(0x20)` 调动作。
所以 `PARAM_READ` 一个 `action.*` 会真的执行它（返回值 0 字节），危险动作由
`require` 门禁兜底；上位机遍历参数时应跳过 `function` 类型（`mc_ep.py dump`
就是这么做的）。

### USB 复合设备与实时性

```
interface 0 (CDC comm, EP2 IN 通知)
interface 1 (CDC data, EP3 OUT / EP1 IN)     <- 和以前完全一样，ASCII 菜单 + 0xAA 帧
interface 2 (vendor,    EP1 OUT / EP3 IN)    <- fibre：一个 USB 包 = 一帧
```

- `usb_conf.h` 的 PMA 布局（地址单位是 2 字节）：EP1 TX `0xC0`、EP2 TX `0x100`、
  EP3 RX `0x110`、EP1 RX `0x150`、EP3 TX `0x190`；最后一块到字节 `0x360`，
  在 1 KB 包内存以内。
- **FOC 不受影响**是有意的设计：USB 中断（优先级 2，低于控制 ISR 的 0）只做
  一次 ≤64 B 的 `USB_CopyPMAToUserBuf()` + 置标志，然后让端点保持 NAK；
  CRC / 描述符下载 / handler / 应答全在主循环的 `endpoint_usb_poll()`。
  USB 流控替代了软件队列，主机不会因为主循环繁忙而丢请求。
- 响应上限 63 字节：64 字节整包不会产生“短包”，主机的 bulk 读会继续等下一包。

Windows 上 vendor interface 需要 **Zadig** 给 interface 2 装 WinUSB **或
libusb-win32**（两者都验证可用；CDC 的两个 interface 仍由 `usbser` 占用，
不需要重装驱动）；Linux 需要 udev 权限；macOS 直接可用。上位机：

```bash
pip install pyusb libusb-package
python tools/mc_ep.py --usb tree
python tools/mc_ep.py --usb get telemetry.i_q
```

2026-11-04 台架（Keil 镜像，电机空闲）：vendor interface 连续读 `telemetry.i_q`
约 3 kHz（两参数交替约 6 k 次事务/秒），期间 `telemetry.loop_count` 仍是
39,990 Hz、`timing.overrun` 保持 0、`timing.period_max`/`total_max` 不变、
`encoder_lost_frames` 不增长；CDC 与 vendor interface 两个线程同时收发也没有
互相干扰。

### endpoint 0（描述符）

`tx_data` 是 `u32` 小端偏移：`0xFFFFFFFF` 返回 `[crc u16][len u16]`；其它偏移
返回从该处开始的一段（长度由 `rxlen` 决定，`mc_ep.py` 用 60）。

描述符是纯 ASCII JSON 数组。约束（改 `descriptor_json()` 时别破坏）：

- 不能出现 `\uXXXX`（JointSDK 的轻量解析器不支持）；
- 类型名用 `bool/uint8/int8/uint16/int16/uint32/int32/uint64/int64/float/double/
  object/endpoint_ref/json/function`；
- 动作端点写 `"type":"function"` + 空 `inputs`/`outputs`，**不能写 `void`**；
- 总长 ≤ 65535（当前约 20.1 KB）。

例子（读 `config.i_max`，ID 2）：

```
payload = 01 00 | 02 80 | 04 00 | 56 34
frame   = AA 08 <crc8> 01 00 02 80 04 00 56 34 <crc16_hi> <crc16_lo>
```

写 `action.save`（ID 71）：

```
payload = 03 00 | 47 40 | 00 00 | 56 34      ; 0x4047 = 71 | EP_REQ_WRITE
```

读 `action.save` 也会执行它（ODrive 兼容，见上文“动作端点例外”）：

```
payload = 03 00 | 47 00 | 00 00 | 56 34      ; 0x0047 = 71（不置 EP_REQ_WRITE）
```

动作端点里与运维相关的两个（都只置标志，真正的工作在 `run_fsm_slow()`）：

| 端点 | ID | 行为 |
|---|---|---|
| `action.reboot` | 127 | `state.reboot_pending = 1` → 先 `request_fsm_state(MENU_MODE)`（关栅），0.5 s 后（`REBOOT_DELAY_CYCLES`）`NVIC_SystemReset()`。**不动 `_reboot_cookie`**：正常启动后它本来就是 42，而 `main.c` 的 `!= 42 → 再复位一次` 是"启动状态不确定"的保险，不该由这里关掉。没保存的改动会丢 |
| `action.enter_dfu_mode` | 180 | `state.dfu_pending = 1` → 与 `action.reboot` 同一条延迟复位路径（共用 `reboot_armed/reboot_deadline`，用 `reboot_mode` 区分），但复位前把 `_reboot_cookie` 写成 **`0xDEADBEEF`**，`early_start_checks()` 会先延时 ~2 s 再 `Jump_To_BOOT()` —— 与串口菜单的 `d`（`DFU_CMD`）完全同义。`require` 要求门极关闭；**handler 里不能直接复位**，否则应答发不出去 |
| `action.enter_bootloader_mode` | 242 | `state.bootloader_pending = 1` → 同一条延迟复位路径，但 cookie 写成 **`BOOTLOADER_MAGIC_VALUE`（`0xB00710AD`）**，`0x08000000` 的 OpenBootloader 看到后停在升级模式（CAN 500 kbit/s、Classic、握手 ID `0x128`）。与菜单 `b`（`BOOTLOADER_CMD`）同义；`require` 要求门极关闭 |
| `action.reset_config` | 126 | `state.reset_config_pending = 1` → `config_apply_defaults()` + `config_apply_limits()` + `save_preferences()`，**保存成功后自动 `reboot_pending = 1`**（`CAN_ID/CAN_PROT/CAN_BAUD` 是运行期读取的，改了不重启会让主站失联，而且 `config.*` 与 `comm_encoder.*` 会处于混合状态）；`require` 要求门极关闭（否则端点返回 `EP_ERR_STATE=6`），主循环里再加一道 `save_status = 2` 兜底。写 flash 失败时**不**重启 |

**`action.encoder_mode`(77) / `action.setup_mode`(78) 已退役**：固件不再提供它们
（串口菜单里的 `e`/`s` 入口仍然保留）。按“ID 只增不改”的规则，这两个 ID 仍在
`tools/endpoint_ids.json` 的 map 里占位，**永远不要重新分配给别的参数**；新动作取
126/127。

**`system.version`(68) 已删除**：版本号改用 `system.fw_version_major/minor/revision/
unreleased`（`main.h` 的 `FW_VERSION_*` 是唯一真源，不再维护 float 版本号）。
ID 68 同样保留空号，**不要复用**；`tools/cb_bench.py` 已改为读 187/188/189。

**一次性例外**：`action.enter_menu` 曾原地改名为 `action.idle_mode` 但**保留 ID 73**
（工程尚未交付客户，不欠外部兼容）。今后再改名必须走"新名字 = 新 ID，旧 ID 留空号"。

`action.*` 会写 `system.save_status` 的路径共有四条（`action.save`、`action.zero`、
`action.reset_config`、标定完成、setup 退出），它的含义是"最近一次写 flash 的结果"。

### command.*（运行命令）

五个 `command.*` 端点直接写 `controller.t_ff/p_des/v_des/kp/kd`，**不持久化**，
描述符里也不给 `min`/`max`（`range_dynamic: true`：真实范围由 `config.i_max/kt/gr/
p_max/v_max/kp_max/kd_max` 在运行期决定，写死一个数字会让上位机按错范围缩放）。

两条必须保持的语义：

- **写入会刷新命令租约**（`"set": "... = v; controller.timeout = 0;"`）。CAN 帧一直是
  这么做的；endpoint 必须一致，否则默认 `config.can_timeout = 100 ms` 一到，
  `run_fsm` 的 MOTOR_MODE 分支就会 `zero_commands()`，USB 写进去的力矩活不过 100 ms。
  刷新的好处是"主机掉线 ⇒ 自动卸力"。**不要靠把 `can_timeout` 置 0 来绕过**，
  那等于永久关掉失效保护（而且会被 `action.save` 存进 flash）。
- **进入 MOTOR_MODE 先 `zero_commands()`**（`fsm_enter_state`）。`command.*` 在任何
  状态都能写，若不在使能前清零，空闲态设的 `t_ff` 会在门极打开的第一拍生效。

## params.json 与代码生成

`params.json`（仓库根）是唯一真源：endpoint、描述符、持久化表、默认值、限幅、
参数手册都由它生成。生成物提交进仓库，使固件构建不依赖 Python。

| 文件 | 作用 |
|---|---|
| `params.json` | 参数/遥测/动作定义 |
| `tools/endpoint_ids.json` | 名字 → 16 位 ID 的永久注册表 + `next_id` |
| `tools/gen_endpoints.py` | 生成器（`--check` 只校验） |
| `Core/{Inc,Src}/endpoint_defs.*` | ID 枚举、描述符、handler |
| `Core/{Inc,Src}/prefs_defs.*` | 持久化表、默认值、限幅 |
| `docs/parameters.md` | 参数手册 |

字段：

| 字段 | 说明 |
|---|---|
| `name` | 点分小写；第一段决定分组（`config/telemetry/timing/system/action`） |
| `type` | `bool/int8/uint8/int16/uint16/int32/uint32/float/void/blob` |
| `access` | `r` / `w` / `rw` |
| `ref` | 可赋值的 C 左值（写路径） |
| `get` | 读取表达式（`rw` 可同时给 `get` 和 `ref`） |
| `set` | 写入语句，`v` 是已校验/限幅的值；缺省 `ref = v;` |
| `call` | 动作语句，只能置标志/写变量 |
| `require` | 为假时 `EP_ERR_STATE`；支持以 `!` 开头 |
| `min`/`max` | 描述符范围 + 限幅依据 |
| `min_expr`/`max_expr` | C 侧限幅用宏（如 `I_MAX_LIMIT`、`P_MIN`），避免两处数字漂移 |
| `range_dynamic` | 真实范围由固件宏/用户配置在运行期决定 → **不发** `min`/`max` 给上位机（仍用它们做 C 限幅）；生成器要求同时有 `min/max` 和 `*_expr` |
| `unit`/`brief` | 只进文档/描述符。**`brief` 是中文字符串，不进线上描述符** |
| `persist`/`default` | 进持久化表；`default` 必填（擦除芯片时用） |
| `hidden` | 不进描述符/handler，只进持久化表（编码器 LUT） |
| `size`/`assert` | blob 字节数；`assert` 生成 `_Static_assert` 绑死尺寸 |

ID 规则：**只增不改、永不复用**。改名 = 新增（旧 ID 留空号）；改单位/含义 =
新 ID + 迁移。新增条目时 `make endpoints` 自动分配 `next_id` 并回写注册表。

生成器还会校验：

- 类型/access 合法、`void` 有 `call`、可读/可写端点有 `get`/`ref`；
- `persist` 必须有 `ref` 和 `default`；
- **容量**（从 `prefs_codec.h` 读上限）：单条 ≤512 B、总载荷 ≤4096 B、条数 ≤256；
- 每个生成的 `case` 必须 `return`（防止 fall through 到下个端点）。

命令：

```bash
make endpoints   # 重新生成
make check       # 校验生成物（提交前/CI）
make hosttest    # 主机单测（prefs_codec）
make             # 编译
```

Windows 默认 `PYTHON=py -3`，其它平台 `python3`；可 `make check PYTHON=...` 覆盖。

`call`/`set` 里**不能** printf、写 flash、等 DMA。需要延后做的事只置标志：
`state.save_pending = 1;`、`state.zero_pending = 1;`、
`request_fsm_state(&state, MOTOR_MODE);`（带临界区；不要从 handler 直接调
`update_fsm()`，那是串口输入路径）。

## 配置持久化

`prefs_codec.c`（纯逻辑，可主机测试）+ `preference_writer.c`（flash）。

### 为什么不用裸数组

旧格式是 `int[256] + float[64]` 整块 + `CONFIG_VERSION` 相等判断：数组下标就是
语义，加/删/重排一个参数所有值错位，版本不等就整体丢弃。现在记录以 **endpoint
ID** 为 key，与 RAM 布局解耦。

### 块格式

两页各 8 KB，每页最多一个块。

头（20 B，小端）：`magic 'PCFG'`(u32) | `schema`(u16) | `flags`(u16) |
`sequence`(u32) | `payload_len`(u16) | `record_count`(u16) | `crc32`(u32)。

CRC 是 **CRC-32/MPEG-2**（`0x04C11DB7`，初值 `0xFFFFFFFF`，不反射、无最终异或），
覆盖 header[0..15] + payload。

记录：

```
id u16 | type u8 | flags u8 | len u16 | reserved u16 | value[len] | padding
```

`id` 与 `endpoint_ids.json` 同一命名空间；`len` ≤ 512；值小端、4 字节对齐。

### 保存

1. 开中断状态下把 RAM 序列化成 TLV，并把旧块里"当前固件不认识"的记录原样追加
   （未知记录透传）。
2. `__disable_irq()`：擦非活动页 → 按 8 字节 double-word 编程（每 8 字节 kick
   IWDG）→ 校验 magic/schema/CRC/序号。
3. 通过才切换 `active_sector`；失败保留旧页并返回 0。

掉电最多丢"这一次保存"；关中断是必须的（见"架构与不变式"）。

### 加载

`main.c`：`config_apply_defaults()` → `preference_writer_load()` →
`config_apply_limits()`。两页都有效取序号大的；记录匹配要求 **ID + type + len
全等**，不会把 `int32` memcpy 到 `float`；缺记录保持默认值。

### 变更策略

| 变更 | 做法 | 升级后 |
|---|---|---|
| 新增参数 | 加 `persist` + `default` | 用默认值，其余不动 |
| 删除参数 | 直接删 | 旧记录透传保留；恢复同 ID 能拿回旧值 |
| 改名 | 新名字新 ID | 旧值留在旧 ID 下 |
| 改单位/含义 | 新 ID + `PREFS_SCHEMA` +1 + 迁移 | 迁移函数换算 |
| 改 C 类型/长度（同 ID） | **不要** | 该参数静默回默认值 |
| 改块布局/编码 | `PREFS_SCHEMA` +1 | 见下 |

迁移：`PREFS_SCHEMA` +1 → `prefs_block_valid()` 本来会拒旧块。做法是让它**继续接受**
上一个 schema（`PREFS_SCHEMA_V1`），再在 `preference_writer_load()` 里用
`prefs_block_schema()` 辨认版本、就地做一次性换算。这样旧配置（含编码器 LUT/标定）
不会丢；换算只发生在 RAM，下次保存写出的块已经是新 schema（**不要**在加载后再
“顺手再存一次”——那会在开机时擦写 flash）。

已有迁移：**schema 1 → 2**——`config.can_timeout` 的单位从「控制周期（25 µs）」
改成**毫秒**（`prefs_v1_cycles_to_ms()`，40 控制周期 = 1 ms，四舍五入，0 仍是关闭）。
新默认值 100 ms（旧默认 1000 周期 = 25 ms）。

容量：单条 512 B、总载荷 4096 B、记录 256 条。`internal.encoder_lut` 是 512 B，
`prefs_defs.c` 里的 `_Static_assert(N_LUT * sizeof(int) == 512)` 会在改 `N_LUT`
时编译失败——同时改 `params.json` 的 `size`。

主机测试：`make hosttest`（往返、缺记录默认值、未知记录透传、512 B blob、
CRC/schema 拒绝、空表拒绝、`old_block == out` 别名拒绝、容量失败、
schema 1→2 单位迁移与降级块仍可读）。

## Flash 布局与 OTA 契约

**这是"OTA 后配置/标定还在"的唯一硬前提。**

| 区域 | 地址 | 大小 |
|---|---|---|
| OpenBootloader | `0x08000000` – `0x08007FFF` | 32 KB (`0x8000`)，不在本镜像里 |
| App | `0x08008000` – `0x0807BFFF` | 464 KB (`0x74000`) |
| 配置页 A | `0x0807C000` – `0x0807DFFF` | 8 KB |
| 配置页 B | `0x0807E000` – `0x0807FFFF` | 8 KB |

链接器强制：`N32H473CE_FLASH.ld` 的 `ORIGIN = 0x08008000, LENGTH = 0x74000`。
镜像超了直接报错。
向量表偏移 `VECT_TAB_OFFSET = 0x8000`（`Core/Src/system_n32h47x_48x.c`）必须跟着改——
三处不一致的表现是"能启动、但所有中断按 bootloader 的向量表分发"。

bootloader 契约（bootloader 是独立仓库 OpenBootloader 的固件，App 链接在 `0x08008000`）：

1. **只擦/写 `0x08008000..0x0807BFFF`**，禁止 mass erase / 512 KB 整段擦
   （整片擦会连 bootloader 和两个配置页一起清掉，之后必须重新烧 bootloader）。
2. 不把 bootloader 自己的参数放在这两个页。
3. "恢复出厂"只擦 app 区，配置由固件自己的 action 清理。
4. **bootloader 必须喂 IWDG**：App 一上电就启用 IWDG（~4 s），而 IWDG 只有上电复位
   才会停。App 用 magic 软复位进 bootloader 后它仍在计数，不喂狗的话升级到一半就复位，
   magic 已被清掉 → 200 ms 后跳回 App，OTA 永远做不完。OpenBootloader 的
   `OPENBL_IWDG_Refresh()`（`iwdg_interface.c`）已实现为 `IWDG_ReloadKey()`，主循环和
   CAN 收包等待循环里都调它（IWDG 没启动时写 KR 是无害空操作）。

### 进入/使用 OpenBootloader

- **App 侧入口**：`call action.enter_bootloader_mode` 或串口菜单 `b`。固件先关门极、把
  应答发完，0.5 s 后把 `_reboot_cookie`（NO_INIT，固定 **`0x20023FF0`**，bootloader 用
  同一个地址）写成 `BOOTLOADER_MAGIC_VALUE = 0xB00710AD` 再 `NVIC_SystemReset()`。
  bootloader 读到后清成 42 并**永久停留**（不再 200 ms 超时跳转）；magic 的定义在
  `Core/Inc/main.h`，两边字面量必须一致。
- **上电时的普通流程**：bootloader 等 200 ms 看有没有 CAN `SYNC`（ID `0x128`，
  data `0x7F`），没有就跳到 `0x08008000`。所以正常上电只多 200 ms。
- **升级工具**：本仓库自带的 `tools/blcan.py`（python-can；`pip install python-can pyserial`，
  默认 slcan/CANable，也支持 `--interface pcan`；默认 MCU profile 就是 `n32h473`）：

  ```
  python tools/blcan.py --channel COM7 sync
  python tools/blcan.py --channel COM7 upgrade --firmware build/mit_h473.bin --erase auto \
          --addr 0x08008000 --chunk-size 256 --verify --go-addr 0x08008000
  ```

  `--erase auto` 只擦镜像覆盖的页（从 app 页开始），**不要**用 `--erase mass`。
  `build/mit_h473.bin` 是从 `0x08008000` 开始的原样镜像（`objcopy -O binary`），
  所以 `--addr` 必须是 `0x08008000`（`.hex` 自带地址，可省）；`--go-addr` 让
  bootloader 直接跳转、不再复位。用法与故障排查见
  [`tools/blcan_使用说明.md`](../tools/blcan_使用说明.md)。
- **本地烧写**：`tools/flash_jlink.py` 默认把镜像写到 `0x08008000`；烧 bootloader 用
  `--base 0x08000000`。`--erase`（整片）会连 bootloader 一起擦掉。

⚠ **刷完 App 先做一次"描述符自检"确认 flash 内容可信**（2026-11-14 台架）：用
J-Link/Keil 的默认 5 MHz 下载 App 后，芯片上的镜像可能是坏的——表现是
`python tools/mc_ep.py --usb get <任意参数>` 报 **"描述符 CRC 校验失败"**（设备声明的
CRC 与读回的 JSON 对不上；实测 20491 字节里 528 字节错乱，因为设备上残留了上一版镜像
的字节）。此时 App 看起来还在跑，但所有参数/遥测访问都失败。用
`tools/blcan.py upgrade --verify` 走 OTA 重刷后逐字节一致。所以**刷完先跑一句
`mc_ep.py --usb get system.prefs_loaded`：能返回就说明描述符自检通过**。
bootloader 自己也可以用同一条 CAN 通路回读校验：`blcan.py read` 逐块读
`0x08000000` 起的 10~11 KB，和 `Keil/Objects/LION_H473_Bootloader.hex`（或
`MDK-ARM/N32H473/` 下的产物）解析出的镜像比 md5。

⚠ **装了 OpenBootloader 之后 `action.enter_dfu_mode`（ROM ISP / DFU）进不去**
（2026-11-13 台架，两次复现）。App 侧临时打点（已删除）测到的完整事实链：

1. **请求链完全正常**：`action.enter_dfu_mode` → cookie `0xDEADBEEF` → 0.5 s 后
   `NVIC_SystemReset()` → OpenBootloader 不动这个地址 → `early_start_checks()` 确实看到
   `0xDEADBEEF` 并调用 `Jump_To_BOOT()`（第 2 条就是证据）。
2. **ROM ISP 确实被启动了**：`Jump_To_BOOT()` 把 `0x20023E00` 起 128 个字清零后，ROM ISP
   用自己的栈把 `0x20023FF0` 附近改成了随机值（两次分别读到 `0x9798705C` / `0x9698705C`）。
3. **约 0.4 s 后芯片回到 `0x08000000` 重新启动，而且复位源是真正的上电复位**：`RCC` 复位
   标志是 `POR|PIN`，**没有 `SFTRSTF`**；同一套打点里普通 `action.reboot` 一直是
   `PIN|SFT`。于是 bootloader(200 ms) → App 再跑一次，App 发现 cookie 既不是 42 也不是
   `0xDEADBEEF`，执行它自己"启动状态不确定就再复位一次"的保险分支 → **这就是
   `enter_dfu_mode` 的 USB 重枚举间隔 0.96 s 而普通复位 0.48 s（多一整个 boot cycle）的来源**。
4. 所以问题既不在 bootloader 的 cookie/RAM 处理（已验证正确），也不在 App 的 DFU 代码
   路径——是 ROM ISP 起来之后**掉电复位**把它弹回去了。最可能的方向是 ROM ISP 接管引脚时
   扰动功率级/供电（本板六路栅极由 MCU 直驱，PB15 在 OpenBootloader 里还被当作 `MUX1`
   输出拉高，而它在**本板是 `GLS_W`**），母线带电时更容易发生。
   **待验证**：把 48 V 母线断电（只留 USB 供电）再试 `action.enter_dfu_mode`；若此时 DFU
   能停住，就确认是上电扰动，并考虑在 `Jump_To_BOOT()` 里先把六路栅极引脚钳到安全电平。
   在此之前**只把 CAN OTA 当刷机手段**（见上"变砖恢复"）。

**OTA 闭环验证（发布前必做）**

1. 记录 `config.gr`、`config.m_zero`、`system.prefs_sequence`，以及某固定机械
   角度下的 `telemetry.encoder_raw`。
2. 用客户同款流程执行一次真实 OTA。
3. 读回：`system.fw_version_major/minor/revision` 为新版；`system.prefs_loaded = true`；
   `config.gr`/`m_zero` 一致；`prefs_sequence` 未变；同一角度 `encoder_raw` 一致。
4. `call action.save` → `prefs_sequence` +1、`save_status = 1`；断电重启再抽查。

任何一项不符，先查 bootloader 擦除范围，不要先怀疑 TLV 代码。

失败恢复：保存掉电用另一页；擦写失败 `save_status = 3` 且旧页保留；两页都坏
→ 默认值 + `prefs_loaded = 0`，需要重新设置 + 标定。

主动“恢复出厂”：`call action.reset_config`（需门极关闭）——它 = `config_apply_defaults()`
、`config_apply_limits()`、保存一页，**会连标定一起清掉**（`ppairs`/零点/LUT 回默认），
`CAN_ID/CAN_PROT/CAN_BAUD` 也回默认（出厂默认 **CYBERBEAST + Classic 1 Mbit/s**），所以保存成功后
固件会自动重启（0.5 s），之后要重新配 CAN 并重新标定。运行中的 `comm_encoder` 副本
故意不跟着改：重启前继续用旧标定，比拿全零 LUT 去换相安全。

## 与 ODrive 端点的对照（缺什么、为什么）

客户上位机按 ODrive 的 fibre 路径做的对照表，本工程的补齐情况：

| ODrive 参数 | 本工程 | 说明 |
|---|---|---|
| `config.dc_bus_overvoltage_trip_level` / `undervoltage` | `config.vbus_ov_trip` / `vbus_uv_trip` | ✅ |
| `config.dc_max_positive_current` | `config.i_dc_max` | ✅ 软限幅（估算，非保护） |
| `motor.fet_thermistor.config.*` / `motor_thermistor.config.*` | `config.fet_temp_*` / `mot_temp_*` | ✅ |
| `motor.config.pre_calibrated` | `config.pre_calibrated` | ✅ 且作为进电机模式门禁 |
| `motor.config.torque_lim` | `config.torque_lim` | ✅ 输出端 N·m |
| `controller.config.input_mode` / `input_filter_bandwidth` / `torque_ramp_rate` | `config.input_mode` / `input_bw` / `torque_ramp_rate` | ✅ 见"输入整形" |
| `controller.config.enable_vel_limit` / `enable_torque_mode_vel_limit` | `config.enable_vel_limit` / `enable_torque_vel_lim` | ✅ |
| `trap_traj.config.vel_limit` / `accel_limit` / `decel_limit` | `config.trap_vel_limit` / `trap_accel_limit` / `trap_decel_limit` | ✅ 独立三元组，默认 0 = 退回 `v_max`/`accel_limit`/`decel_limit`；巡航速度与运行期限速取 min |
| `controller.config.vel_ramp_rate` | `config.vel_ramp_rate` | ✅ 默认 0 = 用 `accel_limit`/`decel_limit`；>0 时对称斜坡 |
| `config.sensor_mode`（遥测） | `telemetry.sensor_mode` | ✅ 恒 0（无无感估计器） |
| `controller.mechanical_power`（遥测） | `telemetry.mechanical_power` | ✅ |
| `current_control.Id_setpoint` / `Iq_setpoint`（遥测） | `telemetry.i_d_des` / `telemetry.i_q_des` | ✅ |
| `fet_thermistor.temperature`（遥测） | `telemetry.mos_temp` | ✅ |
| `ODrive.fw_version_major/minor/revision` / `unreleased` | `system.fw_version_major/minor/revision` / `unreleased` | ✅ 全部由 `main.h` 的 `FW_VERSION_*` 派生（**没有**单独的 float 版本号；老协议 `CAN_VAR_VERSION` 仍按协议给 float，编码 `major + 0.01*minor`） |
| `ODrive.hw_version_major/minor/variant` | `system.hw_version_major/minor/variant` | ✅ `hw_config.h` 的 `HW_VERSION_*`（CBL89 = 1.0.0） |
| `ODrive.serial_number`（uint64） | `system.serial_number`（uint64） | ✅ 直接取 MCU 的 96 位唯一 ID 低 64 位（`GetUID()`），不依赖 EEPROM。为它给 endpoint 协议加了 **uint64** 类型（`ep_get_u64`/`ep_put_u64`），描述符里的类型名与 ODrive 一致 |
| `ODrive.vbus_voltage` / `ibus` / `error` | `telemetry.v_bus` / `i_bus` / `fault` | ✅ 只是命名不同 |
| `ODrive.n_evt_sampling` / `n_evt_control_loop` | `timing.count` / `telemetry.loop_count` | ✅ 只是命名不同 |
| `ODrive.ibus_report_filter_k` | 固定用 `VBUS_FILT_ALPHA`（0.1）滤波 | 未提供；需要按主站要求调上报滤波时再加 |
| `ODrive.brake_resistor_*` | **不提供** | 本硬件没有制动电阻通路（`RM_EN` 在 CBL89 上已是 `GLS_V`） |
| `ODrive.user_config_loaded` / `misconfigured` | `system.prefs_loaded` 覆盖前者 | 后者无对应概念（没有会互相冲突的外设配置） |
| `config.comm_intf_mux` | **不提供** | 本硬件没有可用的接口复用开关：`MUX1`(PB15)/`RM_EN`(PB14) 这两个旧板宏在 CBL89 上已是 `GLS_W`/`GLS_V`（ATIM1 下管驱动）。RS485/脉冲/PWM 输入未实现，需要时按新板定义重做 |
| `can.config.enable_r120` | **不提供** | 板上 120 Ω 终端不可控（无 GPIO），给了端点也只会"写了没效果"，违反参数必须有语义的原则 |

> 命名策略：本工程用扁平短名（上位机做一次映射），只有这些必要的才与 ODrive 同名。
> `Id_setpoint`/`Iq_setpoint` 这种大写开头的名字与 `params.json` 的小写命名规则
> 冲突，所以用 `i_d_des`/`i_q_des` 对应。ODrive 根节点的名字（`serial_number`、
> `fw_version_major`…）在本工程挂在 `system.` 前缀下，因为 `params.json` 要求名字
> 至少带一个点；如果主站坚持按原名探测，再补一组别名（新 ID，同一 getter）即可。

## CAN：协议选择与 CYBERBEAST

**三个持久化参数决定协议与物理层，开机时读取一次，写入后下次上电生效：**

| 参数 | 含义 |
|---|---|
| `config.can_prot` | `0` = 旧 11-bit 协议，`1` = **CYBERBEAST（默认）** |
| `config.can_baud` | bit/s，默认 `1000000`（Classic 1 Mbit/s）。`≤ 1M`：Classic CAN，该值就是位速率；`> 1M`：CAN FD，仲裁域固定 1 M，数据域 = 该值（支持 2M/4M/5M） |
| `config.can_hb_ms` | CYBERBEAST 心跳周期（默认 100 ms，0 关闭） |
| `config.can_tdc` | CAN FD 发送延迟补偿偏移（单位：数据域 tq）。`-1` = 自动（= 数据域 tseg1，默认，与 ODrive / canable2-fw 一致）、`0` = 关闭、`>0` = 手动；只对 FD 生效，下次上电应用 |

`system.can_prot_active` / `system.can_fd` / `system.can_baud_active` 报告**真正在跑**
的协议、物理层与速率。`can_prot=0` 时 `can_baud > 1M` 会被钳到 1M（旧协议只有
8 字节帧）；FD 数据速率不在 2M/4M/5M 表里时退回 Classic 1M，并让
`system.can_fd=0` 如实反映，不做“看起来是 FD、其实没跑起来”的静默降级。
Classic 速率必须能由 40 MHz / (40 个时间量子) 整除：50k/100k/125k/200k/250k/500k/1M。

为什么必须开机生效：NBTP/DBTP、消息 RAM 元素大小（8 B vs 64 B）和滤波器类型
都由这两个值决定，运行期重建会打断 40 kHz 控制循环。因此 `MX_CAN1_Init()` 从
CubeMX 的 SysInit 段移到了配置加载之后
（`config_apply_defaults` → `preference_writer_load` → `config_apply_limits` 之后）。

### 代码结构

| 文件 | 职责 |
|---|---|
| `can.c` | 时钟/引脚、NBTP/DBTP、消息 RAM、滤波器、`can_send_frame` / `can_rx_fetch` |
| `can_proto.c` | 协议表（`can_protocol_t`）与分发；25 µs → 1 ms 时基 |
| `can_mit.c` | 旧 11-bit 协议（从 `n32h47x_48x_it.c` 原样搬出） |
| `can_cyberbeast.c/.h` | CYBERBEAST |
| `can_cyberbeast_codec.h` | 纯编解码（固件与 host 测试共用） |

`n32h47x_48x_it.c` 的 `can_tx_rx()` 只做：`can_proto_tick()` + 每周期最多取 2 帧
→ `can_proto_rx()`。控制帧、查询、心跳、SDO 参数访问都在 ISR；**描述符流式发送
在主循环**（`can_proto_poll()`，2 帧/ms）。新增协议 = 一个 `can_protocol_t` + 一个
`can_prot` 枚举值，不动硬件层。

### CYBERBEAST 实现范围

| MsgType | 行为 |
|---|---|
| `0x00/0x80` MIT | 8 字节位域 → `p_des/v_des/kp/kd/t_ff`（**输出端 1:1**）；单播回 8 字节响应；FD 广播按 `slot = node_id` 取槽（node_id 必须 1..7） |
| `0x03/0x83` TORQUE | 线上是电机端 N·m → `t_ff = τ × GR`，`kp = kd = 0` |
| `0x04` CURRENT | `t_ff = I × KT × GR`，不回应答；**刷新超时**（比 ODrive 的 F19 更安全） |
| `0x01/0x81` CSP | 目标位置 deg(输出端) + `vel_limit` RPM(输出端) + `cur_limit` A(电机端)；Classic 8 B 用 float32 位置 + int16 RPM + int16 0.1A，FD 12 B 全 float32；进 `CTRL_POSITION`，单播回 MIT 响应 |
| `0x02/0x82` CSV | 目标速度 RPM(输出端) + `cur_limit` A(电机端)；进 `CTRL_VELOCITY`，单播回 MIT 响应 |
| `0x20/0x21` SDO | 直接 `endpoint_handler()`；值小端；Classic 下 ReqLen 钳到 4；`>4` 字节走分段写；批量读回 ERR。`mc_ep.py --can` 用这两个消息（8 字节的值在 Classic 下按 offset 分两次读，响应 bit7 = More） |
| `0x22` SAVE | 置 `state.save_pending`（门极关闭时由主循环写 flash） |
| `0x24/0x25` 描述符 | 元数据 + 定长分片（8/64 B，末尾补 0），2 帧/ms。`mc_ep.py --can` 用它在 CAN 上拉整套参数树（Classic 1M 约 1~2 s） |
| `0x40..0x49` 查询 | 状态/位置速度/电流/温度/母线/错误/版本；`0x44` 母线电流与 `0x47` 电/机械功率是**估算值**（无直流分流器，见"母线电流 / 功率估算"） |
| `0x48` 心跳 | Classic 8 B / FD 19 B；pos/vel 按**原始计数域**钳位（F32 教训）；字节 18 是映射后的 ODrive AxisState |
| `0x60..0x65` | SET_NODE_ID（RAM，需 save 持久化）/ SET_ZERO / START（仅 MENU）/ STOP / RESET / CLEAR |
| `0xC0` ESTOP | `controller.fault |= FAULT_ESTOP` → FAULT_MODE 关栅，需显式回菜单清除 |

心跳的**目的地址是主站 ID**（协议 §4.6 `Dest=MasterID`，不是广播）：`cb_master_id` 从收到的帧里
学 Source，**复位/上电清零**，清零期间按默认主站 `1` 发送（`config.can_master` 只在没学到值之前
起作用，学到了就听学到的）。⇒ 主站 ID 不是 1 时，必须**先发一帧**（任意类型）才会把心跳改发到
自己的 ID；台架脚本不要按 `dest == 本机` 过滤心跳，否则"刚复位没心跳"是假故障。

单位表（最容易错的地方）：

| 量 | 线上 | 本工程 |
|---|---|---|
| MIT pos/vel/kp/kd/τ | 输出端 rad / rad/s / N·m/rad / N·m | 同口径，1:1 |
| TORQUE / CURRENT | 电机端 N·m / A | `×GR` / `×KT×GR` 换成输出端 `t_ff` |
| 心跳 pos/vel | 电机端 turns（×100 / ×10000） | `angle_multiturn/(2π)` |
| QUERY_POS_VEL | 电机端 turns | 同上 |

量程沿用 `P_MAX/V_MAX/KP_MAX/KD_MAX`；**MIT 力矩满量程是独立参数
`config.mit_tau_max`**（默认 5 N·m，0 = 退回老行为 `I_MAX·KT·GR`），
响应电流满量程 `I_MAX·GR`（= `mit_max_torque / KT`）。
`command.t_ff` / `TORQUE` / `CURRENT` / 旧协议 `SET_TFF` 用同一个上限
（`user_config.h` 的 `TORQUE_FS` 表达式）。
⚠ **位域量程 ≠ 可达力矩**：`I_MAX·KT·GR` 仍是电流环的物理上限（本机 KT = 0.0334 /
GR = 9：i_max = 4 A 只有 1.2 N·m，出厂上限 12 A 是 3.6 N·m），量程内的超限命令只是让
`i_q` 停在 `i_max`。
早先满量程直接绑在 `I_MAX·KT·GR` 上，12 位字段的分辨率（0.6 mN·m）远高于需要，
却表达不了 3.5 N·m 级峰值，所以拆成独立参数。上位机必须读 `config.mit_tau_max`
（描述符里的 float 端点）后按同一值编解码，否则收到/发出的力矩整体按比例错。

### 与 JointSDK 的现状

`jsdk_context_configure()` 仍会失败：它要求 `axis0.motor.config.gear_ratio` 等
7 个 ODrive 路径。**本工程刻意不加这些别名**（客户将改 JointSDK 适配），
所以现阶段用 `jsdk_context_desc_fetch()` + `jsdk_joint_param_get/set()` 访问参数，
控制用 `0x00/0x03/0x04`。描述符仍是纯 ASCII、动作端点为 `function` 类型，
可直接被 SDK 的 `cb_jsondesc_parse` 解析（当前 239 个端点、描述符 20608 B ≈ 20.1 KB，
其中 2 条 hidden blob 不进描述符；
改 `params.json` 后需在 SDK 环境重跑一次确认）。

### 台架注意

- **5 M 数据域必须开 TDC**（`config.can_tdc` 默认 `-1` = 自动）。2026-11-03 台架实测：
  不开 TDC 时 5M **完全不通** —— 设备自报 `can_fd=true`/`can_baud_active=5000000`，但
  `can_tec=248`、`can_rec=0`、`lec=7`，适配器一帧都收不到（发送无 ACK → 反复重发 → bus-off）；
  同一固件把数据域改成 2M（20 tq，裕量 2.5 倍）则 97/97 全过。根因：8 tq/25 ns 下收发器
  环回延迟（100~250 ns）吃掉采样裕量，发送端需要靠 TDC 把自己的求值点往后推。
  TDC 只能在 init 模式写，所以 `MX_CAN1_Init()` 里必须放在 `FDCAN_Init()` 之后、
  `FDCAN_Start()` 之前；offset 与 filter 都用数据域 tseg1。
- 仲裁域统一 40 个时间量子；旧协议保持原采样点 **87.5%**（34/5，总线行为不变），
  CYBERBEAST 用 80%（31/8，与 ODrive 一致；FD 数据域 5 M = 8 tq/75%）。
- 扩展帧过滤器接受**全部**扩展帧，Dest 由软件过滤；1M 满总线约 2k 帧/s，
  40 kHz 轮询可消化 40k 帧/s。
- 改 `can_prot` / `can_baud` / `can_id` 后必须断电重启，`system.can_prot_active`
  可核对；`can_id` 的滤波器和 CyberBeast 的 Dest 都按新值生效。
- `action.save` 写入的是新参数值，但运行中的物理层不变（下次上电才切换）。
- ⚠ **上位机用错波特率会把设备打进 bus-off**（2026-11-17 台架）：适配器按 500k 打开、
  设备在 1M 发心跳，这些帧没人 ACK，`can_tec` 十几帧就涨到 ~248，之后设备既不发也不答
  （TX 队列卡在一帧永远等 ACK 的报文），**换回正确波特率也不会自己恢复**，
  只能 `action.reboot`（USB 或菜单）。所以排查“`--can` 一帧都收不到”时：
  `mc_ep.py --port COMx get telemetry.can_tec`（>128 = 中招）→ 重启再试；
  `mc_ep.py --can probe` 只监听不发帧，就不会把设备打挂。
- 上位机侧：`tools/mc_ep.py --can`（`--interface slcan|pcan|socketcan|…`）与
  `--port`/`--usb` 用同一套命令和参数名，传输层的差异见 "endpoint 协议" 的表格。

### 台架实测（2026-10-26，Keil 构建 + CANable 2.0）

| 场景 | 结果 |
|---|---|
| Classic 1M：A 握手/SDO/心跳/描述符/查询/ESTOP | 34/34 |
| Classic 1M：B 闭环力矩脉冲 | 7/7 |
| FD 1M/5M：A | 34/34 |
| FD：B MIT 单播脉冲 / C 64 B 广播脉冲 | 7/7 · 5/5 |
| FD：C-static 广播槽位 + 单位映射 | 9/9 |
| FD：`0x64` 重启（回 1.99 s）+ 配置保持 | 7/7 |
| FD：SDO/控制错误路径（D） | 12/12 |
| FD：MOTOR 下命令超时（T，含 20 Hz 主站存活） | 11/11 |

schema 1 → 2 迁移已实机验证（同一块配置，不动 flash）：旧块算出
`config.can_timeout = 25`（原 1000 控制周期）、`system.config_schema = 2`、
`prefs_sequence` 不变、`e_zero = 934` / `ppairs = 14`（同块的标定记录）全部保留；
改成 100 后 `action.save` → sequence +1，重启后直读 schema 2 块，值仍是 100
（**没有二次换算**）。

几条必须记住的行为（都是客户会踩的）：

- **`config.can_timeout` 的单位是毫秒**（默认 **100 ms**，0 = 关闭）。固件内部用
  `CAN_TIMEOUT_CYCLES`（×40）与 `controller.timeout`（控制周期）比较，实测最后一帧后
  **100 ms 量级**被 `zero_commands()` 清零。⇒ 主站必须快于 10 Hz（旧版本是 25 ms 超时、
  要求 >40 Hz，已改）。`telemetry.can_timeout_count` 报的是**控制周期数**（饱和在
  `can_timeout × 40`），用来判断“离超时还有多远”。
- **写的 ACK 不含成败位**（协议如此）：只读端点、类型不符、`require` 不满足都**照样回 ACK**，
  必须读回判定。实测：写 `telemetry.v_bus` 无效果；门极使能时写 `config.gr` 被拒（值不变）。
- 错误路径实测：批量读（flags bit6）回 `BATCH|ERR`（`0x60`）；读 `action.*` 回 0 字节
  但**会执行动作**（ODrive 兼容，见“动作端点例外”；2026-11-09 起 D3 用例就是这样测的，
  只有 `require` 不满足时才回 `EP_ERR_STATE`）；越界写钳到 min/max（`config.i_bw` 1e9→2000、-1e9→100）；
  NaN 被丢弃（值不变）；宽度不符（`config.gr` 用 int16）被丢弃；`0x03` TORQUE 超大值
  钳到 `config.mit_tau_max`（`TORQUE_FS`，0 时 = `I_MAX·KT·GR`），NaN 帧被忽略。
- 台架脚本：`python tools/cb_bench.py --port COMx --stage-a|--stage-b|--stage-c|--stage-c-static|--stage-d|--reset-test|--timeout-test [--fd]`。
  ⚠ 脚本自身的收发周期很关键：早期版本用 `ser.read(4096)`（串口 timeout 50 ms）导致
  实际只有 ~20 Hz、比 25 ms 的超时还慢，量出来的力矩/位置变化偏小 —— **别用"命令没反应"
  去怀疑固件，先数自己发了多少帧**。

## 测试

自动检查：`make check`（生成物/文档最新）、
`make hosttest`（`prefs_codec` + `test_can_cyberbeast` + `test_motion_law` +
`test_dual_gear` + `test_endpoint_proto`）、
`make`（链接）。
上位机侧的 CAN 传输有 `python tools/test_mc_ep_can.py`（或 `make hosttest-py`；
需要 `pip install python-can`，不需要硬件：用 python-can 的 virtual 总线模拟一台
CYBERBEAST 从机，覆盖描述符流、分段读写、动作端点、`n=0` 的只写端点、
Classic/FD 两种帧长）。
Windows 用 MSYS2 bash 构建（Chocolatey 的 make 用 cmd，
`mkdir -p` 会失败）：

```bash
export PATH="/d/Debug/arm-gnu-toolchain-15.2.rel1-mingw-w64-x86_64-arm-none-eabi/bin:$PATH"
make -j8
```

改了协议/描述符时，用 JointSDK 的 `cb_jsondesc_parse.c` 解析
`mc_ep.py descriptor` 导出的 JSON，确认 `rc=0`、类型/权限正确。

### 烧录（J-Link，可靠流程）

**别用 `JLink.exe loadfile` 或 UV4 默认设置直接烧这块板。** 台架实测
（2026-10-30，J-Link V11 + JLink DLL V8.26，VTarget 2.917 V）：SWD **读回不稳**——
同一段 flash 连续读三次会得到三个不同内容（1 MHz），Keil 默认的 5 MHz 下 J-Link
自带 verify 随机报 `Verification failed @ 0x08000000`，而**编程其实只写了一部分**。
最坑的是它有时"看起来成功了"：设备继续跑旧镜像，于是新加的 endpoint 用的是旧实现、
遥测值自相矛盾（这一次就是 `inertia_accel_lo` 与 `inertia_accel_hi` 读回同一个值，
排查了半天才发现是镜像没换）。

可靠做法（`tools/flash_jlink.py` 就是把这一套写成脚本）：

```
python tools/flash_jlink.py            # 250 kHz + 8 KB 分块写 + 逐块回读比对 + 重试
python tools/flash_jlink.py --erase    # 需要时先整片擦除（会清掉配置页！）
python tools/flash_jlink.py --bin build/motorcontrol.bin   # GNU 构建产物也可以
```

- 250 kHz 是实测稳定的上限；1 MHz 读回就会偶发错字节（全镜像一次读完仍可能错 2 字节，
  所以**校验也要分块 + 失败重读**，不能只信 J-Link 的 `Verify`）。
- 烧完必须回读全镜像并逐字节比对，一致才算成功（脚本退出码非 0 就是没烧进去）。
- 烧完核心处于 halt，`COM` 口不会出现；脚本最后会 `r`+`g`。手动流程是
  `si SWD / speed 250 / device N32H473CE / connect / r / g / exit`。
- 整片擦除会清掉配置页（`prefs_loaded = false`、`prefs_sequence = 0`）：
  之后必须重新 `action.calibrate`（R/L/KT/编码器零点）再 `action.save`，
  否则电流环/惯量标定拿到的都是默认值（实测未标定时 `breakaway = 0.4 A`、
  加速度符号都反了，J 差 10 倍）。
- 烧录成功后核对一次现场：`system.prefs_loaded` / `system.prefs_sequence` /
  `config.kt` 是否符合预期，能立刻发现"其实没烧进去"。

台架清单（改 endpoint/持久化后）：

| # | 操作 | 期望 |
|---|---|---|
| 1 | 上电，`tree` | 列出参数树 |
| 2 | `set config.i_max 3.5` | 返回 3.5；再 `get` 一致 |
| 3 | `set config.i_max 99` | 返回 12.0（`I_MAX_LIMIT`） |
| 4 | `set telemetry.i_q 0` | 状态 4 |
| 5 | `get action.save` | **状态 5，电机不能动** |
| 6 | `call action.save` | `save_status = 1`，`prefs_sequence` +1 |
| 7 | 门极使能时 `call action.save` | 状态 6 |
| 8 | 断电重启 | 第 2 步的值保留；`prefs_loaded = true` |
| 9 | 标定后重启 | 同一角度 `encoder_raw` 不变 |
| 10 | 连续保存 3 次 | 序号连续，不丢配置 |
| 11 | 保存瞬间断电（重复几次） | 上电后是上一次的完整配置 |
| 12 | CRC 错的帧 | 设备不应答，后续通信正常 |
| 13 | 旧描述符 CRC | 状态 7 |
| 14 | `call action.reboot` | 应答先返回，~0.5 s 后重启；门极在复位前已关闭 |
| 15 | `call action.reset_config`（先记下 `prefs_sequence`） | `save_status = 1`、序号 +1；`config.e_zero/ppairs` 回默认；**随后自动重启**，重启后 `prefs_loaded = true`、`config.can_prot = 1` / `can_baud = 1000000`（出厂默认）并重新标定 |
| 16 | 门极使能时 `call action.reset_config` | `status 6`（`EP_ERR_STATE`），`save_status` 不变，配置不动 |
| 17 | 空闲态 `set command.t_ff 5` 后 `call action.motor_mode` | 门极使能后 `telemetry.t_ff = 0`（进入模式时清零），电机不窜动 |
| 18 | 插 USB，设备管理器 | 出现 COM 口（CDC）**和**一个 vendor interface；两者同时可用 |
| 19 | `mc_ep.py --port COMx tree` | 和改复合描述符之前一致（ASCII 菜单也能用） |
| 20 | Zadig 给 interface 2 装 WinUSB 后 `mc_ep.py --usb tree` | 参数树正常，`get/set/call` 与 CDC 结果一致 |
| 21 | 电机模式 + `--usb monitor telemetry.i_q ... --rate 100` | FOC 不失步、`telemetry.lost_frames` 不增长（USB 只在主循环处理） |
| 18 | 电机模式下写 `command.t_ff`，然后停发 3×`can_timeout` | 命令自动清零（租约到期），`telemetry.i_q_des → 0` |
| 19 | `set command.mode 1` + `set command.v_des 1` | 电机按速度环转到 ~1 rad/s；`telemetry.v_setpoint`/`vel_err` 有值，`command.mode` 回读为 1 |
| 20 | `set command.mode 2` + `set command.p_des <当前+0.5>` | 位置环把关节转过去并停住；`telemetry.pos_err → 0`，无过冲振荡 |
| 21 | CSP 时连发 3×`can_timeout` 不刷新 | 卸力（零转矩），不是“保持位置” |
| 22 | `set config.pos_error_fault 0.2`，堵住关节让 CSP 追不上 | 约 100 ms 后 `telemetry.fault` 出现 `FAULT_POS(8)`，进 FAULT_MODE 关栅 |
| 23 | `set config.vel_loop_prescaler 1` / `pos_loop_prescaler 1` | `timing.overrun` 仍为 0，`timing.period_max` < 0.6×`isr_period` |
| 24 | `call action.enter_dfu_mode`（门极关闭） | 应答先返回（`EP_OK`）、串口打印 `Entering ROM DFU bootloader`；~0.5 s 后复位。⚠ **装了 bootloader 后这条目前过不了**：设备约 0.4 s 后自己从 `0x08000000` 回来（ROM ISP 起来后被上电复位弹回，见上文），DFU 设备不会出现 |
| 25 | 门极使能时 `call action.enter_dfu_mode` | `status 6`（`EP_ERR_STATE`），不复位、门极保持 |
| 25a | `call action.enter_bootloader_mode`（门极关闭），CAN 侧接 `python tools/blcan.py sync` | 应答先返回（`EP_OK`）、串口打印 `Entering bootloader`；~0.5 s 后复位，`blcan.py sync` 拿到 ACK（**ACK 落在 ID `0x128`**，再 `sync` 一次也应该是 ACK 而不是 NACK）且**超过 30 s 不自动跳回 App**（IWDG 被喂住） |
| 25b | bootloader 里 `python tools/blcan.py upgrade --erase auto --addr 0x08008000 --verify --go-addr 0x08008000` | 升级完成、App 正常启动；`system.prefs_loaded = true`、`prefs_sequence` 不变、`config.gr`/`m_zero`/标定 LUT 都在，且 `mc_ep.py` 能下完整描述符（描述符 CRC 自检通过 = flash 内容与镜像一致） |
| 25c | 门极使能时 `call action.enter_bootloader_mode` | `status 6`；不复位、门极保持 |
| 25d | 串口菜单按 `b` | 同 25a（`b` 是 `BOOTLOADER_CMD`，不是设置前缀） |
| 26 | `set config.pre_calibrated 0` 后 `call action.motor_mode` | `status 6`；串口按 `m` 打印 `Motor mode refused`；CYBERBEAST `START_MOTOR` 后状态仍是 IDLE |
| 27 | 标定成功后读 `config.pre_calibrated` | `1`；进一次标定（即使失败回菜单）后变回 `0` |
| 28 | 可调电源拉到 `config.vbus_ov_trip` 以上 | 锁 `FAULT_OV(1)`；串口故障报告打印实际峰值与阈值 |
| 29 | 门极使能时把母线降到 `config.vbus_uv_trip`（>0）以下并保持 >10 ms | 锁 `FAULT_UV(16)`；门极关闭时同样的电压不报 |
| 30 | 打开 `config.fet_temp_en`，`fet_temp_hi` 设成低于当前 MOS 温度 + 5 | 电流上限按 `[lo,hi]` 线性下降，超过 `hi+5 °C` 锁 `FAULT_FET_OT(32)` |
| 31 | `set config.torque_lim 0.5`，然后下大转矩指令 | `telemetry.torque` 被压在 ~0.5 N·m；设回 0 后恢复 |
| 32 | 母线电压/电流、`telemetry.mos_temp`/`mot_temp` 与万用表/热电偶对照 | `i_bus` 与电源读数同量级同符号；`mos_temp`/`mot_temp` 室温下与实测相差 < 5 °C（偏差大说明 NTC 分压与 ODrive 板不同，需改系数） |
| 33 | `set config.input_mode 5` + CSP 走 1 rad 的阶跃 | 速度曲线是梯形（加速/匀速/减速都可见），到点无过冲；`telemetry.v_setpoint` 不超 `config.v_max` |
| 34 | 同上，中途改 `command.p_des` 到反方向 | 从当前速度减速再反向，不跳变、不触发 `FAULT_POS` |
| 35 | `set config.input_mode 3`，`config.input_bw 10` | 位置平滑跟到目标，无超调；`input_bw` 调到 100 仍稳定（增益被自动压低） |
| 36 | `set config.input_mode 1`（直通）+ CSP 阶跃 | `accel_limit` 不再生效（速度指令瞬间到位），电流冲击明显变大 —— 确认这就是预期 |
| 37 | `set config.input_mode 6` + `config.torque_ramp_rate 2`，MIT 下给 `t_ff` 阶跃 | `telemetry.t_ff` 按 ~2 N·m/s 爬升，不是瞬间到位 |
| 38 | `set config.enable_torque_vel_lim 1` + MIT 推到超速 | `i_q_des` 被压向刹车侧，实际速度被限在 `config.v_max` 附近 |
| 39 | `set config.enable_vel_limit 0` + `set command.v_des 100` | 写入成功（不再是 65），CSV 按 100 rad/s 转（注意机械安全）；设回 1 后回 `v_max` |
| 40 | `set config.vel_ramp_rate 15` + CSV 阶跃 1 rad/s | 加速与减速都按 15 rad/s²（`telemetry.v_setpoint` 斜率一致）；设回 0 后回到 `accel_limit`/`decel_limit` |
| 41 | `set config.input_mode 5` + `config.trap_vel_limit 1.0`（`v_max` 保持 65）+ CSP 走 2 rad | 巡航段速度被限在 1 rad/s（`telemetry.v_setpoint ≈ 1`），到点无过冲；`config.trap_accel_limit 5` 后加减速变缓 |

## 发布检查表

- [ ] `FW_VERSION_MAJOR/MINOR/REVISION/UNRELEASED`（`main.h`）、`EP_PROTOCOL_VERSION`、
      `PREFS_SCHEMA` 是否变化已确认；`FW_VERSION_UNRELEASED` 只在预发布构建里为 1；
- [ ] ID 注册表只追加、没有复用/重排；
- [ ] `make check` 通过，生成物与文档一起提交；
- [ ] GNU Make 能干净构建；`make size` 镜像 < `0x0807C000`
      （app 从 `0x08008000` 起，最多 `0x74000`）；
- [ ] `make hosttest` + 台架清单通过（含 USB 复合设备的 CDC/vendor 两条传输）；
- [ ] 改了齿槽补偿/外环：`action.cogging_calibrate` 跑通，`system.cogging_amp` /
      `cogging_mismatch` 在合理范围，"设参数 + 标定 → OTA → 读回"闭环仍然保留表；
- [ ] bootloader 擦除范围已确认（`tools/blcan.py ... --erase auto`，**不是** mass），OTA 闭环验证
      通过（参数/零点/LUT 保留）；bootloader 侧 `OPENBL_IWDG_Refresh()` 仍然是喂狗的
      （否则从 App 进入后 4 s 就会被 IWDG 复位）；
- [ ] [README](README.md) 的版本矩阵已更新；客户可见的接口变化写进发布说明。

## 接口变更规则

对外契约只有三样：endpoint 协议、描述符、配置记录格式。

- **endpoint 协议**语义变化 → `EP_PROTOCOL_VERSION` +1（当前 2；v2 增加了
  bit14 读写标志，v1 的"空 payload 即执行"已移除）。**例外**：动作端点重新
  接受“读”来执行（对齐 ODrive/JointSDK）是向后兼容的放宽——写路径不变，
  老上位机照旧工作，所以没有升版本。
- **描述符**内容变化 → CRC 自动变，旧上位机会收到 `EP_ERR_VERSION`。
  改名不改 ID；改单位/含义用新 ID。
- **配置格式**变化 → `PREFS_SCHEMA` +1 + 迁移函数。
- **Flash 分区**变化 → 必须重新验证 bootloader 契约。

每次变化同步更新 [README](README.md) 的版本矩阵和本文档对应章节。
