/* GNU linker script for the N32H473CE (512 KB flash / 144 KB SRAM).
 *
 * The historical Keil scatter file is archived at legacy/keil/ODrive_N32.sct.
 * This script owns the active GCC layout, including the 16-byte NO_INIT region
 * at the top of SRAM that holds variables which must survive a
 * soft reset (_reboot_cookie, see main.c / the .bss.NO_INIT section).
 *
 *   BOOT  : 0x08000000, 0x08000 (OpenBootloader, 32 KB - not part of this image)
 *   FLASH : 0x08008000, 0x74000 (application, 464 KB)
 *   SRAM  : 0x20000000, 0x23FF0 (application RW/ZI + stack)
 *   NOINIT: 0x20023FF0, 0x10    (not zero-initialised on startup)
 *
 * The application runs behind the OpenBootloader, which occupies the first
 * 32 KB and jumps here 200 ms after reset unless a CAN SYNC frame asks it to
 * stay (see action.enter_bootloader_mode in fsm.c).  The vector table offset in
 * system_n32h47x_48x.c (VECT_TAB_OFFSET) must match ORIGIN(FLASH).
 *
 * The top two 8 KB pages (0x0807C000 / 0x0807E000) hold the ping-ponged config
 * records used by preference_writer.c.  The FLASH region deliberately stops at
 * 0x0807C000 so the image can never grow into them; the bootloader must only
 * erase the application region (0x08008000..0x0807BFFF).
 */

ENTRY(Reset_Handler)

/* Highest address of the user mode stack (top of the normal SRAM region) */
_estack = ORIGIN(RAM) + LENGTH(RAM);   /* 0x20023FF0 */

_Min_Heap_Size  = 0x200;    /* required amount of heap  */
_Min_Stack_Size = 0x1000;   /* required amount of stack */

MEMORY
{
  FLASH  (rx)  : ORIGIN = 0x08008000, LENGTH = 0x74000
  RAM    (xrw) : ORIGIN = 0x20000000, LENGTH = 0x23FF0
  NOINIT (xrw) : ORIGIN = 0x20023FF0, LENGTH = 0x10
}

SECTIONS
{
  /* Vector table must be the first thing in flash (it is read at reset) */
  .isr_vector :
  {
    . = ALIGN(4);
    KEEP(*(.isr_vector))
    . = ALIGN(4);
  } >FLASH

  .text :
  {
    . = ALIGN(4);
    *(.text)
    *(.text*)
    *(.glue_7)
    *(.glue_7t)
    *(.eh_frame)

    KEEP(*(.init))
    KEEP(*(.fini))

    . = ALIGN(4);
    _etext = .;
  } >FLASH

  .rodata :
  {
    . = ALIGN(4);
    *(.rodata)
    *(.rodata*)
    . = ALIGN(4);
  } >FLASH

  .ARM.extab (READONLY) : { *(.ARM.extab* .gnu.linkonce.armextab.*) } >FLASH
  .ARM (READONLY) :
  {
    __exidx_start = .;
    *(.ARM.exidx*)
    __exidx_end = .;
  } >FLASH

  .preinit_array (READONLY) :
  {
    PROVIDE_HIDDEN(__preinit_array_start = .);
    KEEP(*(.preinit_array*))
    PROVIDE_HIDDEN(__preinit_array_end = .);
  } >FLASH

  .init_array (READONLY) :
  {
    PROVIDE_HIDDEN(__init_array_start = .);
    KEEP(*(SORT(.init_array.*)))
    KEEP(*(.init_array*))
    PROVIDE_HIDDEN(__init_array_end = .);
  } >FLASH

  .fini_array (READONLY) :
  {
    PROVIDE_HIDDEN(__fini_array_start = .);
    KEEP(*(SORT(.fini_array.*)))
    KEEP(*(.fini_array*))
    PROVIDE_HIDDEN(__fini_array_end = .);
  } >FLASH

  /* Address in flash that .data is copied from at startup */
  _sidata = LOADADDR(.data);

  .data :
  {
    . = ALIGN(4);
    _sdata = .;
    *(.data)
    *(.data*)
    . = ALIGN(4);
    _edata = .;
  } >RAM AT> FLASH

  /* Power-reset-surviving variables, e.g. _reboot_cookie (declared with
   * __attribute__((section(".bss.NO_INIT")))).  NOLOAD => not copied/zeroed by
   * the startup code.  This MUST come before .bss, otherwise the *(.bss*)
   * wildcard would match .bss.NO_INIT first and it would be zeroed. */
  .noinit (NOLOAD) :
  {
    . = ALIGN(4);
    *(.bss.NO_INIT)
    . = ALIGN(4);
  } >NOINIT

  . = ALIGN(4);
  .bss :
  {
    _sbss = .;
    __bss_start__ = _sbss;
    *(.bss)
    *(.bss*)
    *(COMMON)
    . = ALIGN(4);
    _ebss = .;
    __bss_end__ = _ebss;
  } >RAM

  /* Reserve room for the heap and stack, and let newlib's _sbrk start from
   * `end`.  The stack itself grows down from _estack. */
  ._user_heap_stack :
  {
    . = ALIGN(8);
    PROVIDE(end = .);
    PROVIDE(_end = .);
    . = . + _Min_Heap_Size;
    . = . + _Min_Stack_Size;
    . = ALIGN(8);
  } >RAM

  .ARM.attributes 0 : { *(.ARM.attributes) }

  /DISCARD/ : { libc.a(*) libm.a(*) libgcc.a(*) }
}
