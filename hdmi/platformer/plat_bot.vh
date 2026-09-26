// A simple bot for the testbenches: always runs, and jumps (holding for a high jump) when
// there is a wall, a pit or a slime just ahead; it simply walks off the end of platforms.
// It peeks at the game's state and the level map, which a player would see on screen.
// fetch_step instead walks under the first mushroom block, bumps it and waits for the
// mushroom to come back to it. Needs instances named level and game.
reg     bot_jump = 1'b0, bot_run = 1'b1;
integer bot_hold = 0, bot_stuck = 0, fetch_phase = 0, fetch_wait = 0;

function bot_solid(input integer col, input integer row);
    bot_solid = row >= 0 && row < 15 && col >= 0 && col < 256 && level.ram[row * 256 + col] >= 32;
endfunction

task bot_step;
    integer d, hx, hy, hh, c, need, kk, fxp, fyp;
    begin
        hx   = game.px[15:4];
        hy   = $signed(game.py) >>> 4;
        hh   = game.big ? 28 : 16;
        need = 0;
        for (d = 1; d <= 14; d = d + 2) begin
            c = (hx + 11 + d) >> 4;
            if (hy >= 0) begin
                if (bot_solid(c, (hy + 2) >> 4) || bot_solid(c, (hy + 14) >> 4) || bot_solid(c, (hy + hh - 3) >> 4))
                    need = 1;                                                            // wall
                if (game.on_ground && hy + hh == 208 && !bot_solid(c, 13)) need = 1;     // pit (at ground level)
            end
        end
        for (kk = 0; kk < 4; kk = kk + 1) begin
            if (game.fst[2 * kk +: 2] == 2'd1) begin
                fxp = game.fx[16 * kk +: 16] >> 4;
                fyp = $signed(game.fy[16 * kk +: 16]) >>> 4;
                if (fxp - hx > 16 && fxp - hx < 44 && fyp > hy + hh - 36 && fyp < hy + hh + 4) need = 1;  // slime ahead
                if (fxp - hx > 0 && fxp - hx < 40 && fyp >= hy + hh + 4 && fyp < hy + hh + 64) need = 1;  // below the ledge
                // At the edge of a raised platform: jump over slimes waiting below rather than drop onto them.
                if (game.on_ground && hy + hh < 208 && !bot_solid((hx + 14) >> 4, (hy + hh) >> 4) &&
                    fxp - hx > 0 && fxp - hx < 96 && fyp > hy) need = 1;
            end
        end
        // At the edge of a raised platform with a pit below the next column: jump across.
        if (game.on_ground && hy + hh < 208 && !bot_solid((hx + 14) >> 4, (hy + hh) >> 4) && !bot_solid((hx + 14) >> 4, 13))
            need = 1;
        bot_stuck = (game.vx == 0) ? bot_stuck + 1 : 0;
        if (bot_stuck > 6) need = 1;
        if (bot_hold > 0 && bot_hold < 20 && game.on_ground)
            bot_hold = 0;                                  // landed: let go, so the next jump is a fresh press
        bot_run = 1'b1;
        if (bot_hold > 0) begin
            bot_hold = bot_hold - 1;
            bot_jump = 1'b1;
        end else if (need && game.on_ground && !bot_jump) begin
            bot_hold = 22;
            bot_jump = 1'b1;
        end else begin
            bot_jump = 1'b0;
        end
    end
endtask

// Fetch the mushroom from the block at column 21: phases 0 walk, 1 stop, 2 jump, 3 wait, 4 done.
task fetch_step;
    integer hx;
    begin
        hx = game.px[15:4];
        case (fetch_phase)
            0: begin
                bot_run = 1'b1; bot_jump = 1'b0;
                if (hx >= 327) fetch_phase = 1;            // stops about 9 px later, under the block
            end
            1: begin
                bot_run = 1'b0; bot_jump = 1'b0;
                if (game.vx == 0) begin fetch_phase = 2; bot_hold = 20; end
            end
            2: begin
                bot_run = 1'b0;
                bot_jump = bot_hold > 0;
                bot_hold = bot_hold - 1;
                if (bot_hold < 0) begin fetch_phase = 3; fetch_wait = 0; bot_hold = 0; end
            end
            3: begin
                bot_run = 1'b0; bot_jump = 1'b0;           // the mushroom comes back from the pipe
                fetch_wait = fetch_wait + 1;
                if (game.big) fetch_phase = 4;
            end
            default: bot_step;
        endcase
    end
endtask
