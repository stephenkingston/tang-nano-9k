// AES-128 in CBC mode, a byte at a time, for the built-in shell's key, iv, enc and dec commands
// (term_aes.py is the reference). One 2 KB block RAM holds the text being worked on, from
// address 0 (up to 112 blocks), then the round keys (0x700), the IV (0x7C0) and two 16-byte
// state buffers (0x7E0, 0x7F0); the S-box and its inverse are a ROM in another. At power-up
// the key and IV are those of NIST SP 800-38A's CBC example (term_aes.hex). A block takes
// about 900 clocks.
//
// The engine writes into the RAM through the h_ port, starts an operation with go, waits while
// busy, and reads results back through the same port (data one clock after the address):
//   1 key  the 16 bytes at 0 become the key: its round keys are worked out
//   2 iv   the 16 bytes at 0 become the IV
//   3 enc  encrypt the nblk blocks at 0, in place
//   4 dec  decrypt the nblk blocks at 0, in place, last block first, so that the block before
//          each one is still ciphertext when it is needed
// Each round works a column at a time: gather its four bytes (ShiftRows, SubBytes, and for
// decryption AddRoundKey) into col, then scatter them (MixColumns and AddRoundKey, or the
// inverse), one byte per turn as col rotates.
module term_aes (
    input  wire        clk,
    input  wire        go,
    input  wire [2:0]  op,
    input  wire [6:0]  nblk,
    output wire        busy,
    input  wire        h_we,
    input  wire [10:0] h_addr,
    input  wire [7:0]  h_wdata,
    output wire [7:0]  h_rdata
);
    localparam A_IDLE = 3'd0, A_KEY = 3'd1, A_IV = 3'd2, A_LOAD = 3'd3, A_GATHER = 3'd4, A_SCATTER = 3'd5;

    reg [2:0]  st = A_IDLE;
    reg [1:0]  ph = 2'd0;                   // the clock within a byte's turn
    reg        dec = 1'b0;
    reg [3:0]  r = 4'd0;                    // round (the round key in use)
    reg [1:0]  c = 2'd0, k = 2'd0;          // column and row of the byte being worked on
    reg [6:0]  blk = 7'd0, last = 7'd0;
    reg        pp = 1'b0;                   // which state buffer holds the state
    reg [7:0]  acc = 8'd0, rcon = 8'h01;
    reg [31:0] col = 32'd0;
    reg        a_we = 1'b0;
    reg [10:0] a_waddr = 11'd0;
    reg [7:0]  a_wdata = 8'd0;

    // the RAM and the S-box ROM (each read gives its data on the next clock)
    reg [7:0]  mem [0:2047];
    reg [7:0]  sbox [0:511];
    initial begin
        $readmemh("term_aes.hex", mem);
        $readmemh("term_sbox.hex", sbox);
    end
    reg  [10:0] a_raddr;
    reg  [7:0]  mq = 8'd0, sq = 8'd0;
    always @(posedge clk) begin
        if (a_we)      mem[a_waddr] <= a_wdata;
        else if (h_we) mem[h_addr] <= h_wdata;
        mq <= mem[(st != A_IDLE) ? a_raddr : h_addr];
        sq <= sbox[{dec, mq}];              // the byte just read, substituted
    end
    assign h_rdata = mq;
    assign busy = go || (st != A_IDLE) || a_we;

    // addresses: the text, the round keys, the IV, the state buffers
    wire [3:0]  rm1 = r - 1'b1;
    wire [6:0]  bm1 = blk - 1'b1;
    wire [10:0] at_data = {blk, c, k};
    wire [10:0] at_rk = {3'b111, r, c, k};
    wire [10:0] at_chain = (blk == 7'd0) ? {7'b1111100, c, k} : {bm1, c, k};     // the IV, or the block before
    wire [10:0] at_st = {6'b111111, pp, c, k};
    wire [10:0] at_next = {6'b111111, !pp, c, k};
    always @* begin
        a_raddr = at_rk;
        case (st)
            A_KEY:     if (ph == 2'd0) a_raddr = (r == 4'd0) ? {7'd0, c, k} : {3'b111, rm1, c, k};
                       else a_raddr = (c == 2'd0) ? {3'b111, rm1, 2'd3, k + 1'b1} : {3'b111, r, c - 1'b1, k};
            A_IV:      a_raddr = {7'd0, c, k};
            A_LOAD:    case (ph)
                           2'd0: a_raddr = at_data;
                           2'd1: a_raddr = dec ? {3'b111, 4'd10, c, k} : at_chain;
                           default: a_raddr = {7'b1110000, c, k};                   // round key 0
                       endcase
            A_GATHER:  if (ph == 2'd0) a_raddr = {6'b111111, pp, dec ? c - k : c + k, k};
            A_SCATTER: if (dec) a_raddr = at_chain;
            default: ;
        endcase
    end

    // MixColumns and InvMixColumns for the byte at the top of col:
    //   2 a0 + 3 a1 + a2 + a3  and  14 a0 + 11 a1 + 13 a2 + 9 a3, sharing terms
    function [7:0] xt;
        input [7:0] a;
        xt = {a[6:0], 1'b0} ^ (a[7] ? 8'h1B : 8'h00);
    endfunction
    wire [7:0]  a0 = col[31:24], a1 = col[23:16], a2 = col[15:8], a3 = col[7:0];
    wire [7:0]  mix = xt(a0 ^ a1) ^ a1 ^ a2 ^ a3;
    wire [7:0]  imix = mix ^ xt(xt(a0 ^ a2)) ^ xt(xt(xt(a0 ^ a1 ^ a2 ^ a3)));
    wire        final_round = dec ? (r == 4'd0) : (r == 4'd10);
    wire [7:0]  out = final_round ? a0 : dec ? imix : mix;

    task write;
        input [10:0] a;
        input [7:0]  d;
        begin
            a_we <= 1'b1; a_waddr <= a; a_wdata <= d;
        end
    endtask

    always @(posedge clk) begin
        a_we <= 1'b0;
        case (st)
        A_IDLE:
            if (go) begin
                dec <= (op == 3'd4);
                r <= 4'd0; c <= 2'd0; k <= 2'd0; ph <= 2'd0; pp <= 1'b0; rcon <= 8'h01;
                blk <= (op == 3'd4) ? nblk - 1'b1 : 7'd0;
                last <= nblk - 1'b1;
                st <= (op == 3'd1) ? A_KEY : (op == 3'd2) ? A_IV : A_LOAD;
            end

        A_KEY: begin                        // round key byte j = 16 r + 4 c + k
            ph <= ph + 1'b1;
            if (ph == 2'd1) acc <= mq;      // w[j - 16]
            if ((ph == 2'd1 && r == 4'd0) || (ph == 2'd2 && c != 2'd0) || ph == 2'd3) begin
                write(at_rk, (r == 4'd0) ? mq : (ph == 2'd2) ? acc ^ mq : acc ^ sq ^ ((k == 2'd0) ? rcon : 8'd0));
                ph <= 2'd0;
                {r, c, k} <= {r, c, k} + 1'b1;
                if ({c, k} == 4'd15 && r != 4'd0) rcon <= xt(rcon);
                if (r == 4'd10 && {c, k} == 4'd15) st <= A_IDLE;
            end
        end

        A_IV: begin
            ph <= !ph[0];
            if (ph[0]) begin
                write({7'b1111100, c, k}, mq);
                {c, k} <= {c, k} + 1'b1;
                if ({c, k} == 4'd15) st <= A_IDLE;
            end
        end

        A_LOAD: begin                       // the block, XOR the IV or the block before, XOR round key 0 (encrypting)
            ph <= ph + 1'b1;                // or XOR round key 10 (decrypting)
            if (ph == 2'd1) acc <= mq;
            if (ph == 2'd2) acc <= acc ^ mq;
            if ((ph == 2'd2 && dec) || ph == 2'd3) begin
                write(at_st, acc ^ mq);
                ph <= 2'd0;
                {c, k} <= {c, k} + 1'b1;
                if ({c, k} == 4'd15) begin
                    st <= A_GATHER;
                    r <= dec ? 4'd9 : 4'd1;
                end
            end
        end

        A_GATHER: begin                     // col gets byte k of column c, shifted and substituted
            ph <= ph + 1'b1;
            if (ph == 2'd2) begin
                col <= {col[23:0], sq ^ (dec ? mq : 8'd0)};
                ph <= 2'd0;
                k <= k + 1'b1;
                if (k == 2'd3) st <= A_SCATTER;
            end
        end

        A_SCATTER: begin                    // byte k of column c: mixed, XOR the round key or the block before
            ph <= !ph[0];
            if (ph[0]) begin
                write(final_round ? at_data : at_next, out ^ ((!dec || r == 4'd0) ? mq : 8'd0));
                col <= {col[23:0], col[31:24]};
                k <= k + 1'b1;
                if (k == 2'd3) begin
                    c <= c + 1'b1;
                    st <= A_GATHER;
                    if (c == 2'd3) begin    // the round is done
                        pp <= !pp;
                        r <= dec ? r - 1'b1 : r + 1'b1;
                        if (final_round) begin
                            if (dec ? blk == 7'd0 : blk == last)
                                st <= A_IDLE;
                            else begin
                                blk <= dec ? bm1 : blk + 1'b1;
                                st <= A_LOAD;
                            end
                        end
                    end
                end
            end
        end

        default:
            st <= A_IDLE;
        endcase
    end
endmodule
