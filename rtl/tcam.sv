//==============================================================================
// File: tcam.sv
// Project: Cut-Through VOQ Switch
// Author: Samarth Gupta
// Date: 2026-05-27
//
// Description:
//   Ternary Content Addressable Memory (TCAM) primitive for the flow
//   steering table. Stores 64 flow rules and performs parallel comparison
//   of the lookup key against all entries simultaneously in one cycle.
//
// Features:
//   - 64-entry storage (TCAM_DEPTH parameter)
//   - 10-bit match key: {dest_addr[7:0], pkt_priority[1:0]}
//   - Ternary matching — each bit can be 0, 1, or X (don't care) via mask
//   - Parallel compare — all 64 entries checked simultaneously
//   - match_vector output — one bit per entry, high if entry matched
//   - match_priority output — rule_priority per entry for priority encoder
//   - Read port — winning_index in, winning_egress_port and action out
//   - Runtime programmable via write port (wr_en, wr_addr, wr_data)
//   - Asynchronous active-low reset clears all entry valid bits
//==============================================================================

module tcam
  import switch_pkg::*; 
#(
    parameter int DEPTH     = TCAM_DEPTH, 
    parameter int KEY_WIDTH = MATCH_WIDTH
)(

  input  logic                      clk,
  input  logic                      rst_n,
  input  logic                      lookup_valid,
  input  logic [KEY_WIDTH-1:0]      lookup_key,
  input  logic                      wr_en,
  input  logic [$clog2(DEPTH)-1:0]  wr_addr,
  input  tcam_entry_t               wr_data,
  input  logic [$clog2(DEPTH)-1:0]  winning_index,
  output logic [1:0]                winning_egress_port,
  output action_t                   winning_action,
  output logic [DEPTH-1:0]          match_vector,
  output logic [3:0]                match_priority [DEPTH]
);

  tcam_entry_t entries [DEPTH];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < DEPTH; i++)
        entries[i] <= '0;
    end else if (wr_en) begin
      entries[wr_addr] <= wr_data;
    end
  end

  always_comb begin
    for (int i = 0; i < DEPTH; i++) begin
      if (lookup_valid && entries[i].valid &&
         ((lookup_key & entries[i].mask) == (entries[i].value & entries[i].mask))) begin
        match_vector[i]   = 1'b1;
        match_priority[i] = entries[i].rule_priority;
      end else begin
        match_vector[i]   = 1'b0;
        match_priority[i] = 4'd0;
      end
    end
  end

  assign winning_egress_port = entries[winning_index].egress_port;
  assign winning_action      = entries[winning_index].action;

endmodule : tcam