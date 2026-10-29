// fpga_top.sv - synthesis top for the build sweep.
//
// Instantiates the JESD204B transmit and receive link layers (parallel
// 10-bit transceiver interfaces; the serial transceivers themselves are
// vendor IP and are not part of this repository) next to the LDPC encoder
// and an array of NUM_DEC decoder cores. The two subsystems share the
// device clock but are otherwise independent; their parameters are the
// knobs swept by scripts/gen_configs.py.
module fpga_top #(
  parameter int L        = 4,
  parameter bit SCR      = 1'b1,
  parameter int F        = 2,
  parameter int K        = 16,
  parameter int NUM_DEC  = 2,
  parameter int MAX_ITER = 10
) (
  input  logic            clk,
  input  logic            rst_n,
  // JESD204B transmit side
  input  logic            tx_sync_n,
  input  logic [8*L-1:0]  tx_data,
  output logic            tx_ready,
  output logic [10*L-1:0] gt_tx_sym,
  // JESD204B receive side
  input  logic [10*L-1:0] gt_rx_sym,
  output logic            rx_sync_n,
  output logic [8*L-1:0]  rx_data,
  output logic            rx_valid,
  output logic            rx_aligned,
  output logic [15:0]     rx_err_count,
  // LDPC encoder
  input  logic            enc_valid,
  input  logic [63:0]     enc_msg,
  output logic            enc_out_valid,
  output logic [127:0]    enc_cw,
  // LDPC decoder array
  input  logic            dec_valid,
  output logic            dec_ready,
  input  logic [7:0]      dec_tag,
  input  logic [128*6-1:0] dec_llr,
  output logic            dec_out_valid,
  output logic [7:0]      dec_out_tag,
  output logic [127:0]    dec_out_bits,
  output logic [4:0]      dec_out_iters,
  output logic            dec_out_ok
);
  jesd_tx #(.L(L), .F(F), .K(K), .SCR(SCR)) u_jesd_tx (
    .clk(clk), .rst_n(rst_n), .sync_n(tx_sync_n), .tx_data(tx_data),
    .tx_ready(tx_ready), .tx_sym(gt_tx_sym), .dbg_octet(), .dbg_k(), .dbg_state());

  jesd_rx #(.L(L), .F(F), .K(K), .SCR(SCR)) u_jesd_rx (
    .clk(clk), .rst_n(rst_n), .rx_sym(gt_rx_sym), .sync_n(rx_sync_n),
    .rx_data(rx_data), .rx_valid(rx_valid), .lane_sync(), .aligned(rx_aligned),
    .ilas_ok(), .err_count(rx_err_count), .align_err_count(), .lane_offset(),
    .lane_depth());

  ldpc_encoder u_enc (
    .clk(clk), .rst_n(rst_n), .in_valid(enc_valid), .msg(enc_msg),
    .out_valid(enc_out_valid), .cw(enc_cw));

  ldpc_dec_array #(.NUM_DEC(NUM_DEC), .TAGW(8), .ITW(5)) u_dec (
    .clk(clk), .rst_n(rst_n), .max_iter(5'(MAX_ITER)),
    .in_valid(dec_valid), .in_ready(dec_ready), .in_tag(dec_tag), .in_llr(dec_llr),
    .out_valid(dec_out_valid), .out_tag(dec_out_tag), .out_bits(dec_out_bits),
    .out_iters(dec_out_iters), .out_ok(dec_out_ok));
endmodule
