// Feeds a byte stream (tb_stream.hex, +len=N bytes) to the terminal engine as fast as it will
// take them, then dumps what term_test.py compares with the Python model:
//   tb_screen.hex   the 28 x 80 terminal cells in display order
//   tb_bars.hex     the title bar and status bar cells
//   tb_state.txt    cursor, modes and attributes
//   tb_replies.hex  every byte the terminal sent back
//   tb_ram.hex      the whole cell memory, then the row map (for the frame test)
// The renderer's turns on the read port are emulated (with junk addresses), and the bar
// updater competes for the write port as it does in the real design.
`timescale 1ns/1ps
module term_core_tb;
    reg clk = 1'b0;
    always #20 clk = ~clk;

    reg [7:0] stream [0:1048575];
    integer len = 0, pos = 0, quiet = 0, gaps = 0, trace = 0, stuck = 0, i, f;
    reg [7:0] in_q = 8'd0;
    reg       gap = 1'b0;
    wire      in_empty = (pos >= len) || gap;
    wire      in_rd;

    reg [2:0] ph = 3'd0;
    wire      slot = (ph == 3'd0);
    reg [12:0] junk = 13'd0;

    wire        e_we, b_we, idle, tcem, cur_blink, scnm, bank, title_custom, bell, tx_start, cmd_theme, cmd_crt;
    integer     themes = 0, crts = 0;                   // the shell's theme and crt commands
    wire [12:0] e_waddr, b_waddr, e_raddr;
    wire [31:0] e_wdata, b_wdata, ram_q;
    wire [6:0]  cx;
    wire [4:0]  cy;
    wire [1:0]  cur_style;
    wire [139:0] map_flat;
    wire [7:0]  tx_data, ln_bcd, col_bcd;
    reg  [5:0]  tx_left = 6'd0;
    wire        tx_busy = (tx_left != 6'd0);

    term_cells cells (
        .clk(clk), .we(e_we | b_we), .waddr(e_we ? e_waddr : b_waddr), .wdata(e_we ? e_wdata : b_wdata),
        .raddr(slot ? junk : e_raddr), .q(ram_q)
    );
    term_core core (
        .clk(clk), .in_empty(in_empty), .in_data(in_q), .in_rd(in_rd),
        .w_en(e_we), .w_addr(e_waddr), .w_data(e_wdata), .r_addr(e_raddr), .r_ok(!slot), .r_data(ram_q),
        .idle(idle), .cx(cx), .cy(cy), .tcem(tcem), .cur_style(cur_style), .cur_blink(cur_blink), .scnm(scnm),
        .bank(bank), .map_flat(map_flat), .title_custom(title_custom), .bell(bell),
        .ln_bcd(ln_bcd), .col_bcd(col_bcd), .shell_req(1'b0), .cmd_theme(cmd_theme), .cmd_crt(cmd_crt),
        .tx_busy(tx_busy), .tx_start(tx_start), .tx_data(tx_data)
    );
    term_bars bars (
        .clk(clk), .ok(idle), .ln(ln_bcd), .col(col_bcd), .baud_bcd(28'h0460800),
        .active(1'b1), .theme(2'd2), .title_custom(title_custom),
        .w_en(b_we), .w_addr(b_waddr), .w_data(b_wdata)
    );

    initial begin
        if (!$value$plusargs("len=%d", len)) len = 0;
        if (!$value$plusargs("gaps=%d", gaps)) gaps = 0;
        if (!$value$plusargs("trace=%d", trace)) trace = 0;
        if (len > 0) $readmemh("tb_stream.hex", stream, 0, len - 1);
        f = $fopen("tb_replies.hex", "w");
    end

    always @(posedge clk) begin
        ph <= ph + 1'b1;
        junk <= $random;
        gap <= gaps ? (($random & 7) == 0) : 1'b0;
        if (in_rd) begin
            in_q <= stream[pos];
            pos <= pos + 1;
            if (trace)
                $display("byte %0d: %02x  (state %0d pst %0d cx %0d cy %0d)", pos, stream[pos], core.state, core.pst, cx, cy);
        end
        stuck <= in_rd ? 0 : stuck + 1;
        if (stuck == 200000) begin
            $display("FAIL: stuck at byte %0d: state %0d pst %0d cx %0d cy %0d f_row %0d f_col %0d s_cnt %0d",
                     pos, core.state, core.pst, cx, cy, core.f_row, core.f_col, core.s_cnt);
            $finish;
        end
        if (cmd_theme) themes = themes + 1;
        if (cmd_crt) crts = crts + 1;
        if (tx_start) begin
            $fwrite(f, "%02x\n", tx_data);
            tx_left <= 6'd40;
        end else if (tx_left != 6'd0)
            tx_left <= tx_left - 1'b1;
        if (e_we && b_we) begin
            $display("FAIL: engine and bar updater wrote in the same clock");
            $finish;
        end
        quiet <= (pos >= len && idle && !tx_busy) ? quiet + 1 : 0;
        if (quiet == 400) begin                 // long enough for the bars to be rewritten
            $fclose(f);
            dump;
            $finish;
        end
    end

    task dump;
        integer r, c, g;
        begin
            g = $fopen("tb_screen.hex", "w");
            for (r = 0; r < 28; r = r + 1)
                for (c = 0; c < 80; c = c + 1)
                    $fwrite(g, "%08x\n", cells.ram[({bank, core.map[r]}) * 80 + c]);
            $fclose(g);
            g = $fopen("tb_bars.hex", "w");
            for (c = 0; c < 160; c = c + 1)
                $fwrite(g, "%08x\n", cells.ram[4800 + c]);
            $fclose(g);
            g = $fopen("tb_ram.hex", "w");
            for (c = 0; c < 4960; c = c + 1)
                $fwrite(g, "%08x\n", cells.ram[c]);
            for (r = 0; r < 28; r = r + 1)
                $fwrite(g, "%08x\n", core.map[r]);
            $fclose(g);
            g = $fopen("tb_state.txt", "w");
            $fwrite(g, "cx %0d\ncy %0d\nwrap %0d\nbank %0d\ntcem %0d\ncur_style %0d\ncur_blink %0d\nscnm %0d\n",
                    cx, cy, core.wrap, bank, tcem, cur_style, cur_blink, scnm);
            $fwrite(g, "title_custom %0d\ntop %0d\nbot %0d\nawm %0d\nirm %0d\nlnm %0d\n",
                    title_custom, core.top, core.bot, core.awm, core.irm, core.lnm);
            $fwrite(g, "fg %0d\nbg %0d\nfl %0d\ninv %0d\ncon %0d\ng0 %0d\ng1 %0d\ngl %0d\npst %0d\n",
                    core.fg, core.bg, core.fl, core.inv, core.con, core.g0, core.g1, core.gl, core.pst);
            $fwrite(g, "local %0d\nprow %0d\nthemes %0d\ncrts %0d\n", core.local, core.prow, themes, crts);
            $fclose(g);
        end
    endtask
endmodule
