//==============================================================================
// File: cdc_handshake_sync.sv
// Project: Cut-Through VOQ Switch
// Author: Samarth Gupta
// Date: 2026-07-09
//
// Description:
//   Clock-domain-crossing (CDC) bridge for the TCAM / flow-steering write path.
//   Moves a single {addr, data} write from the slow config clock (cfg_clk)
//   into the core clock (core_clk) domain. Two-phase toggle handshake CDC.
//   Not four-phase — no return-to-zero step needed since this is a single
//   request/single ack transfer with the bus held stable throughout.
//
// Features:
//   - Two-phase toggle handshake — req and ack each TOGGLE on change (no
//     return-to-zero), one toggle per write transfer
//   - Wide {addr, data} bus is NEVER bit-synchronized — held stable in a
//     cfg-domain register and sampled by the core side after the req toggle
//   - Only the single-bit req and ack toggles cross domains, each through a
//     dedicated 2-FF synchronizer
//   - Edge-detected req produces exactly ONE core_wr_en pulse per write
//   - cfg_wr_ready backpressure — a new write is accepted only after the
//     previous transfer's ack returns
//   - Asynchronous active-low reset in both domains
//==============================================================================

module cdc_handshake_sync
  import switch_pkg::*;
#(
  parameter int ADDR_WIDTH = $clog2(TCAM_DEPTH)
)(
  input  logic                    cfg_clk,
  input  logic                    core_clk,
  input  logic                    rst_n,

  // cfg-side write request (cfg_clk domain)
  input  logic                    cfg_req_valid,
  input  logic [ADDR_WIDTH-1:0]   cfg_wr_addr,
  input  tcam_entry_t             cfg_wr_data,
  output logic                    cfg_wr_ready,

  // core-side write output (core_clk domain)
  output logic                    core_wr_en,
  output logic [ADDR_WIDTH-1:0]   core_wr_addr,
  output tcam_entry_t             core_wr_data
);

  // cfg_clk-domain state
  logic                  cfg_req_toggle;   // toggles once per accepted write
  logic                  cfg_busy;         // high while a transfer is in flight
  logic [ADDR_WIDTH-1:0] cfg_hold_addr;    // stable bus — sampled by core side
  tcam_entry_t           cfg_hold_data;
  logic                  ack_meta, ack_sync, ack_sync_q;  // ack toggle synced in

  // core_clk-domain state
  logic                  req_meta, req_sync, req_sync_q;  // req toggle synced in
  logic                  core_ack_toggle;  // toggles once per completed write

  // Ready to accept a new write whenever no transfer is outstanding
  assign cfg_wr_ready = !cfg_busy;

  // --- cfg_clk domain: request generation + held payload ---
  always_ff @(posedge cfg_clk or negedge rst_n) begin
    if (!rst_n) begin
      cfg_req_toggle <= 1'b0;
      cfg_busy       <= 1'b0;
      cfg_hold_addr  <= '0;
      cfg_hold_data  <= '0;
      ack_meta       <= 1'b0;
      ack_sync       <= 1'b0;
      ack_sync_q     <= 1'b0;
    end else begin
      // 2-FF synchronizer for the ack toggle from the core domain
      ack_meta   <= core_ack_toggle;
      ack_sync   <= ack_meta;
      ack_sync_q <= ack_sync;

      // Ack toggle edge → previous transfer complete, release busy
      if (ack_sync ^ ack_sync_q)
        cfg_busy <= 1'b0;

      // Accept a new write only when idle; latch the bus and toggle req
      if (cfg_req_valid && !cfg_busy) begin
        cfg_hold_addr  <= cfg_wr_addr;
        cfg_hold_data  <= cfg_wr_data;
        cfg_req_toggle <= ~cfg_req_toggle;
        cfg_busy       <= 1'b1;
      end
    end
  end

  // --- core_clk domain: request capture, one-cycle pulse, ack generation ---
  always_ff @(posedge core_clk or negedge rst_n) begin
    if (!rst_n) begin
      req_meta        <= 1'b0;
      req_sync        <= 1'b0;
      req_sync_q      <= 1'b0;
      core_ack_toggle <= 1'b0;
      core_wr_en      <= 1'b0;
      core_wr_addr    <= '0;
      core_wr_data    <= '0;
    end else begin
      // 2-FF synchronizer for the req toggle from the cfg domain
      req_meta   <= cfg_req_toggle;
      req_sync   <= req_meta;
      req_sync_q <= req_sync;

      // Default: no write pulse this cycle
      core_wr_en <= 1'b0;

      // Req toggle edge → sample the (stable) bus, emit one pulse, toggle ack
      if (req_sync ^ req_sync_q) begin
        core_wr_en      <= 1'b1;
        core_wr_addr    <= cfg_hold_addr;
        core_wr_data    <= cfg_hold_data;
        core_ack_toggle <= ~core_ack_toggle;
      end
    end
  end

endmodule : cdc_handshake_sync
