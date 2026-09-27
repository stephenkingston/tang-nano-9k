// term_aes against term_aes.py: cases from tb_aes.hex (written by term_test.py), each
//   flags  bit 7: keep the key and IV (the first case checks the power-up ones)
//   n      blocks
//   key, iv (16 bytes each), plaintext and ciphertext (16 n bytes each)
// then a 0. For each: set the key and IV, encrypt the plaintext, compare, decrypt, compare.
`timescale 1ns/1ps
module term_aes_tb;
    reg clk = 1'b0;
    always #20 clk = ~clk;

    reg        go = 1'b0, h_we = 1'b0;
    reg  [2:0] op = 3'd0;
    reg  [6:0] nblk = 7'd0;
    reg  [10:0] h_addr = 11'd0;
    reg  [7:0] h_wdata = 8'd0;
    wire [7:0] h_rdata;
    wire       busy;
    term_aes aes (.clk(clk), .go(go), .op(op), .nblk(nblk), .busy(busy), .h_we(h_we), .h_addr(h_addr),
                  .h_wdata(h_wdata), .h_rdata(h_rdata));

    reg [7:0] v [0:65535];
    integer p = 0, n, i, cases = 0, errors = 0, clocks, most = 0;

    task put(input integer a, input [7:0] d);
        begin
            @(negedge clk); h_we = 1'b1; h_addr = a; h_wdata = d;
            @(negedge clk); h_we = 1'b0;
        end
    endtask

    task run(input [2:0] o, input integer blocks);
        begin
            @(negedge clk); op = o; nblk = blocks; go = 1'b1;
            @(negedge clk); go = 1'b0;
            clocks = 1;
            while (busy) begin @(negedge clk); clocks = clocks + 1; end
            if (o >= 3 && clocks / blocks > most) most = clocks / blocks;
        end
    endtask

    task expect_data(input integer from, input integer blocks, input [8*8-1:0] what);
        integer j, bad;
        begin
            bad = 0;
            for (j = 0; j < 16 * blocks; j = j + 1) begin
                @(negedge clk); h_addr = j;
                @(negedge clk);
                if (h_rdata !== v[from + j]) begin
                    if (!bad) $display("FAIL: aes case %0d %0s: byte %0d is %02x, not %02x", cases, what, j, h_rdata,
                                       v[from + j]);
                    bad = 1;
                end
            end
            errors = errors + bad;
        end
    endtask

    initial begin
        $readmemh("tb_aes.hex", v);
        #100;
        while (v[p] != 8'd0) begin
            n = v[p + 1];
            if (!v[p][7]) begin
                for (i = 0; i < 16; i = i + 1) put(i, v[p + 2 + i]);
                run(3'd1, 0);
                for (i = 0; i < 16; i = i + 1) put(i, v[p + 18 + i]);
                run(3'd2, 0);
            end
            for (i = 0; i < 16 * n; i = i + 1) put(i, v[p + 34 + i]);
            run(3'd3, n);
            expect_data(p + 34 + 16 * n, n, "encrypt");
            run(3'd4, n);
            expect_data(p + 34, n, "decrypt");
            p = p + 34 + 32 * n;
            cases = cases + 1;
        end
        if (errors == 0)
            $display("ok   aes: %0d cases encrypted and decrypted, %0d clocks a block at most", cases, most);
        $finish;
    end
endmodule
