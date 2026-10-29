// dec_8b10b.sv - 8b/10b decoder with code and disparity error detection.
//
// The 6b and 4b sub-blocks are decoded by matching against the encoder
// tables, then the result is re-encoded with the current running
// disparity. A match means a valid symbol; a match only with the opposite
// disparity is a disparity error; anything else is a code error. This
// classification is mirrored by jesdldpc/enc8b10b.py::decode.
module dec_8b10b (
  input  logic       clk,
  input  logic       rst_n,
  input  logic       en,
  input  logic [9:0] code,
  output logic [7:0] d,
  output logic       k,
  output logic       code_err,
  output logic       disp_err,
  output logic       rd
);
  import jesd_pkg::*;

  logic [5:0] six;
  logic [3:0] four;
  logic [4:0] x;
  logic [2:0] y;
  logic       is_k;
  logic [10:0] e_same, e_opp;
  logic [7:0] d_c;
  logic       ce_c, de_c, rd_c;

  assign six  = code[9:4];
  assign four = code[3:0];

  always_comb begin
    is_k = (six == 6'b001111) || (six == 6'b110000);
    x = 5'd28;
    if (!is_k) begin
      x = 5'd0;
      for (int i = 31; i >= 0; i--) begin
        if (six == six_m(5'(i)) || (six_flips(5'(i)) && six == ~six_m(5'(i)))) x = 5'(i);
      end
    end
    y = 3'd0;
    for (int j = 7; j >= 0; j--) begin
      if (is_k) begin
        // after 001111 the 4b part is taken from the RD+ column, after
        // 110000 from the RD- column (the two K columns overlap otherwise)
        if (four == ((six == 6'b001111) ? ~fourk_m(3'(j)) : fourk_m(3'(j)))) y = 3'(j);
      end else begin
        if (four == four_m(3'(j)) || (four_flips(3'(j)) && four == ~four_m(3'(j)))) y = 3'(j);
      end
    end
    if (!is_k && (four == 4'b0111 || four == 4'b1000)) y = 3'd7;   // alternate A7
    d_c    = {y, x};
    e_same = enc8b10b(d_c, is_k, rd);
    e_opp  = enc8b10b(d_c, is_k, !rd);
    ce_c = 1'b0;
    de_c = 1'b0;
    if (e_same[9:0] == code) begin
      rd_c = e_same[10];
    end else if (e_opp[9:0] == code) begin
      de_c = 1'b1;
      rd_c = e_opp[10];
    end else begin
      ce_c = 1'b1;
      rd_c = (ones6(six) + ones4(four) == 5) ? rd : (ones6(six) + ones4(four) > 5);
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd       <= 1'b0;
      d        <= 8'h00;
      k        <= 1'b0;
      code_err <= 1'b0;
      disp_err <= 1'b0;
    end else if (en) begin
      rd       <= rd_c;
      d        <= ce_c ? 8'h00 : d_c;
      k        <= ce_c ? 1'b0 : is_k;
      code_err <= ce_c;
      disp_err <= de_c;
    end
  end
endmodule
