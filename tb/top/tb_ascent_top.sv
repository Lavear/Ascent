// =============================================================================
// ASCENT — tb_ascent_top.sv
// Phase 4 Testbench: End-to-end inference verification.
//
// Loads test_inputs.hex (784 normalised INT8 pixel bytes for image 0),
// sends them over a simulated UART connection to ascent_top,
// waits for the UART TX response byte,
// checks the predicted class matches golden_outputs.txt.
//
// At 9600 baud, 50MHz clock:
//   CLK_DIVISOR = 50_000_000 / 9600 = 5208 cycles per bit
//   One byte    = 10 bits × 5208 = 52,080 cycles
//   784 bytes   = 784 × 52,080   = ~40.8M cycles
//   Inference   = ~100K cycles
//   Response    = 52,080 cycles
//   Total       ≈ 41M cycles ≈ 820ms simulated time
//
// This is slow for simulation. For ModelSim, run with:
//   vsim -c tb_ascent_top -do "run 1000ms; quit"
//
// For faster simulation, increase BAUD_RATE to 1_000_000 (reduce to 400ms)
// or use the sparse_ctrl testbench which bypasses UART entirely.
// =============================================================================

`timescale 1ns/1ps

module tb_ascent_top;

    localparam int CLK_FREQ  = 50_000_000;
    localparam int BAUD_RATE = 115200;      // Higher baud for faster simulation
    localparam int CLK_HALF  = 10;          // 50MHz = 20ns period = 10ns half
    localparam int BIT_PERIOD = CLK_FREQ / BAUD_RATE;  // clock cycles per UART bit

    // -------------------------------------------------------------------------
    // DUT signals
    // -------------------------------------------------------------------------
    logic       clk, rst_n;
    logic       uart_rx_tb;    // testbench drives this
    logic       uart_tx_dut;   // DUT drives this
    logic [3:0] pred_leds;

    // -------------------------------------------------------------------------
    // DUT
    // -------------------------------------------------------------------------
    ascent_top #(
        .CLK_FREQ  (CLK_FREQ),
        .BAUD_RATE (BAUD_RATE)
    ) u_dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .uart_rx  (uart_rx_tb),
        .uart_tx  (uart_tx_dut),
        .pred_leds(pred_leds)
    );

    // -------------------------------------------------------------------------
    // Clock
    // -------------------------------------------------------------------------
    initial clk = 0;
    always #CLK_HALF clk = ~clk;

    // -------------------------------------------------------------------------
    // Test image and expected result
    // -------------------------------------------------------------------------
    logic [7:0] test_pixels [0:783];   // 784 normalised INT8 pixels
    int expected_class;                 // from golden_outputs.txt

    // -------------------------------------------------------------------------
    // TASK: send one byte over UART (8N1)
    // -------------------------------------------------------------------------
    task automatic uart_send_byte(input logic [7:0] data);
        // Start bit
        uart_rx_tb = 1'b0;
        repeat(BIT_PERIOD) @(posedge clk);
        // 8 data bits, LSB first
        for (int i = 0; i < 8; i++) begin
            uart_rx_tb = data[i];
            repeat(BIT_PERIOD) @(posedge clk);
        end
        // Stop bit
        uart_rx_tb = 1'b1;
        repeat(BIT_PERIOD) @(posedge clk);
    endtask

    // -------------------------------------------------------------------------
    // TASK: receive one byte from UART TX
    // Returns the received byte
    // -------------------------------------------------------------------------
    logic [7:0] rx_byte;

    task automatic uart_recv_byte;
        // Wait for start bit (falling edge)
        @(negedge uart_tx_dut);
        // Wait 1.5 bit periods to sample first data bit in centre
        repeat(BIT_PERIOD + BIT_PERIOD/2) @(posedge clk);
        for (int i = 0; i < 8; i++) begin
            rx_byte[i] = uart_tx_dut;
            repeat(BIT_PERIOD) @(posedge clk);
        end
        // Sample stop bit
        @(posedge clk);
        $display("  UART RX: received byte = 0x%02h (%0d)", rx_byte, rx_byte);
    endtask

    // =========================================================================
    // Main
    // =========================================================================
    initial begin
        $dumpfile("sim/waves/tb_ascent_top.vcd");
        $dumpvars(0, tb_ascent_top);

        uart_rx_tb = 1'b1;   // idle high
        rst_n      = 0;

        repeat(10) @(posedge clk); #1;
        rst_n = 1; #1;

        $display("=====================================================");
        $display("ASCENT Phase 4 — Top-Level End-to-End Testbench");
        $display("=====================================================");

        // Load test image
        $display("\nLoading test image from python/outputs/test_inputs.hex...");
        $readmemh("python/outputs/test_inputs.hex", test_pixels, 0, 783);
        $display("  Loaded 784 pixel bytes.");

        // Expected result: from golden_outputs.txt, image 0 is digit 7
        expected_class = 7;
        $display("  Expected class: %0d", expected_class);

        // Send all 784 pixel bytes
        $display("\nSending 784 bytes over UART at %0d baud...", BAUD_RATE);
        $display("(This will take ~%0d million clock cycles)",
                 (784 * 10 * BIT_PERIOD) / 1_000_000);

        for (int i = 0; i < 784; i++) begin
            uart_send_byte(test_pixels[i]);
            if (i % 100 == 0)
                $display("  Sent %0d / 784 bytes", i);
        end
        $display("  All pixels sent. Waiting for inference...");

        // Wait for response
        $display("\nWaiting for UART TX response...");
        uart_recv_byte;

        // Check result
        $display("\n--- Result ---");
        $display("  Predicted class : %0d", rx_byte[3:0]);
        $display("  Expected class  : %0d", expected_class);
        $display("  LED output      : %04b", pred_leds);

        if (rx_byte[3:0] == expected_class[3:0]) begin
            $display("\nPASS: Correct digit predicted!");
            $display("PASS: Full end-to-end inference verified.");
        end else begin
            $display("\nFAIL: Wrong prediction. Check sparse_ctrl argmax logic.");
        end

        $display("=====================================================");
        $finish;
    end

    // Timeout watchdog: 1 billion cycles max
    initial begin
        #(1_000_000_000);
        $display("TIMEOUT: Simulation exceeded 1 billion cycles.");
        $finish;
    end

endmodule