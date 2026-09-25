// Tang Nano 9K: 640x480 @ 60 Hz colour bars on the HDMI port.
//
// LEDs (for when there is no picture): led[0] on = PLL locked, led[1] blinks = pixel clock running.
module top (
    input  wire       clk,          // 27 MHz oscillator
    output wire       tmds_clk_p,
    output wire       tmds_clk_n,
    output wire [2:0] tmds_d_p,
    output wire [2:0] tmds_d_n,
    output wire [5:0] led           // active low
);
    wire       clk_pix, reset, frame;
    wire [9:0] x, y;
    reg  [7:0] r = 8'd0, g = 8'd0, b = 8'd0;

    dvi_tx #(.PIPE(1)) video (
        .clk_27(clk), .clk_pix(clk_pix), .reset(reset), .x(x), .y(y), .frame(frame),
        .rgb({r, g, b}),
        .tmds_clk_p(tmds_clk_p), .tmds_clk_n(tmds_clk_n), .tmds_d_p(tmds_d_p), .tmds_d_n(tmds_d_n)
    );

    // White, yellow, cyan, green, magenta, red, blue, black; 80 pixels each.
    wire [2:0] bar = (x <  80) ? 3'd0 : (x < 160) ? 3'd1 : (x < 240) ? 3'd2 :
                     (x < 320) ? 3'd3 : (x < 400) ? 3'd4 : (x < 480) ? 3'd5 :
                     (x < 560) ? 3'd6 : 3'd7;

    always @(posedge clk_pix) begin
        r <= {8{~bar[1]}};
        g <= {8{~bar[2]}};
        b <= {8{~bar[0]}};
    end

    reg [24:0] beat = 25'd0;
    always @(posedge clk_pix)
        beat <= beat + 1'b1;

    assign led = ~{4'b0000, beat[24], ~reset};
endmodule
