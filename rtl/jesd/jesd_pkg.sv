// jesd_pkg.sv - 8b/10b tables, scrambler step and JESD204B control codes.
// Symbol bit 9 is 'a' (first on the wire); RD is 0 for RD-, 1 for RD+.
package jesd_pkg;

  localparam logic [7:0] K_R = 8'h1C;   // K28.0  start of ILAS multiframe
  localparam logic [7:0] K_A = 8'h7C;   // K28.3  multiframe alignment
  localparam logic [7:0] K_Q = 8'h9C;   // K28.4  start of ILAS config data
  localparam logic [7:0] K_K = 8'hBC;   // K28.5  code group synchronisation
  localparam logic [7:0] K_F = 8'hFC;   // K28.7  frame alignment

  // 5b/6b code for RD- (abcdei)
  function automatic logic [5:0] six_m(input logic [4:0] x);
    case (x)
      5'd0:  return 6'b100111;  5'd1:  return 6'b011101;  5'd2:  return 6'b101101;
      5'd3:  return 6'b110001;  5'd4:  return 6'b110101;  5'd5:  return 6'b101001;
      5'd6:  return 6'b011001;  5'd7:  return 6'b111000;  5'd8:  return 6'b111001;
      5'd9:  return 6'b100101;  5'd10: return 6'b010101;  5'd11: return 6'b110100;
      5'd12: return 6'b001101;  5'd13: return 6'b101100;  5'd14: return 6'b011100;
      5'd15: return 6'b010111;  5'd16: return 6'b011011;  5'd17: return 6'b100011;
      5'd18: return 6'b010011;  5'd19: return 6'b110010;  5'd20: return 6'b001011;
      5'd21: return 6'b101010;  5'd22: return 6'b011010;  5'd23: return 6'b111010;
      5'd24: return 6'b110011;  5'd25: return 6'b100110;  5'd26: return 6'b010110;
      5'd27: return 6'b110110;  5'd28: return 6'b001110;  5'd29: return 6'b101110;
      5'd30: return 6'b011110;  default: return 6'b101011;   // 31
    endcase
  endfunction

  // 3b/4b data code for RD- (fghj); y = 7 is the primary P7
  function automatic logic [3:0] four_m(input logic [2:0] y);
    case (y)
      3'd0: return 4'b1011;  3'd1: return 4'b1001;  3'd2: return 4'b0101;
      3'd3: return 4'b1100;  3'd4: return 4'b1101;  3'd5: return 4'b1010;
      3'd6: return 4'b0110;  default: return 4'b1110;
    endcase
  endfunction

  // 3b/4b code for K28.y, RD-
  function automatic logic [3:0] fourk_m(input logic [2:0] y);
    case (y)
      3'd0: return 4'b1011;  3'd1: return 4'b0110;  3'd2: return 4'b1010;
      3'd3: return 4'b1100;  3'd4: return 4'b1101;  3'd5: return 4'b0101;
      3'd6: return 4'b1001;  default: return 4'b0111;
    endcase
  endfunction

  function automatic int ones6(input logic [5:0] v);
    int n;
    n = 0;
    for (int i = 0; i < 6; i++) n += int'(v[i]);
    return n;
  endfunction

  function automatic int ones4(input logic [3:0] v);
    int n;
    n = 0;
    for (int i = 0; i < 4; i++) n += int'(v[i]);
    return n;
  endfunction

  // Does the RD+ column differ from RD- (complemented) for this sub-block?
  function automatic logic six_flips(input logic [4:0] x);
    return (ones6(six_m(x)) != 3) || (x == 5'd7);
  endfunction

  function automatic logic four_flips(input logic [2:0] y);
    return (ones4(four_m(y)) != 2) || (y == 3'd3);
  endfunction

  // Encode one octet: returns {rd_out, code[9:0]}. K = 1 encodes K28.y.
  function automatic logic [10:0] enc8b10b(input logic [7:0] d, input logic k,
                                           input logic rd);
    logic [4:0] x;
    logic [2:0] y;
    logic [5:0] six;
    logic [3:0] four;
    logic       rd6, rdo, alt7;
    x = d[4:0];
    y = d[7:5];
    if (k) six = rd ? ~6'b001111 : 6'b001111;
    else   six = (rd && six_flips(x)) ? ~six_m(x) : six_m(x);
    rd6 = (ones6(six) == 3) ? rd : (ones6(six) > 3);
    alt7 = (y == 3'd7) && ((!rd6 && (x == 5'd17 || x == 5'd18 || x == 5'd20)) ||
                           ( rd6 && (x == 5'd11 || x == 5'd13 || x == 5'd14)));
    if (k)          four = rd6 ? ~fourk_m(y) : fourk_m(y);
    else if (alt7)  four = rd6 ? 4'b1000 : 4'b0111;
    else            four = (rd6 && four_flips(y)) ? ~four_m(y) : four_m(y);
    rdo = (ones4(four) == 2) ? rd6 : (ones4(four) > 2);
    return {rdo, six, four};
  endfunction

  // Scramble one octet (1 + x^14 + x^15, MSB first). state[0] = newest bit.
  // Returns {new_state[14:0], octet[7:0]}.
  function automatic logic [22:0] scramble(input logic [7:0] d, input logic [14:0] st);
    logic [14:0] s;
    logic [7:0]  o;
    logic        b;
    s = st;
    for (int i = 7; i >= 0; i--) begin
      b = d[i] ^ s[13] ^ s[14];
      s = {s[13:0], b};
      o[i] = b;
    end
    return {s, o};
  endfunction

  function automatic logic [22:0] descramble(input logic [7:0] sd, input logic [14:0] st);
    logic [14:0] s;
    logic [7:0]  o;
    s = st;
    for (int i = 7; i >= 0; i--) begin
      o[i] = sd[i] ^ s[13] ^ s[14];
      s = {s[13:0], sd[i]};
    end
    return {s, o};
  endfunction

endpackage
