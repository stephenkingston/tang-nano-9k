// Pong geometry and tuning, shared by pong_game and pong_render (in 640x480 screen pixels).
localparam WALL_TOP = 16, WALL_BOT = 456, WALL_H = 8;           // walls at 16..23 and 456..463
localparam FIELD_TOP = WALL_TOP + WALL_H, FIELD_BOT = WALL_BOT;  // the ball moves within 24..455
localparam PAD_W = 12, PAD_H = 64;
localparam LPAD_X = 40, RPAD_X = 588;                            // left edge of each paddle
localparam BALL = 12;
localparam NET_X = 316, NET_W = 8;
localparam SCORE_Y = 40;                                         // digits are 3x5 blocks of 12 px

localparam PLAYER_SPD = 7, CPU_SPD = 4;                          // px per frame
localparam CPU_REACT = 220;                                      // CPU chases the ball once it is this close
localparam SERVE_VX = 64, SPEEDUP = 6, MAX_VX = 176;             // ball speed in 1/16 px per frame
localparam WIN_SCORE = 11;

localparam PH_SERVE = 0, PH_PLAY = 1, PH_OVER = 2;
localparam SND_NONE = 0, SND_PADDLE = 1, SND_WALL = 2, SND_POINT = 3;
