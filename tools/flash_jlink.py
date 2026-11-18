#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""用 J-Link Commander 可靠烧录镜像：分块写 + 逐块回读比对 + 重试。

为什么不用 `JLink.exe -CommanderScript loadfile` 或 UV4 -f 了事：
这块板子在 5 MHz（Keil 默认）和 1 MHz 下 **SWD 读回不稳定** —— 同一段 flash
连续读三次会得到三个不同的内容，J-Link 自带的 verify 随机报
"Verification failed @ 0x08000000"，而编程其实只写了一部分。结果就是设备
继续跑旧镜像，看现象像"新加的参数没生效 / 遥测值自相矛盾"，很难查。
实测 250 kHz + 8 KB 分块写、每块回读比对，可以稳定通过（本文件就是那套流程）。

App 链接在 0x08008000（前 32 KB 是 OpenBootloader），所以默认把镜像烧到那里；
镜像文件本身从 0x08008000 开始（hex/bin/axf 都是），基址只用来算写入地址和回读比对。

用法：
    python tools/flash_jlink.py --bin build/mit_h473.bin # 烧 GCC App 到 0x08008000
    python tools/flash_jlink.py --bin bl.bin --base 0x08000000   # 烧 OpenBootloader
    python tools/flash_jlink.py --erase            # 先整片擦除（bootloader + 配置页都会没！）
    python tools/flash_jlink.py --no-run           # 烧完停在 halt，不 reset&go
    python tools/flash_jlink.py --speed 1000       # 换 SWD 时钟（默认 250 kHz）

