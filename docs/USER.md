# 用户手册

面向使用板子/写上位机的人。参数清单见 [parameters.md](parameters.md)，
协议内部细节见 [DEV.md](DEV.md)。

## 1. 连接

**出货版本默认只有 CAN 接口（没有 USB 座）**，所以日常使用就是 `mc_ep.py --can`。
开发/台架板子上还有一个 USB 复合设备（CDC 串口 + vendor interface），命令行完全
一样，只是把 `--can …` 换成 `--port COM7` 或 `--usb`。

| 入口 | 用途 | 需要 |
|---|---|---|
| **CAN（CYBERBEAST SDO）** | `mc_ep.py --can`：**出货版本的唯一入口**，设备已经在总线上就不用再接线 | slcan(CANable)：`pip install pyserial`；其它后端：`pip install python-can` |
| CDC 虚拟串口（开发板） | ASCII 菜单 + `mc_ep.py --port`（和以前一样） | `pip install pyserial` |
| vendor interface 2（开发板） | `mc_ep.py --usb`，一个 USB 包一帧，更快 | `pip install pyusb libusb-package`；Windows 用 Zadig 给 interface 2 装 WinUSB |

- 工具：`tools/mc_ep.py`

```bash
python tools/mc_ep.py --can tree                          # CAN（默认 slcan/CANable，自动找适配器）
python tools/mc_ep.py --can --interface pcan get config.i_max
python tools/mc_ep.py --can --interface socketcan --channel can0 tree

# 开发/台架板子还可以走 USB（参数名和输出完全一样）
python tools/mc_ep.py --port COM7 tree   # CDC 虚拟串口
python tools/mc_ep.py --usb tree         # vendor interface（fibre）
```

设备会先回送一份 JSON 描述符（名字/ID/类型/权限），工具据此把名字映射到 ID，
所以**固件升级后脚本不用改**。

> 带 USB 的开发板：Windows 上记下 COM 号（如 `COM7`），Linux 是 `/dev/ttyACM0`，
> `--baud` 对 CDC 无实际作用。要用 `--usb` 的话，Windows 用 Zadig → Options →
> List All Devices → 选 `0x1209/0x4342` 的 **interface 2**（不是整个设备）→ 驱动选
> WinUSB 或 libusb-win32（两者都验证可用）→ Replace Driver；CDC 那两个 interface
> 保持 `usbser` 不动，COM 口照常可用。
>
> 同一个串口只能有一个使用者：`mc_ep.py` 运行时不要再开串口终端。原来的
> ASCII 菜单仍然可用（115200 8N1：`m` 电机、`c` 标定、`s` 设置、`e` 编码器、
> `z` 零点、`b` 进 OpenBootloader（CAN 升级）、`d` 进 ROM DFU）。
>
> `--usb` 只占用 vendor interface，**不会**和 CDC 串口互相干扰；但请只在
> 一个进程里同时使用（不要两个 `--usb` 进程抢同一组端点）。
> CAN 侧同理：一个适配器同时只能被一个进程打开。
>
> **出货版本没有 USB 座**，所以也没有 ASCII 菜单和 `myprintf` 的调试输出：
> 本文里提到“串口打印 / 串口菜单”的地方只在带 USB 的开发/台架板子上可见，
> 出货机上等价的信息用 `--can get telemetry.*` / `system.*` 读。
>
> `tools/` 里除 `mc_ep.py` 之外的台架脚本（`csv_csp_test.py`、`gear_test.py`、
> `cogging_test.py`、`torque_test.py`、`cb_bench.py`）目前只走 USB
> （`--port`/`--usb`），需要带 USB 的开发板；出货机上用 `mc_ep.py --can`
> 做同样的读写即可（`set command.*` + `monitor`）。

### 通过 CAN 访问参数（`--can`，出货默认用法）

`--can` 走 CYBERBEAST 协议的 SDO（`PARAM_READ`/`PARAM_WRITE`）和描述符流
（`0x24/0x25`），命令和参数名与 `--port`/`--usb` 完全一样。前提：

- `config.can_prot = 1`（CYBERBEAST，出厂默认；旧 11-bit 协议**没有** endpoint 访问）；
- 速率：
  - **Classic**（出厂默认）：`--bitrate` = `config.can_baud`（1 Mbit/s）；
  - **CAN FD**（`config.can_baud` 为 2M/4M/5M）：固件把**仲裁域固定成 1 Mbit/s**，
    所以 `--bitrate` 保持默认 `1000000` 并加 `--fd`，把 `config.can_baud` 填到
    `--data-bitrate`（固件只接受 2M/4M/5M）；
- `--can-id` 等于 `config.can_id`（出厂 1）；`--master-id` 是本机主站 ID（默认 `0xFE`）。

```bash
# CANable（slcan）：只多要 pyserial；不给 --channel 时自动找 16D0:117E 的串口
python tools/mc_ep.py --can --interface slcan --channel COM3 tree
# PCAN-USB（需要 PEAK 驱动 + pip install python-can）；--channel 默认 PCAN_USBBUS1
python tools/mc_ep.py --can --interface pcan --bitrate 1000000 get config.i_max
# Linux SocketCAN（接口要先配好：sudo ip link set can0 up type can bitrate 1000000）
python tools/mc_ep.py --can --interface socketcan --channel can0 tree
# CAN FD（config.can_baud = 5000000）：仲裁域 1M + 数据域 5M
python tools/mc_ep.py --can --interface slcan --channel COM3 --fd --data-bitrate 5000000 tree
```

| 后端 | 依赖 | 备注 |
|---|---|---|
| `slcan`（CANable/CandleLight，默认） | pyserial | 工具自带实现，含 CAN FD（数据域只支持 2M/5M） |
| `pcan`（PCAN-USB） | python-can + PEAK 驱动 | 速率由 `--bitrate`/`--data-bitrate` 设定 |
| `socketcan`（Linux） | python-can | 速率与是否 FD 由 `ip link` 决定 |
| `gs_usb` / `kvaser` / `vector` / … | python-can | `--interface` 填 python-can 的后端名 |

规则与坑：

- **写没有状态码**：CAN 的写 ACK 不带成败位（只读端点、`require` 不满足、被限幅
  都照样 ACK），所以 `set` 会立刻把值读回来打印；要确认就 `get` 一次。
- `call` 用 `PARAM_READ` 触发（ODrive/JointSDK 的语义），`--read` 对它没有区别。
- 固件的“主站 ID”是从收到的帧里学的，**同一条总线上只能有一个主站在发命令**
  （否则应答/心跳会被发到另一个主站去）。
- 速度：Classic 1M 下 `dump`（220 个参数）约 3 s，`monitor` 的刷新率受往返时间限制
  （1M 时大约 100~200 Hz 上限）；FD 5M 更快。
- **诊断**：`python tools/mc_ep.py --can <连接参数> probe` 先只听 2 s —— 打印总线上
  每个 `src`/消息类型的帧数（心跳能立刻告诉你节点 ID 对不对），再试读一次描述符。
- ⚠ **用错波特率会把设备打进 bus-off**：适配器速率不对时设备的帧没人应答，
  `can_tec` 十几帧就涨到 ~248，之后 CAN 完全“死”掉（换回正确速率也不会自己恢复）。
  恢复（用 USB）：
  `python tools/mc_ep.py --port COMx get telemetry.can_tec`（>128 就是中招了）→
  `python tools/mc_ep.py --port COMx call action.reboot`。

## 2. 读写参数

```bash
python tools/mc_ep.py --can tree                 # 参数树
python tools/mc_ep.py --can descriptor           # 原始 JSON 描述符
python tools/mc_ep.py --can get  <name>          # 读
python tools/mc_ep.py --can set  <name> <value>  # 写（打印实际值）
python tools/mc_ep.py --can call <action>        # 执行 action.*
python tools/mc_ep.py --can dump                 # 读所有可读参数
python tools/mc_ep.py --can monitor <name>... --rate 20
```

上面所有命令就是出货版本的正常用法。带 USB 的开发/台架板子把 `--can` 换成
`--port COM7`（CDC）或 `--usb` 即可，参数名和输出完全一样。

| 前缀 | 内容 | 权限 |
|---|---|---|
| `config.*` | 电流/位置/速度/电机/编码器/CAN/零点 | `rw` |
| `command.*` | 运行命令：`t_ff`/`p_des`/`v_des`/`kp`/`kd`（不持久化） | `rw` |
| `telemetry.*` | 实时测量 | `r` |
| `timing.*` | ISR 耗时统计 | `r` |
| `system.*` | 版本、硬件版本、序列号、配置序号、schema、保存状态 | `r` |
| `action.*` | 保存、置零、切模式、标定 | `w`（读/写都执行） |

