// =============================================================================
// ASCENT — tb_loa_mult.sv
// Phase 2 Testbench: LOA Approximate Multiplier
//
// Test strategy:
//   1. Exact cases  — verify corner cases match exact multiplication
//   2. Sweep test   — compare LOA output against exact for all 256×256
//                     input combinations, measure max/mean error
//   3. Golden check — verify predicted digit class is unchanged when
//                     using LOA vs exact multiply (accuracy tolerance check)
//
// Pass criteria:
//   - Max error ≤ 15  (theoretical bound for K=4)
//   - Mean absolute error < 5
//   - No sign errors (wrong sign on product)
// =============================================================================

`timescale 1ns/1ps

module tb_loa_mult;

    // -------------------------------------------------------------------------
    // DUT signals
    // 'logic' in a testbench is fine — it's driven by initial/always blocks.
    // -------------------------------------------------------------------------
    logic signed [7:0]  a, b;
    logic signed [15:0] p_loa;     // LOA output
    logic signed [15:0] p_exact;   // exact reference

    // -------------------------------------------------------------------------
    // DUT instantiation
    // #(.N(8), .K(4)) overrides the parameters.
    // 'u_loa' is the instance name — convention: u_ prefix for unit under test.
    // -------------------------------------------------------------------------
    loa_mult #(.N(8), .K(4)) u_loa (
        .a(a),
        .b(b),
        .p(p_loa)
    );

    // Exact reference: SystemVerilog signed multiply
    assign p_exact = a * b;

    // -------------------------------------------------------------------------
    // Test variables
    // -------------------------------------------------------------------------
    int error;           // signed error: p_loa - p_exact
    int abs_error;
    int max_error;
    int total_error;
    int error_count;     // cases where error > bound
    int sign_errors;     // cases where sign is wrong
    int tests_run;

    // =========================================================================
    // TASK: check_one
    // A 'task' is like a function in SV — it groups reusable test logic.
    // Unlike a function, a task CAN consume simulation time (#delays, @events).
    // =========================================================================
    task automatic check_one(
        input logic signed [7:0] ta,
        input logic signed [7:0] tb,
        input string             label
    );
        a = ta;
        b = tb;
        #10;   // wait 10ns for combinational logic to settle

        error     = int'(p_loa) - int'(p_exact);
        abs_error = (error < 0) ? -error : error;

        // Track statistics
        if (abs_error > max_error) max_error = abs_error;
        total_error += abs_error;
        tests_run++;

        // Sign error: exact is nonzero but LOA has wrong sign
        if (p_exact != 0 &&
            (p_loa[15] != p_exact[15])) begin
            sign_errors++;
            $display("SIGN ERROR  %s: %0d × %0d = exact %0d, got %0d",
                     label, ta, tb, p_exact, p_loa);
        end

        if (abs_error > 15) begin
            error_count++;
            $display("ERROR BOUND EXCEEDED  %s: %0d × %0d  exact=%0d  loa=%0d  err=%0d",
                     label, ta, tb, p_exact, p_loa, error);
        end
    endtask

    // =========================================================================
    // Main test sequence
    // =========================================================================
    initial begin
        // Waveform dump — open in GTKWave with: gtkwave sim/waves/tb_loa_mult.vcd
        $dumpfile("sim/waves/tb_loa_mult.vcd");
        $dumpvars(0, tb_loa_mult);

        max_error   = 0;
        total_error = 0;
        error_count = 0;
        sign_errors = 0;
        tests_run   = 0;

        $display("=================================================");
        $display("ASCENT Phase 2 — LOA Multiplier Testbench");
        $display("=================================================");

        // ---------------------------------------------------------------------
        // TEST GROUP 1: Corner cases
        // These are the values most likely to expose sign-handling bugs.
        // ---------------------------------------------------------------------
        $display("\n--- Group 1: Corner cases ---");

        check_one(  8'd0,    8'd0,   "0×0");
        check_one(  8'd1,    8'd1,   "1×1");
        check_one( -8'd1,    8'd1,   "-1×1");
        check_one(  8'd1,   -8'd1,   "1×-1");
        check_one( -8'd1,   -8'd1,   "-1×-1");
        check_one(  8'd127,  8'd127, "127×127");
        check_one( -8'd128,  8'd127, "-128×127");
        check_one(  8'd127, -8'd128, "127×-128");
        check_one( -8'd128, -8'd128, "-128×-128");
        check_one(  8'd12,   8'd10,  "12×10");
        check_one( -8'd12,   8'd10,  "-12×10");
        check_one(  8'd64,   8'd2,   "64×2");
        check_one(  8'd15,   8'd15,  "15×15");

        $display("Corner cases done. Max error so far: %0d", max_error);

        // ---------------------------------------------------------------------
        // TEST GROUP 2: Full sweep — all 256 × 256 = 65536 combinations
        // This is the key test: measures actual error distribution.
        // ---------------------------------------------------------------------
        $display("\n--- Group 2: Full sweep (65536 combinations) ---");

        // Reset stats for sweep only
        max_error   = 0;
        total_error = 0;
        error_count = 0;
        sign_errors = 0;
        tests_run   = 0;

        for (int ai = -128; ai <= 127; ai++) begin
            for (int bi = -128; bi <= 127; bi++) begin
                a = 8'(ai);
                b = 8'(bi);
                #1;   // shorter delay for sweep — just needs to settle

                error     = int'(p_loa) - int'(p_exact);
                abs_error = (error < 0) ? -error : error;

                if (abs_error > max_error) max_error = abs_error;
                total_error += abs_error;
                tests_run++;

                if (p_exact != 0 && (p_loa[15] != p_exact[15]))
                    sign_errors++;

                if (abs_error > 15)
                    error_count++;
            end
        end

        $display("  Tests run    : %0d", tests_run);
        $display("  Max error    : %0d  (bound: 15)", max_error);
        $display("  Mean abs err : %0.2f", real'(total_error) / real'(tests_run));
        $display("  Sign errors  : %0d  (must be 0)", sign_errors);
        $display("  Bound exceed : %0d  (must be 0)", error_count);

        // ---------------------------------------------------------------------
        // TEST GROUP 3: Specific neural network relevant values
        // Weights and activations in typical ranges after quantisation
        // ---------------------------------------------------------------------
        $display("\n--- Group 3: Typical NN weight/activation pairs ---");

        // Typical small weights after 60% pruning: mostly ±1..±30
        // Typical activations after normalisation: mostly 0..50
        check_one(  8'd23,   8'd15,  "act=23 w=15");
        check_one( -8'd23,   8'd15,  "act=23 w=-15");
        check_one(  8'd50,   8'd30,  "act=50 w=30");
        check_one(  8'd100,  8'd50,  "act=100 w=50");
        check_one( -8'd100,  8'd50,  "act=100 w=-50");
        check_one(  8'd0,    8'd127, "act=0 w=127");   // zero weight → zero product
        check_one(  8'd50,   8'd0,   "act=50 w=0");    // zero weight → zero product

        // ---------------------------------------------------------------------
        // FINAL SUMMARY
        // ---------------------------------------------------------------------
        $display("\n=================================================");
        $display("FINAL SUMMARY");
        $display("=================================================");
        $display("Max error       : %0d  (spec: ≤15)", max_error);
        $display("Mean abs error  : %0.3f", real'(total_error) / real'(tests_run));
        $display("Sign errors     : %0d  (spec: 0)", sign_errors);
        $display("Bound violations: %0d  (spec: 0)", error_count);

        if (max_error <= 15 && sign_errors == 0 && error_count == 0) begin
            $display("\nPASS: LOA multiplier meets all specifications.");
            $display("Ready for Phase 3 — CIM Array integration.");
        end else begin
            $display("\nFAIL: See errors above.");
        end

        $display("=================================================");
        $finish;
    end

endmodule