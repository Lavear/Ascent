// =============================================================================
// ASCENT — uart_rx.sv
// UART Receiver: converts serial bit-stream to parallel 8-bit bytes.
//
// Protocol: 8N1 — 8 data bits, No parity, 1 stop bit
//   Idle line = HIGH
//   Start bit = LOW (1 bit period)
//   Data bits = 8 bits, LSB first
//   Stop bit  = HIGH (1 bit period)
//
// Oversampling: sample at 16× the baud rate, sample data at the middle
// of each bit period (cycle 8 of 16) to avoid edge effects.
//
// Parameter: CLK_FREQ and BAUD_RATE determine the oversampling divisor.
//   divisor = CLK_FREQ / (BAUD_RATE * 16)
//   For 50MHz, 9600 baud: divisor = 50_000_000 / (9600 × 16) = 325
// =============================================================================

module uart_rx #(
    parameter int CLK_FREQ  = 50_000_000,
    parameter int BAUD_RATE = 9600
)(
    input  logic       clk,
    input  logic       rst_n,
    input  logic       rx,           // serial input from PC

    output logic [7:0] rx_data,      // received byte
    output logic       rx_valid      // pulses high for 1 cycle when byte ready
);

    // -------------------------------------------------------------------------
    // Oversampling clock divider
    // Generates a 'tick' at 16× the baud rate.
    // At each tick we advance the baud counter by 1.
    // -------------------------------------------------------------------------
    localparam int OVERSAMPLE  = 16;
    localparam int CLK_DIVISOR = CLK_FREQ / (BAUD_RATE * OVERSAMPLE);

    logic [$clog2(CLK_DIVISOR)-1:0] clk_cnt;
    logic                           baud_tick;   // 1 pulse per 1/16 baud period

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            clk_cnt   <= '0;
            baud_tick <= 1'b0;
        end else if (clk_cnt == CLK_DIVISOR - 1) begin
            clk_cnt   <= '0;
            baud_tick <= 1'b1;
        end else begin
            clk_cnt   <= clk_cnt + 1'b1;
            baud_tick <= 1'b0;
        end
    end

    // -------------------------------------------------------------------------
    // Input synchroniser: two flip-flop synchroniser to avoid metastability
    // on the asynchronous rx input. Always synchronise external inputs.
    // -------------------------------------------------------------------------
    logic rx_sync0, rx_sync1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_sync0 <= 1'b1;
            rx_sync1 <= 1'b1;
        end else begin
            rx_sync0 <= rx;
            rx_sync1 <= rx_sync0;
        end
    end

    // -------------------------------------------------------------------------
    // FSM states
    // -------------------------------------------------------------------------
    typedef enum logic [1:0] {
        IDLE  = 2'b00,
        START = 2'b01,
        DATA  = 2'b10,
        STOP  = 2'b11
    } uart_state_t;

    uart_state_t state;

    // -------------------------------------------------------------------------
    // Baud sample counter (counts 0..15 within each bit period)
    // Bit sample counter (counts 0..7 data bits)
    // -------------------------------------------------------------------------
    logic [3:0] baud_cnt;    // 0..15 oversamples per bit
    logic [2:0] bit_cnt;     // 0..7  data bits received
    logic [7:0] shift_reg;   // shift register for incoming bits

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= IDLE;
            baud_cnt  <= '0;
            bit_cnt   <= '0;
            shift_reg <= '0;
            rx_data   <= '0;
            rx_valid  <= 1'b0;
        end else begin
            rx_valid <= 1'b0;   // default: not valid

            case (state)
                // ---------------------------------------------------------
                // IDLE: wait for falling edge (start bit)
                // ---------------------------------------------------------
                IDLE: begin
                    if (!rx_sync1) begin     // rx went LOW → start bit detected
                        state    <= START;
                        baud_cnt <= '0;
                    end
                end

                // ---------------------------------------------------------
                // START: wait 8 ticks to reach middle of start bit, verify low
                // ---------------------------------------------------------
                START: begin
                    if (baud_tick) begin
                        if (baud_cnt == 4'd7) begin
                            if (!rx_sync1) begin   // still low → valid start bit
                                state    <= DATA;
                                baud_cnt <= '0;
                                bit_cnt  <= '0;
                            end else begin
                                state <= IDLE;     // glitch — ignore
                            end
                        end else begin
                            baud_cnt <= baud_cnt + 1'b1;
                        end
                    end
                end

                // ---------------------------------------------------------
                // DATA: sample 8 data bits at the middle of each bit period
                // Middle of bit = tick 8 of 16 (baud_cnt == 15 then reset)
                // ---------------------------------------------------------
                DATA: begin
                    if (baud_tick) begin
                        if (baud_cnt == 4'd15) begin
                            baud_cnt          <= '0;
                            shift_reg         <= {rx_sync1, shift_reg[7:1]};  // LSB first
                            if (bit_cnt == 3'd7) begin
                                state   <= STOP;
                                bit_cnt <= '0;
                            end else begin
                                bit_cnt <= bit_cnt + 1'b1;
                            end
                        end else begin
                            baud_cnt <= baud_cnt + 1'b1;
                        end
                    end
                end

                // ---------------------------------------------------------
                // STOP: wait for stop bit, then output data
                // ---------------------------------------------------------
                STOP: begin
                    if (baud_tick) begin
                        if (baud_cnt == 4'd15) begin
                            state    <= IDLE;
                            baud_cnt <= '0;
                            if (rx_sync1) begin     // valid stop bit
                                rx_data  <= shift_reg;
                                rx_valid <= 1'b1;   // pulse valid for 1 cycle
                            end
                            // If stop bit missing: silently discard (framing error)
                        end else begin
                            baud_cnt <= baud_cnt + 1'b1;
                        end
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule