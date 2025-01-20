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
// Description: Process Directory Table Walker (PDTW) for the RISC-V IOMMU.
//              This module walks memory to locate PCs and updates the PDTC.

import rv_iommu_reg_pkg::*;

module rv_iommu_pdtw #(

    /// RISC-V IOMMU configuration struct
    parameter rv_iommu_cfg::rv_iommu_cfg_t RVIOMMUCfg = rv_iommu_cfg::NullCfg,

    /// Address data type
    parameter type addr_t = logic,
    /// Physical address data type
    parameter type paddr_t = logic,

    /// AXI data types
    parameter type axi_req_t = logic,
    parameter type axi_resp_t = logic
) (
    input  logic                            clk_i,
    input  logic                            rst_ni,

    // Init PDTW
    input  logic                            init_pdtw_i,
    
    // Error signaling
    output logic                            active_o,
    output logic                            error_o,
    output rv_iommu::cause_t                cause_code_o,

    // PC checks
    input  iommu_reg2hw_capabilities_reg_t  capabilities_i,

    // Update logic
    output rv_iommu::pdtc_up_t              update_o,

    // Tags
    input  rv_iommu::device_id_t            req_did_i,
    input  rv_iommu::process_id_t           req_pid_i,

    // from DC
    input  logic                            dc_sxl_i,
    input  logic                            en_2S_i,
    input  rv_iommu::ppn_t                  pdtp_ppn_i,
    input  logic [3:0]                      pdtp_mode_i,

    // Implicit second-stage translations
    output logic                            imp_init_o,
    output rv_iommu::ppn_t                  pdt_gppn_o,
    input  logic                            imp_done_i,
    input  logic                            imp_err_i,
    input  rv_iommu::ppn_t                  pdt_ppn_i,

    // Memory interface
    input  axi_resp_t                       mem_resp_i,
    output axi_req_t                        mem_req_o
);

    localparam int unsigned PLEN = RVIOMMUCfg.PAddrWidth;
    localparam int unsigned PPNW = PLEN-12;

    // PDTW states
    typedef enum logic[2:0] {
      IDLE          = 3'b000,
      MEM_ACCESS    = 3'b001,
      NON_LEAF      = 3'b010,
      WAIT_TRANS    = 3'b011,
      SET_PPTR      = 3'b100,
      LEAF          = 3'b101,
      ERROR         = 3'b110
    } pdtw_state_t;
    pdtw_state_t state_q, state_n;

    // PDT levels
    typedef enum logic [1:0] {
        BARE = 2'b00,
        LVL1 = 2'b01, 
        LVL2 = 2'b10, 
        LVL3 = 2'b11
    } pdtw_level_t;
    pdtw_level_t pdt_lvl_q, pdt_lvl_n;

    // PDTW walking
    assign active_o    = (state_q != IDLE);

    // Update registers
    rv_iommu::pc_ta_t   pc_ta_q,    pc_ta_n;
    rv_iommu::fsc_t     pc_fsc_q,   pc_fsc_n;

    // Cast read port to corresponding data structure
    rv_iommu::pc_ta_t       pc_ta;
    rv_iommu::fsc_t         pc_fsc;
    rv_iommu::nl_entry_t    nl;
    assign pc_ta    = rv_iommu::pc_ta_t'(mem_resp_i.r.data[((64*0) & (RVIOMMUCfg.AxiDataWidth-1))+:64]);
    assign pc_fsc   = rv_iommu::fsc_t'(mem_resp_i.r.data[((64*1) & (RVIOMMUCfg.AxiDataWidth-1))+:64]);
    assign nl       = rv_iommu::nl_entry_t'(mem_resp_i.r.data);

    // Physical pointer to access memory bus
    paddr_t pdtw_pptr_q, pdtw_pptr_n;
    // nl.ppn register
    rv_iommu::ppn_t ppn_q, ppn_n;
    // Last PDT level
    logic is_last_pdt_lvl;
    assign is_last_pdt_lvl  = (pdt_lvl_q == LVL1);
    // Aux counter to know how many DWs we have loaded
    logic [1:0] entry_cnt_q, entry_cnt_n;
    logic pc_fully_loaded;
    assign pc_fully_loaded  = (entry_cnt_q == 2'b10);  // always 16-bytes

    // Cause propagation
    rv_iommu::cause_t cause_q, cause_n;
    assign cause_code_o = cause_q;
    // To know whether we have to wait for the AXI transaction to complete
    logic wait_rlast_q, wait_rlast_n;

    // Implicit second-stage translation
    logic imp_active_q, imp_active_n;
    assign pdt_gppn_o       = ppn_q;

    // Edge-triggered init control
    logic edge_trigger_q, edge_trigger_n;
    always_comb begin : pdtw_init_control
        edge_trigger_n = edge_trigger_q;
        if (!edge_trigger_q && init_pdtw_i)
            edge_trigger_n = 1'b1;
        if (edge_trigger_q && !init_pdtw_i)
            edge_trigger_n = 1'b0;
    end

    //------------------------------
    // PDTW FSM combinational logic
    //------------------------------
    always_comb begin : pdtw_fsm_comb

        // AXI parameters
        // AW
        mem_req_o.aw            = '0;
        mem_req_o.aw_valid      = 1'b0;

        // W
        mem_req_o.w             = '0;
        mem_req_o.w_valid       = 1'b0;

        // B
        mem_req_o.b_ready       = 1'b0;

        // AR
        mem_req_o.ar            = '0;
        mem_req_o.ar.id         = 'd2;  // do not change unless you know what you are doing
        mem_req_o.ar.addr       = addr_t'(pdtw_pptr_q);
        mem_req_o.ar.len        = (is_last_pdt_lvl) ? (8'd1) : (8'd0);
        mem_req_o.ar.size       = 3'b011;
        mem_req_o.ar.burst      = axi_pkg::BURST_INCR;

        mem_req_o.ar_valid      = 1'b0;

        // R
        mem_req_o.r_ready       = 1'b0;

        error_o         = 1'b0;
        imp_init_o      = 1'b0;
        update_o.update = 1'b0;
        update_o.did    = req_did_i;
        update_o.pid    = req_pid_i;
        update_o.pc.ta  = pc_ta_q;
        update_o.pc.fsc = pc_fsc_q;

        // Next state values
        state_n         = state_q;
        pdt_lvl_n       = pdt_lvl_q;
        pdtw_pptr_n     = pdtw_pptr_q;
        ppn_n           = ppn_q;
        entry_cnt_n     = entry_cnt_q;
        cause_n         = cause_q;
        wait_rlast_n    = wait_rlast_q;
        imp_active_n    = imp_active_q;

        pc_ta_n         = pc_ta_q;
        pc_fsc_n        = pc_fsc_q;

        unique case (state_q)

            // Init PDTW
            IDLE: begin
                
                entry_cnt_n     = '0;
                wait_rlast_n    = 1'b0;

                if (init_pdtw_i && !edge_trigger_q) begin
                    
                    // start with the level indicated by pdtp.MODE
                    pdt_lvl_n       = pdtw_level_t'(pdtp_mode_i);
                    state_n         = MEM_ACCESS;

                    // load pptr according to pdtp.MODE
                    // PD20
                    if (pdtp_mode_i == 4'b0011)
                        pdtw_pptr_n = {pdtp_ppn_i[PPNW-1:0], 6'b0, req_pid_i[19:17], 3'b0};
                    // PD17
                    else if (pdtp_mode_i == 4'b0010)
                        pdtw_pptr_n = {pdtp_ppn_i[PPNW-1:0], req_pid_i[16:8], 3'b0};
                    // PD8
                    else if (pdtp_mode_i == 4'b0001)
                        pdtw_pptr_n = {pdtp_ppn_i[PPNW-1:0], req_pid_i[7:0], 4'b0};
                    // invalid
                    else begin
                        state_n = ERROR;
                        cause_n = rv_iommu::ALL_INB_TRANSACTIONS_DISALLOWED;
                    end
                end
            end

            // Read from the PDT
            MEM_ACCESS: begin
                mem_req_o.ar_valid = 1'b1;

                if (mem_resp_i.ar_ready) begin
                    state_n = (is_last_pdt_lvl) ? (LEAF) : (NON_LEAF);
                end
            end

            // Fetching a non-leaf PDT entry
            NON_LEAF: begin

                if(mem_resp_i.r_valid) begin

                    mem_req_o.r_ready   = 1'b1;

                    // From Spec:
                    // If pdte.V == 0, stop and report "PDT entry not valid" (cause = 266)
                    if (!nl.v) begin
                        state_n = ERROR;
                        cause_n = rv_iommu::PDT_ENTRY_INVALID;
                    end

                    // From Spec:
                    // If if any bits or encoding that are reserved for future standard use are set within pdte,"
                    // stop and report "PDT entry misconfigured" (cause = 267)
                    else if ((|nl.reserved_1) || (|nl.reserved_2)) begin
                        state_n = ERROR;
                        cause_n = rv_iommu::PDT_ENTRY_MISCONFIGURED;
                    end

                    else begin
                        ppn_n   = nl.ppn;

                        // Translate nl.ppn
                        if (en_2S_i) begin
                            imp_init_o      = 1'b1;
                            imp_active_n    = 1'b1;
                            state_n         = WAIT_TRANS;
                        end

                        else begin
                            state_n = SET_PPTR;
                        end 
                    end
                end
            end

            // Wait for implicit second-stage translation of nl.ppn
            WAIT_TRANS: begin
                
                // Error during implicit translation. Reported by PTW
                if (imp_err_i) begin
                    state_n         = IDLE;
                    imp_active_n    = 1'b0;
                end

                else if (imp_done_i) begin
                    ppn_n           = pdt_ppn_i;
                    imp_active_n    = 1'b0;
                    state_n         = SET_PPTR;
                end
            end

            // Configure the pptr
            SET_PPTR: begin

                state_n = MEM_ACCESS;

                unique case (pdt_lvl_q)
                    LVL3: begin
                        pdt_lvl_n   = LVL2;
                        pdtw_pptr_n = {ppn_q[PPNW-1:0], req_pid_i[16:8], 3'b0};
                    end

                    LVL2: begin
                        pdt_lvl_n   = LVL1;
                        pdtw_pptr_n = {ppn_q[PPNW-1:0], req_pid_i[7:0], 4'b0};
                    end

                    default:;
                endcase
            end

            // Fetching PC
            LEAF: begin

                if (pc_fully_loaded) begin

                    update_o.update = 1'b0;
                    state_n = IDLE;
                end

                else if (mem_resp_i.r_valid) begin

                    mem_req_o.r_ready = 1'b1;
                    entry_cnt_n = entry_cnt_q + 1;

                    unique case ({entry_cnt_q})

                        //PC.ta
                        2'b00: begin
                            pc_ta_n = pc_ta;

                            // From Spec
                            // If pdte.V == 0, stop and report "PDT entry not valid" (cause = 266)
                            if (!pc_ta.v) begin
                                state_n         = ERROR;
                                cause_n         = rv_iommu::PDT_ENTRY_INVALID;
                                wait_rlast_n    = 1'b1;
                            end

                            else if ((|pc_ta.reserved_1) || (|pc_ta.reserved_2)) begin
                                state_n         = ERROR;
                                cause_n         = rv_iommu::PDT_ENTRY_MISCONFIGURED;
                                wait_rlast_n    = 1'b1;
                            end
                        end

                        //PC.fsc
                        2'b01: begin
                            pc_fsc_n = pc_fsc;

                            if ((|pc_fsc.reserved) ||
                                (!dc_sxl_i && (!(pc_fsc.mode inside {4'd0, 4'd8, 4'd9, 4'd10}   ) ||
                                                (!capabilities_i.sv39.q && pc_fsc.mode == 4'd8  ) ||
                                                (!capabilities_i.sv48.q && pc_fsc.mode == 4'd9  ) ||
                                                (!capabilities_i.sv57.q && pc_fsc.mode == 4'd10 )
                                               )) ||
                                (dc_sxl_i && (!(pc_fsc.mode inside {4'd0, 4'd8}              ) ||
                                               (!capabilities_i.sv32.q && pc_fsc.mode == 4'd8)
                                              ))) begin
                                state_n = ERROR;
                                cause_n = rv_iommu::PDT_ENTRY_MISCONFIGURED;
                            end
                        end
                        
                        default: state_n = IDLE;
                    endcase
                end
            end

            // An error occurred
            ERROR: begin
                mem_req_o.r_ready = 1'b1;

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
            cause_n         = rv_iommu::PDT_DATA_CORRUPTION;
            state_n         = ERROR;
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin : pdtw_fsm_ff
        if (!rst_ni) begin
            state_q                 <= IDLE;
            pdt_lvl_q               <= LVL1;
            pdtw_pptr_q             <= '0;
            ppn_q                   <= '0;
            entry_cnt_q             <= '0;
            cause_q                 <= '0;
            pc_ta_q                 <= '0;
            pc_fsc_q                <= '0;
            wait_rlast_q            <= 1'b0;
            edge_trigger_q          <= 1'b0;
            imp_active_q            <= 1'b0;

        end else begin
            state_q                 <= state_n;
            pdt_lvl_q               <= pdt_lvl_n;
            pdtw_pptr_q             <= pdtw_pptr_n;
            ppn_q                   <= ppn_n;
            entry_cnt_q             <= entry_cnt_n;
            cause_q                 <= cause_n;
            pc_ta_q                 <= pc_ta_n;
            pc_fsc_q                <= pc_fsc_n;
            wait_rlast_q            <= wait_rlast_n;
            edge_trigger_q          <= edge_trigger_n;
            imp_active_q            <= imp_active_n;
        end
    end

endmodule