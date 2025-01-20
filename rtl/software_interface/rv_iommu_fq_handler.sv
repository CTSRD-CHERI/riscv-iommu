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
// Description: RISC-V IOMMU Fault Queue (FQ) handler module.
//              This module registers a new fault record into the FQ 
//              upon any translation-related fault.

module rv_iommu_fq_handler #(
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
    input  logic                        clk_i,
    input  logic                        rst_ni,

    // fqb
    input  rv_iommu::ppn_t              fqb_ppn_i,
    input  logic [4:0]                  fqb_size_i,

    // Queue indexes
    input  logic [31:0]                 fq_head_i,
    input  logic [31:0]                 fq_tail_i,
    output logic [31:0]                 fq_tail_o,
    output logic                        fq_tail_wen_o,

    // fqcsr
    input  logic                        fqcsr_en_i,
    input  logic                        fqcsr_ie_i,
    output logic                        fqcsr_on_o,
    output logic                        fqcsr_on_wen_o,
    output logic                        fqcsr_busy_o,
    output logic                        fqcsr_busy_wen_o,
    // Memory fault
    input  logic                        fqcsr_mf_i,
    output logic                        fqcsr_mf_o,
    output logic                        fqcsr_mf_wen_o,
    // Overflow
    input  logic                        fqcsr_of_i,
    output logic                        fqcsr_of_o,
    output logic                        fqcsr_of_wen_o,

    // ipsr
    output logic                        ipsr_fip_o,
    output logic                        ipsr_fip_wen_o,

    // Fault input port
    input  rv_iommu::fq_record_t        fq_data_i,
    input  logic                        fq_valid_i,
    output logic                        fq_ready_o,

    // Memory Bus
    input  axi_resp_t   mem_resp_i,
    output axi_req_t    mem_req_o
);

    localparam int unsigned PLEN = RVIOMMUCfg.PAddrWidth;
    localparam int unsigned PPNW = PLEN-12;

    // FSM States
    enum logic [1:0] {
        IDLE,
        WRITE,
        ERROR
    }   state_q, state_n;

    // Write FSM states
    enum logic [1:0] {
        AW_REQ,
        W_DATA,
        B_RESP
    }   wr_state_q, wr_state_n;

    // Physical pointer to access memory
    paddr_t fq_pptr_q, fq_pptr_n;

    // To mask fqt after incrementing
    logic [31:0]    idx_mask;
    assign          idx_mask = ~({32{1'b1}} << (fqb_size_i+1));

    // Control busy signal to notice SW when is not possible to write to cqcsr
    logic fq_en_q, fq_en_n;

    /* 
      From Spec: When the fqon bit reads 0, the IOMMU guarantees:
        (i)  That there are no in-flight implicit writes to the FQ in progress;
        (ii) No new fault records will be written to the fault-queue.
    */
    assign fqcsr_on_o = (fq_en_q | fqcsr_en_i);
    assign fqcsr_on_wen_o = 1'b1;

    assign fqcsr_busy_o     = (fqcsr_en_i != fq_en_q);
    assign fqcsr_busy_wen_o = 1'b1;

    // ipsr.fip
    assign ipsr_fip_o       = fqcsr_ie_i;
    assign ipsr_fip_wen_o   = (fq_tail_i != (fq_head_i & idx_mask)) | fqcsr_mf_o | fqcsr_of_o;

    // To check if any error bit was cleared by SW
    logic  error_vector;
    assign error_vector     = (fqcsr_mf_i | fqcsr_of_i);

    // FQ Record register to save event data
    rv_iommu::fq_record_t fq_entry_q, fq_entry_n;

    // Counter to send all four FQ record DWs
    logic [1:0] wr_cnt_q, wr_cnt_n;

    // While either error bit is set in fqcsr, the IOMMU discards the record 
    // that led to the fault and all further fault records.
    assign fq_ready_o = (state_q == IDLE) | (state_q == ERROR);

    // Fault Queue handler FSM
    always_comb begin : fq_handler_comb
        
        // Default values
        // AXI parameters
        // AW
        mem_req_o.aw        = '0;
        mem_req_o.aw.id     = 'd1;  // do not change unless you know what you are doing
        mem_req_o.aw.addr   = addr_t'(fq_pptr_q);
        mem_req_o.aw.len    = 8'd3;
        mem_req_o.aw.size   = 3'b011;
        mem_req_o.aw.burst  = axi_pkg::BURST_INCR;

        mem_req_o.aw_valid  = 1'b0;

        // W
        mem_req_o.w.data    = '0;
        mem_req_o.w.strb    = '1;
        mem_req_o.w.last    = 1'b0;
        mem_req_o.w.user    = '0;

        mem_req_o.w_valid   = 1'b0;

        // B
        mem_req_o.b_ready   = 1'b0;

        // AR
        mem_req_o.ar        = '0;
        mem_req_o.ar_valid  = 1'b0;

        // R
        mem_req_o.r_ready   = 1'b1;

        fq_tail_o       = fq_tail_i;
        fq_tail_wen_o   = 1'b1;
        fqcsr_mf_o      = 1'b0;
        fqcsr_mf_wen_o  = 1'b0;
        fqcsr_of_o      = 1'b0;
        fqcsr_of_wen_o  = 1'b0;

        state_n         = state_q;
        wr_state_n      = wr_state_q;
        fq_pptr_n       = fq_pptr_q;
        fq_entry_n      = fq_entry_q;
        wr_cnt_n        = wr_cnt_q;
        fq_en_n         = fq_en_q;

        unique case (state_q)

            // Monitor possible faults
            IDLE: begin

                if (fqcsr_en_i) begin
                    // FQ was recently enabled by SW. Clear fq_tail, fqmf, and fqof
                    if (!fq_en_q) begin
                        fq_tail_o       = '0;
                        fqcsr_mf_wen_o  = 1'b1;
                        fqcsr_of_wen_o  = 1'b1;

                        fq_en_n         = 1'b1;
                    end

                    // If a fault that must be reported occurs and the FQ is full, set fq_of and signal error
                    else if (fq_valid_i) begin
                    
                        if (fq_tail_i == ((fq_head_i - 1) & idx_mask)) begin
                            fqcsr_of_o      = 1'b1;
                            fqcsr_of_wen_o  = 1'b1;
                            state_n         = ERROR;
                        end

                        else begin
                            state_n     = WRITE;
                            wr_state_n  = AW_REQ;

                            fq_entry_n = fq_data_i;
                            fq_pptr_n = ({fqb_ppn_i[PPNW-1:0], 12'b0}) | ({{PLEN-32{1'b0}}, fq_tail_i} << 5);
                        end
                    end
                end

                // Check if EN signal was recently cleared by SW
                else if (fq_en_q) begin
                    fq_en_n = 1'b0;
                end
            end

            // Write FQ Record
            WRITE: begin
                unique case (wr_state_q)
                    AW_REQ: begin
                        mem_req_o.aw_valid  = 1'b1;
                        if (mem_resp_i.aw_ready) begin
                            wr_state_n  = W_DATA;
                            wr_cnt_n    = '0;
                        end
                    end
                    W_DATA: begin
                        unique case (wr_cnt_q)
                            2'b00: mem_req_o.w.data[((64*0) & (RVIOMMUCfg.AxiDataWidth-1))+:64] = fq_entry_q[63:0];
                            2'b01: mem_req_o.w.data = '0;
                            2'b10: mem_req_o.w.data[((64*2) & (RVIOMMUCfg.AxiDataWidth-1))+:64] = fq_entry_q[127:64];
                            2'b11: begin
                                mem_req_o.w.data[((64*3) & (RVIOMMUCfg.AxiDataWidth-1))+:64]    = fq_entry_q[191:128];
                                mem_req_o.w.last = 1'b1;
                            end
                        endcase
                        mem_req_o.w_valid = 1'b1;
                        if(mem_resp_i.w_ready) begin
                            wr_cnt_n = wr_cnt_q + 1;
                            if (&wr_cnt_q) begin
                                wr_state_n = B_RESP;
                            end
                        end
                    end

                    // Check response code
                    B_RESP: begin
                        if (mem_resp_i.b_valid) begin
                            
                            mem_req_o.b_ready   = 1'b1;
                            wr_state_n          = AW_REQ;
                            
                            if (mem_resp_i.b.resp != axi_pkg::RESP_OKAY) begin
                                // AXI error
                                state_n         = ERROR;
                                fqcsr_mf_o      = 1'b1;
                                fqcsr_mf_wen_o  = 1'b1;
                            end

                            // After writing FQ record we can go back to IDLE
                            else begin
                                fq_tail_o       = (fq_tail_i + 1) & idx_mask;
                                state_n         = IDLE;
                            end
                        end
                    end

                    default: state_n = IDLE;
                endcase
            end

            // When an error occurs, the FQ stops generating faults until SW clear all error bits
            ERROR: begin
                if (!error_vector)
                    state_n = IDLE;
            end

            default: state_n = IDLE;
        endcase
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q         <= IDLE;
            wr_state_q      <= AW_REQ;
            fq_pptr_q       <= '0;
            fq_entry_q      <= '0;
            fq_en_q         <= 1'b0;
            wr_cnt_q        <= '0;
        end

        else begin
            state_q         <= state_n;
            wr_state_q      <= wr_state_n;
            fq_pptr_q       <= fq_pptr_n;
            fq_entry_q      <= fq_entry_n;
            fq_en_q         <= fq_en_n;
            wr_cnt_q        <= wr_cnt_n;
        end
    end

endmodule