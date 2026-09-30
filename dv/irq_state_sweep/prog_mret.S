// Same skid-buffer window, but flushed by MRET instead of an exception.
//
// MRET also goes through the controller's FLUSH state (pc_mux = PC_ERET), and
// FLUSH asserts halt_if -> id_in_ready = 0 -> the skid is not cleared.
//
//   back: mret                 <- flushes; IF holds the blt below -> skid fills
//         blt s1,s2,back       <- backward => predicted TAKEN, actually not taken
//         sw t3, R_AFTER       <- stale branch's fall-through
//
// Correct: control goes to mepc (target) -> R_MRET = 1.
// Buggy:   the stale blt mispredicts and steers the PC to its own fall-through,
//          so the MRET target is never reached -> R_AFTER = 0x1111.

  .set R_MRET,  0x600
  .set R_AFTER, 0x604
  .set R_DONE,  0x6F0

  .section .text.start,"ax",@progbits
  .globl _start
_start:
  li    t0, 0x1800          // mstatus.MPP = M
  csrs  mstatus, t0
  la    t0, target
  csrw  mepc, t0

  li    s1, 9               // 9 < 5 false -> blt NOT taken
  li    s2, 5
  li    t3, 0x1111

back:
  mret

  blt   s1, s2, back
  sw    t3, R_AFTER(x0)
  li    t6, 0xDEADBEEF
  sw    t6, R_DONE(x0)
9: j 9b

  .section .vec,"ax",@progbits
  .balign 256
target:
  li    t4, 1
  sw    t4, R_MRET(x0)
  li    t6, 0xDEADBEEF
  sw    t6, R_DONE(x0)
8: j 8b