规则：

- **写会被限幅**：超出 `min`/`max` 夹到边界，不报错。`set` 打印实际写入值。
- `NaN`/`Inf` → `EP_ERR_BAD_VALUE`（3）。
- 写只读端点 → `EP_ERR_READ_ONLY`（4）。
- **读动作端点也会执行它**（ODrive 的 endpoint 协议没有读写标志，功能端点被读
  也会执行，这里跟随它以便兼容按 ODrive 语义调用动作的上位机）。`require`/状态
  前置条件仍生效，例如门极使能时读 `action.save` 返回 `EP_ERR_STATE`（6）而不会存盘；
  但 `action.idle_mode`/`action.clear_fault`/`action.reboot` 等没有 `require`，一次读
  就会停机或复位。**遍历参数的上位机要跳过 `function` 类型**（`mc_ep.py dump`
  已经这么做）。
- 状态前置条件不满足（如门极使能时改 `config.ppairs`）→ `EP_ERR_STATE`（6）。
- `config.p_min`/`v_min` 可单独写（通常由 `p_max`/`v_max` 联动），用于备份恢复。

状态码：0 OK、1 未知 ID、2 长度错、3 数值非法、4 只读、5 只写、6 状态不允许、
7 描述符版本不匹配（工具会自动重新下载描述符）。

### 设备身份

```bash
python tools/mc_ep.py --can get system.fw_version_major      # 2
python tools/mc_ep.py --can get system.fw_version_minor      # 3
python tools/mc_ep.py --can get system.fw_version_revision   # 0
python tools/mc_ep.py --can get system.fw_version_unreleased # 0 = 正式版
python tools/mc_ep.py --can get system.hw_version_major      # 1 (CBL89)
python tools/mc_ep.py --can get system.serial_number         # 十进制
```

- 版本号只有**整数三元组**这一个来源：`fw_version_major.minor.revision`
  （本版 `2.3.0`），`fw_version_unreleased` 为 1 表示这是带 `-dirty`/预发布后缀的
  构建。启动横幅（`Firmware Version Number: 2.3.0`）报的也是同一组数。
- 老协议的 CAN 版本变量（`CAN_VAR_VERSION`）仍然是 float32，编码为
  `major + 0.01×minor`（本版 `2.3.0` → `2.03`，读作 "V2.03"；minor 可以 0–99）。
  修订号不进 float，需要时读 `system.fw_version_revision`。因为协议里那个位置
  就是浮点数，所以只能用这种打包方式 —— 用 `0.1` 的话 minor ≥ 10 会进位到整数
  部分（`2.10` 变成 `3.0`）。
- **`system.serial_number`** 是芯片 96 位唯一 ID 的低 64 位，**每个芯片不同**，
  适合当设备指纹（多台设备同一条总线上区分、日志/标定记录归档）。
  它不依赖 EEPROM，所以换固件/整片擦除都不会变。
- CYBERBEAST 的 `QUERY_DEVICE_INFO (0x46)` 报的是同一组值；CAN FD 下 8–15 字节
  还带 64 位序列号（大端），Classic 帧只有 8 字节，序列号用 `PARAM_READ` 读
  `system.serial_number`。

### 在 Python 脚本里用

```python
import sys
sys.path.insert(0, "tools")
from mc_ep import Device

dev = Device(can_interface="slcan")     # CAN（出货默认；不填 channel 会自动找 CANable）
# dev = Device(can_interface="pcan", can_bitrate=1_000_000)
# dev = Device(can_interface="socketcan", can_channel="can0")
# dev = Device("COM7", 115200, 1.0)     # 开发板 CDC
# dev = Device(use_usb=True)            # 开发板 vendor interface（需要 pyusb/WinUSB）
dev.fetch_descriptor()
print(dev.read("config.gr"))
dev.write("config.gr", 9.0)
dev.call("action.save")
print(dev.read("system.save_status"))
dev.close()
```

## 3. 保存

改参数只改 RAM，**断电会丢**：

```bash
python tools/mc_ep.py --can call action.save
python tools/mc_ep.py --can get system.save_status
# 0 还没执行 / 1 成功 / 2 因门极使能跳过 / 3 写失败
python tools/mc_ep.py --can get system.prefs_sequence   # 成功时 +1
```

`call action.save` 返回 OK 只表示**已受理**，真正的擦写在主循环里做；用
`save_status` 或 `prefs_sequence` 确认。

保存过程中掉电：上电后仍是上一次的完整配置（双页 + 序号）。

## 4. 动作与模式

```bash
python tools/mc_ep.py --can call action.idle_mode    # 空闲/停机：关门极、清锁存故障
python tools/mc_ep.py --can call action.motor_mode    # 进入电机模式
python tools/mc_ep.py --can call action.calibrate     # 标定（相序/编码器/R/L/磁链）
python tools/mc_ep.py --can call action.zero          # 当前位置设为零点并保存
python tools/mc_ep.py --can call action.clear_fault   # 等价于 action.idle_mode
python tools/mc_ep.py --can call action.reboot        # 重启（应答发出后 ~0.5 s 复位）
python tools/mc_ep.py --can call action.reset_config  # 恢复出厂默认值并保存
```

`action.idle_mode` 会停机并清故障，是正常的"急停"用法。

### 纯力矩加载测试

`command.*` 是运行命令，只在 MOTOR_MODE 里被控制环使用，**不持久化**：

| 名称 | 含义 |
|---|---|
| `command.t_ff` | 前馈力矩（输出轴 N·m），固件限幅到 ±`config.mit_tau_max`（0 = 沿用 `I_MAX*KT*GR`） |
| `command.p_des` / `command.v_des` | 位置/速度设定值（输出轴） |
| `command.kp` / `command.kd` | 位置/速度增益 |

纯力矩：`kp = kd = 0`，只改 `command.t_ff`。

**命令租约**：`command.*` 的每次写入都会把 `controller.timeout` 清零，和 CAN 帧一样。
`config.can_timeout`（毫秒，默认 100）内没有新的写入，控制 ISR 就会把所有命令清零
——这是**保护**，不是麻烦：主机掉线/脚本崩溃时电机自动卸力。所以不要为了"设一次
就一直保持"去关它；要么按超时窗口持续刷新（≥3 次/窗口），要么把
`config.can_timeout` 调大到你想接受的失联时间（例如 500 ms）。

进入 MOTOR_MODE 时固件会先 `zero_commands()`，所以**门极一打开命令就是 0**：
在空闲态写 `command.*` 不会在使能瞬间生效，必须在电机模式下重新写。

⚠ 纯力矩没有速度环：**空载会一直加速**。必须接负载/测功机，并随时准备
`action.idle_mode` 或断电。

⚠ 纯力矩也受**位置软限位**约束：实测位置越过 `config.p_max`/`p_min` 之后，固件只
放行**回转方向**的力矩（越界方向的 `i_q_des` 每拍被压成 0，`command.t_ff` 本身不变，
`telemetry.i_q_des` 看到的是被闸后的值）。所以：持续给同方向力矩**推不动**它继续往外
（该方向力矩为 0，负载/重力会把它带回界内，纯力矩没有速度环、不会主动"顶住"边界），
给反方向就正常转回来。MIT（`kp > 0`）不受影响：它的 `p_des` 已被钳在限位内，弹簧本身
就给反向力矩。`set config.p_max 0` 可关闭软限位（见“CSV”一节）。

```bash
python tools/torque_test.py --port COM7 --torques 0,2,4,6 --dwell 5
```

脚本会：按 `can_timeout` 自动选刷新率 → 进 MOTOR_MODE → 逐档施加 `t_ff` 并在每轮
重写（刷新租约）→ 打印 `i_q`/`torque`/`v_bus` → 结束或 Ctrl+C 时卸力并回菜单。
故障位非 0 立即停机；链路断开时脚本会明确提示"力矩可能仍在输出"。
单档手动操作就是：

```bash
python tools/mc_ep.py --can call action.idle_mode
python tools/mc_ep.py --can call action.motor_mode
python tools/mc_ep.py --can get telemetry.gate_drive     # 应为 true
python tools/mc_ep.py --can set command.kp 0
python tools/mc_ep.py --can set command.kd 0
python tools/mc_ep.py --can set command.t_ff 3
python tools/mc_ep.py --can get telemetry.torque
python tools/mc_ep.py --can set command.t_ff 0
python tools/mc_ep.py --can call action.idle_mode
```

