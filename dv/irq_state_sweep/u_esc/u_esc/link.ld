ENTRY(_start)
SECTIONS
{
  /* Ibex reset vector is {boot_addr[31:8], 8'h80} -> 0x80 with boot_addr=0 */
  . = 0x00000080;
  .text : { *(.text.start) *(.text*) }
  .rodata : { *(.rodata*) }
  .data : { *(.data*) }

  /* Trap/IRQ vector table, must be 256-byte aligned and kept out of the
     .text wildcards above so it does not change the program start address. */
  . = ALIGN(256);
  .vec : { *(.vec) }

  .bss : { *(.bss*) }
}
