// =============================================================================
// ASCENT — sparse_ctrl.sv
// Phase 4: Sparse Controller FSM
//
// FSM States:
//   IDLE     — wait for start
//   RECV_PIX — buffer L1_INPUTS pixel bytes
//   CLR_ACC  — one-cycle accumulator clear
//   LOAD_W   — load weight[row][col] into CIM row (cur_rows cycles per col)
//   COMPUTE  — one compute_en pulse for current column
//   ADV_COL  — advance column; if last col go to WAIT_V else go to LOAD_W
//   WAIT_V   — hold here until y_valid goes high, then go to CAPTURE
//   CAPTURE  — advance layer and go to CLR_ACC (or go to ARGMAX if done)
//   ARGMAX   — find max of 10 L3 scores
//   DONE     — assert output_valid for one cycle
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
    input  logic                        start,

    input  logic [DWIDTH-1:0]           pixel_in,
    input  logic                        pixel_valid,

    output logic                        w_load_en,
    output logic [6:0]                  w_load_addr,
    output logic [DWIDTH-1:0]           w_load_data,
    output logic                        compute_en,
    output logic                        acc_clear,
    output logic signed [DWIDTH-1:0]    x_out,

    output logic [L1_ROWS-1:0]          row_en_l1,
    output logic [L2_ROWS-1:0]          row_en_l2,
    output logic [L3_ROWS-1:0]          row_en_l3,
    output logic [1:0]                  layer_sel,

    input  logic                        y_valid,

    input  logic [L1_ROWS-1:0][DWIDTH-1:0] l1_out,
    input  logic [L2_ROWS-1:0][DWIDTH-1:0] l2_out,
    input  logic [L3_ROWS-1:0][DWIDTH-1:0] l3_out,

    output logic [3:0]                  pred_class,
    output logic                        output_valid
);

    // =========================================================================
    // ROMs — weight matrices and sparsity masks
    // =========================================================================
    logic [DWIDTH-1:0]  wrom_l1 [0:L1_ROWS*L1_INPUTS-1];
    logic [DWIDTH-1:0]  wrom_l2 [0:L2_ROWS*L2_INPUTS-1];
    logic [DWIDTH-1:0]  wrom_l3 [0:L3_ROWS*L3_INPUTS-1];
    logic [L1_ROWS-1:0] mrom_l1 [0:L1_INPUTS-1];
    logic [L2_ROWS-1:0] mrom_l2 [0:L2_INPUTS-1];
    logic [L3_ROWS-1:0] mrom_l3 [0:L3_INPUTS-1];

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
    // FSM encoding
    // =========================================================================
    localparam logic [3:0]
        IDLE     = 4'd0,
        RECV_PIX = 4'd1,
        CLR_ACC  = 4'd2,
        LOAD_W   = 4'd3,
        COMPUTE  = 4'd4,
        ADV_COL  = 4'd5,
        WAIT_V   = 4'd6,
        CAPTURE  = 4'd7,
        ARGMAX   = 4'd8,
        DONE     = 4'd9;

    logic [3:0]  state;
    logic [1:0]  layer;
    logic [9:0]  col_cnt;
    logic [6:0]  row_cnt;
    logic [9:0]  pix_cnt;

    // =========================================================================
    // Current layer dimension mux
    // =========================================================================
    logic [9:0] cur_rows, cur_inputs;

    always_comb begin
        case (layer)
            2'd0: begin 
                cur_rows   = 10'd128; 
                cur_inputs = 10'd784; 
            end
            2'd1: begin 
                cur_rows   = 10'd64;  
                cur_inputs = 10'd128; 
            end
            2'd2: begin 
                cur_rows   = 10'd10;  
                cur_inputs = 10'd64;  
            end
            default: begin 
                cur_rows   = 10'd128; 
                cur_inputs = 10'd784; 
            end
        endcase
    end

    // =========================================================================
    // Weight and input muxes
    // =========================================================================
    logic [DWIDTH-1:0] cur_weight;

    always_comb begin
        case (layer)
            2'd0:    cur_weight = wrom_l1[{3'b0, row_cnt} * L1_INPUTS + col_cnt];
            2'd1:    cur_weight = wrom_l2[{3'b0, row_cnt} * L2_INPUTS + col_cnt];
            2'd2:    cur_weight = wrom_l3[{3'b0, row_cnt} * L3_INPUTS + col_cnt];
            default: cur_weight = wrom_l1[{3'b0, row_cnt} * L1_INPUTS + col_cnt];
        endcase
    end

    logic signed [DWIDTH-1:0] cur_x;

    always_comb begin
        case (layer)
            2'd0:    cur_x = pix_buf[col_cnt];
            2'd1:    cur_x = $signed(l1_out[col_cnt]);
            2'd2:    cur_x = $signed(l2_out[col_cnt]);
            default: cur_x = pix_buf[col_cnt];
        endcase
    end

    // =========================================================================
    // Sparsity mask outputs
    // =========================================================================
    always_comb begin
        row_en_l1 = mrom_l1[col_cnt];
        row_en_l2 = (col_cnt < 10'd128) ? mrom_l2[col_cnt] : '0;
        row_en_l3 = (col_cnt < 10'd64)  ? mrom_l3[col_cnt] : '0;
    end

    assign layer_sel = layer;

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
        end else begin
            // Defaults
            w_load_en    <= 1'b0;
            compute_en   <= 1'b0;
            acc_clear    <= 1'b0;
            output_valid <= 1'b0;

            case (state)

                IDLE: begin
                    layer   <= 2'd0;
                    col_cnt <= '0;
                    row_cnt <= '0;
                    pix_cnt <= '0;
                    if (start) begin
                        state <= RECV_PIX;
                    end
                end

                RECV_PIX: begin
                    if (pixel_valid) begin
                        pix_buf[pix_cnt] <= $signed(pixel_in);
                        if (pix_cnt == 10'(L1_INPUTS) - 1) begin
                            pix_cnt <= '0;
                            state   <= CLR_ACC;
                        end else begin
                            pix_cnt <= pix_cnt + 1'b1;
                        end
                    end
                end

                CLR_ACC: begin
                    acc_clear <= 1'b1;
                    col_cnt   <= '0;
                    row_cnt   <= '0;
                    state     <= LOAD_W;
                end

                LOAD_W: begin
                    w_load_en   <= 1'b1;
                    w_load_addr <= row_cnt;
                    w_load_data <= cur_weight;
                    
                    // FIXED: Properly size the subtraction to prevent 7-bit underflow
                    if (row_cnt == 7'(cur_rows - 10'd1)) begin
                        row_cnt <= '0;
                        state   <= COMPUTE;
                    end else begin
                        row_cnt <= row_cnt + 1'b1;
                    end
                end

                COMPUTE: begin
                    x_out      <= cur_x;
                    compute_en <= 1'b1;
                    state      <= ADV_COL;
                end

                ADV_COL: begin
                    if (col_cnt == cur_inputs - 1) begin
                        col_cnt <= '0;
                        state   <= WAIT_V;   // wait for y_valid
                    end else begin
                        col_cnt <= col_cnt + 1'b1;
                        state   <= LOAD_W;
                    end
                end

                WAIT_V: begin
                    if (y_valid) begin
                        state <= CAPTURE;
                    end
                    // else stay here every cycle until y_valid
                end

                CAPTURE: begin
                    // FIXED: Removed acc_clear to prevent wiping the completed layer's output!
                    if (layer == 2'd2) begin
                        state <= ARGMAX;
                    end else begin
                        layer   <= layer + 1'b1;
                        col_cnt <= '0;
                        row_cnt <= '0;
                        state   <= CLR_ACC; // Route back to properly clear the NEW layer
                    end
                end

                ARGMAX: begin
                    begin
                        logic signed [DWIDTH-1:0] best_val;
                        logic [3:0]               best_idx;
                        
                        best_val = $signed(l3_out[0]);
                        best_idx = 4'd0;
                        
                        for (int k = 1; k < L3_ROWS; k++) begin
                            if ($signed(l3_out[k]) > best_val) begin
                                best_val = $signed(l3_out[k]);
                                best_idx = 4'(k);
                            end
                        end
                        
                        // ADD THIS DEBUG LINE:
                        $display("DEBUG LOGITS: [0]:%0d [1]:%0d [2]:%0d [3]:%0d [4]:%0d [5]:%0d [6]:%0d [7]:%0d [8]:%0d [9]:%0d", 
                            $signed(l3_out[0]), $signed(l3_out[1]), $signed(l3_out[2]), $signed(l3_out[3]), $signed(l3_out[4]), 
                            $signed(l3_out[5]), $signed(l3_out[6]), $signed(l3_out[7]), $signed(l3_out[8]), $signed(l3_out[9]));

                        pred_class <= best_idx;
                    end
                    state <= DONE;
                end

                DONE: begin
                    output_valid <= 1'b1;
                    state        <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule