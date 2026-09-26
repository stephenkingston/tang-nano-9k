// Fast-forwards NANO QUEST (the bot plays), then renders one frame and writes the 640x480
// visible pixels (rrggbb hex) to plat_frame.hex for frame2png.py.
//   START   1: press a button on the title screen
//   TICKS   frames to play before rendering
//   UNTIL   0: nothing, else keep playing until the game is in this mode (then 30 frames more)
`timescale 1ns/1ps
module plat_frame_tb;
    parameter START = 0, TICKS = 60, UNTIL = 0;
    localparam PIPE = 3;

    reg clk = 0;
    always #20 clk = ~clk;

    reg          tick = 0, jump = 0, run = 0;
    reg  [9:0]   x = 0, y = 0;
    wire [11:0]  ma_addr, mb_addr, cam_x, hero_x, timer;
    wire [5:0]   mb_wd, mb_rd, ma_rd;
    wire         mb_we, reload, hero_vis;
    wire [2:0]   mode, sfx;
    wire signed [9:0] hero_y;
    wire [3:0]   hero_f, lives, world;
    wire [107:0] foes;
    wire [26:0]  pop;
    wire [23:0]  score, rgb;
    wire [7:0]   coins, frames;

    plat_map level (.clk(clk), .a_addr(ma_addr), .a_rd(ma_rd), .b_addr(mb_addr), .b_we(mb_we), .b_wd(mb_wd),
                    .b_rd(mb_rd), .reload(reload));
    plat_game game (
        .clk(clk), .tick(tick), .btn_jump(jump), .btn_run(run),
        .map_addr(mb_addr), .map_we(mb_we), .map_wd(mb_wd), .map_rd(mb_rd), .map_reload(reload),
        .mode(mode), .cam_x(cam_x), .hero_x(hero_x), .hero_y(hero_y), .hero_f(hero_f), .hero_vis(hero_vis),
        .foes(foes), .pop(pop), .score(score), .coins(coins), .timer(timer), .lives(lives), .world(world),
        .frames(frames), .sfx(sfx)
    );
    plat_render render (
        .clk(clk), .x(x), .y(y), .mode(mode), .cam_x(cam_x),
        .hero_x(hero_x), .hero_y(hero_y), .hero_f(hero_f), .hero_vis(hero_vis), .foes(foes), .pop(pop),
        .score(score), .coins(coins), .timer(timer), .lives(lives), .world(world), .frames(frames),
        .map_addr(ma_addr), .map_rd(ma_rd), .rgb(rgb)
    );

    `include "plat_bot.vh"

    task frame_step;
        begin
            if (mode == 3'd2) begin bot_step; jump = bot_jump; run = 1'b1; end
            tick = 1'b1;
            @(posedge clk); #1;
            tick = 1'b0;
            repeat (79) @(posedge clk);
            #1;
        end
    endtask

    integer n, fd = 0, written = 0, k;
    reg [19:0] pos [1:PIPE];

    initial begin
        for (k = 1; k <= PIPE; k = k + 1) pos[k] = {10'd1023, 10'd1023};
        #1;
        for (n = 0; n < 10; n = n + 1) frame_step;
        if (START) begin run = 1'b1; frame_step; run = 1'b0; end
        for (n = 0; n < TICKS; n = n + 1) frame_step;
        if (UNTIL != 0) begin
            for (n = 0; n < 20000 && mode != UNTIL; n = n + 1) frame_step;
            if (mode != UNTIL) begin
                $display("ERROR: the game never reached mode %0d", UNTIL);
                $finish;
            end
            for (n = 0; n < 30; n = n + 1) frame_step;
        end
        $display("rendering: mode=%0d cam=%0d hero=(%0d,%0d) score=%h coins=%h time=%h lives=%0d",
                 mode, cam_x, hero_x, hero_y, score, coins, timer, lives);
        fd = $fopen("plat_frame.hex", "w");
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
