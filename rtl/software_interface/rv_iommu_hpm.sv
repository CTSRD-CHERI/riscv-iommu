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
// Description: RISC-V IOMMU Hardware Performance Monitor.

module rv_iommu_hpm 
import rv_iommu_reg_pkg::*;
#(
    /// RISC-V IOMMU configuration struct
    parameter rv_iommu_cfg::rv_iommu_cfg_t RVIOMMUCfg = rv_iommu_cfg::NullCfg
) (

    input  logic clk_i,
    input  logic rst_ni,

    // Event data
    input  rv_iommu::hpm_event_t events_i,

    // from HPM registers
    input  iommu_reg2hw_iocountinh_reg_t                                iocountinh_i,
    input  iommu_reg2hw_iohpmcycles_reg_t                               iohpmcycles_i,
    input  iommu_reg2hw_iohpmctr_reg_t [RVIOMMUCfg.NumHpmCounters-1:0]  iohpmctr_i,
    input  iommu_reg2hw_iohpmevt_reg_t [RVIOMMUCfg.NumHpmCounters-1:0]  iohpmevt_i,

    // to HPM registers
    output iommu_hw2reg_iohpmcycles_reg_t                               iohpmcycles_o,
    output iommu_hw2reg_iohpmctr_reg_t [RVIOMMUCfg.NumHpmCounters-1:0]  iohpmctr_o,
    output iommu_hw2reg_iohpmevt_reg_t [RVIOMMUCfg.NumHpmCounters-1:0]  iohpmevt_o,

    // ipsr
    output logic ipsr_pmip_o,
    output logic ipsr_pmip_wen_o
);

    // To signal event counters increment
    logic [RVIOMMUCfg.NumHpmCounters-1:0]  increment_ctr;

    // ID matching
    logic [RVIOMMUCfg.NumHpmCounters-1:0]  did_match;
    logic [RVIOMMUCfg.NumHpmCounters-1:0]  pid_match;
    logic [RVIOMMUCfg.NumHpmCounters-1:0]  gscid_match;
    logic [RVIOMMUCfg.NumHpmCounters-1:0]  pscid_match;

    // Interrupt wires
    logic [RVIOMMUCfg.NumHpmCounters:0]    hpm_ip;
    assign ipsr_pmip_o = 1'b1;
    assign ipsr_pmip_wen_o = |hpm_ip;

    logic                   edged_event_q, edged_event_n;
    rv_iommu::hpm_event_t   event_q, event_n;

    // Event and ID matching logic
    always_comb begin : event_logic

        for (int unsigned i = 0; i < RVIOMMUCfg.NumHpmCounters; i++) begin

            increment_ctr[i] = 1'b0;

            // ID matching
            did_match[i]    = (event_q.filters.did == iohpmevt_i[i].did_gscid.q);
            pid_match[i]    = (event_q.filters.pid_v && (event_q.filters.pid == iohpmevt_i[i].pid_pscid.q));
            gscid_match[i]  = (event_q.filters.gscid == iohpmevt_i[i].did_gscid.q[15:0]);
            pscid_match[i]  = (!event_q.filters.pscid_v || 
                                (event_q.filters.pscid == iohpmevt_i[i].pid_pscid.q));

            // Parse eventID
            if (event_q.valid && 
                rv_iommu::hpm_event_match(
                    rv_iommu::hpm_event_type_t'(iohpmevt_i[i].eventid.q), 
                    event_q.etype_msk)
                    ) begin
                
                // ID filtering
                unique case ({iohpmevt_i[i].idtype.q, iohpmevt_i[i].dv_gscv.q, iohpmevt_i[i].pv_pscv.q})

                    // process_id filtering
                    3'b001: begin
                        increment_ctr[i] = pid_match[i];
                    end

                    // device_id filtering
                    3'b010: begin

                        // DID_GSCID partial matching
                        if (iohpmevt_i[i].dmask.q) begin

                            // Get index of starting bit
                            for (int unsigned k = 0 ; k < 24; k++) begin
                                if (!iohpmevt_i[i].did_gscid.q[k]) begin

                                    // Increment if bits [23:(k+1)] match
                                    // If k = 23, match always occurs
                                    increment_ctr[i] = ((event_q.filters.did >> (k+1)) 
                                                        == (iohpmevt_i[i].did_gscid.q >> (k+1)));
                                    break;
                                end
                            end
                        end

                        // Do not perform partial matching
                        else
                            increment_ctr[i] = did_match[i];
                    end

                    // device_id and process_id filtering
                    3'b011: begin

                        // DID_GSCID partial matching (if PID_PSCID matches)
                        if (iohpmevt_i[i].dmask.q && pid_match[i]) begin

                            // Get index of starting bit
                            for (int unsigned k = 0 ; k < 24; k++) begin
                                if (!iohpmevt_i[i].did_gscid.q[k]) begin

                                    // Increment if bits [23:(k+1)] match
                                    increment_ctr[i] = ((event_q.filters.did >> (k+1)) 
                                                        == (iohpmevt_i[i].did_gscid.q >> (k+1)));
                                    break;
                                end
                            end
                        end

                        // Do not perform DID_GSCID partial matching
                        else
                            increment_ctr[i] = did_match[i] & pid_match[i];
                    end

                    // PSCID filtering
                    3'b101: begin
                        increment_ctr[i] = pscid_match[i];
                    end

                    // GSCID filtering
                    3'b110: begin
                        
                        if (event_q.filters.gscid_v) begin

                            // DID_GSCID partial matching
                            if (iohpmevt_i[i].dmask.q) begin

                                // Get index of starting bit
                                for (int unsigned k = 0 ; k < 16; k++) begin
                                    if (!iohpmevt_i[i].did_gscid.q[k]) begin

                                        // Increment if bits [15:(k+1)] match
                                        increment_ctr[i] = ((event_q.filters.gscid >> (k+1)) 
                                                            == (iohpmevt_i[i].did_gscid.q[15:0] >> (k+1)));
                                        break;
                                    end
                                end
                            end

                            // Do not perform partial matching
                            else
                                increment_ctr[i] = gscid_match[i];
                        end

                        else
                            // GSCID is not known for other events.
                            // Increment without comparing
                            increment_ctr[i] = 1'b1;
                    end

                    // GSCID and PSCID filtering
                    3'b111: begin

                        // PSCID is not known for other events.
                        if (event_q.filters.gscid_v) begin
                        
                            // DID_GSCID partial matching (if PID_PSCID matches)
                            if (iohpmevt_i[i].dmask.q && pscid_match[i]) begin

                                // Get index of starting bit
                                for (int unsigned k = 0 ; k < 16; k++) begin
                                    if (!iohpmevt_i[i].did_gscid.q[k]) begin

                                        // Increment if bits [15:(k+1)] match
                                        increment_ctr[i] = ((event_q.filters.gscid >> (k+1)) 
                                                            == (iohpmevt_i[i].did_gscid.q[15:0] >> (k+1)));
                                        break;
                                    end
                                end
                            end

                            // Do not perform DID_GSCID partial matching
                            else
                                increment_ctr[i] = gscid_match[i] & pscid_match[i];
                        end

                        else
                            // PSCID is not known for other events.
                            // Increment without comparing
                            increment_ctr[i] = 1'b1;
                    end

                    // No filter, increment counter
                    default: begin
                        increment_ctr[i] = 1'b1;
                    end
                endcase
            end
        end
    end

    // Counter increment logic
    always_comb begin : increment_counters

        // Free clock cycles counter value
        iohpmcycles_o.counter.de = ~iocountinh_i.cy.q;          // enable counting
        iohpmcycles_o.counter.d  = iohpmcycles_i.counter.q + 1; // always increment

        // set OF when counter enabled and == '1
        iohpmcycles_o.of.de = (~iocountinh_i.cy.q) & (&iohpmcycles_i.counter.q);
        iohpmcycles_o.of.d  = 1'b1;

        // also set ipsr.pmip if OF bit is clear
        hpm_ip[0]           = (~iocountinh_i.cy.q) & (&iohpmcycles_i.counter.q) & (!iohpmcycles_i.of.q);

        for (int unsigned j = 0; j < RVIOMMUCfg.NumHpmCounters; j++) begin
            
            // Default values for event counters
            iohpmctr_o[j].counter.de    = 1'b0;
            iohpmctr_o[j].counter.d     = iohpmctr_i[j].counter.q + 1;

            // Event OF flag
            iohpmevt_o[j].of.de         = 1'b0;
            iohpmevt_o[j].of.d          = 1'b1;

            hpm_ip[j+1]                 = 1'b0;
            
            // Increment event counter
            if ((increment_ctr[j]) && (~iocountinh_i.hpm.q[j])) begin
                
                iohpmctr_o[j].counter.de    = 1'b1;

                // enable OF setting when counter enabled, counter == '1 (will overflow) and event occurs
                iohpmevt_o[j].of.de         = (&iohpmctr_i[j].counter.q);

                // also set ipsr.pmip if the corresponding OF bit is clear
                hpm_ip[j+1]                 = (&iohpmctr_i[j].counter.q) & (!iohpmevt_i[j].of.q);
            end
        end
    end

    always_comb begin : edge_detection

        edged_event_n   = edged_event_q;
        event_n         = event_q;

        if (events_i.valid && !edged_event_q) begin
            event_n = events_i;
        end

        if (events_i.valid && edged_event_q) begin
            event_n.valid = 1'b0;
        end

        if (!events_i.valid && edged_event_q) begin
            edged_event_n = 1'b0;
            event_n.valid = 1'b0;
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin

        if (!rst_ni) begin
            edged_event_q   <= 1'b0;
            event_q         <= '0;
        end

        else begin
            edged_event_q   <= edged_event_n;
            event_q         <= event_n;
        end
        
    end

endmodule