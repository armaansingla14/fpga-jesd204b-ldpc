// ldpc_decoder.sv
// Layered offset min-sum decoder for the rate-1/2 QC-LDPC code.
//
// Fixed point (bit-exact with jesdldpc/ldpc.py::decode_fixed):
//   channel LLR 6 bits, posterior L 8 bits (saturated to +-127),
//   check messages R 6 bits (magnitude <= 31), offset 1 LSB.
//
// Schedule per layer (block row) with Z rows in parallel:
//   phase 1, one cycle per non-zero block k:  Q = sat(rot(L_c, s) - R_e),
//            track min1 / min2 / argmin / sign parity per row
//   phase 2, one cycle per non-zero block k:  R_e = new message,
//            L_c = rot^-1(sat(Q + R_e))
// After all layers the syndrome of the hard decisions is checked; decoding
// stops when it is zero or after max_iter iterations.
module ldpc_decoder #(
  parameter int ITW = 5            // iteration counter width
) (
  input  logic               clk,
  input  logic               rst_n,
  input  logic [ITW-1:0]     max_iter,
  // input frame: 128 LLRs x 6 bits, LLR i at bits [6*i +: 6]
  input  logic               in_valid,
  output logic               in_ready,
  input  logic [128*6-1:0]   in_llr,
  // output
  output logic               out_valid,
  input  logic               out_ready,
  output logic [127:0]       out_bits,
  output logic [ITW-1:0]     out_iters,
  output logic               out_ok,
  output logic [15:0]        out_cycles
);
  `include "ldpc_code.svh"

  localparam int N = NB * Z;
  localparam int OFFSET = 1;
  localparam int MSG_MAX = 31;
  localparam int APP_MAX = 127;
  localparam int KW = $clog2(MAXDEG + 1);

  typedef enum logic [2:0] {S_IDLE, S_P1, S_P2, S_CHECK, S_DONE} state_t;
  state_t state;

  logic signed [7:0] L  [N];
  logic signed [5:0] R  [NE*Z];
  logic signed [7:0] Qb [MAXDEG*Z];
  logic [6:0]        min1 [Z];
  logic [7:0]        min2 [Z];
  logic [KW-1:0]     amin [Z];
  logic              par  [Z];

  logic [1:0]        layer;
  logic [KW-1:0]     k;
  logic [ITW-1:0]    iter;
  logic [15:0]       cyc;

  int e_cur, col_cur, sh_cur, deg_cur;
  always_comb begin
    deg_cur = ROW_DEG(int'(layer));
    e_cur   = ROW_START(int'(layer)) + int'(k);
    col_cur = E_COL(e_cur);
    sh_cur  = E_SHIFT(e_cur);
  end

  function automatic logic signed [7:0] sat8(input int v);
    if (v > APP_MAX) return 8'sd127;
    if (v < -APP_MAX) return -8'sd127;
    return v[7:0];
  endfunction

  // phase-1 datapath: Q values for the current block
  logic signed [7:0] q_cur [Z];
  always_comb begin
    for (int r = 0; r < Z; r++)
      q_cur[r] = sat8(int'(L[col_cur*Z + (r + sh_cur) % Z]) - int'(R[e_cur*Z + r]));
  end

  // phase-2 datapath: new check messages and posteriors
  logic signed [5:0] r_new [Z];
  logic signed [7:0] l_new [Z];
  always_comb begin
    for (int r = 0; r < Z; r++) begin
      int m;
      logic neg;
      m = (amin[r] == k) ? int'(min2[r]) : int'(min1[r]);
      m = (m > OFFSET) ? m - OFFSET : 0;
      if (m > MSG_MAX) m = MSG_MAX;
      neg = par[r] ^ Qb[int'(k)*Z + r][7];
      r_new[r] = neg ? -6'(m) : 6'(m);
      l_new[r] = sat8(int'(Qb[int'(k)*Z + r]) + int'(r_new[r]));
    end
  end

  // syndrome of the hard decisions
  logic synd_zero;
  always_comb begin
    logic [MB*Z-1:0] s;
    s = '0;
    for (int e = 0; e < NE; e++) begin
      int row;
      row = 0;
      for (int rr = 0; rr < MB; rr++) if (e >= ROW_START(rr)) row = rr;
      for (int r = 0; r < Z; r++)
        s[row*Z + r] = s[row*Z + r] ^ L[E_COL(e)*Z + (r + E_SHIFT(e)) % Z][7];
    end
    synd_zero = (s == '0);
  end

  // sign-extended channel LLRs for the load cycle
  logic signed [7:0] l_load [N];
  always_comb begin
    for (int i = 0; i < N; i++) l_load[i] = 8'(signed'(in_llr[6*i +: 6]));
  end

  assign in_ready = (state == S_IDLE);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state     <= S_IDLE;
      out_valid <= 1'b0;
      layer     <= '0;
      k         <= '0;
      iter      <= '0;
      cyc       <= '0;
      out_bits  <= '0;
      out_iters <= '0;
      out_ok    <= 1'b0;
      out_cycles <= '0;
    end else begin
      if (state != S_IDLE && state != S_DONE) cyc <= cyc + 1'b1;
      case (state)
        S_IDLE: begin
          if (in_valid) begin
            L <= l_load;
            R <= '{default: '0};
            layer <= '0;
            k     <= '0;
            iter  <= 1;
            cyc   <= '0;
            state <= S_P1;
          end
        end

        S_P1: begin
          for (int r = 0; r < Z; r++) begin
            logic [6:0] mag;
            mag = q_cur[r][7] ? 7'(-q_cur[r]) : 7'(q_cur[r]);
            Qb[int'(k)*Z + r] <= q_cur[r];
            if (k == 0) begin
              min1[r] <= mag;
              min2[r] <= 8'd255;
              amin[r] <= '0;
              par[r]  <= q_cur[r][7];
            end else begin
              if (mag < min1[r]) begin
                min2[r] <= {1'b0, min1[r]};
                min1[r] <= mag;
                amin[r] <= k;
              end else if ({1'b0, mag} < min2[r]) begin
                min2[r] <= {1'b0, mag};
              end
              par[r] <= par[r] ^ q_cur[r][7];
            end
          end
          if (int'(k) == deg_cur - 1) begin
            k     <= '0;
            state <= S_P2;
          end else begin
            k <= k + 1'b1;
          end
        end

        S_P2: begin
          for (int r = 0; r < Z; r++) begin
            R[e_cur*Z + r] <= r_new[r];
            L[col_cur*Z + (r + sh_cur) % Z] <= l_new[r];
          end
          if (int'(k) == deg_cur - 1) begin
            k <= '0;
            if (layer == 2'(MB - 1)) begin
              layer <= '0;
              state <= S_CHECK;
            end else begin
              layer <= layer + 1'b1;
              state <= S_P1;
            end
          end else begin
            k <= k + 1'b1;
          end
        end

        S_CHECK: begin
          if (synd_zero || iter >= max_iter) begin
            for (int i = 0; i < N; i++) out_bits[i] <= L[i][7];
            out_iters  <= iter;
            out_ok     <= synd_zero;
            out_cycles <= cyc + 1'b1;
            out_valid  <= 1'b1;
            state      <= S_DONE;
          end else begin
            iter  <= iter + 1'b1;
            state <= S_P1;
          end
        end

        S_DONE: begin
          if (out_ready) begin
            out_valid <= 1'b0;
            state     <= S_IDLE;
          end
        end

        default: state <= S_IDLE;
      endcase
    end
  end
endmodule