（手动分批敲命令时，两条之间可能超过 `can_timeout`，固件会先把命令清零——这是
正常的，重新写一次即可；要连续保持就用脚本。）

**`action.reset_config`（恢复出厂默认值）**：会连标定一起清掉——`ppairs`、零点、
编码器 LUT 全部回默认，必须**重新标定**；`CAN_ID / CAN_PROT / CAN_BAUD` 也会回默认
（**CYBERBEAST + Classic 1 Mbit/s**），所以复位后要**核对 CAN 设置**，否则主站可能再 也
连不上。为避免"改了 CAN 设置却不重启"造成的失联和混合状态，**保存成功后固件会自动
重启**（约 0.5 s，门极先关闭）。和 `action.save` 一样，门极使能时会被直接拒绝
（`mc_ep.py` 报 `status 6` = `EP_ERR_STATE`，配置一个字都不动）；受理之后的结果看
`system.save_status`（1 成功 / 3 写失败，写失败时**不会**重启，默认值只在 RAM 里）。
运行中的编码器副本仍用
旧标定，直到重启才换成默认值——这是故意的（拿全零 LUT 去换相不安全）。

**`action.reboot`**：先回菜单（关门极）再在 0.5 s 后复位，配置按 flash 里已保存的值
重新加载。没保存过的改动会丢——先 `action.save` 再 `action.reboot`。

### 速度环与位置环（CSV / CSP）

固件自带速度环和位置环（CYBERBEAST 的 `0x02/0x82` CSV、`0x01/0x81` CSP 就是它们），
用 USB 也能直接用 `command.mode` 试：

| `command.mode` | 控制律 | 用的命令量 |
|---|---|---|
| 0（默认） | 阻抗/MIT | `t_ff` + `kp`·`p_des` + `kd`·`v_des` |
| 1 | 速度环（CSV） | `v_des` |
| 2 | 位置环（CSP） | `p_des` |

先配增益（都是**输出轴**量，控制输出是电机端安培）：

| 参数 | 单位 | 出厂值 | 说明 |
|---|---|---|---|
| `config.pos_gain` | (rad/s)/rad | 20 | 位置误差 × 它 = 速度指令（配方值 `ω_c/30`=15，配 `accel_limit 200` 时 20 更合适） |
| `config.vel_gain` | A/(rad/s) | 1.397 | 速度误差 × 它 = 电流指令 |
| `config.vel_integrator_gain` | A/(rad/s)/s | 25.15 | 消掉重力/摩擦下的稳态误差 |
| `config.pos_ff_gain` | — | 1.0 | CSP 帧间速度前馈；1 = 全前馈，0 = 关 |
| `config.accel_limit` | rad/s² | 200 | 速度设定值的**加速**斜率（`input_mode=2` 时生效）；0 = 关。**CSP 想快就先放开它**，比加 `pos_gain` 安全：50 时 2 rad 阶跃过冲 22.9%，200 时 1.5% |
| `config.decel_limit` | rad/s² | 200 | 速度设定值的**减速**斜率（`input_mode=2` 时生效）；0 = 与 `accel_limit` 相同 |
| `config.vel_ramp_rate` | rad/s² | 0 | `input_mode=2` 的对称斜率（ODrive 的 `vel_ramp_rate`）：>0 时加速与减速都用它；0 = 用上面两个 |
| `config.trap_vel_limit` | rad/s | 0 | `input_mode=5` 的巡航速度上限（与帧内/`v_max` 限速取较小值）；0 = 用运行期限速 |
| `config.trap_accel_limit` | rad/s² | 0 | `input_mode=5` 的加速度；0 = 用 `accel_limit` |
| `config.trap_decel_limit` | rad/s² | 0 | `input_mode=5` 的减速度；0 = 用 `decel_limit` |
| `config.input_mode` | — | 2 | 输入整形：0 忽略、1 直通、**2 速度斜率（默认）**、3 位置跟踪滤波、5 梯形位置规划、6 转矩斜坡、9 MIT；4/7/8 不支持（按直通） |
| `config.input_bw` | 1/s | 10 | 只对 `input_mode=3` 有效；4 kHz 位置环上实际可用上限约 45，超了固件会自动压低增益 |
| `config.torque_ramp_rate` | N·m/s | 1.0 | 只对 `input_mode=6` 有效：前馈转矩的斜率；0 = 不限 |
| `config.mit_tau_max` | N·m | 5.0 | **力矩满量程**（输出轴）：MIT(`0x00/0x80`) 12 位力矩位域的定标，也是 `command.t_ff` / `TORQUE` / `CURRENT` / 旧协议 `SET_TFF` 的钳位上限；0 = 沿用 `I_MAX*KT*GR`。⚠ 这是**线上量程**，上位机必须用同一个值编解码；实际能出的力矩仍受 `I_MAX*KT*GR` 限制（4 A 时约 1.2 N·m，出厂上限 12 A 时约 3.6 N·m），超出的部分只是让电流环饱和 |
| `config.enable_vel_limit` | — | true | 关掉后 CSV/CSP 不再受 `config.v_max` 约束（`command.v_des` 的物理范围变成 ±200 rad/s） |
| `config.enable_torque_vel_lim` | — | false | 打开后在 MIT/力矩/电流模式也按 `v_max` 限速（`i_q ≤ (v_max−v)·vel_gain`） |
| `config.pos_error_fault` | rad | 0 | 跟随误差故障阈值，0 = 关 |
| `config.pll_bandwidth` | rad/s | 2000 | 编码器速度估计带宽（约 318 Hz）；低速抖就降到 1000，想要更高带宽就升到 3000 |
| `config.inertia` | kg·m² | 0.00096 | 输出端惯量，由 `action.measure_inertia` 测得（只写 RAM）。**默认值只是本台架的实测值**，换电机/换关节必须重测 |
| `config.omega_c` | rad/s | 450 | `action.tune_gains` 的目标穿越频率（越大越激进，300–600 起试） |
| `config.tune_margin` | × | 1.5 | `action.tune_gains` 对速度环的放大系数：摩擦/齿隙大的关节要调大；1 = 纯公式（只适合纯惯性负载）。本台架 GR 9 + 电流环按标定 R/L 推导后实测 1.5（1.7 起超调 >25%，2.2 失稳） |

```bash
python tools/mc_ep.py --can set config.pos_gain 20
python tools/mc_ep.py --can call action.motor_mode
python tools/mc_ep.py --can set command.mode 1
python tools/mc_ep.py --can set command.v_des 1.0
python tools/mc_ep.py --can monitor telemetry.vel_err telemetry.vel_integral
python tools/mc_ep.py --can set command.mode 0      # 回阻抗/MIT
python tools/mc_ep.py --can call action.idle_mode
```

#### 不用脚本，手工发 CSV / CSP

`tools/csv_csp_test.py` 只是把下面几条封装起来，手动测试完全可行，但有 4 个坑：

1. **命令租约**：每次写 `command.*` 都把租约重置为 `config.can_timeout`（默认
   **100 ms**）。超时后 `zero_commands()` 清掉设定值**并把 `command.mode` 复位成 0
   （MIT）** —— 于是关节卸力、你再写 `v_des` 也没反应（因为已经不是 CSV 模式了）。
   手动测试先放大租约，测完改回去：
   ```bash
   python tools/mc_ep.py --can set config.can_timeout 60000    # 60 s
   ```
2. **CSP 要先把 `p_des` 写成当前位置，再切模式**。先 `set command.mode 2` 的话，
   `p_des` 还是 0（或上一次的值），位置环会立刻按 `pos_gain·err` 冲过去。
3. **`p_des` 受 `config.p_max`（默认 ±12.5 rad）钳位**，超范围不是拒绝而是**钳到边界**，
   目标可能落在关节另一侧。**已经在限位外时**放宽：可以给一个仍在界外、但朝界内的
   目标（限位 0~10、当前 15 → 写 12 会让它先退到 12；写 16 会被压回 15），但不能命令
   比当前位置更外的点。`telemetry.position` 是绝对多圈位置（跑过之后可能远大于
   12.5）。要么临时放大 `config.p_max`，要么 `action.zero` **+ `action.reboot`**
   —— 零点只在重启后才生效（`M_ZERO` 在启动时重新对齐多圈计数）。
   `set config.p_max 0`（会同时把 `p_min` 置 0）等于**关掉软限位**：通信层与位置环
   都不再钳 `p_des`，只适合调试/行程未知的机构，**别留在整机上**。
4. **`action.motor_mode` 只能在菜单态调用**，否则返回状态 6；`action.idle_mode`
   回菜单并关栅。`monitor` 会独占连接（串口或 CAN 适配器），Ctrl+C 退出后才能发下一条命令。

