// =============================================================================
// ASCENT — tb_ascent_top.sv  (FIXED)
// Phase 4b: End-to-End Top-Level Testbench
//
// FIX: start pulse fires one cycle BEFORE the first pixel.
// On cycle 0 (start=1): FSM transitions IDLE → RECV_PIX (registered).
// On cycle 1 (pixel_valid=1, pixel 0): FSM is now in RECV_PIX → buffers it.
// All 784 pixels are correctly received.
//
// Bypasses UART for simulation speed — directly injects pixels into
// sparse_ctrl at 1 pixel per cycle instead of UART baud rate.
// =============================================================================

`timescale 1ns/1ps

module tb_ascent_top;

    localparam int CLK_FREQ  = 50_000_000;
    localparam int BAUD_RATE = 115200;
    localparam int CLK_HALF  = 10;
    localparam int L1_INPUTS = 784;

    logic       clk, rst_n;
    logic       uart_rx;
    logic       uart_tx;
    logic [3:0] pred_leds;
    logic [7:0] tb_pixel_in;
    logic       tb_pixel_valid;
    logic       tb_start;

    ascent_top_tb_wrap #(
        .CLK_FREQ  (CLK_FREQ),
        .BAUD_RATE (BAUD_RATE)
    ) u_dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .uart_rx       (uart_rx),
        .uart_tx       (uart_tx),
        .pred_leds     (pred_leds),
        .tb_pixel_in   (tb_pixel_in),
        .tb_pixel_valid(tb_pixel_valid),
        .tb_start      (tb_start)
    );

    initial clk = 0;
    always #CLK_HALF clk = ~clk;

    task clk_cycle; @(posedge clk); #1;
    endtask

    logic [7:0] test_pixels [0:L1_INPUTS-1];

    int wait_cnt;
    int pass_count, fail_count;

    task automatic check(input string lbl, input int got, input int exp);
        if (got === exp) begin
            $display("  PASS  %-50s  got=%0d", lbl, got);
            pass_count++;
        end else begin
            $display("  FAIL  %-50s  got=%0d  exp=%0d", lbl, got, exp);
            fail_count++;
        end
    endtask

    initial begin
        $dumpfile("sim/waves/tb_ascent_top.vcd");
        $dumpvars(0, tb_ascent_top);

        pass_count     = 0;
        fail_count     = 0;
        wait_cnt       = 0;
        rst_n          = 0;
        uart_rx        = 1'b1;
        tb_pixel_in    = '0;
        tb_pixel_valid = 0;
        tb_start       = 0;

        repeat(5) @(posedge clk); #1;
        rst_n = 1; #1;

        $display("=====================================================");
        $display("ASCENT Phase 4b - End-to-End Testbench");
        $display("=====================================================");

        $display("\nLoading python/outputs/test_inputs.hex...");
        $readmemh("python/outputs/test_inputs.hex", test_pixels, 0, L1_INPUTS-1);
        $display("  Loaded %0d pixel bytes. Expected class: 7", L1_INPUTS);

        // -----------------------------------------------------------------
        // Step 1: Assert start for ONE cycle — FSM transitions IDLE→RECV_PIX
        // -----------------------------------------------------------------
        $display("\nSending start pulse...");
        tb_start = 1;
        clk_cycle;          // FSM: IDLE → RECV_PIX (registered at this posedge)
        tb_start = 0;

        // -----------------------------------------------------------------
        // Step 2: Inject 784 pixels — FSM is now in RECV_PIX, ready to buffer
        // -----------------------------------------------------------------
        $display("Injecting 784 pixels...");
        for (int i = 0; i < L1_INPUTS; i++) begin
            tb_pixel_in    = test_pixels[i];
            tb_pixel_valid = 1;
            clk_cycle;
        end
        tb_pixel_valid = 0;
        tb_pixel_in    = '0;

        $display("  Pixels injected. Waiting for inference (~310K cycles)...");

        // -----------------------------------------------------------------
        // Wait for output_valid
        // -----------------------------------------------------------------
        wait_cnt = 0;
        while (!u_dut.output_valid && wait_cnt < 2_000_000) begin
            clk_cycle;
            wait_cnt++;
        end

        if (wait_cnt >= 2_000_000) begin
            $display("  FAIL: Inference timed out (2M cycles)");
            $display("  Debug: layer_sel=%0d  y_valid_active=%0b",
                     u_dut.layer_sel, u_dut.y_valid_active);
            fail_count++;
        end else begin
            $display("  Done in %0d cycles.", wait_cnt + L1_INPUTS + 6);
        end

        // -----------------------------------------------------------------
        // Check result
        // -----------------------------------------------------------------
        $display("\n--- Results ---");
        $display("  pred_class   = %0d", u_dut.pred_class);
        $display("  pred_leds    = %04b (%0d)", pred_leds, pred_leds);
        $display("  output_valid = %0b",  u_dut.output_valid);

        check("pred_class == 7", int'(u_dut.pred_class), 7);
        check("pred_leds  == 7", int'(pred_leds),        7);

        $display("\n=====================================================");
        $display("Top Level: %0d PASS  %0d FAIL", pass_count, fail_count);
        if (fail_count == 0)
            $display("PASS: End-to-end inference verified.");
        else
            $display("FAIL: %0d test(s) failed.", fail_count);
        $display("=====================================================");
        $finish;
    end

endmodule


// =============================================================================
// ascent_top_tb_wrap — adds direct-injection bypass ports to ascent_top
// =============================================================================

module ascent_top_tb_wrap #(
    parameter int CLK_FREQ  = 50_000_000,
    parameter int BAUD_RATE = 115200
)(
    input  logic       clk,
    input  logic       rst_n,
    input  logic       uart_rx,
    output logic       uart_tx,
    output logic [3:0] pred_leds,
    input  logic [7:0] tb_pixel_in,
    input  logic       tb_pixel_valid,
    input  logic       tb_start
);

    localparam int DWIDTH    = 8;
    localparam int L1_ROWS   = 128;
    localparam int L1_INPUTS = 784;
    localparam int L2_ROWS   = 64;
    localparam int L2_INPUTS = 128;
    localparam int L3_ROWS   = 10;
    localparam int L3_INPUTS = 64;

    // Expose for testbench probing
    logic [3:0] pred_class;
    logic       output_valid;
    logic [1:0] layer_sel;
    logic       y_valid_active;

    // UART TX
    logic [7:0] tx_data;
    logic       tx_start;
    logic       tx_busy;

    uart_tx #(.CLK_FREQ(CLK_FREQ), .BAUD_RATE(BAUD_RATE)) u_tx (
        .clk(clk), .rst_n(rst_n),
        .tx_data(tx_data), .tx_start(tx_start),
        .tx(uart_tx), .tx_busy(tx_busy)
    );

    // CIM signals
    logic        w_load_en;
    logic [6:0]  w_load_addr;
    logic [7:0]  w_load_data;
    logic        compute_en;
    logic        acc_clear;
    logic signed [7:0] x_out;

    logic [L1_ROWS-1:0] row_en_l1;
    logic [L2_ROWS-1:0] row_en_l2;
    logic [L3_ROWS-1:0] row_en_l3;

    logic [L1_ROWS-1:0][7:0] l1_out;
    logic [L2_ROWS-1:0][7:0] l2_out;
    logic [L3_ROWS-1:0][7:0] l3_out;

    logic y_valid_l1, y_valid_l2, y_valid_l3;

    always_comb begin
        case (layer_sel)
            2'd0:    y_valid_active = y_valid_l1;
            2'd1:    y_valid_active = y_valid_l2;
            2'd2:    y_valid_active = y_valid_l3;
            default: y_valid_active = y_valid_l1;
        endcase
    end

    // Layer-gated enables
    logic w_en_l1, w_en_l2, w_en_l3;
    logic ce_l1,  ce_l2,  ce_l3;
    logic ac_l1,  ac_l2,  ac_l3;

    assign w_en_l1 = w_load_en  & (layer_sel == 2'd0);
    assign w_en_l2 = w_load_en  & (layer_sel == 2'd1);
    assign w_en_l3 = w_load_en  & (layer_sel == 2'd2);
    assign ce_l1   = compute_en & (layer_sel == 2'd0);
    assign ce_l2   = compute_en & (layer_sel == 2'd1);
    assign ce_l3   = compute_en & (layer_sel == 2'd2);
    assign ac_l1   = acc_clear  & (layer_sel == 2'd0);
    assign ac_l2   = acc_clear  & (layer_sel == 2'd1);
    assign ac_l3   = acc_clear  & (layer_sel == 2'd2);

    cim_array #(.DWIDTH(8),.ROWS(L1_ROWS),.ACC_WIDTH(24),.REQUANT_SHIFT(11),.NUM_INPUTS(L1_INPUTS))
        u_l1(.clk(clk),.rst_n(rst_n),.w_load_en(w_en_l1),.w_load_addr(w_load_addr),
             .w_load_data(w_load_data),.compute_en(ce_l1),.acc_clear(ac_l1),
             .x_in(x_out),.row_en_mask(row_en_l1),.y_out_int8(l1_out),.y_valid(y_valid_l1));

    cim_array #(.DWIDTH(8),.ROWS(L2_ROWS),.ACC_WIDTH(20),.REQUANT_SHIFT(7),.NUM_INPUTS(L2_INPUTS))
        u_l2(.clk(clk),.rst_n(rst_n),.w_load_en(w_en_l2),.w_load_addr(w_load_addr[5:0]),
             .w_load_data(w_load_data),.compute_en(ce_l2),.acc_clear(ac_l2),
             .x_in(x_out),.row_en_mask(row_en_l2),.y_out_int8(l2_out),.y_valid(y_valid_l2));

    // <--- FIXED: Shifted down by 8, Bypass ReLU for Logits --->
    cim_array #(.DWIDTH(8),.ROWS(L3_ROWS),.ACC_WIDTH(20),.REQUANT_SHIFT(4),.NUM_INPUTS(L3_INPUTS), .USE_RELU(0))
        u_l3(.clk(clk),.rst_n(rst_n),.w_load_en(w_en_l3),.w_load_addr(w_load_addr[3:0]),
             .w_load_data(w_load_data),.compute_en(ce_l3),.acc_clear(ac_l3),
             .x_in(x_out),.row_en_mask(row_en_l3),.y_out_int8(l3_out),.y_valid(y_valid_l3));

    sparse_ctrl #(
        .DWIDTH(DWIDTH),
        .L1_ROWS(L1_ROWS), .L1_INPUTS(L1_INPUTS),
        .L2_ROWS(L2_ROWS), .L2_INPUTS(L2_INPUTS),
        .L3_ROWS(L3_ROWS), .L3_INPUTS(L3_INPUTS)
    ) u_ctrl (
        .clk(clk), .rst_n(rst_n),
        .start(tb_start),
        .pixel_in(tb_pixel_in), .pixel_valid(tb_pixel_valid),
        .w_load_en(w_load_en), .w_load_addr(w_load_addr),
        .w_load_data(w_load_data), .compute_en(compute_en),
        .acc_clear(acc_clear), .x_out(x_out),
        .row_en_l1(row_en_l1), .row_en_l2(row_en_l2), .row_en_l3(row_en_l3),
        .layer_sel(layer_sel), .y_valid(y_valid_active),
        .l1_out(l1_out), .l2_out(l2_out), .l3_out(l3_out),
        .pred_class(pred_class), .output_valid(output_valid)
    );

    // UART TX
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_data  <= 8'd0;
            tx_start <= 1'b0;
        end else begin
            tx_start <= 1'b0;
            if (output_valid && !tx_busy) begin
                tx_data  <= {4'b0000, pred_class};
                tx_start <= 1'b1;
            end
        end
    end

    assign pred_leds = pred_class;

endmodule