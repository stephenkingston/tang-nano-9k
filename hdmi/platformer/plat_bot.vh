// A simple bot for the testbenches: always runs, and jumps (holding for a high jump) when
// there is a wall, a pit or a slime just ahead; it simply walks off the end of platforms. It peeks at the game's state
// and the level map, which a player would see on screen. Needs instances named level and game.
reg     bot_jump = 1'b0;
integer bot_hold = 0, bot_stuck = 0;

function bot_solid(input integer col, input integer row);
    bot_solid = row >= 0 && row < 15 && col >= 0 && col < 256 && level.ram[row * 256 + col] >= 32;
endfunction

task bot_step;
    integer d, hx, hy, c, need, kk, fxp, fyp;
    begin
        hx   = game.px[15:4];
        hy   = $signed(game.py) >>> 4;
        need = 0;
        for (d = 1; d <= 14; d = d + 2) begin
            c = (hx + 11 + d) >> 4;
            if (hy >= 0) begin
                if (bot_solid(c, (hy + 2) >> 4) || bot_solid(c, (hy + 13) >> 4)) need = 1;   // wall
                if (game.on_ground && hy == 192 && !bot_solid(c, 13)) need = 1;               // pit (at ground level)
            end
        end
        for (kk = 0; kk < 4; kk = kk + 1) begin
            if (game.fst[2 * kk +: 2] == 2'd1) begin
                fxp = game.fx[16 * kk +: 16] >> 4;
                fyp = $signed(game.fy[16 * kk +: 16]) >>> 4;
                if (fxp - hx > 16 && fxp - hx < 44 && fyp > hy - 20 && fyp < hy + 20) need = 1;  // slime ahead
                if (fxp - hx > 0 && fxp - hx < 40 && fyp >= hy + 20 && fyp < hy + 80) need = 1;  // slime below the ledge
                // At the edge of a raised platform: jump over slimes waiting below rather than drop onto them.
                if (game.on_ground && hy < 192 && !bot_solid((hx + 14) >> 4, (hy + 16) >> 4) &&
                    fxp - hx > 0 && fxp - hx < 96 && fyp > hy) need = 1;
            end
        end
        // At the edge of a raised platform with a pit below the next column: jump across.
        if (game.on_ground && hy < 192 && !bot_solid((hx + 14) >> 4, (hy + 16) >> 4) && !bot_solid((hx + 14) >> 4, 13))
            need = 1;
        bot_stuck = (game.vx == 0) ? bot_stuck + 1 : 0;
        if (bot_stuck > 6) need = 1;
        if (bot_hold > 0 && bot_hold < 20 && game.on_ground)
            bot_hold = 0;                                  // landed: let go, so the next jump is a fresh press
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
