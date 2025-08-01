// Copyright © 2025 Manuel Rodríguez & Zero-Day Labs, Lda.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// Licensed under the Solderpad Hardware License v 2.1 (the “License”); 
// you may not use this file except in compliance with the License, 
// or, at your option, the Apache License version 2.0. 
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/.
// Unless required by applicable law or agreed to in writing, 
// any work distributed under the License is distributed on an “AS IS” BASIS, 
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. 
// See the License for the specific language governing permissions and limitations under the License.
//
// Author: Manuel Rodríguez <manuel.cederog@gmail.com>
// Date: 20/01/2025
// Acknowledges: SSRC - Technology Innovation Institute (TII)
//
// Description: Device Directory Walker (DDTW) for the RISC-V IOMMU.
//              This module walks memory to locate DCs and updates the DDTC

import rv_iommu_reg_pkg::*;

module rv_iommu_ddtw #(

    /// RISC-V IOMMU configuration struct
    parameter rv_iommu_cfg::rv_iommu_cfg_t RVIOMMUCfg = rv_iommu_cfg::NullCfg,

    /// Address data type
    parameter type addr_t = logic,
    /// Physical address data type
    parameter type paddr_t = logic,
    /// Device Context type
    parameter type dc_t         = logic,
    /// DDTC update structure type
    parameter type ddtc_up_t    = logic,

    /// AXI data types
    parameter type axi_req_t = logic,
    parameter type axi_resp_t = logic
) (
    input  logic                clk_i,
    input  logic                rst_ni,

    // Init DDTW
    input  logic                init_ddtw_i,
    
    // Error signaling
    output logic                active_o,
    output logic                error_o,
    output rv_iommu::cause_t    cause_code_o,

    // DC checks
    input  iommu_reg2hw_capabilities_reg_t  capabilities_i,
    input  iommu_reg2hw_fctl_reg_t          fctl_i,
    input  iommu_reg2hw_ddtp_reg_t          ddtp_i,

    // Update logic
    output ddtc_up_t            update_o,

    // Tags
    input  rv_iommu::device_id_t    req_did_i,

    // Implicit second-stage translations
    output logic                imp_init_o,
    output rv_iommu::ppn_t      pdt_gppn_o,
    output rv_iommu::ppn_t      iohgatp_ppn_fw_o,
    input  logic                imp_done_i,
    input  logic                imp_err_i,
    input  rv_iommu::ppn_t      pdt_ppn_i,

    // Memory interface
    input  axi_resp_t   mem_resp_i,
    output axi_req_t    mem_req_o
);

    localparam int unsigned PLEN = RVIOMMUCfg.PAddrWidth;
    localparam int unsigned PPNW = PLEN-12;

    // DDTW states
    typedef enum logic[2:0] {
      IDLE          = 3'b000,
      MEM_ACCESS    = 3'b001,
      NON_LEAF      = 3'b010,
      LEAF          = 3'b011,
      UPDATE        = 3'b100,
      ERROR         = 3'b101
    } ddtw_state_t;
    ddtw_state_t state_q, state_n;

    // IOMMU mode and DDT levels
    typedef enum logic [2:0] {
        OFF     = 3'b000,
        BARE    = 3'b001, 
        LVL1    = 3'b010, 
        LVL2    = 3'b011, 
        LVL3    = 3'b100
    } ddtw_level_t;
    ddtw_level_t ddt_lvl_q, ddt_lvl_n;

    // Physical pointer to access memory bus
    paddr_t ddtw_pptr_q, ddtw_pptr_n;
    // Last DDT level
    logic is_last_ddt_lvl;
    assign is_last_ddt_lvl = (ddt_lvl_q == LVL1);
    // Aux counter to know how many DWs we have loaded
    logic [2:0] entry_cnt_q, entry_cnt_n;
    // DDTW is walking
    assign active_o = (state_q != IDLE);

    // Cause code propagation
    rv_iommu::cause_t cause_q, cause_n;
    assign cause_code_o = cause_q;
    // To know whether we have to wait for the AXI transaction to complete upon error
    logic wait_rlast_q, wait_rlast_n;
    // MSI config checks
    logic en_msi_check;
    logic msi_check_error;

    // Update registers
    dc_t up_dc_content;
    rv_iommu::tc_t      dc_tc_q,        dc_tc_n;
    rv_iommu::iohgatp_t dc_iohgatp_q,   dc_iohgatp_n;
    rv_iommu::dc_ta_t   dc_ta_q,        dc_ta_n;
    rv_iommu::fsc_t     dc_fsc_q,       dc_fsc_n;
    assign up_dc_content.tc         = dc_tc_q;
    assign up_dc_content.iohgatp    = dc_iohgatp_q;
    assign up_dc_content.ta         = dc_ta_q;
    assign up_dc_content.fsc        = dc_fsc_q;

    // Second-stage mode
    logic en_S2;
    assign en_S2 = (dc_iohgatp_q.mode != 4'b0000);

    // Cast read port to corresponding data structure
    rv_iommu::tc_t          dc_tc;
    rv_iommu::iohgatp_t     dc_iohgatp;
    rv_iommu::dc_ta_t       dc_ta;
    rv_iommu::fsc_t         dc_fsc;
    rv_iommu::nl_entry_t    nl;
    assign dc_tc        = rv_iommu::tc_t'(mem_resp_i.r.data[((64*0) & (RVIOMMUCfg.AxiDataWidth-1))+:64]);
    assign dc_iohgatp   = rv_iommu::iohgatp_t'(mem_resp_i.r.data[((64*1) & (RVIOMMUCfg.AxiDataWidth-1))+:64]);
    assign dc_ta        = rv_iommu::dc_ta_t'(mem_resp_i.r.data[((64*2) & (RVIOMMUCfg.AxiDataWidth-1))+:64]);
    assign dc_fsc       = rv_iommu::fsc_t'(mem_resp_i.r.data[((64*3) & (RVIOMMUCfg.AxiDataWidth-1))+:64]);
    assign nl           = rv_iommu::nl_entry_t'(mem_resp_i.r.data);

    // Implicit second-stage translation
    logic imp_active_q, imp_active_n;
    assign pdt_gppn_o       = dc_fsc_q.ppn;
    assign iohgatp_ppn_fw_o = dc_iohgatp_q.ppn;

    // Edge-triggered init control
    logic edge_trigger_q, edge_trigger_n;
    always_comb begin : ddtw_init_control

        edge_trigger_n = edge_trigger_q;
        if (!edge_trigger_q && init_ddtw_i)
            edge_trigger_n = 1'b1;
        if (edge_trigger_q && !init_ddtw_i)
            edge_trigger_n = 1'b0;
    end

    //------------------------------
    // DDTW FSM combinational logic
    //------------------------------
    always_comb begin : ddtw_fsm_comb

        // default assignments
        // AW
        mem_req_o.aw            = '0;
        mem_req_o.aw_valid      = 1'b0;

        // W
        mem_req_o.w             = '0;
        mem_req_o.w_valid       = 1'b0;

        // B
        mem_req_o.b_ready       = 1'b1;

        // AR
        mem_req_o.ar            = '0;
        mem_req_o.ar.id         = 'd1;  // do not change unless you know what you are doing
        mem_req_o.ar.addr       = addr_t'(ddtw_pptr_q);
        mem_req_o.ar.len        = (is_last_ddt_lvl) ? 
                                  ((RVIOMMUCfg.MSITrans != rv_iommu_cfg::MSI_DISABLED) ? 
                                   (8'd7) : 
                                   (8'd3)) : (8'd0);
        mem_req_o.ar.size       = 3'b011;
        mem_req_o.ar.burst      = axi_pkg::BURST_INCR;

        mem_req_o.ar_valid      = 1'b0;

        // R
        mem_req_o.r_ready       = 1'b0;

        en_msi_check            = 1'b0;

        error_o                 = 1'b0;
        imp_init_o              = 1'b0;
        update_o.update         = 1'b0;
        update_o.did            = req_did_i;
        update_o.dc             = up_dc_content;

        state_n                 = state_q;
        ddt_lvl_n               = ddt_lvl_q;
        ddtw_pptr_n             = ddtw_pptr_q;
        entry_cnt_n             = entry_cnt_q;
        cause_n                 = cause_q;
        wait_rlast_n            = wait_rlast_q;
        imp_active_n            = imp_active_q;

        dc_tc_n                 = dc_tc_q;
        dc_iohgatp_n            = dc_iohgatp_q;
        dc_ta_n                 = dc_ta_q;
        dc_fsc_n                = dc_fsc_q;

        unique case (state_q)

            // Init DDTW
            IDLE: begin

                ddt_lvl_n       = ddtw_level_t'(ddtp_i.iommu_mode.q);
                entry_cnt_n     = '0;
                wait_rlast_n    = 1'b0;

                if (init_ddtw_i && !edge_trigger_q) begin
                    
                    state_n = MEM_ACCESS;

                    //// 3LVL
                    //if (ddtp_i.iommu_mode.q == 4'b0100)
                    //    ddtw_pptr_n = {ddtp_i.ppn.q[PPNW-1:0], req_did_i[23:15], 3'b0};
                    if (ddtp_i.iommu_mode.q == 4'b0100)
                        ddtw_pptr_n = {ddtp_i.ppn.q[PPNW-1:0], req_did_i[23:16], 4'b0};
                    // 2LVL
                    else if (ddtp_i.iommu_mode.q == 4'b0011)
                        ddtw_pptr_n = {ddtp_i.ppn.q[PPNW-1:0], req_did_i[14:6], 3'b0};
                    // 1LVL
                    else if (ddtp_i.iommu_mode.q == 4'b0010)
                        ddtw_pptr_n = {ddtp_i.ppn.q[PPNW-1:0], req_did_i[5:0], 6'b0};
                    // invalid
                    else begin
                        state_n = ERROR;
                        cause_n = rv_iommu::ALL_INB_TRANSACTIONS_DISALLOWED;
                    end
                end
            end

            // Read from the DDT
            MEM_ACCESS: begin

                mem_req_o.ar_valid = 1'b1;
                if (mem_resp_i.ar_ready) begin
                    state_n = (is_last_ddt_lvl) ? (LEAF) : (NON_LEAF);
                end
            end

            // Fetching a non-leaf DDT entry
            NON_LEAF: begin

                if (mem_resp_i.r_valid) begin

                    mem_req_o.r_ready = 1'b1;

                    // From Spec
                    // If ddte.V == 0, stop and report "DDT entry not valid" (cause = 258)
                    if (!nl.v) begin
                        state_n = ERROR;
                        cause_n = rv_iommu::DDT_ENTRY_INVALID;
                    end

                    // From Spec
                    // If any bits or encoding that are reserved for future standard use are set within ddte,"
                    // stop and report "DDT entry misconfigured" (cause = 259)
                    else if ((|nl.reserved_1) || (|nl.reserved_2)) begin
                        state_n = ERROR;
                        cause_n = rv_iommu::DDT_ENTRY_MISCONFIGURED;
                    end

                    else begin
                        unique case (ddt_lvl_q)
                            //LVL3: begin
                            //    ddt_lvl_n = LVL2;
                            //    ddtw_pptr_n = {nl.ppn[PPNW-1:0], req_did_i[14:6], 3'b0};
                            LVL3: begin
                                ddt_lvl_n = LVL2;
                                ddtw_pptr_n = {nl.ppn[PPNW-1:0], req_did_i[15:7], 3'b0};
                            end
                            //LVL2: begin
                            //    ddt_lvl_n = LVL1;
                            //    ddtw_pptr_n = {nl.ppn[PPNW-1:0], req_did_i[5:0], 6'b0};
                            LVL2: begin
                                ddt_lvl_n = LVL1;
                                ddtw_pptr_n = {nl.ppn[PPNW-1:0], req_did_i[6:0], 5'b0};
                            end
                            default: begin
                                state_n = ERROR;
                            end
                        endcase

                        state_n = MEM_ACCESS;
                    end
                end
            end

            // Fetching DC
            LEAF: begin

                if (mem_resp_i.r_valid) begin

                    mem_req_o.r_ready   = 1'b1;
                    entry_cnt_n         = entry_cnt_q + 1;

                    unique case (entry_cnt_q)

                        //DC.tc
                        3'b000: begin
                            dc_tc_n = dc_tc;

                            // From Spec
                            // If ddte.V == 0, stop and report "DDT entry not valid" (cause = 258)
                            if (!dc_tc.v) begin
                                state_n         = ERROR;
                                cause_n         = rv_iommu::DDT_ENTRY_INVALID;
                                wait_rlast_n    = 1'b1;
                            end

                            else if ((|dc_tc.reserved_1) || (|dc_tc.reserved_2) || 
                                (!capabilities_i.ats.q && (dc_tc.en_ats || dc_tc.en_pri || dc_tc.prpr)) ||
                                (!dc_tc.en_ats && (dc_tc.t2gpa || dc_tc.en_pri)) ||
                                (!dc_tc.en_pri && dc_tc.prpr) ||
                                (!dc_tc.pdtv && dc_tc.dpe) ||
                                (!capabilities_i.amo_hwad.q && (dc_tc.sade || dc_tc.gade)) ||
                                (fctl_i.be.q != dc_tc.sbe) ||
                                (dc_tc.sxl != fctl_i.gxl.q)
                            ) begin
                                state_n         = ERROR;
                                cause_n         = rv_iommu::DDT_ENTRY_MISCONFIGURED;
                                wait_rlast_n    = 1'b1;
                            end
                        end

                        //DC.iohgatp
                        3'b001: begin
                            dc_iohgatp_n = dc_iohgatp;

                            if ((dc_tc_q.t2gpa && !(|dc_iohgatp.mode)) ||
                                (!(dc_iohgatp.mode inside {4'd0, 4'd8, 4'd9, 4'd10})) ||
                                (!fctl_i.gxl.q && ((!capabilities_i.sv39x4.q && dc_iohgatp.mode == 4'd8) ||
                                                 (!capabilities_i.sv48x4.q && dc_iohgatp.mode == 4'd9) ||
                                                 (!capabilities_i.sv57x4.q && dc_iohgatp.mode == 4'd10))) ||
                                (fctl_i.gxl.q && (!capabilities_i.sv32x4.q && dc_iohgatp.mode == 4'd8)) ||
                                (|dc_iohgatp.mode && |dc_iohgatp.ppn[1:0])
                            ) begin
                                state_n         = ERROR;
                                cause_n         = rv_iommu::DDT_ENTRY_MISCONFIGURED;
                                wait_rlast_n    = 1'b1;
                            end
                        end

                        //DC.ta
                        3'b010: begin
                            dc_ta_n = dc_ta;

                            if ((|dc_ta.reserved_1) || (|dc_ta.reserved_2)) begin
                                state_n         = ERROR;
                                cause_n         = rv_iommu::DDT_ENTRY_MISCONFIGURED;
                                wait_rlast_n    = 1'b1;
                            end
                        end

                        // DC.fsc
                        3'b011: begin
                            dc_fsc_n = dc_fsc;

                            if ((dc_tc_q.pdtv && (!(dc_fsc.mode inside {4'd0, 4'd1, 4'd2, 4'd3}     ) ||
                                                   (!capabilities_i.pd20.q && dc_fsc.mode == 4'b0011) ||
                                                   (!capabilities_i.pd17.q && dc_fsc.mode == 4'b0010) ||
                                                   (!capabilities_i.pd8.q && dc_fsc.mode == 4'b0001 )
                                                  )) ||
                                (!dc_tc_q.pdtv && !dc_tc_q.sxl && (!(dc_fsc.mode inside {4'd0, 4'd8, 4'd9, 4'd10}   ) ||
                                                                    (!capabilities_i.sv39.q && dc_fsc.mode == 4'd8  ) ||
                                                                    (!capabilities_i.sv48.q && dc_fsc.mode == 4'd9  ) ||
                                                                    (!capabilities_i.sv57.q && dc_fsc.mode == 4'd10 )
                                                                   )) ||
                                (!dc_tc_q.pdtv && dc_tc_q.sxl && (!(dc_fsc.mode inside {4'd0, 4'd8}) ||
                                                                   (!capabilities_i.sv32.q && dc_fsc.mode == 4'd8)
                                                                  )) ||
                                (|dc_fsc.reserved)
                            ) begin

                                wait_rlast_n    = 1'b1;
                                state_n         = ERROR;
                                cause_n         = rv_iommu::DDT_ENTRY_MISCONFIGURED;
                            end

                            else begin
                                // MSI translation disabled
                                if (RVIOMMUCfg.MSITrans == rv_iommu_cfg::MSI_DISABLED) begin
                                    state_n = UPDATE;

                                    // If the DC have an associated PC and Stage-2 is enabled, pdtp.PPN must be translated before being cached
                                    if (RVIOMMUCfg.InclPC) begin
                                        if (en_S2 && dc_tc_q.pdtv) begin
                                            imp_init_o      = 1'b1;
                                            imp_active_n    = 1'b1;
                                        end
                                    end
                                end
                            end
                        end

                        // DC MSI fields
                        3'b100, 3'b101, 3'b110: begin
                            if (RVIOMMUCfg.MSITrans != rv_iommu_cfg::MSI_DISABLED) begin
                                en_msi_check = 1'b1;

                                if (msi_check_error) begin
                                    wait_rlast_n    = 1'b1;
                                    state_n         = ERROR;
                                    cause_n         = rv_iommu::DDT_ENTRY_MISCONFIGURED;
                                end
                            end
                        end

                        // DC MSI fields
                        3'b111: begin
                            if (RVIOMMUCfg.MSITrans != rv_iommu_cfg::MSI_DISABLED) begin
                                en_msi_check = 1'b1;
                                state_n = UPDATE;

                                if (msi_check_error) begin
                                    state_n = ERROR;
                                    cause_n = rv_iommu::DDT_ENTRY_MISCONFIGURED;
                                end

                                else begin
                                    // If the DC have an associated PC and Stage-2 is enabled, pdtp.PPN must be translated before being cached
                                    if (RVIOMMUCfg.InclPC) begin
                                        if (en_S2 && dc_tc_q.pdtv) begin
                                            imp_init_o      = 1'b1;
                                            imp_active_n    = 1'b1;
                                        end 
                                    end
                                end
                            end
                        end
                        
                        default: state_n = IDLE;
                    endcase
                end
            end

            // Wait for pdtp.ppn translation and update DDTC
            UPDATE: begin
                
                if (imp_active_q) begin

                    // Error during implicit translation. Reported by PTW
                    if (imp_err_i) begin
                        imp_active_n    = 1'b0;
                        state_n         = IDLE;
                    end

                    else if (imp_done_i) begin
                        dc_fsc_n.ppn    = pdt_ppn_i;
                        imp_active_n    = 1'b0;
                    end
                end

                else begin
                    update_o.update = 1'b1;
                    state_n         = IDLE;
                end
            end

            // An error occurred
            ERROR: begin
                mem_req_o.r_ready   = 1'b1;

                if ((wait_rlast_q && mem_resp_i.r_valid && mem_resp_i.r.last) || !wait_rlast_q) begin
                    error_o = 1'b1;
                    state_n = IDLE;
                end
            end

            default: begin
                state_n = IDLE;
            end
        endcase

        // Check for AXI transmission errors
        if (mem_resp_i.r_valid && mem_resp_i.r.resp != axi_pkg::RESP_OKAY) begin
            update_o.update = 1'b0;
            wait_rlast_n    = ~mem_resp_i.r.last;
            cause_n         = rv_iommu::DDT_DATA_CORRUPTION;
            state_n         = ERROR;
        end
    end

    //-------------------------
    // MSI Translation Support
    //-------------------------
    generate
        
        // MSI translation supported
        if (RVIOMMUCfg.MSITrans != rv_iommu_cfg::MSI_DISABLED) begin : gen_msi_support

            rv_iommu::msiptp_t              dc_msiptp_q, dc_msiptp_n;
            rv_iommu::msi_addr_mask_t       dc_msi_addr_mask_q, dc_msi_addr_mask_n;
            rv_iommu::msi_addr_pattern_t    dc_msi_addr_patt_q, dc_msi_addr_patt_n;
            
            rv_iommu::msiptp_t              dc_msiptp;
            rv_iommu::msi_addr_mask_t       dc_msi_addr_mask;
            rv_iommu::msi_addr_pattern_t    dc_msi_addr_patt;
            logic [63:0]                    dc_reserved;

            always_comb begin : msi_config_checks

                msi_check_error     = 1'b0;
                dc_msiptp           = rv_iommu::msiptp_t'(mem_resp_i.r.data[((64*4) & (RVIOMMUCfg.AxiDataWidth-1))+:64]);
                dc_msi_addr_mask    = rv_iommu::msi_addr_mask_t'(mem_resp_i.r.data[((64*5) & (RVIOMMUCfg.AxiDataWidth-1))+:64]);
                dc_msi_addr_patt    = rv_iommu::msi_addr_pattern_t'(mem_resp_i.r.data[((64*6) & (RVIOMMUCfg.AxiDataWidth-1))+:64]);
                dc_reserved         = mem_resp_i.r.data[((64*7) & (RVIOMMUCfg.AxiDataWidth-1))+:64];

                up_dc_content.msi_addr_pattern  = dc_msi_addr_patt_q;
                up_dc_content.msi_addr_mask     = dc_msi_addr_mask_q;
                up_dc_content.msiptp            = dc_msiptp_q;
                up_dc_content.reserved          = '0;

                dc_msiptp_n         = dc_msiptp_q;
                dc_msi_addr_mask_n  = dc_msi_addr_mask_q;
                dc_msi_addr_patt_n  = dc_msi_addr_patt_q;

                if (en_msi_check) begin

                    unique case (entry_cnt_q)

                        // DC.msiptp
                        3'b100: begin
                            dc_msiptp_n = dc_msiptp;

                            if ((capabilities_i.msi_flat.q && |(dc_msiptp.mode & 4'b1110)) ||
                                (|dc_msiptp.reserved)) begin
                                msi_check_error = 1'b1;
                            end
                        end

                        // DC.msi_addr_mask
                        3'b101: begin
                            dc_msi_addr_mask_n = dc_msi_addr_mask;

                            if ((|dc_msi_addr_mask.reserved)) begin
                                msi_check_error = 1'b1;
                            end
                        end

                        // DC.msi_addr_pattern
                        3'b110: begin
                            dc_msi_addr_patt_n = dc_msi_addr_patt;

                            if ((|dc_msi_addr_patt.reserved)) begin
                                msi_check_error = 1'b1;
                            end
                        end

                        // DC.reserved
                        3'b111: begin

                            if ((|dc_reserved) != 1'b0) begin
                                msi_check_error = 1'b1;
                            end
                        end
                        
                        default:;
                    endcase
                end
            end : msi_config_checks

            always_ff @(posedge clk_i or negedge rst_ni) begin
                if (!rst_ni) begin
                    dc_msiptp_q         <= '0;
                    dc_msi_addr_mask_q  <= '0;
                    dc_msi_addr_patt_q  <= '0;

                end else begin
                    dc_msiptp_q         <= dc_msiptp_n;
                    dc_msi_addr_mask_q  <= dc_msi_addr_mask_n;
                    dc_msi_addr_patt_q  <= dc_msi_addr_patt_n;
                end
            end
        end

        // MSI translation NOT supported
        else begin : gen_msi_support_disabled
            assign msi_check_error = 1'b0;

        end
    endgenerate

    always_ff @(posedge clk_i or negedge rst_ni) begin : ddtw_fsm_ff
        if (!rst_ni) begin
            state_q                 <= IDLE;
            ddt_lvl_q               <= LVL1;
            ddtw_pptr_q             <= '0;
            entry_cnt_q             <= '0;
            cause_q                 <= '0;
            wait_rlast_q            <= 1'b0;
            imp_active_q            <= 1'b0;
            edge_trigger_q          <= 1'b0;
            dc_tc_q                 <= '0;
            dc_iohgatp_q            <= '0;
            dc_ta_q                 <= '0;
            dc_fsc_q                <= '0;

        end else begin
            state_q                 <= state_n;
            ddtw_pptr_q             <= ddtw_pptr_n;
            ddt_lvl_q               <= ddt_lvl_n;
            entry_cnt_q             <= entry_cnt_n;
            cause_q                 <= cause_n;
            wait_rlast_q            <= wait_rlast_n;
            imp_active_q            <= imp_active_n;
            edge_trigger_q          <= edge_trigger_n;
            dc_tc_q                 <= dc_tc_n;
            dc_iohgatp_q            <= dc_iohgatp_n;
            dc_ta_q                 <= dc_ta_n;
            dc_fsc_q                <= dc_fsc_n;
        end
    end

endmodule
