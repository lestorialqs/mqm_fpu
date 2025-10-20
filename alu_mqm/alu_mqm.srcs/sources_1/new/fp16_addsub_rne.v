`timescale 1ns / 1ps

////////////////////////////////////////////////////////////////////
// Módulo Suma/Resta FP16 con Redondeo RNE (Adaptado de FP32)
// Sin localparam
////////////////////////////////////////////////////////////////////
module fp16_addsub_rne(
    input  wire        clk,
    input  wire        reset,
    input  wire        start,
    input  wire        sub,      // 0=ADD, 1=SUB
    input  wire [15:0] a, b,     // Entradas FP16
    output reg  [15:0] y,        // Salida FP16
    output reg  [4:0]  flags,    // {NV,DZ,OF,UF,NX}
    output reg         valid
);

  // Unpack FP16: sign(1) + exp(5) + frac(10)
  wire        sa = a[15];
  wire [4:0]  ea = a[14:10];
  wire [9:0]  fa = a[9:0];
  
  wire        sb = b[15];
  wire [4:0]  eb = b[14:10];
  wire [9:0]  fb = b[9:0];

  // Signo efectivo de B en suma/resta
  wire sb_eff = sb ^ sub;

  // Detectar subnormales (exp == 0)
  wire a_den = (ea == 5'd0);
  wire b_den = (eb == 5'd0);
  
  // Añadir bit implícito (1 para normales, 0 para subnormales)
  // Formato: [implícito][mantisa de 10 bits][bit extra]
  wire [11:0] ma0 = {~a_den, fa, 1'b0};  // 12 bits
  wire [11:0] mb0 = {~b_den, fb, 1'b0};

  // Alinear al mayor exponente
  wire [4:0] e_max = (ea >= eb) ? ea : eb;
  wire [4:0] da = e_max - ea;
  wire [4:0] db = e_max - eb;

  // Extender mantisas y desplazar (24 bits para alineación)
  wire [23:0] ma_sh = {ma0, 12'd0} >> da;
  wire [23:0] mb_sh = {mb0, 12'd0} >> db;

  // Suma/resta según signos efectivos
  wire same_sign = (sa == sb_eff);
  wire [24:0] sum_raw = same_sign ? ({1'b0, ma_sh} + {1'b0, mb_sh})
                                   : (ma_sh >= mb_sh ? ({1'b0, ma_sh} - {1'b0, mb_sh})
                                                     : ({1'b0, mb_sh} - {1'b0, ma_sh}));

  // Signo del resultado
  wire sign_out = same_sign ? sa : (ma_sh >= mb_sh ? sa : sb_eff);

  // Normalización usando priority encoder
  wire [4:0]  exp_norm;
  wire [13:0] mant_norm;
  
  // Detectar la posición del bit más significativo (25 bits a revisar)
  assign exp_norm = sum_raw[24] ? (e_max + 5'd1) :
                    sum_raw[23] ? e_max :
                    sum_raw[22] ? (e_max - 5'd1) :
                    sum_raw[21] ? (e_max - 5'd2) :
                    sum_raw[20] ? (e_max - 5'd3) :
                    sum_raw[19] ? (e_max - 5'd4) :
                    sum_raw[18] ? (e_max - 5'd5) :
                    sum_raw[17] ? (e_max - 5'd6) :
                    sum_raw[16] ? (e_max - 5'd7) :
                    sum_raw[15] ? (e_max - 5'd8) :
                    sum_raw[14] ? (e_max - 5'd9) :
                    sum_raw[13] ? (e_max - 5'd10) :
                    sum_raw[12] ? (e_max - 5'd11) :
                    sum_raw[11] ? (e_max - 5'd12) : 5'd0;

  // Extraer mantisa normalizada (14 bits: 11 mantisa + GRS)
  assign mant_norm = sum_raw[24] ? sum_raw[24:11] :
                     sum_raw[23] ? sum_raw[23:10] :
                     sum_raw[22] ? sum_raw[22:9] :
                     sum_raw[21] ? sum_raw[21:8] :
                     sum_raw[20] ? sum_raw[20:7] :
                     sum_raw[19] ? sum_raw[19:6] :
                     sum_raw[18] ? sum_raw[18:5] :
                     sum_raw[17] ? sum_raw[17:4] :
                     sum_raw[16] ? sum_raw[16:3] :
                     sum_raw[15] ? sum_raw[15:2] :
                     sum_raw[14] ? sum_raw[14:1] :
                     sum_raw[13] ? sum_raw[13:0] :
                     sum_raw[12] ? {sum_raw[12:0], 1'b0} :
                     sum_raw[11] ? {sum_raw[11:0], 2'b0} : 14'd0;

  // Round to Nearest Even (RNE)
  wire [10:0] mant = mant_norm[13:3];  // Mantisa de 11 bits (con implícito)
  wire        G    = mant_norm[2];      // Guard bit
  wire        R    = mant_norm[1];      // Round bit
  wire        S    = mant_norm[0];      // Sticky bit
  
  // Tie: G=1, R=0, S=0 → redondear hacia par (LSB=0)
  wire        tie  = G & ~R & ~S;
  wire        incr = (G & (R | S)) | (tie & mant[0]);

  wire [11:0] mant_rounded = {1'b0, mant} + (incr ? 12'd1 : 12'd0);

  // Si el redondeo causa overflow en la mantisa
  wire [4:0]  exp_final  = mant_rounded[11] ? (exp_norm + 5'd1) : exp_norm;
  wire [9:0]  frac_final = mant_rounded[11] ? mant_rounded[10:1] : mant_rounded[9:0];

  // Flags de excepción
  wire NV = 1'b0;  // Invalid operation (no detectado en esta implementación simple)
  wire DZ = 1'b0;  // Divide by zero (no aplica)
  wire OF = (exp_final >= 5'h1F);  // Overflow
  wire UF = (exp_final == 5'h00) && (|frac_final);  // Underflow
  wire NX = (G | R | S) | OF | UF;  // Inexact

  // Empaquetar resultado FP16
  wire [15:0] pack = {sign_out, exp_final, frac_final};

  // Registro de salida
  always @(posedge clk or posedge reset) begin
    if (reset) begin
      y     <= 16'd0;
      flags <= 5'd0;
      valid <= 1'b0;
    end else if (start) begin
      y     <= pack;
      flags <= {NV, DZ, OF, UF, NX};
      valid <= 1'b1;
    end else begin
      valid <= 1'b0;
    end
  end
  
endmodule