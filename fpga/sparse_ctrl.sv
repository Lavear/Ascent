// =============================================================================
// ASCENT — sparse_ctrl.sv (FPGA OPTIMIZED FOR PYNQ-Z2)
// Changes: Forced BRAM Inference and Output Pipelining
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
    // EXPLICIT BRAM INFERENCE
    // =========================================================================
    (* rom_style = "block" *) logic [DWIDTH-1:0]  wrom_l1 [0:L1_ROWS*L1_INPUTS-1];
    (* rom_style = "block" *) logic [DWIDTH-1:0]  wrom_l2 [0:L2_ROWS*L2_INPUTS-1];
    (* rom_style = "block" *) logic [DWIDTH-1:0]  wrom_l3 [0:L3_ROWS*L3_INPUTS-1];
    
    (* rom_style = "block" *) logic [L1_ROWS-1:0] mrom_l1 [0:L1_INPUTS-1];
    (* rom_style = "block" *) logic [L2_ROWS-1:0] mrom_l2 [0:L2_INPUTS-1];
    (* rom_style = "block" *) logic [L3_ROWS-1:0] mrom_l3 [0:L3_INPUTS-1];

    logic signed [DWIDTH-1:0] pix_buf [0:L1_INPUTS-1];

    initial begin
        $readmemh("python/outputs/weights_l1.hex",     wrom_l1);
        $readmemh("python/outputs/weights_l2.hex",     wrom_l2);
        $readmemh("python/outputs/weights_l3.hex",     wrom_l3);
        $readmemh("python/outputs/sparse_mask_l1.hex", mrom_l1);
        $readmemh("python/outputs/sparse_mask_l2.hex", mrom_l2);
        $readmemh("python/outputs/sparse_mask_l3.hex", mrom_l3);
    end

    // FSM encoding
    localparam logic [3:0]
        IDLE     = 4'd0,  RECV_PIX = 4'd1, CLR_ACC  = 4'd2, LOAD_W   = 4'd3,
        COMPUTE  = 4'd4,  ADV_COL  = 4'd5, WAIT_V   = 4'd6, CAPTURE  = 4'd7,
        ARGMAX   = 4'd8,  DONE     = 4'd9;

    logic [3:0]  state;
    logic [1:0]  layer;
    logic [9:0]  col_cnt, pix_cnt;
    logic [6:0]  row_cnt;

    // FSM internal signals (pre-pipeline)
    logic fsm_w_load_en, fsm_compute_en, fsm_acc_clear;
    logic [6:0] fsm_w_load_addr;
    logic signed [DWIDTH-1:0] fsm_x_out;

    logic [9:0] cur_rows, cur_inputs;
    always_comb begin
        case (layer)
            2'd0: begin cur_rows = 10'd128; cur_inputs = 10'd784; end
            2'd1: begin cur_rows = 10'd64;  cur_inputs = 10'd128; end
            2'd2: begin cur_rows = 10'd10;  cur_inputs = 10'd64;  end
            default: begin cur_rows = 10'd128; cur_inputs = 10'd784; end
        endcase
    end

    // Input selection
    always_comb begin
        case (layer)
            2'd0:    fsm_x_out = pix_buf[col_cnt];
            2'd1:    fsm_x_out = $signed(l1_out[col_cnt[6:0]]);
            2'd2:    fsm_x_out = $signed(l2_out[col_cnt[5:0]]);
            default: fsm_x_out = pix_buf[col_cnt];
        endcase
    end

    // Synchronous BRAM Reads (1 Cycle Latency)
    logic [DWIDTH-1:0] bram_w_l1, bram_w_l2, bram_w_l3;
    logic [L1_ROWS-1:0] bram_m_l1;
    logic [L2_ROWS-1:0] bram_m_l2;
    logic [L3_ROWS-1:0] bram_m_l3;

    always_ff @(posedge clk) begin
        bram_w_l1 <= wrom_l1[{3'b0, row_cnt} * L1_INPUTS + col_cnt];
        bram_w_l2 <= wrom_l2[{3'b0, row_cnt} * L2_INPUTS + col_cnt];
        bram_w_l3 <= wrom_l3[{3'b0, row_cnt} * L3_INPUTS + col_cnt];
        
        bram_m_l1 <= mrom_l1[col_cnt];
        bram_m_l2 <= mrom_l2[col_cnt];
        bram_m_l3 <= mrom_l3[col_cnt];
    end

    assign layer_sel = layer;

    // =========================================================================
    // MAIN FSM
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE; layer <= 2'd0; col_cnt <= '0; row_cnt <= '0; pix_cnt <= '0;
            fsm_w_load_en <= 1'b0; fsm_w_load_addr <= '0; fsm_compute_en <= 1'b0; 
            fsm_acc_clear <= 1'b0; pred_class <= '0; output_valid <= 1'b0;
        end else begin
            fsm_w_load_en <= 1'b0; fsm_compute_en <= 1'b0; 
            fsm_acc_clear <= 1'b0; output_valid <= 1'b0;

            case (state)
                IDLE: begin
                    layer <= 2'd0; col_cnt <= '0; row_cnt <= '0; 
                    if (start) begin
                        // Catch the very first pixel right now!
                        pix_buf[0] <= $signed(pixel_in);
                        pix_cnt <= 10'd1; // Next byte goes to index 1
                        state <= RECV_PIX;
                    end else begin
                        pix_cnt <= '0;
                    end
                end

                RECV_PIX: begin
                    if (pixel_valid) begin
                        pix_buf[pix_cnt] <= $signed(pixel_in);
                        if (pix_cnt == 10'(L1_INPUTS) - 1) begin
                            pix_cnt <= '0; 
                            state <= CLR_ACC;
                        end else begin
                            pix_cnt <= pix_cnt + 1'b1;
                        end
                    end
                end
                CLR_ACC: begin
                    fsm_acc_clear <= 1'b1; col_cnt <= '0; row_cnt <= '0; state <= LOAD_W;
                end
                LOAD_W: begin
                    fsm_w_load_en   <= 1'b1;
                    fsm_w_load_addr <= row_cnt;
                    if (row_cnt == 7'(cur_rows - 10'd1)) begin
                        row_cnt <= '0; state <= COMPUTE;
                    end else row_cnt <= row_cnt + 1'b1;
                end
                COMPUTE: begin
                    fsm_compute_en <= 1'b1; state <= ADV_COL;
                end
                ADV_COL: begin
                    if (col_cnt == cur_inputs - 1) begin
                        col_cnt <= '0; state <= WAIT_V;
                    end else begin
                        col_cnt <= col_cnt + 1'b1; state <= LOAD_W;
                    end
                end
                WAIT_V: begin
                    if (y_valid) state <= CAPTURE;
                end
                CAPTURE: begin
                    if (layer == 2'd2) state <= ARGMAX;
                    else begin
                        layer <= layer + 1'b1; col_cnt <= '0; row_cnt <= '0; state <= CLR_ACC;
                    end
                end
                ARGMAX: begin
                    logic signed [DWIDTH-1:0] best_val;
                    logic [3:0] best_idx;
                    best_val = $signed(l3_out[0]); best_idx = 4'd0;
                    for (int k = 1; k < L3_ROWS; k++) begin
                        if ($signed(l3_out[k]) > best_val) begin
                            best_val = $signed(l3_out[k]); best_idx = 4'(k);
                        end
                    end
                    pred_class <= best_idx; state <= DONE;
                end
                DONE: begin
                    output_valid <= 1'b1; state <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end

    // =========================================================================
    // OUTPUT PIPELINE (Resolves BRAM Latency & Routing Fanout)
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w_load_en <= 0; w_load_addr <= '0; w_load_data <= '0;
            compute_en <= 0; acc_clear <= 0; x_out <= '0;
            row_en_l1 <= '0; row_en_l2 <= '0; row_en_l3 <= '0;
        end else begin
            w_load_en   <= fsm_w_load_en;
            w_load_addr <= fsm_w_load_addr;
            compute_en  <= fsm_compute_en;
            acc_clear   <= fsm_acc_clear;
            x_out       <= fsm_x_out;

            case (layer)
                2'd0: w_load_data <= bram_w_l1;
                2'd1: w_load_data <= bram_w_l2;
                2'd2: w_load_data <= bram_w_l3;
                default: w_load_data <= bram_w_l1;
            endcase

            row_en_l1 <= bram_m_l1;
            row_en_l2 <= (col_cnt < 10'd128) ? bram_m_l2 : '0;
            row_en_l3 <= (col_cnt < 10'd64)  ? bram_m_l3 : '0;
        end
    end

endmodule