**CSV**（速度环）：

```bash
python tools/mc_ep.py --can set config.can_timeout 60000
python tools/mc_ep.py --can call action.motor_mode          # 开门极（需菜单态）
python tools/mc_ep.py --can set command.mode 1              # 0=MIT 1=CSV 2=CSP
python tools/mc_ep.py --can set command.v_des 1.0           # 输出轴 rad/s
python tools/mc_ep.py --can monitor telemetry.velocity_pll telemetry.vel_err telemetry.i_q --rate 5
python tools/mc_ep.py --can set command.v_des -1.0          # 反向
python tools/mc_ep.py --can set command.v_des 0
python tools/mc_ep.py --can call action.idle_mode
python tools/mc_ep.py --can set config.can_timeout 100
```

判读：`velocity_pll` 应跟住 `v_des`；低速时 ±0.2~0.4 rad/s 的抖动是干摩擦 + 齿隙，
正常。`vel_err` 长期很大 ⇒ `vel_gain` 不够；振荡发散 ⇒ 太大。

⚠ **CSV 也受位置软限位约束**：实测位置越过 `config.p_max`/`p_min` 之后，固件只放行
**回转方向**的速度（越界方向的那一拍按 0 处理），继续给越界方向的 `v_des` 只会让
关节顶在边界上；给反方向就能正常转回来。判据是实测位置、没有滞环，
`telemetry.v_setpoint` 可以看到被闸后的实际设定值（`command.v_des` 仍是主站写的值）。
`set config.p_max 0` 可关闭（见上一节）。

**CSP**（位置环）：

```bash
python tools/mc_ep.py --can set config.can_timeout 60000
python tools/mc_ep.py --can call action.motor_mode
python tools/mc_ep.py --can get telemetry.position          # 记下 P0（rad）
python tools/mc_ep.py --can set command.p_des <P0+0.3>      # ← 先给目标
python tools/mc_ep.py --can set command.mode 2              # ← 再切模式
python tools/mc_ep.py --can monitor telemetry.position telemetry.pos_err --rate 5
python tools/mc_ep.py --can call action.idle_mode
python tools/mc_ep.py --can set config.can_timeout 100
```

判读：`pos_err` 收敛到 0.0x mrad，`position` 最后精确等于 `p_des`
（台架实测 0.3 rad 阶跃最终 `pos_err ≈ 3e-5 rad`）。

⚠ 切到 CSP 时如果关节**已经在 `config.p_max`/`p_min` 之外**，固件不会自己把它拉回
限位：位置环冻结、零速保持原地，直到你写入一个**不同的** `command.p_des`，或者关节
自己回到界内。所以界外恢复的顺序是**先切模式、再写目标**：

```bash
# 例：限位 0~10 rad，关节当前在 15 rad
python tools/mc_ep.py --can set command.mode 2        # 冻结：不动
python tools/mc_ep.py --can set command.p_des 12      # 解除冻结，退到 12（仍在界外）
python tools/mc_ep.py --can set command.p_des 13      # 无效：被压回 12，无法远离限位
python tools/mc_ep.py --can set command.p_des 5       # 继续往界内，正常跟踪
```

界内则两种顺序都可以（上面的「先给目标再切模式」仍然是最稳的写法）。如果界外时
`p_des` 本身已经是一个界外的"往回收"目标（比如先写了 12 再切模式），会直接跟踪它、
不冻结；冻结只针对"目标落在界内、很可能是陈旧值"的情况。

- **增益要按关节整定**：出厂值（`vel_gain 1.397`、`vel_integrator_gain 25.15`、
  `pos_gain 20`、`accel_limit 200`、`pll_bandwidth 3000`、`tune_margin 0.94`）是
  2026-11-16 在本台架（`KT 0.0335`、`J 0.000996`、`GR 9`、电流环 `i_bw 1000` 按标定
  R/L 推导）整定的结果，**换电机/换关节必须重做**。
  方法见 [DEV.md](DEV.md) 的“台架整定步骤”，工具是 `tools/csv_csp_test.py`。
  ⚠ 更早那批“`vel_gain 2.469` / J 0.0006”的数据是在 **GR 被误配成 7.75** 时测的；
  2026-11-06 按 GR=9 重算的那组（`2.158 / 38.85 / 15 / 50`）已被 11-16 这组取代
  —— 后者把速度反馈 PLL 带宽提到 3000，并把 `accel_limit` 放到 200，速度环取更
  保守的 1.397 换取阻尼（P-only 5 rad/s 阶跃过冲从 38% 降到 15%）。
- **两条路可选**：① 一条命令 `action.tune_gains`（先做 `action.measure_inertia`），
  配方 = 惯量 + `config.omega_c`(450) + `config.tune_margin`(0.94)；② 手工扫
  `csv_csp_test.py sweep`。当前出厂值实测工作点：

  | 模式 | 参数 | 值 | 效果 |
  |---|---|---|---|
  | MIT | `command.kp` / `kd` | **20 / 0.20**（阻尼准则 `kd = 1.4·√(kp·J)`，ζ≈0.7） | 0.2 rad 阶跃过冲 0.5%、56 ms 稳定；kp 10~100 都适用（kp 100 → kd 0.44） |
  | CSV | `vel_gain` / `vel_integrator_gain` | **1.397 / 25.15** | 1 rad/s 阶跃过冲 4~9%、稳态误差 0.1%、t90 55 ms；5 rad/s 过冲 0.9% |
  | CSP | `pos_gain` / `accel_limit` | **20 / 200** | 0.2/0.5/1/2 rad 阶跃过冲 0.4/0.1/0.1/1.5%，0.2 rad ≈ 0.27 s |

  `accel_limit` 是 CSP 变快的关键：位置环是纯 P，它给出的速度设定值被斜率限制拖慢时
  会出现“追上了速度还没降下来”的过冲（1 rad 阶跃：`accel_limit 10` 过冲 49%、
  50 时 4.8%、200 时 0.1%）。**想要更快的 CSP 请先放开 `accel_limit`，不要只加
  `pos_gain`**——`pos_gain` 超过 20~25 后大阶跃反而会过冲（30 时 1 rad 6.4%、2 rad 27%）。
- ⚠ **`command.p_des` 会被 `config.p_max` 钳位，不是拒绝**：反复跑速度测试后
  绝对位置会漂移，一旦漂到 `p_max`（默认 ±12.5 rad）之外，CSP 的每个目标都被钳在
  边界上，看起来像“位置环完全不动”。处理：放大 `config.p_max`，或 `action.zero`
  **+`action.reboot`**（零点只在重启后生效）。临时调试可以 `set config.p_max 0`
  关掉软限位（见上）。
- 每条命令都刷新“命令租约”（同 `command.*`）：`config.can_timeout` 内没有新命令，
  固件就把命令清零 → **卸力**，不是保持位置。周期同步的主站不会碰到这个问题。
- 进电机模式、超时、故障都会把 `command.mode` 复位成 0（阻抗）。
- 速度限幅：CSV 用 `config.v_max`，CSP 用帧里的 `vel_limit`（RPM，输出端）。
  帧里给 0 视为“未指定”，按 `config.v_max` 处理。把 `config.enable_vel_limit`
  设成 0 就完全不受 `config.v_max` 约束（只剩 ±200 rad/s 的物理范围）。

#### 输入整形：轨迹模式（关节更顺、少冲击）

默认 `config.input_mode = 2`（速度斜率，与旧固件一致）。想让点到点运动真正平滑
（先加速、匀速、再减速），用梯形规划：

```bash
python tools/mc_ep.py --can set config.input_mode 5       # 5 = TRAP_TRAJ
python tools/mc_ep.py --can set config.trap_vel_limit 2.0  # 轨迹巡航速度（输出轴 rad/s）
python tools/mc_ep.py --can set config.trap_accel_limit 10 # rad/s²
python tools/mc_ep.py --can set config.trap_decel_limit 5  # 减速更缓
python tools/mc_ep.py --can set command.mode 2             # CSP
python tools/mc_ep.py --can set command.p_des 1.0
```

- **轨迹有自己的一组限值**（对应 ODrive 的 `trap_traj.config.*`）：
  `config.trap_vel_limit` / `trap_accel_limit` / `trap_decel_limit`。
  **默认全 0 = 沿用 `config.v_max` / `accel_limit` / `decel_limit`**，所以不配也能用；
  配上就能"轨迹慢慢爬、手动高速点动"共存。
  `trap_vel_limit` 只能**收紧**（与帧内 `vel_limit` / `config.v_max` 取较小值）。
