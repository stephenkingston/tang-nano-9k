// Plays NANO QUEST without rendering. First, with the slimes held back, it walks under the
// first mushroom block, bumps it and waits for the mushroom (Nano must grow); then the bot
// plays world 1 as big Nano and world 2 small. After every frame it checks that the hero is
// never inside a solid tile, never jumps in mid-air, never loses the ground while standing,
// and that smashed bricks are really gone. PASS needs the mushroom and both worlds cleared.
//   iverilog -DTRACE -DTRACE_X0=.. -DTRACE_X1=..  prints every frame in that stretch of level
`timescale 1ns/1ps
module plat_game_tb;
    reg clk = 0;
    always #20 clk = ~clk;

    reg          tick = 0, jump = 0, run = 0;
    wire [11:0]  mb_addr, cam_x, hero_x, timer;
    wire [5:0]   mb_wd, mb_rd, ma_rd;
    wire         mb_we, reload, hero_vis, hero_big;
    wire [2:0]   mode;
    wire [3:0]   sfx;
    wire signed [9:0] hero_y;
    wire [3:0]   hero_f, lives, world;
    wire [107:0] foes, debris;
    wire [26:0]  pop, mush;
    wire [9:0]   mush_clip;
    wire [23:0]  score;
    wire [7:0]   coins, frames;

    plat_map level (.clk(clk), .a_addr(12'd0), .a_rd(ma_rd), .b_addr(mb_addr), .b_we(mb_we), .b_wd(mb_wd),
                    .b_rd(mb_rd), .reload(reload));
    plat_game game (
        .clk(clk), .tick(tick), .btn_jump(jump), .btn_run(run),
        .map_addr(mb_addr), .map_we(mb_we), .map_wd(mb_wd), .map_rd(mb_rd), .map_reload(reload),
        .mode(mode), .cam_x(cam_x), .hero_x(hero_x), .hero_y(hero_y), .hero_f(hero_f), .hero_vis(hero_vis),
        .hero_big(hero_big), .foes(foes), .pop(pop), .debris(debris), .mush(mush), .mush_clip(mush_clip),
        .score(score), .coins(coins), .timer(timer), .lives(lives), .world(world), .frames(frames), .sfx(sfx)
    );

    `include "plat_bot.vh"

    localparam [2:0] M_TITLE = 0, M_CARD = 1, M_PLAY = 2, M_DYING = 3, M_CLEAR = 4, M_GAMEOVER = 5, M_TIMEUP = 6;

    integer n_coin = 0, n_stomp = 0, n_jump = 0, n_bump = 0, n_die = 0, n_clear = 0, n_1up = 0, n_break = 0;
    integer n_sprout = 0, n_power = 0, n_shrink = 0;
    always @(posedge clk) begin
        case (sfx)
            4'd1:  n_jump   = n_jump + 1;
            4'd2:  n_coin   = n_coin + 1;
            4'd3:  n_stomp  = n_stomp + 1;
            4'd4:  n_bump   = n_bump + 1;
            4'd5:  n_die    = n_die + 1;
            4'd6:  n_clear  = n_clear + 1;
            4'd7:  n_1up    = n_1up + 1;
            4'd8:  n_break  = n_break + 1;
            4'd9:  n_sprout = n_sprout + 1;
            4'd10: n_power  = n_power + 1;
            4'd11: n_shrink = n_shrink + 1;
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
            repeat (99) @(posedge clk);
            #1;
        end
    endtask

    integer n, errors = 0, max_x = 0, min_y = 999, hx, hy, hh, jumps_before, flicker = 0, lives_before;
    integer die_before, shrinks_before, feet_before;
    reg     grounded_before, was_big;
    reg [2:0] prev_mode = 0;

    // One frame of play with checks. bot_mode 0: fetch the mushroom, 1: the bot plays.
    task play_frame(input integer bot_mode);
        begin
            if (mode == M_PLAY) begin
                if (bot_mode == 0) fetch_step; else bot_step;
                jump = bot_jump;
                run  = bot_run;
            end else begin
                jump = 1'b0;
                run  = 1'b0;
            end
            grounded_before = game.on_ground;
            jumps_before    = n_jump;
            lives_before    = lives;
            die_before      = n_die;
            shrinks_before  = n_shrink;
            was_big         = game.big;
            feet_before     = ($signed(game.py) >>> 4) + (game.big ? 28 : 16);
            frame_step;
            if (brk_pending) begin
                if (level.ram[brk_addr] != 0) begin
                    errors = errors + 1;
                    $display("ERROR: brick at column %0d row %0d not removed", brk_addr[7:0], brk_addr[11:8]);
                end
                brk_pending = 1'b0;
            end
            if (mode == M_PLAY && grounded_before && !game.on_ground && n_jump == jumps_before && game.vy >= 0 &&
                bot_solid((game.px[15:4] + 1) >> 4, (($signed(game.py) >>> 4) + (game.big ? 28 : 16)) >> 4))
                flicker = flicker + 1;                       // "in the air" while standing on something
            if (n_jump != jumps_before && !grounded_before) begin
                errors = errors + 1;
                if (errors < 10) $display("ERROR: jumped in mid-air at frame %0d", n);
            end
            if (n_shrink != shrinks_before) begin
                $display("shrank at x=%0d (frame %0d)", game.px[15:4], n);
                if (!was_big || game.big || n_die != die_before || lives != lives_before) begin
                    errors = errors + 1;
                    $display("ERROR: shrinking went wrong: was_big=%0d big=%0d", was_big, game.big);
                end
            end
            if (!was_big && game.big && (($signed(game.py) >>> 4) + 28) != feet_before) begin
                errors = errors + 1;
                $display("ERROR: growing moved the feet from %0d to %0d", feet_before, ($signed(game.py) >>> 4) + 28);
            end
            if (mode == M_PLAY && game.grow_t == 0) begin
                hx = game.px[15:4];
                hy = $signed(game.py) >>> 4;
                hh = game.big ? 28 : 16;
