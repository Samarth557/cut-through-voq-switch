//==============================================================================
// File: cut_through_ctrl.sv
// Project: Cut-Through VOQ Switch
// Author: Samarth Gupta
// Date: 2026-05-29
//
// Description:
//   Per-egress-port cut-through forwarding controller. Forwards flits from
//   the granted VOQ to the egress port. Uses cut-through mode when egress
//   is free, falling back to store-and-forward when busy. EOP is detected
//   using the length field from the header flit.
//
// Features:
//   - 4-state FSM: IDLE, CUT_THROUGH, STORE_FWD, DRAIN
//   - Cut-through mode — forwarding begins immediately after grant
//   - Store-and-forward fallback — buffers complete packet when egress busy
//   - Mid-packet fallback — switches to buffering if egress becomes busy
//   - Length-based EOP detection using header flit length field [31:16]
//   - Internal SF buffer (MAX_PKT_FLITS deep)
//   - pop output advances VOQ read pointer after each flit consumed
//   - fwd_mode output for latency monitor and coverage
//==============================================================================

module cut_through_ctrl
  import switch_pkg::*;
#(
  parameter int NUM_PORTS     = switch_pkg::NUM_PORTS,
  parameter int FLIT_WIDTH    = switch_pkg::FLIT_WIDTH,
  parameter int MAX_PKT_FLITS = switch_pkg::MAX_PKT_FLITS
)(
  input  logic                          clk,
  input  logic                          rst_n,

  // From QoS arbiter
  input  logic [NUM_PORTS-1:0]          grant,
  input  logic                          grant_valid,

  // From VOQ buffer
  input  logic [FLIT_WIDTH-1:0]         flit_in  [NUM_PORTS],
  input  logic [NUM_PORTS-1:0]          empty,

  // Egress backpressure
  input  logic                          egress_ready,

  // Egress output
  output logic                          out_tvalid,
  output logic [FLIT_WIDTH-1:0]         out_tdata,
  output logic                          out_sop,
  output logic                          out_tlast,

  // Pop signals to VOQ buffer
  output logic [NUM_PORTS-1:0]          pop,

  // Forwarding mode
  output fwd_mode_t                     fwd_mode
);

  // FSM states 
  typedef enum logic [1:0] {
    CT_IDLE        = 2'd0,
    CT_CUT_THROUGH = 2'd1,
    CT_STORE_FWD   = 2'd2,
    CT_DRAIN       = 2'd3
  } ct_state_t;

  ct_state_t                        ct_state;

  // Internal signals
  logic [$clog2(NUM_PORTS)-1:0]     granted_port;

  // Length-based EOP detection
  logic [15:0]                      pkt_length;
  logic [15:0]                      flit_count;

  // Combinational EOP and SOP indicators
  logic                             is_sop;
  logic                             is_eop;

  assign is_sop = (flit_count == 16'd0);
  assign is_eop = (pkt_length != 16'd0) && (flit_count == pkt_length);

  // Store-and-forward buffer
  logic [FLIT_WIDTH-1:0]            sf_buf   [MAX_PKT_FLITS];
  logic [$clog2(MAX_PKT_FLITS):0]   sf_wr_ptr;
  logic [$clog2(MAX_PKT_FLITS):0]   sf_rd_ptr;
  logic                             sf_empty;
  logic                             sf_last;

  assign sf_empty = (sf_wr_ptr == sf_rd_ptr);
  assign sf_last  = (sf_rd_ptr + 1 == sf_wr_ptr);

  // Current flit from granted VOQ
  logic [FLIT_WIDTH-1:0]            current_flit;
  logic                             current_valid;

  assign current_flit  = flit_in[granted_port];
  assign current_valid = grant_valid && !empty[granted_port];

  // FSM - combinational logic 
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ct_state     <= CT_IDLE;
      granted_port <= '0;
      pkt_length   <= '0;
      flit_count   <= '0;
      sf_wr_ptr    <= '0;
      sf_rd_ptr    <= '0;
      out_tvalid   <= 1'b0;
      out_tdata    <= '0;
      out_sop      <= 1'b0;
      out_tlast    <= 1'b0;
      pop          <= '0;
      fwd_mode     <= STORE_FWD;
    end else begin
      // Default deassert each cycle
      pop       <= '0;
      out_tvalid <= 1'b0;
      out_sop    <= 1'b0;
      out_tlast  <= 1'b0;

      case (ct_state)

        // IDLE 
        CT_IDLE: begin
          sf_wr_ptr  <= '0;
          sf_rd_ptr  <= '0;
          flit_count <= '0;
          pkt_length <= '0;

          if (grant_valid) begin
            // Decode one-hot grant to find granted port
            for (int i = 0; i < NUM_PORTS; i++)
              if (grant[i]) granted_port <= i[$clog2(NUM_PORTS)-1:0];

            if (egress_ready) begin
              ct_state <= CT_CUT_THROUGH;
              fwd_mode <= CUT_THROUGH;
            end else begin
              ct_state <= CT_STORE_FWD;
              fwd_mode <= STORE_FWD;
            end
          end
        end

        // CUT-THROUGH 
        CT_CUT_THROUGH: begin
          if (current_valid) begin
            if (egress_ready) begin
              // Forward flit directly to egress
              out_tvalid        <= 1'b1;
              out_tdata         <= current_flit;
              out_sop           <= is_sop;
              out_tlast         <= is_eop;
              pop[granted_port] <= 1'b1;

              // Extract length from header flit on SOP
              if (is_sop)
                pkt_length <= current_flit[31:16];

              flit_count <= flit_count + 1;

              if (is_eop) begin
                flit_count <= '0;
                pkt_length <= '0;
                ct_state   <= CT_IDLE;
              end

            end else begin
              // Egress became busy — buffer this flit and fall back
              sf_buf[sf_wr_ptr[$clog2(MAX_PKT_FLITS)-1:0]] <= current_flit;
              sf_wr_ptr         <= sf_wr_ptr + 1;
              pop[granted_port] <= 1'b1;
              flit_count        <= flit_count + 1;

              if (is_sop)
                pkt_length <= current_flit[31:16];

              ct_state <= CT_STORE_FWD;
              fwd_mode <= STORE_FWD;
            end
          end
        end

        // STORE AND FORWARD 
        CT_STORE_FWD: begin
          out_tvalid <= 1'b0;

          if (current_valid) begin
            sf_buf[sf_wr_ptr[$clog2(MAX_PKT_FLITS)-1:0]] <= current_flit;
            sf_wr_ptr         <= sf_wr_ptr + 1;
            pop[granted_port] <= 1'b1;
            flit_count        <= flit_count + 1;

            if (is_sop)
              pkt_length <= current_flit[31:16];

            if (is_eop)
              ct_state <= CT_DRAIN;
          end
        end

        // DRAIN 
        CT_DRAIN: begin
          if (egress_ready && !sf_empty) begin
            out_tvalid <= 1'b1;
            out_tdata  <= sf_buf[sf_rd_ptr[$clog2(MAX_PKT_FLITS)-1:0]];
            out_sop    <= (sf_rd_ptr == '0);
            out_tlast  <= sf_last;
            sf_rd_ptr <= sf_rd_ptr + 1;

            if (sf_last) begin
              flit_count <= '0;
              pkt_length <= '0;
              ct_state   <= CT_IDLE;
            end
          end
        end

        default: ct_state <= CT_IDLE;

      endcase
    end
  end

endmodule : cut_through_ctrl