- TRAP_TRAJ 会在**位置环**里生成位置+速度设定，速度直接做位置环前馈；中途改
  `command.p_des` 会从当前位置/速度重新规划，不会跳变。
- `config.input_mode = 3` 是二阶跟踪滤波（不是规划，只是把设定值"跟"过去），
  调节 `config.input_bw`（默认 10 1/s，越大跟得越快；4 kHz 位置环上约 45 就饱和）。
- 这两个模式下 `config.pos_ff_gain` 的帧间前馈不参与（轨迹速度取代它）。
- `config.input_mode = 1/9` 是直通（不做任何斜率限制）；`0` 是忽略输入（保持设定值）。
- 阻抗/MIT 模式下想让力矩缓慢建立，用 `config.input_mode = 6` +
  `config.torque_ramp_rate`（N·m/s）。
- ⚠ **`input_mode` 不是 `command.mode`**：前者整形设定值，后者选控制环。两者都设。

- **位置跟随误差故障**默认关闭。打开后（`config.pos_error_fault > 0`）只要位置环
  没被速度限幅饱和、误差又连续超过阈值 100 ms，就锁存故障、关栅停机，需要
  `action.idle_mode` 才能清除。阈值必须**小于 `config.v_max / config.pos_gain`**，
  否则永远触发不了。
- 环率：速度环 = 40 kHz / `config.vel_loop_prescaler`（默认 5 → 8 kHz），
  位置环 = 速度环 / `config.pos_loop_prescaler`（默认 2 → 4 kHz）。设成 1/1 就是
  两个环都跑 40 kHz（电流环永远是 40 kHz，不受影响）。
- **电流环带宽** `config.i_bw`（默认 1000 Hz）：P/I 增益按标定出来的
  `config.r_phase` / `l_d` / `l_q` 自动推导（极点对消），所以**这个数就是实际带宽**，
  换电机不用重调；写入后**立即生效，不需要重启**。实测 300~800 最稳，
  >1000 开始被采样延迟吃掉相位裕度（2000 是上限）。⚠ 电流环变快后外环会显得
  更"冲"，改完 `i_bw` 记得重跑一次 `action.tune_gains` + `csv` 验证。
- **惯量标定**：`action.measure_inertia` **一条指令完成**——自动进电机模式、打两个
  电流台阶测出输出端惯量、再自动回菜单（约 3 s；内部连测 **3 次取中位数**，关节净行程 ~0.5 rad）。结果写入
  `config.inertia`，**不自动保存**；进度和结果看 `system.inertia_status`（2 = 成功）。
  有了它就能用公式算推荐增益，`telemetry.pos_error_fault_suggest` 也会给出跟随误差
  故障的推荐阈值。
  ```bash
  python tools/mc_ep.py --can call action.measure_inertia
  python tools/mc_ep.py --can get system.inertia_status
  python tools/mc_ep.py --can get config.inertia
  python tools/mc_ep.py --can call action.save      # 确认可用后再保存
  ```
  然后 `vel_gain = inertia·ω_c/(KT·GR)`、`pos_gain ≈ ω_c/5`（`ω_c` 300–600 rad/s 起步，
  见 [DEV.md](DEV.md) 的“惯量标定与增益推荐值”）。
- **自动算增益**：`action.tune_gains` 用上面的惯量一步算出三个外环增益并**直接写进
  RAM**（不自动保存）：
  ```bash
  python tools/mc_ep.py --can set config.omega_c 450       # 目标穿越频率
  python tools/mc_ep.py --can set config.tune_margin 2.6   # 摩擦大的关节放大速度环；1 = 纯公式
  python tools/mc_ep.py --can call action.tune_gains
  python tools/mc_ep.py --can get config.vel_gain          # 已经写进去了
  python tools/csv_csp_test.py --port COM6 csv --vel 1.0         # 验证
  python tools/csv_csp_test.py --port COM6 csp --step 0.2
  python tools/mc_ep.py --can call action.save             # 满意后再保存
  ```
  写入关系：`vel_gain = tune_margin·J·ω_c/(KT·GR)`、
  `vel_integrator_gain = vel_gain·clamp(ω_c/25, 5, 30)`、`pos_gain = ω_c/20`。
  两个分母（25 / 20）是按台架实测定的：积分开太快会 stick-slip，`pos_gain` 大了
  齿隙会让位置过冲。要求菜单态、`config.inertia > 0`（先做惯量标定）；门极打开时
  会返回状态 6。
- **`action.measure_inertia` 的“没反应”不一定是失败**：整个过程只有 ~2–4 s、
  电流 0.15–0.25 A、输出轴净行程 ~0.5 rad（~28°，它内部连测 3 次取中位），末了自动回菜单。用
  `get system.inertia_status` 判断（1 运行中 / 2 成功 / 3 关节本来在动 /
  4 加电流也不动 / 5 台阶太短 / 6 激励不足）；`call` 只表示"请求已受理"。

### 保护与限幅

| 参数 | 默认 | 说明 |
|---|---|---|
| `config.vbus_ov_trip` | 67 V | 母线**过压**硬故障：超过即锁 `FAULT_OV`、关栅。任何状态都检查（门极关着也可能被外部推高） |
| `config.vbus_uv_trip` | 0 = 关 | 母线**欠压**故障：只在门极使能时判定，约 10 ms 去抖。0 表示关闭；只有 USB 供电时不会误跳 |
| `config.i_dc_max` | 0 = 关 | 母线电流**软限幅**。硬件没有直流分流器，固件按 `P = 1.5·V_PER_CMD·(v_d·i_d+v_q·i_q)` 估算母线电流并回压电流指令。**只限流不报错**，别当保护用 |
| `config.torque_lim` | 0 = 关 | **输出端**转矩上限（N·m，与 `command.t_ff`/`telemetry.torque` 同量纲）。0 = 不限 |
| `config.fet_temp_en` / `_lo` / `_hi` | 关 / 75 / 95 °C | MOS 温度保护：`lo` 开始线性降流、到 `hi` 电流上限降到 0、超过 `hi+5 °C` 锁 `FAULT_FET_OT` |
| `config.mot_temp_en` / `_lo` / `_hi` | 关 / 75 / 95 °C | 电机温度保护，同上（`FAULT_MOT_OT`） |

温度全程可读（即使保护关着）：`telemetry.mos_temp` / `telemetry.mot_temp`
（`telemetry.temperature` 是 MOS 温度的别名）。

> ⚠ **NTC 换算是照搬 ODrive 板的系数**。第一次上台架请用室温核对这两个读数：
> 明显偏离（例如 25 °C 读到 60 °C 或负值）说明 CBL89 的分压网络不同，需要改
> `foc.c` 里的多项式系数，**在校正前不要打开 `fet_temp_en` / `mot_temp_en`**。

新增故障位：`4 = FAULT_UV`（欠压）、`32 = FAULT_FET_OT`（MOS 过温）、
`64 = FAULT_MOT_OT`（电机过温）。清除方式与其他故障一样：`action.idle_mode`
（回菜单即清）。

## 5. 标定

第一次使用、换电机/编码器、整片擦除后要做一次。**OTA 升级不需要重新标定。**

前置：电机轴能自由转动；动力电已上；`config.i_cal` 合适（默认 5 A，小电机
可降到 1–2 A，R/L/磁链测量时会自动限制在 `config.i_max` 以内）；门极关闭（菜单）。

```bash
python tools/mc_ep.py --can call action.idle_mode
python tools/mc_ep.py --can set config.i_cal 2.0
python tools/mc_ep.py --can call action.calibrate
```

标定分四个阶段，全部自动完成（14 极对时约 30 s，串口会打印每一步的结果）：

1. **相序/极对数**：对齐后正转 **3 个电周期**，行程用**匀速段**上两个采样点
   （斜坡的 20% 与 90%）的差来算、再乘 0.7 外推全程（转子同步旋转时负载角恒定，
   差分里抵消；不能用静止点——静摩擦死区会让 11 极对随机算成 12），再按
   `3 × 2π / 机械行程` 求极对数。串口打印的 travel 是**外推后的 3 周期行程**
   （11 极对约 1.71 rad），不是单周期那 0.57 rad；
2. **编码器**：正反转各一圈采样，得到电角度零位 `E_ZERO` 和 128 点 LUT；
3. **R / L / Ld / Lq**：先用两段直流（`i_cal/2` 和 `i_cal`）外推相电阻，
   再用 ±2 V 电压翻转测电感；然后在 alpha、beta 两个方向分别锁住转子，
   测出 `Ld` 与 `Lq`（感差 `Ld-Lq`）；
