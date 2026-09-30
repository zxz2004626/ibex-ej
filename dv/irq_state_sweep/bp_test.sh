#!/usr/bin/env bash
# Reproduce the IF skid-buffer bug (requires BranchPredictor=1).
#
#   ./run.sh simv_bp +define+BP_ENABLE     # build
#   ./bp_test.sh                           # run
set -e
cd "$(dirname "$0")"

riscv64-unknown-elf-gcc -march=rv32im -mabi=ilp32 -nostdlib -nostartfiles -T link.ld \
    -o prog_bp.elf prog_bp.S
riscv64-unknown-elf-objcopy -O binary prog_bp.elf prog_bp.bin
python3 gen_hex.py prog_bp.bin prog_bp.hex 0x80

riscv64-unknown-elf-gcc -march=rv32im -mabi=ilp32 -nostdlib -nostartfiles -T link.ld \
    -o prog_bp3.elf prog_bp3.S
riscv64-unknown-elf-objcopy -O binary prog_bp3.elf prog_bp3.bin
python3 gen_hex.py prog_bp3.bin prog_bp3.hex 0x80

echo "  (add +wave=<file>.fsdb to any of the runs below to get a waveform)"
echo
echo "===== exception path, BranchPredictor=0 (baseline: handler runs) ====="
./simv     +mem=prog_bp.hex +dump=b0.txt +irq_start=0 +irq_len=0 +max_cycles=2000 -l b0.log
grep -E "^RVFI [0-9]+ cyc=(1[5-9]|2[0-9]) " b0.log | head -6

echo
echo "===== exception path, BranchPredictor=1 (BUG: handler skipped) ====="
./simv_bp  +mem=prog_bp.hex +dump=b1.txt +irq_start=0 +irq_len=0 +max_cycles=2000 -l b1.log
grep -E "^RVFI [0-9]+ cyc=(1[5-9]|2[0-9]) " b1.log | head -6
grep -E "^CYC (1[3-9]|2[0-9]) " b1.log | head -6

echo
echo "===== external interrupt path, BranchPredictor=1 (handler still runs) ====="
./simv_bp  +mem=prog_bp3.hex +dump=b3.txt +irq_start=30 +irq_len=1 +irq_mode=1 \
           +max_cycles=3000 -l b3.log >/dev/null
grep -E "^RVFI [0-9]+ .*intr=1" b3.log | head -3