`ifdef TRACE
                if (hx >= `TRACE_X0 && hx <= `TRACE_X1)
                    $display("frame %0d: x=%0d y=%0d big=%0d vx=%0d vy=%0d ground=%0d jump=%0d", n, hx, hy, game.big,
                             game.vx, game.vy, game.on_ground, jump);
`endif
                if (hx > max_x) max_x = hx;
                if (hy < min_y) min_y = hy;
                if (hy >= 0 && (bot_solid((hx + 1) >> 4, (hy + 1) >> 4) || bot_solid((hx + 10) >> 4, (hy + 1) >> 4) ||
                                bot_solid((hx + 1) >> 4, (hy + hh - 2) >> 4) || bot_solid((hx + 10) >> 4, (hy + hh - 2) >> 4))) begin
                    errors = errors + 1;
                    if (errors < 10) $display("ERROR: hero inside a solid tile at (%0d, %0d), frame %0d", hx, hy, n);
                end
            end
            if (mode == M_DYING && prev_mode != M_DYING)
                $display("died at x=%0d y=%0d (frame %0d)", game.px[15:4], $signed(game.py) >>> 4, n);
            if (mode == M_CLEAR && prev_mode != M_CLEAR)
                $display("world %0d: reached the flag at frame %0d as %s Nano, time left %h, score %h", world, n,
                         game.big ? "big" : "small", timer, score);
            prev_mode = mode;
            n = n + 1;
        end
    endtask

    initial begin
        #1;
        for (n = 0; n < 20; n = n + 1) frame_step;
        if (mode != M_TITLE) begin errors = errors + 1; $display("ERROR: not on the title screen"); end
        run = 1'b1; frame_step; run = 1'b0;
        while (mode != M_PLAY) frame_step;
        n = 0;

        // 1. The mushroom, with no slimes about.
        force game.spawn_ptr = 5'd31;
        while (fetch_phase < 4 && fetch_wait < 600 && mode == M_PLAY) play_frame(0);
        release game.spawn_ptr;
        game.spawn_ptr = 5'd1;                  // the first slime would appear right on top of Nano
        $display("mushroom: %0d appeared, %0d eaten, big=%0d at x=%0d after %0d frames", n_sprout, n_power, game.big,
                 game.px[15:4], n);
        if (n_sprout != 1 || n_power != 1 || !game.big) begin
            errors = errors + 1; $display("ERROR: did not grow from the mushroom");
        end

        // 2. World 1 as big Nano, then world 2 small.
        while (n < 12000 && world < 3 && mode != M_GAMEOVER) play_frame(1);
        $display("after %0d frames: mode=%0d world=%0d lives=%0d furthest x=%0d highest y=%0d score=%h coins=%h",
                 n, mode, world, lives, max_x, min_y, score, coins);
        $display("events: %0d jumps, %0d coins, %0d bricks broken, %0d stomps, %0d bumps, %0d mushrooms (%0d eaten), %0d shrinks, %0d deaths, %0d clears, %0d extra lives",
                 n_jump, n_coin, n_break, n_stomp, n_bump, n_sprout, n_power, n_shrink, n_die, n_clear, n_1up);
        if (n_clear < 2) begin errors = errors + 1; $display("ERROR: the bot did not clear both worlds"); end
        if (flicker != 0) begin errors = errors + 1; $display("ERROR: standing hero lost the ground %0d times", flicker); end
        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule
