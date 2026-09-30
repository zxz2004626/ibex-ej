// Directed interrupt-phase sweep testbench for Ibex.
//
// Drives a small program that performs DIV/REM/MUL/MULH and injects
// irq_external_i for a window of cycles, sweeping the injection phase across
// the whole window of a division. Dumps the architectural results so the
// caller can compare every sweep point against a no-interrupt golden run.
//
// Plusargs:
//   +mem=<hex file>   program image (word-addressed, from 0x0)
//   +dump=<file>      result dump
//   +irq_start=<n>    cycle at which irq_external_i is first asserted
//   +irq_len=<n>      number of cycles it stays asserted (0 = never)
//   +max_cycles=<n>   timeout

`timescale 1ns/1ps

module tb_ibex_irq;

  import ibex_pkg::*;
  import ibex_cheriot_pkg::*;

  // ---------------------------------------------------------------- clock/rst
  logic clk   = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  // ------------------------------------------------------------------- memory
  localparam int MEM_WORDS = 1 << 14;   // 64 KiB
  logic [31:0] mem [0:MEM_WORDS-1];

  // --------------------------------------------------------------------- DUT
  logic        instr_req, instr_gnt, instr_rvalid, instr_err;
  logic [31:0] instr_addr, instr_rdata;
  logic        data_req, data_gnt, data_rvalid, data_we, data_err;
  logic [3:0]  data_be;
  logic [31:0] data_addr, data_wdata, data_rdata;
  logic [6:0]  data_wdata_intg;
  logic        irq_external;

  logic        instr_rvalid_q;
  logic [31:0] instr_rdata_q;
  logic        data_rvalid_q;
  logic [31:0] data_rdata_q;

  assign instr_gnt = instr_req;
  assign instr_err = 1'b0;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      instr_rvalid_q <= 1'b0;
      instr_rdata_q  <= '0;
    end else begin
      instr_rvalid_q <= instr_req & instr_gnt;
      if (instr_req & instr_gnt) instr_rdata_q <= mem[instr_addr[15:2]];
    end
  end

  assign instr_rvalid = instr_rvalid_q;
  assign instr_rdata  = instr_rdata_q;

  assign data_gnt = data_req;
  assign data_err = 1'b0;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      data_rvalid_q <= 1'b0;
      data_rdata_q  <= '0;
    end else begin
      data_rvalid_q <= data_req & data_gnt;
      if (data_req & data_gnt) begin
        if (data_we) begin
          for (int i = 0; i < 4; i++) begin
            if (data_be[i]) mem[data_addr[15:2]][8*i +: 8] <= data_wdata[8*i +: 8];
          end
        end
        data_rdata_q <= mem[data_addr[15:2]];
      end
    end
  end

  assign data_rvalid = data_rvalid_q;
  assign data_rdata  = data_rdata_q;

  prim_ram_1p_pkg::ram_1p_cfg_req_t [IC_NUM_WAYS-1:0] ram_cfg_tag_req;
  prim_ram_1p_pkg::ram_1p_cfg_req_t [IC_NUM_WAYS-1:0] ram_cfg_data_req;
  prim_ram_1p_pkg::ram_1p_cfg_rsp_t [IC_NUM_WAYS-1:0] ram_cfg_tag_rsp;
  prim_ram_1p_pkg::ram_1p_cfg_rsp_t [IC_NUM_WAYS-1:0] ram_cfg_data_rsp;
  assign ram_cfg_tag_req  = '0;
  assign ram_cfg_data_req = '0;

  logic unused_ram_cfg;
  assign unused_ram_cfg = ^{ram_cfg_tag_rsp, ram_cfg_data_rsp};

  ibex_top #(
    .BaseIsa           (BaseIsaRV32IorCHERIoT),
    .PMPEnable         (1'b0),
    .RV32E             (1'b0),
    `ifdef RV32M_SINGLE
    .RV32M             (RV32MSingleCycle),
`elsif RV32M_SLOW
    .RV32M             (RV32MSlow),
`else
    .RV32M             (RV32MFast),