4. **磁链 / Kt**：开环升速到 60 rad/s（电角度）后由稳态 q 轴电压方程算出
   磁链 `λ`，并令 `Kt = 1.5 × 极对数 × λ`。

完成后自动回菜单、应用结果并保存（LUT 写入隐藏记录 `internal.encoder_lut`）。核对：

```bash
python tools/mc_ep.py --can get system.save_status      # 1
python tools/mc_ep.py --can get system.prefs_sequence   # 比标定前 +1
python tools/mc_ep.py --can get config.r_phase          # 欧姆
python tools/mc_ep.py --can get config.l_d              # 亨利
python tools/mc_ep.py --can get config.l_q
python tools/mc_ep.py --can get config.kt               # N-m/A
python tools/mc_ep.py --can get telemetry.ld_lq_diff    # Ld-Lq
```

串口会在 R 阶段两步之间打印 `R step 1: <V> @ <A>`。相电阻大时第二步电压会被
`CAL_LOCK_V_MAX` 钳位，固件用**实测电流**计算 R，不会因此失败；只有两步电流差
太小（开路、母线电压太低）才失败。失败（电机卡住、动力电不足、`i_cal` 不合适、
电流跟不上）会自动回菜单，**不写 flash**；可先降低 `config.i_cal` 再试，随时
`call action.idle_mode` 中止。

标定结果里 `E_ZERO`/`PPAIRS`/零点/`r_phase`/`l_d`/`l_q`/`kt` 都在 `config.*`，
128 点 LUT 在隐藏记录里，**都持久化、都随 OTA 保留**；LUT 不可通过 endpoint 备份。
`telemetry.flux_linkage` 是 `kt` 与极对数换算出来的只读值（λ = Kt/(1.5·极对数)），
因此重启后仍能读到标定得到的磁链。

**`config.pre_calibrated`（已标定标志）**：标定全部成功并保存后会置 1，它同时是
**进入电机模式的前置条件**——为 0 时 `action.motor_mode` 返回状态码 6（`EP_ERR_STATE`），
串口按 `m` 会打印"Motor mode refused"，CYBERBEAST 的 `START_MOTOR` 也不会生效
（状态一直停在 IDLE）。以下情况会重新变成 0：

- 进入标定模式（哪怕中途失败）；
- `action.reset_config`（恢复出厂默认值）。

所以"换了板子 / 整片擦除 / 恢复默认值后电机使能不了"是**正常行为**：重新
`call action.calibrate` 即可。也可以手工 `set config.pre_calibrated 1` 跳过检查
（仅在标定数据确实有效时这么做；门极使能时该参数不可写）。

## 5.1 齿轮式双编（断电记忆输出轴位置）

硬件在转子齿轮旁啮合了一个齿数不同的小齿轮、轴上装第二颗绝对编码器。两路单圈
绝对值合起来能算出转子转到了**第几圈**，所以断电再上电，输出轴位置直接接上，
不需要重新回零（原理与约束见 [DEV.md](DEV.md) 的"齿轮式双编"一节）。

前提：两颗磁编都装好（同一 SPI，NSS 分开）、齿轮齿数已知且**接近但不等**
（量程 = ±T2/(2|T1−T2|) 转子圈；34/33 给 ±16.5 圈，本机的 30/27 只给 ±4.5 圈
= ±0.5 输出圈（GR = 9））。齿数成比例（10/9 = 20/18 = 30/27）行为相同，填真实
物理齿数即可。

**固件自己会检测**：上电时、以及每次进入标定（`action.calibrate` / 串口 `c`）的开始，
都会探一次副编码器并打印

```
GEAR: second encoder found (raw 12345, teeth 30/27) - reference will be captured at the end
GEAR: no second encoder - output position memory stays off
GEAR: second encoder found, but gear config is invalid (T1=30 T2=27) - memory off
```

`telemetry.sec_enc_present` 是同一个结论（只读）。**标定成功收尾时会自动把当前位置
记成双编参考**并一起存盘，所以只要硬件在、齿数填对，走一遍正常标定就够了，不用
额外操作。下面的手动步骤只在"单独想重取参考"或"没做标定时"才需要：

```bash
# 1) 填齿数与减速比（出厂默认 30/27、GR=9、副轴反向；换电机/换减速机时才要改）
python tools/mc_ep.py --can set config.gear_teeth_first 30
python tools/mc_ep.py --can set config.gear_teeth_sec 27
python tools/mc_ep.py --can set config.gear_sec_reversed true
python tools/mc_ep.py --can set config.gr 9.0

# 2) 把"现在这个位置"定为输出轴的绝对参考（不转电机，门极关闭时）
python tools/mc_ep.py --can call action.gear_capture
python tools/mc_ep.py --can get system.gear_status     # 1 = 成功
python tools/mc_ep.py --can get telemetry.sec_enc_raw  # 第二颗编码器的原始读数

# 3) 存盘（capture 只改 RAM）
python tools/mc_ep.py --can call action.save
```

之后每次上电，开机横幅会打印 `Gear encoder: restored multiturn position ... turns`，
`telemetry.position` 从断电前的位置继续；没装第二颗编码器的板子打印
`Gear encoder: no second encoder - output position memory stays off`。

- **`action.zero`**（把当前位置设成零点）现在**清零后 `telemetry.position` 就是 0**
  （旧固件只重设单圈零点，整圈计数留在原处，读数会停在整圈上），并且会把双编参考
  平移同样的量，所以零点与记忆的位置始终一致。`config.m_zero` 的写入口走同一个
  `ps_set_m_zero()`，直接改它不会破坏双编参考。
  注意它**不会**重取参考：记忆窗口仍以原参考位姿为中心（窗口 ±4.5 转子圈 = ±0.5
  输出圈），想让窗口重新以零点为中心，就在轴静止、门极关闭时再跑一次
  `action.gear_capture` + `action.save`。
- **`action.gear_read`** 只读一次并刷新 `telemetry.sec_enc_raw` /
  `telemetry.sec_enc_phase` / `telemetry.gear_abs_turns`，不写 flash —— 校准/验收
  时用它和 `telemetry.position_motor` 对比。
- **`system.gear_status`**：1 成功、-1 齿数/方向配置非法、-2 还没有参考
  （先 `action.gear_capture`）、-3 副编码器没响应（没插/接线断）、-4 门极使能时被拒绝。
- 没做 capture（`config.gear_ref_valid = 0`）时整套功能不参与，行为与旧固件一致。
- 换了齿轮、动过副编码器的安装位置后要**重新 capture + save**，否则参考不再对应。
- 断电后如果用手强力把轴推过窗口，上电解出来的位置会差整整一个相位周期
  （T2/|T1−T2| 转子圈；34/33 = 33 圈、本机 30/27 = 9 圈 = 1 输出圈），不是故障 ——
  想回到正确位置就把轴挪回窗口内（±T2/(2|T1−T2|) 转子圈 = 本机 ±4.5 圈 = ±0.5 输出圈）
  再上电。
- **验收/排查**（可选）：`python tools/gear_test.py --port COM7 check|verify|powercycle`
  （需 `pyserial`）。`check` 不动电机，只打印配置、副编在线状态、量程和"解码 vs
  固件多圈"的当前差值；`verify` 自动在若干位置之间移动并逐点比对；`powercycle`
  在每个位置断电重启后比对。判据是差值为几十分之一 count 的抖动，出现整圈级偏差就是
  齿数/方向配错或超出窗口。

## 5.2 齿槽转矩补偿（anti-cogging）

齿槽力矩让关节在低速时"一顿一顿"、位置保持时有周期性误差。补偿的做法是标定一张
"转子位置 → 需要的 q 轴电流"表，运行时按编码器位置把这段电流前馈加上去。

**前提**

1. 已经 `action.calibrate`（`config.pre_calibrated = true`）；
2. 外环增益已经配好（建议先 `action.measure_inertia` + `action.tune_gains`）。
   标定用的就是这套增益，增益不对表也不可信；
3. 关节能在一个转子圈内自由转动（输出轴约 1/GR 圈，本机 40°），标定期间
   **不要有人或外力碰它**。撞到机械限位会让标定直接失败。
   默认方法会让转子**正转一圈再反转一圈**（约 20 s），所以输出轴要有 ±40° 的行程。

**标定**

```python
dev.call("action.cogging_calibrate")      # 自动进出电机模式，约 20 s
# 进度：system.cogging_progress / system.cogging_progress_total（共 2048 点）
# 结果：system.cogging_status（2 = 成功）
```

或者用台架工具（它顺便打印进度和诊断量）：

