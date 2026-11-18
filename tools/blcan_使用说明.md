# `blcan.py` 使用说明（CAN 升级 / OpenBootloader）

`tools/blcan.py` 是通过 CAN 和 `0x08000000` 处的 **OpenBootloader** 通信的刷机工具：
握手、读版本/ID、读/写/擦内存、跳转执行，以及全自动的 **CAN OTA**（擦除 + 分块写 +
回读校验 + 跳转）。本文件只讲怎么用它；Flash 分区、握手 ID、IWDG 喂狗等**协议契约**
见 [../docs/DEV.md](../docs/DEV.md)「Flash 布局与 OTA 契约」「进入/使用 OpenBootloader」。

> 本文件与 `blcan.py` 都是 OpenBootloader 仓库同名工具的同步副本；改逻辑请回那个仓库改，
> 这里只保留一份可用副本和本仓库的路径/流程说明。

## 1. 运行环境

```bash
pip install python-can pyserial        # CANable/slcan 需要 pyserial，PCAN 只需要 python-can
python tools/blcan.py --help
python tools/blcan.py upgrade --help
```

- 默认接口 `slcan`（CANable 等 USB 转 CAN 适配器，Windows 上是 `COMx`），也支持
  `--interface pcan` 等其他 python-can 后端。
- 默认 MCU profile 是 `n32h473`：握手 ID `0x128`、Flash 基址 `0x08000000`、页大小
  `0x2000`（8 KB）。这正好是本仓库的板子，**不用额外传参数**。
- bootloader 固定 **500 kbit/s、Classic 8 字节帧**（不支持 CAN FD，也不会跟随
  `config.can_baud`）。App 运行时的 CAN 是另一套配置，两者互不干扰。

## 2. 先让设备停在 bootloader 里

```bash
python tools/mc_ep.py --usb call action.enter_bootloader_mode     # 或串口菜单按 b
```

约 0.5 s 后设备复位、停在 bootloader（**不会**再自动跳回 App）。之后才轮到 `blcan.py`。

- 如果 App 已经跑不起来（app 区写坏），见第 6 节「变砖恢复」。
- `action.enter_bootloader_mode` 要求门极关闭（电机模式里调用会返回状态 6）。

## 3. 完整升级（OTA）

```bash
# 1) 握手：确认总线上就是 bootloader
python tools/blcan.py --channel COM7 sync

# 2) 升级（GCC 构建产物需显式指定 App 地址）
python tools/blcan.py --channel COM7 upgrade \
        --firmware build/mit_h473.bin \
        --erase auto \
        --addr 0x08008000 \
        --chunk-size 256 \
        --verify \
        --go-addr 0x08008000
```

- `--channel` 不写时工具会自动找 CANable 的串口；接了多个适配器时一定要显式指定。
- `--erase auto` 只擦镜像覆盖的 app 页（从 `0x08008000` 起）。**绝对不要用
  `--erase mass`**：那会连 OpenBootloader 和两页配置（`0x0807C000`/`0x0807E000`）
  一起擦掉，之后只能用 J-Link 重烧 bootloader，参数/零点/标定全部丢失。
- `--addr` 只对 `.bin` 必需（必须是 `0x08008000`）；`.hex` 自带地址。
- `--verify` 逐块回读比对，宁可慢也要加。
- `--go-addr 0x08008000` 升级完直接跳回 App，省一次断电。
- 升级后核对：`system.fw_version_*`、`system.prefs_loaded`、`system.prefs_sequence`
  应保持升级前的值（见 `docs/USER.md` 第 7 节）。

## 4. 常用子命令

| 命令 | 作用 |
|---|---|
| `sync` | 握手（发 `SYNC`，等 ACK）。设备刚进 bootloader 时必须先做一次 |
| `version` | 读 bootloader 版本 |
| `id` | 读 DEVICE ID（本板 `0x0469`） |
| `read --addr 0x08008000 --len 64 [--out f.bin]` | 读内存（单次最多 256 B） |
| `write --addr 0x... --data DEADBEEF` / `--file f.bin` | 写内存（用于诊断，不要拿来写 flash） |
| `erase --mode pages --pages 4,5` | 按页擦（`--mode mass` 会连 bootloader 一起擦） |
| `go --addr 0x08008000` | 跳到 App，不擦写 |

其他命令默认不握手；需要时加 `--sync`。多个命令连用时通常是 `sync` 一次即可。

## 5. 诊断示例

```bash
# 确认设备真的在 bootloader 里（App 跑 1 Mbit CYBERBEAST，这里 500 kbit 无人应答）
python tools/blcan.py --channel COM7 sync

# 读回 App 区前 64 字节，看向量表的 SP/Reset 是否是期望的镜像
python tools/blcan.py --channel COM7 read --addr 0x08008000 --len 64

# 停在 bootloader 里超过 30 s 仍能应答 ⇒ IWDG 被 bootloader 喂住了
python tools/blcan.py --channel COM7 version
```

## 6. 变砖恢复

App 区写坏也能救：bootloader 在 `0x08000000`，OTA 和擦 app 都不会碰它。

1. 让工具**持续**发 `SYNC`（循环执行 `python tools/blcan.py sync`）：
   ```powershell
   while ($true) { python tools/blcan.py --channel COM7 sync }
   ```
2. 然后给板子上电/复位：bootloader 上电后只有 **200 ms** 的握手窗口，窗口内收到
   `SYNC` 就停在升级模式，不再跳 App。
3. 握手成功后回到第 3 节做 OTA。

## 7. 返回码与常见问题

返回码：`0` 成功、`1` 未知异常、`2` bootloader 协议错误、`3` CAN 驱动错误、`4` 文件不存在。

| 现象 | 处理 |
|---|---|
| `timeout waiting for CAN frame` | 设备没在 bootloader（先进 bootloader 再 `sync`）；或 `--channel` 指错串口；或适配器被别的程序占用 |
| 设备在 bootloader 里却不应答 | 先 `sync`：未握手前设备不理会任何命令 |
| `NACK at sync` | 老 bootloader 在已握手状态下会 NACK 重复 `sync`；本仓库新 bootloader 已修复，可重复握手 |
| 升级到一半整机复位 | bootloader 没喂 IWDG（旧固件）；升级到 `docs/DEV.md` 里修好的 bootloader 版本 |
| 写完 App 读回数值/描述符对不上 | 别用 J-Link 高速刷（见 `AGENTS.md`）；用本工具 `--verify` 走 OTA，或 `tools/flash_jlink.py`（250 kHz） |