烧完会做一次全镜像回读比对，全部一致才算成功（退出码 0）。
"""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile

APP_BASE = 0x08008000      # application (behind the 32 KB OpenBootloader)
BOOT_BASE = 0x08000000     # OpenBootloader
CONFIG_PAGE_A = 0x0807C000 # first of the two ping-ponged config pages


def parse_int(text):
    return int(text, 0)


JLINK_CANDIDATES = [
    r"D:\Program Files\SEGGER\JLink_V826\JLink.exe",
    r"C:\Program Files\SEGGER\JLink\JLink.exe",
    r"C:\Program Files (x86)\SEGGER\JLink\JLink.exe",
    r"D:\SEGGER\JLink\JLink.exe",
]

FROMELF_CANDIDATES = [
    r"D:\Keil_v5\ARM\ARMCLANG\bin\fromelf.exe",
    r"C:\Keil_v5\ARM\ARMCLANG\bin\fromelf.exe",
    r"D:\Keil_v5\ARM\ARMCC\bin\fromelf.exe",
    r"C:\Keil_v5\ARM\ARMCC\bin\fromelf.exe",
]


def find_first(cands, what):
    for path in cands:
        if os.path.isfile(path):
            return path
    found = shutil.which(what)
    if found:
        return found
    sys.exit("找不到 %s，请用命令行参数指定。" % what)


def axf_to_bin(fromelf, axf, out_bin):
    proc = subprocess.run([fromelf, "--bin", "--output", out_bin, axf],
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if not os.path.isfile(out_bin):
        sys.exit("fromelf 没能生成 bin：\n" + proc.stdout.decode("utf-8", "replace"))


class JLink:
    def __init__(self, exe, device, speed, tmpdir):
        self.exe = exe
        self.device = device
        self.speed = speed
        self.tmpdir = tmpdir
        self.script = os.path.join(tmpdir, "jlink.jlink")
        self.log = os.path.join(tmpdir, "jlink.log")

    def run(self, commands, quiet=True):
        head = ["si SWD", "speed %d" % self.speed, "device %s" % self.device, "connect"]
        with open(self.script, "w", encoding="ascii") as fh:
            fh.write("\n".join(head + commands + ["exit"]) + "\n")
        with open(self.log, "wb") as fh:
            subprocess.run([self.exe, "-CommanderScript", self.script, "-NoGui", "1"],
                           stdout=fh, stderr=subprocess.STDOUT)
        with open(self.log, "rb") as fh:
            text = fh.read().decode("utf-8", "replace")
        if not quiet:
            sys.stdout.write(text)
        return text

    def write_chunk(self, path, addr):
        self.run(['loadbin "%s", 0x%08X' % (path, addr)])

    def read_chunk(self, addr, length, out_path):
        if os.path.exists(out_path):
            os.remove(out_path)
        self.run(['savebin "%s", 0x%08X, 0x%X' % (out_path, addr, length)])
        if not os.path.isfile(out_path):
            return None
        with open(out_path, "rb") as fh:
            return fh.read()

    def erase_chip(self):
        text = self.run(["erase"])
        return "Erase" in text

    def reset_and_run(self):
        self.run(["r", "g"])


def read_matches(jl, addr, data, retries, read_file):
    """回读一段并比对。250 kHz 下读回仍有极小概率出错，所以多次读、任一次
    完全一致就算通过（写进去的内容不会自己变，读到不一致说明是读通路错了）。"""
    for _ in range(retries):
        back = jl.read_chunk(addr, len(data), read_file)
        if back == data:
            return True
    return False


def verify_range(jl, base, image, chunk, retries, read_file):
    for off in range(0, len(image), chunk):
        data = image[off:off + chunk]
        if not read_matches(jl, base + off, data, retries, read_file):
            return base + off
    return None


def flash(args):
    jlink_exe = args.jlink or find_first(JLINK_CANDIDATES, "JLink.exe")
    tmpdir = tempfile.mkdtemp(prefix="jflash_")
    bin_path = os.path.join(tmpdir, "image.bin")

    if args.bin:
        shutil.copyfile(args.bin, bin_path)
    else:
        fromelf = args.fromelf or find_first(FROMELF_CANDIDATES, "fromelf.exe")
        axf_to_bin(fromelf, args.axf, bin_path)

    with open(bin_path, "rb") as fh:
        image = fh.read()
    if not image:
        sys.exit("镜像是空的。")

    base = args.base
    if base == APP_BASE and base + len(image) > CONFIG_PAGE_A:
        sys.exit("镜像 %d 字节超出 app 区（0x%08X 起会压到配置页）—— 检查链接脚本。"
                 % (len(image), CONFIG_PAGE_A))
    if base == BOOT_BASE and base + len(image) > APP_BASE:
        sys.exit("镜像 %d 字节超出 bootloader 区（0x%08X 起会压掉 app）—— "
                 "整片镜像请从 0x%08X 起烧，或先 --erase 再分别烧两段。"
                 % (len(image), APP_BASE, BOOT_BASE))

    jl = JLink(jlink_exe, args.device, args.speed, tmpdir)
    print("J-Link : %s" % jlink_exe)
    print("镜像   : %d 字节 -> 0x%08X..0x%08X" % (len(image), base, base + len(image) - 1))
    print("SWD    : %d kHz，分块 %d 字节" % (args.speed, args.chunk))

    if args.erase:
        print("整片擦除（OpenBootloader 与配置页 0x0807C000/0x0807E000 都会没掉，"
              "之后必须先重烧 bootloader）...")
        if not jl.erase_chip():
            sys.exit("擦除失败。")

    chunk_file = os.path.join(tmpdir, "chunk.bin")
    read_file = os.path.join(tmpdir, "verify.bin")
    try:
        for index, off in enumerate(range(0, len(image), args.chunk)):
            data = image[off:off + args.chunk]
            addr = base + off
            with open(chunk_file, "wb") as fh:
                fh.write(data)

            ok = False
            for attempt in range(1, args.retries + 1):
                jl.write_chunk(chunk_file, addr)
                ok = read_matches(jl, addr, data, 2, read_file)
                if ok:
                    break
                if attempt < args.retries:
                    print("  块 %d @0x%08X 校验不过，重写（%d/%d）" % (index, addr, attempt, args.retries))
            if not ok:
                sys.exit("块 %d @0x%08X 写入失败，放弃。检查目标板供电/接线，或降 --speed。" % (index, addr))
            print("  块 %d @0x%08X %5d 字节  OK" % (index, addr, len(data)))

        bad_addr = verify_range(jl, base, image, args.chunk, args.retries, read_file)
        if bad_addr is not None:
            sys.exit("全镜像回读不一致（0x%08X 附近），烧录不可信。" % bad_addr)
        print("全镜像回读一致。")

        if args.run:
            jl.reset_and_run()
            print("已复位运行。")
        else:
            print("已烧录（核心仍处于 halt，需要时再 reset&go）。")
    finally:
        if args.keep:
            print("临时文件保留在 %s" % tmpdir)
        else:
            shutil.rmtree(tmpdir, ignore_errors=True)

    return 0


def main(argv=None):
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    parser = argparse.ArgumentParser(description="J-Link 分块烧录 + 回读校验（N32H473）")
    parser.add_argument("--axf", help="输入 Arm/Keil .axf（仅兼容历史产物）")
    parser.add_argument("--bin", help="直接给 .bin（给了就不调用 fromelf）")
    parser.add_argument("--base", type=parse_int, default=APP_BASE,
                        help="镜像的起始地址（默认 app=0x%08X；烧 bootloader 用 0x%08X）"
                             % (APP_BASE, BOOT_BASE))
    parser.add_argument("--device", default="N32H473CE")
    parser.add_argument("--speed", type=int, default=250, help="SWD 时钟 kHz（默认 250；1 MHz 以上读回可能不稳）")
    parser.add_argument("--chunk", type=int, default=8192, help="每块字节数（默认 8 KB，等于一个擦除页）")
    parser.add_argument("--retries", type=int, default=3)
    parser.add_argument("--erase", action="store_true",
                        help="先整片擦除（bootloader + 配置页都会丢，之后要重烧 bootloader）")
    parser.add_argument("--no-run", dest="run", action="store_false", help="烧完不复位运行")
    parser.add_argument("--keep", action="store_true", help="保留临时目录")
    parser.add_argument("--jlink", help="JLink.exe 路径")
    parser.add_argument("--fromelf", help="fromelf.exe 路径")
    args = parser.parse_args(argv)
    return flash(args)


if __name__ == "__main__":
    sys.exit(main())
