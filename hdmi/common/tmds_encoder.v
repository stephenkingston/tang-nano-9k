// DVI 1.0 TMDS 8b/10b encoder. Output q[0] is transmitted first.
module tmds_encoder (
    input  wire       clk,
    input  wire [7:0] d,      // pixel data, used when de = 1
    input  wire [1:0] c,      // {c1, c0} control bits, used when de = 0
    input  wire       de,     // data enable (active video)
    output reg  [9:0] q = 10'd0
);
    function [3:0] ones8(input [7:0] v);
        integer k;
        begin
            ones8 = 4'd0;
            for (k = 0; k < 8; k = k + 1)
                ones8 = ones8 + v[k];
        end
    endfunction

    // Stage 1: minimise transitions with an XOR or XNOR chain.
    wire [3:0] n1d = ones8(d);
    wire use_xnor = (n1d > 4'd4) || (n1d == 4'd4 && !d[0]);

    reg [8:0] qm;
    integer i;
    always @(*) begin
        qm[0] = d[0];
        for (i = 1; i < 8; i = i + 1)
            qm[i] = use_xnor ? ~(qm[i-1] ^ d[i]) : (qm[i-1] ^ d[i]);
        qm[8] = ~use_xnor;
    end

    // Stage 2: keep the line DC balanced by optionally inverting qm[7:0].
    wire signed [5:0] disp = $signed({1'b0, ones8(qm[7:0]), 1'b0}) - 6'sd8;   // ones - zeros
    reg  signed [5:0] cnt  = 6'sd0;                                         // running disparity

    always @(posedge clk) begin
        if (!de) begin
            cnt <= 6'sd0;
            case (c)
                2'b00:   q <= 10'b1101010100;
                2'b01:   q <= 10'b0010101011;
                2'b10:   q <= 10'b0101010100;
                default: q <= 10'b1010101011;
            endcase
        end else if (cnt == 0 || disp == 0) begin
            q   <= {~qm[8], qm[8], qm[8] ? qm[7:0] : ~qm[7:0]};
            cnt <= qm[8] ? cnt + disp : cnt - disp;
        end else if ((cnt > 0 && disp > 0) || (cnt < 0 && disp < 0)) begin
            q   <= {1'b1, qm[8], ~qm[7:0]};
            cnt <= cnt - disp + (qm[8] ? 6'sd2 : 6'sd0);
        end else begin
            q   <= {1'b0, qm[8], qm[7:0]};
            cnt <= cnt + disp - (qm[8] ? 6'sd0 : 6'sd2);
        end
    end
endmodule
