// Colour of screen pixel (x, y), 4 clocks later.
module scene_render #(
    parameter T0 = 0,               // frame number to start at (for simulation)
    parameter FRONT = 1             // 0 leaves out the foreground shore (saves 7 block RAMs)
) (
    input  wire        clk,
    input  wire [9:0]  x,
    input  wire [9:0]  y,
    input  wire        frame,       // start of vertical blanking: advance the animation
    output reg  [23:0] rgb = 24'd0
);
    `include "scene_params.vh"

    // ---------------------------------------------------------------- ROMs
    reg [1:0]  stars_rom     [0:STARS_H*LW-1];
    reg [1:0]  clouds_rom    [0:CLOUDS_H*STRIP_W-1];
    reg [1:0]  mountains_rom [0:MOUNT_H*STRIP_W-1];
    reg [1:0]  hills_rom     [0:HILLS_H*STRIP_W-1];
    (* rom_style = "logic" *) reg [8:0]  sky_rom    [0:HORIZON-1];   // {band, dither threshold}
    (* rom_style = "logic" *) reg [3:0]  ripple_rom [0:511];         // signed x offset
    (* rom_style = "logic" *) reg [0:0]  bird_rom   [0:255];         // 2 frames of 16x8
    reg [23:0] palette_rom   [0:63];

    initial begin
        $readmemh("scene_stars.hex",     stars_rom);
        $readmemh("scene_clouds.hex",    clouds_rom);
        $readmemh("scene_mountains.hex", mountains_rom);
        $readmemh("scene_hills.hex",     hills_rom);
        $readmemh("scene_sky.hex",       sky_rom);
        $readmemh("scene_ripple.hex",    ripple_rom);
        $readmemh("scene_bird.hex",      bird_rom);
        $readmemh("scene_palette.hex",   palette_rom);
    end

    // ---------------------------------------------------------------- animation state
    // Scroll positions are 9.8 fixed point, so they wrap at the 512-pixel strip width.
    reg [15:0] t      = T0;
    reg [16:0] sc_c   = T0 * SPD_CLOUDS;
    reg [16:0] sc_m   = T0 * SPD_MOUNT;
    reg [16:0] sc_h   = T0 * SPD_HILLS;
    reg [16:0] sc_f   = T0 * SPD_FRONT;
    reg [11:0] flock  = T0 * BIRD_SPD;      // 9.3 fixed point

    always @(posedge clk) begin
        if (frame) begin
            t     <= t + 1'b1;
            sc_c  <= sc_c + SPD_CLOUDS;
            sc_m  <= sc_m + SPD_MOUNT;
            sc_h  <= sc_h + SPD_HILLS;
            sc_f  <= sc_f + SPD_FRONT;
            flock <= flock + BIRD_SPD;
        end
    end

    // ---------------------------------------------------------------- clock A: logical position, water
    wire [8:0] lx    = x[9:1];
    wire [8:0] ly    = y[9:1];
    wire       water = ly >= HORIZON;
    wire [8:0] d     = ly - HORIZON;                    // rows below the horizon
    wire [4:0] phase = ly * 5 + t[5:1];

    reg [8:0]        lxA = 0, lyA = 0;
    reg [7:0]        ryA = 0;                            // row to sample: mirrored in the water
    reg [6:0]        dA  = 0;
    reg              waterA = 0;
    reg signed [3:0] ripA = 0;

    always @(posedge clk) begin
        lxA    <= lx;
        lyA    <= ly;
        waterA <= water;
        dA     <= d[6:0];
        ryA    <= water ? 2 * HORIZON - 1 - ly : ly;
        ripA   <= water ? ripple_rom[{d[6:3], phase}] : 4'sd0;
    end

    // ---------------------------------------------------------------- clock B: addresses and per-pixel tests
    wire signed [10:0] sx = $signed({2'b00, lxA}) + ripA;       // rippled x

    function in_rows(input [8:0] row, input integer top, input integer height);
        in_rows = row >= top && row < top + height;
    endfunction

    wire [8:0]  col_c   = sx[8:0] + sc_c[16:8];
    wire [8:0]  col_m   = sx[8:0] + sc_m[16:8];
    wire [8:0]  col_h   = sx[8:0] + sc_h[16:8];
    wire [8:0]  col_f   = lxA     + sc_f[16:8];
    wire [15:0] addr_s  = (lyA - STARS_TOP)  * LW      + lxA;
    wire [15:0] addr_c  = (ryA - CLOUDS_TOP) * STRIP_W + col_c;
    wire [15:0] addr_m  = (ryA - MOUNT_TOP)  * STRIP_W + col_m;
    wire [15:0] addr_h  = (ryA - HILLS_TOP)  * STRIP_W + col_h;
    wire [15:0] addr_f  = (lyA - FRONT_TOP)  * STRIP_W + col_f;

    // Sun: distance from its centre, only needed within 64 pixels.
    wire signed [10:0] dx  = sx - SUN_X;
    wire signed [10:0] dy  = $signed({3'b000, ryA}) - SUN_Y;
    wire        [10:0] adx = dx < 0 ? -dx : dx;
    wire        [10:0] ady = dy < 0 ? -dy : dy;

    // Birds: the first sprite box containing the pixel picks the sprite pixel.
    wire [8:0] flock_x = flock[11:3];

    function signed [2:0] bob(input [2:0] k);
        bob = BOB[3 * k +: 3];
    endfunction

    wire [8:0]        bx0 = lxA - (flock_x + BIRD0_X);
    wire [8:0]        bx1 = lxA - (flock_x + BIRD1_X);
    wire [8:0]        bx2 = lxA - (flock_x + BIRD2_X);
    wire signed [9:0] by0 = $signed({1'b0, lyA}) - BIRD0_Y - bob(t[5:3]);
    wire signed [9:0] by1 = $signed({1'b0, lyA}) - BIRD1_Y - bob(t[5:3] + 3'd3);
    wire signed [9:0] by2 = $signed({1'b0, lyA}) - BIRD2_Y - bob(t[5:3] + 3'd6);
    wire hit0 = bx0 < 16 && by0 >= 0 && by0 < 8;
    wire hit1 = bx1 < 16 && by1 >= 0 && by1 < 8;
    wire hit2 = bx2 < 16 && by2 >= 0 && by2 < 8;
    wire [7:0] bird_addr = hit0 ? {t[3],  by0[2:0], bx0[3:0]} :
                           hit1 ? {~t[3], by1[2:0], bx1[3:0]} :
                                  {t[3],  by2[2:0], bx2[3:0]};

    // Water sparkles: pseudo-random pixels in a column under the sun, reshuffled every 8 frames.
    function [15:0] hash16(input [15:0] v);
        reg [15:0] a;
        begin
            a      = v ^ (v << 7);
            a      = a ^ (a >> 9);
            hash16 = a ^ (a << 8);
        end
    endfunction

    wire [15:0] h = hash16(hash16({lyA[6:0], lxA}) ^ {3'b000, t[15:3]});

    reg [3:0] bayer;
    always @(*) begin
        case ({lyA[1:0], lxA[1:0]})
            4'h0: bayer = 0;  4'h1: bayer = 8;  4'h2: bayer = 2;  4'h3: bayer = 10;
            4'h4: bayer = 12; 4'h5: bayer = 4;  4'h6: bayer = 14; 4'h7: bayer = 6;
            4'h8: bayer = 3;  4'h9: bayer = 11; 4'hA: bayer = 1;  4'hB: bayer = 9;
            4'hC: bayer = 15; 4'hD: bayer = 7;  4'hE: bayer = 13; 4'hF: bayer = 5;
        endcase
    end

    reg [1:0] vs = 0, vc = 0, vm = 0, vh = 0;
    wire [1:0] vf;

    generate
        if (FRONT) begin : g_front
            reg [1:0] front_rom [0:FRONT_H*STRIP_W-1];
            reg [1:0] q = 0;
            initial $readmemh("scene_front.hex", front_rom);
            always @(posedge clk)
                q <= front_rom[addr_f];
            assign vf = q;
        end else begin : g_no_front
            assign vf = 2'd0;
        end
    endgenerate
    reg [8:0] skyB = 0;
    reg       inS = 0, inC = 0, inM = 0, inH = 0, inF = 0;
    reg       waterB = 0, birdB = 0, sparkleB = 0, twinkleB = 0, nearB = 0, sun_topB = 0;
    reg [5:0] adxB = 0, adyB = 0;
    reg [3:0] bayerB = 0;

    always @(posedge clk) begin
        vs   <= stars_rom[addr_s];
        vc   <= clouds_rom[addr_c];
        vm   <= mountains_rom[addr_m];
        vh   <= hills_rom[addr_h];
        skyB <= sky_rom[ryA];

        inS <= !waterA && in_rows(lyA, STARS_TOP, STARS_H);
        inC <= in_rows(ryA, CLOUDS_TOP, CLOUDS_H);
        inM <= in_rows(ryA, MOUNT_TOP,  MOUNT_H);
        inH <= in_rows(ryA, HILLS_TOP,  HILLS_H);
        inF <= in_rows(lyA, FRONT_TOP,  FRONT_H);

        waterB   <= waterA;
        birdB    <= !waterA && (hit0 || hit1 || hit2) && bird_rom[bird_addr];
        sparkleB <= waterA && adx < 6 + dA[6:2] && h[5:0] == 0;
        twinkleB <= (t[4:3] + lxA[1:0] + lyA[1:0]) == 2'd0;
        nearB    <= adx < 64 && ady < 64;
        sun_topB <= dy < -4;
        adxB     <= adx[5:0];
        adyB     <= ady[5:0];
        bayerB   <= bayer;
    end

    // ---------------------------------------------------------------- clock C: pick the palette entry
    wire [12:0] d2 = adxB * adxB + adyB * adyB;
    wire [1:0]  f  = inF ? vf : 2'd0;
    wire [1:0]  hl = inH ? vh : 2'd0;
    wire [1:0]  mt = inM ? vm : 2'd0;
    wire [1:0]  cl = inC ? vc : 2'd0;
    wire [1:0]  st = inS ? vs : 2'd0;

    reg [5:0] scene_idx;
    always @(*) begin
        if (hl != 0)                                     scene_idx = PAL_HILLS + hl - 1;
        else if (mt != 0)                                scene_idx = PAL_MOUNT + mt - 1;
        else if (cl != 0)                                scene_idx = PAL_CLOUDS + cl - 1;
        else if (nearB && d2 < SUN_R2)                   scene_idx = sun_topB ? PAL_SUN_LIGHT : PAL_SUN_DARK;
        else if (nearB && ((d2 < GLOW1_R2 && bayerB < 10) || (d2 < GLOW2_R2 && bayerB < 4)))
                                                         scene_idx = PAL_GLOW;
        else if (st == 1 || (st == 3 && !twinkleB))      scene_idx = PAL_STAR_DIM;
        else if (st != 0)                                scene_idx = PAL_STAR_BRIGHT;
        else                                             scene_idx = PAL_SKY + skyB[8:5] + (bayerB < skyB[4:0]);
    end

    reg [5:0] idx = 0;
    always @(posedge clk) begin
        if (f != 0)             idx <= PAL_FRONT + f - 1;
        else if (birdB)         idx <= PAL_BIRD;
        else if (sparkleB)      idx <= PAL_SPARKLE;
        else                    idx <= (waterB ? PAL_WATER : 0) + scene_idx;
    end

    // ---------------------------------------------------------------- clock D: palette
    always @(posedge clk)
        rgb <= palette_rom[idx];
endmodule
