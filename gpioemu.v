/* verilator lint_off UNUSED */
/* verilator lint_off UNDRIVEN */
/* verilator lint_off MULTIDRIVEN */
/* verilator lint_off COMBDLY */
/* verilator lint_off WIDTH */
/* verilator lint_off BLKSEQ */

module gpioemu(
    input  wire        clk,
    input  wire        n_reset,
    input  wire        srd,
    input  wire        swr,
    input  wire        gpio_latch,
    input  wire [15:0] saddress,
    input  wire [31:0] sdata_in,
    input  wire [31:0] gpio_in,
    output reg  [31:0] sdata_out,
    output wire [31:0] gpio_out,
    output wire [31:0] gpio_in_s_insp
);

    // apparently te rzeczy musza tu byc bo inaczej nic nie dziala
    assign gpio_out       = 32'h0;
    assign gpio_in_s_insp = gpio_in_s;  

    // stany FSM
    parameter IDLE      = 3'd0;
    parameter START     = 3'd1;
    parameter DIVIDE    = 3'd2;
    parameter NORMALIZE = 3'd3;
    parameter DONE      = 3'd4;
    parameter ERROR     = 3'd5;

    // wartosci CTRL i STATUS, ctrl to sterowanie od linuxa a status to kontrolne veriloga
    parameter CTRL_START   = 32'h1;
    parameter CTRL_ABORT   = 32'h2;
    parameter STATUS_IDLE  = 32'h0;
    parameter STATUS_BUSY  = 32'h1;
    parameter STATUS_DONE  = 32'h2;
    parameter STATUS_ERROR = 32'h3;

    // adresy rejestrow
    parameter ADDR_ARG1_L = 16'h00D0;
    parameter ADDR_ARG1_H = 16'h00D8;
    parameter ADDR_ARG2_L = 16'h00E0;
    parameter ADDR_ARG2_H = 16'h00E8;
    parameter ADDR_STATUS = 16'h00F0;
    parameter ADDR_RES_L  = 16'h00F8;
    parameter ADDR_RES_H  = 16'h0100;
    parameter ADDR_CTRL   = 16'h0108;

    // rejestry komunikacji miedzy c a verilogiem
    reg [63:0] arg1_reg;
    reg [63:0] arg2_reg;
    reg [63:0] result_reg;
    reg [31:0] status_reg;
    reg [2:0]  state;
    reg [31:0] ctrl_reg;

    // to tez musi tu byc z jakiegos powodu
    reg [31:0] gpio_in_s;

    // rejestry robocze dzielenia
    reg [53:0] rem_hi;
    reg [53:0] rem_lo;
    reg [53:0] quo;
    reg [53:0] divisor;
    reg [5:0]  div_cnt;
    reg        res_sign;
    reg [10:0] res_exp;

    // mantysy 54-bit z dolaczonym bitem ukrytym
    // Format kernela: sign[63], mantysa[62:10], exp[9:0]
    wire [53:0] a1_sig = {1'b1, arg1_reg[62:10]};
    wire [53:0] a2_sig = {1'b1, arg2_reg[62:10]};

    // GPIO latch - wsm nie wiem po co mi on jest xd
    always @(posedge gpio_latch) begin
        gpio_in_s <= gpio_in;
    end

    // =========================================================
    // BLOK 1: Zapis z magistrali
    // =========================================================
    // w zboczu narastajacym zapisu verilog zapisuje wszystkie wejscia
    always @(posedge swr) begin
        case (saddress)
            ADDR_ARG1_L: arg1_reg[31:0]  <= sdata_in;
            ADDR_ARG1_H: arg1_reg[63:32] <= sdata_in;
            ADDR_ARG2_L: arg2_reg[31:0]  <= sdata_in;
            ADDR_ARG2_H: arg2_reg[63:32] <= sdata_in;
            ADDR_CTRL:   ctrl_reg        <= sdata_in;
            default: ;
        endcase
    end

    // =========================================================
    // BLOK 1b: Reset asynchroniczny (negedge n_reset)
    // =========================================================
    // przy spadku z 1 na 0 resetu, robi sie reset wszystkiego do 0
    always @(negedge n_reset) begin
        arg1_reg   <= 64'h0;
        arg2_reg   <= 64'h0;
        ctrl_reg   <= 32'h0;
        state      <= IDLE;
        status_reg <= STATUS_IDLE;
        result_reg <= 64'h0;
        rem_hi     <= 54'h0;
        rem_lo     <= 54'h0;
        quo        <= 54'h0;
        divisor    <= 54'h0;
        div_cnt    <= 6'h0;
        res_sign   <= 1'b0;
        res_exp    <= 11'h0;
    end

    // =========================================================
    // BLOK 2: FSM + dzielenie (posedge clk)
    // =========================================================
    always @(posedge clk) begin
        case (state)

            // stan idle po prostu czeka
            IDLE: begin
                // ale jak zobaczy sygnal start to zimenia stan na start, ale czysci rejestr start zeby nie loopowac sie
                if (ctrl_reg == CTRL_START) begin
                    ctrl_reg <= 32'h0;
                    state    <= START;
                end
            end

            START: begin
                // zmiana stanu na busy zeby nie bylo w tym czasie zadnej operacji
                status_reg <= STATUS_BUSY;
                // jak jest dzielenie przez 0 to daje error i jest stop
                if (arg2_reg == 64'h0) begin
                    status_reg <= STATUS_ERROR;
                    state      <= ERROR;
                end else begin
                    // procedura dzielenia dziala dziwnie xd
                    res_sign <= arg1_reg[63] ^ arg2_reg[63];
                    res_exp  <= {1'b0, arg1_reg[9:0]} - {1'b0, arg2_reg[9:0]} + 11'd511;
                    // dzielna przesunieta o 1 w prawo (zapewnia quo[53]=1 po 54 krokach)
                    rem_hi   <= {1'b0, a1_sig[53:1]};
                    rem_lo   <= {a1_sig[0], 53'h0};
                    quo      <= 54'h0;
                    divisor  <= a2_sig;
                    div_cnt  <= 6'd0;
                    state    <= DIVIDE;
                end
            end

            DIVIDE: begin
                // jak trzeba przerwac to przerywa sie
                if (ctrl_reg == CTRL_ABORT) begin
                    ctrl_reg   <= 32'h0;
                    status_reg <= STATUS_IDLE;
                    state      <= IDLE;
                end else begin
                    // tu zaczyna sie wsm caly algorytm restoring division
                    begin : div_step
                        reg [54:0] shifted_hi;
                        reg [55:0] sub_result;
                        shifted_hi = {rem_hi[53:0], rem_lo[53]};
                        sub_result = {1'b0, shifted_hi} - {2'b0, divisor};

                        if (sub_result[55] == 1'b0) begin
                            // brak pozyczki: bit ilorazu = 1
                            quo    <= {quo[52:0], 1'b1};
                            rem_hi <= sub_result[53:0];
                            rem_lo <= {rem_lo[52:0], 1'b0};
                        end else begin
                            // pozyczka: bit ilorazu = 0, przywroc reste
                            quo    <= {quo[52:0], 1'b0};
                            rem_hi <= shifted_hi[53:0];
                            rem_lo <= {rem_lo[52:0], 1'b0};
                        end
                    end

                    if (div_cnt == 6'd53)
                        state <= NORMALIZE;
                    else
                        div_cnt <= div_cnt + 6'd1;
                end
            end

            NORMALIZE: begin
                // quo[53] = bit ukryty; format wyjscia: sign[63],  mantysa[62:10],  exp[9:0]
                // znormalizowany aka pierwszy bit jest 1, najstarszy
                if (quo[53] == 1'b1) begin
                    // wynik juz znormalizowany - pomijamy bit ukryty quo[53]
                    result_reg <= {res_sign, quo[52:0], res_exp[9:0]};
                end else begin
                    // niezagnormalizowany - przesuniecie w lewo + dekrementacja expa
                    result_reg <= {res_sign, quo[51:0], 1'b0, res_exp[9:0] - 10'd1};
                end
                status_reg <= STATUS_DONE;
                state      <= DONE;
            end

            DONE: begin
                // jak ma byc kolejne dzielenie to status start i lecimy znowu
                if (ctrl_reg == CTRL_START) begin
                    ctrl_reg <= 32'h0;
                    state    <= START;
                // jak nie to reset i idle
                end else if (ctrl_reg == CTRL_ABORT) begin
                    ctrl_reg   <= 32'h0;
                    status_reg <= STATUS_IDLE;
                    state      <= IDLE;
                end
            end

            ERROR: begin
                // jak jest error to przerywa sie i tyle
                if (ctrl_reg == CTRL_ABORT) begin
                    ctrl_reg   <= 32'h0;
                    status_reg <= STATUS_IDLE;
                    state      <= IDLE;
                end
            end

            default: state <= IDLE;
        endcase
    end

    // =========================================================
    // BLOK 3: Odczyt z magistrali
    // =========================================================
    always @(posedge srd) begin
        // po prostu verilog zapisuje aktualny stan i wypuszcza go do kernela
        sdata_out <= 32'h0;
        case (saddress)
            ADDR_RES_L:  sdata_out <= result_reg[31:0];
            ADDR_RES_H:  sdata_out <= result_reg[63:32];
            ADDR_STATUS: sdata_out <= status_reg;
            ADDR_CTRL:   sdata_out <= ctrl_reg;
            default:     sdata_out <= 32'h0;
        endcase
    end

endmodule