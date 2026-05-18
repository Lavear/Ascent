// =============================================================================
// ASCENT — ascent_top.sv  (PYNQ-Z2 revision)
//
// Changes from previous version:
//   1. Instantiates clk_wiz to convert 125 MHz board clock → 100 MHz
//   2. CLK_FREQ parameter updated to 100_000_000
//   3. Reset is derived from MMCM locked signal:
//        rst_n_int = locked & btn_rst_n
//      This ensures the design stays in reset until the clock is stable.
//   4. Port list matches PYNQ-Z2 pinout (clk = 125 MHz, btn_rst_n = BTN0)
//   5. All internal logic runs on clk_100 from clk_wiz
//   6. Layer-gating logic and CIM instantiation unchanged from working sim
// =============================================================================

module ascent_top #(
    parameter int CLK_FREQ  = 125_000_000,   // 100 MHz after MMCM
    parameter int BAUD_RATE = 115_200
)(
    input  logic       clk_125,     // 125 MHz from PYNQ-Z2 board (pin H16)
    input  logic       btn_rst_n,   // active-low reset from BTN0 (pin D19)
    input  logic       uart_rx,     // USB-UART RX (pin A14)
    output logic       uart_tx,     // USB-UART TX (pin A15)
    output logic [3:0] pred_leds    // LEDs 3:0 (R14, P14, N16, M14)
);

    // =========================================================================
    // Clock and reset
    // =========================================================================
    logic clk_100;      // 100 MHz — all design logic runs here
    logic mmcm_locked;  // high when MMCM has locked

    clk_wiz u_clk_wiz (
        .clk_125 (clk_125),
        .reset   (~btn_rst_n),      // MMCM reset is active-high
        .clk_100 (clk_100),
        .locked  (mmcm_locked)
    );

    // Internal active-low reset: deasserted only after MMCM locks AND button released
    logic rst_n_int;
    assign rst_n_int = mmcm_locked & btn_rst_n;

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
    // UART RX — 115200 baud, auto-scales from CLK_FREQ parameter
    // =========================================================================
    logic [7:0] rx_data;
    logic       rx_valid;

    uart_rx #(
        .CLK_FREQ  (CLK_FREQ),
        .BAUD_RATE (BAUD_RATE)
    ) u_rx (
        .clk      (clk_100),
        .rst_n    (rst_n_int),
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
        .clk      (clk_100),
        .rst_n    (rst_n_int),
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

    logic [L1_ROWS-1:0] row_en_l1;
    logic [L2_ROWS-1:0] row_en_l2;
    logic [L3_ROWS-1:0] row_en_l3;

    logic [L1_ROWS-1:0][7:0] l1_out;
    logic [L2_ROWS-1:0][7:0] l2_out;
    logic [L3_ROWS-1:0][7:0] l3_out;

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

    // Layer-gated enables
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
    // CIM Array — Layer 1  (128 rows, 784 inputs, 24-bit acc, shift 11, ReLU)
    // =========================================================================
    cim_array #(
        .DWIDTH        (DWIDTH),
        .ROWS          (L1_ROWS),
        .ACC_WIDTH     (24),
        .REQUANT_SHIFT (11),
        .NUM_INPUTS    (L1_INPUTS),
        .USE_RELU      (1)
    ) u_l1 (
        .clk         (clk_100),
        .rst_n       (rst_n_int),
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
    // CIM Array — Layer 2  (64 rows, 128 inputs, 20-bit acc, shift 7, ReLU)
    // =========================================================================
    cim_array #(
        .DWIDTH        (DWIDTH),
        .ROWS          (L2_ROWS),
        .ACC_WIDTH     (20),
        .REQUANT_SHIFT (7),
        .NUM_INPUTS    (L2_INPUTS),
        .USE_RELU      (1)
    ) u_l2 (
        .clk         (clk_100),
        .rst_n       (rst_n_int),
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
    // CIM Array — Layer 3  (10 rows, 64 inputs, 20-bit acc, shift 4, NO ReLU)
    // =========================================================================
    cim_array #(
        .DWIDTH        (DWIDTH),
        .ROWS          (L3_ROWS),
        .ACC_WIDTH     (20),
        .REQUANT_SHIFT (4),
        .NUM_INPUTS    (L3_INPUTS),
        .USE_RELU      (0)
    ) u_l3 (
        .clk         (clk_100),
        .rst_n       (rst_n_int),
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

    // Start inference on first UART byte received while idle
    logic inf_busy;
    logic start_inf;

    always_ff @(posedge clk_100 or negedge rst_n_int) begin
        if (!rst_n_int)
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
        .clk          (clk_100),
        .rst_n        (rst_n_int),
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
    always_ff @(posedge clk_100 or negedge rst_n_int) begin
        if (!rst_n_int) begin
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
