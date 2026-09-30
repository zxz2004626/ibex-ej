#!/usr/bin/env bash
#
# U-mode privilege escalation via a single top-level instruction-bus error,
# when Ibex is built with BranchPredictor=1.
#
#   ./repro.sh            build both configurations and run all cases
#   ./repro.sh -w         ... and dump FSDB waveforms into waves/
#
# Requires: VCS, a riscv64-unknown-elf- toolchain and a licence for VCS.
set -e
cd "$(dirname "$0")"

IBEX="$(cd ../../.. && pwd)"
PRIM="$IBEX/vendor/lowrisc_ip/ip/prim/rtl"
GEN="$IBEX/vendor/lowrisc_ip/ip/prim_generic/rtl"
PULP="$IBEX/vendor/pulp_common_cells/rtl"
DVUT="$IBEX/vendor/lowrisc_ip/dv/sv/dv_utils"

WAVE=0
[ "$1" = "-w" ] && WAVE=1

# ---------------------------------------------------------------- filelist
{
  for f in prim_secded_pkg.sv prim_mubi_pkg.sv prim_count_pkg.sv prim_cipher_pkg.sv \
           prim_util_pkg.sv prim_subreg_pkg.sv; do echo "$PRIM/$f"; done
  echo "$GEN/prim_pkg.sv"; echo "$GEN/prim_ram_1p_pkg.sv"
  echo "$IBEX/rtl/ibex_pkg.sv"; echo "$IBEX/rtl/ibex_cheriot_pkg.sv"
  for f in prim_fifo_sync.sv prim_fifo_sync_cnt.sv prim_lfsr.sv prim_count.sv \
           prim_secded_inv_39_32_enc.sv prim_secded_inv_39_32_dec.sv \
           prim_secded_inv_64_57_enc.sv prim_secded_inv_64_57_dec.sv \
           prim_sparse_fsm_flop.sv prim_onehot_check.sv; do echo "$PRIM/$f"; done
  for f in prim_flop.sv prim_buf.sv prim_clock_gating.sv prim_clock_mux2.sv \
           prim_flop_2sync.sv prim_flop_en.sv prim_flop_no_rst.sv prim_ram_1p.sv \
           prim_and2.sv prim_xor2.sv prim_xnor2.sv; do echo "$GEN/$f"; done
  ls "$IBEX"/rtl/*.sv | grep -vE "ibex_tracer|ibex_top_tracing|ibex_tracer_pkg|ibex_cheriot_pkg|ibex_pkg"
  echo "$PULP/stream_fork.sv"; echo "$PULP/stream_join_dynamic.sv"
  echo "tb_ibex_esc.sv"
} > filelist.f

build() { # $1 = output name, $2 = extra defines
  vcs -full64 +vcs+lic+wait -sverilog -timescale=1ns/1ps -debug_access+all -kdb \
      +define+RVFI $2 +incdir+"$PRIM" +incdir+"$DVUT" \
      -f filelist.f -o "$1" -top tb_ibex_esc > "vcs_$1.log" 2>&1 \
    || { echo "BUILD FAILED for $1 - see vcs_$1.log"; exit 1; }
}

echo "== building =="
build sim_bp   +define+BP_ENABLE     # BranchPredictor = 1  (maxperf)
build sim_nobp                       # BranchPredictor = 0

# ------------------------------------------------------------- program image
for p in prog_u prog_u_ecall; do
  riscv64-unknown-elf-gcc -march=rv32im -mabi=ilp32 -nostdlib -nostartfiles \
      -T link.ld -o $p.elf $p.S
  riscv64-unknown-elf-objcopy -O binary $p.elf $p.bin
  python3 gen_hex.py $p.bin $p.hex 0x80 >/dev/null
done

FAULT_HEX=$(riscv64-unknown-elf-nm prog_u.elf | awk '$3=="fault"{print $1}')
FAULT=$((16#$FAULT_HEX))
echo "== the fault is injected once, on the fetch of 'fault' @ 0x$FAULT_HEX ($FAULT) =="

run() { # $1 = sim, $2 = tag, $3 = program image, $4.. = extra
  local sim=$1 tag=$2 prog=$3
  shift 3
  local w=""
  [ $WAVE = 1 ] && w="+wave=waves/$tag.fsdb"
  ./$sim +mem=$prog +dump=dump_$tag.txt +trace=1 $w "$@" \
       > run_$tag.log 2>&1 || true
  printf '\n----- %s -----\n' "$tag"
  grep -E "^FAULT |^RVFI|^DONE|^TIMEOUT" run_$tag.log | head -40
  [ -f dump_$tag.txt ] && cat dump_$tag.txt
}

echo "===== A) external fault injection on instr_err_i ====="
run sim_bp   esc     prog_u.hex       +fault_addr=$FAULT
run sim_nobp ok      prog_u.hex       +fault_addr=$FAULT
run sim_bp   nofault prog_u.hex

echo
echo "===== B) no fault injection at all, just an ecall (a syscall) ====="
run sim_bp   uecall_esc prog_u_ecall.hex
run sim_nobp uecall_ok  prog_u_ecall.hex

echo
echo "== summary =="
for t in esc ok nofault uecall_esc uecall_ok; do
  printf '  %-12s %s\n' "$t" "$(cat dump_$t.txt 2>/dev/null | tr '\n' ' ' || echo 'no completion')"
done
echo
echo "  expect: BP=1 -> handler skipped (R_HAN untouched) and the U-mode code"
echo "          reads mtvec with M privilege (R_ESC = 00000101)."
echo "          BP=0 -> handler runs (R_HAN = 00000001), R_ESC untouched."
