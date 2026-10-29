// tb_8b10b.sv - 8b/10b verification.
//  1. Exhaustive encoder table (256 D + 8 K28.y, both RDs)        -> +ENC file
//  2. Exhaustive decoder classification (1024 codes, both RDs)     -> +DEC file
//     (files are compared with jesdldpc/enc8b10b.py by scripts/run_sims.py)
//  3. Random encoder -> decoder loopback, self-checked here, including the
//     maximum run length of the serial stream.
module tb_8b10b;
  import jesd_pkg::*;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  // loopback pair
  logic [7:0] d = 0, dd;
  logic       k = 0, kd, ce, de;
  logic [9:0] code;
  enc_8b10b u_enc (.clk(clk), .rst_n(rst_n), .en(1'b1), .d(d), .k(k), .code(code), .rd());
  dec_8b10b u_dec (.clk(clk), .rst_n(rst_n), .en(1'b1), .code(code), .d(dd), .k(kd),
                   .code_err(ce), .disp_err(de), .rd());

  // stand-alone decoder for the classification table
  logic       rst2_n = 0;
  logic [9:0] tcode = 0;
  logic [7:0] td;
  logic       tk, tce, tde, trd;
  dec_8b10b u_dec2 (.clk(clk), .rst_n(rst2_n), .en(1'b1), .code(tcode), .d(td), .k(tk),
                    .code_err(tce), .disp_err(tde), .rd(trd));

  // combinational encoder for the table dump (calling the package function
  // directly from this initial block crashed Verilator 5.020)
  logic [7:0] ed = 0;
  logic       ek = 0, erd = 0, erd_o;
  logic [9:0] ecode;
  enc_8b10b_comb u_encc (.d(ed), .k(ek), .rd_in(erd), .code(ecode), .rd_out(erd_o));

  string fenc = "build/tb8b10b_enc.txt", fdec = "build/tb8b10b_dec.txt";
  int fe, fd;
  int n_loop = 100000, checked = 0, errors = 0, maxrun = 0, run = 0;
  logic lastbit = 0;
  logic [8:0] hist [4];   // {k, d} pipeline history

  initial begin
    void'($value$plusargs("ENC=%s", fenc));
    void'($value$plusargs("DEC=%s", fdec));
    void'($value$plusargs("N=%d", n_loop));
    fe = $fopen(fenc, "w");
    fd = $fopen(fdec, "w");
    for (int rd = 0; rd < 2; rd++) begin
      for (int b = 0; b < 264; b++) begin
        ek  = (b >= 256);
        ed  = ek ? 8'(8'h1C | ((b - 256) << 5)) : 8'(b);
        erd = rd[0];
        #1;
        $fdisplay(fe, "%0d %0d %0d %0d %0d", rd, ek, ed, ecode, erd_o);
      end
    end
    $fclose(fe);

    for (int rd = 0; rd < 2; rd++) begin
      for (int c = 0; c < 1024; c++) begin
        rst2_n = 0;
        @(negedge clk);
        rst2_n = 1;                       // decoder starts at RD-
        if (rd == 1) begin
          tcode = 10'b0011111010;         // K28.5 RD- moves it to RD+
          @(negedge clk);
        end
        tcode = 10'(c);
        @(negedge clk);
        $fdisplay(fd, "%0d %0d %0d %0d %0d %0d %0d", rd, c, td, tk, tce, tde, trd);
      end
    end
    $fclose(fd);

    // random loopback: a value driven before falling edge i is encoded at
    // the next rising edge and decoded at the one after, so it is visible
    // at the decoder output after falling edge i+1
    @(negedge clk);
    rst_n = 1;
    for (int i = 0; i <= n_loop; i++) begin
      hist[2] = hist[1];
      hist[1] = hist[0];
      if (i < n_loop) begin
        if ($urandom_range(0, 15) == 0) begin
          d = 8'h1C | 8'($urandom_range(0, 7) << 5);
          k = 1'b1;
        end else begin
          d = 8'($urandom_range(0, 255));
          k = 1'b0;
        end
      end
      hist[0] = {k, d};
      @(negedge clk);
      if (i >= 1 && i <= n_loop) begin
        checked++;
        if ({kd, dd} != hist[1] || ce || de) begin
          errors++;
          if (errors < 5) $display("loopback mismatch at %0d: got k=%0d d=%02h exp %03h ce=%0d de=%0d",
                                   i, kd, dd, hist[1], ce, de);
        end
      end
      // run length of the transmitted bit stream (code is the word sent
      // in this cycle)
      for (int b = 9; b >= 0; b--) begin
        if (code[b] == lastbit) run++;
        else run = 1;
        lastbit = code[b];
        if (run > maxrun && i > 2) maxrun = run;
      end
    end
    $display("TB_RESULT tb_8b10b loopback_checked=%0d errors=%0d max_run=%0d",
             checked, errors, maxrun);
    $finish;
  end
endmodule
