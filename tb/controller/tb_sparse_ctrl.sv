// =============================================================================
// ASCENT — tb_sparse_ctrl.sv
// Phase 4 Testbench: Sparse Controller FSM verification.
// =============================================================================

`timescale 1ns/1ps

module tb_sparse_ctrl;
    localparam int DWIDTH    = 8;
    localparam int L1_ROWS   = 128;
    localparam int L1_INPUTS = 784;
    localparam int L2_ROWS   = 64;
    localparam int L2_INPUTS = 128;
    localparam int L3_ROWS   = 10;
    localparam int L3_INPUTS = 64;
    localparam int CLK_HALF  = 5;

    // -------------------------------------------------------------------------
    // DUT signals
    // -------------------------------------------------------------------------
    logic        clk, rst_n;
    logic        start;
    logic [7:0]  pixel_in;
    logic        pixel_valid;
    logic        w_load_en;
    logic [6:0]  w_load_addr;
    logic [7:0]  w_load_data;
    logic        compute_en;
    logic        acc_clear;
    logic signed [7:0] x_out;
    logic [L1_ROWS-1:0] row_en_l1;
    logic [L2_ROWS-1:0] row_en_l2;
    logic [L3_ROWS-1:0] row_en_l3;
    logic [1:0]  layer_sel;
    logic        y_valid;
    logic [L1_ROWS-1:0][7:0] l1_out;
    logic [L2_ROWS-1:0][7:0] l2_out;
    logic [L3_ROWS-1:0][7:0] l3_out;
    logic [3:0]  pred_class;
    logic        output_valid;

    // -------------------------------------------------------------------------
    // DUT
    // -------------------------------------------------------------------------
    sparse_ctrl #(
        .DWIDTH    (DWIDTH),
        .L1_ROWS   (L1_ROWS),
        .L1_INPUTS (L1_INPUTS),
        .L2_ROWS   (L2_ROWS),
        .L2_INPUTS (L2_INPUTS),
        .L3_ROWS   (L3_ROWS),
        .L3_INPUTS (L3_INPUTS)
    ) u_dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .start        (start),
        .pixel_in     (pixel_in),
        .pixel_valid  (pixel_valid),
        .w_load_en    (w_load_en),
        .w_load_addr  (w_load_addr),
        .w_load_data  (w_load_data),
        .compute_en   (compute_en),
        .acc_clear    (acc_clear),
        .x_out        (x_out),
        .row_en_l1    (row_en_l1),
        .row_en_l2    (row_en_l2),
        .row_en_l3    (row_en_l3),
        .layer_sel    (layer_sel),
        .y_valid      (y_valid),
        .l1_out       (l1_out),
        .l2_out       (l2_out),
        .l3_out       (l3_out),
        .pred_class   (pred_class),
        .output_valid (output_valid)
    );

    // -------------------------------------------------------------------------
    // Clock
    // -------------------------------------------------------------------------
    initial clk = 0;
    always #CLK_HALF clk = ~clk;

    task clk_cycle; @(posedge clk); #1;
    endtask

    // Fake layer outputs — all zeros except one high score for L3
    initial begin
        l1_out = '0;
        l2_out = '0;
        l3_out = '0;
        l3_out[7] = 8'd100;    // Class 7 wins argmax
    end

    // -------------------------------------------------------------------------
    // Test tracking
    // -------------------------------------------------------------------------
    int pass_count, fail_count;
    
    task automatic check(input string lbl, input int got, input int exp);
        if (got === exp) begin
            $display("  PASS  %-45s got=%0d", lbl, got);
            pass_count++;
        end else begin
            $display("  FAIL  %-45s got=%0d  exp=%0d", lbl, got, exp);
            fail_count++;
        end
    endtask

    // =========================================================================
    // Main
    // =========================================================================
    initial begin
        $dumpfile("sim/waves/tb_sparse_ctrl.vcd");
        $dumpvars(0, tb_sparse_ctrl);

        pass_count = 0; fail_count = 0;

        rst_n       = 0;
        start       = 0;
        pixel_in    = '0;
        pixel_valid = 0;
        y_valid     = 0;

        repeat(3) @(posedge clk); #1;
        rst_n = 1; #1;

        $display("=====================================================");
        $display("ASCENT Phase 4 — Sparse Controller Testbench");
        $display("=====================================================");

        // -----------------------------------------------------------------
        // TEST 1: FSM starts in IDLE, nothing changes until start
        // -----------------------------------------------------------------
        $display("\n--- Test 1: IDLE state ---");
        clk_cycle;
        check("w_load_en idle",  int'(w_load_en),  0);
        check("compute_en idle", int'(compute_en), 0);
        check("acc_clear idle",  int'(acc_clear),  0);
        
        // -----------------------------------------------------------------
        // TEST 2: Start + receive 784 pixels
        // -----------------------------------------------------------------
        $display("\n--- Test 2: Pixel reception ---");
        start = 1; clk_cycle; start = 0;

        // Send 784 pixel bytes one per cycle
        for (int i = 0; i < L1_INPUTS; i++) begin
            pixel_in    = 8'(i & 8'hFF); // incrementing test pattern
            pixel_valid = 1;
            clk_cycle;
        end
        pixel_valid = 0;
        
        // After 784 pixels, should transition to CLR_ACC
        clk_cycle;
        check("acc_clear after pixels received", int'(acc_clear), 1);

        // -----------------------------------------------------------------
        // TEST 3: LOAD_W phase for column 0
        // After CLR_ACC, should start loading weights
        // w_load_en should pulse, address goes 0,1,2,...,127
        // -----------------------------------------------------------------
        $display("\n--- Test 3: Weight load phase ---");
        clk_cycle;    // exit CLR_ACC

        // Check first few weight-load cycles
        for (int j = 0; j < 5; j++) begin
            check($sformatf("w_load_en row %0d", j), int'(w_load_en), 1);
            check($sformatf("w_load_addr row %0d", j), int'(w_load_addr), j);
            clk_cycle;
        end

        // Fast-forward through remaining weight loads for col 0
        repeat(123) clk_cycle;
        
        // -----------------------------------------------------------------
        // TEST 4: COMPUTE cycle for column 0
        // -----------------------------------------------------------------
        $display("\n--- Test 4: Compute cycle ---");
        check("compute_en col 0", int'(compute_en), 1);
        check("layer_sel = 0 (L1)", int'(layer_sel), 0);
        clk_cycle;
        
        // -----------------------------------------------------------------
        // TEST 5: Continue through all 784 columns
        // -----------------------------------------------------------------
        $display("\n--- Test 5: Full L1 compute (fast forward) ---");
        $display("  Fast forwarding through %0d columns...", L1_INPUTS-1);

        // Fast-forward 783 more columns
        repeat((L1_INPUTS-1) * (L1_ROWS + 2)) clk_cycle;
        
        // FSM is in ADV_COL. Give it 1 cycle to enter WAIT_V
        clk_cycle;

        // Assert y_valid to signal L1 complete (FSM moves to CAPTURE)
        y_valid = 1; clk_cycle; y_valid = 0;
        
        // Give FSM 1 cycle to execute CAPTURE state and physically update layer_sel to 1
        clk_cycle; 
        check("layer_sel transitions to 1 (L2)", int'(layer_sel), 1);
        
        // Give FSM 1 cycle to exit CLR_ACC and enter LOAD_W
        clk_cycle; 
        
        // -----------------------------------------------------------------
        // TEST 6: L2 completes, L3 begins
        // -----------------------------------------------------------------
        $display("\n--- Test 6: Layer transitions ---");
        
        // Fast-forward L2. Starting from LOAD_W(0), this math lands EXACTLY in WAIT_V.
        repeat(L2_INPUTS * (L2_ROWS + 2)) clk_cycle;
        y_valid = 1; clk_cycle; y_valid = 0;
        
        // Give FSM 1 cycle to execute CAPTURE state and update layer_sel to 2
        clk_cycle;
        check("layer_sel transitions to 2 (L3)", int'(layer_sel), 2);
        
        // Give FSM 1 cycle to exit CLR_ACC and enter LOAD_W
        clk_cycle;
        
        // Fast-forward L3. Lands EXACTLY in WAIT_V.
        repeat(L3_INPUTS * (L3_ROWS + 2)) clk_cycle;
        y_valid = 1; clk_cycle; y_valid = 0; // FSM enters CAPTURE

        // -----------------------------------------------------------------
        // TEST 7: output_valid and pred_class
        // -----------------------------------------------------------------
        $display("\n--- Test 7: Output ---");
        
        // FSM is currently in CAPTURE.
        // 1 clk: CAPTURE -> ARGMAX
        // 1 clk: ARGMAX -> DONE
        // 1 clk: DONE -> executes, output_valid asserts!
        repeat(3) clk_cycle;
        
        check("output_valid asserted", int'(output_valid), 1);
        check("pred_class = 7 (argmax of l3_out)", int'(pred_class), 7);
        
        // -----------------------------------------------------------------
        // REPORT
        // -----------------------------------------------------------------
        $display("\n=====================================================");
        $display("Sparse Ctrl: %0d PASS  %0d FAIL", pass_count, fail_count);
        if (fail_count == 0)
            $display("PASS: sparse_ctrl FSM verified.");
        else
            $display("FAIL: see above.");
        $display("=====================================================");
        $finish;
    end

endmodule