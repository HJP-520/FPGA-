// =============================================================================
// ph1p_logic_eram_stub.v —— TD ERAM 原语的行为级替身（仅供仿真，TD 综合时用真原语）
// -----------------------------------------------------------------------------
// 端口/参数清单来自官方 blk_mem 生成 RTL 的实例化（addra/addrb/dia/dib/cea/ceb/
// clka/clkb/wea/web/bea/beb/rsta/rstb/doa/dob + ecc 端口）。
// 行为：真双口 RAM，A 口写、B 口读写；bea/beb=0 表示全字节写（忽略）。
//
// v3 修正（2026-10-03，视频通路整链仿真"全 X"事故）：
//   [1] 参数名与官方 wrapper 对齐：wrapper 传的是 ADDR_WIDTH_A/ADDR_WIDTH_B
//       （旧版端口宽度误用 ADDRA_WIDTH/ADDRB_WIDTH，wrapper 传入的宽度
//       没作用到端口上——端口 14bit 对 11bit 连接，高位悬空 Z）。
//   [2] 地址位清洗：端口宽度仍可能大于实际连接位数（formal 高位 Z），
//       mem 索引前把 Z/X 位归 0（真实硬件地址不可能未知）。
//   [3] 使能/写使能语义对齐硬件：cea/ceb 未接（Z）= 直通使能；
//       wea/web 仅显式 1 才写（wrapper 有把 web 悬空的只读用法，
//       若把 Z 当写使能会把 Z 数据灌进 mem——v2 中间版曾犯此错）。
//   [4] mem 上电清零：对齐硬件初值 0，防止 X 沿 AWB 增益累加路径
//       污染整帧（"X 污染锁存"）。
// =============================================================================
`timescale 1ns/1ps
module PH1P_LOGIC_ERAM #(
    parameter integer DATA_WIDTH_A = 20,
    parameter integer DATA_WIDTH_B = DATA_WIDTH_A,
    parameter integer ADDR_WIDTH_A = 14,
    parameter integer ADDR_WIDTH_B = ADDR_WIDTH_A,
    parameter MODE               = "DP",
    parameter IMPLEMENT          = "20KFAST",
    parameter REGMODE_A          = "NORESET",
    parameter REGMODE_B          = "NORESET",
    parameter RESETMODE_A        = "SYNC",
    parameter RESETMODE_B        = "SYNC",
    parameter OREGSET_A          = "RESET",
    parameter OREGSET_B          = "RESET",
    parameter SYNC_RESET_RELEASE_A = "DISABLE",
    parameter SYNC_RESET_RELEASE_B = "DISABLE",
    parameter ASYNC_RESET_RELEASE_A = "ASYNC",
    parameter ASYNC_RESET_RELEASE_B = "ASYNC",
    parameter SSROVERCE          = "DISABLE",
    parameter ECC_ENCODE         = "DISABLE",
    parameter ECC_DECODE         = "DISABLE",
    parameter GSR                = "ENABLE",
    parameter RESETMODE          = "SYNC",
    parameter CLKMODE            = "ASYNC",
    parameter WRITEMODE_A        = "NORMAL",
    parameter WRITEMODE_B        = "NORMAL",
    parameter DATA_DEPTH_A       = 512,
    parameter DATA_DEPTH_B       = 512,
    parameter INIT_FILE          = "NONE",
    parameter FILL_ALL           = "NONE"
)(
    input  wire                     clka,
    input  wire                     clkb,
    input  wire [ADDR_WIDTH_A-1:0]  addra,
    input  wire [ADDR_WIDTH_B-1:0]  addrb,
    input  wire [DATA_WIDTH_A-1:0]  dia,
    input  wire [DATA_WIDTH_B-1:0]  dib,
    input  wire                     cea,
    input  wire                     ceb,
    input  wire                     ocea,
    input  wire                     oceb,
    input  wire                     wea,
    input  wire                     web,
    input  wire                     bea,
    input  wire                     beb,
    input  wire                     rsta,
    input  wire                     rstb,
    output reg  [DATA_WIDTH_A-1:0]  doa,
    output reg  [DATA_WIDTH_B-1:0]  dob,
    output wire                     ecc_sbiterr,
    output wire                     ecc_dbiterr,
    input  wire                     ecc_sbiterrinj,
    input  wire                     ecc_dbiterrinj
);
    localparam DEPTH_A = (DATA_DEPTH_A > 16384) ? 16384 : DATA_DEPTH_A;
    localparam DEPTH_B = (DATA_DEPTH_B > 16384) ? 16384 : DATA_DEPTH_B;
    reg [DATA_WIDTH_A-1:0] mem [0:DEPTH_A-1];
    // 硬件对齐：TD ERAM 上电读出为 0（v3[4]，仅供仿真）
    integer _i;
    initial for (_i = 0; _i < DEPTH_A; _i = _i + 1) mem[_i] = {DATA_WIDTH_A{1'b0}};
    assign ecc_sbiterr = 0; assign ecc_dbiterr = 0;
    // 外脑评审: 未知位(X/Z)单次告警——替身对悬空地址/使能保持宽容语义，
    // 但必须让"连接错误"在仿真阶段可见（只报一次，避免稳定悬空刷屏）。
    reg warned_unknown;
    initial warned_unknown = 1'b0;
    always @(posedge clka or posedge clkb) begin
        if (!warned_unknown &&
            (^{addra, addrb, cea, ceb, wea, web, rsta, rstb} === 1'bx)) begin
            warned_unknown <= 1'b1;
            $display("ERAM_STUB_WARN: unknown (X/Z) on addr/enable pins @ %m (t=%0t)", $time);
        end
    end


    // 地址位清洗（v3[2]）：formal 高位可能因连接位宽不足悬空为 Z，
    // mem 索引带 Z/X 会整体返回 X——把未知位归 0（真实硬件不存在未知地址）。
    reg [ADDR_WIDTH_A-1:0] addra_c;
    reg [ADDR_WIDTH_B-1:0] addrb_c;
    integer _k;
    always @(*) begin
        for (_k = 0; _k < ADDR_WIDTH_A; _k = _k + 1)
            addra_c[_k] = (addra[_k] === 1'b1) ? 1'b1 : 1'b0;
        for (_k = 0; _k < ADDR_WIDTH_B; _k = _k + 1)
            addrb_c[_k] = (addrb[_k] === 1'b1) ? 1'b1 : 1'b0;
    end

    // 使能/写使能语义（v3[3]）：
    //   cea/ceb 未接(Z)=直通使能；rsta/rstb 仅显式 1 复位；
    //   wea/web 仅显式 1 才写（悬空 Z 的 web 不得写——只读端口用法）。
    wire cea_e = (cea !== 1'b0);
    wire ceb_e = (ceb !== 1'b0);

    always @(posedge clka) begin
        if (cea_e && (rsta === 1'b1)) begin
            doa <= 0;
        end else if (cea_e) begin
            if ((wea === 1'b1) && (addra_c < DEPTH_A)) mem[addra_c] <= dia;
            doa <= mem[addra_c];
        end
    end
    always @(posedge clkb) begin
        if (ceb_e && (rstb === 1'b1)) begin
            dob <= 0;
        end else if (ceb_e) begin
            if ((web === 1'b1) && (addrb_c < DEPTH_B)) mem[addrb_c] <= dib;
            dob <= mem[addrb_c];
        end
    end
endmodule

module PH1_LOGIC_ERAM #(
    parameter integer DATA_WIDTH_A = 20,
    parameter integer DATA_WIDTH_B = DATA_WIDTH_A,
    parameter integer ADDR_WIDTH_A = 14,
    parameter integer ADDR_WIDTH_B = ADDR_WIDTH_A,
    parameter MODE               = "DP",
    parameter IMPLEMENT          = "20KFAST",
    parameter REGMODE_A          = "NORESET",
    parameter REGMODE_B          = "NORESET",
    parameter RESETMODE_A        = "SYNC",
    parameter RESETMODE_B        = "SYNC",
    parameter OREGSET_A          = "RESET",
    parameter OREGSET_B          = "RESET",
    parameter SYNC_RESET_RELEASE_A = "DISABLE",
    parameter SYNC_RESET_RELEASE_B = "DISABLE",
    parameter ASYNC_RESET_RELEASE_A = "ASYNC",
    parameter ASYNC_RESET_RELEASE_B = "ASYNC",
    parameter SSROVERCE          = "DISABLE",
    parameter ECC_ENCODE         = "DISABLE",
    parameter ECC_DECODE         = "DISABLE",
    parameter GSR                = "ENABLE",
    parameter RESETMODE          = "SYNC",
    parameter CLKMODE            = "ASYNC",
    parameter WRITEMODE_A        = "NORMAL",
    parameter WRITEMODE_B        = "NORMAL",
    parameter DATA_DEPTH_A       = 512,
    parameter DATA_DEPTH_B       = 512,
    parameter INIT_FILE          = "NONE",
    parameter FILL_ALL           = "NONE"
)(
    input  wire                     clka,
    input  wire                     clkb,
    input  wire [ADDR_WIDTH_A-1:0]  addra,
    input  wire [ADDR_WIDTH_B-1:0]  addrb,
    input  wire [DATA_WIDTH_A-1:0]  dia,
    input  wire [DATA_WIDTH_B-1:0]  dib,
    input  wire                     cea,
    input  wire                     ceb,
    input  wire                     ocea,
    input  wire                     oceb,
    input  wire                     wea,
    input  wire                     web,
    input  wire                     bea,
    input  wire                     beb,
    input  wire                     rsta,
    input  wire                     rstb,
    output reg  [DATA_WIDTH_A-1:0]  doa,
    output reg  [DATA_WIDTH_B-1:0]  dob,
    output wire                     ecc_sbiterr,
    output wire                     ecc_dbiterr,
    input  wire                     ecc_sbiterrinj,
    input  wire                     ecc_dbiterrinj
);
    localparam DEPTH_A = (DATA_DEPTH_A > 16384) ? 16384 : DATA_DEPTH_A;
    localparam DEPTH_B = (DATA_DEPTH_B > 16384) ? 16384 : DATA_DEPTH_B;
    reg [DATA_WIDTH_A-1:0] mem [0:DEPTH_A-1];
    integer _j;
    initial for (_j = 0; _j < DEPTH_A; _j = _j + 1) mem[_j] = {DATA_WIDTH_A{1'b0}};
    assign ecc_sbiterr = 0; assign ecc_dbiterr = 0;
    // 外脑评审: 未知位(X/Z)单次告警——替身对悬空地址/使能保持宽容语义，
    // 但必须让"连接错误"在仿真阶段可见（只报一次，避免稳定悬空刷屏）。
    reg warned_unknown;
    initial warned_unknown = 1'b0;
    always @(posedge clka or posedge clkb) begin
        if (!warned_unknown &&
            (^{addra, addrb, cea, ceb, wea, web, rsta, rstb} === 1'bx)) begin
            warned_unknown <= 1'b1;
            $display("ERAM_STUB_WARN: unknown (X/Z) on addr/enable pins @ %m (t=%0t)", $time);
        end
    end


    reg [ADDR_WIDTH_A-1:0] addra_c;
    reg [ADDR_WIDTH_B-1:0] addrb_c;
    integer _m;
    always @(*) begin
        for (_m = 0; _m < ADDR_WIDTH_A; _m = _m + 1)
            addra_c[_m] = (addra[_m] === 1'b1) ? 1'b1 : 1'b0;
        for (_m = 0; _m < ADDR_WIDTH_B; _m = _m + 1)
            addrb_c[_m] = (addrb[_m] === 1'b1) ? 1'b1 : 1'b0;
    end

    wire cea_e = (cea !== 1'b0);
    wire ceb_e = (ceb !== 1'b0);

    always @(posedge clka) begin
        if (cea_e && (rsta === 1'b1)) begin
            doa <= 0;
        end else if (cea_e) begin
            if ((wea === 1'b1) && (addra_c < DEPTH_A)) mem[addra_c] <= dia;
            doa <= mem[addra_c];
        end
    end
    always @(posedge clkb) begin
        if (ceb_e && (rstb === 1'b1)) begin
            dob <= 0;
        end else if (ceb_e) begin
            if ((web === 1'b1) && (addrb_c < DEPTH_B)) mem[addrb_c] <= dib;
            dob <= mem[addrb_c];
        end
    end
endmodule
