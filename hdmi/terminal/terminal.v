// Tang Nano 9K: NANO TERM, a serial terminal on the HDMI port.
//
// Text sent to the board's USB serial port (the BL702's second interface, /dev/ttyUSB1 on
// Linux) appears on an 80x28 terminal with a title bar and a status bar: 720x480 @ 60 Hz,
// with 9x16 character cells like VGA text mode.
// It understands UTF-8 and the VT100/xterm escape sequences that shells, editors and
// ncurses programs use: cursor movement, erasing, scroll regions, inserting and deleting,
// 256 colours (truecolour is rounded to them), bold/dim/italic/underline/blink/strike/
// reverse, the alternate screen, window titles, box drawing and braille graphics. It answers
// cursor position and device attribute queries on the serial port's other direction. The
// serial speed (9600 to 3000000 baud) is detected from the line.
//
// It starts as a tiny shell for typing at it directly: a "$ " prompt, Backspace, and Enter,
// which runs commands, among them AES-128-CBC encryption and decryption (term_aes.v).
// S1 cycles the colour theme (colour, green phosphor, amber phosphor) and, held down, brings
// the shell back; S2 toggles CRT scanlines.
// LEDs: 0 receiving, 1 sending, 4 measuring the speed, 5 overrun.
module top (
    input  wire       clk,          // 27 MHz oscillator
    input  wire [1:0] btn,          // S1, S2; active low
    input  wire       uart_rx,
    output wire       uart_tx,
    output wire       tmds_clk_p,
    output wire       tmds_clk_n,
    output wire [2:0] tmds_d_p,
    output wire [2:0] tmds_d_n,
    output wire [5:0] led           // active low
);
    `include "term_params.vh"
    localparam CLK_HZ = 27_000_000;

    wire        clk_pix, reset, frame;
    wire [9:0]  x, y;
    wire [23:0] rgb;

    dvi_tx #(.PIPE(6), .MODE(1)) video (
        .clk_27(clk), .clk_pix(clk_pix), .reset(reset), .x(x), .y(y), .frame(frame),
        .rgb(rgb),
        .tmds_clk_p(tmds_clk_p), .tmds_clk_n(tmds_clk_n), .tmds_d_p(tmds_d_p), .tmds_d_n(tmds_d_n)
    );

    // ---------------------------------------------------------------- serial port
    // The speed follows the line (term_serial_in): no setting to get wrong.
    wire        rx_valid, hold, fifo_empty, fifo_rd, fifo_ovf;
    wire [7:0]  rx_data, fifo_q;
    wire [3:0]  rate;
    wire [15:0] period = rate_period(rate);
    term_serial_in #(.INIT(INIT_RATE)) sin (.clk(clk_pix), .rx(uart_rx), .valid(rx_valid), .data(rx_data),
                                             .rate(rate), .hold(hold));
    term_fifo fifo (.clk(clk_pix), .wr(rx_valid), .wdata(rx_data), .rd(fifo_rd), .rdata(fifo_q),
                    .empty(fifo_empty), .ovf(fifo_ovf));

    wire       tx_start, tx_busy;
    wire [7:0] tx_data;
    term_uart_tx utx (.clk(clk_pix), .period(period), .start(tx_start), .data(tx_data), .busy(tx_busy), .tx(uart_tx));

    // ---------------------------------------------------------------- screen memory
    // One write port (the engine, or the bar updater while the engine is idle) and one read
    // port, which the renderer uses once every 8 pixels and the engine the rest of the time.
    wire        e_we, b_we, slot;
    wire [12:0] e_waddr, b_waddr, e_raddr, r_raddr;
    wire [31:0] e_wdata, b_wdata, ram_q;
    term_cells cells (
        .clk(clk_pix), .we(e_we | b_we), .waddr(e_we ? e_waddr : b_waddr), .wdata(e_we ? e_wdata : b_wdata),
        .raddr(slot ? r_raddr : e_raddr), .q(ram_q)
    );

    // ---------------------------------------------------------------- terminal engine
    wire [6:0]   cx;
    wire [4:0]   cy;
    wire [7:0]   ln_bcd, col_bcd;
    wire [1:0]   cur_style;
    wire [139:0] map_flat;
    wire         idle, tcem, cur_blink, scnm, bank, title_custom, bell, cmd_theme, cmd_crt;
    term_core core (
        .clk(clk_pix), .in_empty(fifo_empty), .in_data(fifo_q), .in_rd(fifo_rd),
        .w_en(e_we), .w_addr(e_waddr), .w_data(e_wdata), .r_addr(e_raddr), .r_ok(!slot), .r_data(ram_q),
        .idle(idle), .cx(cx), .cy(cy), .tcem(tcem), .cur_style(cur_style), .cur_blink(cur_blink), .scnm(scnm),
        .bank(bank), .map_flat(map_flat), .title_custom(title_custom), .bell(bell),
        .ln_bcd(ln_bcd), .col_bcd(col_bcd), .shell_req(shell_req), .cmd_theme(cmd_theme), .cmd_crt(cmd_crt),
        .tx_busy(tx_busy), .tx_start(tx_start), .tx_data(tx_data)
    );

    // ---------------------------------------------------------------- live values for the bars
    reg [7:0]  frames = 8'd0;
    reg [5:0]  since_rx = 6'd63;            // frames since the last byte (restarts the cursor blink)
    reg [3:0]  rx_act = 4'd0, tx_act = 4'd0, bell_left = 4'd0;
    reg [1:0]  theme = 2'd0;
    reg        crt = 1'b0, ovf_seen = 1'b0;
    reg [1:0]  btn_s1 = 2'b00, btn_s2 = 2'b00, btn_prev = 2'b00;
    reg [5:0]  s1_held = 6'd0;              // frames S1 has been down
    wire       shell_req = frame && btn_s2[0] && (s1_held == 6'd30);

    always @(posedge clk_pix) begin
        btn_s1 <= ~btn;
        btn_s2 <= btn_s1;
        if (rx_valid) begin
            rx_act <= 4'd6;
            since_rx <= 6'd0;
        end
        if (tx_start)
            tx_act <= 4'd6;
        if (bell)
            bell_left <= 4'd8;
        if (fifo_ovf) ovf_seen <= 1'b1;
        if (frame) begin
            frames <= frames + 1'b1;
            if (!rx_valid && since_rx != 6'd63) since_rx <= since_rx + 1'b1;
            if (rx_act != 0 && !rx_valid) rx_act <= rx_act - 1'b1;
            if (tx_act != 0 && !tx_start) tx_act <= tx_act - 1'b1;
            if (bell_left != 0 && !bell) bell_left <= bell_left - 1'b1;
            // buttons, sampled once a frame: S1 pressed cycles the theme and held for half a
            // second brings the shell back; S2 toggles the CRT scanlines
            btn_prev <= btn_s2;
            if (btn_s2[0]) begin
                if (s1_held != 6'd63) s1_held <= s1_held + 1'b1;
            end else
                s1_held <= 6'd0;
        end
        // the shell's theme and crt commands do the same as the buttons
        if ((frame && !btn_s2[0] && s1_held != 6'd0 && s1_held < 6'd30) || cmd_theme)
            theme <= (theme == 2'd2) ? 2'd0 : theme + 1'b1;
        if ((frame && btn_s2[1] && !btn_prev[1]) || cmd_crt)
            crt <= ~crt;
    end

    term_bars bars (
        .clk(clk_pix), .ok(idle), .ln(ln_bcd), .col(col_bcd), .baud_bcd(rate_bcd(rate)),
        .active(rx_act != 0), .theme(theme), .title_custom(title_custom),
        .w_en(b_we), .w_addr(b_waddr), .w_data(b_wdata)
    );

    // ---------------------------------------------------------------- picture
    term_render render (
        .clk(clk_pix), .x(x), .y(y), .slot(slot), .r_addr(r_raddr), .r_data(ram_q),
        .bank(bank), .map_flat(map_flat), .cx(cx), .cy(cy),
        .cursor(tcem && (!cur_blink || !since_rx[5] || !frames[5])), .style(cur_style), .scnm(scnm),
        .blink_off(frames[5]), .bell(bell_left != 0), .theme(theme), .crt(crt), .rgb(rgb)
    );

    assign led = ~{ovf_seen, hold, 2'b00, tx_act != 0, rx_act != 0};
endmodule


// 8N1 receiver. The bit timer counts in sixteenths of a sample, so fast baud rates that do
// not divide the clock still sample every bit near its middle.
module term_uart_rx (
    input  wire        clk,
    input  wire        en,              // a new sample of the line
    input  wire        s,               // the line, synchronised
    input  wire [15:0] period,          // bit time in sixteenths of a sample
    input  wire [15:0] quiet_len,       // 10 bits, in samples
    input  wire        restart,         // the speed changed: wait for a quiet line
    output reg         valid = 1'b0,    // one-clock pulse with data
    output reg  [7:0]  data = 8'd0,
    output reg         ferr = 1'b0      // one-clock pulse: stop bit missing
);
    reg        busy = 1'b0, armed = 1'b1;
    reg [15:0] acc = 16'd0, quiet = 16'd0;
    reg [3:0]  bitn = 4'd0;
    reg [7:0]  sh = 8'd0;

    always @(posedge clk) begin
        valid <= 1'b0;
        ferr <= 1'b0;
        if (restart) begin
            busy <= 1'b0;
            armed <= 1'b0;
            quiet <= 16'd0;
        end else if (!en) begin
        end else if (!busy) begin
            if (!armed) begin               // after a change of speed, start between two bytes:
                if (!s)                     // the line must first be high for 10 bits
                    quiet <= 16'd0;
                else if (quiet >= quiet_len)
                    armed <= 1'b1;
                else
                    quiet <= quiet + 1'b1;
            end else if (!s) begin
                busy <= 1'b1;
                acc <= period >> 1;
                bitn <= 4'd0;
            end
        end else if (acc[15:4] != 12'd0) begin
            acc[15:4] <= acc[15:4] - 1'b1;  // a whole sample
        end else begin
            acc <= {12'd0, acc[3:0]} + period - 16'd16;
            bitn <= bitn + 1'b1;
            if (bitn == 4'd0) begin
                if (s) busy <= 1'b0;                        // a glitch, not a start bit
            end else if (bitn <= 4'd8) begin
                sh <= {s, sh[7:1]};
            end else begin
                busy <= 1'b0;
                if (s) begin valid <= 1'b1; data <= sh; end
                else ferr <= 1'b1;
            end
        end
    end
endmodule


// The serial input, at whatever speed the sender uses. The bytes are decoded from a delayed
// copy of the line (0.6 ms for the fast speeds, 9.7 ms for 9600 to 38400), while a receiver on
// the live line watches for trouble: a framing error, or a pulse clearly shorter than a bit,
// starts a measurement of the live line. The shortest of the next 8 pulses (or of fewer, once
// the line is quiet for 16 of them) is one bit and picks the speed from the table in
// term_params.vh. That happens before the first byte sent at the new speed comes out of the
// delay, so a change of speed loses nothing; whatever is decoded while measuring (the start of
// a slow sender's bytes, seen through the short delay at the old speed) is thrown away.
module term_serial_in #(
    parameter INIT = 8                  // index of the speed at power-up
) (
    input  wire       clk,
    input  wire       rx,
    output wire       valid,
    output wire [7:0] data,
    output reg  [3:0] rate = INIT,
    output reg        hold = 1'b0       // measuring the speed (what is decoded meanwhile is junk)
);
    `include "term_params.vh"
    localparam [15:0] LONG = 16'hFFFF;
    localparam SLOW = 2;                // speeds 0-2 (9600-38400) use the slow delay

    reg  [2:0]  sync = 3'b111;
    wire        line = sync[2];

    // the delays: 16384 samples, of every clock and of every 16th
    reg         fast_mem [0:16383];
    reg         slow_mem [0:16383];
    reg  [13:0] fp = 14'd0, sp = 14'd0;
    reg  [3:0]  sub = 4'd0;
    reg         fast_d = 1'b1, slow_d = 1'b1, tick = 1'b0;
    integer i;
    initial
        for (i = 0; i < 16384; i = i + 1) begin
            fast_mem[i] = 1'b1;
            slow_mem[i] = 1'b1;
        end
    always @(posedge clk) begin
        sync <= {sync[1:0], rx};
        fast_mem[fp] <= line;
        fast_d <= fast_mem[fp + 1'b1];                  // the oldest sample
        fp <= fp + 1'b1;
        sub <= sub + 1'b1;
        tick <= (sub == 4'd15);
        if (sub == 4'd15) begin
            slow_mem[sp] <= line;
            slow_d <= slow_mem[sp + 1'b1];
            sp <= sp + 1'b1;
        end
    end

    // the live receiver (for its framing errors) and the one that decodes the delayed line
    wire [15:0] per = rate_period(rate);
    wire [15:0] quiet = rate_quiet(rate);
    wire        slow = (rate <= SLOW);
    wire        live_ferr, got;
    wire [7:0]  dec_data;
    reg         changed = 1'b0;
    term_uart_rx live (.clk(clk), .en(1'b1), .s(line), .period(per), .quiet_len(quiet), .restart(changed),
                       .valid(), .data(), .ferr(live_ferr));
    term_uart_rx dec (.clk(clk), .en(slow ? tick : 1'b1), .s(slow ? slow_d : fast_d),
                      .period(slow ? {4'd0, per[15:4]} : per), .quiet_len(slow ? {4'd0, quiet[15:4]} : quiet),
                      .restart(changed), .valid(got), .data(dec_data), .ferr());

    assign valid = got && !hold;
    assign data = dec_data;

    // pulse widths on the live line
    reg         prev = 1'b1, seen = 1'b0, sorting = 1'b0;
    reg  [15:0] run = 16'd0, minw = LONG;
    reg  [3:0]  pulses = 4'd0, k = 4'd0;
    wire        change = (line != prev);
    wire        pulse = change && seen && (run >= 16'd4);                 // a whole pulse, not a glitch

    always @(posedge clk) begin
        prev <= line;
        changed <= 1'b0;
        if (change) begin
            seen <= 1'b1;
            run <= 16'd1;
        end else if (run != LONG)
            run <= run + 1'b1;
        if (!hold) begin
            if (live_ferr || (pulse && run < rate_short(rate))) begin
                hold <= 1'b1;
                pulses <= 4'd0;
                minw <= live_ferr ? LONG : run;
            end
        end else if (sorting) begin                     // the fastest speed whose limit minw is under
            if (k == 4'd0 || minw < rate_edge(k)) begin
                if (k != rate) begin
                    rate <= k;
                    changed <= 1'b1;
                end
                sorting <= 1'b0;
                hold <= 1'b0;
            end else
                k <= k - 1'b1;
        end else if (pulses >= 4'd8 || (line && pulses >= 4'd2 && {4'd0, run} > {minw, 4'd0})) begin
            sorting <= 1'b1;
            k <= NUM_RATES - 1;
        end else if (pulse) begin
            if (run < minw) minw <= run;
            pulses <= pulses + 1'b1;
        end
    end
endmodule


module term_uart_tx (
    input  wire        clk,
    input  wire [15:0] period,          // bit time in sixteenths of a clock
    input  wire        start,
    input  wire [7:0]  data,
    output reg         busy = 1'b0,
    output wire        tx
);
    reg [9:0]  sh = 10'h3FF;
    reg [3:0]  left = 4'd0;
    reg [15:0] acc = 16'd0, per = 16'd0;
    assign tx = sh[0];

    always @(posedge clk) begin
        if (!busy) begin
            if (start) begin
                sh <= {1'b1, data, 1'b0};
                left <= 4'd10;
                acc <= period;
                per <= period;              // a byte keeps the speed it started with
                busy <= 1'b1;
            end
        end else if (acc[15:4] != 12'd0) begin
            acc[15:4] <= acc[15:4] - 1'b1;
        end else begin
            acc <= {12'd0, acc[3:0]} + per - 16'd16;
            sh <= {1'b1, sh[9:1]};
            left <= left - 1'b1;
            if (left == 4'd1) busy <= 1'b0;
        end
    end
endmodule


// 2 KB receive buffer; the engine is usually far ahead of the serial port, but a screen
// clear or a scroll takes a few thousand clocks.
module term_fifo (
    input  wire       clk,
    input  wire       wr,
    input  wire [7:0] wdata,
    input  wire       rd,               // rdata holds the byte from the next clock
    output reg  [7:0] rdata = 8'd0,
    output wire       empty,
    output reg        ovf = 1'b0        // one-clock pulse: a byte was dropped
);
    reg [7:0]  mem [0:2047];
    reg [11:0] wp = 12'd0, rp = 12'd0;
    assign empty = (wp == rp);
    wire full = (wp[10:0] == rp[10:0]) && (wp[11] != rp[11]);

    always @(posedge clk) begin
        ovf <= wr && full;
        if (wr && !full) begin
            mem[wp[10:0]] <= wdata;
            wp <= wp + 1'b1;
        end
        if (rd && !empty) begin
            rdata <= mem[rp[10:0]];
            rp <= rp + 1'b1;
        end
    end
endmodule


// The screen: 62 rows of 80 cells. Rows 0-27 are the main screen and 32-59 the alternate
// screen (the engine's row maps say which physical row shows each terminal row); row 60 is
// the title bar and 61 the status bar.
module term_cells (
    input  wire        clk,
    input  wire        we,
    input  wire [12:0] waddr,
    input  wire [31:0] wdata,
    input  wire [12:0] raddr,
    output reg  [31:0] q = 32'd0
);
    reg [31:0] ram [0:4959];
    initial $readmemh("term_cells.hex", ram);
    always @(posedge clk) begin
        if (we) ram[waddr] <= wdata;
        q <= ram[raddr];
    end
endmodule


// The terminal engine: takes bytes from the FIFO, parses UTF-8 and escape sequences and
// edits the screen, one cell per step. Scrolling rotates a row map (logical row -> physical
// row) and blanks one row, so it costs 80 steps whatever the size of the scroll region.
// It takes a step every other clock (ce). The chip's real delays are well beyond what
// nextpnr's timing model predicts: builds whose engine had to settle in one 37 ns clock failed
// on the board although their timing reports passed, and the same builds worked at a slower
// clock. With two clocks a step they have the margin they need.
module term_core (
    input  wire         clk,
    input  wire         in_empty,
    input  wire [7:0]   in_data,            // the byte popped on the previous clock (kept in bq)
    output wire         in_rd,
    output wire         w_en,               // (one clock per write)
    output reg  [12:0]  w_addr = 13'd0,
    output reg  [31:0]  w_data = 32'd0,
    output wire [12:0]  r_addr,
    input  wire         r_ok,               // the read port is free this clock
    input  wire [31:0]  r_data,             // the cell read on the previous clock (kept in rq)
    output wire         idle,
    output reg  [6:0]   cx = INIT_CX,
    output reg  [4:0]   cy = INIT_CY,
    output reg          tcem = 1'b1,        // cursor visible
    output reg  [1:0]   cur_style = 2'd0,   // block, underline, bar
    output reg          cur_blink = 1'b1,
    output reg          scnm = 1'b0,        // whole screen reversed
    output reg          bank = 1'b0,        // 1: alternate screen
    output wire [139:0] map_flat,
    output reg          title_custom = 1'b0,
    output reg          bell = 1'b0,
    output wire [7:0]   ln_bcd,             // cursor row and column + 1, as two decimal digits
    output wire [7:0]   col_bcd,
    input  wire         shell_req,          // S1 held: back to the built-in shell
    output wire         cmd_theme,          // the shell's theme and crt commands, for the display
    output wire         cmd_crt,
    input  wire         tx_busy,
    output wire         tx_start,
    output reg  [7:0]   tx_data = 8'd0
);
    `include "term_params.vh"
    `include "term_uni.vh"

    localparam S_IDLE = 5'd0, S_BYTE = 5'd1, S_UNI = 5'd2, S_PUT = 5'd3, S_PUT_W = 5'd4, S_PUT_W2 = 5'd5,
               S_SCROLL = 5'd6, S_FILL = 5'd7, S_SH_RD = 5'd8, S_SH_WR = 5'd9, S_SGR = 5'd10,
               S_DECSET = 5'd11, S_SM = 5'd12, S_SUM_RD = 5'd13, S_SUM_ACC = 5'd14, S_REPLY = 5'd15,
               S_SUM_DONE = 5'd16, S_USCAN = 5'd17, S_UCMP = 5'd18, S_EV_RD = 5'd19, S_EV = 5'd20,
               S_AES = 5'd21, S_EV_END = 5'd22, S_PADCHK = 5'd23, S_SAY = 5'd24;
    localparam P_GROUND = 4'd0, P_ESC = 4'd1, P_ESC_INT = 4'd2, P_CSI = 4'd3, P_CSI_IGN = 4'd4,
               P_OSC = 4'd5, P_OSC_ESC = 4'd6, P_STR = 4'd7, P_STR_ESC = 4'd8;
    localparam [31:0] BLANK0 = {6'd0, 8'd0, 8'd7, 10'h020};

    reg [4:0]  state = S_IDLE;
    // a step every other clock: the engine's registers change only at the end of a ce clock, so
    // everything computed from them has two clocks to settle. A cell read is sampled at the end
    // of a ce clock (its address has been steady for two clocks) and kept in rq for the next step;
    // a byte popped from the FIFO is kept in bq the same way, the clock after the pop (the block
    // RAM's output may move on after that).
    reg        ce = 1'b0, shell_req_d = 1'b0;
    reg        w_en_r = 1'b0, cmd_theme_r = 1'b0, cmd_crt_r = 1'b0, tx_start_r = 1'b0;
    reg [31:0] rq = 32'd0;
    reg [7:0]  bq = 8'd0;
    always @(posedge clk) begin
        ce <= ~ce;
        shell_req_d <= shell_req;
        if (!ce) begin
            rq <= r_data;
            bq <= in_data;
        end
    end
    assign w_en = w_en_r && !ce;
    assign cmd_theme = cmd_theme_r && !ce;
    assign cmd_crt = cmd_crt_r && !ce;
    assign tx_start = tx_start_r && !ce;
    reg [3:0]  pst = P_GROUND;
    reg        wrap = 1'b0;
    reg [7:0]  fg = 8'd7, bg = 8'd0;
    reg [5:0]  fl = 6'd0;                   // bold dim italic underline blink strike
    reg        inv = 1'b0, con = 1'b0;
    reg [4:0]  top = 5'd0, bot = 5'd27;
    reg        awm = 1'b1, irm = 1'b0, lnm = 1'b0;
    reg        g0 = 1'b0, g1 = 1'b0, gl = 1'b0;
    reg [4:0]  map [0:27];                  // terminal row -> physical row (within the bank)
    reg [4:0]  smap [0:27];                 // the main screen's map while the alternate one is up

    // saved cursors (DECSC), one per screen
    reg [6:0]  sv_cx [0:1];
    reg [4:0]  sv_cy [0:1];
    reg [7:0]  sv_fg [0:1];
    reg [7:0]  sv_bg [0:1];
    reg [5:0]  sv_fl [0:1];
    reg [1:0]  sv_inv = 2'b00, sv_con = 2'b00, sv_g0 = 2'b00, sv_g1 = 2'b00, sv_gl = 2'b00;

    // parser: digits collect in cur; each finished parameter is written to prm[np]
    reg [11:0] prm [0:15];
    reg [11:0] cur = 12'd0, prm0 = 12'd0, prm1 = 12'd0;
    reg [3:0]  np = 4'd0;
    reg        ovf = 1'b0, fresh = 1'b0;
    reg [7:0]  priv = 8'd0, inter = 8'd0;
    reg [1:0]  need = 2'd0;
    reg [20:0] ucp = 21'd0;
    reg [7:0]  osc_num = 8'd0;
    reg [1:0]  osc_phase = 2'd0;
    reg [5:0]  tlen = 6'd0;

    // jobs
    reg [9:0]  put_g = 10'd0, last_g = 10'd0;
    reg        put_w = 1'b0, last_w = 1'b0, last_ok = 1'b0;
    reg [11:0] rep = 12'd0;
    reg        s_up = 1'b0;
    reg [4:0]  s_top = 5'd0, s_bot = 5'd0, s_cnt = 5'd0, scr_ret = S_IDLE;
    reg [4:0]  f_row = 5'd0, f_erow = 5'd0, fill_ret = S_IDLE;
    reg [6:0]  f_col = 7'd0, f_ecol = 7'd0;
    reg [31:0] f_word = 32'd0;
    reg        f_title = 1'b0;
    reg [6:0]  sh_dst = 7'd0, sh_k = 7'd0;
    reg        sh_ins = 1'b0;
    reg [4:0]  shift_ret = S_IDLE;
    reg [4:0]  pi = 5'd0;
    reg        set_on = 1'b0;
    reg [3:0]  sgr_mode = 4'd0;
    reg [5:0]  tc_cube = 6'd0;              // truecolour so far: the colour cube index
    reg [4:0]  sum_row = 5'd0;
    reg [6:0]  sum_col = 7'd0;
    reg [31:0] sum = 32'd0;
    reg        dumping = 1'b0;             // CSI 998 n: send each cell's glyph byte too
    reg [2:0]  rkind = 3'd0;
    reg [4:0]  ridx = 5'd0;

    // The built-in shell, up at power-up, for typing at the terminal directly (from minicom,
    // say): a "$ " prompt, Backspace (BS or DEL) rubs out, and Enter reads the line back from
    // the screen (from the prompt, over every row it wrapped onto) and runs it. Besides help,
    // clear, theme and crt there is AES-128 in CBC mode (term_aes): key and iv take 32 hex
    // digits, enc encrypts the rest of the line (with PKCS#7 padding) and prints it in hex, and
    // dec decrypts hex and prints the text. Arrow and editing keys are ignored; any other escape
    // sequence means a program is driving the terminal, and the shell steps aside until
    // CSI ? 2112 h or S1 held down. What the shell prints goes through the terminal like
    // received bytes (src_say).
    reg        local = 1'b1;
    reg        last_cr = 1'b0, src_say = 1'b0, want_shell = 1'b0;
    reg [4:0]  prow = INIT_CY;              // the row of the last prompt (it moves up as the screen scrolls)
    reg [7:0]  say_q = 8'd0;
    reg [3:0]  say_ph = 4'd0;               // what the shell prints next (0: nothing)
    reg [1:0]  say_out = 2'd0;              // after the line break: 0 nothing, 1 bytes in hex, 2 text
    reg [4:0]  ev_row = 5'd0;
    reg [6:0]  ev_col = 7'd0;
    // commands: while the line is read, a matcher per command (cmd_char, cmd_len in term_uni.vh)
    reg [7:0]  cm_ok = 8'd0;                // command k still matches the word so far
    reg [2:0]  cm_i [0:7];                  // letters of command k matched
    reg        word_on = 1'b0, word_end = 1'b0, nonblank = 1'b0, args = 1'b0;
    // the argument, written to the AES unit's RAM at ap as it is read: hex digits (key, iv,
    // dec) or the text (enc)
    reg        a_hex = 1'b0, a_text = 1'b0, a_bad = 1'b0, a_ovf = 1'b0, a_half = 1'b0;
    reg [3:0]  a_hi = 4'd0;
    reg [10:0] ap = 11'd0, a_len = 11'd0, dlen = 11'd0;
    reg [7:0]  pv = 8'd0;                   // the padding byte
    reg        padded = 1'b0, pc_wait = 1'b0, pc_got = 1'b0;
    reg [2:0]  aes_op = 3'd0;
    reg [1:0]  aph = 2'd0;
    reg        aes_go = 1'b0, aes_we = 1'b0;
    reg [7:0]  aes_wd = 8'd0;
    wire       aes_busy;
    wire [7:0] aes_q;
    term_aes aes (.clk(clk), .go(aes_go), .op(aes_op), .nblk(ap[10:4]), .busy(aes_busy), .h_we(aes_we),
                  .h_addr(ap), .h_wdata(aes_wd), .h_rdata(aes_q));
    // what the shell prints from term_say.hex (0-terminated strings)
    reg [7:0]  say_rom [0:2047];
    initial $readmemh("term_say.hex", say_rom);
    reg [10:0] say_ptr = 11'd0;
    reg [7:0]  say_c = 8'd0;
    always @(posedge clk)
        say_c <= say_rom[say_ptr];

    // code point ranges for symbols, zero-width and double-width characters (term_uni.hex),
    // scanned in order: {lo[20:0], hi[20:0], width[1:0], glyph[9:0]}
    reg [53:0] utab [0:255];
    initial $readmemh("term_uni.hex", utab);
    reg [53:0] uq = 54'd0;
    reg [7:0]  uidx = 8'd0;
    always @(posedge clk)
        uq <= utab[uidx];

    integer i;
    initial begin
        for (i = 0; i < 28; i = i + 1) begin
            map[i] = i;
            smap[i] = i;
        end
        for (i = 0; i < 2; i = i + 1) begin
            sv_cx[i] = 7'd0; sv_cy[i] = 5'd0; sv_fg[i] = 8'd7; sv_bg[i] = 8'd0; sv_fl[i] = 6'd0;
        end
        for (i = 0; i < 8; i = i + 1)
            cm_i[i] = 3'd0;
    end

    genvar gi;
    generate
        for (gi = 0; gi < 28; gi = gi + 1) begin : flat
            assign map_flat[5*gi +: 5] = map[gi];
        end
    endgenerate

    // ---------------------------------------------------------------- helpers
    function [12:0] addr_of;                // physical row, column -> cell address
        input [5:0] phys;
        input [6:0] col;
        addr_of = {1'b0, phys, 6'd0} + {3'd0, phys, 4'd0} + {6'd0, col};
    endfunction

    // truecolour -> 256-colour index (see term_font.rgb256), one channel per parameter: the
    // cube index so far, the brightest and darkest channel, and r + 2g + b for greys
    function [2:0] cube_step;
        input [7:0] c;
        cube_step = (c < 8'd48) ? 3'd0 : (c < 8'd115) ? 3'd1 : (c < 8'd155) ? 3'd2 : (c < 8'd195) ? 3'd3 :
                    (c < 8'd235) ? 3'd4 : 3'd5;
    endfunction

    function [7:0] hexch;
        input [3:0] n;
        hexch = (n < 4'd10) ? 8'h30 + n : 8'h57 + n;
    endfunction

    wire [7:0]  pen_f0 = (fl[0] && fg < 8'd8) ? fg + 8'd8 : fg;
    wire [7:0]  pen_b = inv ? pen_f0 : bg;
    wire [7:0]  pen_f = con ? pen_b : (inv ? bg : pen_f0);
    wire [31:0] blank = {6'd0, bg, 8'd7, 10'h020};
    wire [9:0]  put_glyph = put_g;

    // the first two parameters, including the one still being typed
    wire [11:0] p0 = (np == 4'd0) ? cur : prm0;
    wire [11:0] p1 = (np == 4'd1) ? cur : (np == 4'd0) ? 12'd0 : prm1;
    wire [11:0] n0 = (p0 == 12'd0) ? 12'd1 : p0;
    wire [11:0] n1 = (p1 == 12'd0) ? 12'd1 : p1;
    wire [15:0] acc10 = {1'b0, cur, 3'd0} + {3'd0, cur, 1'b0} + {12'd0, b[3:0]};
    wire [11:0] acc_sat = (acc10[15:12] != 4'd0) ? 12'd4095 : acc10[11:0];
    // counts and positions never need more than 127
    wire [6:0]  n0c = (p0 == 12'd0) ? 7'd1 : (p0[11:7] != 5'd0) ? 7'd127 : p0[6:0];
    wire [6:0]  n1c = (p1 == 12'd0) ? 7'd1 : (p1[11:7] != 5'd0) ? 7'd127 : p1[6:0];

    // cursor movement targets
    wire [4:0]  cuu_lim = (cy >= top) ? top : 5'd0;
    wire [4:0]  cuu_new = (n0c > {2'd0, cy - cuu_lim}) ? cuu_lim : cy - n0c[4:0];
    wire [4:0]  cud_lim = (cy <= bot) ? bot : 5'd27;
    wire [4:0]  cud_new = (n0c > {2'd0, cud_lim - cy}) ? cud_lim : cy + n0c[4:0];
    wire [6:0]  cuf_new = (n0c > 7'd79 - cx) ? 7'd79 : cx + n0c;
    wire [6:0]  cub_new = (n0c > cx) ? 7'd0 : cx - n0c;
    wire [6:0]  cha_new = (n0c > 7'd80) ? 7'd79 : n0c - 1'b1;
    wire [6:0]  col1_new = (n1c > 7'd80) ? 7'd79 : n1c - 1'b1;
    wire [4:0]  row_new = (n0c > 7'd28) ? 5'd27 : n0c[4:0] - 1'b1;
    wire [3:0]  ntab = (n0c > 7'd10) ? 4'd10 : n0c[3:0];
    wire [4:0]  cht_stop = {1'b0, cx[6:3]} + {1'b0, ntab};
    wire [6:0]  cht_new = (cht_stop >= 5'd10) ? 7'd79 : {cht_stop[3:0], 3'd0};
    wire [4:0]  cbt_up = {1'b0, cx[6:3]} + (cx[2:0] != 3'd0);
    wire [6:0]  cbt_new = ({1'b0, ntab} >= cbt_up) ? 7'd0 : {cbt_up[3:0] - ntab, 3'd0};
    wire [6:0]  tab_next = (cx[6:3] >= 4'd9) ? 7'd79 : {cx[6:3] + 1'b1, 3'd0};
    wire [6:0]  room = 7'd80 - cx;                                  // cells from the cursor to the end
    wire [6:0]  kch = (n0c > room) ? room : n0c;                     // ICH/DCH/ECH count
    wire [4:0]  il_room = bot - cy + 1'b1;
    wire [4:0]  kil = (n0c > {2'd0, il_room}) ? il_room : n0c[4:0];
    wire [4:0]  su_room = bot - top + 1'b1;
    wire [4:0]  ksu = (n0c > {2'd0, su_room}) ? su_room : n0c[4:0];
    wire [6:0]  stbm_t = n0c - 1'b1;
    wire [4:0]  stbm_b = ((p1 == 12'd0 || n1c > 7'd28) ? 5'd28 : n1c[4:0]) - 1'b1;

    // one row map lookup and one address adder serve every state: the writes, the reads for
    // shifting characters and for the checksum, and the scroll rotation
    wire [6:0]  sh_src = sh_ins ? sh_dst - sh_k : sh_dst + sh_k;
    reg  [4:0]  m_row;
    reg  [6:0]  m_col;
    always @* begin
        m_row = cy;
        m_col = cx;
        case (state)
            S_PUT_W2: m_col = cx + 1'b1;
            S_FILL:   begin m_row = f_row; m_col = f_col; end
            S_SH_RD:  m_col = sh_src;
            S_SH_WR:  m_col = sh_dst;
            S_SUM_RD: begin m_row = sum_row; m_col = sum_col; end
            S_EV_RD:  begin m_row = ev_row; m_col = ev_col; end             // the line typed at the shell
            S_SCROLL: m_row = s_up ? s_top : s_bot;                       // the row that wraps around
            S_BYTE:   m_col = TITLE_COL + tlen;                           // an OSC title character
            default: ;
        endcase
    end
    wire [4:0]  m_map = map[m_row];
    wire        m_title = (state == S_BYTE) || (state == S_FILL && f_title);
    wire [12:0] m_addr = addr_of(m_title ? 6'd60 : {bank, m_map}, m_col);
    assign r_addr = m_addr;
    assign in_rd = ce && (state == S_IDLE) && !in_empty && say_ph == 4'd0 && !want_shell;
    assign idle = (state == S_IDLE);

    wire [7:0]  b = src_say ? say_q : bq;
    wire        b_c0 = (b[7:5] == 3'd0);                                  // 0x00-0x1F
    wire        b_inter = (b[7:4] == 4'h2);                               // 0x20-0x2F
    wire        b_digit = (b[7:4] == 4'h3) && (b[3:0] < 4'd10);
    wire        b_final = (b[7:6] == 2'b01) && (b != 8'h7F);              // 0x40-0x7E
    wire        b_print = !b[7] && !b_c0 && (b != 8'h7F);                 // 0x20-0x7E
    wire [11:0] v = prm[pi[3:0]];
    wire [7:0]  vc = (v[11:8] != 4'd0) ? 8'd255 : v[7:0];
    wire [20:0] u_lo = uq[53:33], u_hi = uq[32:12];
    wire [2:0]  q_v = cube_step(vc);
    wire [7:0]  tc_cube6 = {tc_cube, 2'd0} + {1'b0, tc_cube, 1'b0};
    wire [7:0]  truecolour = 8'd16 + tc_cube6 + {5'd0, q_v};

    // the scroll rotation as masks over the 28 rows
    wire [27:0] ge_top = {28{1'b1}} << s_top;
    wire [27:0] le_bot = {28{1'b1}} >> (5'd27 - s_bot);
    wire [27:0] eq_top = 28'd1 << s_top;
    wire [27:0] eq_bot = 28'd1 << s_bot;
    wire [27:0] up_next = ge_top & le_bot & ~eq_bot;                      // top <= i < bot
    wire [27:0] dn_prev = ge_top & le_bot & ~eq_top;                      // top < i <= bot
    wire [7:0]  rowdec = bcd({2'd0, cy} + 7'd1);
    wire [7:0]  coldec = bcd(cx + 7'd1);
    assign ln_bcd = rowdec;
    assign col_bcd = coldec;

    // the shell: the character being read, and the commands typed (complete)
    wire [9:0]  eg = rq[9:0];
    wire        e_blank = (eg == 10'h000) || (eg == 10'h020);
    wire        e_hexd = (eg[9:4] == 6'h03 && eg[3:0] < 4'd10) ||
                         ((eg[9:4] == 6'h04 || eg[9:4] == 6'h06) && eg[3:0] != 4'd0 && eg[3:0] < 4'd7);
    wire [3:0]  e_nib = eg[6] ? eg[3:0] + 4'd9 : eg[3:0];
    wire [7:0]  hit;                        // help clear theme crt key iv enc dec
    generate
        for (gi = 0; gi < 8; gi = gi + 1) begin : hits
            assign hit[gi] = word_on && cm_ok[gi] && cm_i[gi] == cmd_len(gi);
        end
    endgenerate

    // ---------------------------------------------------------------- small jobs
    task index_down;                        // LF: move down, scrolling at the bottom margin
        input [4:0] ret;
        begin
            if (cy == bot) begin
                s_up <= 1'b1; s_top <= top; s_bot <= bot; s_cnt <= 5'd1; scr_ret <= ret; state <= S_SCROLL;
                if (local && !src_say && prow != 5'd0) prow <= prow - 1'b1;     // the line being typed
            end else if (cy != 5'd27)
                cy <= cy + 1'b1;
        end
    endtask

    task index_up;                          // RI: move up, scrolling at the top margin
        begin
            if (cy == top) begin
                s_up <= 1'b0; s_top <= top; s_bot <= bot; s_cnt <= 5'd1; scr_ret <= S_IDLE; state <= S_SCROLL;
            end else if (cy != 5'd0)
                cy <= cy - 1'b1;
        end
    endtask

    task scroll;
        input up;
        input [4:0] t, bt, n;
        begin
            s_up <= up; s_top <= t; s_bot <= bt; s_cnt <= n; scr_ret <= S_IDLE; state <= S_SCROLL;
        end
    endtask

    task fill;                              // blank (r0, c0) .. (r1, c1) in reading order
        input [4:0] r0;
        input [6:0] c0;
        input [4:0] r1;
        input [6:0] c1;
        input [31:0] wv;
        input [4:0] ret;
        begin
            f_row <= r0; f_col <= c0; f_erow <= r1; f_ecol <= c1; f_word <= wv; f_title <= 1'b0;
            fill_ret <= ret; state <= S_FILL;
        end
    endtask

    task shift;                             // ICH (ins) or DCH at the cursor
        input ins;
        input [6:0] k;
        input [4:0] ret;
        begin
            sh_ins <= ins; sh_k <= k; sh_dst <= ins ? 7'd79 : cx; shift_ret <= ret; state <= S_SH_RD;
        end
    endtask

    task control;                           // C0 control characters
        input [7:0] c;
        begin
            case (c)
                8'h07: bell <= 1'b1;
                8'h08: begin wrap <= 1'b0; if (cx != 7'd0) cx <= cx - 1'b1; end
                8'h09: begin wrap <= 1'b0; cx <= tab_next; end
                8'h0A, 8'h0B, 8'h0C: begin wrap <= 1'b0; if (lnm) cx <= 7'd0; index_down(S_IDLE); end
                8'h0D: begin wrap <= 1'b0; cx <= 7'd0; end
                8'h0E: gl <= 1'b1;
                8'h0F: gl <= 1'b0;
                default: ;
            endcase
        end
    endtask

    task save_cursor;
        input slot;
        begin
            sv_cx[slot] <= cx; sv_cy[slot] <= cy; sv_fg[slot] <= fg; sv_bg[slot] <= bg; sv_fl[slot] <= fl;
            sv_inv[slot] <= inv; sv_con[slot] <= con; sv_g0[slot] <= g0; sv_g1[slot] <= g1; sv_gl[slot] <= gl;
        end
    endtask

    task restore_cursor;
        input slot;
        begin
            cx <= sv_cx[slot]; cy <= sv_cy[slot]; fg <= sv_fg[slot]; bg <= sv_bg[slot]; fl <= sv_fl[slot];
            inv <= sv_inv[slot]; con <= sv_con[slot]; g0 <= sv_g0[slot]; g1 <= sv_g1[slot]; gl <= sv_gl[slot];
            wrap <= 1'b0;
        end
    endtask

    task default_cursor;
        input slot;
        begin
            sv_cx[slot] <= 7'd0; sv_cy[slot] <= 5'd0; sv_fg[slot] <= 8'd7; sv_bg[slot] <= 8'd0; sv_fl[slot] <= 6'd0;
            sv_inv[slot] <= 1'b0; sv_con[slot] <= 1'b0; sv_g0[slot] <= 1'b0; sv_g1[slot] <= 1'b0; sv_gl[slot] <= 1'b0;
        end
    endtask

    task rubout;                            // DEL, or Backspace at the shell
        begin
            if (wrap) begin
                wrap <= 1'b0;
                fill(cy, cx, cy, cx, blank, S_IDLE);
            end else if (cx != 7'd0) begin
                cx <= cx - 1'b1;
                fill(cy, cx - 1'b1, cy, cx - 1'b1, blank, S_IDLE);
            end
        end
    endtask

    task sgr_reset;
        begin
            fg <= 8'd7; bg <= 8'd0; fl <= 6'd0; inv <= 1'b0; con <= 1'b0;
        end
    endtask

    task reply;                             // send a report
        input [2:0] kind;                   // 1 DA, 2 status OK, 3 cursor position, 4 checksum
        begin
            rkind <= kind;
            ridx <= 5'd0;
            state <= S_REPLY;
        end
    endtask

    // the reports, a byte at a time (0 = skip): the engine waits while they are sent, so the
    // cursor and checksum they contain cannot change underneath
    wire [7:0] row_t = (rowdec[7:4] == 4'd0) ? 8'd0 : {4'h3, rowdec[7:4]};
    wire [7:0] col_t = (coldec[7:4] == 4'd0) ? 8'd0 : {4'h3, coldec[7:4]};
    wire [3:0] nib = sum[4 * (5'd20 - ridx) +: 4];
    reg  [7:0] rbyte;
    always @* begin
        rbyte = 8'd0;
        if (ridx == 5'd0)      rbyte = 8'h1B;
        else if (ridx == 5'd1) rbyte = "[";
        else case (rkind)
            3'd1: case (ridx)                                   // ESC [ ? 1 ; 2 c
                      5'd2: rbyte = "?"; 5'd3: rbyte = "1"; 5'd4: rbyte = ";"; 5'd5: rbyte = "2"; 5'd6: rbyte = "c";
                      default: ;
                  endcase
            3'd2: case (ridx)                                   // ESC [ 0 n
                      5'd2: rbyte = "0"; 5'd3: rbyte = "n";
                      default: ;
                  endcase
            3'd3: case (ridx)                                   // ESC [ row ; col R
                      5'd2: rbyte = row_t; 5'd3: rbyte = {4'h3, rowdec[3:0]}; 5'd4: rbyte = ";";
                      5'd5: rbyte = col_t; 5'd6: rbyte = {4'h3, coldec[3:0]}; 5'd7: rbyte = "R";
                      default: ;
                  endcase
            default: case (ridx)                                // ESC [ ? 999 ; row ; col ; sum n
                      5'd2: rbyte = "?"; 5'd3, 5'd4, 5'd5: rbyte = "9"; 5'd6, 5'd9, 5'd12: rbyte = ";";
                      5'd7: rbyte = row_t; 5'd8: rbyte = {4'h3, rowdec[3:0]};
                      5'd10: rbyte = col_t; 5'd11: rbyte = {4'h3, coldec[3:0]};
                      5'd13, 5'd14, 5'd15, 5'd16, 5'd17, 5'd18, 5'd19, 5'd20: rbyte = hexch(nib);
                      5'd21: rbyte = "n";
                      default: ;
                  endcase
        endcase
    end

    // ---------------------------------------------------------------- the engine
    always @(posedge clk) if (ce) begin
        w_en_r <= 1'b0;
        bell <= 1'b0;
        tx_start_r <= 1'b0;
        cmd_theme_r <= 1'b0;
        cmd_crt_r <= 1'b0;
        aes_go <= 1'b0;
        aes_we <= 1'b0;
        if (aes_we) ap <= ap + 1'b1;        // each byte written to the AES unit moves ap on
        if (shell_req || shell_req_d) want_shell <= 1'b1;
        case (state)
        S_IDLE:
            if (want_shell) begin
                want_shell <= 1'b0;
                local <= 1'b1;
                pst <= P_GROUND;
                say_out <= 2'd0;
                say_ph <= 4'd1;
            end else if (say_ph != 4'd0)
                state <= S_SAY;
            else if (!in_empty) begin
                src_say <= 1'b0;
                state <= S_BYTE;
            end

        S_BYTE: begin
            state <= S_IDLE;
            if (pst != P_GROUND && pst != P_OSC && pst != P_STR &&
                (b == 8'h1B || b == 8'h18 || b == 8'h1A || (b_c0 && pst != P_OSC_ESC && pst != P_STR_ESC))) begin
                if (b == 8'h1B)                   pst <= P_ESC;
                else if (b == 8'h18 || b == 8'h1A) pst <= P_GROUND;
                else                              control(b);
            end else case (pst)
            P_GROUND:
                if (need != 2'd0 && b[7:6] == 2'b10) begin
                    ucp <= {ucp[14:0], b[5:0]};
                    need <= need - 1'b1;
                    if (need == 2'd1) state <= S_UNI;
                end else begin
                    need <= 2'd0;
                    rep <= 12'd0;
                    put_w <= 1'b0;
                    if (!src_say)
                        last_cr <= (b == 8'h0D);
                    if (local && !src_say && (b == 8'h08 || b == 8'h7F)) begin      // Backspace
                        if (cy != prow || cx > 7'd2) rubout;
                    end else if (local && !src_say && (b == 8'h0D || (b == 8'h0A && !last_cr))) begin
                        ev_row <= (prow > cy) ? cy : prow; ev_col <= 7'd2;          // Enter: run the line
                        cm_ok <= 8'hFF; word_on <= 1'b0; word_end <= 1'b0; nonblank <= 1'b0; args <= 1'b0;
                        a_hex <= 1'b0; a_text <= 1'b0; a_bad <= 1'b0; a_ovf <= 1'b0; a_half <= 1'b0;
                        ap <= 11'd0; a_len <= 11'd0; padded <= 1'b0;
                        for (i = 0; i < 8; i = i + 1)
                            cm_i[i] <= 3'd0;
                        state <= S_EV_RD;
                    end else if (local && !src_say && b == 8'h0A) begin          // (after a CR)
                    end else if (b_c0) begin
                        if (b == 8'h1B) pst <= P_ESC;
                        else control(b);
                    end else if (b_print) begin
                        put_g <= ((gl ? g1 : g0) && (b[6:5] == 2'b11 || b == 8'h5F)) ? dec_glyph(b[4:0] + 5'd1)
                                                                                     : {2'b00, b};
                        state <= S_PUT;
                    end else if (b == 8'h7F) begin                  // DEL: rub out (Backspace, typed)
                        rubout;
                    end else if (b[7:6] == 2'b10 || b[7:3] == 5'b11111) begin
                        put_g <= G_REPLACEMENT;
                        state <= S_PUT;
                    end else if (b[7:5] == 3'b110) begin
                        need <= 2'd1; ucp <= {16'd0, b[4:0]};
                    end else if (b[7:4] == 4'b1110) begin
                        need <= 2'd2; ucp <= {17'd0, b[3:0]};
                    end else begin
                        need <= 2'd3; ucp <= {18'd0, b[2:0]};
                    end
                end
            P_ESC: begin
                pst <= P_GROUND;
                if (local && !src_say && b != "[")
                    local <= 1'b0;                                          // a program is talking
                if (b_inter) begin
                    inter <= b;
                    pst <= P_ESC_INT;
                end else case (b)
                    "[": begin
                        cur <= 12'd0; prm0 <= 12'd0; prm1 <= 12'd0;
                        np <= 4'd0; ovf <= 1'b0; priv <= 8'd0; inter <= 8'd0; fresh <= 1'b1;
                        pst <= P_CSI;
                    end
                    "]": begin osc_num <= 8'd0; osc_phase <= 2'd0; pst <= P_OSC; end
                    "P", "X", "^", "_": pst <= P_STR;
                    "7": save_cursor(bank);
                    "8": restore_cursor(bank);
                    "D": begin wrap <= 1'b0; index_down(S_IDLE); end
                    "E": begin wrap <= 1'b0; cx <= 7'd0; index_down(S_IDLE); end
                    "M": begin wrap <= 1'b0; index_up; end
                    "c": begin                                        // RIS: full reset
                        cx <= 7'd0; cy <= 5'd0; wrap <= 1'b0; sgr_reset;
                        top <= 5'd0; bot <= 5'd27;
                        awm <= 1'b1; irm <= 1'b0; lnm <= 1'b0; tcem <= 1'b1; scnm <= 1'b0;
                        cur_style <= 2'd0; cur_blink <= 1'b1;
                        g0 <= 1'b0; g1 <= 1'b0; gl <= 1'b0;
                        bank <= 1'b0;
                        for (i = 0; i < 28; i = i + 1)
                            map[i] <= i;
                        default_cursor(0);
                        default_cursor(1);
                        last_ok <= 1'b0;
                        need <= 2'd0;
                        title_custom <= 1'b0;
                        fill(5'd0, 7'd0, 5'd27, 7'd79, BLANK0, S_IDLE);
                    end
                    default: ;
                endcase
            end
            P_ESC_INT:
                if (b_inter)
                    inter <= b;
                else if (b_print) begin
                    pst <= P_GROUND;
                    if (inter == "(")       g0 <= (b == "0");
                    else if (inter == ")")  g1 <= (b == "0");
                    else if (inter == "#" && b == "8") begin                 // DECALN
                        top <= 5'd0; bot <= 5'd27; cx <= 7'd0; cy <= 5'd0; wrap <= 1'b0;
                        fill(5'd0, 7'd0, 5'd27, 7'd79, {6'd0, 8'd0, 8'd7, 10'h045}, S_IDLE);
                    end
                end
            P_CSI: begin
                fresh <= 1'b0;
                if (b_digit) begin
                    if (!ovf) cur <= acc_sat;
                end else if (b == ":" || b == ";") begin
                    if (np != 4'd15) begin
                        prm[np] <= cur;
                        if (np == 4'd0) prm0 <= cur;
                        if (np == 4'd1) prm1 <= cur;
                        np <= np + 1'b1;
                        cur <= 12'd0;
                    end else
                        ovf <= 1'b1;
                end else if (b[7:2] == 6'b001111) begin                       // < = > ?
                    if (fresh) priv <= b;
                    else pst <= P_CSI_IGN;
                end else if (b_inter) begin
                    inter <= b;
                end else if (b_final) begin
                    pst <= P_GROUND;
                    prm[np] <= cur;                                             // the last parameter
                    if (!src_say)
                        local <= 1'b0;
                    if (local && !src_say && inter == 8'd0 && priv == 8'd0 &&
                        (b == "A" || b == "B" || b == "C" || b == "D" || b == "~")) begin
                        local <= 1'b1;                                          // a key typed at the shell
                    end else if (inter != 8'd0) begin
                        if (inter == " " && b == "q" && priv == 8'd0 && p0 <= 12'd6) begin   // DECSCUSR
                            cur_style <= (p0 <= 12'd2) ? 2'd0 : (p0 <= 12'd4) ? 2'd1 : 2'd2;
                            cur_blink <= (p0 == 12'd0 || p0[0]);
                        end else if (inter == "!" && b == "p") begin                     // DECSTR
                            tcem <= 1'b1; irm <= 1'b0; awm <= 1'b1;
                            top <= 5'd0; bot <= 5'd27;
                            sgr_reset;
                            g0 <= 1'b0; g1 <= 1'b0; gl <= 1'b0;
                            default_cursor(bank);
                            wrap <= 1'b0;
                        end
                    end else if (priv == "?") begin
                        if (b == "h" || b == "l") begin
                            pi <= 5'd0; set_on <= (b == "h"); state <= S_DECSET;
                        end
                    end else if (priv == 8'd0) begin
                        case (b)
                            "@", "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "P",
                            "S", "T", "X", "Z", 8'h60, "a", "d", "e", "f", "r", "u": wrap <= 1'b0;
                            default: ;
                        endcase
                        case (b)
                            "@": shift(1'b1, kch, S_IDLE);
                            "A": cy <= cuu_new;
                            "B", "e": cy <= cud_new;
                            "C", "a": cx <= cuf_new;
                            "D": cx <= cub_new;
                            "E": begin cy <= cud_new; cx <= 7'd0; end
                            "F": begin cy <= cuu_new; cx <= 7'd0; end
                            "G", 8'h60: cx <= cha_new;
                            "H", "f": begin cy <= row_new; cx <= col1_new; end
                            "I": cx <= cht_new;
                            "Z": cx <= cbt_new;
                            "J": case (p0)
                                     12'd0: fill(cy, cx, 5'd27, 7'd79, blank, S_IDLE);
                                     12'd1: fill(5'd0, 7'd0, cy, cx, blank, S_IDLE);
                                     12'd2, 12'd3: fill(5'd0, 7'd0, 5'd27, 7'd79, blank, S_IDLE);
                                     default: ;
                                 endcase
                            "K": case (p0)
                                     12'd0: fill(cy, cx, cy, 7'd79, blank, S_IDLE);
                                     12'd1: fill(cy, 7'd0, cy, cx, blank, S_IDLE);
                                     12'd2: fill(cy, 7'd0, cy, 7'd79, blank, S_IDLE);
                                     default: ;
                                 endcase
                            "L", "M":
                                if (cy >= top && cy <= bot) begin
                                    scroll(b == "M", cy, bot, kil);
                                    cx <= 7'd0;
                                end
                            "P": shift(1'b0, kch, S_IDLE);
                            "S": scroll(1'b1, top, bot, ksu);
                            "T": if (np == 4'd0) scroll(1'b0, top, bot, ksu);
                            "X": fill(cy, cx, cy, cx + kch - 1'b1, blank, S_IDLE);
                            "b": if (last_ok) begin
                                     put_g <= last_g; put_w <= last_w; rep <= n0 - 1'b1; state <= S_PUT;
                                 end
                            "c": if (p0 == 12'd0) reply(3'd1);
                            "d": cy <= row_new;
                            "h", "l": begin pi <= 5'd0; set_on <= (b == "h"); state <= S_SM; end
                            "m": begin pi <= 5'd0; sgr_mode <= 4'd0; state <= S_SGR; end
                            "n": if (p0 == 12'd5) reply(3'd2);
                                 else if (p0 == 12'd6) reply(3'd3);
                                 else if (p0 == 12'd999 || p0 == 12'd998) begin
                                     sum <= 32'd0; sum_row <= 5'd0; sum_col <= 7'd0; state <= S_SUM_RD;
                                     dumping <= !p0[0];
                                 end
                            "r": if (stbm_t < {2'd0, stbm_b}) begin
                                     top <= stbm_t[4:0]; bot <= stbm_b; cx <= 7'd0; cy <= 5'd0;
                                 end
                            "s": if (np == 4'd0) save_cursor(bank);
                            "u": restore_cursor(bank);
                            default: ;
                        endcase
                    end
                end
            end
            P_CSI_IGN:
                if (b_final) pst <= P_GROUND;
            P_OSC:
                if (b == 8'h07 || b == 8'h18 || b == 8'h1A)
                    pst <= P_GROUND;
                else if (b == 8'h1B)
                    pst <= P_OSC_ESC;
                else if (osc_phase == 2'd0) begin
                    if (b_digit)
                        osc_num <= ({1'b0, osc_num} * 4'd10 + b[3:0] > 12'd255) ? 8'd255 : osc_num * 4'd10 + b[3:0];
                    else if (b == ";" && (osc_num == 8'd0 || osc_num == 8'd2)) begin
                        title_custom <= 1'b1;
                        tlen <= 6'd0;
                        osc_phase <= 2'd1;
                        fill(5'd0, TITLE_COL, 5'd0, TITLE_COL + TITLE_LEN - 1, TITLE_WORD | 32'h020, S_IDLE);
                        f_title <= 1'b1;
                    end else
                        osc_phase <= 2'd2;
                end else if (osc_phase == 2'd1 && b_print && tlen < TITLE_LEN) begin
                    w_en_r <= 1'b1;
                    w_addr <= m_addr;
                    w_data <= TITLE_WORD | {24'd0, b};
                    tlen <= tlen + 1'b1;
                end
            P_STR:
                if (b == 8'h07 || b == 8'h18 || b == 8'h1A) pst <= P_GROUND;
                else if (b == 8'h1B) pst <= P_STR_ESC;
            default:                                                          // OSC_ESC, STR_ESC
                pst <= P_GROUND;
            endcase
        end

        S_UNI: begin                        // a complete UTF-8 character: Latin-1, boxes, blocks, braille
            put_w <= 1'b0;
            state <= S_PUT;
            if (ucp[20:8] == 13'd0) begin
                if (ucp[7:5] == 3'd0 || ucp[7:0] == 8'h7F || ucp[7:5] == 3'b100)   // controls: nothing shown
                    state <= S_IDLE;
                put_g <= {2'b00, ucp[7:0]};
            end else if (ucp[20:7] == 14'h4A)  put_g <= {3'b010, ucp[6:0]};
            else if (ucp[20:5] == 16'h12C)     put_g <= {5'b01100, ucp[4:0]};
            else if (ucp[20:8] == 13'h28)      put_g <= {2'b10, ucp[7:0]};
            else begin
                uidx <= 8'd0;
                state <= S_USCAN;
            end
        end

        S_USCAN:                            // wait for table entry uidx
            state <= S_UCMP;

        S_UCMP:
            if (ucp >= u_lo && ucp <= u_hi) begin
                put_g <= uq[9:0];
                put_w <= (uq[11:10] == 2'd2);
                state <= (uq[11:10] == 2'd0) ? S_IDLE : S_PUT;
            end else if (ucp < u_lo) begin  // not in the table
                put_g <= G_REPLACEMENT;
                put_w <= 1'b0;
                state <= S_PUT;
            end else begin
                uidx <= uidx + 1'b1;
                state <= S_USCAN;
            end

        S_PUT:
            if (wrap) begin                 // autowrap: go to the next line first
                wrap <= 1'b0;
                cx <= 7'd0;
                index_down(S_PUT);
            end else if (put_w && cx == 7'd79) begin
                if (!awm) state <= S_IDLE;
                else begin cx <= 7'd0; index_down(S_PUT); end
            end else if (irm)
                shift(1'b1, put_w ? ((room < 7'd2) ? room : 7'd2) : 7'd1, S_PUT_W);
            else
                state <= S_PUT_W;

        S_PUT_W: begin
            w_en_r <= 1'b1;
            w_addr <= m_addr;
            w_data <= {fl, pen_b, pen_f, put_glyph};
            last_g <= put_g; last_w <= put_w; last_ok <= 1'b1;
            if (put_w)
                state <= S_PUT_W2;
            else begin
                if (cx != 7'd79) cx <= cx + 1'b1;
                else wrap <= awm;
                if (rep != 12'd0) begin rep <= rep - 1'b1; state <= S_PUT; end
                else state <= S_IDLE;
            end
        end

        S_PUT_W2: begin                     // right half of a double-width character
            w_en_r <= 1'b1;
            w_addr <= m_addr;
            w_data <= {fl, pen_b, pen_f, G_WIDE_R[9:0]};
            if (cx < 7'd78) cx <= cx + 2'd2;
            else begin cx <= 7'd79; wrap <= awm; end
            if (rep != 12'd0) begin rep <= rep - 1'b1; state <= S_PUT; end
            else state <= S_IDLE;
        end

        S_SCROLL:
            if (s_cnt == 5'd0)
                state <= scr_ret;
            else begin
                for (i = 0; i < 28; i = i + 1) begin
                    if (s_up) begin
                        if (i < 27 && up_next[i])  map[i] <= map[(i < 27) ? i + 1 : i];
                        else if (eq_bot[i])        map[i] <= m_map;
                    end else begin
                        if (i > 0 && dn_prev[i])   map[i] <= map[(i > 0) ? i - 1 : i];
                        else if (eq_top[i])        map[i] <= m_map;
                    end
                end
                s_cnt <= s_cnt - 1'b1;
                fill(s_up ? s_bot : s_top, 7'd0, s_up ? s_bot : s_top, 7'd79, blank, S_SCROLL);
            end

        S_FILL: begin
            w_en_r <= 1'b1;
            w_addr <= m_addr;
            w_data <= f_word;
            if (f_row == f_erow && f_col == f_ecol)
                state <= fill_ret;
            else if (f_col == 7'd79) begin
                f_col <= 7'd0;
                f_row <= f_row + 1'b1;
            end else
                f_col <= f_col + 1'b1;
        end

        S_SH_RD:                            // copy one cell sideways, then blank the gap
            if (sh_ins ? (sh_dst < cx + sh_k || sh_dst > 7'd79) : ({1'b0, sh_dst} + sh_k > 8'd79))
                fill(cy, sh_ins ? cx : 7'd80 - sh_k, cy, sh_ins ? cx + sh_k - 1'b1 : 7'd79, blank, shift_ret);
            else if (r_ok)
                state <= S_SH_WR;

        S_SH_WR: begin
            w_en_r <= 1'b1;
            w_addr <= m_addr;
            w_data <= rq;
            sh_dst <= sh_ins ? sh_dst - 1'b1 : sh_dst + 1'b1;
            state <= S_SH_RD;
        end

        S_SGR:
            if (pi > {1'b0, np})
                state <= S_IDLE;
            else begin
                pi <= pi + 1'b1;
                case (sgr_mode)
                    4'd0:
                        case (v)
                            12'd0: sgr_reset;
                            12'd1: fl[0] <= 1'b1;
                            12'd2: fl[1] <= 1'b1;
                            12'd3: fl[2] <= 1'b1;
                            12'd4, 12'd21: fl[3] <= 1'b1;
                            12'd5, 12'd6: fl[4] <= 1'b1;
                            12'd7: inv <= 1'b1;
                            12'd8: con <= 1'b1;
                            12'd9: fl[5] <= 1'b1;
                            12'd22: fl[1:0] <= 2'b00;
                            12'd23: fl[2] <= 1'b0;
                            12'd24: fl[3] <= 1'b0;
                            12'd25: fl[4] <= 1'b0;
                            12'd27: inv <= 1'b0;
                            12'd28: con <= 1'b0;
                            12'd29: fl[5] <= 1'b0;
                            12'd30, 12'd31, 12'd32, 12'd33, 12'd34, 12'd35, 12'd36, 12'd37:
                                fg <= {5'd0, v[2:0] + 3'd2};                  // 30-37
                            12'd38: sgr_mode <= 4'd1;
                            12'd39: fg <= 8'd7;
                            12'd40, 12'd41, 12'd42, 12'd43, 12'd44, 12'd45, 12'd46, 12'd47:
                                bg <= {5'd0, v[2:0]};                         // 40-47
                            12'd48: sgr_mode <= 4'd2;
                            12'd49: bg <= 8'd0;
                            12'd90, 12'd91, 12'd92, 12'd93, 12'd94, 12'd95, 12'd96, 12'd97:
                                fg <= {5'd1, v[2:0] + 3'd6};                  // 90-97 -> 8-15
                            12'd100, 12'd101, 12'd102, 12'd103, 12'd104, 12'd105, 12'd106, 12'd107:
                                bg <= {5'd1, v[2:0] + 3'd4};                  // 100-107 -> 8-15
                            default: ;
                        endcase
                    4'd1, 4'd2: sgr_mode <= (v == 12'd5) ? sgr_mode + 4'd2 : (v == 12'd2) ? (sgr_mode == 4'd1 ? 4'd5 : 4'd8) : 4'd0;
                    4'd3: begin fg <= vc; sgr_mode <= 4'd0; end
                    4'd4: begin bg <= vc; sgr_mode <= 4'd0; end
                    4'd5, 4'd8: begin                               // red
                        tc_cube <= {3'd0, q_v};
                        sgr_mode <= sgr_mode + 1'b1;
                    end
                    4'd6, 4'd9: begin                               // green
                        tc_cube <= tc_cube6[5:0] + {3'd0, q_v};
                        sgr_mode <= sgr_mode + 1'b1;
                    end
                    4'd7: begin fg <= truecolour; sgr_mode <= 4'd0; end                   // blue
                    4'd10: begin bg <= truecolour; sgr_mode <= 4'd0; end
                    default: sgr_mode <= 4'd0;
                endcase
            end

        S_DECSET:
            if (pi > {1'b0, np})
                state <= S_IDLE;
            else begin
                pi <= pi + 1'b1;
                case (v)
                    12'd5:  scnm <= set_on;
                    12'd7:  begin awm <= set_on; if (!set_on) wrap <= 1'b0; end
                    12'd12: cur_blink <= set_on;
                    12'd25: tcem <= set_on;
                    12'd1048: if (set_on) save_cursor(bank); else restore_cursor(bank);
                    12'd2112: begin                                     // the built-in shell
                        local <= set_on;
                        if (set_on) begin say_out <= 2'd0; say_ph <= 4'd1; end
                    end
                    12'd47, 12'd1047, 12'd1049:
                        if (set_on && !bank) begin
                            if (v == 12'd1049) save_cursor(1'b0);
                            for (i = 0; i < 28; i = i + 1) begin
                                smap[i] <= map[i];
                                map[i] <= i;
                            end
                            bank <= 1'b1;
                            fill(5'd0, 7'd0, 5'd27, 7'd79, blank, S_DECSET);
                        end else if (!set_on && bank) begin
                            for (i = 0; i < 28; i = i + 1)
                                map[i] <= smap[i];
                            bank <= 1'b0;
                            if (v == 12'd1049) restore_cursor(1'b0);
                        end
                    default: ;
                endcase
            end

        S_SM:
            if (pi > {1'b0, np})
                state <= S_IDLE;
            else begin
                pi <= pi + 1'b1;
                if (v == 12'd4) irm <= set_on;
                else if (v == 12'd20) lnm <= set_on;
            end

        S_SUM_RD:                           // checksum of the screen, for tests: CSI 999 n (or 998 n)
            if (r_ok)
                state <= S_SUM_ACC;

        S_SUM_ACC:
            if (dumping && (tx_busy || tx_start_r))
                state <= S_SUM_RD;                          // the transmitter is busy: read the cell again
            else begin
                if (dumping) begin
                    tx_start_r <= 1'b1;
                    tx_data <= rq[7:0];
                end
                sum <= {sum[30:0], sum[31]} ^ rq;          // rotate left, then XOR
                if (sum_col != 7'd79) begin
                    sum_col <= sum_col + 1'b1;
                    state <= S_SUM_RD;
                end else if (sum_row != 5'd27) begin
                    sum_col <= 7'd0;
                    sum_row <= sum_row + 1'b1;
                    state <= S_SUM_RD;
                end else
                    state <= S_SUM_DONE;
            end

        S_SUM_DONE:                         // sum is final: send it
            reply(3'd4);

        S_EV_RD:                            // the shell: read the line typed, a character at a time
            if (ev_col == 7'd80) begin
                if (ev_row == cy) state <= S_EV_END;
                else begin ev_row <= ev_row + 1'b1; ev_col <= 7'd0; end
            end else if (r_ok)
                state <= S_EV;

        S_EV: begin
            ev_col <= ev_col + 1'b1;
            state <= S_EV_RD;
            if (word_end) begin                                             // the argument
                if (!e_blank) args <= 1'b1;
                if (a_text) begin
                    if (ap == 11'h6FF) a_ovf <= 1'b1;                       // it must fit in 112 blocks, padded
                    else begin
                        aes_we <= 1'b1; aes_wd <= eg[7:0];
                        if (!e_blank) a_len <= ap + 1'b1;                    // (trailing blanks are not typed)
                    end
                end else if (a_hex && !e_blank) begin
                    if (!e_hexd) a_bad <= 1'b1;
                    else if (a_half) begin aes_we <= 1'b1; aes_wd <= {a_hi, e_nib}; a_half <= 1'b0; end
                    else begin a_hi <= e_nib; a_half <= 1'b1; end
                end
            end else if (e_blank) begin
                if (word_on) begin                                          // the command word is over
                    word_end <= 1'b1;
                    a_hex <= hit[4] | hit[5] | hit[7];
                    a_text <= hit[6];
                end
            end else begin
                nonblank <= 1'b1;
                word_on <= 1'b1;
                for (i = 0; i < 8; i = i + 1)
                    if (cm_i[i] >= cmd_len(i) || eg != {2'b00, cmd_char(i, cm_i[i])})
                        cm_ok[i] <= 1'b0;
                    else
                        cm_i[i] <= cm_i[i] + 1'b1;
            end
        end

        S_EV_END: begin                     // the whole line read: which command, and is its argument right?
            state <= S_IDLE;
            say_out <= 2'd0;
            say_ph <= 4'd1;                                                 // (just a new prompt)
            if (!nonblank)
                ;
            else if (hit[0] && !args) begin say_ptr <= SAY_HELP; say_ph <= 4'd10; end
            else if (hit[1] && !args) begin say_ptr <= SAY_CLEAR; say_ph <= 4'd10; end
            else if (hit[2] && !args) cmd_theme_r <= 1'b1;
            else if (hit[3] && !args) cmd_crt_r <= 1'b1;
            else if (hit[4] || hit[5]) begin                                // key, iv: 16 bytes
                if (a_bad || a_half || ap != 11'd16) begin say_ptr <= SAY_KEYLEN; say_ph <= 4'd10; end
                else begin aes_op <= hit[4] ? 3'd1 : 3'd2; aph <= 2'd1; state <= S_AES; end
            end else if (hit[6]) begin                                      // enc: pad the text
                if (a_ovf) begin say_ptr <= SAY_LONG; say_ph <= 4'd10; end
                else begin ap <= a_len; pv <= 8'd16 - a_len[3:0]; aes_op <= 3'd3; aph <= 2'd0; state <= S_AES; end
            end else if (hit[7]) begin                                      // dec: whole blocks
                if (a_bad || a_half || ap == 11'd0 || ap[3:0] != 4'd0) begin say_ptr <= SAY_DECLEN; say_ph <= 4'd10; end
                else begin aes_op <= 3'd4; aph <= 2'd1; state <= S_AES; end
            end else begin say_ptr <= SAY_UNKNOWN; say_ph <= 4'd10; end
        end

        S_AES:                              // pad (enc), run the AES unit, then print what it made
            case (aph)
                2'd0:                                                       // PKCS#7: pv bytes of pv
                    if (padded && ap[3:0] == 4'd0) aph <= 2'd1;
                    else begin aes_we <= 1'b1; aes_wd <= pv; padded <= 1'b1; aph <= 2'd3; end
                2'd3: aph <= 2'd0;                                          // (ap moves on)
                2'd1: begin aes_go <= 1'b1; aph <= 2'd2; end
                default:
                    if (!aes_busy) begin
                        state <= S_IDLE;
                        if (aes_op == 3'd3) begin dlen <= ap; ap <= 11'd0; say_out <= 2'd1; end
                        if (aes_op == 3'd4) begin                           // check the padding first
                            ap <= {ap[10:4] - 1'b1, 4'hF}; pc_wait <= 1'b1; pc_got <= 1'b0; state <= S_PADCHK;
                        end
                    end
            endcase

        S_PADCHK:                           // dec: the last byte (pv) must be 1-16, and the last pv bytes pv
            if (pc_wait)
                pc_wait <= 1'b0;                                            // (the byte at ap is read)
            else if (!pc_got) begin
                pv <= aes_q; pc_got <= 1'b1;
                if (aes_q == 8'd0 || aes_q > 8'd16) begin say_ptr <= SAY_BADPAD; say_ph <= 4'd10; state <= S_IDLE; end
                else begin ap <= {ap[10:4], 4'd0 - aes_q[3:0]}; pc_wait <= 1'b1; end
            end else if (aes_q != pv) begin
                say_ptr <= SAY_BADPAD; say_ph <= 4'd10; state <= S_IDLE;
            end else if (ap[3:0] == 4'hF) begin                             // good: print the text before it
                dlen <= {ap[10:4], 4'd0 - pv[3:0]}; ap <= 11'd0; say_out <= 2'd2; state <= S_IDLE;
            end else begin
                ap <= ap + 1'b1; pc_wait <= 1'b1;
            end

        S_SAY: begin                        // the shell prints: CR LF [hex or text CR LF] or a string, then $ space
            state <= S_BYTE;
            src_say <= 1'b1;
            case (say_ph)
                4'd1: begin say_q <= 8'h0D; say_ph <= 4'd2; end
                4'd2: begin
                    say_q <= 8'h0A;
                    say_ph <= (say_out == 2'd0) ? 4'd7 : (dlen == 11'd0) ? 4'd5 : (say_out == 2'd1) ? 4'd3 : 4'd4;
                end
                4'd3: begin say_q <= hexch(aes_q[7:4]); say_ph <= 4'd11; end   // the AES unit's bytes in hex
                4'd11: begin
                    say_q <= hexch(aes_q[3:0]); ap <= ap + 1'b1;
                    say_ph <= (ap + 1'b1 == dlen) ? 4'd5 : 4'd3;
                end
                4'd4: begin                                                 // or as text ("." if not printable)
                    say_q <= (aes_q >= 8'h20 && aes_q < 8'h7F) ? aes_q : ".";
                    ap <= ap + 1'b1;
                    say_ph <= (ap + 1'b1 == dlen) ? 4'd5 : 4'd4;
                end
                4'd5: begin say_q <= 8'h0D; say_ph <= 4'd6; end
                4'd6: begin say_q <= 8'h0A; say_ph <= 4'd7; end
                4'd7: begin say_q <= "$"; say_ph <= 4'd8; end
                4'd8: begin say_q <= " "; say_ph <= 4'd9; end
                4'd10:                                                      // a string from term_say.hex
                    if (say_c == 8'd0) begin
                        say_ph <= 4'd7;
                        state <= S_SAY;
                    end else begin
                        say_q <= say_c;
                        say_ptr <= say_ptr + 1'b1;
                    end
                default: begin
                    say_ph <= 4'd0;
                    prow <= cy;
                    src_say <= 1'b0;
                    state <= S_IDLE;
                end
            endcase
        end

        S_REPLY:
            if (ridx == 5'd24)
                state <= S_IDLE;
            else if (rbyte == 8'd0)
                ridx <= ridx + 1'b1;
            else if (!tx_busy && !tx_start_r) begin
                tx_start_r <= 1'b1;
                tx_data <= rbyte;
                ridx <= ridx + 1'b1;
            end

        default:
            state <= S_IDLE;
        endcase
    end
endmodule


// Keeps the title bar and status bar up to date while the engine is idle: each cell comes
// from a template (term_bars.hex) that marks where digits, the activity dot, the theme name
// and the window title go.
module term_bars (
    input  wire        clk,
    input  wire        ok,                  // the write port is free
    input  wire [7:0]  ln,                  // cursor row and column + 1, decimal
    input  wire [7:0]  col,
    input  wire [27:0] baud_bcd,
    input  wire        active,
    input  wire [1:0]  theme,
    input  wire        title_custom,
    output reg         w_en = 1'b0,
    output reg  [12:0] w_addr = 13'd0,
    output reg  [31:0] w_data = 32'd0
);
    localparam T_STATIC = 3'd0, T_TITLE = 3'd1, T_DIGIT = 3'd2, T_DOT = 3'd4, T_THEME = 3'd5;
    reg [31:0] tmpl [0:159];
    initial $readmemh("term_bars.hex", tmpl);
    reg [31:0] t = 32'd0;
    reg [7:0]  k = 8'd0;
    reg        phase = 1'b0;

    // digits by field: Ln, Col, speed (7)
    wire [43:0] digits = {baud_bcd[3:0], baud_bcd[7:4], baud_bcd[11:8], baud_bcd[15:12], baud_bcd[19:16],
                          baud_bcd[23:20], baud_bcd[27:24], col[3:0], col[7:4], ln[3:0], ln[7:4]};
    wire [3:0]  field = t[3:0];
    wire [3:0]  digit = digits[4 * field +: 4];
    // leading zeros: the tens of Ln and Col, and of the speed all but the last digit
    wire [6:0]  bd_lead;
    assign bd_lead[0] = (baud_bcd[27:24] == 4'd0);
    genvar gi;
    generate
        for (gi = 1; gi < 7; gi = gi + 1) begin : lead
            assign bd_lead[gi] = bd_lead[gi - 1] && (baud_bcd[27 - 4 * gi -: 4] == 4'd0);
        end
    endgenerate
    wire blank_digit = (field == 4'd0 && ln[7:4] == 4'd0) || (field == 4'd2 && col[7:4] == 4'd0) ||
                       (field >= 4'd4 && field <= 4'd9 && bd_lead[field - 4'd4]);
    reg  [7:0]  letter;                     // the theme's name: COLOR, GREEN, AMBER
    always @*
        case ({theme, t[2:0]})
            5'b00_000: letter = "C";  5'b00_001: letter = "O";  5'b00_010: letter = "L";
            5'b00_011: letter = "O";  5'b00_100: letter = "R";
            5'b01_000: letter = "G";  5'b01_001: letter = "R";  5'b01_010: letter = "E";
            5'b01_011: letter = "E";  5'b01_100: letter = "N";
            5'b10_000: letter = "A";  5'b10_001: letter = "M";  5'b10_010: letter = "B";
            5'b10_011: letter = "E";  5'b10_100: letter = "R";
            default:   letter = " ";
        endcase
    wire [2:0]  kind = t[31:29];
    reg  [9:0]  g;
    reg  [7:0]  f;
    always @* begin
        g = t[9:0];
        f = t[17:10];
        case (kind)
            T_DIGIT: g = blank_digit ? 10'h020 : {6'd3, digit};
            T_DOT:   f = active ? t[17:10] : 8'd238;
            T_THEME: g = {2'b00, letter};
            default: ;
        endcase
    end

    always @(posedge clk) begin
        t <= tmpl[k];
        w_en <= 1'b0;
        if (!phase)
            phase <= 1'b1;
        else if (ok) begin
            if (!(kind == T_TITLE && title_custom)) begin
                w_en <= 1'b1;
                w_addr <= 13'd4800 + k;
                w_data <= {3'd0, t[28:18], f, g};
            end
            k <= (k == 8'd159) ? 8'd0 : k + 1'b1;
            phase <= 1'b0;
        end
    end
endmodule


// The picture, 6 clocks behind the scan position. Cells are 9 pixels wide: the 9th column is
// blank, except that box drawing and block characters continue into it (as VGA text mode did).
//   0  read the cell (the renderer's turn on the read port, once per 9 pixels)
//   1  cell -> font ROM address; braille dots drawn directly
//   2  font row -> pixel on/off (italic, underline, strike, blink, cursor) -> palette
//   3  colour: dim, bar accent lines, visual bell, green/amber phosphor
//   4  CRT: dimmer odd lines
module term_render (
    input  wire         clk,
    input  wire [9:0]   x,
    input  wire [9:0]   y,
    output wire         slot,               // this clock the renderer reads the screen
    output wire [12:0]  r_addr,
    input  wire [31:0]  r_data,
    input  wire         bank,
    input  wire [139:0] map_flat,
    input  wire [6:0]   cx,
    input  wire [4:0]   cy,
    input  wire         cursor,             // draw the cursor this frame
    input  wire [1:0]   style,
    input  wire         scnm,
    input  wire         blink_off,
    input  wire         bell,
    input  wire [1:0]   theme,
    input  wire         crt,
    output reg  [23:0]  rgb = 24'd0
);
    reg [7:0]  font [0:8191];
    reg [23:0] pal [0:255];
    initial begin
        $readmemh("term_font.hex", font);
        $readmemh("term_palette.hex", pal);
    end

    // the first cell of each line: row 0 is the title bar, 29 the status bar
    localparam H_LAST = 857;                // 858 clocks per line (720 visible)
    wire [9:0]  ny = (y == 10'd524) ? 10'd0 : y + 1'b1;
    wire [4:0]  nrow = ny[8:4];
    wire [4:0]  nidx = (nrow == 5'd0 || nrow >= 5'd29) ? 5'd0 : nrow - 1'b1;
    wire [4:0]  nmap = map_flat[5 * nidx +: 5];
    wire [5:0]  nphys = (nrow == 5'd0) ? 6'd60 : (nrow >= 5'd29) ? 6'd61 : {bank, nmap};
    reg  [12:0] rowbase = 13'd4800;
    always @(posedge clk)
        if (x == H_LAST)
            rowbase <= {1'b0, nphys, 6'd0} + {3'd0, nphys, 4'd0};

    // the cell column of x and the pixel within the cell, counted alongside x
    reg [3:0]  fx0 = 4'd0;
    reg [6:0]  col0 = 7'd0;
    always @(posedge clk)
        if (x == H_LAST) begin
            fx0 <= 4'd0;
            col0 <= 7'd0;
        end else if (fx0 == 4'd8) begin
            fx0 <= 4'd0;
            col0 <= col0 + 1'b1;
        end else
            fx0 <= fx0 + 1'b1;
    assign slot = (fx0 == 4'd0);
    assign r_addr = rowbase + {6'd0, col0};

    // stage 1
    reg [3:0]  fx1 = 0;
    reg [3:0]  fy1 = 0;
    reg [4:0]  row1 = 0;
    reg [9:0]  x1 = 0;
    reg        vis1 = 0, cur1 = 0, odd1 = 0;
    reg [31:0] hold = 0;
    always @(posedge clk) begin
        fx1 <= fx0;
        fy1 <= y[3:0];
        row1 <= y[8:4];
        x1 <= x;
        vis1 <= (x < 10'd720) && (y < 10'd480);
        cur1 <= (col0 == cx) && (y[8:4] == {1'b0, cy} + 1'b1);
        odd1 <= y[0];
    end
    wire [31:0] cw = (fx1 == 4'd0) ? r_data : hold;          // the cell word, read once per 9 pixels
    wire [1:0]  bj = fy1[3:2];
    wire        brow = fy1[1] ^ fy1[0];
    wire        dl = brow & ((bj == 2'd0) ? cw[0] : (bj == 2'd1) ? cw[1] : (bj == 2'd2) ? cw[2] : cw[6]);
    wire        dr = brow & ((bj == 2'd0) ? cw[3] : (bj == 2'd1) ? cw[4] : (bj == 2'd2) ? cw[5] : cw[7]);

    // stage 2
    reg [7:0]  font_q = 0, bbyte2 = 0, fg2 = 0, bg2 = 0;
    reg [5:0]  fl2 = 0;
    reg        braille2 = 0, ext2 = 0, vis2 = 0, cur2 = 0, odd2 = 0;
    reg [3:0]  fx2 = 0;
    reg [3:0]  fy2 = 0;
    reg [4:0]  row2 = 0;
    reg [9:0]  x2 = 0;
    always @(posedge clk) begin
        hold <= cw;
        font_q <= font[{cw[8:0], fy1}];
        bbyte2 <= {1'b0, dl, dl, 2'b00, dr, dr, 1'b0};
        braille2 <= cw[9];
        ext2 <= (cw[9:7] == 3'b010) || (cw[9:5] == 5'b01100);         // box drawing, blocks
        fg2 <= cw[17:10];
        bg2 <= cw[25:18];
        fl2 <= cw[31:26];
        fx2 <= fx1; fy2 <= fy1; row2 <= row1; x2 <= x1; vis2 <= vis1; cur2 <= cur1; odd2 <= odd1;
    end
    wire [7:0] b0 = braille2 ? bbyte2 : font_q;
    wire [7:0] b1 = fl2[2] ? (b0 >> ((fy2 < 4'd6) ? 2 : (fy2 < 4'd10) ? 1 : 0)) : b0;
    // (bold is drawn in the bright colour only: the font's stems are already two pixels wide)
    wire [8:0] b3 = ((fl2[3] && fy2 == 4'd14) || (fl2[5] && fy2 == 4'd8)) ? 9'h1FF : {b1, ext2 & b1[0]};
    wire       text2 = (row2 != 5'd0) && (row2 < 5'd29);
    wire       curs = text2 && cursor && cur2 &&
                      (style == 2'd0 || (style == 2'd1 && fy2 >= 4'd14) || (style == 2'd2 && fx2 < 4'd2));
    wire       on = (b3[4'd8 - fx2] & !(fl2[4] && blink_off)) ^ curs ^ (text2 && scnm);

    // stage 3
    reg [23:0] pal_q = 0;
    reg        dim3 = 0, vis3 = 0, odd3 = 0;
    reg [3:0]  fy3 = 0;
    reg [4:0]  row3 = 0;
    reg [9:0]  x3 = 0;
    always @(posedge clk) begin
        pal_q <= pal[on ? fg2 : bg2];
        dim3 <= fl2[1] && on;
        fy3 <= fy2; row3 <= row2; x3 <= x2; vis3 <= vis2; odd3 <= odd2;
    end
    wire [7:0]  r0 = pal_q[23:16], g0 = pal_q[15:8], bl0 = pal_q[7:0];
    wire [7:0]  r1 = dim3 ? {1'b0, r0[7:1]} : r0;                     // dim: half as bright
    wire [7:0]  g1 = dim3 ? {1'b0, g0[7:1]} : g0;
    wire [7:0]  bb1 = dim3 ? {1'b0, bl0[7:1]} : bl0;
    wire [7:0]  t4 = x3[9:2];                                        // accent lines: a gradient across x
    wire        accent = (row3 == 5'd0 && fy3 == 4'd15) || (row3 == 5'd29 && fy3 == 4'd0);
    wire [23:0] c2 = accent ? {t4, ~t4, ~{2'b0, t4[7:2]}} :           // cyan to purple
                     (row3 == 5'd0 && bell) ? ~{r1, g1, bb1} : {r1, g1, bb1};
    wire [10:0] lum_sum = {2'b0, c2[23:16], 1'b0} + {1'b0, c2[15:8], 2'b0} + {3'b0, c2[15:8]} + {3'b0, c2[7:0]};
    wire [7:0]  lum = lum_sum[10:3];
    wire [23:0] c3 = (theme == 2'd1) ? {2'b0, lum[7:2], lum, 2'b0, lum[7:2]} :
                     (theme == 2'd2) ? {lum, {1'b0, lum[7:1]} + {3'b0, lum[7:3]} + {4'b0, lum[7:4]}, 4'b0, lum[7:4]} : c2;

    // stage 4: CRT scanlines, odd lines a quarter darker
    reg [23:0] cd = 0, c1 = 0;
    reg        odd4 = 0;
    always @(posedge clk) begin
        cd <= vis3 ? c3 : 24'd0;
        odd4 <= odd3;
        c1 <= cd;
    end
    always @(posedge clk)
        rgb <= (crt && odd4) ? {c1[23:16] - {2'b0, c1[23:18]}, c1[15:8] - {2'b0, c1[15:10]}, c1[7:0] - {2'b0, c1[7:2]}}
                             : c1;
endmodule
