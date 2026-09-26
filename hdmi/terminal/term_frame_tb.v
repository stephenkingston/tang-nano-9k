// Renders one frame with term_render from a cell memory dump (tb_ram.hex, written by
// term_core_tb) and writes the 720x480 visible pixels (rrggbb hex) to tb_frame.hex, for
// term_test.py to compare with the model's renderer. Settings come from plusargs:
//   +bank +cx +cy +cursor +style +scnm +blink_off +bell +theme +crt
`timescale 1ns/1ps
module term_frame_tb;
    localparam PIPE = 6;
    reg clk = 1'b0;
    always #20 clk = ~clk;

    reg [9:0]   x = 10'd0, y = 10'd0;
    integer     bank = 0, cx = 0, cy = 0, cursor = 1, style = 0, scnm = 0, blink_off = 0, bell = 0, theme = 0,
                crt = 0, i, f, frame = 0;
    reg [31:0]  dump [0:4987];
    reg [139:0] map_flat = 140'd0;
    wire        slot;
    wire [12:0] r_addr;
    wire [31:0] q;
    wire [23:0] rgb;

    term_cells cells (.clk(clk), .we(1'b0), .waddr(13'd0), .wdata(32'd0), .raddr(r_addr), .q(q));
    term_render render (
        .clk(clk), .x(x), .y(y), .slot(slot), .r_addr(r_addr), .r_data(q),
        .bank(bank[0]), .map_flat(map_flat), .cx(cx[6:0]), .cy(cy[4:0]), .cursor(cursor[0]), .style(style[1:0]),
        .scnm(scnm[0]), .blink_off(blink_off[0]), .bell(bell[0]), .theme(theme[1:0]), .crt(crt[0]), .rgb(rgb)
    );

    initial begin
        if ($value$plusargs("bank=%d", bank)) ;
        if ($value$plusargs("cx=%d", cx)) ;
        if ($value$plusargs("cy=%d", cy)) ;
        if ($value$plusargs("cursor=%d", cursor)) ;
        if ($value$plusargs("style=%d", style)) ;
        if ($value$plusargs("scnm=%d", scnm)) ;
        if ($value$plusargs("blink_off=%d", blink_off)) ;
        if ($value$plusargs("bell=%d", bell)) ;
        if ($value$plusargs("theme=%d", theme)) ;
        if ($value$plusargs("crt=%d", crt)) ;
        $readmemh("tb_ram.hex", dump);
        #1;
        for (i = 0; i < 4960; i = i + 1)
            cells.ram[i] = dump[i];
        for (i = 0; i < 28; i = i + 1)
            map_flat[5 * i +: 5] = dump[4960 + i][4:0];
        f = $fopen("tb_frame.hex", "w");
    end

    // scan like dvi_tx in 720x480 mode; the second frame is captured
    reg [9:0] xs [0:PIPE-1];
    reg [9:0] ys [0:PIPE-1];
    reg [1:0] fs [0:PIPE-1];
    always @(posedge clk) begin
        if (x == 10'd857) begin
            x <= 10'd0;
            if (y == 10'd524) begin
                y <= 10'd0;
                frame <= frame + 1;
            end else
                y <= y + 1'b1;
        end else
            x <= x + 1'b1;
        xs[0] <= x; ys[0] <= y; fs[0] <= frame;
        for (i = 1; i < PIPE; i = i + 1) begin
            xs[i] <= xs[i - 1]; ys[i] <= ys[i - 1]; fs[i] <= fs[i - 1];
        end
        // rgb now belongs to the scan position of PIPE clocks ago
        if (fs[PIPE - 1] == 2'd1 && xs[PIPE - 1] < 10'd720 && ys[PIPE - 1] < 10'd480)
            $fwrite(f, "%06x\n", rgb);
        if (frame == 2) begin
            $fclose(f);
            $finish;
        end
    end
endmodule
