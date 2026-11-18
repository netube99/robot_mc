# motorcontrol（N32H473CE 移植）

三相 FOC 电机控制器固件，移植自 Ben Katz 的
[mini-cheetah motorcontrol](https://github.com/bgkatz/motorcontrol)，运行在
**Nations N32H473CE**（Cortex-M4F）上，裸机、无 RTOS。

- 控制环 40 kHz，`ATIM1` 触发三路注入 ADC，编码器走 SPI1 + DMA2。
- 参数访问：**fibre 风格 endpoint**，USB 复合设备上有两条传输——CDC 串口
  （ASCII 菜单 + 带 CRC 的帧）和 vendor interface（一个 USB 包一帧）；设备自带
  JSON 描述符，上位机按名字读写，固件升级不用改脚本。
- 配置持久化：ID-keyed TLV，双页 ping-pong + CRC32；**OTA 升级只擦 app 区时，
  配置和标定都会保留**。

## 构建

本仓库使用 GNU Arm Embedded GCC 和 Makefile 构建固件。
GCC 构建使用 N32H47x SDK 自带的 `startup_n32h47x_48x_gcc.S`，
应用向量表与链接地址均位于 `0x08008000`（OpenBootloader 之后）。

```bash
make              # build/mit_h473.elf/.hex/.bin
make DEBUG=1      # -Og -g3
make size         # 段大小
make check        # 生成的参数表/文档是否最新（提交前跑）
make hosttest     # 主机单测（prefs_codec，不需要板子）
make flash        # J-Link；可覆盖 JLINK_DEVICE/JLINK_IF/JLINK_SPEED
make clean
```

需要 GNU Arm Embedded Toolchain（`arm-none-eabi-gcc`、`objcopy`、`size`）和 GNU Make；
工具链需支持 Cortex-M4F hard-float ABI。工具链不在 PATH 时可用 `GCC_PATH=` 指定其
`bin` 目录。Windows 上建议用 MSYS2 bash：Chocolatey 的 make 用 cmd，`mkdir -p` 会失败。

> ⚠ 当前 N32H473CE 固件入口是根目录 `Makefile`；不要用旧 STM32F446/CubeMX 工程重新生成源码。
> 原始 CubeIDE 配置、`.ioc` 和 STM32F446 链接脚本已归档到 `legacy/stm32f446/`，仅供历史追溯。

## 仓库结构

- `Core/`：N32H473 应用固件源码与头文件。
- `Drivers/`：Nations N32H47x 外设库、USBFSD 与 CMSIS。
- 根目录 `Makefile`、`N32H473CE_FLASH.ld`：当前 GCC 构建入口与内存布局。
- `tools/`：代码生成器、主机端 CAN/OTA/调试工具和 host tests。
- `docs/`：用户、开发者和参数文档。
- `legacy/`：不参与当前构建的旧 STM32F446/CubeIDE 与 Keil 工程资料，说明见 [`legacy/README.md`](legacy/README.md)。

## 文档

- [docs/README.md](docs/README.md)：入口、版本矩阵、五分钟上手
- [docs/USER.md](docs/USER.md)：用户手册（参数读写、标定、备份、OTA、故障排查）
- [docs/DEV.md](docs/DEV.md)：开发者手册（架构、协议、codegen、持久化、Flash/OTA、CAN）
- [docs/parameters.md](docs/parameters.md)：参数手册（自动生成）
- [AGENTS.md](AGENTS.md)：给 AI 的短契约

## 上位机

出货版本默认**只有 CAN 接口**（没有 USB 座），所以上位机走 CAN：

```bash
pip install pyserial python-can
python tools/mc_ep.py --can tree                                # CANable/slcan，自动找适配器
python tools/mc_ep.py --can get config.i_max
python tools/mc_ep.py --can set config.i_max 3.5
python tools/mc_ep.py --can call action.save
python tools/mc_ep.py --can get system.save_status               # 1 = 保存成功
python tools/mc_ep.py --can probe                                # 链路诊断：只监听总线

# 其它 CAN 后端（python-can 的名字）
python tools/mc_ep.py --can --interface pcan get config.i_max              # PCAN-USB
python tools/mc_ep.py --can --interface socketcan --channel can0 tree      # Linux
python tools/mc_ep.py --can --fd --data-bitrate 5000000 tree               # CAN FD 5M
```

开发/台架板子上还有 USB 复合设备，参数名和输出完全一样：

```bash
python tools/mc_ep.py --port COM7 tree   # CDC 虚拟串口（只需 pyserial）
python tools/mc_ep.py --usb tree         # vendor interface（还需 pyusb + WinUSB）
```

## 许可证

本项目采用 **MIT License**（见 [LICENSE](LICENSE)）。原始版权归 Ben Katz（mini-cheetah
`motorcontrol`，2020）；本仓库的 N32H473CE 移植与后续修改版权归 CyberBeast（北京守护兽科技有限公司）。

MIT 条款只要求一件事：分发本软件或其派生作品时，**必须保留原始版权声明和许可全文**。
因此 `LICENSE` 中同时保留原作者与本公司的版权行；在此前提下可以自由修改、再许可
（sub-license）或闭源分发。

以下第三方组件沿用其各自的原始许可，**不要**改动这些文件的版权头：

| 组件 | 位置 | 许可 |
| --- | --- | --- |
| Nations N32H47x 标准外设库 / USBFSD | `Drivers/`、`Core/Src/usb*.c` | Nations Technologies Inc. 版权声明（见各文件头） |
| STM32CubeMX 生成的外设初始化 | `Core/Src/{adc,tim,usart,gpio,spi}.c` 等 | BSD 3-Clause（STMicroelectronics） |
| CMSIS | `Drivers/CMSIS/` | Apache-2.0（ARM） |
| 移植自 ODrive 的算法（`motion_law`、`dual_gear`、`cogging_law`、标定、梯形规划等） | `Core/Inc`、`Core/Src` | MIT（ODrive Robotics） |
