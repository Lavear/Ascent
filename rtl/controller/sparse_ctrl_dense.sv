// =============================================================================
// ASCENT — sparse_ctrl_dense.sv
// ABLATION RUNS A and B: Dense (no sparsity) variant of sparse_ctrl.sv
//
// ONLY CHANGE from sparse_ctrl.sv (synthesis bypass version):
//   row_en masks set to all 1s — every row fires every cycle, no gating.
//
// Used for:
//   Run A: paired with cim_array_exact → measures exact mult + no gating
//   Run B: paired with cim_array       → measures LOA mult + no gating
//
// The difference Run A power − Run B power = LOA approximate computing savings.
// The difference Run B power − Run C power = sparse gating savings.
// (Run C = current synth.tcl with 50% mask = already done)
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
    // SYNTHESIS BYPASS: High-Entropy Dummy Data (same as sparse_ctrl.sv)
    // =========================================================================
    logic [DWIDTH-1:0] tiny_wrom [0:15];
    logic signed [DWIDTH-1:0] pix_buf [0:15];

    initial begin
        tiny_wrom[0] = 8'h12; tiny_wrom[1] = 8'hF4; tiny_wrom[2] = 8'h28; tiny_wrom[3] = 8'hE1;
        tiny_wrom[4] = 8'h05; tiny_wrom[5] = 8'hA2; tiny_wrom[6] = 8'h44; tiny_wrom[7] = 8'hC8;
        tiny_wrom[8] = 8'h3B; tiny_wrom[9] = 8'h99; tiny_wrom[10]= 8'h1F; tiny_wrom[11]= 8'hD0;
        tiny_wrom[12]= 8'h50; tiny_wrom[13]= 8'h88; tiny_wrom[14]= 8'h0A; tiny_wrom[15]= 8'hEF;

        pix_buf[0] = 8'h00; pix_buf[1] = 8'h1A; pix_buf[2] = 8'h40; pix_buf[3] = 8'h00;
        pix_buf[4] = 8'hE5; pix_buf[5] = 8'h00; pix_buf[6] = 8'h7F; pix_buf[7] = 8'h00;
        pix_buf[8] = 8'h9C; pix_buf[9] = 8'h00; pix_buf[10]= 8'h22; pix_buf[11]= 8'h00;
        pix_buf[12]= 8'h55; pix_buf[13]= 8'h00; pix_buf[14]= 8'hB3; pix_buf[15]= 8'h00;
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
    // Layer dimension mux
    // =========================================================================
    logic [9:0] cur_rows, cur_inputs;

    always_comb begin
        case (layer)
            2'd0: begin cur_rows = 10'd128; cur_inputs = 10'd784; end
            2'd1: begin cur_rows = 10'd64;  cur_inputs = 10'd128; end
            2'd2: begin cur_rows = 10'd10;  cur_inputs = 10'd64;  end
            default: begin cur_rows = 10'd128; cur_inputs = 10'd784; end
        endcase
    end

    // =========================================================================
    // High-entropy data muxes (same as sparse_ctrl.sv)
    // =========================================================================
    logic [DWIDTH-1:0]      cur_weight;
    logic [3:0]             w_idx;
    logic signed [DWIDTH-1:0] cur_x;

    always_comb begin
        w_idx      = col_cnt[3:0] ^ row_cnt[3:0] ^ col_cnt[7:4];
        cur_weight = tiny_wrom[w_idx];
    end

    always_comb begin
        case (layer)
            2'd0:    cur_x = pix_buf[col_cnt[3:0]];
            2'd1:    cur_x = $signed(l1_out[col_cnt[6:0]]);
            2'd2:    cur_x = $signed(l2_out[col_cnt[5:0]]);
            default: cur_x = pix_buf[col_cnt[3:0]];
        endcase
    end

    // =========================================================================
    // DENSE SPARSITY MASKS — THE ONLY CHANGE FROM sparse_ctrl.sv
    //
    // sparse_ctrl.sv uses:
    //   row_en_l1 = 128'h6A49_B2D6_... (50% clustered sparsity)
    //
    // sparse_ctrl_dense.sv uses:
    //   row_en_l1 = all 1s (EVERY row fires EVERY cycle — no gating at all)
    //
    // This is the "worst case" power — the CIM array at 100% activity.
    // Compare this run's power vs sparse_ctrl.sv run to see gating savings.
    // =========================================================================
    always_comb begin
        row_en_l1 = {L1_ROWS{1'b1}};   // 128 bits all 1 — all rows active
        row_en_l2 = {L2_ROWS{1'b1}};   //  64 bits all 1
        row_en_l3 = {L3_ROWS{1'b1}};   //  10 bits all 1
    end

    assign layer_sel = layer;

    // =========================================================================
    // FSM — identical to sparse_ctrl.sv
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
                    if (start) state <= RECV_PIX;
                end

                RECV_PIX: begin
                    if (pixel_valid) begin
                        pix_buf[pix_cnt[3:0]] <= $signed(pixel_in);
                        if (pix_cnt == 10'(L1_INPUTS) - 1) begin
                            pix_cnt <= '0;
                            state   <= CLR_ACC;
                        end else
                            pix_cnt <= pix_cnt + 1'b1;
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
                    if (row_cnt == 7'(cur_rows - 10'd1)) begin
                        row_cnt <= '0;
                        state   <= COMPUTE;
                    end else
                        row_cnt <= row_cnt + 1'b1;
                end

                COMPUTE: begin
                    x_out      <= cur_x;
                    compute_en <= 1'b1;
                    state      <= ADV_COL;
                end

                ADV_COL: begin
                    if (col_cnt == cur_inputs - 1) begin
                        col_cnt <= '0;
                        state   <= WAIT_V;
                    end else begin
                        col_cnt <= col_cnt + 1'b1;
                        state   <= LOAD_W;
                    end
                end

                WAIT_V: begin
                    if (y_valid) state <= CAPTURE;
                end

                CAPTURE: begin
                    if (layer == 2'd2)
                        state <= ARGMAX;
                    else begin
                        layer   <= layer + 1'b1;
                        col_cnt <= '0;
                        row_cnt <= '0;
                        state   <= CLR_ACC;
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
