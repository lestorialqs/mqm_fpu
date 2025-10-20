`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 20.10.2025 04:38:40
// Design Name: 
// Module Name: fp16_mul_rne
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


module fp16_mul_rne(
  input         clk, reset, start,
  input  [15:0] a, b,
  output reg [15:0] y,
  output reg [4:0]  flags,    // {NV,DZ,OF,UF,NX}
  output reg        valid
);

  // Unpack IEEE 754 half precision
  wire sa = a[15]; wire [4:0] ea = a[14:10]; wire [9:0] fa = a[9:0];
  wire sb = b[15]; wire [4:0] eb = b[14:10]; wire [9:0] fb = b[9:0];

  wire a_den = (ea == 5'd0);
  wire b_den = (eb == 5'd0);

  // Mantisa completa: 1.fracción (11 bits)
  wire [10:0] ma = {~a_den, fa};
  wire [10:0] mb = {~b_den, fb};

  // Signo de salida
  wire s = sa ^ sb;

  // Producto mantisas: 11 x 11 = 22 bits
  wire [21:0] prod = ma * mb;

  // prod[21:20] contienen la parte entera principal
  // Si prod[21]=1 => normalizar a [1.0, 2.0)
  wire lead = prod[21];

  // Exponente sin bias: (ea - 15) + (eb - 15) = ea + eb - 30
  wire [6:0] exp_raw = {2'b00, ea} + {2'b00, eb} - 7'd30;

  // Normalizar: si lead=1, incrementar exponente
  wire [6:0] exp_normalized = lead ? (exp_raw + 7'd1) : exp_raw;

  // Extraer mantisa y bits de redondeo
  // Si lead=1: bit implícito está en prod[21]
  // mantisa de 10 bits en prod[20:11], G=prod[10], R=prod[9], S=|prod[8:0]
  // Si lead=0: bit implícito en prod[20]
  // mantisa de 10 bits en prod[19:10], G=prod[9], R=prod[8], S=|prod[7:0]

  wire [9:0] mantissa_10 = lead ? prod[20:11] : prod[19:10];
  wire G = lead ? prod[10] : prod[9];
  wire R = lead ? prod[9]  : prod[8];
  wire S = lead ? (|prod[8:0]) : (|prod[7:0]);

  // Round to nearest, ties to even
  wire lsb = mantissa_10[0];
  wire round_up = G & (R | S | lsb);

  // Redondear (agregar 1 si corresponde)
  wire [10:0] mantissa_rounded = {1'b0, mantissa_10} + (round_up ? 11'd1 : 11'd0);

  // Si hay carry out, incrementar exponente
  wire carry_out = mantissa_rounded[10];
  wire [6:0] exp_final = carry_out ? (exp_normalized + 7'd1) : exp_normalized;

  // Fracción final (10 bits)
  wire [9:0] frac_final = carry_out ? mantissa_rounded[9:0] : mantissa_rounded[9:0];

  // Agregar bias de 15
  wire [6:0] exp_biased = exp_final + 7'd15;

  // Detección de overflow / underflow
  wire overflow  = (exp_biased >= 7'd31);
  wire underflow = (exp_biased <= 7'd0);

  wire [4:0] exp_out = overflow  ? 5'h1F :
                       underflow ? 5'h00 :
                       exp_biased[4:0];

  // Flags
  wire NV = 1'b0;
  wire DZ = 1'b0;
  wire OF = overflow;
  wire UF = underflow && (|mantissa_10);
  wire NX = (G | R | S) || OF || UF;

  // Empaquetar resultado IEEE 754 half
  always @(posedge clk or posedge reset) begin
    if (reset) begin
      y     <= 16'd0;
      flags <= 5'd0;
      valid <= 1'b0;
    end else if (start) begin
      y     <= {s, exp_out, frac_final};
      flags <= {NV, DZ, OF, UF, NX};
      valid <= 1'b1;
    end else begin
      valid <= 1'b0;
    end
  end

endmodule
