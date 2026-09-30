// Minimal reproducer: U-mode privilege escalation via a single top-level
// instruction-bus error response, when Ibex is built with BranchPredictor=1.
//
// Only two external things happen here:
//   1. one transient error response is driven on the top-level `instr_err_i`
//      port (`+fault_addr=<decimal>`, one-shot), and
//   2. the architectural results are dumped for comparison.
// Nothing inside the core is forced.
//
// See README.md for the expected observations.

`timescale 1ns/1ps

module tb_ibex_esc;

  import ibex_pkg::*;
  import ibex_cheriot_pkg::*;

  // ----------------------------------------------------------------- clock
  logic clk   = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  // ---------------------------------------------------------------- memory
  localparam int MEM_WORDS = 1 << 14;          // 64 KiB, 1-cycle latency
  logic [31:0] mem [0:MEM_WORDS-1];

  logic        instr_req, instr_gnt, instr_rvalid, instr_err;
  logic [31:0] instr_addr, instr_rdata;
  logic        data_req, data_gnt, data_rvalid, data_we, data_err;
  logic [3:0]  data_be;
  logic [31:0] data_addr, data_wdata, data_rdata;
  logic [6:0]  data_wdata_intg;

  logic        instr_rvalid_q, data_rvalid_q;
  logic [31:0] instr_rdata_q,  data_rdata_q;

  // ---- fault injection: ONE error response on the fetch of `fault_addr` ----
  logic [31:0] fault_addr = 32'hFFFF_FFFF;
  logic        instr_err_q;
  logic        injected = 1'b0;                // makes the fault transient

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      instr_rvalid_q <= 1'b0;
      instr_rdata_q  <= '0;
      instr_err_q    <= 1'b0;
    end else begin
      instr_rvalid_q <= instr_req & instr_gnt;
      if (instr_req & instr_gnt) begin
        instr_rdata_q <= mem[instr_addr[15:2]];
        instr_err_q   <= (instr_addr == fault_addr) & ~injected;
      end
    end
  end

  assign instr_gnt    = instr_req;
  assign instr_err    = instr_err_q;
  assign instr_rvalid = instr_rvalid_q;
  assign instr_rdata  = instr_rdata_q;

  always @(posedge clk) if (instr_err_q) injected <= 1'b1;
  always @(posedge clk) if (rst_n && instr_err_q)
    $display("FAULT injected on fetch, cyc=%0d", cycle_cnt);

  // ------------------------------------------------------------------ data
  logic data_err_q;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      data_rvalid_q <= 1'b0;
      data_rdata_q  <= '0;
      data_err_q    <= 1'b0;
    end else begin
      data_rvalid_q <= data_req & data_gnt;
      data_err_q    <= 1'b0;                   // no data-side faults in this repro
      if (data_req & data_gnt) begin
        if (data_we) begin
          for (int i = 0; i < 4; i++)
            if (data_be[i]) mem[data_addr[15:2]][8*i +: 8] <= data_wdata[8*i +: 8];
        end
        data_rdata_q <= mem[data_addr[15:2]];
      end
    end
  end

  assign data_gnt    = data_req;
  assign data_err    = data_err_q;
  assign data_rvalid = data_rvalid_q;
  assign data_rdata  = data_rdata_q;

  prim_ram_1p_pkg::ram_1p_cfg_req_t [IC_NUM_WAYS-1:0] ram_cfg_tag_req;
  prim_ram_1p_pkg::ram_1p_cfg_req_t [IC_NUM_WAYS-1:0] ram_cfg_data_req;
  prim_ram_1p_pkg::ram_1p_cfg_rsp_t [IC_NUM_WAYS-1:0] ram_cfg_tag_rsp;
  prim_ram_1p_pkg::ram_1p_cfg_rsp_t [IC_NUM_WAYS-1:0] ram_cfg_data_rsp;
  assign ram_cfg_tag_req  = '0;
  assign ram_cfg_data_req = '0;

  // ------------------------------------------------------------------- DUT
`ifdef BP_ENABLE
  localparam bit PREDICTOR = 1'b1;
