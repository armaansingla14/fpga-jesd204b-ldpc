// ldpc_dec_array.sv
// NUM_DEC decoder cores behind a dispatcher. A frame is accepted when any
// core is idle; results leave through a round-robin output arbiter tagged
// with the frame id, so they may complete out of order. NUM_DEC is the
// "LDPC parallelism" knob of the build sweep.
module ldpc_dec_array #(
  parameter int NUM_DEC = 2,
  parameter int TAGW    = 8,
  parameter int ITW     = 5
) (
  input  logic               clk,
  input  logic               rst_n,
  input  logic [ITW-1:0]     max_iter,
  input  logic               in_valid,
  output logic               in_ready,
  input  logic [TAGW-1:0]    in_tag,
  input  logic [128*6-1:0]   in_llr,
  output logic               out_valid,
  output logic [TAGW-1:0]    out_tag,
  output logic [127:0]       out_bits,
  output logic [ITW-1:0]     out_iters,
  output logic               out_ok
);
  logic [NUM_DEC-1:0] c_in_ready, c_in_valid, c_out_valid, c_out_ready, c_ok;
  logic [127:0]       c_bits  [NUM_DEC];
  logic [ITW-1:0]     c_iters [NUM_DEC];
  logic [TAGW-1:0]    c_tag   [NUM_DEC];
  logic [$clog2(NUM_DEC+1)-1:0] rr;

  // dispatch to the lowest-index idle core
  always_comb begin
    c_in_valid = '0;
    in_ready   = |c_in_ready;
    for (int i = NUM_DEC - 1; i >= 0; i--) begin
      if (c_in_ready[i]) c_in_valid = in_valid ? (NUM_DEC'(1) << i) : '0;
    end
  end

  for (genvar i = 0; i < NUM_DEC; i++) begin : g_core
    ldpc_decoder #(.ITW(ITW)) u_dec (
      .clk(clk), .rst_n(rst_n), .max_iter(max_iter),
      .in_valid(c_in_valid[i]), .in_ready(c_in_ready[i]), .in_llr(in_llr),
      .out_valid(c_out_valid[i]), .out_ready(c_out_ready[i]),
      .out_bits(c_bits[i]), .out_iters(c_iters[i]), .out_ok(c_ok[i]),
      .out_cycles());
    always_ff @(posedge clk) if (c_in_valid[i]) c_tag[i] <= in_tag;
  end

  // round-robin output selection, one result per cycle
  int sel;
  always_comb begin
    sel = -1;
    for (int j = 0; j < NUM_DEC; j++) begin
      int idx;
      idx = (int'(rr) + j) % NUM_DEC;
      if (sel < 0 && c_out_valid[idx]) sel = idx;
    end
    c_out_ready = '0;
    if (sel >= 0) c_out_ready[sel] = 1'b1;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rr        <= '0;
      out_valid <= 1'b0;
      out_tag   <= '0;
      out_bits  <= '0;
      out_iters <= '0;
      out_ok    <= 1'b0;
    end else begin
      out_valid <= (sel >= 0);
      if (sel >= 0) begin
        out_tag   <= c_tag[sel];
        out_bits  <= c_bits[sel];
        out_iters <= c_iters[sel];
        out_ok    <= c_ok[sel];
        rr        <= ($clog2(NUM_DEC+1))'((sel + 1) % NUM_DEC);
      end
    end
  end
endmodule
