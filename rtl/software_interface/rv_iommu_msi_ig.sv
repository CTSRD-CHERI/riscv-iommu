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
// Description: RISC-V IOMMU MSI Interrupt Generation Module.

module rv_iommu_msi_ig #(
    /// RISC-V IOMMU configuration struct
    parameter rv_iommu_cfg::rv_iommu_cfg_t RVIOMMUCfg = rv_iommu_cfg::NullCfg,

    /// Address data type
    parameter type addr_t = logic,
    /// Physical address data type
    parameter type paddr_t = logic,

    /// Fault data type
    parameter type fault_data_t = logic,
    /// AXI data types
    parameter type axi_req_t    = logic,
    parameter type axi_resp_t   = logic
) (
    input  logic                    clk_i,
    input  logic                    rst_ni,

    input  logic                    msi_ig_en_i,

    // Interrupt pending bits
    input  logic [2:0]              intp_i,

    // Interrupt vectors
    input  logic [2:0][3:0]         intv_i,

    // MSI config table
    input  logic [15:0][53:0]       msi_addr_x_i,
    input  logic [15:0][31:0]       msi_data_x_i,
    input  logic [15:0]             msi_vec_masked_x_i,

    // MSI write error
    output fault_data_t             fault_data_o,
    output logic                    fault_valid_o,
    input  logic                    fault_ready_i,

    // Memory bus
    input  axi_resp_t               mem_resp_i,
    output axi_req_t                mem_req_o
);

    localparam int unsigned LOG2_INTVEC = (RVIOMMUCfg.NumIntVec == 1) ? 
                                (32'd1) : ($clog2(RVIOMMUCfg.NumIntVec));
    localparam int unsigned PLEN = RVIOMMUCfg.PAddrWidth;
    localparam int unsigned DLEN = RVIOMMUCfg.AxiDataWidth;

    // FSM States
    enum logic [1:0] {
        IDLE    = 2'b00,
        WRITE   = 2'b01,
        ERROR   = 2'b10
    }   state_q, state_n;

    // Write FSM states
    enum logic [1:0] {
        AW_REQ  = 2'b00,
        W_DATA  = 2'b01,
        B_RESP  = 2'b10
    }   wr_state_q, wr_state_n;

    // To detect rising edge transition of IP bits
    logic [2:0]  edged_q, edged_n;

    // Interrupt source selector
    logic [3:0]   intv_q, intv_n;

    // Pending interrupts
    logic [(RVIOMMUCfg.NumIntVec-1):0] pending_q, pending_n;

    paddr_t         msi_addr_q, msi_addr_n;
    logic [31:0]    msi_data_q, msi_data_n;

    always_comb begin : msi_generation_comb

        // Default values
        // AXI parameters
        // AW
        mem_req_o.aw        = '0;
        mem_req_o.aw.id     = 'd3;  // do not modify unless you know what you are doing
        mem_req_o.aw.addr   = addr_t'(msi_addr_q);
        mem_req_o.aw.len    = 8'd0;
        mem_req_o.aw.size   = 3'b011;
        mem_req_o.aw.burst  = axi_pkg::BURST_INCR;

        mem_req_o.aw_valid  = 1'b0;

        // W
        mem_req_o.w.data    = {{DLEN-32{1'b0}}, msi_data_q};
        mem_req_o.w.strb    = 8'b0000_1111;
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

        // Fault data
        fault_valid_o           = 1'b0;
        fault_data_o            = '0;
        fault_data_o.cause_code = rv_iommu::MSI_ST_ACCESS_FAULT;
        fault_data_o.iova       = addr_t'(msi_addr_q);

        state_n         = state_q;
        wr_state_n      = wr_state_q;
        msi_addr_n      = msi_addr_q;
        msi_data_n      = msi_data_q;
        edged_n         = edged_q;
        pending_n       = pending_q;

        unique case (state_q)
            
            // Monitor interrupt-pending bits. Select corresponding vector (addr, data and mask).
            IDLE: begin

                for (int unsigned i = 0; i < 3; i++) begin

                    // Prioritize pending messages
                    if (pending_q[intv_i[i][(LOG2_INTVEC-1):0]] && !msi_vec_masked_x_i[intv_i[i]]) begin

                        msi_addr_n = {msi_addr_x_i[intv_i[i]][PLEN-2-1:0], 2'b0};
                        msi_data_n = msi_data_x_i[intv_i[i]];

                        pending_n[intv_i[i][(LOG2_INTVEC-1):0]] = 1'b0;

                        state_n = WRITE;
                        break;  // Use break to set priority
                    end

                    // Incoming interrupt
                    else if (intp_i[i] && !edged_q[i] && msi_ig_en_i) begin
                        
                        edged_n[i] = 1'b1;

                        // IP bit was set in the last cycle, send MSI if vector is not masked
                        if (!msi_vec_masked_x_i[intv_i[i]]) begin

                            msi_addr_n = {msi_addr_x_i[intv_i[i]][PLEN-2-1:0], 2'b0};
                            msi_data_n = msi_data_x_i[intv_i[i]];

                            state_n = WRITE;
                        end

                        // if vector is masked, then save request
                        else begin
                            pending_n[intv_i[i][(LOG2_INTVEC-1):0]] = 1'b1;
                        end

                        break;  // Use break to set priority
                    end 
                end

                for (int unsigned j = 0; j < 3; j++) begin
                    
                    // Clear edged IP bits when input is clear
                    if (!intp_i[j] && edged_q[j]) begin
                        edged_n[j] = 1'b0;
                    end
                end
            end

            // Write MSI to the corresponding address
            WRITE: begin

                    if (wr_state_q == AW_REQ) begin
                        mem_req_o.aw_valid  = 1'b1;
                        if (mem_resp_i.aw_ready) begin
                            wr_state_n  = W_DATA;
                        end
                    end
                    else if (wr_state_q == W_DATA) begin
                        mem_req_o.w_valid   = 1'b1;
                        mem_req_o.w.last    = 1'b1;
                        if(mem_resp_i.w_ready) begin
                            wr_state_n  = B_RESP;
                        end
                    end
                    else if (wr_state_q == B_RESP) begin
                       if (mem_resp_i.b_valid) begin
                            mem_req_o.b_ready   = 1'b1;
                            state_n             = IDLE;
                            wr_state_n          = AW_REQ;
                            if (mem_resp_i.b.resp != axi_pkg::RESP_OKAY) begin
                                state_n = ERROR;
                            end
                        end
                    end
                    else
                        state_n = IDLE;
            end

            // We may receive an AXI or access error when writing
            ERROR: begin

                fault_valid_o = 1'b1;
                if (fault_ready_i) begin
                    state_n = IDLE;
                end
            end

            default: state_n = IDLE;
        endcase
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        
        if (!rst_ni) begin
            state_q         <= IDLE;
            wr_state_q      <= AW_REQ;
            edged_q         <= '0;
            pending_q       <= '0;
            msi_addr_q      <= '0;
            msi_data_q      <= '0;
        end

        else begin
            state_q         <= state_n;
            wr_state_q      <= wr_state_n;
            edged_q         <= edged_n;
            pending_q       <= pending_n;
            msi_addr_q      <= msi_addr_n;
            msi_data_q      <= msi_data_n;
        end
    end
    
endmodule
