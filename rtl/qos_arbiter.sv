//==============================================================================
// File: qos_arbiter.sv
// Project: Cut-Through VOQ Switch
// Author: Samarth Gupta
// Date: 2026-05-29
//
// Description:
//   Per-egress-port QoS arbiter. Selects which ingress VOQ gets granted
//   access to the egress port each cycle. Uses strict priority (P3 first)
//   with round-robin tiebreaking among equal-priority requesters and an
//   anti-starvation timer to prevent P0 lockout under sustained P3 flood.
//
// Features:
//   - Strict priority arbitration (P3 > P2 > P1 > P0)
//   - Round-robin tiebreaking among equal-priority requesters
//   - Anti-starvation timer — port promoted to unconditional winner after
//     STARVATION_THRESHOLD cycles without a grant
//   - Multiple starved ports served within NUM_PORTS consecutive cycles
//   - Combinational winner selection in always_comb, state in always_ff
//   - Grant held for entire packet duration (no re-arbitration mid-packet)
//   - One-hot grant output
//==============================================================================

module qos_arbiter
  import switch_pkg::*;
#(
  parameter int NUM_PORTS            = switch_pkg::NUM_PORTS,
  parameter int STARVATION_THRESHOLD = 32
)(
  input  logic                    clk,
  input  logic                    rst_n,

  // VOQ status for this egress port
  input  logic [NUM_PORTS-1:0]    empty,
  input  priority_t               voq_priority [NUM_PORTS],
  input  logic [NUM_PORTS-1:0]    eop_in,

  // Grant output
  output logic [NUM_PORTS-1:0]    grant,
  output logic                    grant_valid
);

  // Internal signals 
  logic [$clog2(NUM_PORTS)-1:0]  last_granted;
  logic [$clog2(NUM_PORTS)-1:0]  granted_port;
  logic [5:0]                    starvation_cnt [NUM_PORTS];
  priority_t                     eff_priority   [NUM_PORTS];
  logic                          starved        [NUM_PORTS];

  typedef enum logic {
    ARB_IDLE    = 1'b0,
    ARB_GRANTED = 1'b1
  } arb_state_t;

  arb_state_t arb_state;

  // Combinational winner-finding intermediates
  logic                          found;
  logic [$clog2(NUM_PORTS)-1:0]  winner;
  priority_t                     best_pri;
  logic                          starved_found;
  logic [$clog2(NUM_PORTS)-1:0]  starved_winner;

  // Anti-starvation counter and effective priority 
  always_ff @(posedge clk or negedge rst_n) begin
    for (int i = 0; i < NUM_PORTS; i++) begin
      if (!rst_n) begin
        starvation_cnt[i] <= '0;
        eff_priority[i]   <= PRI_0;
        starved[i]        <= 1'b0;
      end else begin
        if (grant[i]) begin
          starvation_cnt[i] <= '0;
          eff_priority[i]   <= voq_priority[i];
          starved[i]        <= 1'b0;
        end else if (!empty[i]) begin
          if (starvation_cnt[i] < STARVATION_THRESHOLD)
            starvation_cnt[i] <= starvation_cnt[i] + 1;
          if (starvation_cnt[i] >= STARVATION_THRESHOLD - 1) begin
            eff_priority[i] <= PRI_3;
            starved[i]      <= 1'b1;
          end else begin
            eff_priority[i] <= voq_priority[i];
            starved[i]      <= 1'b0;
          end
        end else begin
          starvation_cnt[i] <= '0;
          eff_priority[i]   <= voq_priority[i];
          starved[i]        <= 1'b0;
        end
      end
    end
  end

  // Combinational winner selection 
  always_comb begin
    found          = 1'b0;
    winner         = '0;
    best_pri       = PRI_0;
    starved_found  = 1'b0;
    starved_winner = '0;

    // First pass — find starved port in round-robin order
    for (int k = 0; k < NUM_PORTS; k++) begin
      automatic int i = (last_granted + 1 + k) % NUM_PORTS;
      if (!empty[i] && starved[i] && !starved_found) begin
        starved_found  = 1'b1;
        starved_winner = i[$clog2(NUM_PORTS)-1:0];
      end
    end

    if (starved_found) begin
      winner = starved_winner;
      found  = 1'b1;
    end else begin
      // Normal strict priority + round-robin scan
      for (int k = 0; k < NUM_PORTS; k++) begin
        automatic int i = (last_granted + 1 + k) % NUM_PORTS;
        if (!empty[i]) begin
          if (!found || eff_priority[i] > best_pri) begin
            found    = 1'b1;
            winner   = i[$clog2(NUM_PORTS)-1:0];
            best_pri = eff_priority[i];
          end
        end
      end
    end
  end

  // Arbitration FSM 
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      grant        <= '0;
      grant_valid  <= 1'b0;
      last_granted <= '0;
      granted_port <= '0;
      arb_state    <= ARB_IDLE;
    end else begin
      case (arb_state)

        ARB_IDLE: begin
          grant       <= '0;
          grant_valid <= 1'b0;

          if (found) begin
            grant[winner] <= 1'b1;
            grant_valid   <= 1'b1;
            granted_port  <= winner;
            arb_state     <= ARB_GRANTED;
          end
        end

        ARB_GRANTED: begin
          if (eop_in[granted_port]) begin
            grant        <= '0;
            grant_valid  <= 1'b0;
            last_granted <= granted_port;
            arb_state    <= ARB_IDLE;
          end
        end

        default: arb_state <= ARB_IDLE;

      endcase
    end
  end

endmodule : qos_arbiter