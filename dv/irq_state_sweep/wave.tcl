# Verdi nWave signal setup for the IF skid-buffer repro.
#   verdi -ssf waves/bp_bug.fsdb &   then in the TCL console:  source wave.tcl

add_wave_group "IF skid buffer"
add_wave {tb_ibex_irq.dut.u_ibex_core.if_stage_i.g_branch_predictor.instr_skid_valid_q}
add_wave {tb_ibex_irq.dut.u_ibex_core.if_stage_i.g_branch_predictor.instr_skid_addr_q}
add_wave {tb_ibex_irq.dut.u_ibex_core.if_stage_i.g_branch_predictor.instr_skid_data_q}
add_wave {tb_ibex_irq.dut.u_ibex_core.if_stage_i.g_branch_predictor.instr_skid_en}
add_wave_group "controller FSM"
add_wave {tb_ibex_irq.dut.u_ibex_core.id_stage_i.controller_i.ctrl_fsm_cs}
add_wave {tb_ibex_irq.dut.u_ibex_core.id_stage_i.controller_i.halt_if}
add_wave {tb_ibex_irq.dut.u_ibex_core.id_stage_i.controller_i.flush_id}
add_wave {tb_ibex_irq.dut.u_ibex_core.id_stage_i.controller_i.id_in_ready_o}
add_wave {tb_ibex_irq.dut.u_ibex_core.id_stage_i.controller_i.pc_set_o}
add_wave {tb_ibex_irq.dut.u_ibex_core.id_stage_i.controller_i.pc_mux_o}
add_wave {tb_ibex_irq.dut.u_ibex_core.id_stage_i.controller_i.exc_pc_mux_o}
add_wave_group "IF -> ID handover"
add_wave {tb_ibex_irq.dut.u_ibex_core.if_stage_i.if_id_pipe_reg_we}
add_wave {tb_ibex_irq.dut.u_ibex_core.if_stage_i.if_instr_valid}
add_wave {tb_ibex_irq.dut.u_ibex_core.if_stage_i.if_instr_addr}
add_wave_group "ID stage"
add_wave {tb_ibex_irq.dut.u_ibex_core.id_stage_i.instr_valid_i}
add_wave {tb_ibex_irq.dut.u_ibex_core.id_stage_i.pc_id_i}
add_wave {tb_ibex_irq.dut.u_ibex_core.if_stage_i.instr_rdata_id_o}
add_wave_group "architectural effect"
add_wave {tb_ibex_irq.dut.rvfi_valid}
add_wave {tb_ibex_irq.dut.rvfi_pc_rdata}
add_wave {tb_ibex_irq.dut.rvfi_intr}
add_wave {tb_ibex_irq.dut.rvfi_trap}
add_wave {tb_ibex_irq.dut.u_ibex_core.cs_registers_i.mepc_q}
