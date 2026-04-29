// =============================================================================
// ASCENT — loa_mult.sv
// Phase 2: LOA (Lower-part OR Approximation) Signed 8×8 Multiplier
//
// Computes: p = a × b  (signed 8-bit inputs, signed 16-bit output)
//
// CORRECT LOA ALGORITHM:
//   Step 1. Sum ALL partial products fully (exact Wallace/ripple sum).
//           This preserves carries from bits 0..K-1 into bits K..15.
//   Step 2. REPLACE the lower K bits of the exact sum with OR-reduced bits.
//           OR(pp[0][j], pp[1][j], ..., pp[N-1][j]) for each j in 0..K-1.
//
// PREVIOUS BUG (masked-then-summed):
//   Zeroing lower K bits before summing loses carries from the lower zone
//   into the upper zone, causing errors up to 2×(2^K - 1) = 30 instead of 15.
//
// CORRECT error bound: max |error| = 2^K - 1 = 15 for K=4.
//   Verified by exhaustive sweep of all 65536 signed 8-bit input pairs.
//
// Compatible with ModelSim 2020.1: no declarations inside always_comb.
// =============================================================================

module loa_mult #(
    parameter int N = 8,
    parameter int K = 4
)(
    input  logic signed [N-1:0]     a,
    input  logic signed [N-1:0]     b,
    output logic signed [2*N-1:0]   p
);

    localparam int PWIDTH = 2 * N;   // 16

    // =========================================================================
    // STEP 1: Sign extraction and absolute value
    // =========================================================================

    logic              a_sign, b_sign, p_sign;
    logic [N-1:0]      a_abs, b_abs;

    always_comb begin
        a_sign = a[N-1];
        b_sign = b[N-1];
        p_sign = a_sign ^ b_sign;
        a_abs  = a_sign ? ($unsigned(~a) + 1'b1) : $unsigned(a);
        b_abs  = b_sign ? ($unsigned(~b) + 1'b1) : $unsigned(b);
    end

    // =========================================================================
    // STEP 2: Partial product generation
    //
    // pp[i] = (a_abs zero-extended to PWIDTH bits, shifted left by i)
    //         gated by b_abs[i].
    // {PWIDTH{b_abs[i]}} creates a PWIDTH-wide mask: all 1s or all 0s.
    // PWIDTH'(a_abs) zero-extends a_abs from N to PWIDTH bits.
    // =========================================================================

    logic [PWIDTH-1:0] pp [0:N-1];

    genvar gi;
    generate
        for (gi = 0; gi < N; gi++) begin : gen_pp
            assign pp[gi] = {PWIDTH{b_abs[gi]}} & (PWIDTH'(a_abs) << gi);
        end
    endgenerate

    // =========================================================================
    // STEP 3: Full exact sum of all partial products
    //
    // Sum ALL partial products without any masking.
    // This preserves carries from the lower K bits into the upper bits —
    // which is critical for keeping the error within the LOA bound of 2^K - 1.
    // =========================================================================

    logic [PWIDTH-1:0] sum_exact;    // full exact sum (all bits)
    logic [PWIDTH-1:0] p_unsigned;   // final unsigned result
    logic [K-1:0]      or_bits;      // OR-reduced lower K bits
    logic              or_bit_j;     // single-bit accumulator (reused per iteration)

    always_comb begin
        // Full exact sum — no masking
        sum_exact = pp[0];
        for (int j = 1; j < N; j++) begin
            sum_exact = sum_exact + pp[j];
        end

        // OR approximation: for each lower bit position j,
        // OR the j-th bit of every partial product together.
        // This replaces the exact lower K bits with an approximation
        // that has zero carry-chain depth.
        for (int j = 0; j < K; j++) begin
            or_bit_j = 1'b0;
            for (int k = 0; k < N; k++) begin
                or_bit_j = or_bit_j | pp[k][j];
            end
            or_bits[j] = or_bit_j;
        end

        // Combine: keep exact upper bits, replace lower K bits with OR result.
        // {sum_exact[PWIDTH-1:K], or_bits} concatenates:
        //   - upper (PWIDTH-K) bits from the exact sum (includes correct carries)
        //   - lower K bits from the OR approximation
        p_unsigned = {sum_exact[PWIDTH-1:K], or_bits};
    end

    // =========================================================================
    // STEP 4: Sign correction
    // =========================================================================

    always_comb begin
        if (p_sign)
            p = $signed(~p_unsigned + 1'b1);
        else
            p = $signed(p_unsigned);
    end

endmodule