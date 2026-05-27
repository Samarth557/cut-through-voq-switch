module header_parser  (

  input  logic                    clk,
  input  logic                    rst_n,
  packet_if.slave                 pkt_if,
  output logic                    header_valid,
  output switch_pkg::pkt_header_t parsed_header

);

import switch_pkg::*;

always_comb begin

  if (pkt_if.valid && pkt_if.sop) begin
    parsed_header.dest_port    = pkt_if.data[63:56];
    parsed_header.pkt_priority = priority_t'(pkt_if.data[55:54]);
    parsed_header.length       = pkt_if.data[31:16];

  end else begin
    parsed_header.dest_port    = '0;
    parsed_header.pkt_priority = PRI_0;
    parsed_header.length       = '0;
  end
end

always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n)
    header_valid <= 1'b0;
  else
    header_valid <= pkt_if.valid && pkt_if.sop;
end

endmodule : header_parser