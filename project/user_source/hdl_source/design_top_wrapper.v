

module design_top_wrapper #(
    parameter [5:0] SAT_K_Q4 = 6'd24,
    parameter AWB_ENABLE = 1,
    parameter [15:0] STARTUP_AE = 16'd1991,
    parameter [15:0] STARTUP_AG = 16'd144,
    parameter CB_EN = 1'b1,
    parameter [8:0] CB_G_A_Q8 = 9'd153,
    parameter [15:0] CB_G_B_OFF = 16'd2215,
    parameter SERVO_ENABLE = 1,
    parameter SERVO_INVERT_X = 1, // Fixed installation polarity; K3 controls axes display.
    parameter SERVO_INVERT_Y = 1, // 角度增大向上（图像 y 向下）
    parameter SERVO_HOME_X = 90,  // 2026-10-21：恢复原版上电角（此前 100/180 实验已回退）
    parameter SERVO_HOME_Y = 110  // 2026-10-28：上电/复位角，Y限位仍为[95,180]
) (
    input wire        I_sys_clk,
    input wire        I_rst_n,
      
    output wire       O_cam_scl,
    inout  wire       IO_cam_sda,
    output wire       O_cam_24m,
    output wire       O_cam_rst,
      
    inout wire [3:0]  I_button,          // Mode keys; SW1 OFF redirects K1..K4 to manual motion.
    input wire [3:0]  I_sw,              // 拨码：SW1..SW4 = A4/B4/E11/D11（SW3=E11、SW4=D11 用于边缘模式）

    output wire       O_pwm_x,           // J2-1 C18，水平舵机
    output wire       O_pwm_y,           // J2-2 D15，俯仰舵机
    output wire       O_screen_pwm,
    output wire [3:0] O_led,             // 跟踪状态灯 LED1~4 = D10/E10/C6/D6（低有效，原理图 P04_DIG_LED）
    output wire       O_tmds_ch0_p,
    output wire       O_tmds_ch1_p,
    output wire       O_tmds_ch2_p,
    output wire       O_tmds_clk_p,

    inout wire        IO_rx_clk_pad_n, 
    inout wire        IO_rx_clk_pad_p, 
    inout wire[3:0]   IO_rx_data_pad_n,
    inout wire[3:0]   IO_rx_data_pad_p,

    output wire[12:0] ddr_addr,
    output wire[ 1:0] ddr_ba,
    output wire[ 0:0] ddr_cke,
    output wire[ 0:0] ddr_odt,
    output wire[ 0:0] ddr_cs_n,
    output wire       ddr_ras_n,
    output wire       ddr_cas_n,
    output wire       ddr_we_n,
    output wire[ 0:0] ddr_ck_p,
    output wire[ 0:0] ddr_ck_n,
    inout wire[1:0]   ddr_dm,
    inout wire[15:0]  ddr_dq,
    inout wire[1:0]   ddr_dqs_p,
    inout wire[1:0]   ddr_dqs_n   
);


    wire        	S_100m_clk;
    wire        	S_24m_clk;
    wire        	S_aux_50m_clk;
		
	wire        	S_pll_lock;
    wire        	S_rst_n;
	reg  [17:0] 	S_cam_power_cnt;
	reg         	S_cam_pwdnb;
	reg         	S_cam_i2c_ready;
	(* keep = "true" *) wire [15:0] S_cam_sensor_id;
	(* keep = "true" *) wire        S_cam_sensor_id_ok;
	(* keep = "true" *) wire        S_cam_i2c_error;
	localparam integer CAM_PWDNB_LOW_CYCLES = 23810;  // >= 1 ms at 23.809524 MHz
	localparam integer CAM_I2C_START_CYCLES = 142857; // release + >= 5 ms
	
	wire [15:0] 	S_ae;
    wire [15:0] 	S_ag;
    wire 			S_cam_cfg_done;
    wire 			S_ae_cfg_done;
    wire 			S_ae_req; 
	
	wire        	S_csi_rx_clk;  
    wire        	S_hs_rx_valid;  
    wire[15:0]  	S_hs_rx_data;   
	wire[1:0]   	S_lane_error;
	
	wire        	S_csi_frame_start;       
	wire        	S_csi_frame_end;         
	wire        	S_csi_valid;             
	wire[31:0]  	S_csi_data;  
	(* keep = "true" *) wire [15:0] S_csi_data_length;
		
	wire        	S_raw10_frame_start; 
	wire        	S_raw10_frame_end;   
	wire        	S_raw10_valid;       
	wire [39:0] 	S_raw10_data;

	wire 			S_axis_tlast;  
	wire 			S_axis_tuser;  
	wire [39:0]		S_axis_tdata;  
	wire 			S_axis_tvalid; 
	
	wire [39:0]		S_raw_tdata ;
	wire			S_raw_tlast ;
	wire 			S_raw_tvalid;
	wire 			S_raw_tuser ;
	
	wire			S_ISP_O_tready;
	wire [127:0]	S_ISP_O_tdata ;
	wire 			S_ISP_O_tlast ;
	wire 			S_ISP_O_tuser ;
	wire 			S_ISP_O_tvalid; 
	

    wire        S_ddr_clk;
    wire        S_hdmi_pixel_clk;
    wire        S_hdmi_serial_clk;
    wire        S_hdmi_rst_n;
    wire        S_video_out_rst_n;


    wire        S_vi_128b_frame_start;
    wire        S_vi_128b_valid;      
    wire[127:0] S_vi_128b_data;    
    
    wire        S_video_out_rd_busy;
    wire        S_video_in_wr_busy; 
    wire[1:0]   S_video_out_rp;     

    wire        S_ddr_user_wr_en;       
    wire        S_ddr_user_rd_en;       
    wire[24:0]  S_ddr_user_addr;        
    wire[127:0] S_ddr_user_wr_data;     
    wire        S_ddr_user_ready;       
    wire        S_ddr_user_rd_valid;    
    wire[127:0] S_ddr_user_rd_data;     

    wire        S_vi_ddr_wr_en;   
    wire[24:0]  S_vi_ddr_wr_addr; 
    wire[127:0] S_vi_ddr_wr_data;
    wire        S_vi_ddr_wr_ready;

    wire        S_vo_ddr_rd_en;   
    wire[24:0]  S_vo_ddr_rd_addr; 
    wire        S_vo_ddr_rd_ready;

    wire        S_init_calib_complete; 
    wire[24:0]  S_mc_app_addr;
    wire[127:0] S_mc_app_wdf_data;
    wire        S_mc_app_wdf_end;
    wire[15:0]  S_mc_app_wdf_mask;
    wire[127:0] S_mc_app_rd_data;
    wire        S_mc_app_rd_data_end;
    wire        S_mc_app_rd_data_valid;
    wire        S_mc_ar_valid;
    wire        S_mc_aw_valid;
    wire        S_mc_w_valid;
    wire        S_mc_ar_ready;
    wire        S_mc_aw_ready;
    wire        S_mc_w_ready;
    wire        S_mc_rd_hs;

    wire        S_hdmi_vsync;
    wire        S_hdmi_hsync;
    wire        S_hdmi_de;
    wire        S_hdmi_user;
    wire        S_hdmi_last;
    wire        S_video_out_vsync;
    wire        S_hdmi_window_rd_en;
    wire        S_hdmi_out_vsync;
    wire        S_hdmi_out_hsync;
    wire        S_hdmi_out_de;
    wire[23:0]  S_hdmi_out_data;

    wire[23:0]  S_video_rd_data;
    wire        S_lane_error_any;
    wire        S_csi_packet_start;
    reg         S_csi_length_active_d;
    reg [10:0]  S_mipi_line_count;
    reg         S_mipi_length_error;
    reg         S_mipi_lane_error;
    reg         S_mipi_frame_seen;
    reg         S_mipi_frame_done;
    reg         S_mipi_last_length_error;
    reg         S_mipi_last_line_error;
    reg         S_mipi_last_lane_error;




    assign O_screen_pwm = 1'b1;
    assign S_video_out_vsync = ~S_hdmi_vsync;
	
	
    assign S_rst_n 		= S_pll_lock;
    assign S_hdmi_rst_n = S_pll_lock;

    assign S_lane_error_any = |S_lane_error;

    // ---- 评审#2（2026-10-05 第2批）：坏帧标志（按帧锁存，CSI 域）----
    // frame_end 发布、稳定一整帧；语义 = "上一帧坏"——正合 video_in 帧首回退采样点，
    // 也作为 AWB 拒采信（commit 门）依据。电平信号稳定一整帧，跨域采样安全。
    wire S_frame_bad = S_mipi_last_length_error | S_mipi_last_line_error | S_mipi_last_lane_error;

    // A RAW10 line contains 1280 * 10 / 8 = 1600 bytes.  The CSI parser
    // reports the number of 16-bit lane words, therefore the expected value
    // is 1600 / 2 = 800 = 16'h0320.  Count one long packet whenever that
    // decoded length changes from zero to non-zero.
    assign S_csi_packet_start = (S_csi_data_length != 16'd0) &&
                                !S_csi_length_active_d;

    always @(posedge S_csi_rx_clk or negedge S_rst_n) begin
        if(!S_rst_n) begin
            S_csi_length_active_d      <= 1'b0;
            S_mipi_line_count          <= 11'd0;
            S_mipi_length_error        <= 1'b0;
            S_mipi_lane_error          <= 1'b0;
            S_mipi_frame_seen          <= 1'b0;
            S_mipi_frame_done          <= 1'b0;
            S_mipi_last_length_error   <= 1'b0;
            S_mipi_last_line_error     <= 1'b0;
            S_mipi_last_lane_error     <= 1'b0;
        end
        else begin
            S_csi_length_active_d <= (S_csi_data_length != 16'd0);

            if(S_csi_frame_start) begin
                S_mipi_line_count   <= 11'd0;
                S_mipi_length_error <= 1'b0;
                S_mipi_lane_error   <= 1'b0;
                S_mipi_frame_seen   <= 1'b1;
            end
            else begin
                if(S_csi_packet_start) begin
                    S_mipi_line_count <= S_mipi_line_count + 11'd1;
                    if(S_csi_data_length != 16'h0320)
                        S_mipi_length_error <= 1'b1;
                end

                if(S_lane_error_any)
                    S_mipi_lane_error <= 1'b1;
            end

            // Publish only a completed frame, so the HDMI-domain diagnostic
            // sees a stable result rather than counters changing every line.
            if(S_csi_frame_end) begin
                S_mipi_frame_done        <= 1'b1;
                S_mipi_last_length_error <= S_mipi_length_error;
                S_mipi_last_line_error   <= (S_mipi_line_count != 11'd720);
                S_mipi_last_lane_error   <= S_mipi_lane_error |
                                            S_lane_error_any;
            end
        end
    end

	
	// J9 pin 37 is connected to the module's PWDNB/XSHUTDN input.
	// Hold the sensor in power-down after PLL lock, then allow its internal
	// power-up sequence to finish before the first I2C transaction.
	always @(posedge S_24m_clk or negedge S_pll_lock) begin
		if (!S_pll_lock) begin
			S_cam_power_cnt <= 18'd0;
			S_cam_pwdnb <= 1'b0;
			S_cam_i2c_ready <= 1'b0;
		end else begin
			if (S_cam_power_cnt < CAM_I2C_START_CYCLES)
				S_cam_power_cnt <= S_cam_power_cnt + 1'b1;
			if (S_cam_power_cnt >= CAM_PWDNB_LOW_CYCLES)
				S_cam_pwdnb <= 1'b1;
			if (S_cam_power_cnt >= CAM_I2C_START_CYCLES - 1)
				S_cam_i2c_ready <= 1'b1;
		end
	end

	assign O_cam_rst 	= S_cam_pwdnb;
    assign O_cam_24m 	= S_24m_clk;
	
	
	
	
    PLL u_PLL(
        .refclk      ( I_sys_clk         ),
        .reset    	 ( ~I_rst_n          ),
        
        .clk0_out    ( S_100m_clk        ),
        .clk1_out    ( S_24m_clk         ),

        .clk4_out    ( S_hdmi_pixel_clk  ),
        .clk5_out    ( S_hdmi_serial_clk ),

        .lock        ( S_pll_lock        )

    );


	

  
    // ---- 拨码开关（静态输入）：2FF 同步到 ISP 时钟域 ----
    reg [3:0] S_sw_meta, S_sw_sync;
    reg [1:0] S_sw_ready;
    always @(posedge S_csi_rx_clk or negedge S_rst_n) begin
        if (!S_rst_n) begin S_sw_meta <= 4'd0; S_sw_sync <= 4'd0; S_sw_ready<=0; end
        else begin
            S_sw_meta <= I_sw;
            S_sw_sync <= S_sw_meta;
            S_sw_ready <= {S_sw_ready[0],1'b1};
        end
    end

    // ---- Video mode selection with frame-boundary commit. SW1 OFF holds it. ----
    //   全开            -> 无特殊算法（仅摄像头正常显示）
    //   仅 SW2 关       -> 灰度变换（饱和度 K=0 输出 BT.601 亮度 + CB 旁路）
    //   仅 SW3 关       -> four edge views
    //   仅 SW4 关       -> red/blue tracking
    //   其它组合        -> 原图（安全默认）
    //   解码规则与"帧首锁存 + 连续两帧一致才生效"见 algo_mode_ctrl.v
    wire [1:0] S_algo_mode;                        // 0 raw,1 edge,2 gray,3 tracking
    wire [1:0] S_gray_curve;                       // 0 linear,1 gamma,2 S,3 binary
    wire S_mode_normal   = (S_algo_mode == 2'd0);
    wire S_mode_edge     = (S_algo_mode == 2'd1);
    wire S_mode_gray     = (S_algo_mode == 2'd2);
    wire S_mode_tracking = (S_algo_mode == 2'd3);

    // ---- 跟踪分支（2026-10-11）：135bit 目标包（相机域）→ OSD（显示域）/ LED ----
    wire [134:0] S_det_pack;
    wire         S_det_load, S_det_valid;
    wire [10:0]  S_det_cx, S_det_cy;
    wire [15:0]  S_det_lost;
    wire [2:0]   S_track_preset;

    // ---- 按键去抖 + 模式内状态机（抽成 algo_btn_state 模块以便 TB 覆盖；见 axis_edge_mode_rgb96.v）----
    // 边缘四态：K3 黑白轮廓 / K2 叠加 / K4 卡通化 / K1 原图；灰度三档：K3 γ / K2 S 曲线 / K1 线性
    wire [1:0] S_edge_state;
    wire [1:0] S_gray_state;
    wire S_track_trail,S_track_axes,S_track_info;
    wire S_servo_inv_x,S_servo_inv_y;   // Runtime flips canceled; both remain zero.
    wire [3:0] S_btn_stable;            // 2026-10-22：去抖按键电平（低有效），手动云台用
    localparam [20:0] BUTTON_DEBOUNCE=21'd2000000;
    wire S_display_hold,S_manual_override,S_view_key_lock;
    wire[3:0]S_override_buttons;
    view_manual_gate #(.SW_ON_CYCLES(1000000),.KEY_RELEASE_CYCLES(BUTTON_DEBOUNCE+4)) u_view_manual_gate(
        .clk(S_csi_rx_clk),.rst_n(S_rst_n),.inputs_ready(S_sw_ready[1]),
        .sw1(S_sw_sync[0]),.raw_buttons(I_button),.stable_buttons(S_btn_stable),
        .display_hold(S_display_hold),.manual(S_manual_override),.key_lock(S_view_key_lock),.manual_buttons(S_override_buttons));
    algo_btn_state #(.DEBOUNCE_MAX(BUTTON_DEBOUNCE),.TWO_COLOR_TRACK(1),.KEY_LOCK_EN(1)) u_algo_btn_state (
        .I_clk      (S_csi_rx_clk),
        .I_rst_n    (S_rst_n),
        .I_button   (I_button),
        .I_key_lock (S_view_key_lock),
        .I_display_curve(S_gray_curve),
        .I_mode_edge(S_mode_edge),
        .I_mode_gray(S_mode_gray),
        .I_mode_track(S_mode_tracking),
        .O_edge_state(S_edge_state),
        .O_gray_state(S_gray_state),
        .O_track_preset(S_track_preset),
        .O_track_trail(S_track_trail),.O_track_axes(S_track_axes),.O_track_info(S_track_info),
        .O_inv_x(S_servo_inv_x),.O_inv_y(S_servo_inv_y),.O_btn_stable(S_btn_stable)
    );

    // 边缘级控制：仅"仅 SW3 关"时启用；四态由按键决定（K3/K2/K1/K4）
    // 非边缘模式强制 0（旁路），避免其它模式下按键状态影响输出
    wire [1:0] S_edge_state_eff = S_mode_edge ? S_edge_state : 2'd0;

    // 按键用途（2026-10-08 用户要求）：**取消按键调曝光/增益**，按键只用于边缘三态切换。
    // 因此送 ae_set 的按键恒为"无按键"（4'hF，低有效空闲值）——曝光/增益固定为启动档
    // （STARTUP_AE=1991 / STARTUP_AG=144，即厂商默认档），运行时不可调。

  ae_set #(.AE_DEFAULT(STARTUP_AE), .AG_DEFAULT(STARTUP_AG)) u_ae_set (
      .I_clk(S_24m_clk),
      .I_rst(~S_rst_n),
      .I_btn(4'hF),                   // 按键调曝光/增益已按需求取消（固定启动档 AE/AG）
      .I_cam_cfg_done(S_cam_cfg_done),
      .I_ae_cfg_done(S_ae_cfg_done),
      .O_ae_req(S_ae_req),
      .O_ae(S_ae),
      .O_ag(S_ag)
  );
  
    uicfgcs520 #(
      .CLK_DIV(23809524 / 100000 - 1)
  ) u_uicfgcs520 (
      .I_clk(S_24m_clk),  //系统时钟输入
      .I_rst_n(S_cam_i2c_ready), // SC520CS power-up delay completed
      .I_ae_req(S_ae_req),
      .I_ae(S_ae),
      .I_ag(S_ag),
      .O_cam_scl(O_cam_scl),  //I2C总线，SCL时钟
      .IO_cam_sda(IO_cam_sda),  //I2C总线，SDA数据
      .O_cfg_done(S_cam_cfg_done),  //摄像头寄存器初始化完成
      .O_ae_cfg_done(S_ae_cfg_done),  //AE配置完成
      .O_sensor_id(S_cam_sensor_id),
      .O_sensor_id_ok(S_cam_sensor_id_ok),
      .O_iic_error(S_cam_i2c_error)
  );
	
    mipi_dphy_rx_ph1p_mipiio_wrapper#(
        .DPHY_RX_LOCATION      ( "DPHY0" ),
        .HS_EQUALIZER          ( "3dB"   ),// 828 Mbps/Lane接收均衡
        .HS_VGA_GAIN           ( "8dB" ),//"-3dB","-1.5dB","0dB","1.5dB","3dB","4.5dB","6dB","7.5dB"
        .LANE_NUM              ( 2       ),
        .BYTE_NUM              ( 1       )
    )u_mipi_dphy_rx_ph1p_mipiio_wrapper(
        .I_lp_clk              ( S_100m_clk       ),
        .I_rst                 ( ~S_rst_n         ),

        .I_clk_lane_in_delay   ( 6'd0             ),
        .I_data_lane0_in_delay ( 6'd0             ),
        .I_data_lane1_in_delay ( 6'd0             ),
        .I_data_lane2_in_delay ( 6'd0             ),
        .I_data_lane3_in_delay ( 6'd0             ),

        .I_lane_invert         ( 4'b0000          ),
     
        .O_hs_rx_clk           ( S_csi_rx_clk     ),
        .O_hs_rx_valid         ( S_hs_rx_valid    ),
        .O_hs_rx_data          ( S_hs_rx_data     ),
      
        .O_lp_rx_lane0_p       (  ),
        .O_lp_rx_lane0_n       (  ),
      
        .I_lp_tx_en            ( 1'b0             ),
        .I_lp_tx_lane0_p       ( 1'b1             ),
        .I_lp_tx_lane0_n       ( 1'b1             ),
      
        .O_lane_match_error    (                  ),
        .O_lane_error          ( S_lane_error     ),
      
        .IO_rx_clk_pad_n       ( IO_rx_clk_pad_n  ),
        .IO_rx_clk_pad_p       ( IO_rx_clk_pad_p  ),
        .IO_rx_data_pad_n      ( IO_rx_data_pad_n ),
        .IO_rx_data_pad_p      ( IO_rx_data_pad_p )
    );
	
	
 //  cwc cwc_inst
 //(
 //    .probe0(S_hs_rx_valid),
 //    .probe1(S_hs_rx_data),
 //    .probe2(S_lane_error),
 //    .clk(S_csi_rx_clk)
 //);

 //csi 解码为RAW数据
csi_unpacket_2lane u_csi_unpacket(
.I_clk                 ( S_csi_rx_clk       ),
.I_rst_n               ( S_rst_n        	),
.I_hs_valid            ( S_hs_rx_valid     ),
.I_hs_data             ( S_hs_rx_data      ),

.O_csi_frame_start     ( S_csi_frame_start ),
.O_csi_frame_end       ( S_csi_frame_end   ),
.O_csi_valid           ( S_csi_valid       ),
.O_csi_data            ( S_csi_data        ),
.O_data_length         ( S_csi_data_length )
);


//解码为RAW8
raw10_unpacket_2lane u_raw10_unpacket (
.I_clk  (S_csi_rx_clk),
.I_rst_n(S_rst_n),

.I_csi_frame_start(S_csi_frame_start),
.I_csi_frame_end  (S_csi_frame_end),
.I_csi_valid      (S_csi_valid),
.I_csi_data       (S_csi_data),

.O_raw10_frame_start(S_raw10_frame_start),
.O_raw10_frame_end  (S_raw10_frame_end),
.O_raw10_valid      (S_raw10_valid),
.O_raw10_data       (S_raw10_data)
  );


//将数据转为stream流
uial2axis #(
.IMG_WIDTH(1280),
.IMG_HEIGHT(720),
.INPUT_DATA_WIDTH(40)
) 
u_uial2axis (
.I_native_clk(S_csi_rx_clk),
.I_rst_n     (S_rst_n),
.I_data      (S_raw10_data       ),
.I_data_valid(S_raw10_valid      ),
.I_data_start(S_raw10_frame_start),
.I_data_end  (S_raw10_frame_end  ),
.axis_tvalid (S_axis_tvalid),
.axis_tdata  (S_axis_tdata ),
.axis_tuser  (S_axis_tuser ),
.axis_tlast  (S_axis_tlast )
);
	

// SC520CS原厂HD模式已经直接输出1280x720 RAW10，无需FPGA窗口裁剪。
assign S_raw_tdata  = S_axis_tdata;
assign S_raw_tlast  = S_axis_tlast;
assign S_raw_tvalid = S_axis_tvalid;
assign S_raw_tuser  = S_axis_tuser;


//cwc1 cwc1_Inst
//  (
//      .probe0(S_axis_tuser),
//      .probe1(S_axis_tvalid),
//      .probe2(S_axis_tlast),
//      .probe3(S_axis_tdata),
//      .probe4(S_ISP_O_tuser),
//      .probe5(S_ISP_O_tvalid),
//      .probe6(S_ISP_O_tlast),
//      .probe7(S_ISP_O_tdata),
//      .probe8 (S_raw_tdata ),
//      .probe9 (S_raw_tlast ),
//      .probe10(S_raw_tvalid),
//      .probe11(S_raw_tuser ),
//      .clk(S_csi_rx_clk)
//  );


//ISP算法顶层模块

// 算法模式控制（解码 + 帧首锁存 + 连续两帧一致 + 排空保险；见 axis_edge_mode_rgb96.v 内 algo_mode_ctrl）
    algo_mode_ctrl #(.MANUAL_HOLD_EN(1)) u_algo_mode_ctrl (
        .I_clk        (S_csi_rx_clk),
        .I_rst_n      (S_rst_n),
        .I_sw         ({S_sw_sync[3:1],!S_display_hold}),
        .I_frame_start(S_raw_tuser),
        .I_data_valid (S_raw_tvalid),
        .I_curve      (S_gray_state),
        .O_mode       (S_algo_mode),
        .O_curve      (S_gray_curve)
    );

isp_top #(.SAT_K_Q4(SAT_K_Q4), .AWB_ENABLE(AWB_ENABLE), .CB_EN(CB_EN),
         .CB_G_A_Q8(CB_G_A_Q8), .CB_G_B_OFF(CB_G_B_OFF)) u_isp_top (
.axi4s_video_aclk(S_csi_rx_clk),
.I_rst_n         (S_rst_n),
.I_tlast         (S_raw_tlast	),
.I_tuser         (S_raw_tuser	),
.I_tdata         (S_raw_tdata	),
.I_tvalid        (S_raw_tvalid	),
.I_tdest         (10'd0),
.I_frame_bad     (S_frame_bad    ),
.O_tready        (1'b1),
.O_tdata         (S_ISP_O_tdata ),
.O_tlast         (S_ISP_O_tlast ),
.O_tuser         (S_ISP_O_tuser ),
.O_tvalid        (S_ISP_O_tvalid),
.I_tready        (),
.I_edge_state    (S_edge_state_eff),
.I_gray_mode     (S_mode_gray),
.I_curve_sel     (S_gray_curve),
.I_preset_idx    (S_track_preset),
.O_det_pack      (S_det_pack),
.O_det_load      (S_det_load),
.O_det_valid     (S_det_valid),
.O_det_cx        (S_det_cx),
.O_det_cy        (S_det_cy),
.O_det_lost      (S_det_lost)
  );


    video_in u_video_in(
        .I_rst_n              (  S_rst_n             ),

        .I_camera_clk         ( S_csi_rx_clk          ),
        .I_camera_frame_start ( S_ISP_O_tuser  ),
        .I_camera_valid       ( S_ISP_O_tvalid ),
        .I_camera_data        ( S_ISP_O_tdata  ),
        .I_mipi_rx_error      ( S_frame_bad       ),  // 第2批：接入按帧锁存坏帧标志

        .I_ddr_clk            ( S_ddr_clk             ),
		.I_display_pause      ( 1'b0                       ),
        .I_video_out_rd_busy  ( S_video_out_rd_busy  ),
        .O_video_in_wr_busy   ( S_video_in_wr_busy    ),
        .O_video_out_rp       ( S_video_out_rp        ),

        .O_ddr_user_wr_en     ( S_vi_ddr_wr_en        ),
        .O_ddr_user_addr      ( S_vi_ddr_wr_addr      ),
        .O_ddr_user_wr_data   ( S_vi_ddr_wr_data      ),
        .I_ddr_user_ready     ( S_ddr_user_ready      )
    );



    assign S_ddr_user_wr_en    = S_vi_ddr_wr_en;

    assign S_ddr_user_rd_en    = S_vo_ddr_rd_en;

    assign S_ddr_user_addr     = S_vi_ddr_wr_en ? S_vi_ddr_wr_addr :
                                 S_vo_ddr_rd_en ? S_vo_ddr_rd_addr : 'd0;

    assign S_ddr_user_wr_data  = S_vi_ddr_wr_data;


    assign S_video_out_rst_n = S_hdmi_rst_n;

    video_out u_video_out(
        .I_rst_n             ( S_video_out_rst_n    ),
        .I_ddr_clk           ( S_ddr_clk            ),
 
        .O_video_out_rd_busy ( S_video_out_rd_busy  ),
        .I_video_in_wr_busy  ( S_video_in_wr_busy   ),
        .I_video_out_rp      ( S_video_out_rp       ),
 
        .O_ddr_user_rd_en    ( S_vo_ddr_rd_en       ),
        .O_ddr_user_addr     ( S_vo_ddr_rd_addr     ),
        .I_ddr_user_ready    ( S_ddr_user_ready     ),
        .I_ddr_user_rd_valid ( S_ddr_user_rd_valid  ),
        .I_ddr_user_rd_data  ( S_ddr_user_rd_data   ),

        .I_dsi_clk           ( S_hdmi_pixel_clk     ),
        .I_video_vsync       ( S_video_out_vsync    ),
        .I_video_rd_en       ( S_hdmi_window_rd_en  ),
        .O_vdieo_data        ( S_video_rd_data      )
    );



    mc_to_user_interface u_mc_to_user_interface(
        .I_clk                   ( S_ddr_clk               ),
        .I_rst_n                 ( S_rst_n                 ),

        .I_ddr_user_wr_en        ( S_ddr_user_wr_en        ),
        .I_ddr_user_rd_en        ( S_ddr_user_rd_en        ),
        .I_ddr_user_addr         ( S_ddr_user_addr         ),
        .I_ddr_user_wr_data      ( S_ddr_user_wr_data      ),
        .O_ddr_user_ready        ( S_ddr_user_ready        ),
        .O_ddr_user_rd_valid     ( S_ddr_user_rd_valid     ),
        .O_ddr_user_rd_data      ( S_ddr_user_rd_data      ),
            
        .I_calib_complete        ( S_init_calib_complete  ),
        .O_mc_ar_valid           ( S_mc_ar_valid           ),
        .O_mc_aw_valid           ( S_mc_aw_valid           ),
        .O_mc_w_valid            ( S_mc_w_valid            ),
        .I_mc_ar_ready           ( S_mc_ar_ready           ),
        .I_mc_aw_ready           ( S_mc_aw_ready           ),
        .I_mc_w_ready            ( S_mc_w_ready            ),
        .O_rd_handshake          ( S_mc_rd_hs              ),
        .O_mc_app_addr           ( S_mc_app_addr           ),
        .O_mc_app_wdf_data       ( S_mc_app_wdf_data       ),
        .O_mc_app_wdf_end        ( S_mc_app_wdf_end        ),
        .O_mc_app_wdf_mask       ( S_mc_app_wdf_mask       ),
        .I_mc_app_rd_data        ( S_mc_app_rd_data        ),
        .I_mc_app_rd_data_end    ( S_mc_app_rd_data_end    ),
        .I_mc_app_rd_data_valid  ( S_mc_app_rd_data_valid  )
    );



    ph1p35_324_ddr_wrapper u_ph1p35_324_ddr_wrapper(
        .I_sys_clk              ( I_sys_clk              ),
        .I_sys_rst_n            ( S_rst_n                ),

        .O_ddr_clk              ( S_ddr_clk              ),
        .O_init_calib_complete  ( S_init_calib_complete  ),
        .I_mc_app_addr          ( S_mc_app_addr          ),
        .I_mc_ar_valid          ( S_mc_ar_valid          ),
        .I_mc_aw_valid          ( S_mc_aw_valid          ),
        .I_mc_w_valid           ( S_mc_w_valid           ),
        .I_mc_app_wdf_data      ( S_mc_app_wdf_data      ),
        .I_mc_app_wdf_end       ( S_mc_app_wdf_end       ),
        .I_mc_app_wdf_mask      ( S_mc_app_wdf_mask      ),
        .O_mc_app_rd_data       ( S_mc_app_rd_data       ),
        .O_mc_app_rd_data_end   ( S_mc_app_rd_data_end   ),
        .O_mc_app_rd_data_valid ( S_mc_app_rd_data_valid ),
        .O_mc_ar_ready          ( S_mc_ar_ready          ),
        .O_mc_aw_ready          ( S_mc_aw_ready          ),
        .O_mc_w_ready           ( S_mc_w_ready           ),

        .ddr_addr               ( ddr_addr               ),
        .ddr_ba                 ( ddr_ba                 ),
        .ddr_cke                ( ddr_cke                ),
        .ddr_odt                ( ddr_odt                ),
        .ddr_cs_n               ( ddr_cs_n               ),
        .ddr_ras_n              ( ddr_ras_n              ),
        .ddr_cas_n              ( ddr_cas_n              ),
        .ddr_we_n               ( ddr_we_n               ),
        .ddr_ck_p               ( ddr_ck_p               ),
        .ddr_ck_n               ( ddr_ck_n               ),
        .ddr_dm                 ( ddr_dm                 ),
        .ddr_dq                 ( ddr_dq                 ),
        .ddr_dqs_p              ( ddr_dqs_p              ),
        .ddr_dqs_n              ( ddr_dqs_n              )
    );



    uivtc #(
        .H_ActiveSize ( 1280 ),
        .H_FrameSize  ( 1650 ),
        .H_SyncStart  ( 1390 ),
        .H_SyncEnd    ( 1430 ),
        .V_ActiveSize ( 720  ),
        .V_FrameSize  ( 750  ),
        .V_SyncStart  ( 725  ),
        .V_SyncEnd    ( 730  )
    )u_hdmi_vtc(
        .I_vtc_rstn    ( S_hdmi_rst_n    ),
        .I_vtc_clk     ( S_hdmi_pixel_clk ),
        .O_vtc_vs      ( S_hdmi_vsync     ),
        .O_vtc_hs      ( S_hdmi_hsync     ),
        .O_vtc_de_valid( S_hdmi_de        ),
        .O_vtc_user    ( S_hdmi_user      ),
        .O_vtc_last    ( S_hdmi_last      )
    );

    hdmi_mixer #(
        .H_OFFSET   ( 0    ),
        .V_OFFSET   ( 0    ),
        .IMG_WIDTH  ( 1280 ),
        .IMG_HEIGHT ( 720  ),
        // Normal camera display.  Set to 4 only when the MIPI diagnostic
        // full-screen status page is needed.
        .DEBUG_MODE ( 0    )
    )u_hdmi_mixer(
        .I_clk           ( S_hdmi_pixel_clk   ),
        .I_rst_n         ( S_hdmi_rst_n       ),
        .I_video_vsync   ( S_hdmi_vsync       ),
        .I_video_hsync   ( S_hdmi_hsync       ),
        .I_video_de      ( S_hdmi_de          ),
        .I_video_user    ( S_hdmi_user        ),
        .I_video_last    ( S_hdmi_last        ),
        .I_debug_status  ( 4'd6                 ),
        .O_video_rd_en   ( S_hdmi_window_rd_en),
        .I_video_rd_data ( S_video_rd_data    ),
        .O_hdmi_vsync    ( S_hdmi_out_vsync   ),
        .O_hdmi_hsync    ( S_hdmi_out_hsync   ),
        .O_hdmi_de       ( S_hdmi_out_de      ),
        .O_hdmi_data     ( S_hdmi_out_data    )
    );

    // ---- UI 叠加层（logo 常驻左上角）：移植自 QQ/ui 工程，不动视频链路与边缘检测 ----
    wire [23:0] S_ui_page_data;
    wire        S_ui_page_vsync, S_ui_page_de;
    ui_logo_page u_ui_logo_page (
        .I_clk      ( S_hdmi_pixel_clk  ),
        .I_rst_n    ( S_hdmi_rst_n      ),
        .I_de       ( S_hdmi_out_de     ),
        .I_vsync    ( S_hdmi_out_vsync  ),
        .I_cam_data ( S_hdmi_out_data   ),
        .O_data     ( S_ui_page_data    ),
        .O_vsync    ( S_ui_page_vsync   ),
        .O_de       ( S_ui_page_de      )
    );

    // 舵机控制域使用原板载 50MHz；复位包含按键和 PLL 失锁。
    // 目标包原样窃取，视觉/UI 分支与像素时序不变。
    wire [7:0] S_servo_angle_x,S_servo_angle_y;
    wire S_servo_locked,S_servo_lost;
    wire [19:0] S_servo_ticks_x,S_servo_ticks_y;
    // Manual: all switches ON (raw view), or SW1 OFF (preserve current view).
    // K1 up/K2 down/K3 left/K4 right; unchanged50Hz continuous fine steps.
    // SW1 OFF keeps the current live view and takes the keys for manual motion.
    // Existing all-ON manual mode is retained.
    wire S_mode_manual = S_sw_ready[1] && ((S_sw_sync == 4'b1111) || S_manual_override);
    track_servo_ctrl #(.SMOOTH_EN(1),.MAN_SMOOTH_EN(1),.STABILITY_EN(5),.MAX_STEP(4),.INVERT_X(SERVO_INVERT_X),.INVERT_Y(SERVO_INVERT_Y),
        .HOME_X(SERVO_HOME_X),.HOME_Y(SERVO_HOME_Y)) u_track_servo(
        .i_det_clk(S_csi_rx_clk),.i_clk_50m(I_sys_clk),.i_arst_n(I_rst_n & S_pll_lock),
        .i_tracking(S_mode_tracking && SERVO_ENABLE && !S_display_hold),.i_preset(S_track_preset),
        .i_frame_bad(S_frame_bad),.i_result_load(S_det_load),.i_result(S_det_pack),
        .i_inv_x(S_servo_inv_x),.i_inv_y(S_servo_inv_y),
        .i_manual_en(S_mode_manual && SERVO_ENABLE),.i_btn(S_manual_override?S_override_buttons:S_btn_stable),
        .o_pwm_x(O_pwm_x),.o_pwm_y(O_pwm_y),.o_angle_x(S_servo_angle_x),.o_angle_y(S_servo_angle_y),
        .o_locked(S_servo_locked),.o_lost(S_servo_lost),.o_ticks_x(S_servo_ticks_x),.o_ticks_y(S_servo_ticks_y));

    // ---- 跟踪 OSD 叠加层（2026-10-11）：挂在 logo 之后、hdmi_tx 之前 ----
    // 优先级：文字 > 十字 > 框 > Logo > 底图（logo 已烧进底图，osd_track 画跟踪图形）
    wire        S_vpix_valid, S_vpix_sof, S_vpix_eol;
    wire [10:0] S_vpix_x;
    vpix_de_vsync #(.IMG_WIDTH(1280)) u_vpix (
        .I_clk(S_hdmi_pixel_clk), .I_rst_n(S_hdmi_rst_n),
        .I_de(S_ui_page_de), .I_vsync(S_ui_page_vsync),
        .O_valid(S_vpix_valid), .O_sof(S_vpix_sof), .O_eol(S_vpix_eol), .O_x(S_vpix_x)
    );

    wire [134:0] S_display_pack;wire S_display_load;
    wire        S_osd_valid, S_osd_sof, S_osd_eol;
    wire [23:0] S_osd_data;
    // 【SC520 本工程改动 v16】跟踪模式：稳定框 + 中心坐标轴。
    osd_track #(.IMG_WIDTH(1280), .IMG_HEIGHT(720), .AXIS_EN(1), .STABILIZE_EN(1)) u_osd_track (
        .I_clk(S_hdmi_pixel_clk), .I_rst_n(S_hdmi_rst_n),
        .I_valid(S_vpix_valid), .I_sof(S_vpix_sof), .I_eol(S_vpix_eol), .I_data(S_ui_page_data),
        .I_det_clk(S_csi_rx_clk), .I_det_rst_n(S_rst_n),
        .I_det_pack(S_det_pack), .I_det_load(S_det_load), .O_det_busy(),
        .I_bright(7'd0), .I_contrast(8'd64),
        .O_valid(), .O_sof(), .O_eol(), .O_data(),
        .O_display_pack(S_display_pack),.O_display_load(S_display_load)
    );

    // Unified white UI: atomic config CDC; same 3-cycle pixel/sync delay in every mode.
    wire [11:0] ui_cfg_src={S_algo_mode,S_edge_state,S_gray_state,S_track_preset,S_track_trail,S_track_axes,S_track_info};
    reg [11:0] ui_cfg_sent,ui_cfg_packet;reg ui_cfg_load;wire ui_cfg_busy;
    wire [11:0] ui_cfg_dst;wire ui_cfg_update;
    always @(posedge S_csi_rx_clk or negedge S_rst_n)begin
      if(!S_rst_n)begin ui_cfg_sent<=12'hfff;ui_cfg_packet<=0;ui_cfg_load<=0;end
      else begin ui_cfg_load<=0;
        if(!ui_cfg_busy&&!ui_cfg_load&&ui_cfg_src!=ui_cfg_sent)begin
          ui_cfg_sent<=ui_cfg_src;ui_cfg_packet<=ui_cfg_src;ui_cfg_load<=1;
        end
      end
    end
    cdc_4phase #(.WIDTH(12)) u_ui_cfg_cdc(
      .I_clk_src(S_csi_rx_clk),.I_rst_src_n(S_rst_n),.I_src_data(ui_cfg_packet),.I_src_load(ui_cfg_load),.O_src_busy(ui_cfg_busy),
      .I_clk_dst(S_hdmi_pixel_clk),.I_rst_dst_n(S_hdmi_rst_n),.O_dst_data(ui_cfg_dst),.O_dst_valid(ui_cfg_update));
    wire [23:0] S_hdmi_final_data;wire S_hdmi_final_de,S_hdmi_final_vsync;
    wire [3:0] S_led_state;   // 【改动 2026-10-14】LED 逻辑态（1=应亮），供 ui_hud 图例
    ui_hud_v17_r1 u_ui_hud(
      .clk(S_hdmi_pixel_clk),.rst_n(S_hdmi_rst_n),.iv(S_vpix_valid),.iu(S_vpix_sof),.il(S_vpix_eol),.ivs(S_ui_page_vsync),.id(S_ui_page_data),
      .config_data(ui_cfg_dst),.config_load(ui_cfg_update),.result_data(S_display_pack),.result_load(S_display_load),.led_n(S_led_state),
      .ov(S_hdmi_final_de),.ou(),.ol(),.ovs(S_hdmi_final_vsync),.od(S_hdmi_final_data));

    // ---- 跟踪状态指示灯（F4；相机域；低有效）----
    // 【本工程改动 2026-10-14】LED_ACTIVE_LOW=0：本板物理 LED 实测为**高有效**（原低有效假设下上板行为完全相反）。
    // O_led_state = 逻辑态（1=应亮），送给 ui_hud 画屏幕圆点，使圆点与物理极性解耦。
    led_indicator #(
        .DEADZONE(11'd25), .LOCK_N(4'd8), .HEART_HALF(26'd51_750_000),
        .CX0(11'd640), .CY0(11'd360), .LOST_TH(16'd180),
        .LED_ACTIVE_LOW(1'b0)
    ) u_led_indicator (
        .I_clk(S_csi_rx_clk), .I_rst_n(S_rst_n),
        .I_pll_lock(S_pll_lock),
        .I_pack_load(S_det_load), .I_target_valid(S_det_valid),
        .I_cx(S_det_cx), .I_cy(S_det_cy),
        .I_lost_cnt(S_det_lost), .I_frame_bad(S_frame_bad),
        .O_led(O_led), .O_led_state(S_led_state)
    );

    hdmi_tx u_hdmi_tx(
        .I_pixel_clk        ( S_hdmi_pixel_clk  ),
        .I_serial_clk       ( S_hdmi_serial_clk ),
        .I_rst              ( ~S_hdmi_rst_n     ),
        .I_key_in           ( 1'b0              ),
        .I_edid_read_trig   ( 1'b0              ),
        .O_edid_read_valid  (                   ),
        .O_edid_read_data   (                   ),
        .I_video_rgb_enable ( 1'b1              ),
        .I_video_in_vs      ( S_hdmi_final_vsync ),
        .I_video_in_de      ( S_hdmi_final_de    ),
        .I_video_in_user    ( 1'b0              ),
        .I_video_in_valid   ( 1'b0              ),
        .I_video_in_last    ( 1'b0              ),
        .O_video_in_ready   (                   ),
        .I_video_in_data    ( S_hdmi_final_data ),
        .I_audio_valid      ( 1'b0              ),
        .I_audio_left_data  ( 24'd0             ),
        .I_audio_right_data ( 24'd0             ),
        .I_i2s_BCLK         ( 1'b0              ),
        .I_i2s_LRCK         ( 1'b0              ),
        .I_i2s_DOUT         ( 1'b0              ),
        .O_ddc_scl          (                   ),
        .O_hdmi_clk_p       (                   ),
        .O_hdmi_tx_p        (                   ),
        .O_tmds_ch0_p       ( O_tmds_ch0_p      ),
        .O_tmds_ch1_p       ( O_tmds_ch1_p      ),
        .O_tmds_ch2_p       ( O_tmds_ch2_p      ),
        .O_tmds_clk_p       ( O_tmds_clk_p      )
    );

    

    
    
    
    
    
endmodule
