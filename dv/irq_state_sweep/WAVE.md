# 复现 IF skid buffer 漏洞并看波形

## 1. 构建 + 跑出波形

```bash
cd dv/irq_state_sweep

# 打开波形导出的配置：BranchPredictor=1（复现 bug）
./run.sh simv_bp +define+BP_ENABLE

# 跑 bug 版本（BranchPredictor=1）
./simv_bp +mem=prog_bp.hex +irq_start=0 +irq_len=0 +max_cycles=2000 \
         +wave=bp_bug.fsdb -l w_bug.log

# 跑对照组（BranchPredictor=0，无 skid buffer）
./run.sh simv
./simv    +mem=prog_bp.hex +irq_start=0 +irq_len=0 +max_cycles=2000 \
          +wave=bp_ok.fsdb  -l w_ok.log
```

`+wave=<file>` 由 testbench 直接支持；`.fsdb` 后缀走 Verdi FSDB dumper，
其它后缀走 `$dumpvars` 的 VCD（VCS 里加 `+define+NO_FSDB`）。

仓库里已经放了两份跑好的波形：

```
waves/bp_bug.fsdb   BranchPredictor=1 —— 处理程序被跳过
waves/bp_ok.fsdb    BranchPredictor=0 —— 处理程序正常执行
```

## 2. 打开

```bash
verdi -ssf waves/bp_bug.fsdb &
# 或者两个一起对比
verdi -ssf waves/bp_bug.fsdb -ssf waves/bp_ok.fsdb &
```

进 nWave 后可以在 TCL 控制台直接 `source wave.tcl` 把关注信号加进来。

## 3. 要看的信号

时钟周期 10 ns，`cyc N` 对应 `t ≈ (N + 9.5) × 10 ns`。关注窗口是
**cyc 13–18，即 225–275 ns**（程序：`ecall` 在 pc 0x9c，紧跟着 0xa0 的
后向分支 `blt`，处理程序在 pc 0x100）。

先把这组控制信号加进来（顺序按因果关系排）：

```tcl
# 分支预测器 skid buffer —— 漏洞主角
add_wave {{tb_ibex_irq.dut.u_ibex_core.if_stage_i.g_branch_predictor.instr_skid_valid_q}}
add_wave {{tb_ibex_irq.dut.u_ibex_core.if_stage_i.g_branch_predictor.instr_skid_addr_q}}
add_wave {{tb_ibex_irq.dut.u_ibex_core.if_stage_i.g_branch_predictor.instr_skid_data_q}}
add_wave {{tb_ibex_irq.dut.u_ibex_core.if_stage_i.g_branch_predictor.instr_skid_en}}

# 控制器：ctrl_fsm_cs 的编码 5=DECODE 6=FLUSH 7=IRQ_TAKEN
add_wave {{tb_ibex_irq.dut.u_ibex_core.id_stage_i.controller_i.ctrl_fsm_cs}}
add_wave {{tb_ibex_irq.dut.u_ibex_core.id_stage_i.controller_i.halt_if}}
add_wave {{tb_ibex_irq.dut.u_ibex_core.id_stage_i.controller_i.flush_id}}
add_wave {{tb_ibex_irq.dut.u_ibex_core.id_stage_i.controller_i.id_in_ready_o}}
add_wave {{tb_ibex_irq.dut.u_ibex_core.id_stage_i.controller_i.pc_set_o}}
add_wave {{tb_ibex_irq.dut.u_ibex_core.id_stage_i.controller_i.pc_mux_o}}
add_wave {{tb_ibex_irq.dut.u_ibex_core.id_stage_i.controller_i.exc_pc_mux_o}}

# IF -> ID 的交接：这一拍决定陈旧指令是否被锁存
add_wave {{tb_ibex_irq.dut.u_ibex_core.if_stage_i.if_id_pipe_reg_we}}
add_wave {{tb_ibex_irq.dut.u_ibex_core.if_stage_i.if_instr_valid}}
add_wave {{tb_ibex_irq.dut.u_ibex_core.if_stage_i.if_instr_addr}}

# ID 阶段实际在执行什么
add_wave {{tb_ibex_irq.dut.u_ibex_core.id_stage_i.instr_valid_i}}
add_wave {{tb_ibex_irq.dut.u_ibex_core.id_stage_i.pc_id_i}}
add_wave {{tb_ibex_irq.dut.u_ibex_core.if_stage_i.instr_rdata_id_o}}

# 架构可见后果
add_wave {{tb_ibex_irq.dut.rvfi_valid}}
add_wave {{tb_ibex_irq.dut.rvfi_pc_rdata}}
add_wave {{tb_ibex_irq.dut.rvfi_intr}}
add_wave {{tb_ibex_irq.dut.rvfi_trap}}
add_wave {{tb_ibex_irq.dut.u_ibex_core.cs_registers_i.mepc_q}}
```

`ctrl_fsm_cs` 的枚举值（`ibex_pkg::ctrl_fsm_e`）：
`0 RESET, 1 BOOT_SET, 2 WAIT_SLEEP, 3 SLEEP, 4 FIRST_FETCH, 5 DECODE,`
`6 FLUSH, 7 IRQ_TAKEN, 8 DBG_TAKEN_IF, 9 DBG_TAKEN_ID`

## 4. 波形上应该看到什么

| cyc | t (ns) | 事件 |
|---|---|---|
| 13 | 225 | `ctrl=5 (DECODE)`，`id_pc=0x9c`（ecall），`instr_skid_valid_q=0` |
| 14 | 235 | `ctrl=6 (**FLUSH**)`，**`instr_skid_valid_q=1`，`instr_skid_addr_q=0x000000a0`** ← 预测跳转的分支正躺在 skid 里 |
| 15 | 245 | `ctrl=5 (DECODE)`，`instr_skid_valid_q` 仍为 1 |
| 16 | 255 | `instr_skid_valid_q` 落 0，**`id_pc=0x000000a0`，`instr_valid_i=1`** ← 陈旧指令被锁存进 ID |
| 18 | 275 | `id_pc=0x000000a4`，控制流留在旧代码路径，**从未出现 `id_pc=0x100`（处理程序入口）** |

