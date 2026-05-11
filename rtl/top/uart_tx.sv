// =============================================================================
// ASCENT — uart_tx.sv
// UART Transmitter: converts parallel 8-bit byte to serial bit-stream.
//
// Protocol: 8N1 — 8 data bits, No parity, 1 stop bit
//   tx_start pulse with tx_data → transmits one byte
//   tx_busy goes HIGH during transmission
//   When idle: line is HIGH
// =============================================================================

module uart_tx #(
    parameter int CLK_FREQ  = 50_000_000,
    parameter int BAUD_RATE = 9600
)(
    input  logic       clk,
    input  logic       rst_n,

    input  logic [7:0] tx_data,    // byte to transmit
    input  logic       tx_start,   // pulse high for 1 cycle to begin transmission

    output logic       tx,         // serial output
    output logic       tx_busy     // 1 while transmitting
);

    localparam int CLK_DIVISOR = CLK_FREQ / BAUD_RATE;

    // -------------------------------------------------------------------------
    // Baud rate clock divider — one tick per bit period
    // -------------------------------------------------------------------------
    logic [$clog2(CLK_DIVISOR)-1:0] clk_cnt;
    logic                           baud_tick;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            clk_cnt   <= '0;
            baud_tick <= 1'b0;
        end else if (tx_busy) begin
            if (clk_cnt == CLK_DIVISOR - 1) begin
                clk_cnt   <= '0;
                baud_tick <= 1'b1;
            end else begin
                clk_cnt   <= clk_cnt + 1'b1;
                baud_tick <= 1'b0;
            end
        end else begin
            clk_cnt   <= '0;
            baud_tick <= 1'b0;
        end
    end

    // -------------------------------------------------------------------------
    // FSM
    // -------------------------------------------------------------------------
    typedef enum logic [1:0] {
        IDLE  = 2'b00,
        START = 2'b01,
        DATA  = 2'b10,
        STOP  = 2'b11
    } tx_state_t;

    tx_state_t   state;
    logic [7:0]  shift_reg;
    logic [2:0]  bit_cnt;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= IDLE;
            tx        <= 1'b1;   // idle high
            tx_busy   <= 1'b0;
            shift_reg <= '0;
            bit_cnt   <= '0;
        end else begin
            case (state)
                IDLE: begin
                    tx      <= 1'b1;
                    tx_busy <= 1'b0;
                    if (tx_start) begin
                        state     <= START;
                        shift_reg <= tx_data;
                        tx_busy   <= 1'b1;
                        bit_cnt   <= '0;
                    end
                end

                START: begin
                    tx <= 1'b0;     // start bit
                    if (baud_tick)
                        state <= DATA;
                end

                DATA: begin
                    tx <= shift_reg[0];    // LSB first
                    if (baud_tick) begin
                        shift_reg <= {1'b0, shift_reg[7:1]};
                        if (bit_cnt == 3'd7) begin
                            state   <= STOP;
                            bit_cnt <= '0;
                        end else begin
                            bit_cnt <= bit_cnt + 1'b1;
                        end
                    end
                end

                STOP: begin
                    tx <= 1'b1;    // stop bit
                    if (baud_tick) begin
                        state   <= IDLE;
                        tx_busy <= 1'b0;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule