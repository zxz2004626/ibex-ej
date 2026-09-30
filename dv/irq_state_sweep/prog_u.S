// Does the swallowed trap also escalate privilege?
//
// The core first drops to U-mode via MRET (mstatus.MPP = 0). Then a top-level
// instruction-bus fault (instr_err_i) is injected on one fetch. That fault must
// trap to the M-mode handler, which is what raises privilege to M.
//
// If the IF skid-buffer bug skips the handler, the PC is steered back into the
// U-mode code *while the core is already in M-mode* -- i.e. U-mode code keeps
// running with M-mode privilege.
//
// Discriminator right after the branch:
//   csrr t2, mtvec      -> legal in M-mode, raises illegal-instruction in U-mode
//   sw   t2, R_ESC      -> executed ONLY if we are actually running in M-mode

  .set R_HAN,  0x600      // M-mode trap handler ran (the correct outcome)
  .set R_ESC,  0x604      // privileged op SUCCEEDED -> privilege escalation
  .set R_DONE, 0x6F0

  .section .text.start,"ax",@progbits
  .globl _start
_start:                   // M-mode
  la    t0, vec_base
  csrw  mtvec, t0
  la    t0, u_entry
  csrw  mepc, t0
  li    t1, 0x1800
  csrc  mstatus, t1       // mstatus.MPP = 00 -> U-mode
  mret                    // drop to U-mode

u_entry:                  // ---- U-mode from here ----
  li    s0, 0
  li    s1, 9             // 9 < 5 false -> blt NOT taken
  li    s2, 5

back:
  addi  s0, s0, 1

fault:
  nop                     // <- instr_err_i injected on this fetch
  blt   s1, s2, back      // backward -> predicted TAKEN, actually not taken

  // Reached either (a) normally in U-mode, or (b) in M-mode if the handler was
  // skipped. Probe an M-mode-only CSR.
  csrr  t2, mtvec
  sw    t2, R_ESC(x0)
  li    t6, 0xDEADBEEF
  sw    t6, R_DONE(x0)
9: j 9b

  .section .vec,"ax",@progbits
  .balign 256
vec_base:
handler:                  // M-mode trap handler
  li    t3, 1
  sw    t3, R_HAN(x0)
  csrr  t4, mepc
  addi  t4, t4, 4         // skip the faulting instruction so we do not spin
  csrw  mepc, t4
  mret
