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
// Description: RISC-V IOMMU Debug Interface Controller Module.

module rv_iommu_dbg_if_ctl
import rv_iommu_reg_pkg::*;
#(
    /// Translation request data type
    parameter type trans_req_data_t = logic,
    /// Debug response data type
    parameter type dbg_resp_t = logic
) (
    input  logic                clk_i,
    input  logic                rst_ni,

    // Debug registers
    input  iommu_reg2hw_tr_req_iova_reg_t   dbg_iova_i,
    input  iommu_reg2hw_tr_req_ctl_reg_t    dbg_ctl_i,
    output iommu_hw2reg_tr_response_reg_t   dbg_resp_o,
    output iommu_hw2reg_tr_req_ctl_reg_t    dbg_ctl_o,

    // Request port
    output trans_req_data_t req_data_o,
    output logic            req_valid_o,
    input  logic            req_ready_i,

    // Response port
    input  dbg_resp_t       resp_data_i,
    input  logic            resp_valid_i,
    output logic            resp_ready_o
);

    typedef enum logic { 
        IDLE    = 1'b0,
        ONGOING = 1'b1
    } dbg_if_ctl_state_t;
    dbg_if_ctl_state_t state_q, state_n;

    always_comb begin
        
        req_valid_o = 1'b0;

        // Request data
        req_data_o.iova             = {dbg_iova_i.vpn.q, 12'b0};
        req_data_o.did              = dbg_ctl_i.did.q;
        req_data_o.pid_valid        = dbg_ctl_i.pv.q;
        req_data_o.pid              = dbg_ctl_i.pid.q;
        req_data_o.priv             = dbg_ctl_i.priv.q;
        req_data_o.is_debug         = 1'b1;

        // RWX values
        unique case ({dbg_ctl_i.exe.q, dbg_ctl_i.nw.q})
            2'b00: req_data_o.ttype = rv_iommu::UNTRANSLATED_W;
            2'b01: req_data_o.ttype = rv_iommu::UNTRANSLATED_R;
            2'b10: req_data_o.ttype = rv_iommu::UNTRANSLATED_W;
            2'b11: req_data_o.ttype = rv_iommu::UNTRANSLATED_RX;
            default: req_data_o.ttype = rv_iommu::NONE;
        endcase

        // Response registers
        dbg_resp_o.fault.d          = resp_data_i.error;
        dbg_resp_o.pbmt.d           = resp_data_i.pbmt;
        dbg_resp_o.s.d              = resp_data_i.is_superpage;
        dbg_resp_o.ppn.d            = resp_data_i.ppn;
        dbg_resp_o.fault.de         = resp_valid_i;
        dbg_resp_o.pbmt.de          = resp_valid_i;
        dbg_resp_o.s.de             = resp_valid_i;
        dbg_resp_o.ppn.de           = resp_valid_i;

        resp_ready_o                = 1'b1;
        dbg_ctl_o.busy.d            = 1'b0;
        dbg_ctl_o.busy.de           = resp_valid_i;

        state_n = state_q;

        unique case (state_q)
            IDLE: begin
                
                if (dbg_ctl_i.go.q) begin
                    req_valid_o = 1'b1;
                    if (req_ready_i) begin
                        state_n = ONGOING;
                    end
                end
            end

            ONGOING: begin
                if (resp_valid_i) begin
                    state_n = IDLE;
                end
            end

            default: begin
                state_n = IDLE;
            end
        endcase

    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        
        if (!rst_ni) begin
            state_q    <= IDLE;
        end
        else begin
            state_q    <= state_n;
        end
    end
    
endmodule