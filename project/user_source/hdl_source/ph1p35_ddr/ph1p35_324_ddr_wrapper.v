// -----------------------------------------------------------------------------
// R4 DDR wrapper: pure channel mapping between the command bridge and the
// vendor DDR hard-IP (ddr2). VALID/READY are per channel and never cross-gated;
// the bridge owns command ordering and dequeue (see mc_to_user_interface.v).
// -----------------------------------------------------------------------------
module ph1p35_324_ddr_wrapper (
    input wire         I_sys_clk,
    input wire         I_sys_rst_n,

    output wire        O_ddr_clk,
    output  wire       O_init_calib_complete,

    input  wire[24:0]  I_mc_app_addr,
    input  wire[127:0] I_mc_app_wdf_data,
    input  wire        I_mc_app_wdf_end,
    input  wire[15:0]  I_mc_app_wdf_mask,

    // per-channel command VALID (held stable by the bridge until handshake)
    input  wire        I_mc_ar_valid,
    input  wire        I_mc_aw_valid,
    input  wire        I_mc_w_valid,

    // per-channel READY back to the bridge
    output wire        O_mc_ar_ready,
    output wire        O_mc_aw_ready,
    output wire        O_mc_w_ready,

    // response path
    output wire[127:0] O_mc_app_rd_data,
    output wire        O_mc_app_rd_data_end,
    output wire        O_mc_app_rd_data_valid,

// DDR3 signals
    output wire[12:0]  ddr_addr,
    output wire[1:0]   ddr_ba,
    output wire        ddr_cke,
    output wire        ddr_odt,
    output wire        ddr_cs_n,
    output wire        ddr_ras_n,
    output wire        ddr_cas_n,
    output wire        ddr_we_n,
    output wire        ddr_ck_p,
    output wire        ddr_ck_n,
    inout wire[1:0]    ddr_dm,
    inout wire[15:0]   ddr_dq,
    inout wire[1:0]    ddr_dqs_p,
    inout wire[1:0]    ddr_dqs_n   

);

    wire         ddrphy_rdy;

    wire dhi_clk;
    wire [24:0]  paxi_awaddr;
    wire         paxi_awvalid;
    wire         paxi_awready;
       
    wire [127:0] paxi_wdata;
    wire [15:0]  paxi_wstrb;
    wire         paxi_wvalid;
    wire         paxi_wlast;
    wire         paxi_wready;
                                 
    wire [24:0]  paxi_araddr;
    wire         paxi_arvalid;
    wire         paxi_arready;

    wire [127:0] paxi_rdata;
    wire         paxi_rlast;
    wire         paxi_rvalid;
    wire         paxi_rready;                                    

    assign O_init_calib_complete = ddrphy_rdy;
    assign O_ddr_clk = dhi_clk;

    // write address channel (VALID held by the bridge until AWREADY)
    assign paxi_awaddr              = I_mc_app_addr                              ;
    assign paxi_awvalid             = I_mc_aw_valid                              ;
    // write data channel (independent of the address channel)
    assign paxi_wdata               = I_mc_app_wdf_data                          ;
    assign paxi_wstrb               = I_mc_app_wdf_mask                          ;
    assign paxi_wvalid              = I_mc_w_valid                               ;
    assign paxi_wlast               = I_mc_app_wdf_end                           ;
    // read address channel
    assign paxi_araddr              = I_mc_app_addr                              ;
    assign paxi_arvalid             = I_mc_ar_valid                              ;
    assign paxi_rready              = 1'b1                                       ;

    assign O_mc_app_rd_data        = paxi_rdata                                  ;
    assign O_mc_app_rd_data_end    = paxi_rlast                                  ;
    assign O_mc_app_rd_data_valid  = paxi_rvalid                                 ;

    assign O_mc_ar_ready           = paxi_arready                                ;
    assign O_mc_aw_ready           = paxi_awready                                ;
    assign O_mc_w_ready            = paxi_wready                                 ;


    ddr2 u_ddr2 (
        .ref_clk      ( I_sys_clk    ),
        .sys_rst_n    ( I_sys_rst_n  ),
        .apb_pclk     ( I_sys_clk    ),
        .apb_prst_n   ( I_sys_rst_n  ),                 
        .dhi_clk      ( dhi_clk      ),
        .cfg_clk      (  ),
        .ddrphy_rst_n (  ),
        .ddrphy_rdy   ( ddrphy_rdy   ),

        .paxi_awaddr  ( paxi_awaddr  ),
        .paxi_awvalid ( paxi_awvalid ),
        .paxi_awready ( paxi_awready ),
        .paxi_wdata   ( paxi_wdata   ),
        .paxi_wstrb   ( paxi_wstrb   ),
        .paxi_wvalid  ( paxi_wvalid  ),
        .paxi_wlast   ( paxi_wlast   ),
        .paxi_wready  ( paxi_wready  ),
        .paxi_araddr  ( paxi_araddr  ),
        .paxi_arvalid ( paxi_arvalid ),
        .paxi_arready ( paxi_arready ),
        .paxi_rdata   ( paxi_rdata   ),
        .paxi_rlast   ( paxi_rlast   ),
        .paxi_rvalid  ( paxi_rvalid  ),
        .paxi_rready  ( paxi_rready  ),

        .ddr_ck_p     ( ddr_ck_p     ),
        .ddr_ck_n     ( ddr_ck_n     ),
        .ddr_cke      ( ddr_cke      ),
        .ddr_odt      ( ddr_odt      ),
        .ddr_cs_n     ( ddr_cs_n     ),
        .ddr_ras_n    ( ddr_ras_n    ),
        .ddr_cas_n    ( ddr_cas_n    ),
        .ddr_we_n     ( ddr_we_n     ),
        .ddr_ba       ( ddr_ba       ),
        .ddr_addr     ( ddr_addr     ),
        .ddr_dqs_p    ( ddr_dqs_p    ),
        .ddr_dqs_n    ( ddr_dqs_n    ),
        .ddr_dq       ( ddr_dq       ),
        .ddr_dm       ( ddr_dm       )
    );




endmodule
