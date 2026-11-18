# Legacy project artifacts

This directory contains retained files from earlier project configurations. These files are archived for provenance and reference; none are used by the supported N32H473CE GCC build.

- `stm32f446/`: upstream STM32F446 CubeIDE/CubeMX metadata, `.ioc`, and linker scripts. Do not regenerate the N32H473 firmware from these inputs.
- `keil/`: historical Keil scatter files and RTE component header. The Keil uVision project was removed; these artifacts are not a supported build path.

The active firmware source is under `Core/`, the Nations SDK is under `Drivers/`, the GCC build is defined by the root `Makefile` and `N32H473CE_FLASH.ld`, host utilities/tests are under `tools/`, and user/developer docs are under `docs/`.