`else
  localparam bit PREDICTOR = 1'b0;
`endif

  logic alert_minor, alert_major_internal, alert_major_bus;

  ibex_top #(
    .BaseIsa           (BaseIsaRV32IorCHERIoT),
    .RV32M             (RV32MFast),
    .RV32ZC            (RV32Zca),
    .RegFile           (RegFileFF),
    .BranchTargetALU   (1'b0),
    .WritebackStage    (1'b1),
    .BranchPredictor   (PREDICTOR),
    .ICache            (1'b0),
    .PMPEnable         (1'b0),
    .SecureIbex        (1'b0)
  ) dut (
    .clk_i                 (clk),
    .rst_ni                (rst_n),
    .test_en_i             (1'b0),
    .ram_cfg_icache_tag_i  (ram_cfg_tag_req),
    .ram_cfg_icache_tag_o  (ram_cfg_tag_rsp),
    .ram_cfg_icache_data_i (ram_cfg_data_req),
    .ram_cfg_icache_data_o (ram_cfg_data_rsp),
    .cheriot_enable_i      (IbexMuBiOff),
    .hart_id_i             (32'h0),
    .boot_addr_i           (32'h0),
    .trvk_heap_base_addr_i (32'h0),

    .instr_req_o           (instr_req),
    .instr_gnt_i           (instr_gnt),
    .instr_rvalid_i        (instr_rvalid),
    .instr_addr_o          (instr_addr),
    .instr_rdata_i         (instr_rdata),
    .instr_rdata_intg_i    (7'h0),
    .instr_err_i           (instr_err),

    .data_req_o            (data_req),
    .data_gnt_i            (data_gnt),
    .data_rvalid_i         (data_rvalid),
    .data_we_o             (data_we),
    .data_be_o             (data_be),
    .data_addr_o           (data_addr),
    .data_wdata_o          (data_wdata),
    .data_wdata_intg_o     (data_wdata_intg),
    .data_tag_o            (),
    .data_rdata_i          (data_rdata),
    .data_rdata_intg_i     (7'h0),
    .data_tag_i            (1'b0),
    .data_err_i            (data_err),

    .trvk_revbm_req_o      (),
    .trvk_revbm_gnt_i      (1'b0),
    .trvk_revbm_rvalid_i   (1'b0),
    .trvk_revbm_addr_o     (),
    .trvk_revbm_rdata_i    (32'h0),
    .trvk_revbm_rdata_intg_i(7'h0),
    .trvk_revbm_err_i      (1'b0),

    .irq_software_i        (1'b0),
    .irq_timer_i           (1'b0),
    .irq_external_i        (1'b0),
    .irq_fast_i            (15'h0),
    .irq_nm_i              (1'b0),

    .scramble_key_valid_i  (1'b0),
    .scramble_key_i        ('0),
    .scramble_nonce_i      ('0),
    .scramble_req_o        (),
    .debug_req_i           (1'b0),
    .crash_dump_o          (),
    .double_fault_seen_o   (),

    .fetch_enable_i        (IbexMuBiOn),
    .mcounteren_writable_i (IbexMuBiOff),
    .alert_minor_o         (alert_minor),
    .alert_major_internal_o(alert_major_internal),
    .alert_major_bus_o      (alert_major_bus),
    .core_sleep_o          (),
    .scan_rst_ni           (1'b1),
    .lockstep_cmp_en_o     ()
  );

  // --------------------------------------------------------------- tracing
  int unsigned cycle_cnt = 0;

  // Reproducible skid / controller timeline (only exists with the predictor).
  logic timeline_on = 1'b0;
`ifdef BP_ENABLE
  wire        tl_skid_v    = dut.u_ibex_core.if_stage_i.g_branch_predictor.instr_skid_valid_q;
  wire [31:0] tl_skid_addr = dut.u_ibex_core.if_stage_i.g_branch_predictor.instr_skid_addr_q;
  wire [3:0]  tl_ctrl      = dut.u_ibex_core.id_stage_i.controller_i.ctrl_fsm_cs;
  always @(posedge clk) if (rst_n && timeline_on)
    $display("CYC %0d ctrl=%0d skid_valid=%b skid_addr=%08x id_pc=%08x id_valid=%b",
             cycle_cnt, tl_ctrl, tl_skid_v, tl_skid_addr,
             dut.u_ibex_core.id_stage_i.pc_id_i, dut.u_ibex_core.id_stage_i.instr_valid_i);
`endif
  int unsigned trace_n   = 0;
  logic        trace_on  = 1'b0;
  string       dump_file = "dump.txt";
  string       mem_file  = "prog_u.hex";
  string       wave_file = "";

  // Architectural mode + cause, so the escalation is directly visible.
  always @(posedge clk) if (rst_n && dut.rvfi_valid && trace_on) begin
    $display("RVFI %0d cyc=%0d pc=%08x insn=%08x trap=%b rd=x%0d wd=%08x | priv=%0d mcause=%0d mstatus.mpp=%0d",
             trace_n, cycle_cnt, dut.rvfi_pc_rdata, dut.rvfi_insn, dut.rvfi_trap,
             dut.rvfi_rd_addr, dut.rvfi_rd_wdata,
             dut.u_ibex_core.cs_registers_i.priv_lvl_q,
             {26'b0, dut.u_ibex_core.cs_registers_i.mcause_q.lower_cause[4:0]} |
             {29'b0, dut.u_ibex_core.cs_registers_i.mcause_q.irq_int,
              dut.u_ibex_core.cs_registers_i.mcause_q.irq_ext, 1'b0} |
             {27'b0, dut.u_ibex_core.cs_registers_i.mcause_q.irq_int, 4'b0},
             dut.u_ibex_core.cs_registers_i.mstatus_q.mpp);
    trace_n <= trace_n + 1;
  end

  int fh;

  initial begin
    if (!$value$plusargs("mem=%s",   mem_file))  mem_file  = "prog_u.hex";
    if (!$value$plusargs("dump=%s",  dump_file)) dump_file = "dump.txt";
    void'($value$plusargs("fault_addr=%d", fault_addr));
    void'($value$plusargs("trace=%d",      trace_on));
    void'($value$plusargs("timeline=%d",   timeline_on));
    if (!$value$plusargs("wave=%s",  wave_file)) wave_file = "";

    for (int i = 0; i < MEM_WORDS; i++) mem[i] = 32'h00000013;   // NOP fill
    $readmemh(mem_file, mem);

    rst_n = 1'b0;
    repeat (10) @(posedge clk);
    rst_n = 1'b1;

    if (wave_file != "") begin
      $fsdbDumpfile(wave_file);
      $fsdbDumpvars(0, tb_ibex_esc);
      $fsdbDumpMDA();
    end
  end

  always @(posedge clk) begin
    if (rst_n) begin
      cycle_cnt <= cycle_cnt + 1;

      if (mem[16'h06F0 >> 2] == 32'hDEADBEEF) begin
        fh = $fopen(dump_file, "w");
        $fwrite(fh, "R_HAN  %08x   // 0x600: M-mode trap handler ran\n", mem[16'h0600 >> 2]);
        $fwrite(fh, "R_ESC  %08x   // 0x604: M-only CSR read succeeded -> escalated\n",
                mem[16'h0604 >> 2]);
        $fclose(fh);
        $display("DONE cycles=%0d  R_HAN=%08x R_ESC=%08x", cycle_cnt,
                 mem[16'h0600 >> 2], mem[16'h0604 >> 2]);
        $finish;
      end

      if (cycle_cnt > 20000) begin
        $display("TIMEOUT");
        $finish;
      end
    end
  end

endmodule
