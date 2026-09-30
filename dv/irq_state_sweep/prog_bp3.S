// Does an EXTERNAL INTERRUPT leave the same stale skid branch behind?
//
// The interrupt is held until taken. It is asserted while a long DIV runs, so
// the core takes it at the first instruction boundary after the div completes.
// During the div the IF stage runs ahead and puts the backward (predicted
// taken, actually not-taken) branch into the skid buffer.
//
// By the analysis, IRQ_TAKEN leaves halt_if deasserted, so id_in_ready is high
// and the skid IS cleared -> the handler must run normally.

  .set R_CNT,  0x600
  .set H_RAN,  0x604
  .set R_DONE, 0x6F0

  .section .text.start,"ax",@progbits
  .globl _start
_start:
  la    t0, vec_base
  csrw  mtvec, t0
  li    t1, 0x800
  csrs  mie, t1
  li    t1, 0x8
  csrs  mstatus, t1

  li    s0, 0
  li    s1, 9            // 9 < 5 false -> branch NOT taken (mispredict case)
  li    s2, 5

loop:
  addi  s0, s0, 1
  li    s3, 0x7FFFFFFF
  li    s4, 0x00001235
  div   s5, s3, s4       // long stall; interrupt is held asserted through it
  blt   s1, s2, loop     // backward branch, predicted taken, actually not taken
  sw    s0, R_CNT(x0)
  li    t6, 0xDEADBEEF
  sw    t6, R_DONE(x0)
1: j 1b

  .section .vec,"ax",@progbits
  .balign 256
vec_base:
  .zero 44               // machine external interrupt (cause 11) -> base + 44
handler:
  li    t3, 1
  sw    t3, H_RAN(x0)
  mret