`endif
    .RV32B             (RV32BNone),
    .RV32ZC            (RV32Zca),
    .RegFile           (RegFileFF),
    .BranchTargetALU   (1'b0),
    `ifdef NO_WB
    .WritebackStage    (1'b0),
`else
    .WritebackStage    (1'b1),
`endif
    .ICache            (1'b0),
    .ICacheECC         (1'b0),
    .ICacheScramble    (1'b0),
    `ifdef BP_ENABLE
    .BranchPredictor   (1'b1),
`else
    .BranchPredictor   (1'b0),
`endif
    .DbgTriggerEn      (1'b0),
    .SecureIbex        (1'b0),
    .DummyInstructions (1'b0),
    .RegFileECC        (1'b0),
    .MemECC            (1'b0)
  ) dut (
    .clk_i                          (clk),
    .rst_ni                         (rst_n),
    .test_en_i                      (1'b0),
    .ram_cfg_icache_tag_i           (ram_cfg_tag_req),
    .ram_cfg_icache_tag_o           (ram_cfg_tag_rsp),
    .ram_cfg_icache_data_i          (ram_cfg_data_req),
    .ram_cfg_icache_data_o          (ram_cfg_data_rsp),
    .cheriot_enable_i               (ibex_pkg::IbexMuBiOff),
    .hart_id_i                      (32'h0),
    .boot_addr_i                    (32'h0),
    .trvk_heap_base_addr_i          (32'h0),

    .instr_req_o                    (instr_req),
    .instr_gnt_i                    (instr_gnt),
    .instr_rvalid_i                 (instr_rvalid),
    .instr_addr_o                   (instr_addr),
    .instr_rdata_i                  (instr_rdata),
    .instr_rdata_intg_i             (7'h0),
    .instr_err_i                    (instr_err),

    .data_req_o                     (data_req),
    .data_gnt_i                     (data_gnt),
    .data_rvalid_i                  (data_rvalid),
    .data_we_o                      (data_we),
    .data_be_o                      (data_be),
    .data_addr_o                    (data_addr),
    .data_wdata_o                   (data_wdata),
    .data_wdata_intg_o              (data_wdata_intg),
    .data_tag_o                     (),
    .data_rdata_i                   (data_rdata),
    .data_rdata_intg_i              (7'h0),
    .data_tag_i                     (1'b0),
    .data_err_i                     (data_err),

    .trvk_revbm_req_o               (),
    .trvk_revbm_gnt_i               (1'b0),
    .trvk_revbm_rvalid_i            (1'b0),
    .trvk_revbm_addr_o              (),
    .trvk_revbm_rdata_i             (32'h0),
    .trvk_revbm_rdata_intg_i        (7'h0),
    .trvk_revbm_err_i               (1'b0),

    .irq_software_i                 (1'b0),
    .irq_timer_i                    (1'b0),
    .irq_external_i                 (irq_external),
    .irq_fast_i                     (15'h0),
    .irq_nm_i                       (1'b0),

    .scramble_key_valid_i           (1'b0),
    .scramble_key_i                 ('0),
    .scramble_nonce_i               ('0),
    .scramble_req_o                 (),

    .debug_req_i                    (1'b0),
    .crash_dump_o                   (),
    .double_fault_seen_o            (),

    .fetch_enable_i                 (ibex_pkg::IbexMuBiOn),
    .mcounteren_writable_i          (ibex_pkg::IbexMuBiOff),
    .alert_minor_o                  (),
    .alert_major_internal_o         (),
    .alert_major_bus_o              (),
    .core_sleep_o                   (),
    .scan_rst_ni                    (1'b1),
    .lockstep_cmp_en_o              ()
  );

  // ------------------------------------------------------------------ control
  int unsigned cycle_cnt  = 0;
  int unsigned irq_start  = 32'hFFFFFFF0;
  int unsigned irq_len    = 0;
  int unsigned max_cycles = 20000;
  string       mem_file   = "prog.hex";
  string       dump_file  = "dump.txt";
  string       wave_file  = "";

  logic irq_taken_seen = 1'b0;
  int unsigned irq_mode = 0;   // 0 = window of irq_len cycles, 1 = hold until taken
  always @(posedge clk) if (rst_n && dut.rvfi_valid && dut.rvfi_intr) irq_taken_seen <= 1'b1;

  assign irq_external = (irq_len != 0) && (cycle_cnt >= irq_start) &&
                        ((irq_mode == 1) ? ~irq_taken_seen
                                         : (cycle_cnt < irq_start + irq_len));

  // Reserve the RVFI outputs so the tool does not warn, and log traps.
  logic rvfi_valid_q;
  always_ff @(posedge clk) rvfi_valid_q <= dut.rvfi_valid;

  // skid-buffer / trap observability (only exists when the predictor is built in)
`ifdef BP_ENABLE
  wire skid_v      = dut.u_ibex_core.if_stage_i.g_branch_predictor.instr_skid_valid_q;
  wire [31:0] skid_addr = dut.u_ibex_core.if_stage_i.g_branch_predictor.instr_skid_addr_q;
  wire [3:0] ctrl_cs = dut.u_ibex_core.id_stage_i.controller_i.ctrl_fsm_cs;
  always @(posedge clk) if (rst_n)
    $display("CYC %0d ctrl=%0d skid_valid=%b skid_addr=%08x id_pc=%08x id_valid=%b",
             cycle_cnt, ctrl_cs, skid_v, skid_addr,
             dut.u_ibex_core.id_stage_i.pc_id_i, dut.u_ibex_core.id_stage_i.instr_valid_i);
`endif

`ifdef WAVE_CHECK
  // compile-time check that every path documented in WAVE.md resolves
  wire c1  = dut.u_ibex_core.if_stage_i.g_branch_predictor.instr_skid_valid_q;
  wire [31:0] c2 = dut.u_ibex_core.if_stage_i.g_branch_predictor.instr_skid_addr_q;
  wire [31:0] c3 = dut.u_ibex_core.if_stage_i.g_branch_predictor.instr_skid_data_q;
  wire c4  = dut.u_ibex_core.if_stage_i.g_branch_predictor.instr_skid_en;
  wire [3:0] c5 = dut.u_ibex_core.id_stage_i.controller_i.ctrl_fsm_cs;
  wire c6  = dut.u_ibex_core.id_stage_i.controller_i.halt_if;
  wire c7  = dut.u_ibex_core.id_stage_i.controller_i.flush_id;
  wire c8  = dut.u_ibex_core.id_stage_i.controller_i.id_in_ready_o;
  wire c9  = dut.u_ibex_core.id_stage_i.controller_i.pc_set_o;
  wire [3:0] c10 = dut.u_ibex_core.id_stage_i.controller_i.pc_mux_o;
  wire [3:0] c11 = dut.u_ibex_core.id_stage_i.controller_i.exc_pc_mux_o;
  wire c12 = dut.u_ibex_core.if_stage_i.if_id_pipe_reg_we;
  wire c13 = dut.u_ibex_core.if_stage_i.if_instr_valid;
  wire [31:0] c14 = dut.u_ibex_core.if_stage_i.if_instr_addr;
  wire c15 = dut.u_ibex_core.id_stage_i.instr_valid_i;
  wire [31:0] c16 = dut.u_ibex_core.id_stage_i.pc_id_i;
  wire [31:0] c17 = dut.u_ibex_core.if_stage_i.instr_rdata_id_o;
  wire c18 = dut.rvfi_valid, c19 = dut.rvfi_intr, c20 = dut.rvfi_trap;
  wire [31:0] c21 = dut.rvfi_pc_rdata;
  wire [31:0] c22 = dut.u_ibex_core.cs_registers_i.mepc_q;
  wire unused_wave_check = ^{c1,c2,c3,c4,c5,c6,c7,c8,c9,c10,c11,c12,c13,c14,c15,c16,c17,c18,c19,c20,c21,c22};
`endif

  int unsigned trace_n = 0;
  always @(posedge clk) begin
    if (rst_n && dut.rvfi_valid) begin
      $display("RVFI %0d cyc=%0d pc=%08x insn=%08x intr=%b trap=%b rd=x%0d wd=%08x mtvec=%08x mepc=%08x",
               trace_n, cycle_cnt, dut.rvfi_pc_rdata, dut.rvfi_insn,
               dut.rvfi_intr, dut.rvfi_trap, dut.rvfi_rd_addr, dut.rvfi_rd_wdata,
               dut.u_ibex_core.cs_registers_i.mtvec_q,
               dut.u_ibex_core.cs_registers_i.mepc_q);
      trace_n <= trace_n + 1;
    end
  end

  // Log the divider FSM so we can see how far it got.
  logic verbose = 1'b0;
`ifdef RV32M_SLOW
  wire [2:0] fsm_state = dut.u_ibex_core.ex_block_i.gen_multdiv_slow.multdiv_i.md_state_q;
`else
  wire [2:0] fsm_state = dut.u_ibex_core.ex_block_i.gen_multdiv_fast.multdiv_i.md_state_q;
`endif
  always @(posedge clk) begin
    if (rst_n && verbose) begin
      $display("[%0t] cyc=%0d md=%0d div_en=%b mul_en=%b instr_valid=%b ",
               $time, cycle_cnt, fsm_state,
               dut.u_ibex_core.ex_block_i.div_en_i,
               dut.u_ibex_core.ex_block_i.mult_en_i,
               dut.u_ibex_core.id_stage_i.instr_valid_i);
    end
  end

  int fh;

  initial begin
    if (!$value$plusargs("mem=%s",       mem_file))   mem_file   = "prog.hex";
    if (!$value$plusargs("dump=%s",      dump_file))  dump_file  = "dump.txt";
    void'($value$plusargs("irq_start=%d", irq_start));
    void'($value$plusargs("irq_len=%d",   irq_len));
    void'($value$plusargs("max_cycles=%d",max_cycles));
    void'($value$plusargs("verbose=%d",    verbose));
    void'($value$plusargs("irq_mode=%d",   irq_mode));
    if (!$value$plusargs("wave=%s", wave_file)) wave_file = "";

    for (int i = 0; i < MEM_WORDS; i++) mem[i] = 32'h00000013; // NOP

    $readmemh(mem_file, mem);

    rst_n = 1'b0;
    repeat (10) @(posedge clk);
    rst_n = 1'b1;

    if (wave_file != "") begin
      $display("[tb] dumping waveform to %s", wave_file);
`ifdef NO_FSDB
      $dumpfile(wave_file);
      $dumpvars(0, tb_ibex_irq);
`else
      $fsdbDumpfile(wave_file);
      $fsdbDumpvars(0, tb_ibex_irq);
      $fsdbDumpMDA();
`endif
    end
  end

  always @(posedge clk) begin
    if (rst_n) begin
      cycle_cnt <= cycle_cnt + 1;

      // completion marker written by the program
      if (mem[16'h06F0 >> 2] == 32'hDEADBEEF) begin
        fh = $fopen(dump_file, "w");
        $fwrite(fh, "div1  %08x\n", mem[16'h0600 >> 2]);
        $fwrite(fh, "rem1  %08x\n", mem[16'h0604 >> 2]);
        $fwrite(fh, "hdiv  %08x\n", mem[16'h0608 >> 2]);
        $fwrite(fh, "hrem  %08x\n", mem[16'h060C >> 2]);
        $fwrite(fh, "mul   %08x\n", mem[16'h0610 >> 2]);
        $fwrite(fh, "mulh  %08x\n", mem[16'h0614 >> 2]);
        $fwrite(fh, "div2  %08x\n", mem[16'h0618 >> 2]);
        $fwrite(fh, "rem2  %08x\n", mem[16'h061C >> 2]);
        $fwrite(fh, "cycles %0d\n", cycle_cnt);
        $fclose(fh);
        $display("DONE irq_start=%0d cycles=%0d", irq_start, cycle_cnt);
        $finish;
      end

      if (cycle_cnt > max_cycles) begin
        $display("TIMEOUT irq_start=%0d", irq_start);
        $finish;
      end
    end
  end

endmodule
