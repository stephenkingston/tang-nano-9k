// Tang Nano 9K: 640x480 or 720x480 @ 60 Hz video out of the HDMI port (DVI signalling).
//
// MODE 0: 640x480. 27 MHz --rPLL--> 126 MHz serial clock --CLKDIV/5--> 25.2 MHz pixel clock.
// MODE 1: 720x480 (480p, as in VGA text mode's 9-pixel-wide characters). 135 MHz -> 27 MHz.
// Each pixel is TMDS encoded to 10 bits and shifted out by an OSER10 (DDR, 5 fast clocks).
//
// The scan position (x, y) is output every pixel clock; the caller must present the
// colour of that pixel on rgb exactly PIPE clocks later. Sync and blanking are delayed
// by the same amount so everything lines up.
module dvi_tx #(
    parameter PIPE = 1,                 // clocks from (x, y) to the matching rgb
    parameter MODE = 0                  // 0: 640x480, 1: 720x480
) (
    input  wire        clk_27,          // 27 MHz oscillator
    output wire        clk_pix,         // 25.2 MHz pixel clock
    output wire        reset,           // high until the PLL is locked
    output reg  [9:0]  x = 10'd0,       // 0..799 (0..857), visible when < 640 (720)
    output reg  [9:0]  y = 10'd0,       // 0..524, visible when < 480
    output wire        frame,           // one-clock pulse at the start of vertical blanking
    input  wire [23:0] rgb,             // {r, g, b} for the pixel issued PIPE clocks ago
    output wire        tmds_clk_p,
    output wire        tmds_clk_n,
    output wire [2:0]  tmds_d_p,        // 0 = blue, 1 = green, 2 = red
    output wire [2:0]  tmds_d_n
);
    // ---------------------------------------------------------------- clocks
    wire clk_x5, pll_lock;

    rPLL #(
        .FCLKIN("27"),
        .DEVICE("GW1N-9C"),
        .IDIV_SEL(MODE ? 0 : 2),    // 27 / 3  =   9 MHz reference   (or 27 / 1)
        .FBDIV_SEL(MODE ? 4 : 13),  //  9 * 14 = 126 MHz out         (or 27 * 5 = 135 MHz)
        .ODIV_SEL(4),               // VCO = 126 * 4 = 504 MHz       (or 540 MHz)
        .DYN_IDIV_SEL("false"),
        .DYN_FBDIV_SEL("false"),
        .DYN_ODIV_SEL("false"),
        .DYN_SDIV_SEL(2),
        .PSDA_SEL("0000"),
        .DYN_DA_EN("true"),
        .DUTYDA_SEL("1000"),
        .CLKOUT_FT_DIR(1'b1),
        .CLKOUTP_FT_DIR(1'b1),
        .CLKOUT_DLY_STEP(0),
        .CLKOUTP_DLY_STEP(0),
        .CLKFB_SEL("internal"),
        .CLKOUT_BYPASS("false"),
        .CLKOUTP_BYPASS("false"),
        .CLKOUTD_BYPASS("false"),
        .CLKOUTD_SRC("CLKOUT"),
        .CLKOUTD3_SRC("CLKOUT")
    ) pll (
        .CLKIN(clk_27),
        .CLKOUT(clk_x5),
        .LOCK(pll_lock),
        .CLKOUTP(),
        .CLKOUTD(),
        .CLKOUTD3(),
        .RESET(1'b0),
        .RESET_P(1'b0),
        .CLKFB(1'b0),
        .FBDSEL(6'd0),
        .IDSEL(6'd0),
        .ODSEL(6'd0),
        .PSDA(4'd0),
        .DUTYDA(4'd0),
        .FDLY(4'd0)
    );

    CLKDIV #(.DIV_MODE("5")) pixdiv (
        .HCLKIN(clk_x5),
        .RESETN(pll_lock),
        .CLKOUT(clk_pix)
    );

    // Hold everything in reset until the PLL has been locked for a few pixel clocks.
    reg [3:0] rst_cnt = 4'd0;
    assign reset = ~rst_cnt[3];
    always @(posedge clk_pix or negedge pll_lock)
        if (!pll_lock)        rst_cnt <= 4'd0;
        else if (!rst_cnt[3]) rst_cnt <= rst_cnt + 1'b1;

    // ---------------------------------------------------------------- 640x480 / 720x480 @ 60 Hz timing
    localparam H_ACTIVE = MODE ? 720 : 640, H_FP = 16, H_SYNC = MODE ? 62 : 96, H_TOTAL = MODE ? 858 : 800;
    localparam V_ACTIVE = 480, V_FP = MODE ? 9 : 10, V_SYNC = MODE ? 6 : 2, V_TOTAL = 525;

    always @(posedge clk_pix) begin
        if (reset) begin
            x <= 10'd0;
            y <= 10'd0;
        end else if (x == H_TOTAL - 1) begin
            x <= 10'd0;
            y <= (y == V_TOTAL - 1) ? 10'd0 : y + 1'b1;
        end else begin
            x <= x + 1'b1;
        end
    end

    assign frame = (x == 0) && (y == V_ACTIVE);

    // Blanking and sync for (x, y), delayed PIPE clocks to line up with rgb.
    wire de0 =  (x < H_ACTIVE) && (y < V_ACTIVE);
    wire hs0 = ~((x >= H_ACTIVE + H_FP) && (x < H_ACTIVE + H_FP + H_SYNC));  // negative polarity
    wire vs0 = ~((y >= V_ACTIVE + V_FP) && (y < V_ACTIVE + V_FP + V_SYNC));  // negative polarity

    reg [PIPE-1:0] de_sr = {PIPE{1'b0}};
    reg [PIPE-1:0] hs_sr = {PIPE{1'b1}};
    reg [PIPE-1:0] vs_sr = {PIPE{1'b1}};

    always @(posedge clk_pix) begin
        de_sr <= (de_sr << 1) | de0;
        hs_sr <= (hs_sr << 1) | hs0;
        vs_sr <= (vs_sr << 1) | vs0;
    end

    wire de    = de_sr[PIPE-1];
    wire hsync = hs_sr[PIPE-1];
    wire vsync = vs_sr[PIPE-1];

    // ---------------------------------------------------------------- TMDS encode + serialise
    wire [9:0] tmds_b, tmds_g, tmds_r;

    tmds_encoder enc_b (.clk(clk_pix), .d(rgb[7:0]),   .c({vsync, hsync}), .de(de), .q(tmds_b));
    tmds_encoder enc_g (.clk(clk_pix), .d(rgb[15:8]),  .c(2'b00),          .de(de), .q(tmds_g));
    tmds_encoder enc_r (.clk(clk_pix), .d(rgb[23:16]), .c(2'b00),          .de(de), .q(tmds_r));

    // Clock lane carries 5 ones then 5 zeros per pixel, serialised like the data lanes.
    wire [9:0] lane [0:3];
    assign lane[0] = tmds_b;
    assign lane[1] = tmds_g;
    assign lane[2] = tmds_r;
    assign lane[3] = 10'b0000011111;

    wire [3:0] ser;

    genvar n;
    generate
        for (n = 0; n < 4; n = n + 1) begin : serialise
            OSER10 oser (
                .D0(lane[n][0]), .D1(lane[n][1]), .D2(lane[n][2]), .D3(lane[n][3]), .D4(lane[n][4]),
                .D5(lane[n][5]), .D6(lane[n][6]), .D7(lane[n][7]), .D8(lane[n][8]), .D9(lane[n][9]),
                .PCLK(clk_pix),
                .FCLK(clk_x5),
                .RESET(reset),
                .Q(ser[n])
            );
        end
    endgenerate

    ELVDS_OBUF obuf [3:0] (
        .I (ser),
        .O ({tmds_clk_p, tmds_d_p}),
        .OB({tmds_clk_n, tmds_d_n})
    );
endmodule
