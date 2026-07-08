//==============================================================================
// File: voq_buffer.sv
// Project: Cut-Through VOQ Switch
// Author: Samarth Gupta
// Date: 2026-05-27
//
// Description:
//   Virtual Output Queue (VOQ) buffer array. Stores incoming flits in the
//   correct FIFO based on ingress port and egress port determined by the
//   flow steering table. Prevents head-of-line blocking by maintaining
//   independent queues per {ingress, egress} pair.
//
// Features:
//   - NUM_PORTS x NUM_PORTS array of synchronous FIFOs (NUM_PORTS^2 total, one per {ingress,egress} pair)
//   - Explicit 3-state FSM per ingress port (IDLE, FORWARDING, DROPPING)
//   - DROP action support — payload flits discarded without VOQ write
//   - Oversized packet detection — drops packets exceeding MAX_PKT_FLITS
//   - VOQ overflow detection — drops packet cleanly when VOQ full mid-packet
//   - full/empty status per VOQ for arbiter and backpressure
//   - Parameterised depth (VOQ_DEPTH) and port count (NUM_PORTS)
//==============================================================================

module voq_buffer
  import switch_pkg::*;
#(
  parameter int NUM_PORTS     = switch_pkg::NUM_PORTS,
  parameter int FLIT_WIDTH    = switch_pkg::FLIT_WIDTH,
  parameter int DEPTH         = switch_pkg::VOQ_DEPTH,
  parameter int MAX_PKT_FLITS = switch_pkg::MAX_PKT_FLITS
)(
  input  logic                          clk,
  input  logic                          rst_n,

  // Per-ingress flit input
  input  logic [NUM_PORTS-1:0]          in_valid,
  input  logic [FLIT_WIDTH-1:0]         in_data    [NUM_PORTS],
  input  logic [NUM_PORTS-1:0]          in_sop,
  input  logic [NUM_PORTS-1:0]          in_eop,

  // Flow steering results
  input  logic [NUM_PORTS-1:0]          header_valid,
  input  logic [2:0]                    egress_port  [NUM_PORTS],
  input  action_t                       action       [NUM_PORTS],

  // Pop signals from cut-through controllers
  input  logic [NUM_PORTS-1:0]          pop          [NUM_PORTS],

  // VOQ outputs
  output logic [FLIT_WIDTH-1:0]         flit_out     [NUM_PORTS][NUM_PORTS],
  output logic [NUM_PORTS-1:0]          empty        [NUM_PORTS],
  output logic [NUM_PORTS-1:0]          full         [NUM_PORTS],

  // Error output
  output logic [NUM_PORTS-1:0]          pkt_error
);

  // FSM - combinational logic - for each ingress port
  typedef enum logic [1:0] {
    IDLE       = 2'd0,
    FORWARDING = 2'd1,
    DROPPING   = 2'd2
  } voq_state_t;

  voq_state_t                      state          [NUM_PORTS];
  logic [2:0]                      current_egress [NUM_PORTS];
  logic [$clog2(MAX_PKT_FLITS):0]  flit_count     [NUM_PORTS];

  always_ff @(posedge clk or negedge rst_n) begin
    for (int i = 0; i < NUM_PORTS; i++) begin
      if (!rst_n) begin
        state[i]          <= IDLE;
        current_egress[i] <= '0;
        flit_count[i]     <= '0;
        pkt_error[i]      <= 1'b0;
      end else begin
        case (state[i])

          IDLE: begin
            flit_count[i] <= '0;
            pkt_error[i]  <= 1'b0;
            if (header_valid[i]) begin
              current_egress[i] <= egress_port[i];
              if (action[i] == ACTION_DROP)
                state[i] <= DROPPING;
              else
                state[i] <= FORWARDING;
            end
          end

          FORWARDING: begin
            if (in_valid[i]) begin
              flit_count[i] <= flit_count[i] + 1;
              // Oversized packet — drops remaining flits
              if (flit_count[i] >= MAX_PKT_FLITS - 1) begin
                state[i]     <= DROPPING;
                pkt_error[i] <= 1'b1;
              end
              // VOQ overflow — drops packet cleanly rather than corrupting it
              if (full[i][current_egress[i]]) begin
                state[i]     <= DROPPING;
                pkt_error[i] <= 1'b1;
              end
            end
            if (in_valid[i] && in_eop[i]) begin
              state[i]      <= IDLE;
              flit_count[i] <= '0;
              pkt_error[i]  <= 1'b0;
            end
          end

          DROPPING: begin
            if (in_valid[i] && in_eop[i]) begin
              state[i]      <= IDLE;
              flit_count[i] <= '0;
              pkt_error[i]  <= 1'b0;
            end
          end

          default: state[i] <= IDLE;

        endcase
      end
    end
  end

  // FIFO storage 
  logic [FLIT_WIDTH-1:0]        mem    [NUM_PORTS][NUM_PORTS][DEPTH];
  logic [$clog2(DEPTH):0]       wr_ptr [NUM_PORTS][NUM_PORTS];
  logic [$clog2(DEPTH):0]       rd_ptr [NUM_PORTS][NUM_PORTS];

  genvar gi, gj;
  generate
    for (gi = 0; gi < NUM_PORTS; gi++) begin : gen_ingress
      for (gj = 0; gj < NUM_PORTS; gj++) begin : gen_egress
        assign empty[gi][gj]    = (wr_ptr[gi][gj] == rd_ptr[gi][gj]);
        assign full[gi][gj]     = ((wr_ptr[gi][gj] - rd_ptr[gi][gj]) == DEPTH[$clog2(DEPTH):0]);
        assign flit_out[gi][gj] = mem[gi][gj][rd_ptr[gi][gj][$clog2(DEPTH)-1:0]];
      end
    end
  endgenerate

  // Write logic 
  always_ff @(posedge clk or negedge rst_n) begin
    for (int i = 0; i < NUM_PORTS; i++) begin
      if (!rst_n) begin
        for (int j = 0; j < NUM_PORTS; j++)
          wr_ptr[i][j] <= '0;
      end else begin
        if (in_valid[i] && (state[i] == FORWARDING)) begin
          if (!full[i][current_egress[i]]) begin
            mem[i][current_egress[i]][wr_ptr[i][current_egress[i]][$clog2(DEPTH)-1:0]]
              <= in_data[i];
            wr_ptr[i][current_egress[i]]
              <= wr_ptr[i][current_egress[i]] + 1;
          end
        end
      end
    end
  end

  // Read logic 
  always_ff @(posedge clk or negedge rst_n) begin
    for (int i = 0; i < NUM_PORTS; i++) begin
      if (!rst_n) begin
        for (int j = 0; j < NUM_PORTS; j++)
          rd_ptr[i][j] <= '0;
      end else begin
        for (int j = 0; j < NUM_PORTS; j++) begin
          if (pop[i][j] && !empty[i][j])
            rd_ptr[i][j] <= rd_ptr[i][j] + 1;
        end
      end
    end
  end

endmodule : voq_buffer