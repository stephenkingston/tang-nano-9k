// Checks tmds_encoder against an independent TMDS decoder:
// every data word must decode back to its input, control tokens must be exact,
// and the running DC balance of the transmitted bits must stay bounded.
`timescale 1ns/1ps
module tmds_encoder_tb;
    reg        clk = 0;
    reg  [7:0] d   = 0;
    reg  [1:0] c   = 0;
    reg        de  = 0;
    wire [9:0] q;

    tmds_encoder dut (.clk(clk), .d(d), .c(c), .de(de), .q(q));

    always #5 clk = ~clk;

    function [7:0] decode(input [9:0] w);
        reg [7:0] v;
        integer k;
        begin
            v = w[9] ? ~w[7:0] : w[7:0];
            decode[0] = v[0];
            for (k = 1; k < 8; k = k + 1)
                decode[k] = w[8] ? (v[k] ^ v[k-1]) : ~(v[k] ^ v[k-1]);
        end
    endfunction

    function [9:0] token(input [1:0] cc);
        case (cc)
            2'b00:   token = 10'b1101010100;
            2'b01:   token = 10'b0010101011;
            2'b10:   token = 10'b0101010100;
            default: token = 10'b1010101011;
        endcase
    endfunction

    integer n, k, errors = 0, balance = 0, worst = 0, words = 0;
    reg [7:0] exp_d;
    reg [1:0] exp_c;
    reg       exp_de;

    initial begin
        for (n = 0; n < 200000; n = n + 1) begin
            // Mostly active video with some blanking; exercise all 256 values and runs of repeats.
            de = ($random % 8) != 0;
            d  = (n < 256) ? n[7:0] : (($random % 4) == 0 ? d : $random);
            c  = $random;
            exp_d = d; exp_c = c; exp_de = de;
            @(posedge clk); #1;

            if (exp_de) begin
                if (decode(q) !== exp_d) begin
                    errors = errors + 1;
                    if (errors < 10) $display("DATA MISMATCH d=%02h q=%b decoded=%02h", exp_d, q, decode(q));
                end
                for (k = 0; k < 10; k = k + 1)
                    balance = balance + (q[k] ? 1 : -1);
                if (balance > worst)  worst = balance;
                if (-balance > worst) worst = -balance;
                words = words + 1;
            end else begin
                balance = 0;
                if (q !== token(exp_c)) begin
                    errors = errors + 1;
                    if (errors < 10) $display("TOKEN MISMATCH c=%b q=%b", exp_c, q);
                end
            end
        end
        $display("checked %0d data words, worst running DC imbalance = %0d bits", words, worst);
        if (errors == 0 && worst <= 20) $display("PASS");
        else                            $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule
