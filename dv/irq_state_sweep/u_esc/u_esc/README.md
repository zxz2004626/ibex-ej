# U-mode privilege escalation from a single top-level instruction-bus error (`BranchPredictor=1`)

## Summary

When Ibex is built with `BranchPredictor=1`, the IF-stage branch-predictor skid
buffer is not invalidated when the pipeline is flushed by a trap. If a
predicted-taken branch happens to be sitting in the skid buffer when an
exception is taken, that stale branch survives the redirect and is executed as
the first post-trap instruction.

Because trap entry is what raises the privilege level, the consequence from
U-mode is not just "the handler is skipped" - the core is now in M-mode and the
PC is steered back into the U-mode instruction stream, so **U-mode code keeps
executing with M-mode privilege**.

Only one external port is perturbed to trigger this: a single transient error
response on the top-level `instr_err_i` (an instruction access fault). No
software cooperation and no forcing of internal signals is required.

## Impact

A sandboxed U-mode program that takes one transient instruction-bus fault
executes past the trap handler with M-mode privilege. It can then read/write
M-mode-only CSRs (`mtvec`, `pmpcfg*`, ...), reprogram PMP, or otherwise escape
the U-mode sandbox completely. The trap is silently swallowed - the handler that
would have enforced the policy never runs.

Note this is *not* limited to `instr_err_i`: anything that reaches the
controller's `FLUSH` state is exposed - all synchronous exceptions (illegal
instruction, `ecall`, `ebreak`, instruction fetch error, load/store misaligned
or access fault, CHERIoT faults) plus `mret`, `dret`, `wfi` and CSR-write
triggered flushes. External interrupts (`irq_*`) and debug entry are **not**
affected, because they are taken through `IRQ_TAKEN` / `DBG_TAKEN_IF`, which
leave `halt_if` deasserted and therefore do clear the skid.

## Affected configuration

