`timescale 1ns / 1ps
// MÓDULO FPU (sin cambios)
// Este módulo selecciona entre fp16_new y fp32_new
module fpu_new (
    // ---- NUEVAS ENTRADAS/SALIDAS DE CONTROL SECUENCIAL ----
    clk,
    reset,
    start,
    valid_out,
    SrcA,
    SrcB,
    FPUControl,
    precision,
    round_mode,
    FPUResult,
    FPUFlags
);
    input  wire        clk;       // Reloj principal (rápido)
    input  wire        reset;        // Reset
    input  wire        start;   // Señal para iniciar la operación
    input wire [1:0] round_mode;    
    output wire        valid_out;  // Indica que el resultado está listo

    // ---- ENTRADAS/SALIDAS ORIGINALES (FPUControl ahora [1:0]) ----
    input  wire [31:0] SrcA;
    input  wire [31:0] SrcB;
    input  wire [1:0]  FPUControl; // 00 sum, 01 res, 10 mul, 11 div
    input  wire        precision;  // 0 = FP32, 1 = FP16
    output wire [31:0] FPUResult;
    output wire [4:0]  FPUFlags;    // {NV, DZ, OF, UF, NX}
    
    
    
    
    
    
    wire [31:0] core32_a_in = SrcA; // Core32 siempre usa los 32 bits completos
    wire [31:0] core32_b_in = SrcB;
    wire [15:0] core16_a_in = SrcA[15:0]; // Core16 usa los 16 bits bajos
    wire [15:0] core16_b_in = SrcB[15:0];

    // --- Mapeo de Control (FPUControl -> op) ---
    // Asumiendo que op[2] siempre es 0 (antes era ALU/FPU select)
    wire [2:0] core_op = {precision, FPUControl};

    // --- Instancia del Core FP32 ---
    wire [31:0] core32_result;
    wire [4:0]  core32_flags;
    wire        core32_valid;
    
    fp_core32 u_core32 (
        .clk(clk), .reset(reset),
        .start(start & ~precision),
        .round_mode(round_mode),
        .op(core_op),
        .a(core32_a_in), 
        .b(core32_b_in),
        .result(core32_result),
        .flags(core32_flags),
        .valid_out(core32_valid)
    );

    // --- Instancia del Core FP16 (¡NECESITAS CREAR ESTE MÓDULO!) ---
    // Debería tener una interfaz similar a fp_core32 pero operar internamente con 16 bits
    // Podría reutilizar fp_addsub_rne, etc. si son parametrizables, o necesitar versiones _fp16.
    wire [15:0] core16_result;
    wire [4:0]  core16_flags;
    wire        core16_valid;

// <<< PASO 1: DESCOMENTA ESTE BLOQUE >>>
    fp_core16 u_core16 (
        .clk(clk),
        .reset(reset), // Asegúrate que fp_core16 usa 'reset'
        .start(start & precision), // Activar solo si start=1 y precision=1
        .round_mode(round_mode), // Pasar modo de redondeo
        .op(core_op),
        .a(core16_a_in),
        .b(core16_b_in),
        .result(core16_result),
        .flags(core16_flags),
        .valid_out(core16_valid)
    );
    

    // --- Selección de Salidas basado en Precision ---
    wire [4:0]  selected_flags     = precision ? core16_flags : core32_flags;
    wire        selected_valid     = precision ? core16_valid : core32_valid;

// --- Formateo Final del Resultado (Directo) ---
    assign FPUResult = precision ? {16'h0000, core16_result} : core32_result; // <<< ASIGNA DIRECTAMENTE >>>

    // --- Asignación Final de Salidas ---
    assign FPUFlags   = selected_flags;
    assign valid_out  = selected_valid;

endmodule
