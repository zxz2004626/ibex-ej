# Interrupt / trap state-retention sweep

Purpose: hunt for the bug class described in CVA6 issue #3408 — a multi-cycle
unit holding persistent state that is **not** cleared when a trap flushes the
pipeline, so the stale state leaks into a later (possibly more privileged)
instruction.

The class only bites when the unit's state can span a **trap boundary**. Ibex's
design takes traps only at instruction boundaries, so the interesting question is
which units can hold state *across* ID-stage instructions.

## What is here

| file | purpose |
|---|---|
| `tb_ibex_irq.sv` | VCS testbench: instantiates `ibex_top`, simple 1-cycle memory, RVFI instruction trace, interrupt injection, result dump |
| `prog.S` | Directed mult/div program: a div/rem pair interrupted by an external IRQ, then mul/mulh and a further div/rem after the trap; the trap handler runs its own div/rem |
| `prog_bp.S` | Branch-predictor skid-buffer test: `ecall` immediately followed by a backward (predicted-taken, actually not-taken) branch |
| `link.ld` | Places code at `0x80` (Ibex reset vector) and the trap vector table in its own 256-byte aligned `.vec` section |
| `gen_hex.py` | flat binary -> word-addressed `$readmemh` image |
| `sweep2.py`, `sweep3.py` | phase sweeps: run the program N times, each time asserting the IRQ one cycle later, and compare every result against the no-interrupt golden run |
| `run.sh` | builds a simulator (`vcs`) and the program images |

## Things that will bite you (Ibex specifics found the hard way)

1. **`mtvec.BASE` is forced 256-byte aligned.** `ibex_cs_registers.sv` builds
   `mtvec_d` from `csr_wdata_int[31:8]`, so writing e.g. `0xC0` silently becomes
   base `0x00`. The handler must sit on a 256-byte boundary.
2. **Non-CHERIoT mode uses vectored interrupts.**
   `ibex_if_stage.sv` (`exc_pc_mux`): the direct `{mtvec[31:2],2'b00}` form is
   used only when `BaseIsa == BaseIsaRV32IorCHERIoT && cheriot_enable == On`.
   Otherwise `EXC_PC_IRQ` is `{mtvec[31:8], 1'b0, irq_vec, 2'b00}`, i.e. an
   external interrupt (cause 11) enters at `base + 44`.
3. **`mie.MEIE`, not just `mstatus.MIE`.** `irqs_o = mip & mie_q`, so
   `irq_pending_o` stays 0 unless the per-interrupt enable bit (11) is set.
4. **A short IRQ pulse during a multi-cycle instruction is simply dropped.**
   `handle_irq` is gated on `!stall`, and mult/div asserts stall for its whole
   duration. A realistic (level-held) interrupt is required — the TB's
   `+irq_mode=1` holds the line until the core takes it.

## Running

```sh
./run.sh simv                                   # RV32MFast
./run.sh simv_single +define+RV32M_SINGLE       # RV32MSingleCycle
./run.sh simv_slow   +define+RV32M_SLOW         # RV32MSlow
./run.sh simv_bp     +define+BP_ENABLE          # BranchPredictor=1
python3 sweep3.py ./simv_single
```

## Results

### mult/div — no state leaks across an external interrupt

4000 sweep points — `RV32MFast` 1000, `RV32MSingleCycle` 1000, `RV32MSlow` 2000
(interrupt window 1/3/7/40 cycles, and held-until-taken), each comparing
`div`/`rem` before the trap, the trap handler's own `div`/`rem`, and
`mul`/`mulh`/`div`/`rem` after the trap against the golden run: all bit-exact.

The handler really did execute in a large fraction of the runs (572/1000 for
`RV32MFast` and `RV32MSingleCycle`, 713/2000 for `RV32MSlow` — the rest have the
IRQ injected after the program has already finished), so the cross-context case
is genuinely covered rather than trivially passing.

Why it is safe: `ibex_controller.sv` only enters `IRQ_TAKEN` when
`!stall && !special_req && !id_wb_pending`, and `ibex_multdiv_*` asserts
`stall_multdiv` for the whole operation, so the FSM is always back in
`MD_IDLE`/`ALBL` before a trap is taken.

### IF skid buffer — CONFIRMED bug (BranchPredictor=1 only)

`prog_bp.S` + `simv_bp` reproduces a trap handler being **skipped**:

```
RVFI 7  pc=0000009c  insn=00000073  trap=1        <- ecall, exception taken
RVFI 8  pc=000000a0  insn=ff24cce3               <- stale skid branch executed
RVFI 9  pc=000000a4  ...                          <- handler at 0x100 never runs
CYC 14  ctrl=6(FLUSH)  skid_valid=1 skid_addr=000000a0
CYC 16  ctrl=5(DECODE) skid_valid=0 id_pc=000000a0 id_valid=1
```

The injected trap in this program is a synchronous exception: `ecall` from
M-mode, i.e. `mcause = 11`, `mepc = 0x9c`, `mstatus.MPP = 3` (not an interrupt).

### Trigger it with top-level fault injection only

`prog_err.S` / `tb_ibex_irq.sv +instr_err_addr=<addr>` shows the same window is
reachable by perturbing **one external port**: `instr_err_i` on `ibex_top`, for
a single fetch. That is what a faulty memory, an ECC error or a misbehaving
peripheral drives - no software cooperation and no internal signal forcing.

```sh
# fault the fetch of the instruction at 0x9c (one-shot, transient)
./simv_bp +mem=prog_err.hex +instr_err_addr=156 +max_cycles=2000   # BP=1 -> handler skipped
./simv    +mem=prog_err.hex +instr_err_addr=156 +max_cycles=2000   # BP=0 -> handler runs
```

