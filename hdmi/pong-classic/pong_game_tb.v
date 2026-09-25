// Plays pong_game for thousands of frames without rendering, checking that paddles and
// ball stay on the field, that rallies end, and that games start, finish and return to
// attract mode. Scenarios: machine vs machine, an idle player, a bot player, colour change.
`timescale 1ns/1ps
module pong_game_tb;
    `include "pong_defs.vh"

    reg clk = 0;
    always #20 clk = ~clk;

    reg          tick = 0, up = 0, down = 0;
    wire         demo, ball_vis, player_won;
    wire [1:0]   phase, theme, sound;
    wire [9:0]   ball_x;
    wire [8:0]   ball_y, lpad, rpad;
    wire [3:0]   lscore, rscore;
    wire [7:0]   frames;
    wire [159:0] trail;

    pong_game dut (
        .clk(clk), .tick(tick), .btn_up(up), .btn_down(down),
        .demo(demo), .phase(phase), .ball_x(ball_x), .ball_y(ball_y), .ball_vis(ball_vis),
        .lpad(lpad), .rpad(rpad), .lscore(lscore), .rscore(rscore), .player_won(player_won),
        .theme(theme), .frames(frames), .trail(trail), .sound(sound)
    );

    integer errors = 0, hits = 0, walls = 0, points = 0, rally = 0, longest = 0, rallies = 0, rally_sum = 0, n;
    reg     bot = 0;

    // Advance one frame. With bot set, the left paddle chases the ball using the buttons.
    task frame_step;
        begin
            if (bot) begin
                up   = dut.vx < 0 ? lpad + PAD_H / 2 > ball_y + BALL / 2 + 3 : lpad + PAD_H / 2 > 243;
                down = dut.vx < 0 ? lpad + PAD_H / 2 < ball_y + BALL / 2 - 3 : lpad + PAD_H / 2 < 237;
            end
            tick = 1'b1;
            @(posedge clk); #1;
            tick = 1'b0;
            repeat (3) @(posedge clk);          // the update takes 4 clocks
            #1;
            case (sound)
                SND_PADDLE: hits   = hits + 1;
                SND_WALL:   walls  = walls + 1;
                SND_POINT:  points = points + 1;
            endcase
            if (phase == PH_PLAY) rally = rally + 1;
            else if (rally != 0) begin rallies = rallies + 1; rally_sum = rally_sum + rally; rally = 0; end
            if (rally > longest) longest = rally;
            if (lpad < FIELD_TOP || lpad > FIELD_BOT - PAD_H || rpad < FIELD_TOP || rpad > FIELD_BOT - PAD_H) begin
                errors = errors + 1;
                if (errors < 10) $display("ERROR: paddle off the field: lpad=%0d rpad=%0d", lpad, rpad);
            end
            if (phase == PH_PLAY && ball_vis && (ball_y < FIELD_TOP || ball_y > FIELD_BOT - BALL)) begin
                errors = errors + 1;
                if (errors < 10) $display("ERROR: ball off the field: y=%0d", ball_y);
            end
            if (rally > 3000) begin
                errors = errors + 1;
                $display("ERROR: rally never ends");
                rally = 0;
            end
            repeat (4) @(posedge clk);
            #1;
        end
    endtask

    task press_start;
        begin
            up = 1'b1;
            frame_step;
            up = 1'b0;
            frame_step;
        end
    endtask

    task reset_stats;
        begin
            hits = 0; walls = 0; points = 0; longest = 0; rallies = 0; rally_sum = 0;
        end
    endtask

    initial begin
        #1;
        // 1. Attract mode: the machine plays itself; scores must not change.
        reset_stats;
        for (n = 0; n < 20000; n = n + 1) frame_step;
        $display("attract: %0d frames, %0d paddle hits, %0d wall bounces, %0d points, rally avg %0d / longest %0d frames, score %0d-%0d, demo=%0d",
                 n, hits, walls, points, rally_sum / (rallies ? rallies : 1), longest, lscore, rscore, demo);
        if (!demo || lscore != 0 || rscore != 0 || points < 20 || hits < 50) begin
            errors = errors + 1; $display("ERROR: attract mode misbehaved");
        end

        // 2. Idle player: the CPU should win 0-11, then the game returns to attract mode.
        reset_stats;
        press_start;
        if (demo) begin errors = errors + 1; $display("ERROR: button did not start a game"); end
        n = 0;
        while (phase != PH_OVER && n < 100000) begin frame_step; n = n + 1; end
        $display("idle player: game over after %0d frames, score %0d-%0d, player_won=%0d", n, lscore, rscore, player_won);
        if (phase != PH_OVER || rscore != WIN_SCORE || player_won) begin errors = errors + 1; $display("ERROR: idle game"); end
        n = 0;
        while (!demo && n < 1000) begin frame_step; n = n + 1; end
        if (!demo) begin errors = errors + 1; $display("ERROR: did not return to attract mode"); end
        else $display("back in attract mode %0d frames after game over", n);

        // 3. Bot player: tracks the ball with the buttons at player speed.
        reset_stats;
        press_start;
        bot = 1'b1;
        n = 0;
        while (phase != PH_OVER && n < 200000) begin frame_step; n = n + 1; end
        bot = 1'b0; up = 0; down = 0;
        $display("bot player: game over after %0d frames, score %0d-%0d, player_won=%0d, %0d paddle hits, rally avg %0d / longest %0d frames",
                 n, lscore, rscore, player_won, hits, rally_sum / (rallies ? rallies : 1), longest);
        if (phase != PH_OVER || (lscore != WIN_SCORE && rscore != WIN_SCORE)) begin errors = errors + 1; $display("ERROR: bot game"); end
        while (!demo) frame_step;

        // 4. Holding both buttons for a second changes the phosphor colour exactly once.
        up = 1'b1; down = 1'b1;
        for (n = 0; n < 150; n = n + 1) frame_step;
        up = 1'b0; down = 1'b0;
        frame_step;
        $display("theme after one long hold: %0d", theme);
        if (theme != 1) begin errors = errors + 1; $display("ERROR: theme change"); end

        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule
