##############################################################################
# Makefile for the N32H473CE motorcontrol firmware
#
# GNU Arm Embedded command-line build for the N32H473CE application image.
# Uses the vendor GCC startup and N32H473CE_FLASH.ld.
#
# Targets:
#   make [all]     build build/mit_h473.elf/.hex/.bin
#   make DEBUG=1   -Og -g3 build
#   make size      print the section sizes
#   make flash     program the .hex over J-Link (see the FLASH section below)
#   make clean     remove the build directory
#
# Toolchain: arm-none-eabi-gcc / as / objcopy / size on PATH (override the
# directory with GCC_PATH=/path/to/toolchain/bin).
##############################################################################

TARGET    = mit_h473
BUILD_DIR = build

DEBUG ?= 0
ifeq ($(DEBUG), 1)
OPT = -Og -g3
else
OPT = -O2
endif

######################################
# toolchain
######################################
PREFIX = arm-none-eabi-
ifdef GCC_PATH
CC = $(GCC_PATH)/$(PREFIX)gcc
AS = $(GCC_PATH)/$(PREFIX)gcc -x assembler-with-cpp
CP = $(GCC_PATH)/$(PREFIX)objcopy
SZ = $(GCC_PATH)/$(PREFIX)size
OD = $(GCC_PATH)/$(PREFIX)objdump
else
CC = $(PREFIX)gcc
AS = $(PREFIX)gcc -x assembler-with-cpp
CP = $(PREFIX)objcopy
SZ = $(PREFIX)size
OD = $(PREFIX)objdump
endif

