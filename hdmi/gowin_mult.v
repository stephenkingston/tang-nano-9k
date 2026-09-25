// Registered 18x18 multiply on a Gowin DSP block: p = a * b, one clock after a and b.
// Yosys does not infer Gowin DSPs, so a plain "*" would be built from logic cells.
// Define SIM to use a behavioural model instead (for Icarus Verilog).
module dsp_mul18 #(
    parameter A_SIGNED = 1,
    parameter B_SIGNED = 1
) (
    input  wire        clk,
    input  wire [17:0] a,
    input  wire [17:0] b,
    output wire [35:0] p
);
`ifdef SIM
    wire [35:0] ax = A_SIGNED ? {{18{a[17]}}, a} : {18'd0, a};
    wire [35:0] bx = B_SIGNED ? {{18{b[17]}}, b} : {18'd0, b};
    reg  [35:0] r  = 36'd0;
    always @(posedge clk)
        r <= ax * bx;
    assign p = r;
`else
    MULT18X18 #(
        .AREG(1'b0), .BREG(1'b0), .OUT_REG(1'b1), .PIPE_REG(1'b0),
        .ASIGN_REG(1'b0), .BSIGN_REG(1'b0), .SOA_REG(1'b0), .MULT_RESET_MODE("SYNC")
    ) mult (
        .A(a), .B(b), .SIA(18'd0), .SIB(18'd0),
        .ASIGN(A_SIGNED != 0), .BSIGN(B_SIGNED != 0), .ASEL(1'b0), .BSEL(1'b0),
        .CE(1'b1), .CLK(clk), .RESET(1'b0),
        .DOUT(p), .SOA(), .SOB()
    );
`endif
endmodule
