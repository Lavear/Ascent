// =============================================================================
// ASCENT — ascent_top.sv
// Phase 4b: Top-Level Integration
//
// Wires together:
//   uart_rx   → sparse_ctrl (pixel stream)
//   sparse_ctrl → cim_array_l1, cim_array_l2, cim_array_l3
//   cim_array outputs → sparse_ctrl (inter-layer activations)
//   sparse_ctrl result → uart_tx (predicted digit byte)
//
// Data flow:
//   PC sends 784 normalised INT8 pixel bytes over UART
//   sparse_ctrl buffers them, runs 3-layer inference
//   Predicted digit (0–9) sent back as one byte over UART
//   pred_leds shows the 4-bit result on FPGA LEDs
//
// Layer configurations:
//   L1: 128 rows, 784 inputs, 24-bit acc, shift 11
//   L2:  64 rows, 128 inputs, 20-bit acc, shift  7
//   L3:  10 rows,  64 inputs, 20-bit acc, shift  8  (Logits - No ReLU)
// =============================================================================

module ascent_top_exact #(
    parameter int CLK_FREQ  = 50_000_000,
    parameter int BAUD_RATE = 115200
)(
    input  logic       clk,
    input  logic       rst_n,
    input  logic       uart_rx,
    output logic       uart_tx,
    output logic [3:0] pred_leds
);

    // =========================================================================
    // Local parameters
    // =========================================================================
    localparam int DWIDTH    = 8;
    localparam int L1_ROWS   = 128;
    localparam int L1_INPUTS = 784;
    localparam int L2_ROWS   = 64;
    localparam int L2_INPUTS = 128;
    localparam int L3_ROWS   = 10;
    localparam int L3_INPUTS = 64;

    // =========================================================================
    // UART RX
    // =========================================================================
    logic [7:0] rx_data;
    logic       rx_valid;

    uart_rx #(
        .CLK_FREQ  (CLK_FREQ),
        .BAUD_RATE (BAUD_RATE)
    ) u_rx (
        .clk      (clk),
        .rst_n    (rst_n),
        .rx       (uart_rx),
        .rx_data  (rx_data),
        .rx_valid (rx_valid)
    );

    // =========================================================================
    // UART TX
    // =========================================================================
    logic [7:0] tx_data;
    logic       tx_start;
    logic       tx_busy;

    uart_tx #(
        .CLK_FREQ  (CLK_FREQ),
        .BAUD_RATE (BAUD_RATE)
    ) u_tx (
        .clk      (clk),
        .rst_n    (rst_n),
        .tx_data  (tx_data),
        .tx_start (tx_start),
        .tx       (uart_tx),
        .tx_busy  (tx_busy)
    );

    // =========================================================================
    // Shared CIM control signals (from sparse_ctrl)
    // =========================================================================
    logic        w_load_en;
    logic [6:0]  w_load_addr;
    logic [7:0]  w_load_data;
    logic        compute_en;
    logic        acc_clear;
    logic signed [7:0] x_out;
    logic [1:0]  layer_sel;

    // Sparsity masks
    logic [L1_ROWS-1:0] row_en_l1;
    logic [L2_ROWS-1:0] row_en_l2;
    logic [L3_ROWS-1:0] row_en_l3;

    // CIM array outputs
    logic [L1_ROWS-1:0][7:0] l1_out;
    logic [L2_ROWS-1:0][7:0] l2_out;
    logic [L3_ROWS-1:0][7:0] l3_out;

    // y_valid from each layer — muxed to sparse_ctrl based on layer_sel
    logic y_valid_l1, y_valid_l2, y_valid_l3;
    logic y_valid_active;

    always_comb begin
        case (layer_sel)
            2'd0:    y_valid_active = y_valid_l1;
            2'd1:    y_valid_active = y_valid_l2;
            2'd2:    y_valid_active = y_valid_l3;
            default: y_valid_active = y_valid_l1;
        endcase
    end

    // Gate w_load_en, compute_en, acc_clear per active layer
    logic w_load_en_l1, w_load_en_l2, w_load_en_l3;
    logic compute_en_l1, compute_en_l2, compute_en_l3;
    logic acc_clear_l1, acc_clear_l2, acc_clear_l3;

    assign w_load_en_l1  = w_load_en  & (layer_sel == 2'd0);
    assign w_load_en_l2  = w_load_en  & (layer_sel == 2'd1);
    assign w_load_en_l3  = w_load_en  & (layer_sel == 2'd2);

    assign compute_en_l1 = compute_en & (layer_sel == 2'd0);
    assign compute_en_l2 = compute_en & (layer_sel == 2'd1);
    assign compute_en_l3 = compute_en & (layer_sel == 2'd2);

    assign acc_clear_l1  = acc_clear  & (layer_sel == 2'd0);
    assign acc_clear_l2  = acc_clear  & (layer_sel == 2'd1);
    assign acc_clear_l3  = acc_clear  & (layer_sel == 2'd2);

    // =========================================================================
    // CIM Array — Layer 1
    // =========================================================================
    cim_array_exact #(
        .DWIDTH        (DWIDTH),
        .ROWS          (L1_ROWS),
        .ACC_WIDTH     (24),
        .REQUANT_SHIFT (11),
        .NUM_INPUTS    (L1_INPUTS)
    ) u_l1 (
        .clk         (clk),
        .rst_n       (rst_n),
        .w_load_en   (w_load_en_l1),
        .w_load_addr (w_load_addr),
        .w_load_data (w_load_data),
        .compute_en  (compute_en_l1),
        .acc_clear   (acc_clear_l1),
        .x_in        (x_out),
        .row_en_mask (row_en_l1),
        .y_out_int8  (l1_out),
        .y_valid     (y_valid_l1)
    );

    // =========================================================================
    // CIM Array — Layer 2
    // =========================================================================
    cim_array_exact #(
        .DWIDTH        (DWIDTH),
        .ROWS          (L2_ROWS),
        .ACC_WIDTH     (20),
        .REQUANT_SHIFT (7),
        .NUM_INPUTS    (L2_INPUTS)
    ) u_l2 (
        .clk         (clk),
        .rst_n       (rst_n),
        .w_load_en   (w_load_en_l2),
        .w_load_addr (w_load_addr[5:0]),
        .w_load_data (w_load_data),
        .compute_en  (compute_en_l2),
        .acc_clear   (acc_clear_l2),
        .x_in        (x_out),
        .row_en_mask (row_en_l2),
        .y_out_int8  (l2_out),
        .y_valid     (y_valid_l2)
    );

    // =========================================================================
    // CIM Array — Layer 3
    // =========================================================================
    cim_array_exact #(
        .DWIDTH        (DWIDTH),
        .ROWS          (L3_ROWS),
        .ACC_WIDTH     (20),
        .REQUANT_SHIFT (4),            // <--- FIXED: Shifted down by 8
        .NUM_INPUTS    (L3_INPUTS),
        .USE_RELU      (0)             // <--- FIXED: Bypass ReLU for Logits
    ) u_l3 (
        .clk         (clk),
        .rst_n       (rst_n),
        .w_load_en   (w_load_en_l3),
        .w_load_addr (w_load_addr[3:0]),
        .w_load_data (w_load_data),
        .compute_en  (compute_en_l3),
        .acc_clear   (acc_clear_l3),
        .x_in        (x_out),
        .row_en_mask (row_en_l3),
        .y_out_int8  (l3_out),
        .y_valid     (y_valid_l3)
    );

    // =========================================================================
    // Sparse Controller
    // =========================================================================
    logic [3:0] pred_class;
    logic       output_valid;

    // Start inference when first UART byte arrives and we are idle
    logic inf_busy;
    logic start_inf;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            inf_busy <= 1'b0;
        else if (output_valid)
            inf_busy <= 1'b0;
        else if (rx_valid && !inf_busy)
            inf_busy <= 1'b1;
    end

    assign start_inf = rx_valid && !inf_busy;

    sparse_ctrl #(
        .DWIDTH    (DWIDTH),
        .L1_ROWS   (L1_ROWS), .L1_INPUTS (L1_INPUTS),
        .L2_ROWS   (L2_ROWS), .L2_INPUTS (L2_INPUTS),
        .L3_ROWS   (L3_ROWS), .L3_INPUTS (L3_INPUTS)
    ) u_ctrl (
        .clk          (clk),
        .rst_n        (rst_n),
        .start        (start_inf),
        .pixel_in     (rx_data),
        .pixel_valid  (rx_valid),
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
        .y_valid      (y_valid_active),
        .l1_out       (l1_out),
        .l2_out       (l2_out),
        .l3_out       (l3_out),
        .pred_class   (pred_class),
        .output_valid (output_valid)
    );

    // =========================================================================
    // UART TX — send predicted class when inference completes
    // =========================================================================
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
