// Directed IRQ-phase sweep test for Ibex mult/div state retention.
//
//   main: div/rem pair #1  -> interrupt is injected somewhere in this window
//         mul/mulh         -> checks multiplier FSM residue after the trap
//         div/rem pair #2  -> checks divider FSM residue after the trap
//   handler: div/rem pair -> checks that stale state does NOT poison the
//                            trap handler's own division (cross-context leak)
//
// Results are stored at 0x600+ (well clear of code) for the TB to dump.

  .set R_DIV1,   0x600   // main   div  (interrupt window)
  .set R_REM1,   0x604   // main   rem
  .set R_HDIV,   0x608   // handler div
  .set R_HREM,   0x60C   // handler rem
  .set R_MUL,    0x610   // post-trap mul
  .set R_MULH,   0x614   // post-trap mulh
  .set R_DIV2,   0x618   // post-trap div
  .set R_REM2,   0x61C   // post-trap rem
  .set R_DONE,   0x6F0   // completion marker

  .section .text.start,"ax",@progbits
  .globl _start
_start:
  la    t0, vec_base
  csrw  mtvec, t0

  li    t1, 0x800          // mie.MEIE
  csrs  mie, t1
  li    t1, 0x8            // mstatus.MIE
  csrs  mstatus, t1

  // ------------- main div/rem pair (the interrupt lands in here) -------------
  li    s0, 0x7FFFFFFF
  li    s1, 0x00001235
  div   s2, s0, s1
  rem   s3, s0, s1
  sw    s2, R_DIV1(x0)
  sw    s3, R_REM1(x0)

  // -------------------- after the trap: mul / mulh ---------------------------
  li    s4, 0x0000BEEF
  li    s5, 0x0000CAFE
  mul   s6, s4, s5
  mulh  s7, s4, s5
  sw    s6, R_MUL(x0)
  sw    s7, R_MULH(x0)

  // -------------------- after the trap: div / rem ----------------------------
  li    a4, 0xFFFFFFFB
  li    a5, 0x00000007
  div   a6, a4, a5
  rem   a7, a4, a5
  sw    a6, R_DIV2(x0)
  sw    a7, R_REM2(x0)

  li    t6, 0xDEADBEEF
  sw    t6, R_DONE(x0)

1: j 1b

  // ------------------------------ trap handler -------------------------------
  // mtvec is 256-byte aligned and, in non-CHERIoT mode, used in VECTORED mode:
  // machine external interrupt (cause 11) enters at vec_base + 4*11 = vec_base + 44.
  .section .vec,"ax",@progbits
  .balign 256
vec_base:
  .zero 44
handler:
  li    t2, 0xF0000000
  li    t3, 0x00000007
  div   t4, t2, t3
  rem   t5, t2, t3
  sw    t4, R_HDIV(x0)
  sw    t5, R_HREM(x0)
  mret
