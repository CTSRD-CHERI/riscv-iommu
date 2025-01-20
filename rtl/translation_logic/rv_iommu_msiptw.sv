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
// Description: RISC-V IOMMU MSI Page Table Walker.
//              Fetches and validates MSI PTEs in Basic-Translate (BT) mode or MRIF mode.
//              For MSI PTEs in BT mode, it updates the IOTLB.
//              For MSI PTEs in MRIF mode, it updates the MRIF cache.
//

module rv_iommu_msiptw #(

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
    input  logic    clk_i,
    input  logic    rst_ni,

    // Init MSI PTW
    input  logic    init_msi_ptw_i,

    // Error signaling
    output logic                error_o,
    output rv_iommu::cause_t    cause_code_o,
    output logic                ignore_o,

    // Transaction data
    input  addr_t req_iova_i,
    input  rv_iommu::pscid_t    pscid_i,
    input  rv_iommu::gscid_t    gscid_i,
    input  logic                en_1S_i,
    input  logic                is_rx_i,

    // MSI data from DC
    input  rv_iommu::ppn_t                  msiptp_ppn_i,
    input  logic [rv_iommu::GPPNW39-1:0]    msi_addr_mask_i,
    
    // First-stage data provided by PTW
    input  rv_iommu::iotlb_stage_content_t  content_1S_i,

    // IOTLB update port
    output rv_iommu::iotlb_up_t             iotlb_update_o,

    // MRIFC update port
    output rv_iommu::mrifc_up_t             mrifc_update_o,

    // Memory interface
    input  axi_resp_t   mem_resp_i,
    output axi_req_t    mem_req_o
);

    localparam int unsigned PLEN = RVIOMMUCfg.PAddrWidth;
    localparam int unsigned PPNW = PLEN-12;

    // MSI-BT FSM States
    typedef enum logic[1:0] {
        IDLE        = 2'b00,
        MEM_ACCESS  = 2'b01,
        BT_PROC_PTE = 2'b10,
        BT_ERROR    = 2'b11
    } state_bt_t;
    state_bt_t bt_state_q, bt_state_n;

    // Physical pointer to access memory
    paddr_t pptr_q, pptr_n;

    // To cast input memory port to MSI PTE data
    rv_iommu::msi_pte_bt_t msi_pte_bt;
    assign msi_pte_bt = rv_iommu::msi_pte_bt_t'(mem_resp_i.r.data);

    // Error from BT FSM
    logic bt_error;
    // Fault code
    rv_iommu::cause_t bt_cause_q, bt_cause_n;
    // To know whether we have to wait for the AXI transaction to complete on errors
    logic bt_wait_rlast_q, bt_wait_rlast_n;

    // Trigger MRIF-MSI FSM
    logic init_msi_mrif;

    // Registers to propagate first-stage data
    logic [(rv_iommu::GPPNW39-1):0]   vpn_q,         vpn_n;
    rv_iommu::pscid_t               pscid_q,       pscid_n;
    rv_iommu::gscid_t               gscid_q,       gscid_n;
    rv_iommu::iotlb_stage_content_t content_1S_q,  content_1S_n;

    // IOTLB update port
    assign iotlb_update_o.vpn = vpn_q;
    assign iotlb_update_o.pscid = pscid_q;
    assign iotlb_update_o.gscid = gscid_q;
    assign iotlb_update_o.content.content_1S = content_1S_q;
    assign iotlb_update_o.content.content_2S.is_1G = 1'b0;
    assign iotlb_update_o.content.content_2S.is_2M = 1'b0;
    assign iotlb_update_o.content.content_2S.ppn = msi_pte_bt.ppn;
    assign iotlb_update_o.content.content_2S.g = 1'b0;
    assign iotlb_update_o.content.content_2S.u = 1'b0;
    assign iotlb_update_o.content.content_2S.x = 1'b0;
    assign iotlb_update_o.content.content_2S.w = 1'b1;
    assign iotlb_update_o.content.content_2S.r = 1'b1;
    assign iotlb_update_o.content.content_2S.v = msi_pte_bt.v;

    // Edge-triggered init control
    logic edge_trigger_q, edge_trigger_n;
    always_comb begin : msi_ptw_init_control
        edge_trigger_n = edge_trigger_q;
        if (!edge_trigger_q && init_msi_ptw_i)
            edge_trigger_n = 1'b1;
        if (edge_trigger_q && !init_msi_ptw_i)
            edge_trigger_n = 1'b0;
    end

    //--------------------------------
    // MSI-BT FSM combinational logic
    //--------------------------------
    always_comb begin : bt_comb

        automatic logic [rv_iommu::GPPNW39-1:0] imsic_num;
        imsic_num = '0;

        // Default assignments
        // Wires
        init_msi_mrif           = 1'b0;
        bt_error                = 1'b0;

        // Output signals
        // AXI parameters
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
        mem_req_o.ar.id         = 'd4; // do not change unless you know what you are doing
        mem_req_o.ar.addr       = addr_t'(pptr_q);
        mem_req_o.ar.len        = 8'b1;
        mem_req_o.ar.size       = 3'b011;
        mem_req_o.ar.burst      = axi_pkg::BURST_INCR;

        mem_req_o.ar_valid      = 1'b0;

        // R
        mem_req_o.r_ready       = 1'b1;

        iotlb_update_o.update   = 1'b0;

        // Next-state values
        pptr_n                  = pptr_q;
        bt_state_n              = bt_state_q;
        bt_wait_rlast_n         = bt_wait_rlast_q;
        bt_cause_n              = bt_cause_q;
        vpn_n                   = vpn_q;
        pscid_n                 = pscid_q;
        gscid_n                 = gscid_q;
        content_1S_n            = content_1S_q;

        unique case (bt_state_q)

            // Init MSI PTW
            IDLE: begin

                bt_wait_rlast_n   = 1'b0;
                
                if (init_msi_ptw_i && !edge_trigger_q) begin

                    // From Spec:
                    // If the transaction is an Untranslated or Translated read-for-execute
                    // then stop and report Instruction access fault (cause = 1).
                    if (is_rx_i) begin
                        bt_cause_n = rv_iommu::INSTR_ACCESS_FAULT;
                        bt_state_n = BT_ERROR;
                    end

                    else begin
                        
                        // First-stage translation enabled. Tags come from PTW.
                        if (en_1S_i) begin
                            
                            imsic_num = rv_iommu::extract_imsic_num(content_1S_i.ppn[(rv_iommu::GPPNW39-1):0], msi_addr_mask_i);

                            pptr_n          = {msiptp_ppn_i[PPNW-1:0], 12'b0} | 
                                                ({{PLEN-rv_iommu::GPPNW39{1'b0}}, imsic_num} << 4);
                            content_1S_n    = content_1S_i;
                        end
                        
                        // First-stage translation disabled. Tags come directly from translation logic.
                        else begin
                            
                            imsic_num = rv_iommu::extract_imsic_num(req_iova_i[(rv_iommu::GPLEN39-1):12], msi_addr_mask_i);

                            pptr_n          = {msiptp_ppn_i[PPNW-1:0], 12'b0} | 
                                                ({{PLEN-rv_iommu::GPPNW39{1'b0}}, imsic_num} << 4);
                            content_1S_n    = '0;
                        end
                        
                        vpn_n   = req_iova_i[(rv_iommu::GPLEN39-1):12];
                        pscid_n = pscid_i;
                        gscid_n = gscid_i;

                        bt_state_n = MEM_ACCESS;
                    end
                end
            end

            // Access memory
            MEM_ACCESS: begin
                mem_req_o.ar_valid = 1'b1;
                if (mem_resp_i.ar_ready) begin
                    bt_state_n = BT_PROC_PTE;
                end
            end

            // Validate MSI PTE and check for errors.
            BT_PROC_PTE: begin
                
                if (mem_resp_i.r_valid) begin

                    bt_wait_rlast_n   = 1'b1;

                    // From Spec:
                    // If msipte.V == 0, then stop and report "MSI PTE not valid" (cause = 262)
                    // This implementation only supports standard MSI PTE formats (msi_pte.c = 0)
                    if (!msi_pte_bt.v || msi_pte_bt.c) begin
                        bt_cause_n = rv_iommu::MSI_PTE_INVALID;
                        bt_state_n = BT_ERROR;
                    end

                    // Check for AXI errors
                    else if (mem_resp_i.r.resp != axi_pkg::RESP_OKAY) begin
                        bt_cause_n = rv_iommu::MSI_PT_DATA_CORRUPTION;
                        bt_state_n = BT_ERROR;
                    end

                    // Valid MSI PTE
                    else begin

                        unique case (msi_pte_bt.m)

                            // MRIF mode
                            rv_iommu::MRIF: begin

                                if (RVIOMMUCfg.MSITrans == rv_iommu_cfg::MSI_BT_MRIF) begin
                                    init_msi_mrif     = 1'b1;
                                    bt_wait_rlast_n   = 1'b0;
                                    bt_state_n        = IDLE;
                                end
                                else begin
                                    bt_cause_n = rv_iommu::MSI_PTE_MISCONFIGURED;
                                    bt_state_n = BT_ERROR;
                                end
                            end 

                            // Basic-Translate mode
                            rv_iommu::BT: begin
                                
                                // From Spec
                                // If any bits or encoding that are reserved for future standard use are set within msipte,
                                // stop and report "MSI PTE misconfigured" (cause = 263).
                                if ((|msi_pte_bt.__rsv_1) || (|msi_pte_bt.__rsv_2)) begin
                                    bt_cause_n = rv_iommu::MSI_PTE_MISCONFIGURED;
                                    bt_state_n = BT_ERROR;
                                end
                                else begin
                                    iotlb_update_o.update   = 1'b1;
                                    bt_wait_rlast_n         = 1'b0;
                                    bt_state_n              = IDLE;
                                end
                            end 

                            // reserved modes (fault)
                            default: begin
                                bt_cause_n = rv_iommu::MSI_PTE_MISCONFIGURED;
                                bt_state_n = BT_ERROR;
                            end
                        endcase
                    end
                end
            end

            // Propagate error code to the translation logic
            BT_ERROR: begin

                // Check whether we have to wait for AXI transmission to end
                if ((bt_wait_rlast_q && mem_resp_i.r_valid && mem_resp_i.r.last) || !bt_wait_rlast_q) begin
                    bt_error    = 1'b1;
                    bt_state_n  = IDLE;
                end
            end
        endcase
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin : bt_seq
        if (!rst_ni) begin
            bt_state_q      <= IDLE;
            pptr_q          <= '0;
            bt_wait_rlast_q <= 1'b0;
            bt_cause_q      <= '0;
            vpn_q           <= '0;
            pscid_q         <= '0;
            gscid_q         <= '0;
            content_1S_q    <= '0;
            edge_trigger_q  <= 1'b0;
        end 
        
        else begin
            bt_state_q      <= bt_state_n;
            pptr_q          <= pptr_n;
            bt_wait_rlast_q <= bt_wait_rlast_n;
            bt_cause_q      <= bt_cause_n;
            vpn_q           <= vpn_n;
            pscid_q         <= pscid_n;
            gscid_q         <= gscid_n;
            content_1S_q    <= content_1S_n;
            edge_trigger_q  <= edge_trigger_n;
        end
    end

    //----------------
    // MSI-MRIF Logic
    //----------------

    // States
    typedef enum logic[1:0] {
       MRIF_PTE     = 2'b00,    // 00
       NOTICE_PTE   = 2'b01,    // 01
       MRIF_ERROR   = 2'b10     // 10
    } state_mrif_t;

    generate

    // MRIF support enabled
    if (RVIOMMUCfg.MSITrans == rv_iommu_cfg::MSI_BT_MRIF) begin : gen_mrif_support

        state_mrif_t mrif_state_q, mrif_state_n;

        // Read ports
        rv_iommu::msi_pte_mrif_t msi_pte_mrif;
        rv_iommu::msi_pte_notice_t msi_pte_notice;
        assign msi_pte_mrif     = rv_iommu::msi_pte_mrif_t'(mem_resp_i.r.data);
        assign msi_pte_notice   = rv_iommu::msi_pte_notice_t'(mem_resp_i.r.data);

        // Error from MRIF FSM
        logic mrif_error;
        // Fault code
        rv_iommu::cause_t mrif_cause_q, mrif_cause_n;

        // To wait for last AXI beat
        logic mrif_wait_rlast_q, mrif_wait_rlast_n;

        // Destination MRIF address register
        logic [46:0] mrif_addr_q, mrif_addr_n;

        // MRIFC update ports
        assign mrifc_update_o.vpn = vpn_q;
        assign mrifc_update_o.pscid = pscid_q;
        assign mrifc_update_o.gscid = gscid_q;
        assign mrifc_update_o.content_1S = content_1S_q;
        assign mrifc_update_o.msi_content.addr = mrif_addr_q;
        assign mrifc_update_o.msi_content.nid  = {msi_pte_notice.nid_10, msi_pte_notice.nid_9_0};
        assign mrifc_update_o.msi_content.nppn = msi_pte_notice.nppn;

        // Error
        assign error_o = (bt_error) | (mrif_error);
        assign cause_code_o = (bt_error) ? (bt_cause_q) : ((mrif_error) ? (mrif_cause_q) : ('0));
    
        //----------------------------------
        // MSI-MRIF FSM combinational logic
        //----------------------------------
        always_comb begin : mrif_comb

            // Default assignments
            // Output values
            mrifc_update_o.update   = 1'b0;
            ignore_o                = 1'b0;
            mrif_error              = 1'b0;

            // Next-state values
            mrif_state_n            = mrif_state_q;
            mrif_cause_n            = mrif_cause_q;
            mrif_addr_n             = mrif_addr_q;
            mrif_wait_rlast_n       = mrif_wait_rlast_q;

            unique case (mrif_state_q)

                // Validate the first 64 bits of the PTE
                MRIF_PTE: begin

                    if (init_msi_mrif) begin

                        mrif_wait_rlast_n = 1'b0;
                        
                        if ((|msi_pte_mrif.__rsv_1) || (|msi_pte_mrif.__rsv_2)) begin
                            mrif_wait_rlast_n   = 1'b1;
                            mrif_cause_n        = rv_iommu::MSI_PTE_MISCONFIGURED;
                            mrif_state_n        = MRIF_ERROR;
                        end

                        // Check bits [11:0] of the access address (this implementation does not support BE accesses)
                        else if ((|req_iova_i[11:0])) begin
                            // this check does not generate faults, the transfer is discarded
                            ignore_o        = 1'b1;
                            mrif_state_n    = MRIF_PTE;
                        end

                        else begin
                            mrif_addr_n     = msi_pte_mrif.addr;
                            mrif_state_n    = NOTICE_PTE;
                        end
                    end
                end

                // Validate the last 64 bits of the PTE
                // Update MRIF cache
                NOTICE_PTE: begin

                    if (mem_resp_i.r_valid) begin
                        
                        if ((|msi_pte_notice.__rsv_1) || (|msi_pte_notice.__rsv_2)) begin
                            mrif_cause_n = rv_iommu::MSI_PTE_MISCONFIGURED;
                            mrif_state_n = MRIF_ERROR;
                        end

                        // Check for AXI transmission errors
                        else if (mem_resp_i.r.resp != axi_pkg::RESP_OKAY) begin
                            mrif_cause_n    = rv_iommu::MSI_PT_DATA_CORRUPTION;
                            mrif_state_n    = MRIF_ERROR;
                        end

                        else begin
                            mrifc_update_o.update   = 1'b1;
                            mrif_state_n            = MRIF_PTE;
                        end
                    end
                end

                // Propagate fault code to the translation logic
                MRIF_ERROR: begin

                    // Check whether we have to wait for AXI transmission to end
                    if ((mrif_wait_rlast_q && mem_resp_i.r_valid && mem_resp_i.r.last) || !mrif_wait_rlast_q) begin
                        mrif_error      = 1'b1;
                        mrif_state_n    = MRIF_PTE;
                    end
                end

                default: mrif_state_n = MRIF_PTE;
            endcase
        end

        always_ff @(posedge clk_i or negedge rst_ni) begin : mrif_seq
            if (!rst_ni) begin
                mrif_state_q        <= MRIF_PTE;
                mrif_wait_rlast_q   <= 1'b0;
                mrif_cause_q        <= '0;
                mrif_addr_q         <= '0;
            end 
            
            else begin
                mrif_state_q        <= mrif_state_n;
                mrif_wait_rlast_q   <= mrif_wait_rlast_n;
                mrif_cause_q        <= mrif_cause_n;
                mrif_addr_q         <= mrif_addr_n;
            end
        end
    end

    // MRIF support disabled
    else begin : gen_mrif_support_disabled

        assign mrifc_update_o   = '0;
        assign ignore_o         = 1'b0;

        assign error_o          = bt_error;
        assign cause_code_o     = bt_cause_q;
    end
    endgenerate

endmodule
