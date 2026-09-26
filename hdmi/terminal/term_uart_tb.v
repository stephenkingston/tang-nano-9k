// The serial port at the bit level, with the speed detection: a sender changes speed several
// times (some with its clock 2.5% off) and every byte must arrive, in order and intact,
// including those sent while the new speed is being measured; at an unchanged speed all 256
// byte values must arrive; and the transmitter, looped into a receiver, must send at the
// detected speed with every bit edge within a clock of where it belongs.
`timescale 1ns/1ps
module term_uart_tb;
    localparam real CLK_NS = 1.0e9 / 27_000_000;
    reg clk = 1'b0;
    always #(CLK_NS / 2) clk = ~clk;

    reg         line_in = 1'b1;
    wire        got, hold, busy, txd, lgot, lferr;
    wire [7:0]  data, ldata;
    wire [3:0]  rate;
    wire [15:0] period;
    reg         start = 1'b0;
    reg  [7:0]  tdata = 8'd0;
    `include "term_params.vh"
    assign period = rate_period(rate);
    term_serial_in #(.INIT(INIT_RATE)) sin (.clk(clk), .rx(line_in), .valid(got), .data(data), .rate(rate),
                                             .hold(hold));
    term_uart_tx tx (.clk(clk), .period(period), .start(start), .data(tdata), .busy(busy), .tx(txd));
    term_uart_rx lrx (.clk(clk), .en(1'b1), .s(txd), .period(period), .quiet_len(16'd0), .restart(1'b0),
                      .valid(lgot), .data(ldata), .ferr(lferr));

    // what arrived
    reg [7:0] seen [0:1023];
    integer   nseen = 0, lgotn = 0, errors = 0;
    always @(posedge clk) begin
        if (got) begin
            seen[nseen] = data;
            nseen = nseen + 1;
        end
        if (lgot) begin
            if (ldata != (8'h3C ^ lgotn[7:0])) errors = errors + 1;
            lgotn = lgotn + 1;
        end
        if (lferr) errors = errors + 1;
    end

    real bit_ns;
    integer k;
    task send_byte(input [7:0] b);
        begin
            line_in = 1'b0;
            #(bit_ns);
            for (k = 0; k < 8; k = k + 1) begin
                line_in = b[k];
                #(bit_ns);
            end
            line_in = 1'b1;
            #(bit_ns);
        end
    endtask

    // send n bytes (first, first+1, ...) at baud with the sender ppm off, then check what came
    task segment(input integer baud, input integer ppm, input integer first, input integer n,
                 input integer may_lose);
        integer i, from, lost, bad;
        begin
            bit_ns = 1.0e9 / (baud * (1.0 + ppm * 1.0e-6));
            #(12000000);                                // quiet, as between two programs using the port
            from = nseen;
            bad = 0;
            for (i = 0; i < n; i = i + 1)
                send_byte(first + i);
            #(bit_ns * 30 + 11000000);                  // the bytes come out of the delay
            lost = n - (nseen - from);
            if (lost < 0 || lost > may_lose) begin
                $display("FAIL: %0d baud: %0d of %0d bytes arrived", baud, nseen - from, n);
                for (i = from; i < nseen; i = i + 1) $write(" %02x", seen[i]);
                $display("");
                bad = 1;
            end else
                for (i = from; i < nseen; i = i + 1)
                    if (seen[i] != ((first + lost + (i - from)) & 255)) begin
                        if (!bad) $display("FAIL: %0d baud: byte %0d arrived as %02x", baud, i - from, seen[i]);
                        bad = 1;
                    end
            if (bad)
                errors = errors + 1;
            else
                $display("ok   uart %0d baud, sender %0d ppm off: %0d of %0d bytes (detected %h)",
                         baud, ppm, n - lost, n, rate_bcd(rate));
        end
    endtask

    // every edge of a transmitted frame must fall on the bit grid that starts at its start bit
    realtime t0 = 0;
    real worst = 0, tx_bit = 1.0;
    reg in_frame = 1'b0;
    always @(negedge busy) in_frame = 1'b0;
    always @(txd) begin
        if (!in_frame && txd == 1'b0) begin
            in_frame = 1'b1;
            t0 = $realtime;
        end else if (in_frame) begin : measure
            real bits, off;
            bits = ($realtime - t0) / tx_bit;
            off = (bits - $rtoi(bits + 0.5)) * tx_bit;
            if (off < 0) off = -off;
            if (off > worst) worst = off;
        end
    end

    initial begin : run
        integer j;
        #(20000);
        segment(115200, 0, 8'h00, 40, 0);          // from the power-up speed down to 115200
        segment(115200, 0, 8'h00, 256, 0);         // all byte values at an unchanged speed
        segment(3000000, 25000, 8'h40, 40, 0);
        segment(460800, -25000, 8'h80, 40, 0);
        segment(1000000, 0, 8'h10, 40, 0);
        segment(57600, 0, 8'hA0, 24, 0);
        segment(9600, -25000, 8'h30, 12, 0);        // the slow delay
        segment(9600, 0, 8'h51, 1, 0);
        segment(38400, 25000, 8'h61, 16, 0);
        segment(230400, 0, 8'h68, 1, 0);            // single keystrokes, as typed in minicom
        segment(230400, 0, 8'h69, 1, 0);
        segment(2000000, 25000, 8'h20, 40, 0);
        segment(2000000, 0, 8'h00, 256, 0);
        // the transmitter at the detected speed, looped back
        tx_bit = 1.0e9 / 2000000;
        for (j = 0; j < 32; j = j + 1) begin
            @(posedge clk);
            while (busy) @(posedge clk);
            tdata <= 8'h3C ^ j;
            start <= 1'b1;
            @(posedge clk);
            start <= 1'b0;
            @(posedge clk);
        end
        while (busy) @(posedge clk);
        #(tx_bit * 12);
        if (lgotn != 32) begin
            $display("FAIL: %0d of 32 bytes looped back", lgotn);
            errors = errors + 1;
        end
        if (worst > CLK_NS * 1.1) begin             // one clock, plus the testbench clock's rounding
            $display("FAIL: a transmitted bit edge was %.1f ns off", worst);
            errors = errors + 1;
        end
        if (errors == 0)
            $display("ok   uart transmit at the detected speed: 32 bytes looped back, bit edges within %.1f ns",
                     worst);
        $finish;
    end
endmodule
