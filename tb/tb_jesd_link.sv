// tb_jesd_link.sv - JESD204B TX -> serial channel -> RX loopback.
//
// The channel serialises each lane's 10-bit symbols and delays them by a
// seed-dependent number of bits (0..MAXDLY), so every lane arrives with a
// different bit offset and a different octet skew. The test then checks:
//   1. link bring-up: CGS on all lanes, ILAS structure/config, lane
//      alignment (all lanes deliver their first data in the same cycle)
//   2. N_DATA cycles of random user data, compared octet for octet
//   3. a single-bit error: detected by the 8b/10b decoder, link stays up,
//      data is correct again afterwards
//   4. a burst error on one lane: loss of code group sync, SYNC~ re-request,
//      full re-initialisation, data checked again
// It also dumps lane 0's TX octet/symbol stream for the bit-exact check
// against the Python model (scripts/run_sims.py).
//   +SEED=<n> +NDATA=<n> +DUMP=<file> +TXDATA=<file>
module tb_jesd_link #(
  parameter int L = 2,
  parameter bit SCR = 1'b1,
  parameter int F = 2,
  parameter int K = 16
);
  localparam int MAXDLY = 10 * 12 + 9;    // up to 12 symbols + 9 bits of skew
  localparam int W = MAXDLY + 10;

  logic clk = 0, rst_n = 0;
  always #4 clk = ~clk;

  logic [8*L-1:0]  tx_data;
  logic            tx_ready, sync_n, rx_valid, aligned, ilas_ok;
  logic [10*L-1:0] tx_sym, rx_sym;
  logic [8*L-1:0]  rx_data, dbg_octet;
  logic [L-1:0]    dbg_k, lane_sync;
  logic [1:0]      dbg_state;
  logic [15:0]     err_count, align_err_count;
  logic [L*4-1:0]  lane_offset;
  logic [L*6-1:0]  lane_depth;

  jesd_tx #(.L(L), .F(F), .K(K), .SCR(SCR)) u_tx (
    .clk(clk), .rst_n(rst_n), .sync_n(sync_n), .tx_data(tx_data), .tx_ready(tx_ready),
    .tx_sym(tx_sym), .dbg_octet(dbg_octet), .dbg_k(dbg_k), .dbg_state(dbg_state));

  jesd_rx #(.L(L), .F(F), .K(K), .SCR(SCR), .BUF_AW(5)) u_rx (
    .clk(clk), .rst_n(rst_n), .rx_sym(rx_sym), .sync_n(sync_n), .rx_data(rx_data),
    .rx_valid(rx_valid), .lane_sync(lane_sync), .aligned(aligned), .ilas_ok(ilas_ok),
    .err_count(err_count), .align_err_count(align_err_count),
    .lane_offset(lane_offset), .lane_depth(lane_depth));

  // ------------------------------------------------------------- channel
  logic [W-1:0] sr [L];
  int           dly [L];
  logic [9:0]   inj_mask [L];
  logic         inj_zero [L];    // force the lane to 10'b0 (not a valid code)

  always_ff @(posedge clk) begin
    for (int ln = 0; ln < L; ln++) sr[ln] <= {sr[ln][W-11:0], tx_sym[10*ln +: 10]};
  end
  always_comb begin
    for (int ln = 0; ln < L; ln++)
      rx_sym[10*ln +: 10] = inj_zero[ln] ? 10'h000 : (sr[ln][dly[ln] +: 10] ^ inj_mask[ln]);
  end

  // ------------------------------------------------- stimulus and checks
  int unsigned lcg = 1;
  function automatic int unsigned rnd();
    lcg = lcg * 1664525 + 1013904223;
    return lcg >> 8;
  endfunction

  logic [8*L-1:0] q [$];
  int  checking = 0;         // compare RX data only while set
  int  compared = 0, mismatches = 0, skipped = 0;
  int  first_rx_cycle = -1, cycle = 0;
  int  fdump = 0, ftx = 0;
  logic [8*L-1:0] next_data;

  // data source: new random word whenever the transmitter accepts one
  always_ff @(posedge clk) begin
    cycle <= cycle + 1;
    if (tx_ready) begin
      q.push_back(tx_data);
      if (ftx != 0) $fdisplay(ftx, "%0h", tx_data[7:0]);
    end
    if (!tx_ready && q.size() > 0 && dbg_state != 2'd3) q.delete();
    if (rx_valid) begin
      if (first_rx_cycle < 0) first_rx_cycle = cycle;
      if (q.size() == 0) begin
        if (checking) mismatches++;
      end else begin
        logic [8*L-1:0] exp;
        exp = q.pop_front();
        if (checking) begin
          compared++;
          if (exp !== rx_data) begin
            mismatches++;
            if (mismatches <= 5) $display("DATA MISMATCH cycle %0d: got %h exp %h", cycle, rx_data, exp);
          end
        end else skipped++;
      end
    end
    if (fdump != 0 && rst_n) $fdisplay(fdump, "%0d %0d %0d", dbg_k[0], dbg_octet[7:0], tx_sym[9:0]);
  end

  always_ff @(posedge clk) begin
    if (tx_ready) begin
      logic [8*L-1:0] v;
      for (int ln = 0; ln < L; ln++) v[8*ln +: 8] = 8'(rnd());
      tx_data <= v;
    end
  end

  task automatic wait_link(output int cycles_taken, input int limit);
    int c0;
    c0 = cycle;
    while (!(aligned && rx_valid) && cycle - c0 < limit) @(posedge clk);
    cycles_taken = cycle - c0;
  endtask

  initial begin
    int unsigned seed = 1;
    int n_data = 2000, t_link = 0, t_relink = 0, e0, sync_drops = 0;
    bit pass_link, pass_ilas, err_detected, stayed_up, relinked;
    string dump = "", txf = "";
    int mm_before;
    void'($value$plusargs("SEED=%d", seed));
    void'($value$plusargs("NDATA=%d", n_data));
    void'($value$plusargs("DUMP=%s", dump));
    void'($value$plusargs("TXDATA=%s", txf));
    lcg = seed * 7919 + 17;
    for (int ln = 0; ln < L; ln++) begin
      dly[ln] = int'(rnd() % (MAXDLY + 1));
      inj_mask[ln] = '0;
      inj_zero[ln] = 1'b0;
      sr[ln] = '0;
    end
    tx_data = '0;
    if (dump != "") fdump = $fopen(dump, "w");
    if (txf != "") ftx = $fopen(txf, "w");
    repeat (3) @(posedge clk);
    rst_n = 1;

    // 1. bring-up
    wait_link(t_link, 5000);
    pass_link = aligned && rx_valid;
    pass_ilas = ilas_ok;

    // 2. data
    checking = 1;
    repeat (n_data) @(posedge clk);
    if (fdump != 0) begin $fclose(fdump); fdump = 0; end
    if (ftx != 0) begin $fclose(ftx); ftx = 0; end

    // 3. single-bit error on lane 0
    e0 = err_count;
    mm_before = mismatches;
    checking = 0;
    @(negedge clk);
    inj_mask[0] = 10'b0000100000;
    @(negedge clk);
    inj_mask[0] = '0;
    repeat (40) @(posedge clk);
    err_detected = err_count > e0;
    stayed_up = &lane_sync && aligned;
    checking = 1;
    repeat (n_data / 2) @(posedge clk);

    // 4. burst of invalid characters on the last lane: the lane loses code
    //    group sync, SYNC~ is asserted and the link re-initialises
    checking = 0;
    @(negedge clk);
    for (int i = 0; i < 12; i++) begin
      inj_zero[L-1] = 1'b1;
      @(negedge clk);
    end
    inj_zero[L-1] = 1'b0;
    sync_drops = (sync_n == 0) ? 1 : 0;
    repeat (4) @(posedge clk);
    if (sync_n == 0) sync_drops = 1;
    wait_link(t_relink, 5000);
    relinked = aligned && rx_valid;
    checking = 1;
    repeat (n_data / 2) @(posedge clk);
    checking = 0;

    $display("TB_RESULT tb_jesd_link L=%0d SCR=%0d seed=%0d link=%0d ilas_ok=%0d link_cycles=%0d compared=%0d mismatches=%0d err_detected=%0d stayed_up=%0d sync_dropped=%0d relinked=%0d relink_cycles=%0d align_errs=%0d",
             L, SCR, seed, pass_link, pass_ilas, t_link, compared, mismatches, err_detected,
             stayed_up, sync_drops, relinked, t_relink, align_err_count);
    for (int ln = 0; ln < L; ln++)
      $display("LANE %0d delay_bits=%0d offset=%0d depth=%0d", ln, dly[ln],
               lane_offset[4*ln +: 4], lane_depth[6*ln +: 6]);
    $finish;
  end

  initial begin
    #4ms;
    $display("TB_RESULT tb_jesd_link TIMEOUT");
    $finish;
  end
endmodule
