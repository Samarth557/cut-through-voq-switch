module priority_encoder
  import switch_pkg::*;
#(
  parameter int DEPTH = TCAM_DEPTH
)(
  input  logic [DEPTH-1:0]         match_vector,
  input  logic [3:0]               match_priority [DEPTH],
  output logic [$clog2(DEPTH)-1:0] winning_index,
  output logic                     match_found
);

  always_comb begin
    winning_index = '0;
    match_found   = 1'b0;

    for (int i = 0; i < DEPTH; i++) begin
      if (match_vector[i]) begin
        if (!match_found || match_priority[i] > match_priority[winning_index]) begin
          winning_index = i[$clog2(DEPTH)-1:0];
          match_found   = 1'b1;
        end
      end
    end
  end

endmodule : priority_encoder
