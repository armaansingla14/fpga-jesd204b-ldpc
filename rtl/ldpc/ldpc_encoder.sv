// ldpc_encoder.sv
// Rate-1/2 QC-LDPC encoder (n = 128, k = 64). The dual-diagonal parity
// structure turns encoding into an accumulation over block rows:
//   lambda_r = XOR_c rot(m_c, s_rc),  p_0 = lambda_0,  p_r = lambda_r ^ p_{r-1}
// One codeword per clock, one cycle of latency.
module ldpc_encoder (
  input  logic                 clk,
  input  logic                 rst_n,
  input  logic                 in_valid,
  input  logic [63:0]          msg,      // bit i = message bit i
  output logic                 out_valid,
  output logic [127:0]         cw        // systematic: cw[63:0] = msg
);
  `include "ldpc_code.svh"

  // out[r] = in[(r + s) mod Z]
  function automatic logic [Z-1:0] rot(input logic [Z-1:0] v, input int s);
    logic [Z-1:0] o;
    for (int r = 0; r < Z; r++) o[r] = v[(r + s) % Z];
    return o;
  endfunction

  logic [MB*Z-1:0] parity;

  always_comb begin
    logic [Z-1:0] acc, lam;
    acc = '0;
    for (int r = 0; r < MB; r++) begin
      lam = '0;
      for (int c = 0; c < KB; c++) begin
        if (BASE_INFO(r*KB + c) >= 0)
          lam = lam ^ rot(msg[c*Z +: Z], BASE_INFO(r*KB + c));
      end
      acc = acc ^ lam;
      parity[r*Z +: Z] = acc;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      out_valid <= 1'b0;
      cw        <= '0;
    end else begin
      out_valid <= in_valid;
      if (in_valid) cw <= {parity, msg};
    end
  end
endmodule
