`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 20.10.2025 04:39:23
// Design Name: 
// Module Name: fp16_div_rne
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module fp16_div_rne(
  input clk, reset, start,
  input  [15:0] a, b,
  output reg [15:0] y,
  output reg [4:0]  flags,   // {NV,DZ,OF,UF,NX}
  output reg        valid
);
  // Parameters for FP16
  localparam EXP_W = 5;
  localparam FRAC_W = 10;
  localparam BIAS = 15;
  localparam EXP_INF_NAN = {EXP_W{1'b1}}; // 5'b11111
  localparam EXP_ZERO = {EXP_W{1'b0}};
  localparam FRAC_ZERO = {FRAC_W{1'b0}};

  // Unpack
  wire sa = a[15];
  wire [EXP_W-1:0] ea = a[14:10];
  wire [FRAC_W-1:0] fa = a[9:0];

  wire sb = b[15];
  wire [EXP_W-1:0] eb = b[14:10];
  wire [FRAC_W-1:0] fb = b[9:0];

  // Detect special inputs
  wire a_is_zero = (ea == EXP_ZERO) && (fa == FRAC_ZERO);
  wire b_is_zero = (eb == EXP_ZERO) && (fb == FRAC_ZERO);
  wire a_is_den  = (ea == EXP_ZERO) && (fa != FRAC_ZERO);
  wire b_is_den  = (eb == EXP_ZERO) && (fb != FRAC_ZERO);
  wire a_is_inf  = (ea == EXP_INF_NAN) && (fa == FRAC_ZERO);
  wire b_is_inf  = (eb == EXP_INF_NAN) && (fb == FRAC_ZERO);
  wire a_is_nan  = (ea == EXP_INF_NAN) && (fa != FRAC_ZERO);
  wire b_is_nan  = (eb == EXP_INF_NAN) && (fb != FRAC_ZERO);

  // Result sign
  wire s = sa ^ sb;

  // Early special-case detection
  wire case_nan = a_is_nan | b_is_nan;
  wire case_inf_inf = a_is_inf & b_is_inf;
  wire case_zero_zero = a_is_zero & b_is_zero;
  wire case_div_by_zero = b_is_zero & ~a_is_zero; // a/0 (non-zero / 0)
  // note: 0/0 and Inf/Inf are invalid -> produce NaN and NV flag

  // Build mantissas (11 bits: implicit + frac). For denormals implicit=0.
  // For normal: implicit=1. For zero, mantissa kept 0.
  wire [FRAC_W:0] ma = a_is_zero ? {FRAC_W+1{1'b0}} : ({a_is_den ? 1'b0 : 1'b1, fa});
  wire [FRAC_W:0] mb = b_is_zero ? {FRAC_W+1{1'b0}} : ({b_is_den ? 1'b0 : 1'b1, fb});

  // Compute unbiased exponents (signed)
  // For normal: ea_unb = ea - BIAS
  // For denorm: ea_unb = 1 - BIAS (since exponent field = 0 represents 2^(1-bias) times fraction)
  wire signed [7:0] ea_unb = a_is_zero ? (1 - BIAS) : (a_is_den ? (1 - BIAS) : $signed({1'b0, ea}) - BIAS);
  wire signed [7:0] eb_unb = b_is_zero ? (1 - BIAS) : (b_is_den ? (1 - BIAS) : $signed({1'b0, eb}) - BIAS);

  // Base unbiased exponent for quotient (ea_unb - eb_unb)
  wire signed [8:0] e_base_unb = $signed(ea_unb) - $signed(eb_unb);

  // If divisor is zero we will not perform / ; division by zero handled separately.

  // --- Division scaled to produce FRAC_W + 3 GRS bits of precision ---
  // Need mantissa precision = FRAC_W + 3 (GRS). We'll shift dividend left by SCALE bits.
  localparam integer GRS = 3;
  localparam integer SCALE = FRAC_W + GRS; // 13 for fp16
  // dividend width: (FRAC_W+1) + SCALE  -> 11 + 13 = 24 bits
  wire [FRAC_W+SCALE:0] dividend = {ma, {SCALE{1'b0}}}; // 11 + 13 = 24 bits
  wire [FRAC_W:0] divisor = mb; // 11 bits

  // Protect divide-by-zero: if divisor==0 we skip division (handled by cases)
  wire divisor_is_zero = (divisor == 0);

  // Full quotient and remainder (integer division)
  // widths: q_full up to 24 bits; r_full up to 11 bits
  wire [FRAC_W+SCALE:0] q_full  = divisor_is_zero ? {FRAC_W+SCALE+1{1'b0}} : (dividend / divisor);
  wire [FRAC_W:0]        r_full  = divisor_is_zero ? {FRAC_W+1{1'b0}} : (dividend % divisor);

  // We only need lower (SCALE+1) bits: 1 integer bit + FRAC_W + GRS = SCALE+1 bits.
  // index: q_full[SCALE:0] (e.g., [13:0] for fp16)
  wire [SCALE:0] q_scaled = q_full[SCALE:0]; // 14 bits

  // Determine lead (is quotient in [1,2) -> q_scaled[SCALE]==1, otherwise it is [0.5,1) -> 0)
  wire lead = q_scaled[SCALE];

  // Normalize: if lead==0 shift left 1 and decrement exponent by 1
  wire [SCALE:0] norm_scaled = lead ? q_scaled : {q_scaled[SCALE-1:0], 1'b0}; // still SCALE+1 bits
  wire signed [8:0] e_norm_unb = lead ? e_base_unb : (e_base_unb - 1);

  // Extract mantissa (1.f -> FRAC_W+1 bits = 11) and G,R,S
  // norm_scaled bits mapping: bit [SCALE] is integer bit
  // mant_full = norm_scaled[SCALE : SCALE-FRAC_W]  -> gives (FRAC_W+1) bits (implicit + frac)
  wire [FRAC_W:0] mant_full = norm_scaled[SCALE : SCALE-FRAC_W]; // bits [13:3] -> [10:0]
  wire G = norm_scaled[2];
  wire R = norm_scaled[1];
  wire S_sticky = norm_scaled[0] | (|r_full); // sticky OR remainder

  // Round-to-nearest-even (RNE)
  wire tie = G & ~R & ~S_sticky;
  wire round_up = (G & (R | S_sticky)) | (tie & mant_full[0]);

  wire [FRAC_W+1:0] mant_plus = {1'b0, mant_full} + (round_up ? {{(FRAC_W+1){1'b0}},1'b1} : {FRAC_W+2{1'b0}});
  // mant_plus width = FRAC_W+2 (12 bits)

  // If rounding produced carry (i.e., bit FRAC_W+1 == 1), shift right and increment exponent
  wire mant_carry = mant_plus[FRAC_W+1];
  wire [FRAC_W:0] mant_rounded = mant_carry ? mant_plus[FRAC_W+1:1] : mant_plus[FRAC_W:0];
  // mant_rounded is (FRAC_W+1) bits (implicit + frac)

  // Adjust exponent unbiased after rounding carry
  wire signed [9:0] e_adj_unb = mant_carry ? (e_norm_unb + 1) : e_norm_unb;

  // Now compute biased exponent
  wire signed [9:0] exp_biased_signed = e_adj_unb + BIAS; // can be negative or >31

  // Overflow / underflow decisions
  wire is_overflow = (exp_biased_signed >= EXP_INF_NAN);
  wire is_underflow = (exp_biased_signed <= 0);

  // Output for normal case:
  wire [EXP_W-1:0] exp_out_normal = is_overflow ? EXP_INF_NAN : exp_biased_signed[EXP_W-1:0];
  wire [FRAC_W-1:0] frac_out_normal = mant_rounded[FRAC_W-1:0];

  // If underflow -> produce subnormal or zero.
  // For subnormal generation:
  // shift = 1 - exp_biased_signed (positive)
  // We need to take the unrounded mantissa with implicit 1 (before final rounding carry),
  // shift it right by 'shift' bits and then round to nearest even using the bits shifted out.
  // We will build a wide mantissa to shift: use (implicit 1 + FRAC_W) plus extra GRS bits already present:
  // Use the 'norm_scaled' window as source (it contains FRAC_W+1 + GRS bits).
  // We'll reconstruct a wide value: W = {mant_full, G, R, S_rest}, where S_rest includes remainder bits.
  // Simpler approach: rebuild a wide integer from q_full (the full quotient) and shift accordingly.

  // For subnormal processing, create a wide value 'wide_q' consisting of:
  // - the integer+fraction bits of q_full (we have q_full up to many bits) and remainder r_full
  // We'll create a wide vector from (q_full concatenated with r_full) to do accurate right shift.
  localparam WIDE = (FRAC_W+1) + GRS + 8; // generous width
  // build wide value: take q_full bits [ (SCALE + extra) : 0 ] and append r_full zeros
  // For simplicity we create a 32-bit wide value with the high bits of q_full and remainder.
  wire [31:0] wide_q_low;
  assign wide_q_low = { {8{1'b0}}, q_full[23:0] }; // safe pad; q_full width <= 24 (for fp16)

  // shift amount to create subnormal
  wire [7:0] shift_amount = (is_underflow) ? (8'd1 - exp_biased_signed[7:0]) : 8'd0; // positive when underflow

  // When is_underflow, create subnormal result:
  // Take mantissa with implicit bit extended into an integer and right shift by shift_amount.
  // We'll take a  (FRAC_W+1 + GRS + extra) bit field starting from norm_scaled and remainder r_full.
  // To avoid overcomplication, approximate by starting from {mant_full, G, R, S_sticky} as a 14-bit field
  // and then right shift with sticky aggregation for rounding.
  wire [FRAC_W+GRS+1:0] mant_with_grs = {mant_full, G, R, S_sticky}; // 11+3 = 14 bits: [13:0]

  // If shift_amount >= (FRAC_W+1) -> result will be zero (all shifted out)
  // else shift right and compute final fraction and rounding.
  reg [FRAC_W-1:0] frac_sub;
  reg uf_flag_sub;
    // 👇 Declarar estas señales aquí también
  reg G_sub;
  reg R_sub;
  reg S_sub;
  integer k;
  reg [FRAC_W+GRS+1:0] temp;
  reg shifted_out_nonzero;
  reg [FRAC_W-1:0] frac_cand;
  always @(*) begin
    frac_sub = 0;
    uf_flag_sub = 0;
    G_sub = 0;
    R_sub = 0;
    S_sub = 0;
    temp = 0;
    shifted_out_nonzero = 0;

    if (is_underflow) begin
      if (shift_amount >= (FRAC_W+1)) begin
        frac_sub = 0;
        uf_flag_sub = (|mant_with_grs);
      end else begin
        temp = mant_with_grs;
        shifted_out_nonzero = 0;
        for (k = 0; k < shift_amount; k = k + 1) begin
          shifted_out_nonzero = shifted_out_nonzero | temp[0];
          temp = temp >> 1;
        end
        G_sub = temp[0];
        R_sub = shifted_out_nonzero;
        S_sub = 0;
         // ⚠️ si esto da error, también sácalo fuera
        frac_cand = temp[FRAC_W:1];
        if (G_sub & (R_sub | S_sub | frac_cand[0])) begin
          frac_sub = frac_cand + 1;
        end else begin
          frac_sub = frac_cand;
        end
        uf_flag_sub = (|mant_with_grs) && (|({G_sub,R_sub}));
      end
    end
  end

  // Final output selection (special cases)
  reg [15:0] result_pack;
  reg NV_flag;
  reg DZ_flag;
  reg OF_flag;
  reg UF_flag;
  reg NX_flag;

  always @(*) begin
    // default
    result_pack = 16'h0000;
    NV_flag = 1'b0; DZ_flag = 1'b0; OF_flag = 1'b0; UF_flag = 1'b0; NX_flag = 1'b0;

    // NaN input -> quiet NaN (propagate a if it is NaN, else b)
    if (case_nan) begin
      // propagate a's payload if a is NaN else b's
      if (a_is_nan) result_pack = {1'b0, EXP_INF_NAN, {1'b1, fa[FRAC_W-1:0]}}; // qNaN bit1=1
      else           result_pack = {1'b0, EXP_INF_NAN, {1'b1, fb[FRAC_W-1:0]}};
      NV_flag = 1'b1;
      NX_flag = 1'b1;
    end
    else if (case_inf_inf) begin
      // Inf/Inf -> NaN (invalid)
      result_pack = {1'b0, EXP_INF_NAN, 1'b1 << (FRAC_W-1)}; // canonical NaN
      NV_flag = 1'b1;
      NX_flag = 1'b1;
    end
    else if (case_zero_zero) begin
      // 0/0 -> NaN (invalid)
      result_pack = {1'b0, EXP_INF_NAN, 1'b1 << (FRAC_W-1)};
      NV_flag = 1'b1;
      NX_flag = 1'b1;
    end
    else if (case_div_by_zero) begin
      // a/0 (a != 0) -> +/- Inf, set DZ flag
      result_pack = {s, EXP_INF_NAN, FRAC_ZERO};
      DZ_flag = 1'b1;
      NX_flag = 1'b0;
    end
    else if (a_is_inf && ~b_is_inf) begin
      // Inf / finite -> Inf
      result_pack = {s, EXP_INF_NAN, FRAC_ZERO};
      NX_flag = 1'b0;
    end
    else if (~a_is_inf && b_is_inf) begin
      // finite / Inf -> zero (signed)
      result_pack = {s, EXP_ZERO, FRAC_ZERO};
      NX_flag = 1'b0;
    end
    else begin
      // Normal or subnormal result production
      if (is_overflow) begin
        // Overflow -> infinite
        result_pack = {s, EXP_INF_NAN, FRAC_ZERO};
        OF_flag = 1'b1;
        NX_flag = 1'b1;
      end else if (is_underflow) begin
        // produce subnormal or zero; use frac_sub computed
        result_pack = {s, EXP_ZERO, frac_sub};
        UF_flag = uf_flag_sub;
        NX_flag = (|mant_with_grs) | UF_flag; // inexact if any lower bits present or UF
      end else begin
        // Normal result
        result_pack = {s, exp_out_normal, frac_out_normal};
        // set NX if any G,R,S were non-zero OR remainder non-zero
        NX_flag = (G | R | S_sticky);
      end
    end
  end

  // Output register
  always @(posedge clk or posedge reset) begin
    if (reset) begin
      y <= 16'd0;
      flags <= 5'd0;
      valid <= 1'b0;
    end else if (start) begin
      y <= result_pack;
      flags <= {NV_flag, DZ_flag, OF_flag, UF_flag, NX_flag};
      valid <= 1'b1;
    end else begin
      valid <= 1'b0;
    end
  end

endmodule
