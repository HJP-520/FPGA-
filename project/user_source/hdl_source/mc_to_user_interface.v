// -----------------------------------------------------------------------------
// R4 command bridge: real per-channel handshake, calibration gated.
//
// Fixes vs R3 (see SC520_黑屏与JTAG抓图_交接说明.md section C):
//   1. READ : ARVALID is asserted as soon as a read command is at the FIFO head.
//             The payload (address) is held stable until ARVALID && ARREADY;
//             only a real handshake pops the head.
//   2. WRITE: AWVALID and WVALID are independent of any READY. Each channel
//             latches its own completion; a completed channel stops driving,
//             the other keeps VALID with stable payload; the head pops only
//             after BOTH channels completed. (Fixing O_mc_app_en = !empty alone
//             would duplicate write address/data and is deliberately avoided.)
//   3. CALIB: user-ready and all channel VALIDs are gated by I_calib_complete,
//             so no uninitialized traffic reaches the controller. Commands that
//             are nevertheless enqueued while uncalibrated are retained in the
//             FIFO (nothing pops silently) and are issued after calibration.
//   4. DIAG : counters split into user attempted / FIFO accepted / controller
//             read-handshaken / write-completed / responses. Read counting is
//             O_rd_handshake = ARVALID && ARREADY (one count per accepted
//             transfer, even if VALID is held for many cycles).
//
// The header command FIFO is the vendor-generated w155_d512_fifo (show-ahead,
// synchronous read RAM). Its dout is stable while nothing is popped and still
// shows the popped word during the pop cycle, so holding VALID for many cycles
// needs no extra payload registers.
// -----------------------------------------------------------------------------
module mc_to_user_interface (
    input  wire         I_clk,
    input  wire         I_rst_n,

    /* user interface: semantics unchanged from the vendor original
       (I_ddr_user_ready 拉低时还能写入8个长度数据) */
    input  wire         I_ddr_user_wr_en,
    input  wire         I_ddr_user_rd_en,
    input  wire [24:0]  I_ddr_user_addr,
    input  wire [127:0] I_ddr_user_wr_data,
    output wire         O_ddr_user_ready,
    output wire         O_ddr_user_rd_valid,
    output wire [127:0] O_ddr_user_rd_data,

    /* calibration status (quasi-static, same DDR domain in this design) */
    input  wire         I_calib_complete,

    /* controller command channels: VALID held with stable payload until the
       matching READY handshake; the head pops only on real handshakes */
    output wire         O_mc_ar_valid,
    output wire         O_mc_aw_valid,
    output wire         O_mc_w_valid,
    output wire [24:0]  O_mc_app_addr,
    output wire [127:0] O_mc_app_wdf_data,
    output wire         O_mc_app_wdf_end,
    output wire [15:0]  O_mc_app_wdf_mask,
    input  wire         I_mc_ar_ready,
    input  wire         I_mc_aw_ready,
    input  wire         I_mc_w_ready,

    /* controller response path */
    input  wire [127:0] I_mc_app_rd_data,
    input  wire         I_mc_app_rd_data_end,
    input  wire         I_mc_app_rd_data_valid,

    /* diagnostics */
    output wire         O_rd_handshake
);

    wire         S_fifo_wr_en;
    wire [154:0] S_fifo_wr_data;
    wire         S_fifo_pro_full;
    wire         S_fifo_full;
    wire         S_fifo_rd_en;
    wire [154:0] S_fifo_rd_data;
    wire         S_fifo_empty;

    // ---- command FIFO (vendor generated, show-ahead) ----
    assign S_fifo_wr_en   = I_ddr_user_wr_en | I_ddr_user_rd_en;
    assign S_fifo_wr_data = {I_ddr_user_wr_en, I_ddr_user_rd_en, I_ddr_user_addr, I_ddr_user_wr_data};

    w155_d512_fifo U_w155_d512_fifo(
        .clk        ( I_clk             ),
        .rst        ( ~I_rst_n          ),
        .we         ( S_fifo_wr_en      ),
        .di         ( S_fifo_wr_data    ),
        .afull      ( S_fifo_pro_full   ),
        .full_flag  ( S_fifo_full       ),
        .wrusedw    (),
        .re         ( S_fifo_rd_en      ),
        .valid      (),
        .dout       ( S_fifo_rd_data    ),
        .empty_flag ( S_fifo_empty      ),
        .aempty     (),
        .rdusedw    ()
    );

    // ---- calibration synchronizer (single quasi-static bit, 2FF) ----
    (* async_reg = "true" *) reg S_calib_meta, S_calib_sync;
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            S_calib_meta <= 1'b0;
            S_calib_sync <= 1'b0;
        end else begin
            S_calib_meta <= I_calib_complete;
            S_calib_sync <= S_calib_meta;
        end
    end

    // ---- head decode (show-ahead output is stable while nothing pops) ----
    wire S_head_valid = ~S_fifo_empty;
    wire S_head_rd    = S_fifo_rd_data[153];
    wire S_head_wr    = S_fifo_rd_data[154];

    // ---- per-channel completion latches (cleared when the head pops) ----
    reg S_aw_done, S_w_done;

    // ---- per-channel VALID: held (stable payload) until its own handshake ----
    assign O_mc_ar_valid = S_calib_sync & S_head_valid &  S_head_rd;
    assign O_mc_aw_valid = S_calib_sync & S_head_valid & S_head_wr & (~S_aw_done);
    assign O_mc_w_valid  = S_calib_sync & S_head_valid & S_head_wr & (~S_w_done);

    assign O_mc_app_addr     = S_fifo_rd_data[152:128];
    assign O_mc_app_wdf_data = S_fifo_rd_data[127:0];
    assign O_mc_app_wdf_end  = 1'b1;
    assign O_mc_app_wdf_mask = 16'd0;   // vendor convention: 0 = no byte masked

    wire S_ar_hs = O_mc_ar_valid & I_mc_ar_ready;
    wire S_aw_hs = O_mc_aw_valid & I_mc_aw_ready;
    wire S_w_hs  = O_mc_w_valid  & I_mc_w_ready;
    wire S_wr_done = (S_aw_done | S_aw_hs) & (S_w_done | S_w_hs);

    // the head pops ONLY on a real handshake:
    //   READ  -> on ARVALID&&ARREADY
    //   WRITE -> when both AW and W channels have completed
    wire S_pop = S_ar_hs | (S_head_wr & S_wr_done);
    assign S_fifo_rd_en = S_pop;

    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            S_aw_done <= 1'b0;
            S_w_done  <= 1'b0;
        end else if(S_pop) begin
            S_aw_done <= 1'b0;
            S_w_done  <= 1'b0;
        end else begin
            if(S_aw_hs) S_aw_done <= 1'b1;
            if(S_w_hs)  S_w_done  <= 1'b1;
        end
    end

    // ---- user side ----
    assign O_ddr_user_ready    = S_calib_sync & (~S_fifo_pro_full);
    assign O_ddr_user_rd_valid = I_mc_app_rd_data_valid;
    assign O_ddr_user_rd_data  = I_mc_app_rd_data;

    // ---- diagnostics: user attempted / FIFO accepted / handshaken / responses ----
    reg [31:0] C_user_req, C_accepted, C_rd_hs, C_wr_hs, C_rsp;
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            C_user_req <= 32'd0;
            C_accepted <= 32'd0;
            C_rd_hs    <= 32'd0;
            C_wr_hs    <= 32'd0;
            C_rsp      <= 32'd0;
        end else begin
            if(S_fifo_wr_en)                C_user_req <= C_user_req + 1'b1;
            if(S_fifo_wr_en & ~S_fifo_full) C_accepted <= C_accepted + 1'b1;
            if(S_ar_hs)                     C_rd_hs    <= C_rd_hs + 1'b1;
            if(S_head_wr & S_wr_done)       C_wr_hs    <= C_wr_hs + 1'b1;
            if(I_mc_app_rd_data_valid)      C_rsp      <= C_rsp + 1'b1;
        end
    end

    assign O_rd_handshake = S_ar_hs;

endmodule
