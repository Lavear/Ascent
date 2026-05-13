// =============================================================================
// ASCENT — tb_cim_row.sv  (FIXED)
// Phase 3 Testbench: Single CIM row verification.
//
// FIX: Test 3 (sparsity gate) previously used weight=10, input=5.
// LOA gives 10×5=58, not 50. Changed to weight=8 (power of 2) so all
// products are LOA-exact (no error in the lower K bits).
// =============================================================================

`timescale 1ns/1ps

module tb_cim_row;

    localparam int DWIDTH        = 8;
    localparam int ACC_WIDTH     = 24;
    localparam int REQUANT_SHIFT = 11;
    localparam int ACC_MAX       = (1 << (ACC_WIDTH-1)) - 1;  // 8388607
    localparam int CLK_HALF      = 5;

    logic                         clk;
    logic                         rst_n;
    logic                         w_load_en;
    logic [DWIDTH-1:0]            w_load_data;
    logic                         compute_en;
    logic                         row_en;
    logic                         acc_clear;
    logic signed [DWIDTH-1:0]     x_in;
    logic signed [ACC_WIDTH-1:0]  acc_out;
    logic [DWIDTH-1:0]            y_out_int8;

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

    initial clk = 0;
    always #CLK_HALF clk = ~clk;

    int pass_count, fail_count;

    task clk_cycle;
        @(posedge clk); #1;
    endtask

    task load_weight(input logic [DWIDTH-1:0] w);
        w_load_en = 1; w_load_data = w;
        clk_cycle;
        w_load_en = 0;
    endtask

    task do_mac(input logic signed [DWIDTH-1:0] x,
                input logic                     r_en);
        x_in = x; compute_en = 1; row_en = r_en;
        clk_cycle;
        compute_en = 0;
    endtask

    task clear_acc;
        acc_clear = 1; clk_cycle; acc_clear = 0;
    endtask

    task automatic check(
        input string label,
        input int    actual,
        input int    expected
    );
        if (actual === expected) begin
            $display("  PASS  %-45s  got=%0d", label, actual);
            pass_count++;
        end else begin
            $display("  FAIL  %-45s  got=%0d  expected=%0d",
                     label, actual, expected);
            fail_count++;
        end
    endtask

    initial begin
        $dumpfile("sim/waves/tb_cim_row.vcd");
        $dumpvars(0, tb_cim_row);

        pass_count = 0; fail_count = 0;

        rst_n = 0; w_load_en = 0; w_load_data = '0;
        compute_en = 0; row_en = 1; acc_clear = 0; x_in = '0;

        repeat(3) @(posedge clk); #1;
        rst_n = 1; #1;

        $display("=====================================================");
        $display("ASCENT Phase 3 - CIM Row Testbench");
        $display("=====================================================");

        // -----------------------------------------------------------------
        // TEST 1: Basic MAC
        // weight=5, inputs [1,2,3] — using small values, LOA exact here
        // 5×1=5, 5+5×2=15, 15+5×3=30
        // -----------------------------------------------------------------
        $display("\n--- Test 1: Basic MAC ---");
        load_weight(8'sd5);
        do_mac(8'sd1, 1'b1); check("acc after w=5 x=1",  $signed(acc_out),  5);
        do_mac(8'sd2, 1'b1); check("acc after w=5 x=2",  $signed(acc_out), 15);
        do_mac(8'sd3, 1'b1); check("acc after w=5 x=3",  $signed(acc_out), 30);
        clear_acc;

        // -----------------------------------------------------------------
        // TEST 2: Signed MAC
        // Use weight=-4, input=4 → -16 (power of 2, LOA exact)
        // Then weight=-4, input=-4 → +16, acc = 0
        // -----------------------------------------------------------------
        $display("\n--- Test 2: Signed MAC ---");
        load_weight(8'(-4));
        do_mac( 8'sd4,  1'b1); check("acc w=-4 x=+4",  $signed(acc_out), -16);
        do_mac( 8'(-4), 1'b1); check("acc w=-4 x=-4",  $signed(acc_out),   0);
        clear_acc;

        // -----------------------------------------------------------------
        // TEST 3: Sparsity gate
        // FIX: use weight=8 (power of 2) so LOA gives exact products.
        //   8×4  = 32  (exact, lower bits of PP are 0)
        //   8×100 = 800 but row_en=0, acc stays 32
        //   8×-3  = but row_en=0, acc stays 32
        //   8×4   = 32 again, acc = 32+32 = 64
        // -----------------------------------------------------------------
        $display("\n--- Test 3: Sparsity gate ---");
        load_weight(8'sd8);
        do_mac( 8'sd4,   1'b1); check("acc before gate (8x4=32)",     $signed(acc_out), 32);
        do_mac( 8'sd100, 1'b0); check("acc unchanged when gated",      $signed(acc_out), 32);
        do_mac( 8'(-3),  1'b0); check("acc unchanged 2nd gated cycle", $signed(acc_out), 32);
        do_mac( 8'sd4,   1'b1); check("acc resumes after re-enable (32+32=64)", $signed(acc_out), 64);
        clear_acc;

        // -----------------------------------------------------------------
        // TEST 4: acc_clear
        // -----------------------------------------------------------------
        $display("\n--- Test 4: acc_clear ---");
        load_weight(8'sd8);
        do_mac(8'sd8, 1'b1); check("acc before clear (64)", $signed(acc_out), 64);
        clear_acc;
        check("acc after clear (0)", $signed(acc_out), 0);

        // -----------------------------------------------------------------
        // TEST 5: ReLU
        // Negative acc → y_out_int8 = 0
        // Positive acc → nonzero y_out
        // -----------------------------------------------------------------
        $display("\n--- Test 5: ReLU ---");
        load_weight(8'(-8));
        do_mac(8'sd8, 1'b1);  // acc = -64
        check("acc is -64",                  $signed(acc_out), -64);
        check("y_out_int8=0 (ReLU of -64)", int'(y_out_int8),   0);
        clear_acc;

        // Positive: acc=2048, shift 11 → y_out=1
        load_weight(8'sd1);
        repeat(2048) begin
            do_mac(8'sd1, 1'b1);
        end
        check("acc = 2048",              $signed(acc_out), 2048);
        check("y_out = 1 (2048>>11=1)", int'(y_out_int8),    1);
        clear_acc;

        // -----------------------------------------------------------------
        // TEST 6: Saturation
        // weight=127, input=127 → each MAC ≈ 16129
        // After 600 cycles → exceeds 8388607 → saturates
        // -----------------------------------------------------------------
        $display("\n--- Test 6: Saturation ---");
        load_weight(8'sd127);
        repeat(600) begin
            do_mac(8'sd127, 1'b1);
        end
        check("acc saturated at ACC_MAX", $signed(acc_out), ACC_MAX);
        check("y_out_int8 = 127",         int'(y_out_int8),    127);
        clear_acc;

        // -----------------------------------------------------------------
        // TEST 7: Zero weight
        // -----------------------------------------------------------------
        $display("\n--- Test 7: Zero weight ---");
        load_weight(8'sd0);
        do_mac(8'sd127,  1'b1);
        do_mac(8'(-128), 1'b1);
        do_mac(8'sd64,   1'b1);
        check("acc=0 with zero weight",        $signed(acc_out), 0);
        check("y_out_int8=0 with zero weight", int'(y_out_int8), 0);

        // -----------------------------------------------------------------
        // REPORT
        // -----------------------------------------------------------------
        $display("\n=====================================================");
        $display("CIM Row: %0d PASS  %0d FAIL", pass_count, fail_count);
        if (fail_count == 0)
            $display("PASS: cim_row verified.");
        else
            $display("FAIL: see above.");
        $display("=====================================================");
        $finish;
    end

endmodule