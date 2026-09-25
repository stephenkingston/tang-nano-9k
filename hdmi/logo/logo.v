// Tang Nano 9K: a logo bouncing around a 640x480 HDMI screen, screensaver style.
//
// The logo bitmap (logo.hex, from logo_gen.py) holds 4-bit coverage per pixel, so the
// edges are anti-aliased. It moves 2 px per frame, changes colour every time it hits a
// wall, and all six LEDs flash when it lands exactly in a corner.
module top (
    input  wire       clk,          // 27 MHz oscillator
    output wire       tmds_clk_p,
    output wire       tmds_clk_n,
    output wire [2:0] tmds_d_p,
    output wire [2:0] tmds_d_n,
    output wire [5:0] led           // active low
);
    localparam LOGO_W = 192, LOGO_H = 96;        // must match logo_gen.py
    localparam MAX_X  = 640 - LOGO_W;
    localparam MAX_Y  = 480 - LOGO_H;
    localparam SPEED  = 2;                       // pixels per frame on each axis

    wire        clk_pix, reset, frame;
    wire [9:0]  x, y;
    reg  [23:0] rgb = 24'd0;

    dvi_tx #(.PIPE(2)) video (
        .clk_27(clk), .clk_pix(clk_pix), .reset(reset), .x(x), .y(y), .frame(frame),
        .rgb(rgb),
        .tmds_clk_p(tmds_clk_p), .tmds_clk_n(tmds_clk_n), .tmds_d_p(tmds_d_p), .tmds_d_n(tmds_d_n)
    );

    // ---------------------------------------------------------------- motion (once per frame, in vblank)
    // This start point puts the logo exactly in a corner every ~22 s.
    reg [9:0] px = 10'd100, py = 10'd100;        // top-left corner of the logo
    reg       left = 1'b0, up = 1'b0;            // current direction on each axis
    reg [2:0] colour = 3'd0;
    reg [6:0] flash = 7'd0;                      // frames of LED flashing left
    reg [2:0] blink = 3'd0;

    wire hit_x = left ? (px <= SPEED) : (px >= MAX_X - SPEED);
    wire hit_y = up   ? (py <= SPEED) : (py >= MAX_Y - SPEED);

    always @(posedge clk_pix) begin
        if (frame) begin
            if (hit_x) begin
                px   <= left ? 10'd0 : MAX_X;
                left <= ~left;
            end else begin
                px <= left ? px - SPEED : px + SPEED;
            end

            if (hit_y) begin
                py <= up ? 10'd0 : MAX_Y;
                up <= ~up;
            end else begin
                py <= up ? py - SPEED : py + SPEED;
            end

            if (hit_x || hit_y)
                colour <= colour + 1'b1;

            if (hit_x && hit_y)
                flash <= 7'd120;                 // 2 seconds
            else if (flash != 0)
                flash <= flash - 1'b1;

            blink <= blink + 1'b1;
        end
    end

    assign led = (flash != 0 && blink[2]) ? 6'b000000 : 6'b111111;

    // ---------------------------------------------------------------- palette
    reg [23:0] tint;
    always @(*) begin
        case (colour)
            3'd0: tint = 24'h00A8FF;   // azure
            3'd1: tint = 24'hFF3CAC;   // pink
            3'd2: tint = 24'hFFD60A;   // yellow
            3'd3: tint = 24'h32D74B;   // green
            3'd4: tint = 24'hFF6B00;   // orange
            3'd5: tint = 24'hBF5AF2;   // purple
            3'd6: tint = 24'h64D2FF;   // sky
            3'd7: tint = 24'hFFFFFF;   // white
        endcase
    end

    // ---------------------------------------------------------------- render
    // Clock 0: work out where (x, y) falls in the logo and address the bitmap.
    wire [9:0]  lx     = x - px;                  // wraps to a large value left of the logo
    wire [9:0]  ly     = y - py;
    wire        inside = (lx < LOGO_W) && (ly < LOGO_H);
    wire [14:0] addr   = ly * LOGO_W + lx;

    reg [3:0] logo_rom [0:LOGO_W*LOGO_H-1];
    initial $readmemh("logo.hex", logo_rom);

    // Clock 1: bitmap coverage for this pixel is available.
    reg [3:0] alpha     = 4'd0;
    reg       inside_d  = 1'b0;
    always @(posedge clk_pix) begin
        alpha    <= logo_rom[addr];
        inside_d <= inside;
    end

    // Clock 2: scale the tint by coverage (a/15 ~= a*17/256) over a black background.
    function [7:0] shade(input [7:0] c, input [3:0] a);
        reg [15:0] p;
        begin
            p     = c * a;
            shade = (p + (p << 4)) >> 8;
        end
    endfunction

    always @(posedge clk_pix)
        rgb <= inside_d ? {shade(tint[23:16], alpha), shade(tint[15:8], alpha), shade(tint[7:0], alpha)}
                        : 24'h000000;
endmodule