* `BranchPredictor = 1`. This is **not** a default and **not** one of the
  supported configurations: in `ibex_configs.yaml` every supported entry
  (`small`, `opentitan`, `maxperf`, `maxperf-pmp*`) sets `BranchPredictor: 0`.
  The only entry that enables it is `experimental-branch-predictor`, listed under
  "EXPERIMENTAL CONFIGURATIONS - configurations using experimental features that
  aren't yet verified and/or known to have issues". The `maxperf` entry is
  explicitly "the maximum performance configuration *ignoring* the branch
  predictor (which isn't yet fully verified)".

  So this is a latent defect in an experimental, non-default configuration
  rather than a vulnerability in any supported build - but it must be fixed
  before the branch predictor can be considered production-ready.
* Verified on upstream `master` at `4dd3932a`.

## Root cause

`rtl/ibex_if_stage.sv:731` (inside `generate if (BranchPredictor) : g_branch_predictor`):

```systemverilog
assign instr_skid_valid_d = (instr_skid_valid_q & ~id_in_ready_i & ~stall_dummy_instr &
                             !(instr_gets_expanded inside
                             {INSTR_EXPANDED, INSTR_EXPANDED_COMMIT})) | instr_skid_en;
```

The only way to invalidate the skid is `~id_in_ready_i`; there is no
flush/trap/kill term. `instr_skid_en` cannot re-fill while `pc_set_i` is high,
but an *already occupied* skid is never cleared.

`rtl/ibex_controller.sv:1020`:

```systemverilog
assign id_in_ready_o = ~stall & ~halt_if & ~retain_id;
```

* `FLUSH` (used for exceptions, `mret`, `dret`, `wfi`, CSR-write flushes)
  asserts `halt_if`, so `id_in_ready_o == 0` and the skid survives the redirect.
* `IRQ_TAKEN` and `DBG_TAKEN_IF` leave `halt_if` deasserted and also assert
  `pc_set_o`, so `id_in_ready_o == 1` while `if_id_pipe_reg_we` is masked by
  `~pc_set_i` - the skid is cleared without being consumed. That is why only the
  `FLUSH` path is affected.

Timeline for the reproducer below (cycles are simulation cycles):

```
cyc 14  ctrl=FLUSH   instr_skid_valid_q=1  instr_skid_addr_q=0x000000a0   <- branch stranded
cyc 15  ctrl=DECODE  instr_skid_valid_q=1
cyc 16  ctrl=DECODE  instr_skid_valid_q=0  pc_id=0x000000a0 valid=1       <- stale insn latched
```

At cyc 16 `id_in_ready_o == 1` and `pc_set_i == 0`, so
`if_id_pipe_reg_we = if_instr_valid & id_in_ready_i & ~pc_set_i`
(`ibex_if_stage.sv:587`) is high and the stale branch is written into the IF/ID
register.

If that stale branch turns out **not** to be taken (a static-predictor
misprediction), `nt_branch_mispredict_o` steers the PC to the branch's own
fall-through (`predicted_branch_nt_pc_q`, `ibex_if_stage.sv:897`), which is back
in the pre-trap instruction stream - so the trap vector is abandoned entirely.

The same state element is what the instruction cache already guards against for
its own skid (`rtl/ibex_icache.sv:1105`):

```systemverilog
assign skid_valid_d =
    // Branches invalidate the skid buffer
    branch_i ? 1'b0 : ...
```

## Reproducer

```
u_esc/
  repro.sh            builds both configurations and runs all three cases
  tb_ibex_esc.sv      VCS testbench (simple memory + one-shot instr_err_i injection)
  prog_u.S            PoC A: external one-shot `instr_err_i` fault injection
  prog_u_ecall.S      PoC B: no fault injection at all - just an `ecall`
  link.ld gen_hex.py  build helpers (reset vector 0x80, 256-byte aligned .vec)
  skid_fix.patch      proposed one-line fix
  waves/u_esc.fsdb      waveform, PoC A, BranchPredictor=1 (vulnerable)
  waves/u_ok.fsdb       waveform, PoC A, BranchPredictor=0 (correct)
  waves/u_ecall_esc.fsdb  waveform, PoC B, BranchPredictor=1 (vulnerable)
  waves/u_ecall_ok.fsdb   waveform, PoC B, BranchPredictor=0 (correct)
```

```sh
cd u_esc && ./repro.sh          # add -w to regenerate the FSDB waveforms
```

The program drops to U-mode via `mret` (`mstatus.MPP = 0`), then executes:

```asm
fault:
  nop                     // <- a single instr_err_i error response lands here
  blt   s1, s2, back      // backward => predicted TAKEN, but 9 < 5 is false
  csrr  t2, mtvec         // M-mode-only CSR: illegal in U-mode
  sw    t2, R_ESC(x0)     // executes only if we are actually in M-mode
```

`back` is placed before `fault` so the branch offset is negative and the static
predictor predicts it taken.

## Observed results

```
PoC A (one-shot instr_err_i fault)
  BranchPredictor=1 + fault : R_HAN=00000013 R_ESC=00000101   <- escalated
  BranchPredictor=0 + fault : R_HAN=00000001 R_ESC=00000000   <- correct
  BranchPredictor=1, no fault: R_HAN=00000001 R_ESC=00000000  <- control

PoC B (plain `ecall`, NO fault injection; repro.sh section B)
  BranchPredictor=1         : R_HAN=00000013 R_ESC=00000101   <- escalated
  BranchPredictor=0         : R_HAN=00000001 R_ESC=00000000   <- correct
```

PoC B differs from A only in what triggers the trap. `prog_u_ecall.S` runs in
U-mode and executes an ordinary `ecall`; in the vulnerable build the trap handler
is skipped and the `blt` back-edge, stranded in the skid buffer, is executed in
M-mode:

```
RVFI 14 cyc=26 pc=000000b8 insn=00000073 trap=1 | priv=3 mcause=11  <- U-mode ecall, priv raised
RVFI 15 cyc=29 pc=000000bc insn=ff24cce3 trap=0 | priv=3 mcause=11  <- the STALE blt
RVFI 17 cyc=32 pc=000000c4 insn=305023f3 trap=0 | priv=3           <- csrr t2,mtvec SUCCEEDS
```

(`li t2, 0` sits between the branch and the probe so that the correct path,
where the U-mode `csrr` traps and the handler skips it, still leaves
`R_ESC = 0` rather than a stale register value.)

* `R_HAN` (0x600) is written by the M-mode trap handler. `00000013` is the
  memory fill pattern - i.e. the handler never ran.
* `R_ESC` (0x604) is written by the U-mode code only if `csrr t2, mtvec`
  succeeds, i.e. only if the core is in M-mode.

RVFI trace of the vulnerable run (`RVFI <n> cyc=.. pc=.. insn=.. trap=.. | priv=.. mcause=..`):

```
RVFI 14 cyc=26 pc=000000b8 insn=00000013 trap=1 | priv=3 mcause=1   <- access fault, priv raised to M
RVFI 15 cyc=29 pc=000000bc insn=ff24cce3 trap=0 | priv=3 mcause=1   <- the STALE branch, still in M-mode
RVFI 16 cyc=31 pc=000000c0 insn=305023f3 trap=0 | priv=3 mcause=1   <- csrr t2,mtvec SUCCEEDS (rd=0x101)
```

For comparison, the same instruction in genuine U-mode (`BranchPredictor=0`, or
`BranchPredictor=1` without the fault) correctly traps:

```
RVFI 22 cyc=38 pc=000000c0 insn=305023f3 trap=1 | priv=3 mcause=2   <- illegal instruction
```

The `no fault` control run is important: it shows the `csrr mtvec` probe really
does trap when the core is honestly in U-mode, so `R_ESC = 0x101` can only be
explained by the core running in M-mode.

## Suggested fix

```diff
--- a/rtl/ibex_if_stage.sv
+++ b/rtl/ibex_if_stage.sv
@@ -729,6 +729,7 @@
     assign instr_skid_en = predict_branch_taken & ~pc_set_i & ~id_in_ready_i & ~instr_skid_valid_q;

     assign instr_skid_valid_d = (instr_skid_valid_q & ~id_in_ready_i & ~stall_dummy_instr &
+                                 ~pc_set_i &
                                  !(instr_gets_expanded inside
                                  {INSTR_EXPANDED, INSTR_EXPANDED_COMMIT})) | instr_skid_en;
```

`pc_set_i` is the PC-redirect signal already available in `ibex_if_stage`
(`ibex_if_stage.sv:100`) and already used in `instr_skid_en`, so this simply
makes the invalidation symmetric. It covers `PC_EXC` (exceptions), `PC_ERET`
(`mret`), `PC_DRET` (`dret`) and `PC_JUMP`. It does not interfere with the
predictor's own redirect, which goes through `pc_mux_internal == PC_BP` and does
not assert `pc_set_i` (`ibex_if_stage.sv:237`).

Narrowing it to `pc_set_i & (pc_mux_i == PC_EXC)` (i.e. reusing the existing
`flush_expanded`) also fixes the exception cases but leaves `mret` / `dret`
broken.

With the patch applied, all three cases in `repro.sh` produce `R_HAN=00000001`,
`R_ESC=00000000`, and no regression was observed in the mult/div interrupt
sweeps in the parent directory.

## Reachability without any fault injection

`instr_err_i` is not a special "attacker only" signal. In `ibex_if_stage.sv:430`
it is OR'd with the PMP and CHERIoT checks to form the single
`instr_fetch_err` that reaches the controller:

```systemverilog
assign if_instr_err = if_instr_bus_err | if_instr_pmp_err | cheriot_acc_vio | cheriot_bound_vio;
```

So the very same `FLUSH` window is reachable from entirely ordinary
architecture:

* **PMP instruction-access fault** - a U-mode program jumping outside its
  executable region. This is precisely the violation a U-mode sandbox exists to
  contain, and it needs no fault injection at all.
* **CHERIoT fetch violation** (`cheriot_acc_vio` / `cheriot_bound_vio`) - a
  capability whose bounds or permissions do not cover the fetch target.
* A memory/interconnect error response, or an ECC error on a fetched word -
  the error the ECC machinery is *designed* to trap on.

More generally the bug does not need `instr_err` at all: the same skid window is
entered by every path through the controller's `FLUSH` state. It has been
reproduced with an ordinary `ecall` (mcause 11) and with an ordinary `mret`, both
of which are plain instructions requiring no fault injection. The `instr_err`
variant exists only because it makes the trigger unambiguously external.

## Notes on the threat model

* The trigger is a **single, transient, external** error response on
  `instr_err_i`. The same works through `data_err_i` (load/store access fault).
  An attacker who can glitch the bus, corrupt a fetch, or use a malicious
  peripheral needs no software cooperation.
* The only code-shape requirement is that the instruction after the faulting one
  is a backward branch (predicted taken). Loop back-edges are pervasive, so
  this is not a contrived pattern.
* External interrupts and debug requests do **not** trigger this; see the
  `FLUSH` vs `IRQ_TAKEN` note above.