`data_err_addr=<addr>` does the same through the data port (load/store access
fault). Note the asymmetry: `irq_*` / `debug_req_i` do **not** trigger it
(they take `IRQ_TAKEN` / `DBG_TAKEN_IF`, which clear the skid) - only the
`err`-driven exceptions do.

### From U-mode this is a privilege escalation, not just a skipped handler

`prog_u.S` drops to U-mode via MRET (`mstatus.MPP = 0`), then the same
one-shot `instr_err_i` fault is injected. Trap entry raises the privilege to M
(that is inherent to taking the trap); if the handler is then skipped, the PC
is steered back into the U-mode instruction stream **while the core is already
in M-mode**.

```sh
./simv_bp +mem=prog_u.hex +instr_err_addr=184 +max_cycles=2000   # BP=1
./simv    +mem=prog_u.hex +instr_err_addr=184 +max_cycles=2000   # BP=0
```

```
BP=1 (bug)                                        BP=0 (correct)
RVFI 14 pc=b8  trap=1 mcause=1 priv=3(M)          same trap, then
RVFI 15 pc=bc  (stale blt)  priv=3(M)             handler runs -> R_HAN=1
RVFI 16 pc=c0  csrr t2,mtvec -> rd=00000101       U-mode csrr mtvec
               ^ M-only CSR read SUCCEEDS           -> trap mcause=2 (illegal)
R_HAN=0(unwritten)  R_ESC=0x101                   R_ESC=0
```

The U-mode code reads `mtvec`, an M-mode-only CSR, successfully - i.e. the
sandboxed code keeps executing with M-mode privilege. With `skid_fix.patch`
applied this becomes `R_HAN=1`, `R_ESC=0` and the `csrr` correctly takes an
illegal-instruction exception.

`prog_mret.S` shows the same window on a **non-exception** flush: the
instruction that flushes is `mret`. With `BranchPredictor=1` the `mret`'s
return address never takes effect (R_MRET stays unwritten, R_AFTER = 0x1111);
with `BranchPredictor=0` it returns correctly. `waves/mret_bug.fsdb` and
`waves/mret_ok.fsdb` are the two waveforms.

`instr_skid_valid_d` (`rtl/ibex_if_stage.sv:731`) has no flush term; the only
way out is `~id_in_ready_i`. `FLUSH` asserts `halt_if`, which forces
`id_in_ready_o == 0` (`rtl/ibex_controller.sv:1020`), so the skid survives the
trap redirect; the following `DECODE` cycle has `id_in_ready=1` and
`pc_set_i=0`, so the stale branch is latched into ID. `IRQ_TAKEN` and
`DBG_TAKEN_IF` leave `halt_if` deasserted, which is why interrupts and debug
entry are *not* affected — only the exception (`FLUSH`) path is.

Run `./simv_bp +mem=prog_bp.hex +irq_start=0 +irq_len=0` and compare with
`./simv +mem=prog_bp.hex +irq_start=0 +irq_len=0` to see the difference.

Scope: everything that reaches the controller's `FLUSH` state is exposed —
exceptions (illegal instruction, `ecall`, `ebreak`, instruction fetch error,
load/store misaligned or access fault, CHERIoT faults), plus `mret`, `dret`,
`wfi` and CSR-write-triggered flushes. Interrupts and debug entry use
`IRQ_TAKEN` / `DBG_TAKEN_IF`, which leave `halt_if` deasserted, so they are not
affected.


## Lockstep (SecureIbex=1) - still escalates, and lockstep is NOT what catches it

`SecureIbex=1` enables the redundant lockstep core (`Lockstep = SecureIbex` in
`ibex_top.sv:212`) plus PCIncrCheck, hardened counters and register-file ECC.
The build keeps `MemECC=0` so the plain 32-bit memory model stays valid.

```sh
./run.sh lsp     +define+SECURE +define+BP_ENABLE
./run.sh lsp_nobp +define+SECURE
./lsp +mem=prog_u.hex +instr_err_addr=184 +max_cycles=4000
```

Result on `prog_u` with the one-shot `instr_err_i` fault:

```
R_HAN = 0x13 (unwritten)   handler never ran
R_ESC = 0x101              U-mode code read mtvec with M privilege  -> escalation still happens

cyc 27  pc_mismatch=1  lockstep_cmp=0     <- PCIncrCheck in the PRIMARY core
cyc 28  pc_mismatch=0  lockstep_cmp=1     <- PCIncrCheck in the SHADOW, one cycle later
LSMIS (outputs_mismatch) never asserts
```

Two things to take away:

1. **The lockstep output comparison does not fire.** `outputs_mismatch` is
   `shadow_outputs_q != core_outputs_q[0]` - it compares the two cores against
   *each other*. Both cores are fed the same `instr_err_i` and both contain the
   same bug, so they diverge identically and their outputs match. Lockstep
   catches transient faults inside *one* core; it cannot catch a deterministic
   design bug driven by a shared input.
2. **What does fire is `PCIncrCheck`**, an independent hardening feature also
   enabled by `SecureIbex` (`localparam bit PCIncrCheck = SecureIbex`). It
   notices the anomalous PC sequence and raises `alert_major_internal`. The
   `lockstep_cmp=1` at cyc 28 is just the shadow's own PCIncrCheck, surfaced
   through the lockstep's `shadow_alert_major_internal` - which is why it can
   look like lockstep caught it.

Controls (both 0 alerts): `prog_min` (backward branch, no trap) with BP=1, and
`prog_bp` with BP=0 - so the alert really is bug-specific.

So: with `SecureIbex=1` the escalation still happens and is reported *after the
fact* by PCIncrCheck; with `SecureIbex=0` (`maxperf`) there is no PCIncrCheck
and no lockstep, and the escalation is silent.
