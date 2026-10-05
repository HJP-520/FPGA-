// Manual exposure/gain controller. Active-low keys:
// KEY1 exposure-, KEY2 exposure+, KEY3 gain-, KEY4 gain+.
// Defaults retain the known 720p exposure range but remove the old 16x
// startup gain. This is manual control, not a closed-loop auto-exposure.
module ae_set #(
    parameter integer CLK_HZ = 23809524,
    parameter integer DEBOUNCE_MS = 10,
    parameter [15:0] AE_DEFAULT = 16'd1991,
    parameter [15:0] AG_DEFAULT = 16'd16,
    parameter [15:0] AE_MIN = 16'd2, AE_MAX = 16'd1991,
    parameter [15:0] AG_MIN = 16'd16, AG_MAX = 16'd176
)(
    input wire I_clk, I_rst,
    input wire [3:0] I_btn,
    input wire I_ae_cfg_done, I_cam_cfg_done,
    output reg O_ae_req,
    output reg [15:0] O_ae, O_ag
);
    localparam integer DB_CYC = (CLK_HZ / 1000 * DEBOUNCE_MS < 1) ? 1 : CLK_HZ / 1000 * DEBOUNCE_MS;
    localparam integer AE_CYC = (CLK_HZ / 250 < 1) ? 1 : CLK_HZ / 250;
    localparam integer AG_CYC = (CLK_HZ / 1000 * 128 < 1) ? 1 : CLK_HZ / 1000 * 128;
    (* async_reg = "true" *) reg [3:0] btn_sync1, btn_sync2;
    reg [3:0] btn_stable, btn_prev;
    reg [31:0] db_count [0:3];
    reg [31:0] ae_count, ag_count;
    reg [15:0] r_ae_set, r_ag_set;
    reg initial_write;
    wire [3:0] pressed = btn_stable & ~btn_prev;
    wire ae_tick = (ae_count == AE_CYC-1);
    wire ag_tick = (ag_count == AG_CYC-1);
    integer i;
    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin
            btn_sync1 <= 0; btn_sync2 <= 0;
            btn_stable <= 0; btn_prev <= 0;
            ae_count <= 0; ag_count <= 0;
            for (i=0;i<4;i=i+1) db_count[i] <= 0;
            r_ae_set <= AE_DEFAULT; r_ag_set <= AG_DEFAULT;
            O_ae <= AE_DEFAULT; O_ag <= AG_DEFAULT;
            O_ae_req <= 0; initial_write <= 1;
        end else begin
            btn_sync1 <= ~I_btn;
            btn_sync2 <= btn_sync1;
            btn_prev <= btn_stable;
            for (i=0;i<4;i=i+1) begin
                if (btn_sync2[i] == btn_stable[i]) db_count[i] <= 0;
                else if (db_count[i] == DB_CYC-1) begin
                    btn_stable[i] <= btn_sync2[i];
                    db_count[i] <= 0;
                end else db_count[i] <= db_count[i]+1;
            end
            ae_count <= ae_tick ? 0 : ae_count+1;
            ag_count <= ag_tick ? 0 : ag_count+1;
            // Opposing keys pressed together cancel; all steps saturate.
            if (btn_stable[0] && !btn_stable[1] && (pressed[0] || ae_tick))
                if (r_ae_set > AE_MIN) r_ae_set <= r_ae_set-1;
            if (btn_stable[1] && !btn_stable[0] && (pressed[1] || ae_tick))
                if (r_ae_set < AE_MAX) r_ae_set <= r_ae_set+1;
            if (btn_stable[2] && !btn_stable[3] && (pressed[2] || ag_tick))
                if (r_ag_set > AG_MIN) r_ag_set <= r_ag_set-1;
            if (btn_stable[3] && !btn_stable[2] && (pressed[3] || ag_tick))
                if (r_ag_set < AG_MAX) r_ag_set <= r_ag_set+1;
            O_ae_req <= 0;
            if (!O_ae_req && I_cam_cfg_done && I_ae_cfg_done &&
                (initial_write || O_ae != r_ae_set || O_ag != r_ag_set)) begin
                O_ae <= r_ae_set; O_ag <= r_ag_set;
                O_ae_req <= 1; initial_write <= 0;
            end
        end
    end
endmodule
