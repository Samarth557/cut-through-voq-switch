module flow_steering_table
  import switch_pkg::*;
#(parameter int DEPTH     = TCAM_DEPTH, parameter int KEY_WIDTH = MATCH_WIDTH)
  (
  input  logic                      clk,
  input  logic                      rst_n,
  // Lookup port
  input  logic                      lookup_valid,
  input  logic [7:0]                dest_addr,
  input  switch_pkg::priority_t     pkt_priority,
  // Write port
  input  logic                      wr_en,
  input  logic [$clog2(DEPTH)-1:0]  wr_addr,
  input  tcam_entry_t               wr_data
  
  output logic [1:0]                egress_port,
  output action_t                   action,
  output logic                      hit,
  output logic                      miss,
);

  // Internal signals
  logic [KEY_WIDTH-1:0]        lookup_key;
  logic [DEPTH-1:0]            match_vector;
  logic [3:0]                  match_priority [DEPTH];
  logic [$clog2(DEPTH)-1:0]    winning_index;
  logic                        match_found;

  // Form lookup key from dest_addr and pkt_priority
  assign lookup_key = {dest_addr, pkt_priority};

  // Instantiate TCAM
  tcam #(.DEPTH(DEPTH), .KEY_WIDTH(KEY_WIDTH)) u_tcam (
    .clk,
    .rst_n,
    .lookup_valid,
    .lookup_key,
    .wr_en,
    .wr_addr,
    .wr_data,
    .winning_index,
    .winning_egress_port  (egress_port),
    .winning_action       (action),
    .match_vector,
    .match_priority
  );

  // Instantiate priority encoder
  priority_encoder #(.DEPTH(DEPTH)) u_penc (
    .match_vector,
    .match_priority,
    .winning_index,
    .match_found
  );


  assign hit  = lookup_valid && match_found;
  assign miss = lookup_valid && !match_found;

endmodule : flow_steering_table