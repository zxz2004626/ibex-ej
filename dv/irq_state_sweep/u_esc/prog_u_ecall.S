// U-mode escalation with NO fault injection: just an `ecall` (a syscall) and a
// loop back-edge. BranchPredictor=1 only.

  .set R_HAN,  0x600
  .set R_ESC,  0x604
  .set R_DONE, 0x6F0

  .section .text.start,"ax",@progbits
  .globl _start
_start:                    // M-mode setup
  la    t0, vec_base
  csrw  mtvec, t0
  la    t0, u_entry
  csrw  mepc, t0
  li    t1, 0x1800
  csrc  mstatus, t1        // mstatus.MPP = U-mode
  mret

u_entry:                   // ---- U-mode from here ----
  li    s0, 0
  li    s1, 9              // 9 < 5 false -> blt NOT taken
  li    s2, 5

back:
  addi  s0, s0, 1

Injection:
  ecall                    // IF holds the blt below while this is in ID
  blt   s1, s2, back       // backward -> predicted TAKEN, actually not taken

  // Reached only if the trap handler was skipped, i.e. we are still in M-mode.
  li    t2, 0
  csrr  t2, mtvec          // M-mode-only CSR: illegal in U-mode
  sw    t2, R_ESC(x0)
  li    t6, 0xDEADBEEF
  sw    t6, R_DONE(x0)
9: j 9b

  .section .vec,"ax",@progbits
  .balign 256
vec_base:                  // exception entry: exc_pc = {mtvec[31:8], 8'h00}
handler:
  li    t3, 1
  sw    t3, R_HAN(x0)
  csrr  t4, mepc
  addi  t4, t4, 4          // skip the trapping instruction so we do not spin
  csrw  mepc, t4
  mret
