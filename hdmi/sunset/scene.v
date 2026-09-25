// Tang Nano 9K: a parallax pixel-art sunset over a lake, on the HDMI port.
//
// The scene is 320x240 logical pixels, each shown as 2x2 screen pixels. Every pixel is
// composited on the fly from palette-indexed layers held in block RAM (see scene_gen.py,
// which generates the art and scene_params.vh, and contains a reference model of this file).
// Nothing is stored as a frame: sky, sun, water and birds are computed per pixel.
module top (
    input  wire       clk,          // 27 MHz oscillator
    output wire       tmds_clk_p,
    output wire       tmds_clk_n,
    output wire [2:0] tmds_d_p,
    output wire [2:0] tmds_d_n,
    output wire [5:0] led           // active low
);
    wire        clk_pix, reset, frame;
    wire [9:0]  x, y;
    wire [23:0] rgb;

    dvi_tx #(.PIPE(4)) video (
        .clk_27(clk), .clk_pix(clk_pix), .reset(reset), .x(x), .y(y), .frame(frame),
        .rgb(rgb),
        .tmds_clk_p(tmds_clk_p), .tmds_clk_n(tmds_clk_n), .tmds_d_p(tmds_d_p), .tmds_d_n(tmds_d_n)
    );

    scene_render scene (.clk(clk_pix), .x(x), .y(y), .frame(frame), .rgb(rgb));

    assign led = ~{5'b00000, ~reset};
endmodule
