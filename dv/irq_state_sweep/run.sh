#!/usr/bin/env bash
# Build + run the interrupt-phase sweep testbench for Ibex.
#
# Usage:
#   ./run.sh [simv_name] [extra vcs defines...]
#
#   ./run.sh simv                      # RV32MFast          (small)
#   ./run.sh simv_single +define+RV32M_SINGLE   # RV32MSingleCycle (opentitan)
#   ./run.sh simv_slow   +define+RV32M_SLOW     # RV32MSlow
#   ./run.sh simv_bp     +define+BP_ENABLE      # BranchPredictor=1 (maxperf)
#   ./run.sh lsp         +define+SECURE +define+BP_ENABLE   # SecureIbex=1 (lockstep + PCIncrCheck)
#
# Then:  python3 sweep3.py ./simv_single
set -e
IBEX="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$(dirname "$0")"

OUT="${1:-simv}"
shift || true

PRIM="$IBEX/vendor/lowrisc_ip/ip/prim/rtl"
GEN="$IBEX/vendor/lowrisc_ip/ip/prim_generic/rtl"
PULP="$IBEX/vendor/pulp_common_cells/rtl"
DVUT="$IBEX/vendor/lowrisc_ip/dv/sv/dv_utils"

{
  for f in prim_secded_pkg.sv prim_mubi_pkg.sv prim_count_pkg.sv prim_cipher_pkg.sv \
           prim_util_pkg.sv prim_subreg_pkg.sv; do echo "$PRIM/$f"; done
  echo "$GEN/prim_pkg.sv"; echo "$GEN/prim_ram_1p_pkg.sv"
  echo "$IBEX/rtl/ibex_pkg.sv"; echo "$IBEX/rtl/ibex_cheriot_pkg.sv"
  for f in prim_fifo_sync.sv prim_fifo_sync_cnt.sv prim_lfsr.sv prim_count.sv; do echo "$PRIM/$f"; done
  for f in prim_flop.sv prim_buf.sv prim_clock_gating.sv prim_clock_mux2.sv prim_flop_2sync.sv \
           prim_flop_en.sv prim_flop_no_rst.sv prim_ram_1p.sv prim_and2.sv prim_xor2.sv \
           prim_xnor2.sv; do echo "$GEN/$f"; done
  ls "$IBEX"/rtl/*.sv | grep -vE "ibex_tracer|ibex_top_tracing|ibex_tracer_pkg|ibex_cheriot_pkg|ibex_pkg"
  echo "$PULP/stream_fork.sv"; echo "$PULP/stream_join_dynamic.sv"
  echo "tb_ibex_irq.sv"
} > filelist.f

vcs -full64 +vcs+lic+wait -sverilog -timescale=1ns/1ps -debug_access+all -kdb \
    +define+RVFI "$@" +incdir+"$PRIM" +incdir+"$DVUT" \
    -f filelist.f -o "$OUT" -top tb_ibex_irq

# program images
riscv64-unknown-elf-gcc -march=rv32im -mabi=ilp32 -nostdlib -nostartfiles \
    -T link.ld -o prog.elf prog.S
riscv64-unknown-elf-objcopy -O binary prog.elf prog.bin
python3 gen_hex.py prog.bin prog.hex 0x80

riscv64-unknown-elf-gcc -march=rv32im -mabi=ilp32 -nostdlib -nostartfiles \
    -T link.ld -o prog_bp.elf prog_bp.S
riscv64-unknown-elf-objcopy -O binary prog_bp.elf prog_bp.bin
python3 gen_hex.py prog_bp.bin prog_bp.hex 0x80

# golden reference (no interrupt)
"./$OUT" +mem=prog.hex +dump=golden.txt +irq_start=0 +irq_len=0 +max_cycles=20000 -l golden.log
echo "built ./$OUT ; golden:"
cat golden.txt