```bash
python tools/cogging_test.py --port COM7 calibrate
python tools/cogging_test.py --port COM7 status
```

**它是怎么测的**：位置目标以恒定速度扫过一个转子圈，同时按转子位置把速度环的
输出（"维持这个速度所需的 i_q"）分箱累积；正反各扫一遍，动摩擦方向相反、平均后
抵消，剩下的随位置周期变化的部分就是齿槽。所以标定时**转子的匀速性比停得准更
重要**，不要去扶它。

标定完表在 RAM、`config.cogging_valid = 1`，但**补偿还没打开**：
先用低速 `csv`（`tools/csv_csp_test.py`）走一段比较速度波动，确认有效再：

```python
dev.write("config.cogging_en", True)      # 打开补偿
dev.call("action.save")                   # 门极关闭（回到菜单）时才写 flash
```

台架实测（空载，48 V）：主导齿槽阶次的速度纹波下降 **71~90%**（22/24/44/72 次/转）。
总速度纹波 RMS 基本不变——因为本机低速纹波的大部分不是齿槽（高空间频率的振铃 +
4 次/转成分），所以验证时要看**阶次**而不是总 RMS。

**怎么看结果**

| 端点 | 含义 |
|---|---|
| `system.cogging_status` | 0 没跑 / 1 运行中 / 2 成功 / -1 中止 / -2 坏点太多 / -3 两遍不一致 / -4 超时 / -5 增益没配 |
| `system.cogging_amp` | 表的 RMS 幅值（A）。本机应在 0.05~0.5 A；接近 0 说明齿槽很弱或转子没动 |
| `system.cogging_mismatch` | 正反两遍的差异。与 `amp` 同量级 ⇒ 重复性差（多半是 `cogging_sweep_ms` 太小，其次才是增益不对/标定时有外力/编码器丢帧） |
| `system.cogging_bad` | 两遍都没收敛的点数（> 1/4 直接判失败） |
| `telemetry.cogging_ff` | 当前实际叠加的前馈电流 |
| `telemetry.cogging_value` + `config.cogging_index` | 逐个读表（`tools/cogging_test.py dump` 会读全表并给出主要谐波、可存 CSV） |

**参数**

- `config.cogging_method`（默认 1）：1 = 匀速扫描（推荐，约 20 s）；
  0 = 逐点停住（约 10 分钟，受静摩擦影响、精度差，**不推荐**）；
- `config.cogging_sweep_ms`（默认 8000）：扫描法一个转子圈走多少毫秒。台架实测
  太快会让两遍差异变大（2000 ms 时 0.24 A，信号只有 0.05 A）；4000 以下不建议；
- `config.cogging_gain`（默认 1.0）：补偿缩放。不确定时先用 0.7~0.9；
- `config.cogging_max`（默认 1.0 A）：前馈钳位，用来兜住一张错的表（0 = 不补偿）；
- `config.cogging_pos_thr` / `cogging_settle_ms` / `cogging_avg`：只对方法 0
  （逐点停住）有效；
- `config.cogging_detrend`：去趋势阶数，见下。

**重力/外载**（重要）

标定测的是"维持速度/位置需要的总电流"，里面有重力矩。正反两遍抵消不了重力（方向
相同），所以标定时会去掉一个多项式趋势（`config.cogging_detrend`，默认 3 阶）：
一个转子圈只走 `2π/GR` 的输出角（本机 40°），重力在这段里几乎就是一条三次曲线，
而齿槽是 20~120 次/转，不会被误删。经验：`tools/cogging_test.py dump` 里 1~3 阶
幅值应该接近 0；如果明显不是，把 `cogging_detrend` 调大（直接驱动 GR=1 用 5~6）。
最稳妥仍然是**卸掉负载 / 让关节水平**再标定。

**注意**

- 换编码器、重新标定编码器之后表就失效了（相位跟着编码器走），必须重标；
  只改 `config.m_zero` / `action.zero` **不影响**表。
- `action.cogging_reset` 丢弃表（RAM），换电机/拆装后用它清掉再重标。
- 补偿是在 `i_q_des` 上加前馈，仍然要经过电流限幅、弱磁和 `i_q` 的 `i_max` 钳位，
  不会绕过保护。
- 没有做"在线自适应"：温度变化带来的齿槽漂移（NdFeB 约 −0.12%/°C）不跟踪。
- 表是**隐藏记录**，不在第 6 节的 backup/restore 里（换控制器板要重标，不能靠
  参数备份搬过去）。

## 6. 备份与恢复

只备份"持久化 = 是"的参数（见 [parameters.md](parameters.md)）。LUT 是隐藏记录，
不在备份里。

```python
# backup
dev = Device("COM7", 115200, 1.0); dev.fetch_descriptor()
data = {e["name"]: dev.read(e["name"]) for e in dev.descriptor
        if e.get("persist") and e.get("access") in ("r", "rw")}
json.dump(data, open("backup.json", "w"), indent=2)

# restore（门极关闭；按 ID 升序写，p_max 先于 p_min）
by = {e["name"]: e for e in dev.descriptor}
for name in sorted(data, key=lambda n: by[n]["id"]):
    if by[name].get("access") in ("w", "rw") and by[name].get("persist"):
        dev.write(name, data[name])
dev.call("action.save")
```

恢复脚本会跳过当前固件里不存在的参数。换主板/整片擦除后必须重新标定。

## 7. OTA 升级

固件分成两段：**`0x08000000` 起 32 KB 是 OpenBootloader**，应用程序在
**`0x08008000`**（最多到 `0x0807BFFF`）。

**只要 OTA 只擦 app 区（`0x08008000..0x0807BFFF`），升级后配置、零点、标定 LUT
全部保留。** 整片擦除会全丢（连 bootloader 一起没）——这是固件救不了的。

升级前（建议）：

```bash
python tools/mc_ep.py --can get system.prefs_sequence
python tools/mc_ep.py --can get config.gr
python tools/mc_ep.py --can get config.m_zero
```

升级后核对：

```bash
python tools/mc_ep.py --can get system.fw_version_major   # 与发布说明一致
python tools/mc_ep.py --can get system.fw_version_minor
python tools/mc_ep.py --can get system.fw_version_revision
python tools/mc_ep.py --can get system.prefs_loaded       # true
python tools/mc_ep.py --can get system.config_schema      # 与发布说明一致
python tools/mc_ep.py --can get config.gr                 # 与基线一致
```

LUT 的验证：把电机停到升级前同一机械角度，比较 `telemetry.encoder_raw`。

| 现象 | 原因 | 处理 |
|---|---|---|
| `prefs_loaded = false`，参数全默认 | 配置页被擦了 | 查 OTA 擦除范围；从备份恢复；重新标定 |
| 个别参数变默认 | 该 ID 的类型/长度变了（不应发生） | 查发布说明；备份恢复 |
| `system.fw_version_*` 没变 | 没烧进去 | 重试 |
| 工具报状态 7 | 描述符 CRC 变了 | 用新版 `mc_ep.py`，自动重下描述符 |
| `--can` 一帧都收不到 | 波特率/协议/节点 ID 不匹配，或设备已被打进 bus-off | 先 `--can … probe`（只监听）；`telemetry.can_tec > 128` 就 `call action.reboot`（见 §1） |
| `--can set` 打印的值没变 | ACK 不带状态：端点只读、`require` 不满足或被限幅 | `get` 确认；只读/状态类错误用 `--port`/`--usb` 看（那边有状态码 4/6） |

**第一次刷入 TLV 配置格式的固件**（本仓库之前的版本用的是裸数组）会忽略旧块，
参数回默认值，需要重新设置 + 标定一次；之后每次升级都会保留。

### 进 OpenBootloader（CAN 升级，保留配置）

正常的固件升级走这条：让设备停在 `0x08000000` 的 OpenBootloader 里，再用
CAN 把新的 app 镜像写进去。本固件**没有** USB/串口升级通道，bootloader 只认 CAN。

```bash
# 1) 让设备进 bootloader（门极关闭；带 USB 的开发板也可以串口菜单按 'b'）
python tools/mc_ep.py --can call action.enter_bootloader_mode

# 2) 用本仓库自带的 CAN 工具升级（tools/blcan.py，需要 pip install python-can pyserial；
#    bootloader 固定 500 kbit/s、Classic 帧，支持 CANable(slcan) / PCAN）
#    --channel 填 CANable 的串口（上面 mc_ep.py 自动找到的那个），或者用
#    --interface pcan / socketcan
python tools/blcan.py --channel COM3 sync
python tools/blcan.py --channel COM3 upgrade --firmware build/mit_h473.bin \
        --erase auto --addr 0x08008000 --chunk-size 256 --verify --go-addr 0x08008000
```

