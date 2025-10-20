`timescale 1ns / 1ps

module fp_core16(
    input  wire        clk,
    input  wire        reset, // Cambiado 'rst' a 'reset' para consistencia
    input  wire        start,
    input  wire [2:0]  op,         // 100 add, 101 sub, 110 mul, 111 div
    input  wire [15:0] a, b,       // ENTRADAS FP16
    input  wire [1:0]  round_mode, // Ignorado por ahora, asume RNE
    output wire [15:0] result,     // SALIDA FP16
    output wire [4:0]  flags,      // {NV, DZ, OF, UF, NX}
    output wire        valid_out
);

    // --- Desempaquetado FP16 ---
    wire sa = a[15];
    wire sb = b[15];
    wire [4:0] ea = a[14:10]; // Exponente de 5 bits
    wire [4:0] eb = b[14:10];
    wire [9:0] fa = a[9:0];  // Fracción de 10 bits
    wire [9:0] fb = b[9:0];

    localparam EXP_WIDTH = 5;
    localparam FRAC_WIDTH = 10;
    localparam BIAS = 15;
    localparam EXP_INF_NAN = 5'h1F; // Patrón de exponente para Inf/NaN en FP16
    localparam EXP_ZERO = 5'h00;

    // --- Predicados FP16 ---
    wire a_is_nan = (ea == EXP_INF_NAN) && (fa != 0);
    wire b_is_nan = (eb == EXP_INF_NAN) && (fb != 0);
    wire a_is_inf = (ea == EXP_INF_NAN) && (fa == 0);
    wire b_is_inf = (eb == EXP_INF_NAN) && (fb == 0);
    wire a_is_zero= (ea == EXP_ZERO)    && (fa == 0);
    wire b_is_zero= (eb == EXP_ZERO)    && (fb == 0);

    // --- Lógica de Casos Especiales FP16 ---
    reg [15:0] special_res;
    reg [4:0]  special_flags;
    reg        take_special;

    localparam QNAN16 = 16'h7E00; // NaN Canónico para FP16
    localparam INF16_POS = {1'b0, EXP_INF_NAN, {FRAC_WIDTH{1'b0}}};
    localparam INF16_NEG = {1'b1, EXP_INF_NAN, {FRAC_WIDTH{1'b0}}};

    always @* begin
        take_special  = 1'b0;
        special_res   = QNAN16;
        special_flags = 5'b00000;

        if (a_is_nan || b_is_nan) begin
            take_special  = 1'b1;
            special_flags = 5'b10000; // NV
        end
        else if (op == 3'b011 && b_is_zero) begin // Div por cero
            take_special  = 1'b1;
            special_res   = (sa ^ sb) ? INF16_NEG : INF16_POS;
            special_flags = 5'b01000; // DZ
        end
        else if (op == 3'b010 && ((a_is_inf && b_is_zero) || (a_is_zero && b_is_inf))) begin // Mul Inf * 0
            take_special  = 1'b1;
            special_res   = QNAN16;
            special_flags = 5'b10000; // NV
        end
        else if (a_is_inf || b_is_inf) begin // Operaciones con Inf
            if (op == 3'b010) begin // Mul
                take_special = 1'b1;
                special_res  = (sa ^ sb) ? INF16_NEG : INF16_POS;
            end
            else if (op == 3'b000 || op == 3'b001) begin // Add/Sub
                // Inf - Inf = NaN, Inf + Fin = Inf
                if (a_is_inf && b_is_inf && (sa ^ sb) == (op == 3'b001 ? 1'b0 : 1'b1)) begin // Inf - Inf
                    take_special  = 1'b1;
                    special_res   = QNAN16;
                    special_flags = 5'b10000; // NV
                end else begin // Inf + Fin ó Inf + Inf (mismo signo)
                    take_special = 1'b1;
                    special_res  = a_is_inf ? a : b; // Resultado es el Infinito de entrada
                end
            end
        end
    end

    // --- Operadores FP16 (Necesitas crear/adaptar estos módulos) ---
    wire [15:0] add_res_16; wire [4:0] add_flg_16; wire add_v_16;
    wire [15:0] sub_res_16; wire [4:0] sub_flg_16; wire sub_v_16;
    wire [15:0] mul_res_16; wire [4:0] mul_flg_16; wire mul_v_16;
    wire [15:0] div_res_16; wire [4:0] div_flg_16; wire div_v_16;

    // Instanciar unidades FP16 (¡Asegúrate de que existan y funcionen!)
    fp16_addsub_rne u_add16 (.clk(clk), .reset(reset), .start(start & ~take_special), .sub(1'b0),
                             .a(a), .b(b), .y(add_res_16), .flags(add_flg_16), .valid(add_v_16));
    fp16_addsub_rne u_sub16 (.clk(clk), .reset(reset), .start(start & ~take_special), .sub(1'b1),
                            .a(a), .b(b), .y(sub_res_16), .flags(sub_flg_16), .valid(sub_v_16));
    fp16_mul_rne    u_mul16 (.clk(clk), .reset(reset), .start(start & ~take_special),
                             .a(a), .b(b), .y(mul_res_16), .flags(mul_flg_16), .valid(mul_v_16));
    fp16_div_rne    u_div16 (.clk(clk), .reset(reset), .start(start & ~take_special),
                             .a(a), .b(b), .y(div_res_16), .flags(div_flg_16), .valid(div_v_16));



    // --- Selección de Resultado, Flags y Valid ---
    reg [15:0] y_r; // Resultado FP16
    reg [4:0]  f_r;
    reg        v_r;

    always @* begin
        if (take_special) begin
            y_r = special_res;
            f_r = special_flags;
            v_r = start; // Casos especiales terminan rápido
        end else begin
            case (op)
                3'b100: begin y_r = add_res_16; f_r = add_flg_16; v_r = add_v_16; end
                3'b101: begin y_r = sub_res_16; f_r = sub_flg_16; v_r = sub_v_16; end
                3'b110: begin y_r = mul_res_16; f_r = mul_flg_16; v_r = mul_v_16; end // Temporal
                3'b111: begin y_r = div_res_16; f_r = div_flg_16; v_r = div_v_16; end // Temporal
                default: begin y_r = QNAN16; f_r = 5'b10000; v_r = start; end // Operación inválida
            endcase
        end
    end

    assign result    = y_r;
    assign flags     = f_r;
    assign valid_out = v_r;

endmodule
