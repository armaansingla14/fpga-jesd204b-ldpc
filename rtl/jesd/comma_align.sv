// comma_align.sv - word alignment of a 10-bit parallel stream with an
// unknown bit offset. A K28.5 (either disparity) found at offset o in the
// 20-bit window {previous word, current word} sets the alignment while
// 'search' is high; the offset is frozen once the lane is synchronised.
module comma_align (
  input  logic       clk,
  input  logic       rst_n,
  input  logic       search,
  input  logic [9:0] din,        // bit 9 is the earliest bit on the wire
  output logic [9:0] dout,
  output logic       locked,
  output logic [3:0] offset
);
  logic [9:0]  prev;
  logic [19:0] win;
  logic [3:0]  hit_off;
  logic        hit;

  assign win = {prev, din};

  always_comb begin
    hit = 1'b0;
    hit_off = '0;
    for (int o = 9; o >= 0; o--) begin
      if (win[19-o -: 10] == 10'b0011111010 || win[19-o -: 10] == 10'b1100000101) begin
        hit = 1'b1;
        hit_off = 4'(o);
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      prev   <= '0;
      offset <= '0;
      locked <= 1'b0;
      dout   <= '0;
    end else begin
      prev <= din;
      if (search && hit && (!locked || hit_off != offset)) begin
        offset <= hit_off;
        locked <= 1'b1;
        dout   <= win[19-int'(hit_off) -: 10];
      end else begin
        dout   <= win[19-int'(offset) -: 10];
      end
    end
  end
endmodule