- 工具的完整用法、诊断命令和故障排查见 [`tools/blcan_使用说明.md`](../tools/blcan_使用说明.md)；
  协议契约（握手 ID、IWDG 喂狗、擦除范围）见 `docs/DEV.md`。
- **进 bootloader 后不会再自动跳回 App**（要断电或 `go` 才离开），可以从容升级。
- `--erase auto` 只擦镜像覆盖的页；**绝对不要用 `--erase mass`**——那会把 bootloader
  和两页配置一起擦掉，之后只能用 J-Link 重烧 bootloader。
- `build/mit_h473.bin` 是从 `0x08008000` 开始的原样 GCC 镜像，所以 `--addr`/`--go-addr`
  必须是 `0x08008000`。
- 上电时不发 SYNC 的话，bootloader 等 200 ms 就跳回 App，正常使用感觉不到它的存在。
- 升级完核对 `system.fw_version_*` 与 `system.prefs_loaded`，并确认 `config.*` 还在
  （见上一节）。
- **变砖恢复**：app 区写坏也能救——bootloader 在 `0x08000000`，OTA/擦 app 都不会碰它。
  让 CAN 工具持续发 `SYNC`（循环跑 `python tools/blcan.py sync`，或让主站一直发
  ID `0x128` data `0x7F`），再给板子上电，200 ms 窗口内握手成功就停在 bootloader 里。

### 进 DFU 引导程序（整片烧写）

> ⛔ **装了 OpenBootloader 的机器上，这个功能目前用不了**：动作会照常执行、设备也会
> 复位，但约 0.4 s 后芯片自己从 `0x08000000` 重新启动（台架实测是**上电复位**弹回来，
> 不是固件逻辑问题，详见 `docs/DEV.md` 的"⚠ 装了 OpenBootloader 之后 `enter_dfu_mode`
> 进不去"）。**刷机请走上一节的 CAN OTA**；真要 DFU/整片烧写，等这个问题查清或者用
> J-Link。下面保留原始说明，便于问题查清后直接使用。

如果需要用 DFU 工具整片烧写，可以让设备自己跳进 ROM bootloader：

```bash
python tools/mc_ep.py --port COM7 call action.enter_dfu_mode
```

要求门极关闭（菜单/设置/故障状态都可以）。固件会先在总线上把应答发完，约 0.5 s
后复位，再过约 2 s 跳到 ROM DFU——之后设备在 USB 上会**重新枚举**（Windows 上
可能换一个 COM 号或需要装 DFU 驱动），配置页/标定是否保留取决于你下载的地址
范围：**只写 app 区就保留，整片擦除就全丢**（见上一节）。这和串口菜单里按 `d`
是同一个动作，区别只是走了 endpoint，脚本里用更方便。

> ⚠ 别在电机还在转的时候用（门极使能时该动作返回状态 6）。跳 DFU 前固件会先
> 关栅并等 0.5 s，但这不是给"运行中急停"用的——急停请用 `action.idle_mode`。

回退到旧固件：旧固件不认识新格式，参数回默认值；在旧固件里保存会覆盖配置页，
再升回来也回不到新格式的值。回退前先备份。

## 8. 故障排查

| 现象 | 可能原因 | 处理 |
|---|---|---|
| `无法打开串口` | 端口错；被别的程序占用 | 关掉串口终端/另一个工具；确认 COM 号 |
| 一直超时 | 板子没运行；USB 没枚举成 CDC | 重新上电；看设备管理器 |
| `没有返回描述符版本信息` | 端口错或收到的是菜单输出 | 用 `descriptor` 看原始返回；只留一个使用者 |
| 状态 1 未知 ID | 名字错；上位机描述符过期 | `tree`；升级工具 |
| 状态 4/5/6 | 写只读、读动作、状态不允许 | 看参数手册；`call` 代替 `get`；先回菜单 |
| 状态 7 | 描述符 CRC 变了 | 新版工具会自动重下 |
| `save_status = 2` | 门极使能 | 回菜单再存 |
| `save_status = 3` | flash 写失败 | 看串口打印；`make check` 查容量；重试 |
| `set` 的值和给的不一样 | 被限幅 | 正常，`set` 打印的是实际值 |
| 串口终端乱码 | 两个程序抢一个串口 | 关掉多余连接，重新上电 |
| CSP 命令发了但关节完全不动 | ①目标比当前位置更外（界外只有"朝界内"的目标才生效）；②界外冻结生效中，而 `p_des` 与冻结时相同 | ①给一个朝界内的目标；②换一个 `command.p_des` 值（见 CSP 一节） |
| CSP 大阶跃过冲很大 | `config.accel_limit` 太小（速度设定值被斜率限制拖慢） | 先放开 `accel_limit`（30~100），再考虑动 `pos_gain` |
| 高速跑一段时间后突然卸力、`telemetry.fault=2` | `FAULT_OC`：相电流超过 1.5×`config.i_max`（猛加速或高压纹波） | `action.idle_mode` 清故障；降 `accel_limit` 或确认 `i_max` 与电机匹配 |
| `telemetry.fault=4` | `FAULT_UV`：母线低于 `config.vbus_uv_trip`（只在门极使能时判定） | 查电源/电池与线束压降；不需要就把它设 0 关掉 |
| `telemetry.fault=32 / 64` | MOS / 电机过温（`hi + 5 °C`） | 降温；确认 `config.fet_temp_*` / `mot_temp_*` 的阈值合理；NTC 读数明显不对先看 `telemetry.mos_temp` 是否可信 |
| `set` 大转矩/大电流但输出被压住 | `config.torque_lim` 或 `config.i_dc_max` 生效了（或温度降流） | 读 `telemetry.torque` / `telemetry.i_bus` / `telemetry.mos_temp` 确认；把对应参数设 0 关闭 |
| 使能电机没反应、串口提示 `Motor mode refused` | `config.pre_calibrated = false` | 重新 `call action.calibrate`；或确认标定数据有效后 `set config.pre_calibrated 1` |
| 烧了新固件但行为没变（新参数不存在、遥测自相矛盾） | **其实没烧进去**：高 SWD 时钟下读回不稳，J-Link/Keil 的 verify 会失败但编程只写了一部分，设备继续跑旧镜像 | 用 `python tools/flash_jlink.py`（250 kHz + 分块写 + 回读校验）重烧；烧完核对 `system.prefs_loaded`、`config.kt` |
| 整片擦除后电流环/惯量标定结果离谱 | 标定数据被擦掉，跑的是默认值 | 重新 `action.calibrate`，再 `action.save`；然后重测惯量 |

## 9. FAQ

**升级后要重新标定吗？** 不用，除非换了硬件或整片擦除。

**参数存在哪？** `0x0807C000`/`0x0807E000` 两页，双份 + CRC32 + 序号；
写了要 `action.save` 才落盘。

**为什么 `get action.save` 报错？** 动作端点只能执行不能读——否则一次误读就能
让电机停机。

**为什么 `p_min` 可以单独写？** 正常由 `p_max` 联动；单独写是为了备份恢复，
限幅仍保证它 ≤ 0。两者构成 `[p_min, p_max]`；`p_max` 写成 0 时 `p_min` 也是 0，
此时 `P_MAX <= P_MIN`，软限位按“不限制”处理（`ml_pos_cmd_range()` 里只有这一个
判据，不会出现“钳到一个反号边界”）。

**LUT 能导出吗？** 不能，隐藏记录。它随配置页保留；换板/整片擦除要重新标定。

**能加多少参数？** 配置记录 256 条、总载荷 4 KB、描述符 64 KB。当前用了 30 条
配置 + 1 条 LUT（512 B）。超限会在 `make endpoints` 时直接报错。

**保存会磨损 flash 吗？** 每次擦一页（8 KB），只在显式 `action.save` 时发生。

**支持 CAN 吗？** 两套协议，用 `config.can_prot` 选择：`0` = 原有 11-bit 协议，
`1` = CYBERBEAST（**默认**）。`config.can_baud` 决定速率与物理层（**默认 1000000**
= Classic 1 Mbit/s）：≤ 1 Mbit/s 为 Classic CAN，> 1 Mbit/s 为 CAN FD（例：
`can_baud = 5000000` 就是 1M 仲裁 / 5M 数据）。两者都是**下次上电生效**，
`system.can_prot_active` / `system.can_fd` / `system.can_baud_active` 可核对
当前实际运行值。详见 [DEV.md](DEV.md#can协议选择与-cyberbeast)。
