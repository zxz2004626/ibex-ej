// Branch-predictor skid-buffer test.
//
// Goal: get a predicted-taken (backward) branch sitting in the IF skid buffer at
// the moment an exception is taken, then see whether it gets executed as the
// first post-trap instruction instead of the handler.
//
//   loop: addi s0, s0, 1
//         ecall               <-- exception; in this cycle IF holds the blt
//         blt  s1, s2, loop   <-- backward => static predictor says TAKEN,
//                                 but 9 < 5 is false => actually NOT taken
//         (fall-through target)
//
// Correct behaviour: handler runs (writes 1 to H_RAN), mepc advanced past the
// ecall, control resumes at the blt which falls through.
//
// Buggy behaviour: the stale skid blt is executed first, is a mispredict
// (predicted taken / actually not taken), so the PC is steered to the stale
// branch's fall-through in the OLD stream -> the handler never runs.

  .set R_CNT,  0x600   // loop counter value observed
  .set H_RAN,  0x604   // 1 if the trap handler actually executed
  .set R_DONE, 0x6F0

  .section .text.start,"ax",@progbits
  .globl _start
_start:
  la    t0, handler
  csrw  mtvec, t0

  li    s0, 0
  li    s1, 9          // 9 < 5 is false -> blt NOT taken
  li    s2, 5

  .align 2
loop:
  addi  s0, s0, 1
  ecall                // exception taken here; IF holds the blt below
  blt   s1, s2, loop   // backward branch: predicted taken, actually not taken
  sw    s0, R_CNT(x0)  // fall-through target of the blt
  li    t6, 0xDEADBEEF
  sw    t6, R_DONE(x0)

1: j 1b

  .section .vec,"ax",@progbits
  .balign 256
vec_base:
handler:
  li    t3, 1
  sw    t3, H_RAN(x0)  // record handler entry

  csrr  t2, mepc
  addi  t2, t2, 4      // skip the ecall
  csrw  mepc, t2
  mret
