// Tang Nano 9K: Pong on the HDMI port, drawn like an old arcade CRT.
//
// You are the left paddle (S1 = up, S2 = down) against the computer; first to 11 wins.
// When nobody is playing, the machine plays itself under a blinking "PRESS BUTTON".
// Hold both buttons for a second to switch phosphor: white, green, amber.
//
// The picture is computed per pixel through a barrel distortion (curved glass), with
// phosphor glow, a fading ball trail, scanlines, vignetting and a little static.
// A piezo buzzer between pin 25 and GND plays the original-style blips (optional).
module top (
    input  wire       clk,          // 27 MHz oscillator
    input  wire [1:0] btn,          // S1, S2; active low
    output wire       tmds_clk_p,
    output wire       tmds_clk_n,
    output wire [2:0] tmds_d_p,
    output wire [2:0] tmds_d_n,
    output wire [5:0] led,          // active low
    output wire       beep
);
    wire        clk_pix, reset, frame;
    wire [9:0]  x, y;
    wire [23:0] rgb;

    dvi_tx #(.PIPE(10)) video (
        .clk_27(clk), .clk_pix(clk_pix), .reset(reset), .x(x), .y(y), .frame(frame),
        .rgb(rgb),
        .tmds_clk_p(tmds_clk_p), .tmds_clk_n(tmds_clk_n), .tmds_d_p(tmds_d_p), .tmds_d_n(tmds_d_n)
    );

    // Buttons into the pixel clock domain; the game only looks at them once per frame.
    reg [1:0] btn_s1 = 2'b00, btn_s2 = 2'b00;
    always @(posedge clk_pix) begin
        btn_s1 <= ~btn;
        btn_s2 <= btn_s1;
    end

    wire         demo, ball_vis, player_won;
    wire [1:0]   phase, theme, sound;
    wire [9:0]   ball_x;
    wire [8:0]   ball_y, lpad, rpad;
    wire [3:0]   lscore, rscore;
    wire [7:0]   frames;
    wire [159:0] trail;

    pong_game game (
        .clk(clk_pix), .tick(frame), .btn_up(btn_s2[0]), .btn_down(btn_s2[1]),
        .demo(demo), .phase(phase), .ball_x(ball_x), .ball_y(ball_y), .ball_vis(ball_vis),
        .lpad(lpad), .rpad(rpad), .lscore(lscore), .rscore(rscore), .player_won(player_won),
        .theme(theme), .frames(frames), .trail(trail), .sound(sound)
    );

    pong_render render (
        .clk(clk_pix), .x(x), .y(y),
        .demo(demo), .phase(phase), .ball_x(ball_x), .ball_y(ball_y), .ball_vis(ball_vis),
        .lpad(lpad), .rpad(rpad), .lscore(lscore), .rscore(rscore), .player_won(player_won),
        .theme(theme), .frames(frames), .trail(trail), .rgb(rgb)
    );

    beeper sfx (.clk(clk_pix), .evt(demo ? 2'd0 : sound), .out(beep));

    // LEDs: a scanner while in attract mode, your score in binary during a game, all
    // flashing when the game is over.
    reg [3:0] scan = 4'd0;
    reg [2:0] scan_div = 3'd0;
    always @(posedge clk_pix) begin
        if (frame) begin
            scan_div <= (scan_div == 3'd5) ? 3'd0 : scan_div + 1'b1;
            if (scan_div == 3'd5)
                scan <= (scan == 4'd9) ? 4'd0 : scan + 1'b1;
        end
    end
    wire [3:0] scan_pos = (scan < 6) ? scan : 4'd10 - scan;

    assign led = ~(demo             ? (6'b000001 << scan_pos) :
                   phase == 2'd2    ? {6{frames[3]}} :
                                      {2'b00, lscore});
endmodule


// Game state, advanced once per frame.
module pong_game (
    input  wire         clk,
    input  wire         tick,               // once per frame, in vertical blanking
    input  wire         btn_up,             // held, active high
    input  wire         btn_down,
    output reg          demo       = 1'b1,  // attract mode: the machine plays itself
    output reg  [1:0]   phase      = 2'd0,  // PH_SERVE, PH_PLAY, PH_OVER
    output reg  [9:0]   ball_x     = 10'd314,
    output reg  [8:0]   ball_y     = 9'd234,
    output reg          ball_vis   = 1'b0,
    output reg  [8:0]   lpad       = 9'd208,
    output reg  [8:0]   rpad       = 9'd208,
    output reg  [3:0]   lscore     = 4'd0,
    output reg  [3:0]   rscore     = 4'd0,
    output reg          player_won = 1'b0,
    output reg  [1:0]   theme      = 2'd0,
    output reg  [7:0]   frames     = 8'd0,
    output reg  [159:0] trail      = 160'd0,  // last 8 ball positions {vis, y, x}, newest in [19:0]
    output reg  [1:0]   sound      = 2'd0     // one-clock pulse after a tick: SND_*
);
    `include "pong_defs.vh"

    // Everything below is sized explicitly: unsized integer maths would build 32-bit adders.
    localparam signed [15:0] Y_TOP   = FIELD_TOP * 16;               // ball y limits, 1/16 px
    localparam signed [15:0] Y_BOT   = (FIELD_BOT - BALL) * 16;
    localparam signed [15:0] X_LFACE = (LPAD_X + PAD_W) * 16;        // ball x when touching a paddle
    localparam signed [15:0] X_RFACE = (RPAD_X - BALL) * 16;
    localparam signed [15:0] X_OUT_L = -16 * 16, X_OUT_R = (640 + 16) * 16;
    localparam signed [15:0] X_VIS_R = (640 - BALL) * 16;
    localparam signed [15:0] X_SERVE = 314 * 16, Y_SERVE = 234 * 16;
    localparam signed [10:0] P_MIN = FIELD_TOP, P_MAX = FIELD_BOT - PAD_H;
    localparam signed [10:0] HALF_PAD = PAD_H / 2, HALF_BALL = BALL / 2, BALL_S = BALL, PAD_H_S = PAD_H;
    localparam signed [10:0] L_REACT = LPAD_X + PAD_W + CPU_REACT, R_REACT = RPAD_X - CPU_REACT - BALL;
    localparam signed [10:0] MID = 240, P_SPD = PLAYER_SPD;
    localparam signed [9:0]  V_SERVE = SERVE_VX, V_UP = SPEEDUP, V_MAX = MAX_VX;
    localparam        [3:0]  WIN_M1 = WIN_SCORE - 1;

    reg signed [15:0] bxf = X_SERVE, byf = Y_SERVE;     // ball position, 1/16 px
    reg signed [9:0]  vx = 0, vy = 0;                   // ball velocity, 1/16 px per frame
    reg        [7:0]  timer = 8'd60;
    reg               serve_left = 1'b0;
    reg signed [6:0]  err_l = 0, err_r = 0;             // where each CPU paddle aims, off-centre
    reg               btn_prev = 1'b0;
    reg        [5:0]  hold = 6'd0;
    reg        [15:0] lfsr = 16'hACE1;

    always @(posedge clk)
        lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};

    function signed [10:0] clamp_pad(input signed [10:0] p);
        clamp_pad = p < P_MIN ? P_MIN : p > P_MAX ? P_MAX : p;
    endfunction

    // Move a paddle so its centre heads for target, at most spd px.
    function signed [10:0] track(input signed [10:0] pad, input signed [10:0] target, input [3:0] spd);
        reg signed [10:0] d, s;
        begin
            d = target - (pad + HALF_PAD);
            s = $signed({7'd0, spd});
            if (d > 11'sd2)       track = clamp_pad(pad + (d < s ? d : s));
            else if (d < -11'sd2) track = clamp_pad(pad - (-d < s ? -d : s));
            else                  track = pad;
        end
    endfunction

    // Return angle from where the ball hit the paddle: 3/16 px per frame per pixel off-centre.
    function signed [9:0] angle(input signed [10:0] ball_top, input signed [10:0] pad_top);
        reg signed [10:0] off;
        begin
            off   = (ball_top + HALF_BALL) - (pad_top + HALF_PAD);
            angle = off + (off <<< 1);
        end
    endfunction

    // The update is spread over four clocks after each tick so no single clock has to
    // chain paddle movement, bounces, hits and scoring:
    //   0 (tick) inputs and paddles, 1 ball movement and walls, 2 paddle hits, 3 points and commit.
    reg        [1:0]  step = 2'd0;
    reg        [15:0] rnd = 16'd0;                      // lfsr as it was at the tick
    reg               start_q = 1'b0;
    reg signed [15:0] nx_q = 0, ny_q = 0;
    reg signed [9:0]  nvx_q = 0, nvy_q = 0;
    reg        [1:0]  snd_q = 0, ph_q = 0;
    reg        [7:0]  tm_q = 0;

    reg signed [15:0] nx, ny;
    reg signed [9:0]  nvx, nvy, serve_vy;
    reg signed [10:0] lp, rp, bx, by, nyi;
    reg        [1:0]  snd, ph;
    reg        [7:0]  tm;
    reg               start, left_out, chase_l, chase_r;

    always @(posedge clk) begin
        sound <= SND_NONE;
        case (step)
            2'd0: if (tick) begin
                step <= 2'd1;
                rnd  <= lfsr;

                // A button press starts a game; holding both for a second changes the phosphor.
                start    = demo && (btn_up || btn_down) && !btn_prev;
                start_q  <= start;
                btn_prev <= btn_up || btn_down;
                if (btn_up && btn_down) begin
                    if (hold != 6'd63) hold <= hold + 1'b1;
                    if (hold == 6'd59) theme <= (theme == 2'd2) ? 2'd0 : theme + 1'b1;
                end else begin
                    hold <= 6'd0;
                end

                // Paddles. The CPU only chases the ball once it is heading its way and close.
                bx = bxf >>> 4;
                by = byf >>> 4;
                lp = $signed({2'b00, lpad});
                rp = $signed({2'b00, rpad});
                chase_l = phase == PH_PLAY && vx < 0 && bx < L_REACT;
                chase_r = phase == PH_PLAY && vx > 0 && bx > R_REACT;
                if (demo) begin
                    lp = track(lp, chase_l ? by + HALF_BALL + err_l : MID, chase_l ? CPU_SPD : 2);
                end else if (btn_up && !btn_down) begin
                    lp = clamp_pad(lp - P_SPD);
                end else if (btn_down && !btn_up) begin
                    lp = clamp_pad(lp + P_SPD);
                end
                rp = track(rp, chase_r ? by + HALF_BALL + err_r : MID, chase_r ? CPU_SPD : 2);
                lpad <= lp[8:0];
                rpad <= rp[8:0];
            end

            2'd1: begin
                step <= 2'd2;
                nx  = bxf;
                ny  = byf;
                nvx = vx;
                nvy = vy;
                snd = SND_NONE;
                ph  = phase;
                tm  = timer;
                serve_vy = $signed({5'd0, rnd[4:0]}) + 10'sd16;
                case (phase)
                    PH_SERVE: begin
                        nx = X_SERVE;
                        ny = Y_SERVE;
                        if (tm == 8'd0) begin
                            ph  = PH_PLAY;
                            nvx = serve_left ? -V_SERVE : V_SERVE;
                            nvy = rnd[5] ? -serve_vy : serve_vy;
                        end else begin
                            tm = tm - 1'b1;
                        end
                    end

                    PH_PLAY: begin
                        nx = bxf + vx;
                        ny = byf + vy;
                        if (ny < Y_TOP) begin
                            ny  = Y_TOP + Y_TOP - ny;
                            nvy = -vy;
                            snd = SND_WALL;
                        end else if (ny > Y_BOT) begin
                            ny  = Y_BOT + Y_BOT - ny;
                            nvy = -vy;
                            snd = SND_WALL;
                        end
                    end

                    default: begin  // PH_OVER: show the result, then back to attract mode
                        if (tm == 8'd0) begin
                            demo <= 1'b1;
                            ph   = PH_SERVE;
                            tm   = 8'd60;
                        end else begin
                            tm = tm - 1'b1;
                        end
                    end
                endcase
                nx_q  <= nx;
                ny_q  <= ny;
                nvx_q <= nvx;
                nvy_q <= nvy;
                snd_q <= snd;
                ph_q  <= ph;
                tm_q  <= tm;
            end

            2'd2: begin
                // Paddle faces. Where the ball hits the paddle sets the return angle,
                // and every hit makes the ball a little faster.
                step <= 2'd3;
                nx  = nx_q;
                nvx = nvx_q;
                nvy = nvy_q;
                snd = snd_q;
                nyi = ny_q >>> 4;
                lp  = $signed({2'b00, lpad});
                rp  = $signed({2'b00, rpad});
                if (phase == PH_PLAY) begin
                    if (vx < 0 && bxf >= X_LFACE && nx < X_LFACE && nyi + BALL_S > lp && nyi < lp + PAD_H_S) begin
                        nx  = X_LFACE;
                        nvx = -vx + V_UP;
                        if (nvx > V_MAX) nvx = V_MAX;
                        nvy = angle(nyi, lp);
                        snd = SND_PADDLE;
                        err_r <= $signed(rnd[6:0]) >>> 1;
                    end
                    if (vx > 0 && bxf <= X_RFACE && nx > X_RFACE && nyi + BALL_S > rp && nyi < rp + PAD_H_S) begin
                        nx  = X_RFACE;
                        nvx = -(vx + V_UP);
                        if (nvx < -V_MAX) nvx = -V_MAX;
                        nvy = angle(nyi, rp);
                        snd = SND_PADDLE;
                        err_l <= $signed(rnd[6:0]) >>> 1;
                    end
                end
                nx_q  <= nx;
                nvx_q <= nvx;
                nvy_q <= nvy;
                snd_q <= snd;
            end

            default: begin
                // Out of play: a point, then serve towards whoever lost it. Then commit.
                step <= 2'd0;
                snd = snd_q;
                ph  = ph_q;
                tm  = tm_q;
                if (phase == PH_PLAY) begin
                    left_out = nx_q < X_OUT_L;
                    if (left_out || nx_q > X_OUT_R) begin
                        snd        = SND_POINT;
                        ph         = PH_SERVE;
                        tm         = 8'd60;
                        serve_left <= left_out;
                        if (!demo) begin
                            if (left_out) begin
                                rscore <= rscore + 1'b1;
                                if (rscore == WIN_M1) begin ph = PH_OVER; tm = 8'd240; player_won <= 1'b0; end
                            end else begin
                                lscore <= lscore + 1'b1;
                                if (lscore == WIN_M1) begin ph = PH_OVER; tm = 8'd240; player_won <= 1'b1; end
                            end
                        end
                    end
                end

                if (start_q) begin
                    demo       <= 1'b0;
                    lscore     <= 4'd0;
                    rscore     <= 4'd0;
                    serve_left <= 1'b0;
                    ph         = PH_SERVE;
                    tm         = 8'd90;
                end

                phase  <= ph;
                timer  <= tm;
                bxf    <= nx_q;
                byf    <= ny_q;
                vx     <= nvx_q;
                vy     <= nvy_q;
                sound  <= snd;
                frames <= frames + 1'b1;

                // What the renderer shows. The ball blinks in the centre while waiting to serve.
                trail    <= {trail[139:0], ball_vis, ball_y, ball_x};
                ball_x   <= nx_q[13:4];
                ball_y   <= ny_q[12:4];
                ball_vis <= ph == PH_SERVE ? frames[3] :
                            ph == PH_PLAY  ? (!nx_q[15] && nx_q <= X_VIS_R) : 1'b0;
            end
        endcase
    end
endmodule


// Colour of screen pixel (x, y), 10 clocks later.
module pong_render #(
    parameter WARP_SH = 19          // screen curvature; larger is flatter
) (
    input  wire         clk,
    input  wire [9:0]   x,
    input  wire [9:0]   y,
    input  wire         demo,
    input  wire [1:0]   phase,
    input  wire [9:0]   ball_x,
    input  wire [8:0]   ball_y,
    input  wire         ball_vis,
    input  wire [8:0]   lpad,
    input  wire [8:0]   rpad,
    input  wire [3:0]   lscore,
    input  wire [3:0]   rscore,
    input  wire         player_won,
    input  wire [1:0]   theme,
    input  wire [7:0]   frames,
    input  wire [159:0] trail,
    output reg  [23:0]  rgb = 24'd0
);
    `include "pong_defs.vh"

    // ---------------------------------------------------------------- font and text
    localparam [4:0] C_SP = 0, C_A = 1, C_B = 2, C_E = 3, C_G = 4, C_I = 5, C_M = 6, C_N = 7, C_O = 8,
                     C_P = 9, C_R = 10, C_S = 11, C_T = 12, C_U = 13, C_V = 14, C_W = 15, C_Y = 16;

    // Messages, first character in the low bits.
    localparam [59:0] MSG_PONG  = {40'd0, C_G, C_N, C_O, C_P};
    localparam [59:0] MSG_PRESS = {C_N, C_O, C_T, C_T, C_U, C_B, C_SP, C_S, C_S, C_E, C_R, C_P};
    localparam [59:0] MSG_WIN   = {25'd0, C_N, C_I, C_W, C_SP, C_U, C_O, C_Y};
    localparam [59:0] MSG_OVER  = {15'd0, C_R, C_E, C_V, C_O, C_SP, C_E, C_M, C_A, C_G};

    // 5x7 glyphs, top row in the high bits, leftmost pixel first.
    function [34:0] glyph(input [4:0] code);
        case (code)
            C_A: glyph = {5'b01110, 5'b10001, 5'b10001, 5'b11111, 5'b10001, 5'b10001, 5'b10001};
            C_B: glyph = {5'b11110, 5'b10001, 5'b10001, 5'b11110, 5'b10001, 5'b10001, 5'b11110};
            C_E: glyph = {5'b11111, 5'b10000, 5'b10000, 5'b11110, 5'b10000, 5'b10000, 5'b11111};
            C_G: glyph = {5'b01110, 5'b10001, 5'b10000, 5'b10111, 5'b10001, 5'b10001, 5'b01111};
            C_I: glyph = {5'b01110, 5'b00100, 5'b00100, 5'b00100, 5'b00100, 5'b00100, 5'b01110};
            C_M: glyph = {5'b10001, 5'b11011, 5'b10101, 5'b10101, 5'b10001, 5'b10001, 5'b10001};
            C_N: glyph = {5'b10001, 5'b11001, 5'b10101, 5'b10011, 5'b10001, 5'b10001, 5'b10001};
            C_O: glyph = {5'b01110, 5'b10001, 5'b10001, 5'b10001, 5'b10001, 5'b10001, 5'b01110};
            C_P: glyph = {5'b11110, 5'b10001, 5'b10001, 5'b11110, 5'b10000, 5'b10000, 5'b10000};
            C_R: glyph = {5'b11110, 5'b10001, 5'b10001, 5'b11110, 5'b10100, 5'b10010, 5'b10001};
            C_S: glyph = {5'b01111, 5'b10000, 5'b10000, 5'b01110, 5'b00001, 5'b00001, 5'b11110};
            C_T: glyph = {5'b11111, 5'b00100, 5'b00100, 5'b00100, 5'b00100, 5'b00100, 5'b00100};
            C_U: glyph = {5'b10001, 5'b10001, 5'b10001, 5'b10001, 5'b10001, 5'b10001, 5'b01110};
            C_V: glyph = {5'b10001, 5'b10001, 5'b10001, 5'b10001, 5'b10001, 5'b01010, 5'b00100};
            C_W: glyph = {5'b10001, 5'b10001, 5'b10001, 5'b10101, 5'b10101, 5'b10101, 5'b01010};
            C_Y: glyph = {5'b10001, 5'b10001, 5'b01010, 5'b00100, 5'b00100, 5'b00100, 5'b00100};
            default: glyph = 35'd0;
        endcase
    endfunction

    // Chunky 3x5 score digits, as on the original cabinet.
    function [14:0] digit(input [3:0] d);
        case (d)
            4'd0: digit = {3'b111, 3'b101, 3'b101, 3'b101, 3'b111};
            4'd1: digit = {3'b001, 3'b001, 3'b001, 3'b001, 3'b001};
            4'd2: digit = {3'b111, 3'b001, 3'b111, 3'b100, 3'b111};
            4'd3: digit = {3'b111, 3'b001, 3'b111, 3'b001, 3'b111};
            4'd4: digit = {3'b101, 3'b101, 3'b111, 3'b001, 3'b001};
            4'd5: digit = {3'b111, 3'b100, 3'b111, 3'b001, 3'b111};
            4'd6: digit = {3'b111, 3'b100, 3'b111, 3'b101, 3'b111};
            4'd7: digit = {3'b111, 3'b001, 3'b001, 3'b001, 3'b001};
            4'd8: digit = {3'b111, 3'b101, 3'b111, 3'b101, 3'b111};
            default: digit = {3'b111, 3'b101, 3'b111, 3'b001, 3'b111};
        endcase
    endfunction

    // ---------------------------------------------------------------- clocks 1-5: curved glass
    // Each screen pixel looks up the game picture at a point pushed outwards in proportion
    // to its squared distance from the centre, so straight lines bow like an old tube.
    reg signed [10:0] u1 = 0, v1 = 0, u2 = 0, v2 = 0, u3 = 0, v3 = 0, u4 = 0, v4 = 0;
    reg        [21:0] r2_3 = 0, r2_4 = 0;
    reg signed [11:0] gx5 = 0, gy5 = 0;
    reg        [7:0]  vig5 = 0;
    reg        [8:1]  odd = 0;                          // odd screen line, per stage
    wire       [35:0] uu2, vv2, pu4, pv4;               // DSP products, registered

    wire [17:0] u1x = {{7{u1[10]}}, u1}, v1x = {{7{v1[10]}}, v1};
    wire [17:0] u3x = {{7{u3[10]}}, u3}, v3x = {{7{v3[10]}}, v3};
    wire [17:0] r2q = {1'b0, r2_3[18:2]};               // r^2 / 4, positive

    dsp_mul18 mul_uu (.clk(clk), .a(u1x), .b(u1x), .p(uu2));
    dsp_mul18 mul_vv (.clk(clk), .a(v1x), .b(v1x), .p(vv2));
    dsp_mul18 mul_pu (.clk(clk), .a(u3x), .b(r2q), .p(pu4));
    dsp_mul18 mul_pv (.clk(clk), .a(v3x), .b(r2q), .p(pv4));

    always @(posedge clk) begin
        u1   <= $signed({1'b0, x}) - 11'sd320;
        v1   <= $signed({1'b0, y}) - 11'sd240;
        u2   <= u1;
        v2   <= v1;
        r2_3 <= uu2[21:0] + vv2[21:0];
        u3   <= u2;
        v3   <= v2;
        u4   <= u3;
        v4   <= v3;
        r2_4 <= r2_3;
        gx5  <= 12'sd320 + u4 + ($signed(pu4[28:0]) >>> WARP_SH);
        gy5  <= 12'sd240 + v4 + ($signed(pv4[28:0]) >>> WARP_SH);
        vig5 <= 8'd255 - r2_4[18:11];                   // darker towards the corners
        odd  <= {odd[7:1], y[0]};
    end

    // ---------------------------------------------------------------- clock 6: what is at (gx, gy)
    wire signed [11:0] X = gx5;
    wire signed [11:0] Y = gy5;

    // Distance outside [lo, lo + len) along one axis, 0 inside, saturated at 63.
    function [5:0] outside(input signed [11:0] p, input signed [11:0] lo, input [6:0] len);
        reg signed [12:0] a;
        reg        [12:0] d;
        begin
            a = p - lo;
            if (a < 13'sd0)                          d = -a;
            else if (a >= $signed({6'd0, len}))      d = a - $signed({6'd0, len}) + 13'sd1;
            else                                     d = 13'd0;
            outside = |d[12:6] ? 6'd63 : d[5:0];
        end
    endfunction

    // Inside a ball-sized box: offsets left of or above it wrap to large unsigned values.
    function in_box(input signed [11:0] px, input signed [11:0] py, input [9:0] bx, input [8:0] by);
        reg [11:0] dx, dy;
        begin
            dx     = px - {2'b00, bx};
            dy     = py - {3'b000, by};
            in_box = dx < 12'd12 && dy < 12'd12;
        end
    endfunction

    // Rough Euclidean distance from its x and y parts.
    function [6:0] dist(input [5:0] a, input [5:0] b);
        dist = a > b ? a + (b >> 1) : b + (a >> 1);
    endfunction

    wire [5:0] bdx = outside(X, {2'b00, ball_x}, BALL), bdy = outside(Y, {3'b000, ball_y}, BALL);
    wire [5:0] ldx = outside(X, LPAD_X, PAD_W),         ldy = outside(Y, {3'b000, lpad}, PAD_H);
    wire [5:0] rdx = outside(X, RPAD_X, PAD_W),         rdy = outside(Y, {3'b000, rpad}, PAD_H);
    wire [6:0] bd  = dist(bdx, bdy);
    wire [6:0] pd  = dist(ldx, ldy) < dist(rdx, rdy) ? dist(ldx, ldy) : dist(rdx, rdy);
    wire [5:0] wtd = outside(Y, WALL_TOP, WALL_H), wbd = outside(Y, WALL_BOT, WALL_H);
    wire [5:0] wd  = wtd < wbd ? wtd : wbd;

    // Fading copies of the ball where it was on the last 8 frames.
    reg [7:0] trail_i;
    integer k;
    always @(*) begin
        trail_i = 8'd0;
        for (k = 7; k >= 0; k = k - 1)
            if (trail[20 * k + 19] && in_box(X, Y, trail[20 * k +: 10], trail[20 * k + 10 +: 9]))
                trail_i = 8'd170 - 8'd20 * k[2:0];
    end

    // Score digits: left score right-aligned against the net, right score left-aligned.
    reg        dig_on;
    reg [3:0]  dig_val;
    reg [5:0]  dig_x;
    always @(*) begin
        dig_on  = 1'b0;
        dig_val = 4'd0;
        dig_x   = 6'd0;
        if (!demo && Y >= SCORE_Y && Y < SCORE_Y + 60) begin
            if (X >= 244 && X < 280) begin
                dig_on = 1'b1; dig_val = lscore >= 10 ? lscore - 4'd10 : lscore; dig_x = X - 244;
            end else if (X >= 196 && X < 232 && lscore >= 10) begin
                dig_on = 1'b1; dig_val = 4'd1; dig_x = X - 196;
            end else if (X >= 360 && X < 396) begin
                dig_on = 1'b1; dig_val = rscore >= 10 ? 4'd1 : rscore; dig_x = X - 360;
            end else if (X >= 408 && X < 444 && rscore >= 10) begin
                dig_on = 1'b1; dig_val = rscore - 4'd10; dig_x = X - 408;
            end
        end
    end
    wire [5:0] dig_y = Y - SCORE_Y;

    // Big line: "PONG" in attract mode, the result when the game is over. 8x scale, 48 px pitch.
    wire [59:0]        big_msg = demo ? MSG_PONG : player_won ? MSG_WIN : MSG_OVER;
    wire signed [12:0] big_x0  = demo ? 13'sd224 : player_won ? 13'sd152 : 13'sd104;   // 320 - chars * 24
    wire signed [12:0] big_w   = demo ? 13'sd192 : player_won ? 13'sd336 : 13'sd432;   // chars * 48
    wire signed [12:0] big_dx  = X - big_x0;
    wire signed [12:0] big_dy  = Y - (demo ? 13'sd104 : 13'sd196);
    wire               big_in  = (demo || phase == PH_OVER) && big_dx >= 13'sd0 && big_dx < big_w &&
                                 big_dy >= 13'sd0 && big_dy < 13'sd56;
    wire [5:0]         big_n   = big_dx[8:3];                // glyph column across the line
    wire [3:0]         big_idx = (big_n * 43) >> 8;          // n / 6, exact for n < 128

    // Small line: blinking "PRESS BUTTON" in attract mode. 4x scale, 24 px pitch.
    wire signed [12:0] sm_dx  = X - 13'sd176;
    wire signed [12:0] sm_dy  = Y - 13'sd340;
    wire               sm_in  = demo && frames[5:4] != 2'b00 && sm_dx >= 13'sd0 && sm_dx < 13'sd288 &&
                                sm_dy >= 13'sd0 && sm_dy < 13'sd28;
    wire [6:0]         sm_n   = sm_dx[8:2];
    wire [3:0]         sm_idx = (sm_n * 43) >> 8;

    // Static: a xorshift32 random number generator stepped every pixel.
    reg  [31:0] rng = 32'h2545F491;
    wire [31:0] rng_a = rng ^ (rng << 13);
    wire [31:0] rng_b = rng_a ^ (rng_a >> 17);
    always @(posedge clk)
        rng <= rng_b ^ (rng_b << 5);

    reg        in6 = 0, ball6 = 0, pad6 = 0, wall6 = 0, net6 = 0, dig6 = 0, big6 = 0, sm6 = 0, hum6 = 0;
    reg [3:0]  bglow6 = 0, pglow6 = 0, wglow6 = 0, dval6 = 0;
    reg [4:0]  big_code6 = 0, sm_code6 = 0;
    reg [7:0]  trail6 = 0, vig6 = 0;
    reg [5:0]  dx6 = 0, dy6 = 0;
    reg [2:0]  big_c6 = 0, big_r6 = 0, sm_c6 = 0, sm_r6 = 0;
    reg [2:0]  noise6 = 0;

    always @(posedge clk) begin
        in6    <= X >= 0 && X < 640 && Y >= 0 && Y < 480;
        ball6  <= ball_vis && bdx == 0 && bdy == 0;
        bglow6 <= ball_vis && bd < 14 ? 14 - bd : 4'd0;
        pad6   <= (ldx == 0 && ldy == 0) || (rdx == 0 && rdy == 0);
        pglow6 <= pd < 12 ? 12 - pd : 4'd0;
        wall6  <= wd == 0;
        wglow6 <= wd < 8 ? 8 - wd : 4'd0;
        hum6   <= Y[8:0] - {frames, 1'b0} < 9'd48;          // a faint bar rolling down the tube
        net6   <= X >= NET_X && X < NET_X + NET_W && Y >= FIELD_TOP && Y < FIELD_BOT && Y[4];
        trail6 <= trail_i;
        dig6   <= dig_on;
        dval6  <= dig_val;
        dx6    <= dig_x;
        dy6    <= dig_y;
        big6      <= big_in;
        big_code6 <= big_msg[big_idx * 5 +: 5];
        big_c6    <= big_n - big_idx * 6;
        big_r6    <= big_dy[5:3];
        sm6       <= sm_in;
        sm_code6  <= MSG_PRESS[sm_idx * 5 +: 5];
        sm_c6     <= sm_n - sm_idx * 6;
        sm_r6     <= sm_dy[4:2];
        noise6 <= rng[31:29];
        vig6   <= vig5;
    end

    // ---------------------------------------------------------------- clock 7: brightness
    function glyph_px(input [4:0] code, input [2:0] col, input [2:0] row);
        reg [34:0] g;
        begin
            g        = glyph(code);
            glyph_px = col < 5 && row < 7 && g[34 - 5 * row - col];
        end
    endfunction

    wire [1:0] dcol = dx6 < 12 ? 2'd0 : dx6 < 24 ? 2'd1 : 2'd2;
    wire [2:0] drow = dy6 < 12 ? 3'd0 : dy6 < 24 ? 3'd1 : dy6 < 36 ? 3'd2 : dy6 < 48 ? 3'd3 : 3'd4;
    wire [14:0] dbits = digit(dval6);
    wire dig_px = dig6 && dbits[14 - 3 * drow - dcol];

    // Glow falls off with the square of the distance: ball up to 196, paddles 144, walls 128.
    reg [7:0] level;
    always @(*) begin
        level = trail6;
        if (bglow6 * bglow6 > level)            level = bglow6 * bglow6;
        if (pglow6 * pglow6 > level)            level = pglow6 * pglow6;
        if (wglow6 * wglow6 * 2 > level)        level = wglow6 * wglow6 * 2;
        if (net6 && level < 150)                level = 150;
        if (wall6 && level < 190)               level = 190;
        if (dig_px && level < 220)              level = 220;
        if (sm6 && glyph_px(sm_code6, sm_c6, sm_r6) && level < 220) level = 220;
        if (pad6 && level < 240)                level = 240;
        if (ball6 || (big6 && glyph_px(big_code6, big_c6, big_r6))) level = 255;
    end

    // The tube itself glows faintly, with static and the hum bar on top.
    wire [8:0] lit = level + 8'd10 + noise6 + (hum6 ? 4'd6 : 4'd0);
    reg  [7:0] i7 = 0, vig7 = 0;
    reg  [2:0] in_d = 0;                                // in6 delayed to clocks 7, 8 and 9
    always @(posedge clk) begin
        i7   <= lit[8] ? 8'd255 : lit[7:0];
        vig7 <= vig6;
        in_d <= {in_d[1:0], in6};
    end

    // ---------------------------------------------------------------- clocks 8-9: vignette and scanlines
    wire [35:0] iv8;
    dsp_mul18 #(.A_SIGNED(0), .B_SIGNED(0)) mul_vig (.clk(clk), .a({10'd0, i7}), .b({10'd0, vig7}), .p(iv8));
    wire [7:0] i8 = odd[8] ? iv8[15:9] + iv8[15:11] : iv8[15:8];   // odd lines at 5/8 brightness

    // ---------------------------------------------------------------- clocks 9-10: phosphor colour
    reg [23:0] tint;
    always @(*) begin
        case (theme)
            2'd1:    tint = 24'h46FF78;     // green
            2'd2:    tint = 24'hFFAA28;     // amber
            default: tint = 24'hE6F0FF;     // white
        endcase
    end

    // Bright pixels saturate towards white, like an overdriven phosphor.
    wire [35:0] pr, pg, pb, hot;
    dsp_mul18 #(.A_SIGNED(0), .B_SIGNED(0)) mul_r   (.clk(clk), .a({10'd0, i8}), .b({10'd0, tint[23:16]}), .p(pr));
    dsp_mul18 #(.A_SIGNED(0), .B_SIGNED(0)) mul_g   (.clk(clk), .a({10'd0, i8}), .b({10'd0, tint[15:8]}),  .p(pg));
    dsp_mul18 #(.A_SIGNED(0), .B_SIGNED(0)) mul_b   (.clk(clk), .a({10'd0, i8}), .b({10'd0, tint[7:0]}),   .p(pb));
    dsp_mul18 #(.A_SIGNED(0), .B_SIGNED(0)) mul_hot (.clk(clk), .a({10'd0, i8}), .b({10'd0, i8}),          .p(hot));

    function [7:0] chan(input [15:0] p, input [5:0] extra);
        reg [8:0] s;
        begin
            s    = p[15:8] + extra;
            chan = s[8] ? 8'd255 : s[7:0];
        end
    endfunction

    always @(posedge clk)
        rgb <= in_d[2] ? {chan(pr[15:0], hot[15:10]), chan(pg[15:0], hot[15:10]), chan(pb[15:0], hot[15:10])}
                       : 24'h000000;
endmodule


// Square-wave blips: paddle 490 Hz, wall and point 245 Hz, like the original.
module beeper (
    input  wire       clk,          // 25.2 MHz
    input  wire [1:0] evt,          // one-clock pulse: SND_PADDLE, SND_WALL or SND_POINT
    output reg        out = 1'b0
);
    reg [15:0] half = 16'd0, cnt = 16'd0;
    reg [23:0] left = 24'd0;

    always @(posedge clk) begin
        if (evt != 2'd0) begin
            half <= (evt == 2'd1) ? 16'd25714 : 16'd51429;
            left <= (evt == 2'd1) ? 24'd1008000 : (evt == 2'd2) ? 24'd756000 : 24'd6300000;  // 40, 30, 250 ms
            cnt  <= 16'd0;
        end else if (left != 0) begin
            left <= left - 1'b1;
            if (cnt == half) begin
                cnt <= 16'd0;
                out <= ~out;
            end else begin
                cnt <= cnt + 1'b1;
            end
        end else begin
            out <= 1'b0;
        end
    end
endmodule
