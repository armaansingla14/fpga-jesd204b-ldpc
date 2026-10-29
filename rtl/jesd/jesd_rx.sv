// jesd_rx.sv - JESD204B receive link layer, L lanes.
//
// Per lane: comma alignment -> 8b/10b decode -> code group sync FSM
// (4 good /K/ to synchronise, 4 consecutive bad characters to drop) ->
// elastic buffer that starts filling at the first /R/ of the ILAS.
// Lane alignment: all buffers are released in the same cycle once every
// lane has started, which removes lane-to-lane skew. The aligned stream is
// checked against the ILAS structure and configuration, then control
// characters are replaced back, the data is descrambled and frame /
// multiframe alignment characters are monitored.
module jesd_rx #(
  parameter int L   = 2,
  parameter int F   = 2,
  parameter int K   = 16,
  parameter bit SCR = 1'b1,
  parameter int BUF_AW = 5
) (
  input  logic            clk,
  input  logic            rst_n,
  input  logic [10*L-1:0] rx_sym,
  output logic            sync_n,
  output logic [8*L-1:0]  rx_data,
  output logic            rx_valid,
  // status
  output logic [L-1:0]    lane_sync,
  output logic            aligned,          // ILAS seen and checked
  output logic            ilas_ok,          // structure + config + FCHK valid
  output logic [15:0]     err_count,        // cycles with a code/disparity error (link up)
  output logic [15:0]     align_err_count,  // cycles with a misplaced /A/ or /F/ or other K
  output logic [L*4-1:0]  lane_offset,      // comma alignment bit offsets
  output logic [L*(BUF_AW+1)-1:0] lane_depth // buffer fill at release (skew)
);
  import jesd_pkg::*;
  localparam int MF = F * K;
  localparam int PW = $clog2(MF);

  logic [L-1:0] started, started_q;
  logic [L-1:0] ce, de, kk;
  logic [7:0]   oct    [L];
  logic         release_q;
  logic         link_up;

  assign link_up = &lane_sync;

  // ---------------------------------------------------------------- lanes
  logic [8:0] buf_out [L];  // {k, octet}

  for (genvar ln = 0; ln < L; ln++) begin : g_lane
    logic [9:0] aligned_sym;
    logic [2:0] good_k, bad;
    logic [8:0] mem [2**BUF_AW];
    logic [BUF_AW-1:0] wp, rp;
    logic [BUF_AW:0]   cnt;
    logic       wr;

    comma_align u_align (.clk(clk), .rst_n(rst_n), .search(!lane_sync[ln]),
                         .din(rx_sym[10*ln +: 10]), .dout(aligned_sym),
                         .locked(), .offset(lane_offset[4*ln +: 4]));

    dec_8b10b u_dec (.clk(clk), .rst_n(rst_n), .en(1'b1), .code(aligned_sym),
                     .d(oct[ln]), .k(kk[ln]), .code_err(ce[ln]), .disp_err(de[ln]), .rd());

    // code group synchronisation
    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
        lane_sync[ln] <= 1'b0;
        good_k <= '0;
        bad    <= '0;
      end else if (!lane_sync[ln]) begin
        if (kk[ln] && oct[ln] == K_K && !ce[ln] && !de[ln]) begin
          good_k <= good_k + 1'b1;
          if (good_k == 3'd3) begin
            lane_sync[ln] <= 1'b1;
            bad <= '0;
          end
        end else begin
          good_k <= '0;
        end
      end else begin
        if (ce[ln] || de[ln]) begin
          bad <= bad + 1'b1;
          if (bad == 3'd3) begin
            lane_sync[ln] <= 1'b0;
            good_k <= '0;
          end
        end else begin
          bad <= '0;
        end
      end
    end

    // elastic buffer: starts at the first non-/K/ character after sync
    assign wr = link_up && (started[ln] || !(kk[ln] && oct[ln] == K_K));

    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
        started[ln] <= 1'b0;
        wp  <= '0;
        rp  <= '0;
        cnt <= '0;
      end else if (!link_up) begin
        started[ln] <= 1'b0;
        wp  <= '0;
        rp  <= '0;
        cnt <= '0;
      end else begin
        if (wr) begin
          started[ln] <= 1'b1;
          mem[wp] <= {kk[ln], oct[ln]};
          wp <= wp + 1'b1;
        end
        if (release_q) rp <= rp + 1'b1;
        cnt <= cnt + (BUF_AW+1)'(wr) - (BUF_AW+1)'(release_q);
      end
    end

    assign buf_out[ln]   = mem[rp];

    always_ff @(posedge clk) begin
      if (!release_q && (&started) && !(&started_q)) lane_depth[ln*(BUF_AW+1) +: BUF_AW+1] <= cnt;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) started_q <= '0;
    else        started_q <= started;
  end

  // release all lanes together once every lane holds data
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)             release_q <= 1'b0;
    else if (!link_up)      release_q <= 1'b0;
    else if (&started)      release_q <= 1'b1;
  end

  // --------------------------------------------- aligned stream processing
  logic [PW-1:0] pos;
  logic [2:0]    mf;          // 0..3 ILAS multiframes, 4 = data
  logic [L-1:0]  ilas_bad;
  logic [7:0]    cfg_sum [L];
  logic [14:0]   dsc_st  [L];
  logic [7:0]    prev_last [L];
  logic          end_frame, end_mf;

  assign end_frame = (int'(pos) % F) == F - 1;
  assign end_mf    = int'(pos) == MF - 1;

  // expected configuration octets (must match the transmitter parameters)
  function automatic logic [7:0] exp_cfg(input int idx, input int lane);
    case (idx)
      2:  return 8'(lane);
      3:  return {SCR, 2'b00, 5'(L - 1)};
      4:  return 8'(F - 1);
      5:  return 8'(K - 1);
      default: return 8'h00;
    endcase
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pos <= '0;
      mf  <= '0;
      aligned  <= 1'b0;
      ilas_ok  <= 1'b0;
      ilas_bad <= '0;
      rx_valid <= 1'b0;
      rx_data  <= '0;
      err_count <= '0;
      align_err_count <= '0;
      sync_n <= 1'b0;
      for (int ln = 0; ln < L; ln++) begin
        cfg_sum[ln]   <= '0;
        dsc_st[ln]    <= '0;
        prev_last[ln] <= '0;
      end
    end else begin
      sync_n   <= link_up;
      rx_valid <= 1'b0;
      if (!link_up || !release_q) begin
        pos <= '0;
        mf  <= '0;
        aligned  <= 1'b0;
        ilas_bad <= '0;
        for (int ln = 0; ln < L; ln++) begin
          cfg_sum[ln] <= '0;
          dsc_st[ln]  <= '0;
        end
      end else begin
        pos <= end_mf ? '0 : pos + 1'b1;
        if (end_mf && mf != 3'd4) mf <= mf + 1'b1;
        if (mf == 3'd3 && end_mf) begin
          aligned <= 1'b1;
          ilas_ok <= ~|ilas_bad;
        end
        for (int ln = 0; ln < L; ln++) begin
          logic        k_i;
          logic [7:0]  o_i;
          logic [7:0]  s_i;
          logic [22:0] ds;
          k_i = buf_out[ln][8];
          o_i = buf_out[ln][7:0];
          if (mf < 3'd4) begin
            // ILAS structure and configuration checks
            if (pos == '0 && !(k_i && o_i == K_R)) ilas_bad[ln] <= 1'b1;
            if (end_mf && !(k_i && o_i == K_A))    ilas_bad[ln] <= 1'b1;
            if (mf == 3'd1 && pos == 1 && !(k_i && o_i == K_Q)) ilas_bad[ln] <= 1'b1;
            if (mf == 3'd1 && int'(pos) >= 2 && int'(pos) < 15) begin
              cfg_sum[ln] <= cfg_sum[ln] + o_i;
              if (int'(pos) >= 4 && int'(pos) <= 7 &&
                  o_i != exp_cfg(int'(pos) - 2, ln)) ilas_bad[ln] <= 1'b1;
            end
            if (mf == 3'd1 && pos == 15 && o_i != cfg_sum[ln]) ilas_bad[ln] <= 1'b1;
          end else begin
            // data phase: undo character replacement, then descramble
            s_i = o_i;
            if (k_i) begin
              if (!((o_i == K_A && end_mf) || (o_i == K_F && end_frame)))
                align_err_count <= align_err_count + 1'b1;
              if (SCR) s_i = (o_i == K_A) ? 8'h7C : 8'hFC;
              else     s_i = prev_last[ln];
            end
            if (SCR) begin
              ds = descramble(s_i, dsc_st[ln]);
              dsc_st[ln] <= ds[22:8];
              rx_data[8*ln +: 8] <= ds[7:0];
              if (end_frame) prev_last[ln] <= ds[7:0];
            end else begin
              rx_data[8*ln +: 8] <= s_i;
              if (end_frame) prev_last[ln] <= s_i;
            end
            rx_valid <= 1'b1;
          end
        end
      end
      // count decoder errors once the link is up
      if (link_up && release_q)
        for (int ln = 0; ln < L; ln++)
          if (ce[ln] || de[ln]) err_count <= err_count + 1'b1;
    end
  end
endmodule
