// Tang Nano 9K: fill the 6 onboard LEDs one at a time from led[0] to led[5],
// then empty them in reverse (led[5] off first), and repeat.
module top (
    input  wire       clk,    // 27 MHz oscillator
    output wire [5:0] led     // active low
);
    localparam CLK_HZ    = 27_000_000;
    localparam STEP_HZ   = 12;                  // one LED changes 12 times per second
    localparam STEP_DIV  = CLK_HZ / STEP_HZ;

    reg [21:0] div = 22'd0;
    reg [5:0]  bar = 6'b000000;                 // lit LEDs, always a run starting at led[0]
    reg        dir = 1'b0;                      // 0 = filling, 1 = emptying

    always @(posedge clk) begin
        if (div == STEP_DIV - 1) begin
            div <= 22'd0;
            if (!dir) begin
                bar <= {bar[4:0], 1'b1};
                if (bar[4]) dir <= 1'b1;        // about to be full: start emptying
            end else begin
                bar <= bar >> 1;
                if (!bar[1]) dir <= 1'b0;       // about to be empty: start filling
            end
        end else begin
            div <= div + 1'b1;
        end
    end

    assign led = ~bar;
endmodule
