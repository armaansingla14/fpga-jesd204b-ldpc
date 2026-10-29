// tb_ldpc_dec.sv - feeds quantised LLR frames into ldpc_dec_array and logs
// the results (tag, iterations, converged flag, hard decisions) for the
// bit-exact comparison against the Python fixed-point model.
//   +IN=<file> (per frame: 128 two-digit hex LLRs, two's complement)
//   +OUT=<file> +N=<frames> +MAXITER=<n>; parameter NUM_DEC via -G
module tb_ldpc_dec #(parameter int NUM_DEC = 1);
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic in_valid = 0, in_ready, out_valid, out_ok;
  logic [7:0] in_tag = '0, out_tag;
  logic [128*6-1:0] in_llr = '0;
  logic [127:0] out_bits;
  logic [4:0] out_iters, max_iter = 5'd10;

  ldpc_dec_array #(.NUM_DEC(NUM_DEC), .TAGW(8), .ITW(5)) dut (
    .clk(clk), .rst_n(rst_n), .max_iter(max_iter),
    .in_valid(in_valid), .in_ready(in_ready), .in_tag(in_tag), .in_llr(in_llr),
    .out_valid(out_valid), .out_tag(out_tag), .out_bits(out_bits),
    .out_iters(out_iters), .out_ok(out_ok));

  string fin = "build/dec_in.hex", fout = "build/dec_out.txt";
  int n = 0, fi, fo, received = 0, cycles = 0, t_first = -1, t_last = 0;
  int unsigned mi = 10;

  always @(posedge clk) begin
    if (rst_n) cycles++;
    if (out_valid) begin
      // frame tag is 8 bits; the TB keeps the full index in the file order
      $fdisplay(fo, "%0d %0d %0d %032h", out_tag, out_iters, out_ok, out_bits);
      received++;
      t_last = cycles;
    end
  end

  initial begin
    logic [7:0] v;
    logic [128*6-1:0] frame;
    void'($value$plusargs("IN=%s", fin));
    void'($value$plusargs("OUT=%s", fout));
    void'($value$plusargs("N=%d", n));
    void'($value$plusargs("MAXITER=%d", mi));
    max_iter = 5'(mi);
    fi = $fopen(fin, "r");
    fo = $fopen(fout, "w");
    if (fi == 0 || fo == 0) begin $display("TB_ERROR cannot open files"); $finish; end
    repeat (2) @(negedge clk);
    rst_n = 1;
    for (int f = 0; f < n; f++) begin
      for (int i = 0; i < 128; i++) begin
        void'($fscanf(fi, "%h", v));
        frame[6*i +: 6] = v[5:0];
      end
      in_llr = frame;   // whole-vector write so the DUT inputs update
      in_tag = 8'(f);
      in_valid = 1;
      do @(posedge clk); while (!in_ready);
      if (t_first < 0) t_first = cycles;
      @(negedge clk);
      in_valid = 0;
    end
    while (received < n) @(negedge clk);
    $fclose(fo);
    $display("TB_RESULT tb_ldpc_dec frames=%0d received=%0d num_dec=%0d cycles=%0d",
             n, received, NUM_DEC, t_last);
    $finish;
  end
endmodule