关键因果链看两处：

1. **cyc 14**：`halt_if=1` → `id_in_ready_o=0`，所以 `instr_skid_valid_d`
   里唯一的清零点 `~id_in_ready_i` 不成立，skid 活过了这次 `PC_EXC` 重定向。
   （对比 `IRQ_TAKEN`：那一拍 `halt_if=0` → `id_in_ready_o=1` 且 `pc_set_o=1`，
   skid 会被清掉且不会锁存——这就是为什么只有异常路径中招。）
2. **cyc 16**：`id_in_ready_o=1`、`pc_set_o=0` → `if_id_pipe_reg_we=1`，
   陈旧指令在这一拍写进 IF/ID 流水寄存器。

## 5. 与对照组对比

`waves/bp_ok.fsdb`（`BranchPredictor=0`）里没有 skid buffer 逻辑
（`g_no_branch_predictor` 分支），在 cyc 18 应该看到 `id_pc=0x00000100`
——`ecall` 之后直接进入处理程序。把两组波形的 `pc_id_i`
和 `ctrl_fsm_cs` 并排对齐，差异一眼可见。

## 6. 终端里的等价证据（不用波形）

```bash
# BranchPredictor=1：ecall(trap=1) 之后 pc=0xa0，处理程序 0x100 从未出现
./simv_bp +mem=prog_bp.hex +irq_start=0 +irq_len=0 +max_cycles=2000 -l b1.log
grep -E "^RVFI|^CYC" b1.log | sed -n '1,30p'

# BranchPredictor=0：ecall 之后进入 0x100
./simv    +mem=prog_bp.hex +irq_start=0 +irq_len=0 +max_cycles=2000 -l b0.log
grep -E "^RVFI" b0.log | sed -n '1,16p'
```

## 7. 另一个触发源：`mret`（不是异常）

`prog_mret.S` 用 `mret` 触发同一个窗口（`mret` 也走控制器的 `FLUSH` 状态，
`pc_mux = PC_ERET`，同样 `halt_if=1`）。程序里 `mret` 后面紧跟着一条后向
`blt`：

```bash
./simv    +mem=prog_mret.hex +max_cycles=2000 +wave=waves/mret_ok.fsdb    -l /dev/null
./simv_bp +mem=prog_mret.hex +max_cycles=2000 +wave=waves/mret_bug.fsdb   -l /dev/null
```

- BP=0：`mret`(0xa8) 跳到 mepc 目标 0x100，`R_MRET`(0x600)=1，`R_AFTER` 未写
- BP=1：`mret` 退休后执行的是 skid 里的 `blt`(0xac)，mispredict 把 PC 引到
  `blt` 自己的 fall-through，**`mret` 的返回地址完全没生效**：
  `R_MRET` 未写，`R_AFTER`(0x604)=0x1111

关注信号同上，窗口是 cyc 16–22。

## 8. 顶层端口故障注入（不需要软件配合）

`prog_err.S` 把触发源换成**唯一一个顶层端口** `instr_err_i`：对 `0x9c` 那次
取指注入一次错误响应（one-shot，模拟瞬态总线/ECC 故障）。软件里没有任何
异常指令。

```bash
./run.sh simv ; ./run.sh simv_bp +define+BP_ENABLE
./simv    +mem=prog_err.hex +instr_err_addr=156 +max_cycles=2000 +wave=waves/err_ok.fsdb
./simv_bp +mem=prog_err.hex +instr_err_addr=156 +max_cycles=2000 +wave=waves/err_bug.fsdb
```

`+instr_err_addr=<十进制地址>`；数据侧同理是 `+data_err_addr=`（load/store access fault）。

- BP=0：`0x9c` 取指故障 → `trap=1` → pc=0x100（handler），`R_HAN=1`
- BP=1：`trap=1` 之后 pc=0xa0（skid 里的陈旧分支），**handler 未执行**

关注信号同第 3 节，窗口 cyc 14–18。

## 9. U-mode：特权提升

`prog_u.S` 先用 MRET 降到 U-mode（`mstatus.MPP=0`），再对 `0xb8` 那次取指注入
顶层 `instr_err_i`。

```bash
./simv_bp +mem=prog_u.hex +instr_err_addr=184 +max_cycles=2000 +wave=waves/u_esc.fsdb
./simv    +mem=prog_u.hex +instr_err_addr=184 +max_cycles=2000 +wave=waves/u_ok.fsdb
```

关注信号：除第 3 节那组外，加

```tcl
add_wave {{tb_ibex_irq.dut.u_ibex_core.cs_registers_i.priv_lvl_q}}   ;# 3=M, 0=U
add_wave {{tb_ibex_irq.dut.u_ibex_core.cs_registers_i.mcause_q}}
```

窗口 cyc 24–35：

| cyc | BP=1（漏洞） | BP=0（正确） |
|---|---|---|
| 24 | `priv=0` (U) | `priv=0` (U) |
| 26 | pc=b8 `trap=1 mcause=1`，`priv=3` | 同左 |
| 29 | pc=bc（陈旧 blt），`priv=3` | handler 在 0x100 执行 |
| 31 | pc=c0 `csrr t2,mtvec` **成功**，rd=101 | `csrr` 触发非法指令异常 |

`priv_lvl_q` 从 0 跳到 3 而 PC 还停在 U-mode 地址段 —— 这就是逃逸瞬间。
