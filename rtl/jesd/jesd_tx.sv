// jesd_tx.sv - JESD204B transmit link layer, L lanes, one octet per lane
// per character clock.
//
//  * CGS : /K/ on every lane while SYNC~ is low
//  * ILAS: starts at the next LMFC boundary after SYNC~ goes high; four
//          multiframes /R/ ... /A/, the second with /Q/ + 14 config octets
//  * DATA: user octets, optionally scrambled (1 + x^14 + x^15), with /F/ and
//          /A/ character replacement at frame / multiframe ends
// Losing SYNC~ (low) at any time returns the link to CGS.
module jesd_tx #(
  parameter int L   = 2,
  parameter int F   = 2,
  parameter int K   = 16,
  parameter bit SCR = 1'b1,
  parameter logic [7:0] DID = 8'h5A,
  parameter logic [3:0] BID = 4'h3,
  parameter int M  = 2,
  parameter int NBITS = 14,
  parameter int NP = 16
) (
  input  logic           clk,
  input  logic           rst_n,
  input  logic           sync_n,
  // user data, accepted when tx_ready
  input  logic [8*L-1:0] tx_data,
  output logic           tx_ready,
  // to transceivers
  output logic [10*L-1:0] tx_sym,
  // debug view of the pre-8b/10b stream
  output logic [8*L-1:0] dbg_octet,
  output logic [L-1:0]   dbg_k,
  output logic [1:0]     dbg_state
);
  import jesd_pkg::*;
  localparam int MF = F * K;
  localparam int PW = $clog2(MF);

  typedef enum logic [1:0] {CGS, WAIT_LMFC, ILAS, DATA} st_t;
  st_t state;
  logic [PW-1:0] lmfc;          // octet position in the multiframe
  logic [1:0]    ilas_mf;
  logic          sync_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      lmfc    <= '0;
      state   <= CGS;
      ilas_mf <= '0;
      sync_q  <= 1'b0;
    end else begin
      sync_q <= sync_n;
      lmfc   <= (int'(lmfc) == MF - 1) ? '0 : lmfc + 1'b1;
      if (!sync_q) begin
        state <= CGS;
      end else begin
        case (state)
          CGS:       state <= WAIT_LMFC;
          WAIT_LMFC: if (int'(lmfc) == MF - 1) begin state <= ILAS; ilas_mf <= '0; end
          ILAS:      if (int'(lmfc) == MF - 1) begin
                       if (ilas_mf == 2'd3) state <= DATA;
                       ilas_mf <= ilas_mf + 1'b1;
                     end
          DATA:      ;
        endcase
      end
    end
  end

  assign tx_ready  = (state == DATA) && sync_q;
  assign dbg_state = state;

  for (genvar ln = 0; ln < L; ln++) begin : g_lane
    logic [14:0] scr_st;
    logic [7:0]  prev_last;
    logic        have_prev;
    logic [7:0]  oct, oct_q;
    logic        isk, isk_q;
    logic [7:0]  cfg [14];
    logic [22:0] sc;
    logic        end_frame, end_mf;

    // ILAS link configuration (JESD204B table 20)
    always_comb begin
      int sum;
      cfg[0]  = DID;
      cfg[1]  = {4'h0, BID};
      cfg[2]  = 8'(ln);
      cfg[3]  = {SCR, 2'b00, 5'(L - 1)};
      cfg[4]  = 8'(F - 1);
      cfg[5]  = 8'(K - 1);
      cfg[6]  = 8'(M - 1);
      cfg[7]  = 8'(NBITS - 1);
      cfg[8]  = {3'd1, 5'(NP - 1)};      // subclass 1
      cfg[9]  = {3'd1, 5'd0};            // JESD204B, S = 1
      cfg[10] = 8'h00;
      cfg[11] = 8'h00;
      cfg[12] = 8'h00;
      sum = 0;
      for (int i = 0; i < 13; i++) sum += int'(cfg[i]);
      cfg[13] = 8'(sum);
    end

    assign end_frame = (int'(lmfc) % F) == F - 1;
    assign end_mf    = int'(lmfc) == MF - 1;
    assign sc        = scramble(tx_data[8*ln +: 8], scr_st);

    always_comb begin
      oct = K_K;
      isk = 1'b1;
      case (state)
        ILAS: begin
          if (lmfc == '0)                          begin oct = K_R; isk = 1'b1; end
          else if (end_mf)                         begin oct = K_A; isk = 1'b1; end
          else if (ilas_mf == 2'd1 && lmfc == 1)   begin oct = K_Q; isk = 1'b1; end
          else if (ilas_mf == 2'd1 && int'(lmfc) >= 2 && int'(lmfc) < 16) begin
            oct = cfg[int'(lmfc) - 2]; isk = 1'b0;
          end else begin
            oct = 8'(lmfc); isk = 1'b0;             // ramp filler
          end
        end
        DATA: begin
          isk = 1'b0;
          oct = SCR ? sc[7:0] : tx_data[8*ln +: 8];
          if (SCR) begin
            if (end_mf && sc[7:0] == 8'h7C)         begin oct = K_A; isk = 1'b1; end
            else if (end_frame && sc[7:0] == 8'hFC) begin oct = K_F; isk = 1'b1; end
          end else if (end_frame && have_prev && tx_data[8*ln +: 8] == prev_last) begin
            oct = end_mf ? K_A : K_F;
            isk = 1'b1;
          end
        end
        default: ;
      endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
        scr_st    <= '0;
        prev_last <= '0;
        have_prev <= 1'b0;
        oct_q     <= K_K;
        isk_q     <= 1'b1;
      end else begin
        oct_q <= oct;
        isk_q <= isk;
        if (state == DATA && sync_q) begin
          if (SCR) scr_st <= sc[22:8];
          if (end_frame) begin
            prev_last <= tx_data[8*ln +: 8];
            have_prev <= 1'b1;
          end
        end else begin
          scr_st    <= '0;
          have_prev <= 1'b0;
        end
      end
    end

    enc_8b10b u_enc (.clk(clk), .rst_n(rst_n), .en(1'b1), .d(oct_q), .k(isk_q),
                     .code(tx_sym[10*ln +: 10]), .rd());

    assign dbg_octet[8*ln +: 8] = oct_q;
    assign dbg_k[ln]            = isk_q;
  end
endmodule
