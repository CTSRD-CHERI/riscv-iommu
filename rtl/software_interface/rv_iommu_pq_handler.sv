// Copyright (c) 2025 ETH Zurich, University of Bologna
//
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Author: Maicol Ciani <maicol.ciani@unibo.it>
// Date: 24/03/2025
//
// Description: RISC-V IOMMU Page Queue (PQ) handler module.
//

module rv_iommu_pq_handler #(
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

    // pqb
    input  rv_iommu::ppn_t              pqb_ppn_i,
    input  logic [4:0]                  pqb_size_i,

    // Queue indexes
    input  logic [31:0]                 pq_head_i,
    input  logic [31:0]                 pq_tail_i,
    output logic [31:0]                 pq_tail_o,
    output logic                        pq_tail_wen_o,

    // pqcsr
    input  logic                        pqcsr_en_i,
    input  logic                        pqcsr_ie_i,
    output logic                        pqcsr_on_o,
    output logic                        pqcsr_on_wen_o,
    output logic                        pqcsr_busy_o,
    output logic                        pqcsr_busy_wen_o,
    // Memory fault
    input  logic                        pqcsr_mf_i,
    output logic                        pqcsr_mf_o,
    output logic                        pqcsr_mf_wen_o,
    // Overflow
    input  logic                        pqcsr_of_i,
    output logic                        pqcsr_of_o,
    output logic                        pqcsr_of_wen_o,

    // ipsr
    output logic                        ipsr_pip_o,
    output logic                        ipsr_pip_wen_o,

    // Page input port
    input  rv_iommu::pq_record_t        pq_data_i,
    input  logic                        pq_valid_i,
    output logic                        pq_ready_o,

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
    paddr_t pq_pptr_q, pq_pptr_n;

    // To mask pqt after incrementing
    logic [31:0]    idx_mask;
    assign          idx_mask = ~({32{1'b1}} << (pqb_size_i+1));

    // Control busy signal to notice SW when is not possible to write to cqcsr
    logic pq_en_q, pq_en_n;

    /*
      From Spec: When the pqon bit reads 0, the IOMMU guarantees:
      When pqon reads 0, the IOMMU guarantees that there are no older 
      in-flight implicit writes to the queue memory and no
      further implicit writes will be generated to the queue memory.
    */
    assign pqcsr_on_o = (pq_en_q | pqcsr_en_i);
    assign pqcsr_on_wen_o = 1'b1;

    assign pqcsr_busy_o     = (pqcsr_en_i != pq_en_q);
    assign pqcsr_busy_wen_o = 1'b1;

    // ipsr.fip
    assign ipsr_fip_o       = pqcsr_ie_i;
    assign ipsr_fip_wen_o   = (pq_tail_i != (pq_head_i & idx_mask)) | pqcsr_mf_o | pqcsr_of_o;

    // To check if any error bit was cleared by SW
    logic  error_vector;
    assign error_vector     = (pqcsr_mf_i | pqcsr_of_i);

    // PQ Record register to save event data
    rv_iommu::pq_record_t pq_entry_q, pq_entry_n;

    // Counter to send all four PQ record DWs
    logic wr_cnt_q, wr_cnt_n;

    // While either error bit is set in pqcsr, the IOMMU discards the record
    // that led to the fault and all further fault records.
    assign pq_ready_o = (state_q == IDLE) | (state_q == ERROR);

    // Fault Queue handler FSM
    always_comb begin : pq_handler_comb

        // Default values
        // AXI parameters
        // AW
        mem_req_o.aw        = '0;
        mem_req_o.aw.id     = 'd1;  // do not change unless you know what you are doing
        mem_req_o.aw.addr   = addr_t'(pq_pptr_q);
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

        pq_tail_o       = pq_tail_i;
        pq_tail_wen_o   = 1'b1;
        pqcsr_mf_o      = 1'b0;
        pqcsr_mf_wen_o  = 1'b0;
        pqcsr_of_o      = 1'b0;
        pqcsr_of_wen_o  = 1'b0;

        state_n         = state_q;
        wr_state_n      = wr_state_q;
        pq_pptr_n       = pq_pptr_q;
        pq_entry_n      = pq_entry_q;
        wr_cnt_n        = wr_cnt_q;
        pq_en_n         = pq_en_q;

        unique case (state_q)

            // Monitor possible faults
            IDLE: begin

                if (pqcsr_en_i) begin
                    // PQ was recently enabled by SW. Clear pq_tail, pqmf, and pqof
                    if (!pq_en_q) begin
                        pq_tail_o       = '0;
                        pqcsr_mf_wen_o  = 1'b1;
                        pqcsr_of_wen_o  = 1'b1;

                        pq_en_n         = 1'b1;
                    end

                    // If a fault that must be reported occurs and the PQ is full, set pq_of and signal error
                    else if (pq_valid_i) begin

                        if (pq_tail_i == ((pq_head_i - 1) & idx_mask)) begin
                            pqcsr_of_o      = 1'b1;
                            pqcsr_of_wen_o  = 1'b1;
                            state_n         = ERROR;
                        end

                        else begin
                            state_n     = WRITE;
                            wr_state_n  = AW_REQ;

                            pq_entry_n = pq_data_i;
                            pq_pptr_n = ({pqb_ppn_i[PPNW-1:0], 12'b0}) | ({{PLEN-32{1'b0}}, pq_tail_i} << 5);
                        end
                    end
                end

                // Check if EN signal was recently cleared by SW
                else if (pq_en_q) begin
                    pq_en_n = 1'b0;
                end
            end

            // Write PQ Record
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
                        if(!wr_cnt_q) begin
                           mem_req_o.w.data[((64*0) & (RVIOMMUCfg.AxiDataWidth-1))+:64] = pq_entry_q[63:0];
                        end else begin
                           mem_req_o.w.data[((64*1) & (RVIOMMUCfg.AxiDataWidth-1))+:64] = pq_entry_q[127:64];
                           mem_req_o.w.last = 1'b1;
                        end
                        mem_req_o.w_valid = 1'b1;
                        if(mem_resp_i.w_ready) begin
                            wr_cnt_n = wr_cnt_q + 1;
                            if (wr_cnt_q) begin
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
                                pqcsr_mf_o      = 1'b1;
                                pqcsr_mf_wen_o  = 1'b1;
                            end

                            // After writing PQ record we can go back to IDLE
                            else begin
                                pq_tail_o       = (pq_tail_i + 1) & idx_mask;
                                state_n         = IDLE;
                            end
                        end
                    end

                    default: state_n = IDLE;
                endcase
            end

            // When an error occurs, the PQ stops generating faults until SW clear all error bits
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
            pq_pptr_q       <= '0;
            pq_entry_q      <= '0;
            pq_en_q         <= 1'b0;
            wr_cnt_q        <= '0;
        end

        else begin
            state_q         <= state_n;
            wr_state_q      <= wr_state_n;
            pq_pptr_q       <= pq_pptr_n;
            pq_entry_q      <= pq_entry_n;
            pq_en_q         <= pq_en_n;
            wr_cnt_q        <= wr_cnt_n;
        end
    end

endmodule
