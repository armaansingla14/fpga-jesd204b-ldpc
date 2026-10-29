// enc_8b10b.sv - registered 8b/10b encoder with running disparity.
module enc_8b10b (
  input  logic       clk,
  input  logic       rst_n,
  input  logic       en,
  input  logic [7:0] d,
  input  logic       k,          // 1: K28.y control character
  output logic [9:0] code,
  output logic       rd          // running disparity after 'code' (1 = RD+)
);
  import jesd_pkg::*;
  logic [10:0] r;
  assign r = enc8b10b(d, k, rd);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd   <= 1'b0;                // start at RD-
      code <= 10'h0;
    end else if (en) begin
      code <= r[9:0];
      rd   <= r[10];
    end
  end
endmodule

// Combinational view of the encoder (explicit RD in/out), used by the
// exhaustive table testbench.
module enc_8b10b_comb (
  input  logic [7:0] d,
  input  logic       k,
  input  logic       rd_in,
  output logic [9:0] code,
  output logic       rd_out
);
  import jesd_pkg::*;
  logic [10:0] r;
  assign r = enc8b10b(d, k, rd_in);
  assign code = r[9:0];
  assign rd_out = r[10];
endmodule
