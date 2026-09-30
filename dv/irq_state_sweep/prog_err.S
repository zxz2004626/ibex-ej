// Trigger the IF skid-buffer window with a TOP-LEVEL FAULT INJECTION ONLY.
//
// The software does nothing unusual. The fault model perturbs the external
// instruction-bus response (`instr_err_i` on ibex_top) for a single fetch --
// exactly what a faulty memory, an ECC error or a misbehaving peripheral
// would drive.
//
//   back:  addi s0, s0, 1
//   fault: nop               <- instr_err_i injected for this fetch
//          blt s1, s2, back   <- backward => predicted TAKEN, actually not taken
//
// The resulting instruction access fault goes through the controller's FLUSH
// state, exactly like `ecall` did -- but the trigger is an external signal.

  .set R_CNT,  0x600
  .set R_HAN,  0x604
  .set R_DONE, 0x6F0

  .section .text.start,"ax",@progbits
  .globl _start
_start:
  la    t0, vec_base
  csrw  mtvec, t0

  li    s0, 0
  li    s1, 9              // 9 < 5 false -> blt NOT taken (worst case: mispredict)
  li    s2, 5

back:
  addi  s0, s0, 1

fault:
  nop                      // <- external instr_err_i lands on this fetch
  blt   s1, s2, back       // backward branch sitting in IF while `fault` is in ID
  sw    s0, R_CNT(x0)
  li    t6, 0xDEADBEEF
  sw    t6, R_DONE(x0)
9: j 9b

  .section .vec,"ax",@progbits
  .balign 256
vec_base:                   // exception vector (exc_pc = {mtvec[31:8], 8'h00})
handler:
  li    t3, 1
  sw    t3, R_HAN(x0)      // marker: the trap handler actually ran
  mret                     // mepc already points at `fault`, so it re-executes
