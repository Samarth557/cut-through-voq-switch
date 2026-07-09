//==============================================================================
// File: switch_top.sv
// Project: Cut-Through VOQ Switch
// Author: Samarth Gupta
// Date: 2026-05-29
//
// Description:
//   Top-level integration of the cut-through VOQ switch. Instantiates and
//   wires all submodules. Contains no logic — purely structural.
//   Uses pre-sliced intermediate arrays for clean instantiation.
//
// Features:
//   - cfg_clk domain for TCAM programming, two-phase handshake CDC
//
// Submodules instantiated:
//   - header_parser      x8  (one per ingress port)
//   - flow_steering_table x8 (one per ingress port, shared TCAM write port)
//   - voq_buffer         x1  (shared 8x8 FIFO array)
//   - qos_arbiter        x8  (one per egress port)
//   - cut_through_ctrl   x8  (one per egress port)
//   - cdc_handshake_sync x1  (cfg->core TCAM write CDC)
//==============================================================================

module switch_top
  import switch_pkg::*;
#(
  parameter int NUM_PORTS  = switch_pkg::NUM_PORTS,
  parameter int FLIT_WIDTH = switch_pkg::FLIT_WIDTH
)(
  input  logic                                      clk,
  input  logic                                      rst_n,
  input  logic                                      cfg_clk,

  // Ingress interfaces
  packet_if.slave                                   ingress_if [NUM_PORTS],

  // Egress interfaces
  packet_if.master                                  egress_if  [NUM_PORTS],

  // Flow steering table write port — from RAL model
  input  logic                                      fst_wr_en,
  input  logic [$clog2(switch_pkg::TCAM_DEPTH)-1:0] fst_wr_addr,
  input  tcam_entry_t                               fst_wr_data,
  output logic                                      cfg_wr_ready,   // CDC backpressure to cfg side

  // Error outputs
  output logic [NUM_PORTS-1:0]                      pkt_error
);

  // Header parser outputs 
  logic        header_valid  [NUM_PORTS];
  pkt_header_t parsed_header [NUM_PORTS];

  // Flow steering outputs 
  logic [2:0]  fst_egress_port [NUM_PORTS];
  action_t     fst_action      [NUM_PORTS];

  // TCAM write port after CDC (core_clk domain)
  logic                                       core_wr_en;
  logic [$clog2(switch_pkg::TCAM_DEPTH)-1:0]  core_wr_addr;
  tcam_entry_t                                core_wr_data;

  // VOQ buffer outputs
  logic [FLIT_WIDTH-1:0]  flit_out  [NUM_PORTS][NUM_PORTS];
  logic [NUM_PORTS-1:0]   voq_empty [NUM_PORTS];
  logic [NUM_PORTS-1:0]   voq_full  [NUM_PORTS];

  // Arbiter outputs 
  logic [NUM_PORTS-1:0]   grant       [NUM_PORTS];
  logic                   grant_valid [NUM_PORTS];

  // Cut-through controller outputs 
  logic [NUM_PORTS-1:0]   pop          [NUM_PORTS];
  logic                   ct_out_tvalid[NUM_PORTS];
  logic [FLIT_WIDTH-1:0]  ct_out_tdata [NUM_PORTS];
  logic                   ct_out_sop   [NUM_PORTS];
  logic                   ct_out_tlast [NUM_PORTS];
  fwd_mode_t              fwd_mode     [NUM_PORTS];

  // Ingress interface wires
  logic [NUM_PORTS-1:0]   in_valid_w;
  logic [FLIT_WIDTH-1:0]  in_data_w  [NUM_PORTS];
  logic [NUM_PORTS-1:0]   in_sop_w;
  logic [NUM_PORTS-1:0]   in_eop_w;

  // Pre-sliced arrays for per-egress instantiation 
  // arb_empty[j][i]    = voq_empty[i][j]    — column j of empty array
  // arb_priority[j][i] = priority of VOQ[i][j] head flit
  // ct_flit_in[j][i]   = flit_out[i][j]     — column j of flit_out array
  // eop_to_arb[j][i]   = ct_out_tlast[j] && grant[j][i]
  logic [NUM_PORTS-1:0]   arb_empty    [NUM_PORTS];
  priority_t              arb_priority [NUM_PORTS][NUM_PORTS];
  logic [FLIT_WIDTH-1:0]  ct_flit_in   [NUM_PORTS][NUM_PORTS];
  logic [NUM_PORTS-1:0]   ct_empty     [NUM_PORTS];
  logic [NUM_PORTS-1:0]   eop_to_arb   [NUM_PORTS];

  genvar si, sj;
  generate
    for (si = 0; si < NUM_PORTS; si++) begin : gen_ingress_wires
      assign in_valid_w[si] = ingress_if[si].valid;
      assign in_data_w[si]  = ingress_if[si].data;
      assign in_sop_w[si]   = ingress_if[si].sop;
      assign in_eop_w[si]   = ingress_if[si].eop;
    end

    for (si = 0; si < NUM_PORTS; si++) begin : gen_slice_i
      for (sj = 0; sj < NUM_PORTS; sj++) begin : gen_slice_j
        // For egress port sj, ingress port si:
        assign arb_empty[sj][si]    = voq_empty[si][sj];
        assign arb_priority[sj][si] = priority_t'(flit_out[si][sj][55:54]);
        assign ct_flit_in[sj][si]   = flit_out[si][sj];
        assign ct_empty[sj][si]     = voq_empty[si][sj];
        // EOP to arbiter — high on granted port when EOP fires
        assign eop_to_arb[sj][si]   = ct_out_tlast[sj] && grant[sj][si];
      end
    end
  endgenerate

  // Header parsers 
  genvar hp;
  generate
    for (hp = 0; hp < NUM_PORTS; hp++) begin : gen_parser
      header_parser u_parser (
        .clk,
        .rst_n,
        .pkt_if        (ingress_if[hp]),
        .header_valid  (header_valid[hp]),
        .parsed_header (parsed_header[hp])
      );
    end
  endgenerate

  // Config-clock -> core-clock CDC for TCAM writes (two-phase toggle handshake)
  cdc_handshake_sync u_cdc_fst_wr (
    .cfg_clk        (cfg_clk),
    .core_clk       (clk),
    .rst_n          (rst_n),
    .cfg_req_valid  (fst_wr_en),
    .cfg_wr_addr    (fst_wr_addr),
    .cfg_wr_data    (fst_wr_data),
    .cfg_wr_ready   (cfg_wr_ready),
    .core_wr_en     (core_wr_en),
    .core_wr_addr   (core_wr_addr),
    .core_wr_data   (core_wr_data)
  );

  // Flow steering tables
  genvar fst;
  generate
    for (fst = 0; fst < NUM_PORTS; fst++) begin : gen_fst
      flow_steering_table u_fst (
        .clk,
        .rst_n,
        .lookup_valid  (header_valid[fst]),
        .dest_addr     (parsed_header[fst].dest_port),
        .pkt_priority  (parsed_header[fst].pkt_priority),
        .egress_port   (fst_egress_port[fst]),
        .action        (fst_action[fst]),
        .hit           (),
        .miss          (),
        .wr_en         (core_wr_en),
        .wr_addr       (core_wr_addr),
        .wr_data       (core_wr_data)
      );
    end
  endgenerate

  // VOQ buffer 
  voq_buffer u_voq (
    .clk,
    .rst_n,
    .in_valid      (in_valid_w),
    .in_data       (in_data_w),
    .in_sop        (in_sop_w),
    .in_eop        (in_eop_w),
    .header_valid  (header_valid),
    .egress_port   (fst_egress_port),
    .action        (fst_action),
    .pop           (pop),
    .flit_out      (flit_out),
    .empty         (voq_empty),
    .full          (voq_full),
    .pkt_error     (pkt_error)
  );

  // QoS arbiters
  genvar arb;
  generate
    for (arb = 0; arb < NUM_PORTS; arb++) begin : gen_arbiter
      qos_arbiter u_arb (
        .clk,
        .rst_n,
        .empty        (arb_empty[arb]),
        .voq_priority (arb_priority[arb]),
        .eop_in       (eop_to_arb[arb]),
        .grant        (grant[arb]),
        .grant_valid  (grant_valid[arb])
      );
    end
  endgenerate

  // Cut-through controllers 
  genvar ct;
  generate
    for (ct = 0; ct < NUM_PORTS; ct++) begin : gen_ct_ctrl
      cut_through_ctrl u_ct (
        .clk,
        .rst_n,
        .grant        (grant[ct]),
        .grant_valid  (grant_valid[ct]),
        .flit_in      (ct_flit_in[ct]),
        .empty        (ct_empty[ct]),
        .egress_ready (egress_if[ct].tready),
        .out_tvalid   (ct_out_tvalid[ct]),
        .out_tdata    (ct_out_tdata[ct]),
        .out_sop      (ct_out_sop[ct]),
        .out_tlast    (ct_out_tlast[ct]),
        .pop          (pop[ct]),
        .fwd_mode     (fwd_mode[ct])
      );

      // Connect to egress interface
      assign egress_if[ct].tvalid       = ct_out_tvalid[ct];
      assign egress_if[ct].tdata        = ct_out_tdata[ct];
      assign egress_if[ct].sop          = ct_out_sop[ct];
      assign egress_if[ct].tlast        = ct_out_tlast[ct];
      assign egress_if[ct].pkt_priority = PRI_0;
    end
  endgenerate

endmodule : switch_top