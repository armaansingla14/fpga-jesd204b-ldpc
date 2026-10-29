// tb_ldpc_enc.sv - streams messages from a hex file through ldpc_encoder and
// writes the codewords; scripts/run_sims.py compares them with the model.
//   +IN=<file> (one 64-bit hex message per line)  +OUT=<file>  +N=<frames>
module tb_ldpc_enc;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  logic in_valid = 0, out_valid;
  logic [63:0] msg = '0;
  logic [127:0] cw;

  ldpc_encoder dut (.clk(clk), .rst_n(rst_n), .in_valid(in_valid), .msg(msg),
                    .out_valid(out_valid), .cw(cw));

  string fin = "build/enc_in.hex", fout = "build/enc_out.hex";
  int n = 0, fi, fo, written = 0;
  logic [63:0] tmp;

  always @(posedge clk) if (out_valid) begin
    $fdisplay(fo, "%032h", cw);
    written++;
  end

  initial begin
    void'($value$plusargs("IN=%s", fin));
    void'($value$plusargs("OUT=%s", fout));
    void'($value$plusargs("N=%d", n));
    fi = $fopen(fin, "r");
    fo = $fopen(fout, "w");
    if (fi == 0 || fo == 0) begin $display("TB_ERROR cannot open files"); $finish; end
    repeat (2) @(negedge clk);
    rst_n = 1;
    for (int i = 0; i < n; i++) begin
      @(negedge clk);
      // read into a temporary first: Verilator does not re-evaluate
      // combinational logic for variables written by $fscanf
      void'($fscanf(fi, "%h", tmp));
      msg = tmp;
      in_valid = 1;
    end
    @(negedge clk);
    in_valid = 0;
    repeat (3) @(negedge clk);
    $fclose(fo);
    $display("TB_RESULT tb_ldpc_enc frames=%0d written=%0d", n, written);
    $finish;
  end
endmodule
