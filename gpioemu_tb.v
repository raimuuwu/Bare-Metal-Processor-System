    `timescale 1ns/1ps

module gpioemu_tb;

// sygnaly 
reg         clk, n_reset, srd, swr, gpio_latch;
reg  [15:0] saddress;
reg  [31:0] sdata_in, gpio_in;
wire [31:0] sdata_out, gpio_out, gpio_in_s_insp;

gpioemu dut (
    .clk            (clk),
    .n_reset        (n_reset),
    .srd            (srd),
    .swr            (swr),
    .gpio_latch     (gpio_latch),
    .saddress       (saddress),
    .sdata_in       (sdata_in),
    .gpio_in        (gpio_in),
    .sdata_out      (sdata_out),
    .gpio_out       (gpio_out),
    .gpio_in_s_insp (gpio_in_s_insp)
);

// zegar 100MHz (10ns okres)
initial clk = 0;
always  #5 clk = ~clk;

// adresy rejestrow 
localparam ADDR_A1_L  = 16'h00D0;
localparam ADDR_A1_H  = 16'h00D8;
localparam ADDR_A2_L  = 16'h00E0;
localparam ADDR_A2_H  = 16'h00E8;
localparam ADDR_STAT  = 16'h00F0;
localparam ADDR_RES_L = 16'h00F8;
localparam ADDR_RES_H = 16'h0100;
localparam ADDR_CTRL  = 16'h0108;

// statusy
localparam ST_IDLE  = 32'h0;
localparam ST_BUSY  = 32'h1;
localparam ST_DONE  = 32'h2;
localparam ST_ERROR = 32'h3;

// liczniki testow
integer ok_cnt, fail_cnt;


// taski pomocnicze
task zapis;
    input [15:0] addr;
    input [31:0] data;
    begin
        @(negedge clk);
        saddress = addr;
        sdata_in = data;
        swr      = 1;
        srd      = 0;
        @(posedge clk); #1;
        swr      = 0;
        saddress = 16'h0;
        sdata_in = 32'h0;
    end
endtask

task odczyt;
    input  [15:0] addr;
    output [31:0] data;
    begin
        @(negedge clk);
        saddress = addr;
        srd      = 1;
        swr      = 0;
        #2;
        data     = sdata_out;
        @(posedge clk); #1;
        srd      = 0;
        saddress = 16'h0;
    end
endtask

// czeka az status bedzie DONE lub ERROR
task czekaj;
    output [31:0] status;
    integer cnt;
    begin
        cnt    = 0;
        status = ST_BUSY;
        while ((status == ST_BUSY) && (cnt < 80)) begin
            @(posedge clk); @(negedge clk);
            saddress = ADDR_STAT;
            srd      = 1;
            swr      = 0;
            #2;
            status   = sdata_out;
            @(posedge clk); #1;
            srd      = 0;
            saddress = 16'h0;
            cnt      = cnt + 1;
        end
        if (cnt >= 80)
            $display("  [TIMEOUT] po %0d cyklach, status=0x%0h", cnt, status);
    end
endtask

// wysyla argumenty, startuje, czeka, sprawdza wynik
task test;
    input [63:0]  a1, a2, oczekiwane;
    input [255:0] opis;
    reg   [31:0]  res_lo, res_hi, status;
    reg   [63:0]  wynik;
    begin
        $display("\n[ %0s ]", opis);

        // wpisz argumenty (najpierw low, potem high)
        zapis(ADDR_A1_L, a1[31:0]);
        zapis(ADDR_A1_H, a1[63:32]);
        zapis(ADDR_A2_L, a2[31:0]);
        zapis(ADDR_A2_H, a2[63:32]);

        // uruchom
        zapis(ADDR_CTRL, 32'h1);

        // czekaj na wynik
        czekaj(status);

        // odczytaj wynik
        odczyt(ADDR_RES_L, res_lo);
        odczyt(ADDR_RES_H, res_hi);
        wynik = {res_hi, res_lo};

        $display("  a1       = 0x%016h", a1);
        $display("  a2       = 0x%016h", a2);
        $display("  wynik    = 0x%016h  (sign=%b exp=%0d mant=0x%014h)", wynik,    wynik[63],    wynik[9:0],    wynik[62:10]);
        $display("  oczekiw. = 0x%016h  (sign=%b exp=%0d mant=0x%014h)", oczekiwane, oczekiwane[63], oczekiwane[9:0], oczekiwane[62:10]);

        if ((wynik === oczekiwane) && (status === ST_DONE)) begin
            $display("  >> OK");
            ok_cnt = ok_cnt + 1;
        end else begin
            $display("  >> FAIL  (status=0x%0h)", status);
            fail_cnt = fail_cnt + 1;
        end

        // zresetuj do IDLE przed kolejnym testem
        zapis(ADDR_CTRL, 32'h2);
        repeat(2) @(posedge clk);
    end
endtask

task test_blad;
    input [63:0]  a1, a2;
    input [255:0] opis;
    reg   [31:0]  status;
    begin
        $display("\n[ %0s ]", opis);

        zapis(ADDR_A1_L, a1[31:0]);
        zapis(ADDR_A1_H, a1[63:32]);
        zapis(ADDR_A2_L, a2[31:0]);
        zapis(ADDR_A2_H, a2[63:32]);
        zapis(ADDR_CTRL, 32'h1);

        czekaj(status);

        $display("  status = 0x%0h", status);
        if (status === ST_ERROR) begin
            $display("  >> OK (ERROR oczekiwany)");
            ok_cnt = ok_cnt + 1;
        end else begin
            $display("  >> FAIL (oczekiwano ERROR=3)");
            fail_cnt = fail_cnt + 1;
        end

        zapis(ADDR_CTRL, 32'h2);
        repeat(2) @(posedge clk);
    end
endtask

// wartosci testowe
// Format: sign[63] | mantissa[62:10] | exp_biased[9:0]

// liczby podstawowe
localparam [63:0] V_1_0   = 64'h00000000000001FF; // 1.0
localparam [63:0] V_2_0   = 64'h0000000000000200; // 2.0
localparam [63:0] V_3_0   = 64'h4000000000000200; // 3.0
localparam [63:0] V_1_5   = 64'h40000000000001FF; // 1.5
localparam [63:0] V_6_0   = 64'h4000000000000201; // 6.0
localparam [63:0] V_N6_0  = 64'hC000000000000201; // -6.0
localparam [63:0] V_N2_0  = 64'h8000000000000200; // -2.0
localparam [63:0] V_N3_0  = 64'hC000000000000200; // -3.0
localparam [63:0] V_10_0  = 64'h2000000000000202; // 10.0
localparam [63:0] V_4_0   = 64'h0000000000000201; // 4.0
localparam [63:0] V_2_5   = 64'h2000000000000200; // 2.5

// 1/3 i 1/7 (ulamki cykliczne)
localparam [63:0] V_7_0        = 64'h6000000000000201; // 7.0
localparam [63:0] V_1div3      = 64'h2AAAAAAAAAAAA9FD; // 0.333...
localparam [63:0] V_1div7      = 64'h12492492492491FC; // 0.142857...

// 22/7 i 355/113 (~pi)
localparam [63:0] V_22_0       = 64'h3000000000000203; // 22.0
localparam [63:0] V_22div7     = 64'h4924924924924A00; // 3.14285...
localparam [63:0] V_355_0      = 64'h3180000000000207; // 355.0
localparam [63:0] V_113_0      = 64'h6200000000000205; // 113.0
localparam [63:0] V_355div113  = 64'h490FDBC090FDC200; // 3.14159292...

// nieokragle wartosci zmiennoprzecinkowe
localparam [63:0] V_1p23456    = 64'h1E060FE47991C1FF; // 1.23456
localparam [63:0] V_7p89012    = 64'h7C7BDCF0307F2201; // 7.89012
localparam [63:0] V_1p23div7p89= 64'h20396FC3231D89FC; // 0.156469...
localparam [63:0] V_9p87654    = 64'h1E064ECE9A2C6A02; // 9.87654
localparam [63:0] V_3p21098    = 64'h4D80B242070B9200; // 3.21098
localparam [63:0] V_9p87div3p21= 64'h44DAF791D9967A00; // 3.07586...
localparam [63:0] V_0p1        = 64'h4CCCCCCCCCCCD1FB; // 0.1
localparam [63:0] V_0p3        = 64'h19999999999999fd; // 0.3 
localparam [63:0] V_0p1div0p3  = 64'h2AAAAAAAAAAAB1FD; // 0.333...

// duze wartosci
localparam [63:0] V_1e10       = 64'h1502F90000000220; // 1e10
localparam [63:0] V_1e5        = 64'h435000000000020F; // 1e5 = 100000
localparam [63:0] V_1e15       = 64'h635FA931A0000230; // 1e15
localparam [63:0] V_1e8        = 64'h3EBC200000000219; // 1e8
localparam [63:0] V_1e7        = 64'h1896800000000216; // 1e7

// male wartosci
localparam [63:0] V_1em10      = 64'h5BE6FECEBDEDD9DD; // 1e-10
localparam [63:0] V_1em5       = 64'h27C5AC471B4789EE; // 1e-5
localparam [63:0] V_1em5_r     = 64'h27C5AC471B4781EE; // wynik 1e-10/1e-5
localparam [63:0] V_1em20      = 64'h3CE50864921119BC; // 1e-20
localparam [63:0] V_1em10_r    = 64'h5BE6FECEBDEDD1DD; // wynik 1e-20/1e-10
localparam [63:0] V_1p5em15    = 64'h582C3B72D80901CD; // 1.5e-15
localparam [63:0] V_2p5em8     = 64'h56BF94D5E57A41E5; // 2.5e-8
localparam [63:0] V_6em8       = 64'h00D9594D234959E7; // 6e-8 = wynik

// a/a = 1
localparam [63:0] V_12345p6789 = 64'h40E6B7318FC50A0C; // 12345.6789

// glowny ciag testow
initial begin
    ok_cnt   = 0;
    fail_cnt = 0;

    n_reset    = 0;
    srd        = 0;
    swr        = 0;
    gpio_latch = 0;
    saddress   = 16'h0;
    sdata_in   = 32'h0;
    gpio_in    = 32'h0;

    repeat(4) @(posedge clk);
    n_reset = 1;
    repeat(2) @(posedge clk);

    $display("=========================================");
    $display("   gpioemu_tb - testy dzielenia float64");
    $display("=========================================");

    // podstawowe
    test(V_1_0,  V_1_0,  V_1_0,  "1.0 / 1.0 = 1.0");
    test(V_6_0,  V_2_0,  V_3_0,  "6.0 / 2.0 = 3.0");
    test(V_3_0,  V_2_0,  V_1_5,  "3.0 / 2.0 = 1.5");
    test(V_10_0, V_4_0,  V_2_5,  "10.0 / 4.0 = 2.5");

    // znaki
    test(V_N6_0, V_2_0,  V_N3_0, "-6.0 / 2.0 = -3.0");
    test(V_6_0,  V_N2_0, V_N3_0, "6.0 / -2.0 = -3.0");
    test(V_N6_0, V_N2_0, V_3_0,  "-6.0 / -2.0 = 3.0");

    // ulamki cykliczne
    test(V_1_0,  V_3_0,  V_1div3,     "1.0 / 3.0 (cykliczny)");
    test(V_1_0,  V_7_0,  V_1div7,     "1.0 / 7.0 (cykliczny)");
    test(V_22_0, V_7_0,  V_22div7,    "22.0 / 7.0 (~pi)");
    test(V_355_0,V_113_0,V_355div113, "355.0 / 113.0 (~pi dokladne)");

    // nieokragle zmiennoprzecinkowe
    test(V_1p23456, V_7p89012, V_1p23div7p89, "1.23456 / 7.89012");
    test(V_9p87654, V_3p21098, V_9p87div3p21, "9.87654 / 3.21098");
    test(V_0p1,     V_0p3,     V_0p1div0p3,   "0.1 / 0.3");

    // duze wartosci
    test(V_1e10, V_1e5, V_1e5, "1e10 / 1e5 = 1e5");
    test(V_1e15, V_1e8, V_1e7, "1e15 / 1e8 = 1e7");

    // male wartosci
    test(V_1em10,   V_1em5,   V_1em5_r,  "1e-10 / 1e-5 = 1e-5");
    test(V_1em20,   V_1em10,  V_1em10_r, "1e-20 / 1e-10 = 1e-10");
    test(V_1p5em15, V_2p5em8, V_6em8,    "1.5e-15 / 2.5e-8 = 6e-8");

    // a/a = 1
    test(V_12345p6789, V_12345p6789, V_1_0, "12345.6789 / 12345.6789 = 1.0");

    // dzielenie przez zero
    test_blad(V_6_0,  64'h0, "6.0 / 0.0 => ERROR");
    test_blad(V_N6_0, 64'h0, "-6.0 / 0.0 => ERROR");

    $display("\n=========================================");
    $display("  OK:   %0d", ok_cnt);
    $display("  FAIL: %0d", fail_cnt);
    $display("=========================================");

    $finish;
end

// zabezpieczenie przed nieskonczona symulacja
initial begin
    #1000000;
    $display("FATAL: timeout symulacji");
    $finish;
end

endmodule
