// Plays NANO QUEST with the bot for up to 30000 frames, without rendering. After every
// frame it checks that the hero is never inside a solid tile, and it reports how far the
// bot got, what it collected and how it died. PASS needs the bot to clear the course.
`timescale 1ns/1ps
module plat_game_tb;
    reg clk = 0;
    always #20 clk = ~clk;

    reg          tick = 0, jump = 0, run = 0;
    wire [11:0]  mb_addr, cam_x, hero_x, timer;
    wire [5:0]   mb_wd, mb_rd, ma_rd;
    wire         mb_we, reload, hero_vis;
    wire [2:0]   mode;
    wire [3:0]   sfx;
    wire signed [9:0] hero_y;
    wire [3:0]   hero_f, lives, world;
    wire [107:0] foes, debris;
    wire [26:0]  pop;
    wire [23:0]  score;
    wire [7:0]   coins, frames;

    plat_map level (.clk(clk), .a_addr(12'd0), .a_rd(ma_rd), .b_addr(mb_addr), .b_we(mb_we), .b_wd(mb_wd),
                    .b_rd(mb_rd), .reload(reload));
    plat_game game (
        .clk(clk), .tick(tick), .btn_jump(jump), .btn_run(run),
        .map_addr(mb_addr), .map_we(mb_we), .map_wd(mb_wd), .map_rd(mb_rd), .map_reload(reload),
        .mode(mode), .cam_x(cam_x), .hero_x(hero_x), .hero_y(hero_y), .hero_f(hero_f), .hero_vis(hero_vis),
        .foes(foes), .pop(pop), .debris(debris), .score(score), .coins(coins), .timer(timer), .lives(lives),
        .world(world), .frames(frames), .sfx(sfx)
    );

    `include "plat_bot.vh"

    localparam [2:0] M_TITLE = 0, M_CARD = 1, M_PLAY = 2, M_DYING = 3, M_CLEAR = 4, M_GAMEOVER = 5, M_TIMEUP = 6;

    integer n_coin = 0, n_stomp = 0, n_jump = 0, n_bump = 0, n_die = 0, n_clear = 0, n_1up = 0, n_break = 0;
    always @(posedge clk) begin
        case (sfx)
            4'd1: n_jump  = n_jump + 1;
            4'd2: n_coin  = n_coin + 1;
            4'd3: n_stomp = n_stomp + 1;
            4'd4: n_bump  = n_bump + 1;
            4'd5: n_die   = n_die + 1;
            4'd6: n_clear = n_clear + 1;
            4'd7: n_1up   = n_1up + 1;
            4'd8: n_break = n_break + 1;
        endcase
    end

    // A broken brick must be gone from the level: note where each one was.
    reg [11:0] brk_addr = 0;
    reg        brk_pending = 0;
    always @(posedge clk)
        if (sfx == 4'd8) begin
            brk_addr    <= mb_addr;
            brk_pending <= 1'b1;
        end

    task frame_step;
        begin
            tick = 1'b1;
            @(posedge clk); #1;
            tick = 1'b0;
            repeat (79) @(posedge clk);
            #1;
        end
    endtask

    integer n, errors = 0, max_x = 0, min_y = 999, hx, hy, jumps_before, flicker = 0;
    reg     grounded_before;
    reg [2:0] prev_mode = 0;

    initial begin
        #1;
        for (n = 0; n < 20; n = n + 1) frame_step;
        if (mode != M_TITLE) begin errors = errors + 1; $display("ERROR: not on the title screen"); end
        run = 1'b1; frame_step; run = 1'b0;
        for (n = 0; n < 5; n = n + 1) frame_step;
        if (mode != M_CARD) begin errors = errors + 1; $display("ERROR: button did not start a game"); end

        for (n = 0; n < 30000 && !(mode == M_CARD && world == 2) && mode != M_GAMEOVER; n = n + 1) begin
            if (mode == M_PLAY) begin
                bot_step;
                jump = bot_jump;
                run  = 1'b1;
            end else begin
                jump = 1'b0;
                run  = 1'b0;
            end
            grounded_before = game.on_ground;
            jumps_before    = n_jump;
            frame_step;
            if (mode == M_PLAY && grounded_before && !game.on_ground && n_jump == jumps_before && game.vy >= 0 &&
                bot_solid((game.px[15:4] + 1) >> 4, (($signed(game.py) >>> 4) + 16) >> 4))
                flicker = flicker + 1;                       // "in the air" while standing on something
            if (brk_pending) begin
                if (level.ram[brk_addr] != 0) begin
                    errors = errors + 1;
                    $display("ERROR: brick at column %0d row %0d not removed", brk_addr[7:0], brk_addr[11:8]);
                end
                brk_pending = 1'b0;
            end
            if (n_jump != jumps_before && !grounded_before) begin
                errors = errors + 1;
                if (errors < 10) $display("ERROR: jumped in mid-air at frame %0d", n);
            end
            if (mode == M_PLAY) begin
                hx = game.px[15:4];
                hy = $signed(game.py) >>> 4;
`ifdef TRACE
                // iverilog -DTRACE -DTRACE_X0=.. -DTRACE_X1=..: follow the hero through a stretch of level
                if (hx >= `TRACE_X0 && hx <= `TRACE_X1)
                    $display("frame %0d: x=%0d y=%0d vx=%0d vy=%0d ground=%0d jump=%0d foes %0d:(%0d,%0d) %0d:(%0d,%0d) %0d:(%0d,%0d) %0d:(%0d,%0d)",
                             n, hx, hy, game.vx, game.vy, game.on_ground, jump,
                             game.fst[1:0], game.fx[15:4], $signed(game.fy[15:0]) >>> 4,
                             game.fst[3:2], game.fx[31:20], $signed(game.fy[31:16]) >>> 4,
                             game.fst[5:4], game.fx[47:36], $signed(game.fy[47:32]) >>> 4,
                             game.fst[7:6], game.fx[63:52], $signed(game.fy[63:48]) >>> 4);
`endif
                if (hx > max_x) max_x = hx;
                if (hy < min_y) min_y = hy;
                if (hy >= 0 && (bot_solid((hx + 1) >> 4, (hy + 1) >> 4) || bot_solid((hx + 10) >> 4, (hy + 1) >> 4) ||
                                bot_solid((hx + 1) >> 4, (hy + 14) >> 4) || bot_solid((hx + 10) >> 4, (hy + 14) >> 4))) begin
                    errors = errors + 1;
                    if (errors < 10) $display("ERROR: hero inside a solid tile at (%0d, %0d), frame %0d", hx, hy, n);
                end
            end
            if (mode == M_DYING && prev_mode != M_DYING) begin
                $display("died at x=%0d y=%0d (frame %0d)", game.px[15:4], $signed(game.py) >>> 4, n);
            end
            if (mode == M_CLEAR && prev_mode != M_CLEAR)
                $display("reached the flag at frame %0d, time left %h, score %h", n, timer, score);
            prev_mode = mode;
        end
        $display("after %0d frames: mode=%0d world=%0d lives=%0d furthest x=%0d highest y=%0d score=%h coins=%h",
                 n, mode, world, lives, max_x, min_y, score, coins);
        $display("events: %0d jumps, %0d coins, %0d bricks broken, %0d stomps, %0d bumps, %0d deaths, %0d clears, %0d extra lives",
                 n_jump, n_coin, n_break, n_stomp, n_bump, n_die, n_clear, n_1up);
        if (n_clear == 0) begin errors = errors + 1; $display("ERROR: the bot never reached the flag"); end
        if (flicker != 0) begin errors = errors + 1; $display("ERROR: standing hero lost the ground %0d times", flicker); end
        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule
