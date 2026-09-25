// Renders one frame of scene_render with the same 800x525 scan as dvi_tx and writes every
// visible pixel (640x480, row-major, rrggbb hex) to scene_frame.hex. scene_gen.py --check
// compares that dump with its reference model.
`timescale 1ns/1ps
module scene_tb;
    parameter FRAME = 0;                // animation frame to render
    localparam PIPE = 4;                // scene_render latency

    reg clk = 0;
    always #20 clk = ~clk;

    reg  [9:0]  x = 0, y = 0;
    wire        frame = (x == 0) && (y == 480);
    wire [23:0] rgb;

    scene_render #(.T0(FRAME)) dut (.clk(clk), .x(x), .y(y), .frame(frame), .rgb(rgb));

    always @(posedge clk) begin
        x <= (x == 799) ? 10'd0 : x + 1'b1;
        if (x == 799)
            y <= (y == 524) ? 10'd0 : y + 1'b1;
    end

    // Remember which pixel each rgb value belongs to.
    reg [19:0] pos [1:PIPE];
    integer k;
    initial for (k = 1; k <= PIPE; k = k + 1) pos[k] = {10'd1023, 10'd1023};
    always @(posedge clk) begin
        pos[1] <= {y, x};
        for (k = 2; k <= PIPE; k = k + 1)
            pos[k] <= pos[k - 1];
    end

    integer fd, written = 0;
    initial fd = $fopen("scene_frame.hex", "w");

    always @(negedge clk) begin
        if (pos[PIPE][9:0] < 640 && pos[PIPE][19:10] < 480) begin
            $fwrite(fd, "%06x\n", rgb);
            written = written + 1;
            if (written == 640 * 480) begin
                $fclose(fd);
                $display("wrote scene_frame.hex (frame %0d)", FRAME);
                $finish;
            end
        end
    end
endmodule