######################################
# firmware sources (the GCC build is the supported project entry point)
######################################
C_SOURCES = \
$(wildcard Core/Src/*.c) \
Drivers/CMSIS/core/arm_common_tables.c \
$(wildcard Drivers/n32h47x_48x_std_periph_driver/src/*.c) \
$(wildcard Drivers/n32h47x_48x_usbfsd_driver/src/*.c)

ASM_SOURCES = Drivers/CMSIS/device/startup/startup_n32h47x_48x_gcc.S

######################################
# flags
######################################
CPU   = -mcpu=cortex-m4
FPU   = -mfpu=fpv4-sp-d16
FLOAT = -mfloat-abi=hard
MCU   = $(CPU) -mthumb $(FPU) $(FLOAT)

C_DEFS = \
-DN32H473 \
-DARM_MATH_CM4 \
-DHSE_VALUE=24000000 \
-D__FPU_PRESENT=1

C_INCLUDES = \
-ICore/Inc \
-IDrivers/CMSIS/core \
-IDrivers/CMSIS/device \
-IDrivers/n32h47x_48x_std_periph_driver/inc \
-IDrivers/n32h47x_48x_usbfsd_driver/inc

ASFLAGS = $(MCU) $(OPT) -Wall -fdata-sections -ffunction-sections
CFLAGS  = $(MCU) $(C_DEFS) $(C_INCLUDES) $(OPT) -Wall -std=gnu11 \
          -fdata-sections -ffunction-sections -fno-strict-aliasing

# generate dependency information
CFLAGS += -MMD -MP -MF"$(@:%.o=%.d)"

######################################
# linker
######################################
LDSCRIPT = N32H473CE_FLASH.ld

LIBS    = -lc -lm -lnosys
LDFLAGS = $(MCU) -specs=nano.specs -u _printf_float -T$(LDSCRIPT) $(LIBS) \
          -Wl,-Map=$(BUILD_DIR)/$(TARGET).map,--cref -Wl,--gc-sections

######################################
# build rules  (objects mirror the source tree, so basenames need not be unique)
######################################
OBJECTS  = $(addprefix $(BUILD_DIR)/,$(C_SOURCES:.c=.o))
OBJECTS += $(addprefix $(BUILD_DIR)/,$(ASM_SOURCES:.S=.o))

all: $(BUILD_DIR)/$(TARGET).elf $(BUILD_DIR)/$(TARGET).hex $(BUILD_DIR)/$(TARGET).bin

$(BUILD_DIR)/%.o: %.c Makefile | $(BUILD_DIR)
	@mkdir -p $(dir $@)
	$(CC) -c $(CFLAGS) $< -o $@

# .S is preprocessed by the compiler; .s is assembled directly
$(BUILD_DIR)/%.o: %.S Makefile | $(BUILD_DIR)
	@mkdir -p $(dir $@)
	$(AS) -c $(ASFLAGS) $< -o $@

$(BUILD_DIR)/%.o: %.s Makefile | $(BUILD_DIR)
	@mkdir -p $(dir $@)
	$(AS) -c $(ASFLAGS) $< -o $@

$(BUILD_DIR)/$(TARGET).elf: $(OBJECTS) Makefile $(LDSCRIPT)
	$(CC) $(OBJECTS) $(LDFLAGS) -o $@
	$(SZ) $@

$(BUILD_DIR)/%.hex: $(BUILD_DIR)/%.elf
	$(CP) -O ihex $< $@

$(BUILD_DIR)/%.bin: $(BUILD_DIR)/%.elf
	$(CP) -O binary -S $< $@

$(BUILD_DIR):
	mkdir -p $@

size: $(BUILD_DIR)/$(TARGET).elf
	$(SZ) $<

######################################
# endpoint table
#
# params.json 是参数表/持久化表的唯一真源；生成的 endpoint_defs.c/h 与
# prefs_defs.c/h 提交进仓库，这样 Keil 构建和没装 Python 的机器也能直接编译。
# 改了 params.json 后运行 `make endpoints`；`make check` 检查 C 表和文档是否过期
# （CI/提交前跑这个）。PYTHON 可覆盖：`make check PYTHON=python3`。
# Windows 用 `py -3`：MSYS2 的 PATH 里通常没有 python.exe，但 py 启动器在。
######################################
ifeq ($(OS),Windows_NT)
PYTHON ?= py -3
else
PYTHON ?= python3
endif

endpoints:
	$(PYTHON) tools/gen_endpoints.py --params params.json --ids tools/endpoint_ids.json --out .

endpoints-check:
	$(PYTHON) tools/gen_endpoints.py --params params.json --ids tools/endpoint_ids.json --out . --check

check: endpoints-check

######################################
# host tests
#
# 纯逻辑模块（prefs_codec）不需要目标板，主机 gcc 就能跑。
######################################
HOSTCC ?= gcc
HOSTTEST = $(BUILD_DIR)/test_prefs_codec
HOSTTEST_CAN = $(BUILD_DIR)/test_can_cyberbeast
HOSTTEST_MOTION = $(BUILD_DIR)/test_motion_law
HOSTTEST_EP = $(BUILD_DIR)/test_endpoint_proto
HOSTTEST_GEAR = $(BUILD_DIR)/test_dual_gear
HOSTTEST_COG = $(BUILD_DIR)/test_cogging

hosttest: $(BUILD_DIR)
	$(HOSTCC) -std=gnu11 -O1 -Wall -Wextra -ICore/Inc tools/test_prefs_codec.c Core/Src/prefs_codec.c -lm -o $(HOSTTEST)
	./$(HOSTTEST)
	$(HOSTCC) -std=gnu11 -O1 -Wall -Wextra -ICore/Inc tools/test_can_cyberbeast.c -lm -o $(HOSTTEST_CAN)
	./$(HOSTTEST_CAN)
	$(HOSTCC) -std=gnu11 -O1 -Wall -Wextra -ICore/Inc tools/test_motion_law.c -lm -o $(HOSTTEST_MOTION)
	./$(HOSTTEST_MOTION)
	$(HOSTCC) -std=gnu11 -O1 -Wall -Wextra -ICore/Inc tools/test_dual_gear.c -lm -o $(HOSTTEST_GEAR)
	./$(HOSTTEST_GEAR)
	$(HOSTCC) -std=gnu11 -O1 -Wall -Wextra -ICore/Inc tools/test_cogging.c -lm -o $(HOSTTEST_COG)
	./$(HOSTTEST_COG)
	$(HOSTCC) -std=gnu11 -O1 -Wall -Wextra -ICore/Inc tools/test_endpoint_proto.c Core/Src/endpoint.c -lm -o $(HOSTTEST_EP)
	./$(HOSTTEST_EP)

# 上位机侧的 CAN 传输（tools/mc_ep.py）：用 python-can 的 virtual 总线模拟设备，
# 不需要硬件/适配器，但要 `pip install python-can`（所以不并进 hosttest）。
hosttest-py:
	$(PYTHON) tools/test_mc_ep_can.py

######################################
# flash
#
# The firmware is programmed over J-Link, so `flash`
# drives the J-Link Commander.  Override the probe settings as needed, e.g.:
#     make flash JLINK_DEVICE=N32H473CE JLINK_IF=SWD JLINK_SPEED=4000
# If J-Link does not know the exact device, set JLINK_DEVICE to a compatible
# N32H47x/N32H473 part name from the J-Link device list.
#
# Alternative probes (both installed here) are provided too:
#     make flash-pyocd                     (override PYOCD_TARGET)
#     make flash-openocd                   (override OPENOCD_ARGS)
#
# The application links at 0x08008000 (the first 32 KB hold the OpenBootloader),
# so the .hex already carries that address.  For the chunked/verified flashing
# path use tools/flash_jlink.py (default base 0x08008000; --base 0x08000000 when
# flashing the bootloader itself).
######################################
JLINK_EXE    ?= JLink
JLINK_DEVICE ?= N32H473CE
JLINK_IF     ?= SWD
JLINK_SPEED  ?= 4000

PYOCD        ?= pyocd
PYOCD_TARGET ?= n32h473ce

OPENOCD      ?= openocd
OPENOCD_ARGS ?= -f interface/cmsis-dap.cfg

flash: $(BUILD_DIR)/$(TARGET).hex
	@printf 'si %s\nspeed %s\nconnect\nr\nloadfile %s\nr\ng\nqc\n' \
		"$(JLINK_IF)" "$(JLINK_SPEED)" "$(BUILD_DIR)/$(TARGET).hex" > $(BUILD_DIR)/flash.jlink
	$(JLINK_EXE) -device $(JLINK_DEVICE) -if $(JLINK_IF) -speed $(JLINK_SPEED) \
		-autoconnect 1 -CommanderScript $(BUILD_DIR)/flash.jlink

flash-pyocd: $(BUILD_DIR)/$(TARGET).hex
	$(PYOCD) flash -t $(PYOCD_TARGET) $(BUILD_DIR)/$(TARGET).hex

flash-openocd: $(BUILD_DIR)/$(TARGET).elf
	$(OPENOCD) $(OPENOCD_ARGS) -c "program $< verify reset exit"

clean:
	rm -rf $(BUILD_DIR)

-include $(OBJECTS:.o=.d)

.PHONY: all clean flash flash-pyocd flash-openocd size endpoints endpoints-check check hosttest hosttest-py
