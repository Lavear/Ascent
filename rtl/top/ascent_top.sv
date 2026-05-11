// =============================================================================
// ASCENT — ascent_top.sv
// Phase 4: Top-level module — wires UART, CIM arrays, and sparse controller.
//
// System overview:
//   PC → UART RX → pixel buffer → sparse_ctrl → cim_array (L1,L2,L3)
//                                                          → argmax
//                                             → UART TX → PC
//
// Three separate cim_array instances for L1, L2, L3.
// sparse_ctrl drives all three but only the active layer gets compute_en.
// =============================================================================

module ascent_top #(
    parameter int CLK_FREQ  = 50_000_000,
    parameter int BAUD_RATE = 9600,
    parameter int DWIDTH    = 8
)(
    input  logic clk,
    input  logic rst_n,
    input  logic uart_rx,
    output logic uart_tx,

    // Debug LEDs (optional — tie to pred_class for FPGA bring-up)
    output logic [3:0] pred_leds
);

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
    // CIM Array — Layer 1 (128 rows, 784 inputs, 24-bit acc)
    // =========================================================================
    localparam int L1_ROWS   = 128;
    localparam int L1_INPUTS = 784;
    localparam int L2_ROWS   = 64;
    localparam int L2_INPUTS = 128;
    localparam int L3_ROWS   = 10;
    localparam int L3_INPUTS = 64;

    // Shared CIM control signals (driven by sparse_ctrl, gated per layer)
    logic        w_load_en;
    logic [6:0]  w_load_addr;
    logic [7:0]  w_load_data;
    logic        compute_en;
    logic        acc_clear;
    logic signed [7:0] x_out;
    logic [1:0]  layer_sel;

    // Row enable masks
    logic [L1_ROWS-1:0] row_en_l1;
    logic [L2_ROWS-1:0] row_en_l2;
    logic [L3_ROWS-1:0] row_en_l3;

    // y_valid and outputs from each layer
    logic y_valid_l1, y_valid_l2, y_valid_l3;
    logic [L1_ROWS-1:0][7:0] l1_out;
    logic [L2_ROWS-1:0][7:0] l2_out;
    logic [L3_ROWS-1:0][7:0] l3_out;

    // Active y_valid (muxed to sparse_ctrl)
    logic y_valid_active;
    always_comb begin
        case (layer_sel)
            2'd0:    y_valid_active = y_valid_l1;
            2'd1:    y_valid_active = y_valid_l2;
            2'd2:    y_valid_active = y_valid_l3;
            default: y_valid_active = y_valid_l1;
        endcase
    end

    // Layer-gated compute_en and acc_clear
    logic compute_en_l1, compute_en_l2, compute_en_l3;
    logic acc_clear_l1,  acc_clear_l2,  acc_clear_l3;

    assign compute_en_l1 = compute_en & (layer_sel == 2'd0);
    assign compute_en_l2 = compute_en & (layer_sel == 2'd1);
    assign compute_en_l3 = compute_en & (layer_sel == 2'd2);
    assign acc_clear_l1  = acc_clear  & (layer_sel == 2'd0);
    assign acc_clear_l2  = acc_clear  & (layer_sel == 2'd1);
    assign acc_clear_l3  = acc_clear  & (layer_sel == 2'd2);

    cim_array #(
        .DWIDTH        (8),
        .ROWS          (L1_ROWS),
        .ACC_WIDTH     (24),
        .REQUANT_SHIFT (11),
        .NUM_INPUTS    (L1_INPUTS)
    ) u_l1 (
        .clk          (clk),
        .rst_n        (rst_n),
        .w_load_en    (w_load_en    & (layer_sel == 2'd0)),
        .w_load_addr  (w_load_addr[6:0]),
        .w_load_data  (w_load_data),
        .compute_en   (compute_en_l1),
        .acc_clear    (acc_clear_l1),
        .x_in         (x_out),
        .row_en_mask  (row_en_l1),
        .y_out_int8   (l1_out),
        .y_valid      (y_valid_l1)
    );

    cim_array #(
        .DWIDTH        (8),
        .ROWS          (L2_ROWS),
        .ACC_WIDTH     (20),
        .REQUANT_SHIFT (7),
        .NUM_INPUTS    (L2_INPUTS)
    ) u_l2 (
        .clk          (clk),
        .rst_n        (rst_n),
        .w_load_en    (w_load_en    & (layer_sel == 2'd1)),
        .w_load_addr  (w_load_addr[5:0]),
        .w_load_data  (w_load_data),
        .compute_en   (compute_en_l2),
        .acc_clear    (acc_clear_l2),
        .x_in         (x_out),
        .row_en_mask  (row_en_l2),
        .y_out_int8   (l2_out),
        .y_valid      (y_valid_l2)
    );

    cim_array #(
        .DWIDTH        (8),
        .ROWS          (L3_ROWS),
        .ACC_WIDTH     (20),
        .REQUANT_SHIFT (0),
        .NUM_INPUTS    (L3_INPUTS)
    ) u_l3 (
        .clk          (clk),
        .rst_n        (rst_n),
        .w_load_en    (w_load_en    & (layer_sel == 2'd2)),
        .w_load_addr  (w_load_addr[3:0]),
        .w_load_data  (w_load_data),
        .compute_en   (compute_en_l3),
        .acc_clear    (acc_clear_l3),
        .x_in         (x_out),
        .row_en_mask  (row_en_l3),
        .y_out_int8   (l3_out),
        .y_valid      (y_valid_l3)
    );

    // =========================================================================
    // Sparse Controller
    // =========================================================================
    logic [3:0] pred_class;
    logic       output_valid;

    // Start inference when first pixel byte arrives
    // (we use rx_valid as the start trigger — sparse_ctrl waits for all 784)
    logic       start_inf;
    logic       inf_running;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            inf_running <= 1'b0;
        else if (output_valid)
            inf_running <= 1'b0;
        else if (rx_valid && !inf_running)
            inf_running <= 1'b1;
    end

    assign start_inf = rx_valid && !inf_running;

    sparse_ctrl #(
        .DWIDTH    (8),
        .L1_ROWS   (L1_ROWS),
        .L1_INPUTS (L1_INPUTS),
        .L2_ROWS   (L2_ROWS),
        .L2_INPUTS (L2_INPUTS),
        .L3_ROWS   (L3_ROWS),
        .L3_INPUTS (L3_INPUTS)
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
    // UART TX — send predicted class back to PC
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_data  <= '0;
            tx_start <= 1'b0;
        end else begin
            tx_start <= 1'b0;
            if (output_valid && !tx_busy) begin
                tx_data  <= {4'b0, pred_class};
                tx_start <= 1'b1;
            end
        end
    end

    assign pred_leds = pred_class;

endmodule