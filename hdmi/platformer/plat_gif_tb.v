// Records NANO QUEST for a GIF. The bot plays from power-up (the title screen, a button
// press at tick 30, then the game); every STEP-th tick from T0 up to T1 the renderer draws a
// 320x240 frame, one sample per 2x2 block of screen pixels, appended to plat_gif_<JOB>.hex
// (one line of 320 rrggbb values per row). Arguments: +T0=n +T1=n +STEP=n +JOB=n.
// Without +T0 it only prints the tick at which each mode begins. plat_gif.py runs it.
`timescale 1ns/1ps
module plat_gif_tb;
    localparam PIPE = 3;
    integer T0 = 1, T1 = 0, STEP = 2, JOB = 0;

    reg clk = 0;
    always #20 clk = ~clk;

    reg          tick = 0, jump = 0, run = 0;
    reg  [9:0]   x = 0, y = 0;
    wire [11:0]  ma_addr, mb_addr, cam_x, hero_x, timer;
    wire [5:0]   mb_wd, mb_rd, ma_rd;
    wire         mb_we, reload, hero_vis;
    wire [2:0]   mode;
    wire [3:0]   sfx;
    wire signed [9:0] hero_y;
    wire [3:0]   hero_f, lives, world;
    wire [107:0] foes, debris;
    wire [26:0]  pop;
    wire [23:0]  score, rgb;
    wire [7:0]   coins, frames;

    plat_map level (.clk(clk), .a_addr(ma_addr), .a_rd(ma_rd), .b_addr(mb_addr), .b_we(mb_we), .b_wd(mb_wd),
                    .b_rd(mb_rd), .reload(reload));
    plat_game game (
        .clk(clk), .tick(tick), .btn_jump(jump), .btn_run(run),
        .map_addr(mb_addr), .map_we(mb_we), .map_wd(mb_wd), .map_rd(mb_rd), .map_reload(reload),
        .mode(mode), .cam_x(cam_x), .hero_x(hero_x), .hero_y(hero_y), .hero_f(hero_f), .hero_vis(hero_vis),
        .foes(foes), .pop(pop), .debris(debris), .score(score), .coins(coins), .timer(timer), .lives(lives),
        .world(world), .frames(frames), .sfx(sfx)
    );
    plat_render render (
        .clk(clk), .x(x), .y(y), .mode(mode), .cam_x(cam_x),
        .hero_x(hero_x), .hero_y(hero_y), .hero_f(hero_f), .hero_vis(hero_vis), .foes(foes), .pop(pop),
        .debris(debris), .score(score), .coins(coins), .timer(timer), .lives(lives), .world(world), .frames(frames),
        .map_addr(ma_addr), .map_rd(ma_rd), .rgb(rgb)
    );

    `include "plat_bot.vh"

    // Samples come out PIPE clocks after their coordinates go in.
    reg            rendering = 1'b0;
    reg [PIPE:1]   vld = 0;
    integer        fd = 0, col = 0;
    always @(posedge clk)
        vld <= {vld[PIPE-1:1], rendering};
    always @(negedge clk) begin
        if (vld[PIPE]) begin
            $fwrite(fd, "%06x", rgb);
            col = col + 1;
            if (col == 320) begin
                $fwrite(fd, "\n");
                col = 0;
            end
        end
    end

    task render_frame;
        integer lx, ly;
        begin
            rendering = 1'b1;
            for (ly = 0; ly < 240; ly = ly + 1)
                for (lx = 0; lx < 320; lx = lx + 1) begin
                    x = 2 * lx;
                    y = 2 * ly;
                    @(posedge clk); #1;
                end
            rendering = 1'b0;
            repeat (PIPE + 1) @(posedge clk);
            #1;
        end
    endtask

    integer   t;
    reg [2:0] last_mode = 3'd7;
    reg [8*32:1] fname;

    initial begin
        if ($value$plusargs("T0=%d", T0) && $value$plusargs("T1=%d", T1)) ;
        if ($value$plusargs("STEP=%d", STEP)) ;
        if ($value$plusargs("JOB=%d", JOB)) ;
        $sformat(fname, "plat_gif_%0d.hex", JOB);
        if (T0 <= T1) fd = $fopen(fname, "w");
        #1;
        for (t = 0; t <= (T0 <= T1 ? T1 : 6000); t = t + 1) begin
            run  = (t == 30);
            jump = 1'b0;
            if (mode == 3'd2) begin bot_step; jump = bot_jump; run = 1'b1; end
            tick = 1'b1;
            @(posedge clk); #1;
            tick = 1'b0;
            repeat (79) @(posedge clk);
            #1;
            if (mode != last_mode && T0 > T1)
                $display("tick %0d: mode %0d (world %0d, x %0d)", t, mode, world, game.px[15:4]);
            last_mode = mode;
            if (t >= T0 && t <= T1 && (t - T0) % STEP == 0)
                render_frame;
        end
        if (fd) $fclose(fd);
        $finish;
    end
endmodule
