// Fast-forwards pong_game, then renders one full frame through pong_render and writes the
// 640x480 visible pixels (row-major, rrggbb hex) to pong_frame.hex for frame2png.py.
//   TICKS    frames to fast-forward
//   PLAYER   0: nobody (attract mode), 1: start a game and idle, 2: start a game with a bot
//   OVER     1: keep going until the game-over screen appears
//   HIT      1: keep going until a paddle hit, then render 3 frames later (sparks)
//   POINT    1: keep going until a point is scored, then render 2 frames later (flash, shake)
//   THEMES   how many times to hold both buttons (changes theme; also starts a game)
`timescale 1ns/1ps
module pong_frame_tb;
    parameter TICKS = 300, PLAYER = 0, OVER = 0, HIT = 0, POINT = 0, THEMES = 0;
    localparam PIPE = 13;
    `include "pong_defs.vh"

    reg clk = 0;
    always #20 clk = ~clk;

    reg          tick = 0, up = 0, down = 0;
    reg  [9:0]   x = 0, y = 0;
    wire         demo, ball_vis, player_won, lflash, rflash, flash_side;
    wire [1:0]   phase, theme, sound, ball_tier;
    wire [9:0]   ball_x;
    wire [8:0]   ball_y, lpad, rpad;
    wire [3:0]   lscore, rscore, flash_level;
    wire [7:0]   frames;
    wire [159:0] trail;
    wire [175:0] sparks;
    wire signed [3:0] shake_x, shake_y;
    wire [23:0]  rgb;

    pong_game game (
        .clk(clk), .tick(tick), .btn_up(up), .btn_down(down),
        .demo(demo), .phase(phase), .ball_x(ball_x), .ball_y(ball_y), .ball_vis(ball_vis),
        .lpad(lpad), .rpad(rpad), .lscore(lscore), .rscore(rscore), .player_won(player_won),
        .theme(theme), .frames(frames), .trail(trail), .sound(sound),
        .ball_tier(ball_tier), .lflash(lflash), .rflash(rflash), .shake_x(shake_x), .shake_y(shake_y),
        .flash_side(flash_side), .flash_level(flash_level), .sparks(sparks)
    );

    pong_render render (
        .clk(clk), .x(x), .y(y), .frame(tick),
        .demo(demo), .phase(phase), .ball_x(ball_x), .ball_y(ball_y), .ball_vis(ball_vis),
        .ball_tier(ball_tier), .lpad(lpad), .rpad(rpad), .lflash(lflash), .rflash(rflash),
        .lscore(lscore), .rscore(rscore), .player_won(player_won), .theme(theme), .frames(frames),
        .trail(trail), .sparks(sparks), .shake_x(shake_x), .shake_y(shake_y),
        .flash_side(flash_side), .flash_level(flash_level), .rgb(rgb)
    );

    reg saw_hit = 0, saw_point = 0;
    always @(posedge clk) begin
        if (sound == SND_PADDLE) saw_hit   <= 1'b1;
        if (sound == SND_POINT)  saw_point <= 1'b1;
    end

    task frame_step;
        begin
            if (PLAYER == 2 && !demo) begin
                up   = game.vx < 0 ? lpad + PAD_H / 2 > ball_y + BALL / 2 + 3 : lpad + PAD_H / 2 > 243;
                down = game.vx < 0 ? lpad + PAD_H / 2 < ball_y + BALL / 2 - 3 : lpad + PAD_H / 2 < 237;
            end
            tick = 1'b1;
            @(posedge clk); #1;
            tick = 1'b0;
            repeat (7) @(posedge clk);
            #1;
        end
    endtask

    integer n, t, fd = 0, written = 0;
    reg [19:0] pos [1:PIPE];
    integer k;

    initial begin
        for (k = 1; k <= PIPE; k = k + 1) pos[k] = {10'd1023, 10'd1023};
        #1;
        for (t = 0; t < THEMES; t = t + 1) begin
            up = 1'b1; down = 1'b1;
            for (n = 0; n < 70; n = n + 1) frame_step;
            up = 1'b0; down = 1'b0;
            frame_step;
        end
        for (n = 0; n < TICKS; n = n + 1) begin
            if (PLAYER != 0 && n == 10) up = 1'b1;
            if (PLAYER != 0 && n == 11) up = 1'b0;
            frame_step;
        end
        if (OVER) begin
            while (phase != PH_OVER) frame_step;
            for (n = 0; n < 30; n = n + 1) frame_step;
        end
        if (HIT) begin
            saw_hit = 0;
            while (!saw_hit) frame_step;
            for (n = 0; n < 3; n = n + 1) frame_step;
        end
        if (POINT) begin
            saw_point = 0;
            while (!saw_point) frame_step;
            for (n = 0; n < 2; n = n + 1) frame_step;
        end
        $display("rendering: demo=%0d phase=%0d score %0d-%0d theme=%0d ball=(%0d,%0d) vis=%0d tier=%0d shake=(%0d,%0d) flash=%0d",
                 demo, phase, lscore, rscore, theme, ball_x, ball_y, ball_vis, ball_tier, shake_x, shake_y, flash_level);

        // Scan one frame with the same timing as dvi_tx.
        fd = $fopen("pong_frame.hex", "w");
        forever begin
            @(posedge clk);
            x <= (x == 799) ? 10'd0 : x + 1'b1;
            if (x == 799) y <= (y == 524) ? 10'd0 : y + 1'b1;
        end
    end

    always @(posedge clk) begin
        pos[1] <= {y, x};
        for (k = 2; k <= PIPE; k = k + 1) pos[k] <= pos[k - 1];
    end

    always @(negedge clk) begin
        if (fd && pos[PIPE][9:0] < 640 && pos[PIPE][19:10] < 480) begin
            $fwrite(fd, "%06x\n", rgb);
            written = written + 1;
            if (written == 640 * 480) begin
                $fclose(fd);
                $finish;
            end
        end
    end
endmodule
