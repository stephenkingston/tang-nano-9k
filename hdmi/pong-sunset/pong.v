// Tang Nano 9K: neon Pong over the pixel-art sunset, drawn like an old arcade CRT.
//
// You are the left paddle (S1 = up, S2 = down) against the computer; first to 11 wins.
// When nobody is playing, the machine plays itself under a blinking "PRESS BUTTON".
// Hold both buttons for a second to change theme: sunset, neon grid, green, amber phosphor.
//
// Everything is computed per pixel through a barrel distortion (curved glass): the sunset
// scene, glowing paddles and a ball that heats up as it speeds up, a fire trail, sparks on
// every hit, reflections in the lake, screen shake and a colour flash on every point, plus
// scanlines, vignetting, static and a rolling hum bar.
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

    dvi_tx #(.PIPE(13)) video (
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

    wire         demo, ball_vis, player_won, lflash, rflash, flash_side;
    wire [1:0]   phase, theme, sound, ball_tier;
    wire [9:0]   ball_x;
    wire [8:0]   ball_y, lpad, rpad;
    wire [3:0]   lscore, rscore, flash_level;
    wire [7:0]   frames;
    wire [159:0] trail;
    wire [175:0] sparks;
    wire signed [3:0] shake_x, shake_y;

    pong_game game (
        .clk(clk_pix), .tick(frame), .btn_up(btn_s2[0]), .btn_down(btn_s2[1]),
        .demo(demo), .phase(phase), .ball_x(ball_x), .ball_y(ball_y), .ball_vis(ball_vis),
        .lpad(lpad), .rpad(rpad), .lscore(lscore), .rscore(rscore), .player_won(player_won),
        .theme(theme), .frames(frames), .trail(trail), .sound(sound),
        .ball_tier(ball_tier), .lflash(lflash), .rflash(rflash), .shake_x(shake_x), .shake_y(shake_y),
        .flash_side(flash_side), .flash_level(flash_level), .sparks(sparks)
    );

    pong_render render (
        .clk(clk_pix), .x(x), .y(y), .frame(frame),
        .demo(demo), .phase(phase), .ball_x(ball_x), .ball_y(ball_y), .ball_vis(ball_vis),
        .ball_tier(ball_tier), .lpad(lpad), .rpad(rpad), .lflash(lflash), .rflash(rflash),
        .lscore(lscore), .rscore(rscore), .player_won(player_won), .theme(theme), .frames(frames),
        .trail(trail), .sparks(sparks), .shake_x(shake_x), .shake_y(shake_y),
        .flash_side(flash_side), .flash_level(flash_level), .rgb(rgb)
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
    output reg  [1:0]   sound      = 2'd0,    // one-clock pulse after a tick: SND_*
    // Effects for the renderer
    output reg  [1:0]   ball_tier  = 2'd0,    // how hot the ball is: 0 slow .. 3 fastest
    output wire         lflash,               // a paddle just hit the ball
    output wire         rflash,
    output reg  signed [3:0] shake_x = 4'sd0, // screen shake after a point
    output reg  signed [3:0] shake_y = 4'sd0,
    output reg          flash_side  = 1'b0,   // goal flash: who scored (0 left, 1 right)
    output reg  [3:0]   flash_level = 4'd0,
    output reg  [175:0] sparks      = 176'd0  // 8 particles {level, y, x}; level 0 = not drawn
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

    // Effects: paddle hit flashes, screen shake, goal flash and 8 spark particles
    // (positions and velocities in 1/16 px, like the ball). The particles sit in a ring
    // that rotates once per frame, so one set of adders updates them one per clock.
    localparam [4:0] SPARK_LIFE = 28;
    reg        [3:0]   lhit_t = 0, rhit_t = 0;
    reg        [4:0]   shake_t = 0;
    reg                hit_l_q = 0, hit_r_q = 0;
    reg        [8*15-1:0] spx = 0, spy = 0;             // ring: element 0 in the low bits
    reg        [8*8-1:0]  spvx = 0, spvy = 0;
    reg        [8*5-1:0]  splife = 0;
    reg                sp_start = 0, sp_go = 0, sp_spawn = 0, sp_left = 0;
    reg        [2:0]   sp_i = 0;
    reg signed [14:0]  sp_x0 = 0, sp_y0 = 0;
    reg        [31:0]  sp_rr = 0;
    reg        [3:0]   sp_r;
    assign lflash = lhit_t != 0;
    assign rflash = rhit_t != 0;

    // Spark directions: a fan of 8 from -75 to +75 degrees, 3 px per frame.
    function signed [7:0] spark_c(input [2:0] i);
        case (i)
            3'd0, 3'd7: spark_c = 8'sd12;
            3'd1, 3'd6: spark_c = 8'sd28;
            3'd2, 3'd5: spark_c = 8'sd41;
            default:    spark_c = 8'sd47;
        endcase
    endfunction
    function signed [7:0] spark_s(input [2:0] i);
        case (i)
            3'd0: spark_s = -8'sd46;  3'd1: spark_s = -8'sd39;  3'd2: spark_s = -8'sd26;  3'd3: spark_s = -8'sd9;
            3'd4: spark_s = 8'sd9;    3'd5: spark_s = 8'sd26;   3'd6: spark_s = 8'sd39;   default: spark_s = 8'sd46;
        endcase
    endfunction

    reg signed [15:0] nx, ny;
    reg signed [9:0]  nvx, nvy, serve_vy;
    reg signed [10:0] lp, rp, bx, by, nyi;
    reg        [1:0]  snd, ph;
    reg        [7:0]  tm;
    reg               start, left_out, chase_l, chase_r, point, spawn, spawn_left;
    reg signed [14:0] spawn_x, spawn_y, px_n, py_n;
    reg signed [7:0]  vx_n, vy_n;
    reg        [3:0]  r4;
    reg signed [9:0]  avx;

    always @(posedge clk) begin
        sound    <= SND_NONE;
        sp_start <= 1'b0;
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
                    if (hold == 6'd59) theme <= theme + 1'b1;
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
                hit_l_q <= 1'b0;
                hit_r_q <= 1'b0;
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
                        hit_l_q <= 1'b1;
                    end
                    if (vx > 0 && bxf <= X_RFACE && nx > X_RFACE && nyi + BALL_S > rp && nyi < rp + PAD_H_S) begin
                        nx  = X_RFACE;
                        nvx = -(vx + V_UP);
                        if (nvx < -V_MAX) nvx = -V_MAX;
                        nvy = angle(nyi, rp);
                        snd = SND_PADDLE;
                        err_l <= $signed(rnd[6:0]) >>> 1;
                        hit_r_q <= 1'b1;
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
                point    = 1'b0;
                left_out = nx_q < X_OUT_L;
                if (phase == PH_PLAY) begin
                    if (left_out || nx_q > X_OUT_R) begin
                        point      = 1'b1;
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

                // Effects. A point shakes the screen, flashes the scorer's colour and throws
                // sparks off the goal line; a paddle hit flashes the paddle and throws sparks.
                lhit_t <= hit_l_q ? 4'd10 : lhit_t - (lhit_t != 0);
                rhit_t <= hit_r_q ? 4'd10 : rhit_t - (rhit_t != 0);
                if (point) begin
                    shake_t     <= 5'd20;
                    flash_level <= 4'd15;
                    flash_side  <= left_out;            // the ball left on the left: right scored
                end else begin
                    shake_t     <= shake_t - (shake_t != 0);
                    flash_level <= flash_level - (flash_level != 0);
                end
                r4 = shake_t > 15 ? 4'd0 : shake_t > 10 ? 4'd1 : shake_t > 5 ? 4'd2 : 4'd3;
                shake_x <= shake_t == 0 ? 4'sd0 : $signed(rnd[3:0]) >>> r4;
                shake_y <= shake_t == 0 ? 4'sd0 : $signed(rnd[7:4]) >>> r4;

                avx = nvx_q < 0 ? -nvx_q : nvx_q;
                ball_tier <= avx < 80 ? 2'd0 : avx < 112 ? 2'd1 : avx < 144 ? 2'd2 : 2'd3;

                spawn      = point || hit_l_q || hit_r_q;
                spawn_left = point ? !left_out : hit_r_q;   // sparks fly towards -x
                spawn_x    = point ? (left_out ? 15'sd0 : 15'sd10224) :
                             hit_l_q ? 15'sd832 : 15'sd9408;  // goal lines and paddle faces, 1/16 px
                spawn_y    = $signed({ny_q[14:4], 4'd0}) + 15'sd96;
                sp_start   <= 1'b1;                     // update the sparks over the next 8 clocks
                sp_spawn   <= spawn;
                sp_left    <= spawn_left;
                sp_x0      <= spawn_x;
                sp_y0      <= spawn_y;

                // What the renderer shows. The ball blinks in the centre while waiting to serve.
                trail    <= {trail[139:0], ball_vis, ball_y, ball_x};
                ball_x   <= nx_q[13:4];
                ball_y   <= ny_q[12:4];
                ball_vis <= ph == PH_SERVE ? frames[3] :
                            ph == PH_PLAY  ? (!nx_q[15] && nx_q <= X_VIS_R) : 1'b0;
            end
        endcase
    end

    // Sparks: each clock takes the ring's first particle, spawns or moves it, and puts it
    // back at the end; after 8 clocks every particle is updated and the ring is back in order.
    always @(posedge clk) begin
        if (sp_start) begin
            sp_go <= 1'b1;
            sp_i  <= 3'd0;
            sp_rr <= {rnd, rnd};
        end else if (sp_go) begin
            px_n = spx[14:0];
            py_n = spy[14:0];
            vx_n = spvx[7:0];
            vy_n = spvy[7:0];
            sp_r = sp_rr[3:0];
            if (sp_spawn) begin
                vx_n = spark_c(sp_i) + $signed({2'b00, sp_r[1:0], 2'b00}) + $signed({3'b000, sp_r[1:0], 1'b0});
                px_n = sp_x0;
                py_n = sp_y0;
                vx_n = sp_left ? -vx_n : vx_n;
                vy_n = spark_s(sp_i) + ($signed({1'b0, sp_r[3:2]}) - 8'sd2) * 6 - 8'sd8;
                splife <= {SPARK_LIFE, splife[39:5]};
            end else if (splife[4:0] != 0) begin
                px_n = px_n + vx_n;
                py_n = py_n + vy_n;
                vy_n = vy_n + 8'sd2;                    // gravity
                splife <= {splife[4:0] - 1'b1, splife[39:5]};
            end else begin
                splife <= {splife[4:0], splife[39:5]};
            end
            spx  <= {px_n, spx[119:15]};
            spy  <= {py_n, spy[119:15]};
            spvx <= {vx_n, spvx[63:8]};
            spvy <= {vy_n, spvy[63:8]};
            // Drawn only while x and y are non-negative and y < 512; x up to 1023 is simply
            // off the right of the screen. The level is from before this frame's decrement.
            sparks <= {(!px_n[14] && !py_n[14] && !py_n[13]) ? (sp_spawn ? 3'd7 : splife[4:2]) : 3'd0,
                       py_n[12:4], px_n[13:4], sparks[175:22]};
            sp_rr <= sp_rr >> 2;
            sp_i  <= sp_i + 1'b1;
            if (sp_i == 3'd7)
                sp_go <= 1'b0;
        end
    end
endmodule


// Colour of screen pixel (x, y), 13 clocks later.
//
// Clocks 1-5 bend the screen like curved glass, 6-8 work out what is at the bent position,
// 9 looks up colours (and the sunset scene arrives), 10 adds everything up, 11-13 apply the
// phosphor themes, vignette and scanlines.
module pong_render #(
    parameter WARP_SH = 19          // screen curvature; larger is flatter
) (
    input  wire              clk,
    input  wire [9:0]        x,
    input  wire [9:0]        y,
    input  wire              frame,         // advances the sunset animation
    input  wire              demo,
    input  wire [1:0]        phase,
    input  wire [9:0]        ball_x,
    input  wire [8:0]        ball_y,
    input  wire              ball_vis,
    input  wire [1:0]        ball_tier,
    input  wire [8:0]        lpad,
    input  wire [8:0]        rpad,
    input  wire              lflash,
    input  wire              rflash,
    input  wire [3:0]        lscore,
    input  wire [3:0]        rscore,
    input  wire              player_won,
    input  wire [1:0]        theme,         // 0 sunset, 1 neon grid, 2 green, 3 amber phosphor
    input  wire [7:0]        frames,
    input  wire [159:0]      trail,
    input  wire [175:0]      sparks,
    input  wire signed [3:0] shake_x,
    input  wire signed [3:0] shake_y,
    input  wire              flash_side,
    input  wire [3:0]        flash_level,
    output reg  [23:0]       rgb = 24'd0
);
    `include "pong_defs.vh"
    `include "pong_pal.vh"

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
    // Each screen pixel looks up the picture at a point pushed outwards in proportion to its
    // squared distance from the centre, so straight lines bow like an old tube. A point
    // scored shakes the whole picture.
    reg signed [10:0] u1 = 0, v1 = 0, u2 = 0, v2 = 0, u3 = 0, v3 = 0, u4 = 0, v4 = 0;
    reg        [21:0] r2_3 = 0, r2_4 = 0;
    reg signed [11:0] gx5 = 0, gy5 = 0;
    reg        [7:0]  vig5 = 0;
    reg        [12:1] odd = 0;                          // odd screen line, per stage
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
        gx5  <= 12'sd320 + u4 + ($signed(pu4[28:0]) >>> WARP_SH) + shake_x;
        gy5  <= 12'sd240 + v4 + ($signed(pv4[28:0]) >>> WARP_SH) + shake_y;
        vig5 <= 8'd255 - r2_4[18:11];                   // darker towards the corners
        odd  <= {odd[11:1], y[0]};
    end

    wire signed [11:0] X = gx5;
    wire signed [11:0] Y = gy5;

    // The sunset scene (without its foreground shore) is sampled at the bent position too,
    // so it curves with the glass. Its colour arrives 4 clocks later, at clock 9.
    wire [9:0]  scene_x = X < 0 ? 10'd0 : X > 639 ? 10'd639 : X[9:0];
    wire [9:0]  scene_y = Y < 0 ? 10'd0 : Y > 479 ? 10'd479 : Y[9:0];
    wire [23:0] scene_rgb;
    scene_render #(.FRONT(0)) sunset (.clk(clk), .x(scene_x), .y(scene_y), .frame(frame), .rgb(scene_rgb));

    // ---------------------------------------------------------------- clock 6: what is at (X, Y)
    // Distance outside [lo, lo + len) along one axis, 0 inside, saturated at 63.
    // Positions stay within -64..704, so 11-bit arithmetic is enough.
    function [5:0] outside(input signed [11:0] p, input signed [11:0] lo, input [6:0] len);
        reg signed [10:0] a, b;
        reg        [10:0] d;
        begin
            a = p[10:0] - lo[10:0];                             // < 0 before the span
            b = a - $signed({4'd0, len}) + 11'sd1;              // > 0 after it
            d = a[10] ? -a : (!b[10] && b != 0) ? b : 11'd0;
            outside = |d[10:6] ? 6'd63 : d[5:0];
        end
    endfunction

    // Offset v below a size of 4, 12 or 64, tested with bits rather than a compare
    // (on Gowin every compare is a carry chain). Negative offsets wrap to large values.
    function below(input [9:0] v, input [6:0] size);
        case (size)
            7'd4:    below = v[9:2] == 0;
            7'd12:   below = v[9:4] == 0 && !(v[3] && v[2]);
            default: below = v[9:6] == 0;                    // 64
        endcase
    endfunction

    // Inside a box of w x h at (bx, by). 10-bit offsets are enough: positions stay within
    // -64..704 and boxes within 0..740, so a far-away pixel never wraps into the box.
    function in_box(input signed [11:0] px, input signed [11:0] py, input [9:0] bx, input [8:0] by,
                    input [6:0] w, input [6:0] h);
        begin
            in_box = below(px[9:0] - bx, w) && below(py[9:0] - {1'b0, by}, h);
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
    wire [6:0] ld  = dist(ldx, ldy), rd = dist(rdx, rdy);
    wire       pside = rd < ld;                         // nearer paddle: 0 left, 1 right
    wire [6:0] pd  = pside ? rd : ld;

    // Walls and their glow straight from Y's bits: each wall (16..23, 456..463) and the 8
    // rows either side of it are 8-row blocks, so Y[2:0] is the position within the block.
    reg       wall_i;
    reg [3:0] gw;
    always @(*) begin
        wall_i = 1'b0;
        gw     = 4'd0;
        if (Y[11:10] == 2'b00)
            case (Y[9:3])
                7'd1, 7'd56: gw = {1'b0, Y[2:0]};                        // rising towards a wall
                7'd2, 7'd57: begin gw = 4'd8; wall_i = 1'b1; end          // the walls
                7'd3, 7'd58: gw = {1'b0, ~Y[2:0]};                       // fading away from it
                default: ;
            endcase
    end

    // One glow per pixel: whichever of the ball, the nearer paddle and the walls is brightest.
    wire [3:0] gb = ball_vis && bd < 14 ? 14 - bd : 4'd0;
    wire [3:0] gp = pd < 12 ? 12 - pd : 4'd0;
    wire [1:0] gsrc = (gb >= gp && gb >= gw) ? 2'd0 : (gp >= gw) ? 2'd1 : 2'd2;
    wire [3:0] glev = gsrc == 2'd0 ? gb : gsrc == 2'd1 ? gp : gw;

    // Newest trail copy and brightest spark covering the pixel.
    reg       tr_hit;
    reg [2:0] tr_age, spark_lvl;
    integer   k;
    always @(*) begin
        tr_hit    = 1'b0;
        tr_age    = 3'd0;
        spark_lvl = 3'd0;
        for (k = 7; k >= 0; k = k - 1) begin
            if (k < 6 && trail[20 * k + 19] && in_box(X, Y, trail[20 * k +: 10], trail[20 * k + 10 +: 9], BALL, BALL)) begin
                tr_hit = 1'b1;
                tr_age = k[2:0];
            end
            if (sparks[22 * k + 19 +: 3] > spark_lvl && in_box(X, Y, sparks[22 * k +: 10], sparks[22 * k + 10 +: 9], 4, 4))
                spark_lvl = sparks[22 * k + 19 +: 3];
        end
    end

    // Reflections in the lake (bottom third): mirror about the shoreline and ripple sideways
    // with the same wave table as the scene's water.
    (* rom_style = "logic" *) reg [3:0] ripple_rom [0:511];
    initial $readmemh("scene_ripple.hex", ripple_rom);
    wire               water = theme != 2'd1 && Y >= 320 && Y < 480;    // no lake in the neon theme
    wire [8:0]         wl    = Y[9:1] - 9'd160;                       // logical rows below the shore
    wire [4:0]         wph   = Y[9:1] * 5 + frames[5:1];
    wire signed [3:0]  rip   = ripple_rom[{wl[6:3], wph}];
    wire signed [11:0] mx    = X + {{7{rip[3]}}, rip, 1'b0};
    wire signed [11:0] my    = 12'sd639 - Y;
    wire refl_ball = water && ball_vis && in_box(mx, my, ball_x, ball_y, BALL, BALL);
    wire refl_lpad = water && in_box(mx, my, LPAD_X, lpad, PAD_W, PAD_H);
    wire refl_rpad = water && in_box(mx, my, RPAD_X, rpad, PAD_W, PAD_H);

    // Score digits: left score right-aligned against the net, right score left-aligned.
    reg        dig_on, dig_side;
    reg [3:0]  dig_val;
    reg [5:0]  dig_x;
    always @(*) begin
        dig_on   = 1'b0;
        dig_side = 1'b0;
        dig_val  = 4'd0;
        dig_x    = 6'd0;
        if (!demo && Y >= SCORE_Y && Y < SCORE_Y + 60) begin
            if (X >= 244 && X < 280) begin
                dig_on = 1'b1; dig_val = lscore >= 10 ? lscore - 4'd10 : lscore; dig_x = X - 244;
            end else if (X >= 196 && X < 232 && lscore >= 10) begin
                dig_on = 1'b1; dig_val = 4'd1; dig_x = X - 196;
            end else if (X >= 360 && X < 396) begin
                dig_on = 1'b1; dig_side = 1'b1; dig_val = rscore >= 10 ? 4'd1 : rscore; dig_x = X - 360;
            end else if (X >= 408 && X < 444 && rscore >= 10) begin
                dig_on = 1'b1; dig_side = 1'b1; dig_val = rscore - 4'd10; dig_x = X - 408;
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
    (* rom_style = "logic" *) reg [6:0] div6_rom [0:127];    // n -> {n / 6, n % 6}
    initial $readmemh("pong_div6.hex", div6_rom);
    wire [6:0]         big_qr  = div6_rom[{1'b0, big_n}];

    // Small line: blinking "PRESS BUTTON" in attract mode. 4x scale, 24 px pitch.
    wire signed [12:0] sm_dx  = X - 13'sd176;
    wire signed [12:0] sm_dy  = Y - 13'sd340;
    wire               sm_in  = demo && frames[5:4] != 2'b00 && sm_dx >= 13'sd0 && sm_dx < 13'sd288 &&
                                sm_dy >= 13'sd0 && sm_dy < 13'sd28;
    wire [6:0]         sm_n   = sm_dx[8:2];
    wire [6:0]         sm_qr  = div6_rom[sm_n];

    // Static: a xorshift32 random number generator stepped every pixel.
    reg  [31:0] rng = 32'h2545F491;
    wire [31:0] rng_a = rng ^ (rng << 13);
    wire [31:0] rng_b = rng_a ^ (rng_a >> 17);
    always @(posedge clk)
        rng <= rng_b ^ (rng_b << 5);

    reg        in6 = 0, ball6 = 0, lpad6 = 0, rpad6 = 0, wall6 = 0, net6 = 0, dig6 = 0, dside6 = 0;
    reg        big6 = 0, sm6 = 0, hum6 = 0, tr6 = 0, grid6 = 0, pside6 = 0;
    reg        rball6 = 0, rlpad6 = 0, rrpad6 = 0;
    reg [3:0]  glev6 = 0, dval6 = 0;
    reg [1:0]  gsrc6 = 0;
    reg [4:0]  big_code6 = 0, sm_code6 = 0, big_hue6 = 0, band6 = 0;
    reg [7:0]  vig6 = 0;
    reg [5:0]  dx6 = 0, dy6 = 0;
    reg [2:0]  big_c6 = 0, big_r6 = 0, sm_c6 = 0, sm_r6 = 0, age6 = 0, spark6 = 0, noise6 = 0;

    always @(posedge clk) begin
        in6    <= X >= 0 && X < 640 && Y >= 0 && Y < 480;
        ball6  <= ball_vis && bdx == 0 && bdy == 0;
        lpad6  <= ldx == 0 && ldy == 0;
        rpad6  <= rdx == 0 && rdy == 0;
        pside6 <= pside;
        gsrc6  <= gsrc;
        glev6  <= glev;
        wall6  <= wall_i;
        net6   <= X >= NET_X && X < NET_X + NET_W && Y >= FIELD_TOP && Y < FIELD_BOT && Y[4];
        tr6    <= tr_hit;
        age6   <= tr_age;
        spark6 <= spark_lvl;
        rball6 <= refl_ball;
        rlpad6 <= refl_lpad;
        rrpad6 <= refl_rpad;
        dig6   <= dig_on;
        dside6 <= dig_side;
        dval6  <= dig_val;
        dx6    <= dig_x;
        dy6    <= dig_y;
        big6      <= big_in;
        big_code6 <= big_msg[big_qr[6:3] * 5 +: 5];
        big_c6    <= big_qr[2:0];
        big_r6    <= big_dy[5:3];
        big_hue6  <= big_n[4:0] + frames[7:3];               // the rainbow drifts along the text
        sm6       <= sm_in;
        sm_code6  <= MSG_PRESS[sm_qr[6:3] * 5 +: 5];
        sm_c6     <= sm_qr[2:0];
        sm_r6     <= sm_dy[4:2];
        grid6  <= X[4:1] == 4'd0 || (Y[8:0] - {1'b0, frames}) % 32 < 2;   // neon theme's scrolling grid
        band6  <= Y[8:4];
        hum6   <= Y[8:0] - {frames, 1'b0} < 9'd48;          // a faint bar rolling down the tube
        noise6 <= rng[31:29];
        vig6   <= vig5;
    end

    // ---------------------------------------------------------------- clock 7: palette indices
    function glyph_px(input [4:0] code, input [2:0] col, input [2:0] row);
        reg [34:0] g;
        begin
            g        = glyph(code);
            glyph_px = col < 5 && row < 7 && g[34 - 5 * row - col];
        end
    endfunction

    wire [1:0]  dcol  = dx6 < 12 ? 2'd0 : dx6 < 24 ? 2'd1 : 2'd2;
    wire [2:0]  drow  = dy6 < 12 ? 3'd0 : dy6 < 24 ? 3'd1 : dy6 < 36 ? 3'd2 : dy6 < 48 ? 3'd3 : 3'd4;
    wire [14:0] dbits = digit(dval6);
    wire        dig_px = dig6 && dbits[14 - 3 * drow - dcol];
    wire        big_px = big6 && glyph_px(big_code6, big_c6, big_r6);
    wire        sm_px  = sm6 && glyph_px(sm_code6, sm_c6, sm_r6);

    // Opaque layer, front to back.
    reg [5:0] solid_i;
    always @(*) begin
        if (big_px)              solid_i = (demo || player_won) ? SOL_HUE + big_hue6 : SOL_OVER;
        else if (ball6)          solid_i = SOL_BALL + ball_tier;
        else if (lpad6)          solid_i = lflash ? SOL_LPAD_HIT : SOL_LPAD;
        else if (rpad6)          solid_i = rflash ? SOL_RPAD_HIT : SOL_RPAD;
        else if (sm_px)          solid_i = SOL_PRESS;
        else if (dig_px)         solid_i = dside6 ? SOL_RDIG : SOL_LDIG;
        else if (wall6)          solid_i = SOL_WALL;
        else                     solid_i = SOL_NONE;
    end

    // Additive layer: whichever of these is on top.
    reg [4:0] add_i;
    always @(*) begin
        if (spark6 != 0)         add_i = ADD_SPARK + spark6;
        else if (tr6)            add_i = ADD_TRAIL + age6;
        else if (rball6)         add_i = ADD_BALL_REFL + ball_tier;
        else if (rlpad6)         add_i = ADD_LPAD_REFL;
        else if (rrpad6)         add_i = ADD_RPAD_REFL;
        else if (net6)           add_i = ADD_NET;
        else                     add_i = ADD_NONE;
    end

    // Indices wait one clock (7 -> 8) so the table lookups land at clock 9 with the scene.
    reg [5:0] solid7 = 0, solid8 = 0, grid7 = 0, grid8 = 0;
    reg [7:0] glow7 = 0, glow8 = 0;
    reg [4:0] add7 = 0, add8 = 0, flash7 = 0, flash8 = 0;
    reg [3:0] nh7 = 0, nh8 = 0, nh9 = 0;                // static plus hum bar
    reg [7:0] vig7 = 0, vig8 = 0, vig9 = 0, vig10 = 0, vig11 = 0;
    reg [6:1] in_d = 0;                                 // in6 delayed to clocks 7..12

    always @(posedge clk) begin
        solid7 <= solid_i;
        add7   <= add_i;
        // glow table index: {source, variant, level}; ball variants are its heat, paddle
        // variants are {side, just hit}, the walls have one
        glow7  <= {gsrc6, gsrc6 == 2'd0 ? ball_tier : gsrc6 == 2'd1 ? {pside6, pside6 ? rflash : lflash} : 2'd0, glev6};
        flash7 <= {flash_side, flash_level};
        grid7  <= {grid6, band6};
        nh7    <= noise6 + (hum6 ? 4'd6 : 4'd0);
        vig7   <= vig6;
        solid8 <= solid7; add8 <= add7; glow8 <= glow7; flash8 <= flash7; grid8 <= grid7;
        nh8    <= nh7;    nh9    <= nh8;
        vig8   <= vig7;   vig9   <= vig8;   vig10 <= vig9;   vig11 <= vig10;
        in_d   <= {in_d[5:1], in6};
    end

    // ---------------------------------------------------------------- clock 9: colour tables
    reg [23:0] solid_rom [0:63], add_rom [0:31], glow_rom [0:255], flash_rom [0:31], grid_rom [0:63];
    initial begin
        $readmemh("pong_solid.hex", solid_rom);
        $readmemh("pong_add.hex",   add_rom);
        $readmemh("pong_glow.hex",  glow_rom);
        $readmemh("pong_flash.hex", flash_rom);
        $readmemh("pong_grid.hex",  grid_rom);
    end

    reg [23:0] solid9 = 0, add9 = 0, glow9 = 0, flash9 = 0, grid9 = 0;
    reg        opaque9 = 0;
    always @(posedge clk) begin
        solid9  <= solid_rom[solid8];
        add9    <= add_rom[add8];
        glow9   <= glow_rom[glow8];
        flash9  <= flash_rom[flash8];
        grid9   <= grid_rom[grid8];
        opaque9 <= solid8 != SOL_NONE;
    end

    // ---------------------------------------------------------------- clock 10: add it all up
    // The sunset is dimmed to 5/8 so the neon stays readable in front of it.
    function [7:0] ch(input [23:0] c, input [1:0] n);
        ch = c[8 * n +: 8];
    endfunction

    function [7:0] mix_ch(input [1:0] n, input [23:0] bg);
        reg [10:0] s;
        begin
            s = (opaque9 ? ch(solid9, n) : ch(bg, n)) + ch(add9, n) + ch(glow9, n) + ch(flash9, n) + nh9;
            mix_ch = |s[10:8] ? 8'd255 : s[7:0];
        end
    endfunction

    function [7:0] dim58(input [7:0] c);
        dim58 = (c >> 1) + (c >> 3);
    endfunction
    wire [23:0] dim_scene = {dim58(scene_rgb[23:16]), dim58(scene_rgb[15:8]), dim58(scene_rgb[7:0])};
    wire [23:0] bg = theme == 2'd1 ? grid9 : dim_scene;

    reg [23:0] rgb10 = 0;
    always @(posedge clk)
        rgb10 <= {mix_ch(2, bg), mix_ch(1, bg), mix_ch(0, bg)};

    // ---------------------------------------------------------------- clock 11: phosphor themes
    // Green and amber turn the whole picture into one phosphor colour by brightness.
    wire [9:0]  luma = rgb10[23:16] + {rgb10[15:8], 1'b0} + rgb10[7:0];     // r + 2g + b
    wire [23:0] tint = theme == 2'd2 ? TINT_GREEN : TINT_AMBER;
    wire [35:0] mr, mg, mb;
    dsp_mul18 #(.A_SIGNED(0), .B_SIGNED(0)) mul_mr (.clk(clk), .a({10'd0, luma[9:2]}), .b({10'd0, tint[23:16]}), .p(mr));
    dsp_mul18 #(.A_SIGNED(0), .B_SIGNED(0)) mul_mg (.clk(clk), .a({10'd0, luma[9:2]}), .b({10'd0, tint[15:8]}),  .p(mg));
    dsp_mul18 #(.A_SIGNED(0), .B_SIGNED(0)) mul_mb (.clk(clk), .a({10'd0, luma[9:2]}), .b({10'd0, tint[7:0]}),   .p(mb));
    reg [23:0] rgb11 = 0;
    always @(posedge clk)
        rgb11 <= rgb10;
    wire [23:0] toned = theme[1] ? {mr[15:8], mg[15:8], mb[15:8]} : rgb11;

    // ---------------------------------------------------------------- clocks 12-13: vignette and scanlines
    wire [35:0] vr, vg, vb;
    dsp_mul18 #(.A_SIGNED(0), .B_SIGNED(0)) mul_vr (.clk(clk), .a({10'd0, toned[23:16]}), .b({10'd0, vig11}), .p(vr));
    dsp_mul18 #(.A_SIGNED(0), .B_SIGNED(0)) mul_vg (.clk(clk), .a({10'd0, toned[15:8]}),  .b({10'd0, vig11}), .p(vg));
    dsp_mul18 #(.A_SIGNED(0), .B_SIGNED(0)) mul_vb (.clk(clk), .a({10'd0, toned[7:0]}),   .b({10'd0, vig11}), .p(vb));

    function [7:0] scanline(input [15:0] p, input dim);
        scanline = dim ? p[15:9] + p[15:11] : p[15:8];       // odd lines at 5/8 brightness
    endfunction

    always @(posedge clk)
        rgb <= in_d[6] ? {scanline(vr[15:0], odd[12]), scanline(vg[15:0], odd[12]), scanline(vb[15:0], odd[12])}
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
