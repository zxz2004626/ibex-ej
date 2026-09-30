# One Branch Away from M-mode: U-mode privilege escalation in Ibex

A U-mode program that takes a trap while a predicted-taken branch is stranded in
the IF-stage branch-predictor skid buffer keeps executing **with M-mode
privilege**. The trap handler - the code that is supposed to enforce the U/M
boundary - never runs.

The trigger is ordinary software. No fault injection, no attacker-controlled
pins, no hardware glitch: an `ecall` (a syscall any U-mode program may issue)
immediately followed by a loop back-edge is enough.

## Affected configuration

* Requires `BranchPredictor = 1`.
* This is **not** a default and **not** a supported configuration. In
  `ibex_configs.yaml` every supported entry - `small`, `opentitan`, `maxperf`,
  `maxperf-pmp*` - sets `BranchPredictor: 0`. The only entry that enables it is
  `experimental-branch-predictor`, listed under
  *"EXPERIMENTAL CONFIGURATIONS - configurations using experimental features
  that aren't yet verified and/or known to have issues"*. The `maxperf` entry is
  explicitly described as the maximum performance configuration *"ignoring the
  branch predictor (which isn't yet fully verified)"*.

So no supported Ibex build is affected. This is a latent defect in an
experimental configuration that must be fixed before the branch predictor can be
considered production-ready - and any integration that has enabled the
predictor is fully exposed.

* Verified against upstream `master` at `4dd3932a`.

## Impact

Trap entry is what raises the privilege level, and trap entry does happen:
`mepc`, `mcause` and `mstatus` are all updated, `mstatus.MPP` records U, and the
core is now in M-mode. But the PC is then steered back into the U-mode
instruction stream by the stranded branch, so the sandboxed program continues
running with M-mode privilege.

It can then read and write M-mode-only CSRs (`mtvec`, `pmpcfg*`, `mepc`, ...),
disable PMP, redirect the trap vector, or otherwise take complete control of the
core. The trap is silently swallowed and whatever policy the handler would have
enforced never happens.

This is a design defect rather than a transient fault, so redundancy does not
help: a lockstep shadow core contains the same bug and produces identical
outputs, so the lockstep output comparison never fires. (In a `SecureIbex=1`
build the independent `PCIncrCheck` hardening does notice the anomalous PC and
raises `alert_major_internal` - but only *after* the trap has been skipped.)

## Root cause

`rtl/ibex_if_stage.sv:731`, inside `generate if (BranchPredictor) : g_branch_predictor`:

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

* `FLUSH` - taken for every synchronous exception, and also for `mret`, `dret`,
  `wfi` and CSR-write flushes - asserts `halt_if`, so `id_in_ready_o == 0` and
  the skid survives the redirect.
* `IRQ_TAKEN` and `DBG_TAKEN_IF` leave `halt_if` deasserted and additionally
  assert `pc_set_o`, so `id_in_ready_o == 1` while `if_id_pipe_reg_we` is masked
  by `~pc_set_i`: the skid is cleared without being consumed. **External
  interrupts and debug requests are therefore not affected** - only the `FLUSH`
  path is.

Concretely, for the PoC below:

```
CYC 24  ctrl=5 (DECODE)  skid_valid=0  id_pc=0xb8 id_valid=1   <- the ecall is in ID
CYC 25  ctrl=6 (FLUSH)   skid_valid=1  skid_addr=0xbc          <- the back-edge is stranded
CYC 26  ctrl=5 (DECODE)  skid_valid=1
CYC 27  ctrl=5 (DECODE)  skid_valid=0  id_pc=0xbc id_valid=1   <- stale insn latched into ID
```

At CYC 27 `id_in_ready_o == 1` and `pc_set_i == 0`, so
`if_id_pipe_reg_we = if_instr_valid & id_in_ready_i & ~pc_set_i`
(`ibex_if_stage.sv:587`) is high and the stale branch is written into the IF/ID
register.

The branch is predicted-taken but actually **not** taken, so
`nt_branch_mispredict_o` steers the PC to the branch's own fall-through
(`predicted_branch_nt_pc_q`, `ibex_if_stage.sv:897`) - straight back into the
pre-trap instruction stream - and the trap vector is abandoned.

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
  repro.sh                builds both configurations and runs all cases
  tb_ibex_esc.sv          VCS testbench (simple memory, RVFI trace, timeline probe)
  prog_u_ecall.S          PoC: software only - an ordinary `ecall`
  prog_u.S                same window via one external `instr_err_i` error response
  link.ld gen_hex.py      build helpers (reset vector 0x80, 256-byte aligned .vec)
  skid_fix.patch          proposed one-line fix
  waves/u_ecall_esc.fsdb  waveform, BranchPredictor=1 (vulnerable)
  waves/u_ecall_ok.fsdb   waveform, BranchPredictor=0 (correct)
  waves/u_esc.fsdb        waveform, external-trigger variant, BranchPredictor=1
  waves/u_ok.fsdb         waveform, external-trigger variant, BranchPredictor=0
```

```sh
cd u_esc && ./repro.sh          # add -w to regenerate the FSDB waveforms

# just the software-only PoC:
./sim_bp   +mem=prog_u_ecall.hex +trace=1 +timeline=1
./sim_nobp +mem=prog_u_ecall.hex +trace=1
```

### The PoC

`prog_u_ecall.S` drops to U-mode via `mret` (`mstatus.MPP = 0`) and then runs:

```asm
back:
  addi  s0, s0, 1

Injection:
  ecall                    // the IF stage holds the blt below while this is in ID
  blt   s1, s2, back       // backward -> predicted TAKEN, but 9 < 5 is false

  // Reached only if the trap handler was skipped, i.e. we are still in M-mode.
  li    t2, 0
  csrr  t2, mtvec          // M-mode-only CSR: illegal in U-mode
  sw    t2, R_ESC(x0)
  li    t6, 0xDEADBEEF
  sw    t6, R_DONE(x0)
```

`ecall` is an ordinary syscall, and a loop back-edge is the most common
control-flow shape there is. The `li t2, 0` keeps the discriminator clean: on
the correct path the U-mode `csrr` raises an illegal instruction, the handler
skips it, and `sw t2, R_ESC` still executes in U-mode - but now carries `t2 == 0`,
so `R_ESC` stays zero.

## Observed results

```
BranchPredictor=1 : R_HAN=00000013  R_ESC=00000101   <- escalated
BranchPredictor=0 : R_HAN=00000001  R_ESC=00000000   <- correct
```

* `R_HAN` (0x600) is written by the M-mode trap handler. `00000013` is the
  memory fill pattern - the handler never ran.
* `R_ESC` (0x604) is written by the U-mode code only if `csrr t2, mtvec`
  succeeds, i.e. only if the core is actually in M-mode.

RVFI trace, vulnerable run
(`RVFI <n> cyc=.. pc=.. insn=.. trap=.. | priv=.. mcause=..`):

```
RVFI 14 cyc=26 pc=000000b8 insn=00000073 trap=1 | priv=3 mcause=8   <- U-mode ecall, priv raised to M
RVFI 15 cyc=29 pc=000000bc insn=ff24cce3 trap=0 | priv=3 mcause=8   <- the STALE branch, still in M-mode
RVFI 17 cyc=32 pc=000000c4 insn=305023f3 trap=0 | priv=3 mcause=8   <- csrr t2,mtvec SUCCEEDS (rd=0x101)
```

RVFI trace, correct run - the trap handler runs and the very same `csrr`
correctly faults in U-mode:

```
RVFI 14 cyc=26 pc=000000b8 insn=00000073 trap=1 | priv=3 mcause=8   <- U-mode ecall, handler entered
RVFI 15 cyc=29 pc=00000100 ...                                      <- handler at 0x100
RVFI 20 cyc=34 pc=00000114 insn=30200073 trap=0 | priv=0            <- mret, back to U-mode
RVFI 23 cyc=39 pc=000000c4 insn=305023f3 trap=1 | priv=3 mcause=2   <- illegal instruction
```

Because the handler runs in the correct build, the U-mode `csrr mtvec` probe
genuinely traps there - so `R_ESC = 0x101` in the vulnerable build can only mean
the core was executing with M-mode privilege.

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
makes the invalidation symmetric: if the PC is redirected, the skid instruction
is by definition on the wrong path and must be dropped. It covers `PC_EXC`
(exceptions), `PC_ERET` (`mret`), `PC_DRET` (`dret`) and `PC_JUMP`, and does not
interfere with the predictor's own redirect, which goes through
`pc_mux_internal == PC_BP` and does not assert `pc_set_i`
(`ibex_if_stage.sv:237`).

Narrowing the term to `pc_set_i & (pc_mux_i == PC_EXC)` (i.e. reusing the
existing `flush_expanded`) also fixes the exception cases but leaves `mret` /
`dret` broken.

With the patch applied every case covered by `repro.sh` produces
`R_HAN=00000001`, `R_ESC=00000000`, and no regression was seen in the mult/div
interrupt sweeps in the parent directory.

## Scope of the trigger

Anything that reaches the controller's `FLUSH` state is exposed: every
synchronous exception (illegal instruction, `ecall`, `ebreak`, instruction fetch
error, load/store misaligned or access fault, CHERIoT faults) plus `mret`,
`dret`, `wfi` and CSR-write-triggered flushes.

For the fetch-error family specifically, `instr_err_i` is not the only source -
`ibex_if_stage.sv:430` ORs the PMP and CHERIoT checks into the same signal:

```systemverilog
assign if_instr_err = if_instr_bus_err | if_instr_pmp_err | cheriot_acc_vio | cheriot_bound_vio;
```

so a U-mode program jumping outside its executable region, or a CHERIoT fetch
whose capability does not permit execution, reaches the identical window with no
fault injection of any kind. The one requirement there is that the instruction
after the faulting one is a loop back-edge (predicted taken) that does not itself
produce a fetch error - `predict_branch_taken` is gated by `~fetch_err`
(`ibex_if_stage.sv:780`).

External interrupts (`irq_*`) and debug requests (`debug_req_i`) are **not**
affected; see the `FLUSH` versus `IRQ_TAKEN` note under Root cause.

## Alternative trigger: an external error response

The same window is reachable by perturbing one top-level port instead of using
software - a single transient error response on `instr_err_i`, as a faulty
memory or ECC error would produce. `prog_u.S` is the same program with the
`ecall` replaced by a fetch that gets one injected error
(`+fault_addr=<addr>`, one-shot):

```sh
# +fault_addr takes a decimal address; extract it from the ELF
F=$(riscv64-unknown-elf-nm prog_u.elf | awk '$3=="fault"{print $1}')
./sim_bp +mem=prog_u.hex +fault_addr=$((16#$F)) +trace=1
```

This variant is only useful as a demonstration that the window is reachable from
outside the core as well; the software path above needs no assistance from the
environment at all, so it is the one to concentrate on.
