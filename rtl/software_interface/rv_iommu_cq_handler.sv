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
// Description: RISC-V IOMMU Command Queue (CQ) handler module.
//              This module fetches, decodes and executes commands
//              issued by software into the CQ.

module rv_iommu_cq_handler #(
    /// RISC-V IOMMU configuration struct
    parameter rv_iommu_cfg::rv_iommu_cfg_t RVIOMMUCfg = rv_iommu_cfg::NullCfg,

    /// Address data type
    parameter type addr_t = logic,
    /// Physical address data type
    parameter type paddr_t = logic,

    /// AXI data types
    parameter type axi_req_t    = logic,
    parameter type axi_resp_t   = logic
) (
    input  logic clk_i,
    input  logic rst_ni,

    // cqb
    input  rv_iommu::ppn_t              cqb_ppn_i,
    input  logic [4:0]                  cqb_size_i,

    // Queue indexes
    input  logic [31:0]                 cq_tail_i,
    input  logic [31:0]                 cq_head_i,
    output logic [31:0]                 cq_head_o,
    output logic                        cq_head_wen_o,

    // cqcsr
    input  logic                        cqcsr_en_i,
    input  logic                        cqcsr_ie_i,
    output logic                        cqcsr_on_o,
    output logic                        cqcsr_on_wen_o,
    output logic                        cqcsr_busy_o,
    output logic                        cqcsr_busy_wen_o,
    // Memory fault
    input  logic                        cqcsr_mf_i,
    output logic                        cqcsr_mf_o,
    output logic                        cqcsr_mf_wen_o,
    // Timeout
    input  logic                        cqcsr_to_i,
    output logic                        cqcsr_to_o,
    output logic                        cqcsr_to_wen_o,
    // Illegal command
    input  logic                        cqcsr_ill_i,
    output logic                        cqcsr_ill_o,
    output logic                        cqcsr_ill_wen_o,
    // IOFENCE completion
    input  logic                        cqcsr_fence_i,
    output logic                        cqcsr_fence_o,
    output logic                        cqcsr_fence_wen_o,

    // ipsr
    output logic                        ipsr_cip_o,
    output logic                        ipsr_cip_wen_o,

    // WSI enable
    input  logic                        wsi_en_i,

    // Context Cache Invalidation
    output rv_iommu::xdtc_inval_t       iodirinval_o,
    // IOTLB Invalidation
    output rv_iommu::iotlb_inval_t      iotinval_o,
    // ATS Invalidation
    output rv_iommu::cq_atsinval_t      atsinval_o,
    output logic                        atsinval_valid_o,
    input  logic                        atsinval_ready_i,

    input  logic                        atsinval_to_i,
    input  logic                        atsinval_inflight_i,

    // Memory Bus
    input  axi_resp_t   mem_resp_i,
    output axi_req_t    mem_req_o
);

    localparam int unsigned PLEN = RVIOMMUCfg.PAddrWidth;
    localparam int unsigned PPNW = PLEN-12;

    // FSM states
    enum logic [2:0] {
        IDLE,           // 000
        FETCH,          // 001
        REGISTER,       // 010
        DECODE,         // 011
        WRITE,          // 100
        ERROR           // 101
    }   state_q, state_n;

    // Write FSM states
    enum logic [1:0] {
        AW_REQ,
        W_DATA,
        B_RESP
    }   wr_state_q, wr_state_n;

    // Physical pointer to access memory
    paddr_t cq_pptr_q, cq_pptr_n;

    // To mask fqh after incrementing
    logic [31:0]    idx_mask;
    assign          idx_mask = ~({32{1'b1}} << (cqb_size_i+1));

    // Control busy signal to notice SW when is not possible to write to cqcsr
    logic cq_en_q, cq_en_n;

    /* 
      From Spec: When the cqon bit reads 0, the IOMMU guarantees:
        (i)  That no implicit memory accesses to the command queue are in-flight;
        (ii) The command-queue will not generate new implicit loads to the queue memory.
    */
    assign cqcsr_on_o       = (cq_en_q | cqcsr_en_i);
    assign cqcsr_on_wen_o   = 1'b1;

    assign cqcsr_busy_o     = (cqcsr_en_i != cq_en_q);
    assign cqcsr_busy_wen_o = 1'b1;

    // To check if any error bit was cleared by SW
    logic   error_vector;
    assign  error_vector    = (cqcsr_mf_i | cqcsr_to_i | cqcsr_ill_i);

    // Set ipsr.cie if any error bit is set
    assign ipsr_cip_o       = cqcsr_ie_i;
    assign ipsr_cip_wen_o   = (cqcsr_mf_o | cqcsr_to_o | cqcsr_ill_o | cqcsr_fence_o);

    // CQ entry register
    logic [127:0]   cmd_q, cmd_n;

    // Cast read bus to receive CQ entries from memory
    rv_iommu::cq_entry_t    cq_entry;
    rv_iommu::cq_iotinval_t cmd_iotinval;
    rv_iommu::cq_iofence_t  cmd_iofence;
    rv_iommu::cq_iodir_t    cmd_iodirinval;
    rv_iommu::cq_iodir_t    cmd_atsinval;

    assign cq_entry         = rv_iommu::cq_entry_t'(cmd_q);
    assign cmd_iotinval     = rv_iommu::cq_iotinval_t'(cmd_q);
    assign cmd_iofence      = rv_iommu::cq_iofence_t'(cmd_q);
    assign cmd_iodirinval   = rv_iommu::cq_iodir_t'(cmd_q);
    assign cmd_atsinval     = rv_iommu::cq_atsinval_t'(cmd_q);

    //# Combinational Logic
    always_comb begin : cq_handler_comb

        // Default values
        // AXI parameters
        // AW
        mem_req_o.aw            = '0;
        mem_req_o.aw.id         = 'd0;  // do not change unless you know what you are doing
        mem_req_o.aw.addr       = addr_t'(cq_pptr_q);
        mem_req_o.aw.len        = 8'b0;
        mem_req_o.aw.size       = 3'b011;
        mem_req_o.aw.burst      = axi_pkg::BURST_INCR;

        mem_req_o.aw_valid      = 1'b0;

        // W
        mem_req_o.w.data        = {32'b0, cmd_iofence.data};
        mem_req_o.w.strb        = '1;
        mem_req_o.w.last        = 1'b1;
        mem_req_o.w.user        = '0;

        mem_req_o.w_valid       = 1'b0;

        // B
        mem_req_o.b_ready       = 1'b0;

        // AR
        mem_req_o.ar            = '0;
        mem_req_o.ar.id         = 'd3;  // do not change unless you know what you are doing
        mem_req_o.ar.addr       = addr_t'(cq_pptr_q);
        mem_req_o.ar.len        = 8'd1;
        mem_req_o.ar.size       = 3'b011;
        mem_req_o.ar.burst      = axi_pkg::BURST_INCR;

        mem_req_o.ar_valid      = 1'b0;

        // R
        mem_req_o.r_ready       = 1'b0;

        iotinval_o              = '0;
        iodirinval_o            = '0;
        atsinval_o              = '0;
        atsinval_valid_o        = '0;

        cq_head_o               = cq_head_i;
        cq_head_wen_o           = 1'b1;
        cqcsr_mf_o              = 1'b0;
        cqcsr_mf_wen_o          = 1'b0;
        cqcsr_to_o              = 1'b0;
        cqcsr_to_wen_o          = 1'b0;
        cqcsr_ill_o             = 1'b0;
        cqcsr_ill_wen_o         = 1'b0;
        cqcsr_fence_o           = 1'b0;
        cqcsr_fence_wen_o       = 1'b0;

        state_n                 = state_q;
        wr_state_n              = wr_state_q;
        cq_pptr_n               = cq_pptr_q;
        cq_en_n                 = cq_en_q;
        cmd_n                   = cmd_q;

        unique case (state_q)

            // CQ fetch is automatically triggered when head != tail and CQ is enabled
            IDLE: begin

                if (cqcsr_en_i) begin

                    // CQ was recently enabled by SW. Set cq_head, cqmf, cmd_ill, cmd_to and fence_w_ip to zero
                    if (!cq_en_q) begin
                        cq_head_o           = '0;
                        cqcsr_mf_wen_o      = 1'b1;
                        cqcsr_to_wen_o      = 1'b1;
                        cqcsr_ill_wen_o     = 1'b1;
                        cqcsr_fence_wen_o   = 1'b1;

                        cq_en_n = 1'b1;
                    end
                
                    // New command
                    else if ((cq_tail_i & idx_mask) != cq_head_i) begin
                        cq_pptr_n = {cqb_ppn_i[PPNW-1:0], 12'b0} | ({{PLEN-32{1'b0}}, cq_head_i} << 4);
                        state_n = FETCH;
                    end
                end

                // Check if EN signal was recently cleared by SW
                else if (cq_en_q) begin
                    cq_en_n = 1'b0;
                end
            end

            FETCH: begin
                mem_req_o.ar_valid = 1'b1;
                if (mem_resp_i.ar_ready) begin
                    state_n     = REGISTER;
                end
            end

            REGISTER: begin
                if (mem_resp_i.r_valid) begin
                    mem_req_o.r_ready   = 1'b1;
                    if (mem_resp_i.r.last) begin
                        cmd_n[127:64]   = mem_resp_i.r.data[((64*1) & 
                                                (RVIOMMUCfg.AxiDataWidth-1))+:64];
                        cq_head_o       = (cq_head_i + 1) & idx_mask;
                        state_n         = DECODE;
                    end
                    else cmd_n[63:0]    = mem_resp_i.r.data[((64*0) & 
                                                (RVIOMMUCfg.AxiDataWidth-1))+:64];

                    // Check for AXI transmission errors
                    if (mem_resp_i.r.resp != axi_pkg::RESP_OKAY) begin
                        state_n         = ERROR;
                        cqcsr_mf_o      = 1'b1;
                        cqcsr_mf_wen_o  = 1'b1;
                    end
                end
            end

            DECODE: begin

                state_n = IDLE;
                unique case (cq_entry.opcode)

                    /*
                        IOTINVAL.VMA ensures that previous stores made to the first-stage page tables by the harts are
                        observed by the IOMMU before all subsequent implicit reads from IOMMU to the corresponding
                        first-stage page tables.

                        IOTINVAL.GVMA ensures that previous stores made to the second-stage page tables are observed
                        before all subsequent implicit reads from IOMMU to the corresponding second-stage page tables.
                    */
                    rv_iommu::IOTINVAL: begin

                        iotinval_o.av       = cmd_iotinval.av;
                        iotinval_o.gv       = cmd_iotinval.gv;
                        iotinval_o.pscv     = cmd_iotinval.pscv;
                        iotinval_o.vpn      = cmd_iotinval.addr[(rv_iommu::GPPNW39-1):0];
                        iotinval_o.gscid    = cmd_iotinval.gscid;
                        iotinval_o.pscid    = cmd_iotinval.pscid;

                        // From Spec:
                        // A command is determined to be illegal if a reserved bit is set to 1
                        // Setting PSCV to 1 with IOTINVAL.GVMA is illegal
                        if ((|cmd_iotinval.reserved_1) || (|cmd_iotinval.reserved_2)                        || 
                            (|cmd_iotinval.reserved_3) || (|cmd_iotinval.reserved_4)                        ||
                            (cmd_iotinval.func3 != rv_iommu::VMA && cmd_iotinval.func3 != rv_iommu::GVMA)   ||
                            (cmd_iotinval.func3 == rv_iommu::GVMA && cmd_iotinval.pscv)) begin
                            
                            cqcsr_ill_o     = 1'b1;
                            cqcsr_ill_wen_o = 1'b1;
                            state_n         = ERROR;
                        end

                        // Check func3 to determine if command is VMA or GVMA
                        else if (cmd_iotinval.func3 == rv_iommu::VMA) begin
                            iotinval_o.inval_vma    = 1'b1;
                        end

                        else if (cmd_iotinval.func3 == rv_iommu::GVMA) begin
                            iotinval_o.inval_gvma   = 1'b1;
                        end

                    end

                    /*
                        A IOFENCE.C command completion, as determined by cqh advancing past the index of the IOFENCE.C
                        command in the CQ, guarantees that all previous commands fetched from the CQ have been
                        completed and committed.
                    */
                    rv_iommu::IOFENCE: begin

                        // From Spec:
                        // A command is determined to be illegal if a reserved bit is set to 1
                        if ((|cmd_iofence.reserved_1) || (|cmd_iofence.reserved_2)  ||
                            (cmd_iofence.func3 != rv_iommu::IOFENCE_C)) begin
                            cqcsr_ill_o     = 1'b1;
                            cqcsr_ill_wen_o = 1'b1;
                            state_n         = ERROR;
                        end

                        // Valid IOFENCE.C command
                        else begin

                            // TODO: Add IOFENCE support with PR and PW using R/W counters

                            // From Spec:
                            // If AV=1, the IOMMU writes DATA to memory at a 4-byte aligned address ADDR[63:2] * 4
                            if(cmd_iofence.av) begin
                                cq_pptr_n   = {cmd_iofence.addr[PLEN-1-2:0], 2'b0};
                                wr_state_n  = AW_REQ;
                                state_n     = WRITE;
                            end

                            // Set cqcsr.fence_w_ip if IOMMU supports and uses WSIs
                            if (cmd_iofence.wsi && wsi_en_i) begin
                                cqcsr_fence_o       = 1'b1;
                                cqcsr_fence_wen_o   = 1'b1;
                            end

                            // Wait for ATS invalidations to complete before proceeding
                            if(atsinval_inflight_i) begin
                               //An Invalidation timed out
                               if(atsinval_to_i) begin
                                  cqcsr_to_o = 1'b1;
                                  cqcsr_to_wen_o = 1'b1;
                               end else begin
                                  state_n = DECODE;
                               end
                            end

                        end
                    end

                    /*
                        IODIR.INVAL_DDT guarantees that any previous stores made by a RISC-V hart to the DDT are observed
                        before all subsequent implicit reads from IOMMU to DDT.

                        IODIR.INVAL_PDT guarantees that any previous stores made by a RISC-V hart to the PDT are observed
                        before all subsequent implicit reads from IOMMU to PDT.
                    */
                    rv_iommu::IODIR: begin

                        iodirinval_o.dv     = cmd_iodirinval.dv;
                        iodirinval_o.did    = cmd_iodirinval.did;
                        iodirinval_o.pid    = cmd_iodirinval.pid;

                        // From Spec:
                        // A command is determined to be illegal if a reserved bit is set to 1
                        // The PID operand is reserved for IODIR.INVAL_DDT
                        // The DV operand must be 1 for IODIR.INVAL_PDT
                        if ((|cmd_iodirinval.reserved_1) || (|cmd_iodirinval.reserved_2)                     ||
                            (|cmd_iodirinval.reserved_3) || (|cmd_iodirinval.reserved_4)                     ||
                            (cmd_iodirinval.func3 != rv_iommu::DDT && cmd_iodirinval.func3 != rv_iommu::PDT) ||
                            (cmd_iodirinval.func3 == rv_iommu::DDT && |cmd_iodirinval.pid)                   ||
                            (cmd_iodirinval.func3 == rv_iommu::PDT && !cmd_iodirinval.dv)) begin
                            
                            cqcsr_ill_o     = 1'b1;
                            cqcsr_ill_wen_o = 1'b1;
                            state_n         = ERROR;
                        end

                        // Check func3 to determine if command is INVAL_DDT or INVAL_PDT
                        else if (cmd_iodirinval.func3 == rv_iommu::DDT) begin
                            iodirinval_o.inval_ddtc = 1'b1;
                            iodirinval_o.inval_pdtc = 1'b1;
                        end

                        else if (cmd_iodirinval.func3 == rv_iommu::PDT) begin
                            iodirinval_o.inval_pdtc = 1'b1;
                        end
                    end

                    /*
                        ATS.INVAL is now supported, but ATS.PRGR still is not supported
                    */
                    rv_iommu::ATS: begin
                        // It's an ATS Invalidation command
                        if(cmd_atsinval.func3 == 3'b000) begin
                           atsinval_o = cmd_atsinval;
                           atsinval_valid_o = 1'b1;
                           if(~atsinval_ready_i)
                              state_n = DECODE;
                        // It is a PRGR command, not supported yet
                        end else begin
                           cqcsr_ill_o     = 1'b1;
                           cqcsr_ill_wen_o = 1'b1;
                           state_n         = ERROR;
                        end
                    end

                    default: begin
                        // From Spec:
                        // A command is determined to be illegal if it uses a reserved encoding
                        cqcsr_ill_o     = 1'b1;
                        cqcsr_ill_wen_o = 1'b1;
                        state_n         = ERROR;
                    end
                    
                endcase
            end

            // Write DATA (32-bit) to ADDR[63:2] * 4
            WRITE: begin
                
                unique case (wr_state_q)
                    AW_REQ: begin
                        mem_req_o.aw_valid  = 1'b1;
                        if (mem_resp_i.aw_ready) begin
                            wr_state_n  = W_DATA;
                        end
                    end
                    W_DATA: begin
                        mem_req_o.w_valid   = 1'b1;
                        if(mem_resp_i.w_ready) begin
                            wr_state_n  = B_RESP;
                        end
                    end
                    B_RESP: begin
                        if (mem_resp_i.b_valid) begin
                            mem_req_o.b_ready   = 1'b1;
                            if (mem_resp_i.b.resp != axi_pkg::RESP_OKAY) begin
                                state_n         = ERROR;
                                cqcsr_mf_o      = 1'b1;
                                cqcsr_mf_wen_o  = 1'b1;
                            end
                            else state_n = IDLE;
                        end
                    end
                    default: state_n = IDLE;
                endcase
            end

            // When an error occurs, the CQ stops processing commands until SW clear all error bits
            // If CQ IE is set, the cip bit in the ipsr must be set
            ERROR: begin
                mem_req_o.r_ready  = 1'b1;
                if (!error_vector)
                    state_n = IDLE;
            end

            default: state_n = IDLE;
        endcase
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        
        // Reset
        if (!rst_ni) begin
            state_q         <= IDLE;
            wr_state_q      <= AW_REQ;
            cq_en_q         <= 1'b0;
            cmd_q           <= '0;
            cq_pptr_q       <= '0;
        end

        else begin
            state_q         <= state_n;
            wr_state_q      <= wr_state_n;
            cq_en_q         <= cq_en_n;
            cmd_q           <= cmd_n;
            cq_pptr_q       <= cq_pptr_n;
        end
    end
    
endmodule
