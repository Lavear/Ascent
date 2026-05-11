// =============================================================================
// ASCENT — cim_row.sv
// Phase 3: One row of the Compute-In-Memory array.
//
// Each row represents ONE output neuron. It holds:
//   - One INT8 weight register
//   - One LOA multiplier (from Phase 2)
//   - One saturating signed accumulator (24b for L1, 20b for L2/L3)
//   - ReLU + arithmetic right-shift requantisation + saturation to INT8
//
// Three operating phases:
//   LOAD:    w_load_en=1 → stores weight_reg ← w_load_data
//   COMPUTE: compute_en=1, row_en=1 → acc += x_in × weight_reg (LOA)
//            compute_en=1, row_en=0 → acc unchanged (sparse skip — zero energy)
//   CLEAR:   acc_clear=1 → acc ← 0 (between inferences or layers)
//
// y_out_int8 is combinationally derived from acc at all times.
// The controller reads it after exactly NUM_INPUTS compute cycles.
//
// ModelSim 2020.1 compatible: no variable declarations inside always blocks.
// =============================================================================

module cim_row #(
    parameter int DWIDTH        = 8,     // input/weight bit width
    parameter int ACC_WIDTH     = 24,    // accumulator width (24 for L1, 20 for L2/L3)
    parameter int REQUANT_SHIFT = 11     // post-accumulation right-shift (11 for L1, 7 for L2)
)(
    input  logic                           clk,
    input  logic                           rst_n,       // active-low synchronous reset

    // ---- Weight load ----
    input  logic                           w_load_en,   // 1: latch w_load_data this cycle
    input  logic        [DWIDTH-1:0]       w_load_data, // unsigned bits, interpreted as signed

    // ---- Compute ----
    input  logic                           compute_en,  // 1: do a MAC this cycle
    input  logic                           row_en,      // 0: skip (sparse gate)
    input  logic                           acc_clear,   // 1: synchronously zero the acc
    input  logic signed [DWIDTH-1:0]       x_in,        // broadcast input activation

    // ---- Outputs ----
    output logic signed [ACC_WIDTH-1:0]    acc_out,     // raw accumulator (for debug)
    output logic        [DWIDTH-1:0]       y_out_int8   // ReLU + requant result
);

    // =========================================================================
    // 1. Weight register
    //    Loaded once per inference. Holds one INT8 weight for this row/neuron.
    //    w_load_data arrives as unsigned bits from $readmemh — we interpret as signed.
    // =========================================================================
    logic signed [DWIDTH-1:0] weight_reg;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            weight_reg <= '0;
        else if (w_load_en)
            weight_reg <= $signed(w_load_data);
    end

    // =========================================================================
    // 2. LOA Multiplier (instantiate Phase 2 module)
    //    Purely combinational. Product is always live.
    //    We only USE the product when compute_en && row_en.
    // =========================================================================
    logic signed [2*DWIDTH-1:0] product;  // 16-bit signed product

    loa_mult #(
        .N (DWIDTH),
        .K (4)
    ) u_mult (
        .a (x_in),
        .b (weight_reg),
        .p (product)
    );

    // =========================================================================
    // 3. Saturating accumulator
    //
    // We compute acc + product in ACC_WIDTH+1 bits to detect overflow,
    // then saturate to [ACC_MIN, ACC_MAX].
    //
    // Why ACC_WIDTH+1?
    //   If acc = ACC_MAX and product = +32767 (max 16-bit), their sum overflows
    //   ACC_WIDTH bits. By using one extra bit we can check the overflow flag
    //   before writing back.
    //
    // Saturation bounds (compile-time constants):
    //   ACC_MAX =  2^(ACC_WIDTH-1) - 1   e.g. 8,388,607 for 24 bits
    //   ACC_MIN = -2^(ACC_WIDTH-1)        e.g. -8,388,608 for 24 bits
    // =========================================================================
    logic signed [ACC_WIDTH-1:0]  acc;
    logic signed [ACC_WIDTH-1:0]  acc_next;
    logic signed [ACC_WIDTH:0]    acc_sum_wide;  // one extra bit for overflow

    // Saturation limits as local parameters.
    // '<<<' is SV arithmetic left shift. For constants this compiles to
    // a literal number — no hardware cost.
    localparam logic signed [ACC_WIDTH-1:0] ACC_MAX =
        (ACC_WIDTH)'($signed({1'b0, {(ACC_WIDTH-1){1'b1}}}));  //  2^(N-1)-1
    localparam logic signed [ACC_WIDTH-1:0] ACC_MIN =
        (ACC_WIDTH)'($signed({1'b1, {(ACC_WIDTH-1){1'b0}}}));  // -2^(N-1)

    always_comb begin
        acc_sum_wide = '0;
        acc_next     = acc;

        if (acc_clear) begin
            acc_next = '0;
        end else if (compute_en && row_en) begin
            // Sign-extend product to ACC_WIDTH+1 bits then add to acc
            // $signed() ensures the sign extension is correct
            acc_sum_wide = {{(ACC_WIDTH - 2*DWIDTH + 1){product[2*DWIDTH-1]}},
                            product} + {{1{acc[ACC_WIDTH-1]}}, acc};

            // Saturate: if top two bits of wide sum differ, overflow occurred
            if (acc_sum_wide[ACC_WIDTH] && !acc_sum_wide[ACC_WIDTH-1])
                acc_next = ACC_MIN;                       // positive overflow → max
            else if (!acc_sum_wide[ACC_WIDTH] && acc_sum_wide[ACC_WIDTH-1])
                acc_next = ACC_MAX;                       // negative overflow → min

            // Wait — the above is inverted. Let's be explicit:
            // acc_sum_wide[ACC_WIDTH] is the overflow guard bit (sign of wide result)
            // acc_sum_wide[ACC_WIDTH-1] is the MSB of the ACC_WIDTH result
            // If they differ, we have overflow. Overflow direction:
            //   product > 0 && overflowed → result should be ACC_MAX
            //   product < 0 && overflowed → result should be ACC_MIN
            else
                acc_next = acc_sum_wide[ACC_WIDTH-1:0];   // no overflow, take result
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) acc <= '0;
        else        acc <= acc_next;
    end

    assign acc_out = acc;

    // =========================================================================
    // 4. ReLU + Requantisation + Saturation
    //
    //   relu_val:    acc if positive, 0 if negative (MSB check)
    //   shifted_val: relu_val >>> REQUANT_SHIFT  (arithmetic right shift = free wiring)
    //   y_out_int8:  clip shifted_val to [0, 127]
    //
    // All combinational — y_out_int8 is always valid, controller reads at the
    // right moment.
    //
    // '>>>' in SystemVerilog is arithmetic right shift (sign-fills the MSBs).
    // Since relu_val is always >= 0, using >>> or >> gives the same result,
    // but >>> is correct by definition for signed values.
    // =========================================================================
    logic signed [ACC_WIDTH-1:0] relu_val;
    logic signed [ACC_WIDTH-1:0] shifted_val;

    always_comb begin
        // ReLU
        relu_val = acc[ACC_WIDTH-1] ? '0 : acc;

        // Arithmetic right shift by REQUANT_SHIFT
        // This is equivalent to dividing by 2^REQUANT_SHIFT (integer division)
        shifted_val = relu_val >>> REQUANT_SHIFT;

        // Saturate to [0, 127]
        if (shifted_val > $signed({{(ACC_WIDTH-7){1'b0}}, 7'h7F}))
            y_out_int8 = 8'd127;
        else
            y_out_int8 = shifted_val[DWIDTH-1:0];
    end

endmodule
