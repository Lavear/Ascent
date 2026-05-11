// =============================================================================
// ASCENT — sparse_ctrl.sv
// Phase 4: Sparse Controller — FSM + Sparsity Mask ROM + CIM Sequencer
//
// Orchestrates a full 3-layer MLP inference:
//   For each layer (L1→L2→L3):
//     For each input column i:
//       Load all ROWS weights for column i into CIM array (ROWS cycles)
//       Assert compute_en with row_en_mask from sparsity ROM (1 cycle)
//     Wait for y_valid, capture output, feed to next layer
//   After L3: compute argmax → predicted class
//
// FSM States:
//   IDLE      — waiting for inference start
//   RECV_PIX  — buffering 784 incoming pixel bytes
//   CLR_ACC   — one-cycle accumulator clear before each layer
//   LOAD_W    — loading weight[row][col] (ROWS cycles per column)
//   COMPUTE   — one compute_en cycle
//   ADV_COL   — advance column counter or finish layer
//   CAPTURE   — register layer output (y_valid must be high)
//   ARGMAX    — find maximum score among 10 L3 outputs
//   DONE      — assert output_valid with pred_class
// =============================================================================

module sparse_ctrl #(
    parameter int DWIDTH    = 8,
    parameter int L1_ROWS   = 128,
    parameter int L1_INPUTS = 784,
    parameter int L2_ROWS   = 64,
    parameter int L2_INPUTS = 128,
    parameter int L3_ROWS   = 10,
    parameter int L3_INPUTS = 64
)(
    input  logic                        clk,
    input  logic                        rst_n,

    // Start inference
    input  logic                        start,

    // Pixel input (from UART RX or testbench)
    input  logic [DWIDTH-1:0]           pixel_in,
    input  logic                        pixel_valid,

    // CIM array interface — Layer 1
    output logic                        w_load_en,
    output logic [6:0]                  w_load_addr,
    output logic [DWIDTH-1:0]           w_load_data,
    output logic                        compute_en,
    output logic                        acc_clear,
    output logic signed [DWIDTH-1:0]    x_out,

    // Sparsity masks (one per layer, muxed externally or here)
    output logic [L1_ROWS-1:0]          row_en_l1,
    output logic [L2_ROWS-1:0]          row_en_l2,
    output logic [L3_ROWS-1:0]          row_en_l3,

    // Layer select (for top-level CIM array muxing)
    output logic [1:0]                  layer_sel,

    // y_valid from active CIM array
    input  logic                        y_valid,

    // Layer outputs captured from CIM arrays
    input  logic [L1_ROWS-1:0][DWIDTH-1:0] l1_out,
    input  logic [L2_ROWS-1:0][DWIDTH-1:0] l2_out,
    input  logic [L3_ROWS-1:0][DWIDTH-1:0] l3_out,

    // Result
    output logic [3:0]                  pred_class,
    output logic                        output_valid
);

    // =========================================================================
    // ROMs
    // =========================================================================
    logic [DWIDTH-1:0]  wrom_l1 [0:L1_ROWS*L1_INPUTS-1];
    logic [DWIDTH-1:0]  wrom_l2 [0:L2_ROWS*L2_INPUTS-1];
    logic [DWIDTH-1:0]  wrom_l3 [0:L3_ROWS*L3_INPUTS-1];

    logic [L1_ROWS-1:0] mrom_l1 [0:L1_INPUTS-1];
    logic [L2_ROWS-1:0] mrom_l2 [0:L2_INPUTS-1];
    logic [L3_ROWS-1:0] mrom_l3 [0:L3_INPUTS-1];

    // Pixel input buffer
    logic signed [DWIDTH-1:0] pix_buf [0:L1_INPUTS-1];

    initial begin
        $readmemh("python/outputs/weights_l1.hex",     wrom_l1);
        $readmemh("python/outputs/weights_l2.hex",     wrom_l2);
        $readmemh("python/outputs/weights_l3.hex",     wrom_l3);
        $readmemh("python/outputs/sparse_mask_l1.hex", mrom_l1);
        $readmemh("python/outputs/sparse_mask_l2.hex", mrom_l2);
        $readmemh("python/outputs/sparse_mask_l3.hex", mrom_l3);
    end

    // =========================================================================
    // FSM state
    // =========================================================================
    typedef enum logic [3:0] {
        IDLE     = 4'd0,
        RECV_PIX = 4'd1,
        CLR_ACC  = 4'd2,
        LOAD_W   = 4'd3,
        COMPUTE  = 4'd4,
        ADV_COL  = 4'd5,
        CAPTURE  = 4'd6,
        ARGMAX   = 4'd7,
        DONE     = 4'd8
    } state_t;

    state_t      state;
    logic [1:0]  layer;
    logic [9:0]  col_cnt;     // input column index
    logic [6:0]  row_cnt;     // weight-load row counter
    logic [9:0]  pix_cnt;     // pixel receive counter

    // Current layer dimensions
    logic [9:0] cur_rows, cur_inputs;
    always_comb begin
        case (layer)
            2'd0:    begin cur_rows = 10'(L1_ROWS); cur_inputs = 10'(L1_INPUTS); end
            2'd1:    begin cur_rows = 10'(L2_ROWS); cur_inputs = 10'(L2_INPUTS); end
            2'd2:    begin cur_rows = 10'(L3_ROWS); cur_inputs = 10'(L3_INPUTS); end
            default: begin cur_rows = 10'(L1_ROWS); cur_inputs = 10'(L1_INPUTS); end
        endcase
    end

    // Current weight ROM value
    logic [DWIDTH-1:0] cur_weight;
    always_comb begin
        case (layer)
            2'd0:    cur_weight = wrom_l1[{3'b0, row_cnt} * L1_INPUTS + col_cnt];
            2'd1:    cur_weight = wrom_l2[{3'b0, row_cnt} * L2_INPUTS + col_cnt];
            2'd2:    cur_weight = wrom_l3[{3'b0, row_cnt} * L3_INPUTS + col_cnt];
            default: cur_weight = wrom_l1[{3'b0, row_cnt} * L1_INPUTS + col_cnt];
        endcase
    end

    // Current input value
    logic signed [DWIDTH-1:0] cur_x;
    always_comb begin
        case (layer)
            2'd0:    cur_x = pix_buf[col_cnt];
            2'd1:    cur_x = $signed(l1_out[col_cnt]);
            2'd2:    cur_x = $signed(l2_out[col_cnt]);
            default: cur_x = pix_buf[col_cnt];
        endcase
    end

    // Sparsity masks (driven combinationally from ROMs)
    always_comb begin
        row_en_l1 = mrom_l1[col_cnt];
        row_en_l2 = mrom_l2[col_cnt];
        row_en_l3 = (col_cnt < L3_INPUTS) ? mrom_l3[col_cnt] : '0;
    end

    assign layer_sel = layer;

    // =========================================================================
    // Argmax over 10 L3 outputs
    // =========================================================================
    logic [3:0]         argmax_idx;
    logic signed [7:0]  argmax_val;
    logic [3:0]         am_i;       // loop variable for argmax

    // =========================================================================
    // FSM
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= IDLE;
            layer        <= 2'd0;
            col_cnt      <= '0;
            row_cnt      <= '0;
            pix_cnt      <= '0;
            w_load_en    <= 1'b0;
            w_load_addr  <= '0;
            w_load_data  <= '0;
            compute_en   <= 1'b0;
            acc_clear    <= 1'b0;
            x_out        <= '0;
            pred_class   <= '0;
            output_valid <= 1'b0;
            argmax_idx   <= '0;
            argmax_val   <= '0;
        end else begin
            w_load_en    <= 1'b0;
            compute_en   <= 1'b0;
            acc_clear    <= 1'b0;
            output_valid <= 1'b0;

            case (state)
                // ----------------------------------------------------------------
                IDLE: begin
                    layer   <= 2'd0;
                    col_cnt <= '0;
                    row_cnt <= '0;
                    pix_cnt <= '0;
                    if (start) state <= RECV_PIX;
                end

                // ----------------------------------------------------------------
                // Buffer 784 pixels from UART
                // ----------------------------------------------------------------
                RECV_PIX: begin
                    if (pixel_valid) begin
                        pix_buf[pix_cnt] <= $signed(pixel_in);
                        if (pix_cnt == L1_INPUTS - 1) begin
                            pix_cnt <= '0;
                            state   <= CLR_ACC;
                        end else
                            pix_cnt <= pix_cnt + 1'b1;
                    end
                end

                // ----------------------------------------------------------------
                // Clear accumulator before each layer
                // ----------------------------------------------------------------
                CLR_ACC: begin
                    acc_clear <= 1'b1;
                    col_cnt   <= '0;
                    row_cnt   <= '0;
                    state     <= LOAD_W;
                end

                // ----------------------------------------------------------------
                // Load weight[row_cnt][col_cnt] for current layer
                // ----------------------------------------------------------------
                LOAD_W: begin
                    w_load_en   <= 1'b1;
                    w_load_addr <= row_cnt;
                    w_load_data <= cur_weight;

                    if (row_cnt == cur_rows - 1) begin
                        row_cnt <= '0;
                        state   <= COMPUTE;
                    end else
                        row_cnt <= row_cnt + 1'b1;
                end

                // ----------------------------------------------------------------
                // One compute cycle for input col_cnt
                // ----------------------------------------------------------------
                COMPUTE: begin
                    x_out      <= cur_x;
                    compute_en <= 1'b1;
                    state      <= ADV_COL;
                end

                // ----------------------------------------------------------------
                // Advance column. If last column, wait for y_valid then capture.
                // ----------------------------------------------------------------
                ADV_COL: begin
                    if (col_cnt == cur_inputs - 1) begin
                        if (y_valid) begin
                            col_cnt <= '0;
                            state   <= CAPTURE;
                        end
                        // else stay here until y_valid (should be next cycle)
                    end else begin
                        col_cnt <= col_cnt + 1'b1;
                        state   <= LOAD_W;
                    end
                end

                // ----------------------------------------------------------------
                // Capture layer output and move to next layer or argmax
                // ----------------------------------------------------------------
                CAPTURE: begin
                    if (layer == 2'd2) begin
                        // L3 done — compute argmax
                        argmax_idx <= 4'd0;
                        argmax_val <= $signed(l3_out[0]);
                        state      <= ARGMAX;
                    end else begin
                        layer   <= layer + 1'b1;
                        col_cnt <= '0;
                        state   <= CLR_ACC;
                    end
                end

                // ----------------------------------------------------------------
                // Argmax: scan L3 outputs to find highest score
                // ----------------------------------------------------------------
                ARGMAX: begin
                    // Combinational scan — find max in one cycle
                    // (10 comparisons is tiny)
                    begin
                        logic signed [7:0] best_val;
                        logic [3:0]        best_idx;
                        best_val = $signed(l3_out[0]);
                        best_idx = 4'd0;
                        for (int k = 1; k < L3_ROWS; k++) begin
                            if ($signed(l3_out[k]) > best_val) begin
                                best_val = $signed(l3_out[k]);
                                best_idx = 4'(k);
                            end
                        end
                        pred_class <= best_idx;
                    end
                    state <= DONE;
                end

                // ----------------------------------------------------------------
                DONE: begin
                    output_valid <= 1'b1;
                    state        <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule