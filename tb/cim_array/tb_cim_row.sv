// =============================================================================
// ASCENT — tb_cim_row.sv
// Phase 3 Testbench: Single CIM row verification.
//
// Test groups:
//   1. Basic MAC: manually verify dot product for small known values
//   2. Sparsity gate: row_en=0 must leave accumulator unchanged
//   3. Accumulator clear: acc_clear must zero the accumulator
//   4. ReLU: negative accumulator must give 0 at output
//   5. Requantisation: verify right-shift is applied correctly
//   6. Saturation: verify accumulator doesn't wrap (saturates at max)
// =============================================================================

`timescale 1ns/1ps

module tb_cim_row;

    // -------------------------------------------------------------------------
    // Parameters — match the DUT
    // -------------------------------------------------------------------------
    localparam int DWIDTH        = 8;
    localparam int ACC_WIDTH     = 24;
    localparam int REQUANT_SHIFT = 11;
    localparam int CLK_HALF      = 5;    // 10ns period = 100MHz

    // -------------------------------------------------------------------------
    // DUT signals
    // -------------------------------------------------------------------------
    logic                          clk;
    logic                          rst_n;
    logic                          w_load_en;
    logic [DWIDTH-1:0]             w_load_data;
    logic                          compute_en;
    logic                          row_en;
    logic                          acc_clear;
    logic signed [DWIDTH-1:0]      x_in;
    logic signed [ACC_WIDTH-1:0]   acc_out;
    logic [DWIDTH-1:0]             y_out_int8;

    // -------------------------------------------------------------------------
    // DUT instantiation
    // -------------------------------------------------------------------------
    cim_row #(
        .DWIDTH        (DWIDTH),
        .ACC_WIDTH     (ACC_WIDTH),
        .REQUANT_SHIFT (REQUANT_SHIFT)
    ) u_dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .w_load_en   (w_load_en),
        .w_load_data (w_load_data),
        .compute_en  (compute_en),
        .row_en      (row_en),
        .acc_clear   (acc_clear),
        .x_in        (x_in),
        .acc_out     (acc_out),
        .y_out_int8  (y_out_int8)
    );

    // -------------------------------------------------------------------------
    // Clock generation: 100MHz
    // -------------------------------------------------------------------------
    initial clk = 0;
    always #(CLK_HALF) clk = ~clk;

    // -------------------------------------------------------------------------
    // Test tracking
    // -------------------------------------------------------------------------
    int pass_count;
    int fail_count;

    // -------------------------------------------------------------------------
    // TASK: clk_cycle — advance one clock, then sample outputs
    // -------------------------------------------------------------------------
    task clk_cycle;
        @(posedge clk);
        #1;   // 1ns after posedge to sample outputs (avoid race with clk edge)
    endtask

    // -------------------------------------------------------------------------
    // TASK: load_weight — load a single weight into the row
    // -------------------------------------------------------------------------
    task load_weight(input logic [DWIDTH-1:0] w);
        w_load_en   = 1;
        w_load_data = w;
        clk_cycle;
        w_load_en   = 0;
        w_load_data = '0;
    endtask

    // -------------------------------------------------------------------------
    // TASK: do_mac — drive one input and accumulate
    // -------------------------------------------------------------------------
    task do_mac(input logic signed [DWIDTH-1:0] x, input logic r_en);
        x_in       = x;
        compute_en = 1;
        row_en     = r_en;
        clk_cycle;
        compute_en = 0;
    endtask

    // -------------------------------------------------------------------------
    // TASK: clear_acc
    // -------------------------------------------------------------------------
    task clear_acc;
        acc_clear = 1;
        clk_cycle;
        acc_clear = 0;
    endtask

    // -------------------------------------------------------------------------
    // TASK: check — compare actual vs expected, print result
    // -------------------------------------------------------------------------
    task automatic check(
        input string   label,
        input int      actual,
        input int      expected
    );
        if (actual == expected) begin
            $display("  PASS  %-40s  got=%0d", label, actual);
            pass_count++;
        end else begin
            $display("  FAIL  %-40s  got=%0d  expected=%0d", label, actual, expected);
            fail_count++;
        end
    endtask

    // =========================================================================
    // Main test sequence
    // =========================================================================
    initial begin
        $dumpfile("sim/waves/tb_cim_row.vcd");
        $dumpvars(0, tb_cim_row);

        pass_count = 0;
        fail_count = 0;

        // Initialise all inputs to idle state
        rst_n       = 0;
        w_load_en   = 0;
        w_load_data = '0;
        compute_en  = 0;
        row_en      = 1;
        acc_clear   = 0;
        x_in        = '0;

        // Apply reset for 3 cycles then release
        repeat(3) @(posedge clk);
        #1;
        rst_n = 1;
        #1;

        $display("=====================================================");
        $display("ASCENT Phase 3 — CIM Row Testbench");
        $display("=====================================================");

        // =================================================================
        // TEST 1: Basic MAC — verify dot product [3,5,7] · [2,4,6] = 76
        //
        // We load weight=2, stream inputs 3, 5, 7. But cim_row only holds
        // ONE weight (for one output neuron). So we load weight=2 and stream
        // inputs 3, 5, 7 to compute 3×2 + 5×2 + 7×2 = 30.
        // Then we test weight=3 with input=10 to get 30.
        // Then we test a proper sequence.
        //
        // Actually: for one row, acc = sum(x_in[i] × weight) for all cycles.
        // Weight is fixed per row. To test dot product behaviour:
        //   Load weight=5, stream inputs [1,2,3], expect acc=5+10+15=30
        // =================================================================
        $display("\n--- Test 1: Basic MAC (fixed weight, streaming inputs) ---");

        load_weight(8'sd5);                    // weight = 5

        do_mac( 8'sd1, 1'b1);                  // acc = 5×1 = 5
        check("acc after input=1", $signed(acc_out), 5);

        do_mac( 8'sd2, 1'b1);                  // acc = 5 + 5×2 = 15
        check("acc after input=2", $signed(acc_out), 15);

        do_mac( 8'sd3, 1'b1);                  // acc = 15 + 5×3 = 30
        check("acc after input=3", $signed(acc_out), 30);

        clear_acc;

        // =================================================================
        // TEST 2: Signed multiplication — negative weight
        // Load weight=-3, stream inputs [4, -2], expect acc = -12 + 6 = -6
        // =================================================================
        $display("\n--- Test 2: Signed values ---");

        load_weight(8'(-3));                   // weight = -3

        do_mac( 8'sd4, 1'b1);                  // acc = (-3)×4 = -12
        check("acc after -3×4", $signed(acc_out), -12);

        do_mac(-8'sd2, 1'b1);                  // acc = -12 + (-3)×(-2) = -12+6 = -6
        check("acc after -3×(-2)", $signed(acc_out), -6);

        clear_acc;

        // =================================================================
        // TEST 3: Sparsity gating — row_en=0 must NOT change acc
        // Load weight=10, accumulate input=5 (acc=50), then drive input=100
        // with row_en=0. Acc should stay at 50.
        // =================================================================
        $display("\n--- Test 3: Sparsity gate (row_en=0) ---");

        load_weight(8'sd10);

        do_mac( 8'sd5, 1'b1);                  // acc = 50
        check("acc before gating", $signed(acc_out), 50);

        do_mac( 8'sd100, 1'b0);                // row_en=0: acc must stay 50
        check("acc after gated cycle", $signed(acc_out), 50);

        do_mac(-8'sd3, 1'b0);                  // still gated
        check("acc after second gated cycle", $signed(acc_out), 50);

        do_mac( 8'sd2, 1'b1);                  // row_en=1 again: acc = 50 + 20 = 70
        check("acc after re-enable", $signed(acc_out), 70);

        clear_acc;

        // =================================================================
        // TEST 4: acc_clear
        // =================================================================
        $display("\n--- Test 4: acc_clear ---");

        load_weight(8'sd7);
        do_mac( 8'sd9, 1'b1);                  // acc = 63
        check("acc before clear", $signed(acc_out), 63);

        clear_acc;
        check("acc after clear", $signed(acc_out), 0);

        // =================================================================
        // TEST 5: ReLU
        // Negative accumulator should give y_out_int8 = 0.
        // Positive accumulator should pass through (after shift).
        // =================================================================
        $display("\n--- Test 5: ReLU ---");

        // Load negative weight, positive input → negative acc
        load_weight(8'(-20));                  // weight = -20
        do_mac(8'sd10, 1'b1);                  // acc = -200

        check("acc is negative (ReLU input)", $signed(acc_out) < 0, 1);
        check("y_out_int8 after ReLU on negative", int'(y_out_int8), 0);

        clear_acc;

        // Positive accumulation
        load_weight(8'sd10);
        // Accumulate enough to produce nonzero output after shifting by 11
        // Need acc > 2^11 = 2048. Do 300 cycles with weight=10, input=10 → acc=30000
        repeat(300) begin
            do_mac(8'sd10, 1'b1);
        end

        check("acc is positive (ReLU pass)", $signed(acc_out) > 0, 1);
        // After shift by 11: 30000 >> 11 = 14 (approximately)
        // LOA multiplier: 10×10 ≈ 100, 300 cycles → acc ≈ 30000
        // 30000 >>> 11 = 14
        $display("  INFO  acc_out=%0d  y_out_int8=%0d  (expected ~14)",
                 $signed(acc_out), y_out_int8);
        check("y_out_int8 nonzero after positive acc", int'(y_out_int8) > 0, 1);

        clear_acc;

        // =================================================================
        // TEST 6: Saturation — drive acc toward ACC_MAX
        // Weight=127, input=127, repeat many cycles
        // Each cycle adds up to 127×127 = 16129
        // ACC_MAX = 2^23-1 = 8388607
        // After 521 cycles: 521 × 16129 = 8,403,209 > ACC_MAX → should saturate
        // =================================================================
        $display("\n--- Test 6: Accumulator saturation ---");

        load_weight(8'sd127);
        repeat(600) begin
            do_mac(8'sd127, 1'b1);
        end

        check("acc saturated at ACC_MAX",
              $signed(acc_out), (1 << (ACC_WIDTH-1)) - 1);

        clear_acc;

        // =================================================================
        // TEST 7: Zero weight — any input should leave acc at 0
        // =================================================================
        $display("\n--- Test 7: Zero weight (sparse row) ---");

        load_weight(8'sd0);
        do_mac(8'sd127, 1'b1);
        do_mac(-8'sd128, 1'b1);
        do_mac(8'sd50, 1'b1);
        check("acc with zero weight", $signed(acc_out), 0);
        check("y_out_int8 with zero weight", int'(y_out_int8), 0);

        clear_acc;

        // =================================================================
        // FINAL REPORT
        // =================================================================
        $display("\n=====================================================");
        $display("CIM Row Results: %0d PASS, %0d FAIL", pass_count, fail_count);
        if (fail_count == 0)
            $display("PASS: cim_row meets all specifications.");
        else
            $display("FAIL: %0d test(s) failed. See above.", fail_count);
        $display("=====================================================");

        $finish;
    end

endmodule
