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
// Description: RISC-V IOMMU Device Directory Table Cache (DDTC).
//              Fully-associative cache to store Device Contexts.

module rv_iommu_ddtc #(
    /// RISC-V IOMMU configuration struct
    parameter rv_iommu_cfg::rv_iommu_cfg_t RVIOMMUCfg = rv_iommu_cfg::NullCfg,

    /// Device Context type
    parameter type dc_t = logic,
    /// DDTC update structure type
    parameter type ddtc_up_t = logic
)(
    input  logic                    clk_i,
    input  logic                    rst_ni,

    // Flush
    input  rv_iommu::xdtc_inval_t   inval_i,

    // Update
    input  ddtc_up_t                update_i,

    // Lookup
    input  logic                    lookup_i,
    input  rv_iommu::device_id_t    lu_did_i,
    output dc_t                     lu_content_o,
    output logic                    lu_hit_o
);

    // Tags
    struct packed {
        rv_iommu::device_id_t   device_id;
        logic                   valid;
    } [RVIOMMUCfg.NumDdtcEntries-1:0] tags_q, tags_n;

    // Contents
    dc_t [RVIOMMUCfg.NumDdtcEntries-1:0] content_q, content_n;

    // Replacement logic
    logic [RVIOMMUCfg.NumDdtcEntries-1:0] lu_hit;
    logic [RVIOMMUCfg.NumDdtcEntries-1:0] replace_en;

    //--------
    // Lookup
    //--------
    always_comb begin : lookup

        // default assignment
        lu_hit          = '{default: 0};
        lu_hit_o        = 1'b0;
        lu_content_o    = '{default: 0};

        if (lookup_i) begin

            for (int unsigned i = 0; i < RVIOMMUCfg.NumDdtcEntries; i++) begin
                
                // An entry match occurs if the entry is valid and if a device_id match occurs
                if (tags_q[i].valid && tags_q[i].device_id == lu_did_i) begin
                
                    lu_content_o    = content_q[i];
                    lu_hit_o        = 1'b1;
                    lu_hit[i]       = 1'b1;
                end
            end
        end
    end

    //-------------------------
    // Invalidation and Update
    //-------------------------
    /*
        IODIR.INVAL_DDT guarantees that any previous stores made by a RISC-V hart to the DDT are observed
        before all subsequent implicit reads from IOMMU to DDT. If DV is 0, then the command invalidates
        all DDT and PDT entries cached for all devices. If DV is 1, then the command invalidates cached leaf
        level DDT entry for the device identified by DID operand and all associated PDT entries.
    */
    always_comb begin : update_flush
        tags_n      = tags_q;
        content_n   = content_q;

        for (int unsigned i = 0; i < RVIOMMUCfg.NumDdtcEntries; i++) begin
            
            // overall flush flag
            if (inval_i.inval_ddtc) begin
                
                // DV = 0: Invalidate all DDTC entries
                if (!inval_i.dv) begin
                    tags_n[i].valid = 1'b0;
                end

                // DV = 1: Invalidate only the DDTC entry that matches given device_id
                else if (tags_q[i].device_id == inval_i.did) begin
                    tags_n[i].valid = 1'b0;
                end
            end

            // normal replacement
            else if (update_i.update && replace_en[i]) begin
                
                tags_n[i] = '{
                    device_id:  update_i.did,
                    valid:      1'b1
                };

                content_n[i] = update_i.dc;
            end
        end 
    end

    //----------------------------------------------
    // PLRU - Pseudo Least Recently Used Replacement
    //----------------------------------------------
    logic[(RVIOMMUCfg.NumDdtcEntries-2):0] plru_tree_q, plru_tree_n;

    always_comb begin : plru_replacement
        plru_tree_n = plru_tree_q;

        for (int unsigned i = 0; i < RVIOMMUCfg.NumDdtcEntries; i++) begin
            automatic int unsigned idx_base, shift, new_index;
            idx_base    = 0;
            shift       = 0;
            new_index   = 0;

            if (lu_hit[i]) begin
                for (int unsigned lvl = 0; lvl < $clog2(RVIOMMUCfg.NumDdtcEntries); lvl++) begin 
                    idx_base = $unsigned((2**lvl)-1);
                    shift = $clog2(RVIOMMUCfg.NumDdtcEntries) - lvl;
                    new_index =  ~((i >> (shift-1)) & 32'b1);
                    plru_tree_n[idx_base + (i >> shift)] = new_index[0];
                end
            end
        end

        for (int unsigned i = 0; i < RVIOMMUCfg.NumDdtcEntries; i += 1) begin
            automatic logic en;
            automatic int unsigned idx_base, shift, new_index;
            en = 1'b1;

            for (int unsigned lvl = 0; lvl < $clog2(RVIOMMUCfg.NumDdtcEntries); lvl++) begin
                idx_base = $unsigned((2**lvl)-1);
                shift = $clog2(RVIOMMUCfg.NumDdtcEntries) - lvl;
                new_index =  (i >> (shift-1)) & 32'b1;
                if (new_index[0]) begin
                    en &= plru_tree_q[idx_base + (i>>shift)];
                end else begin
                    en &= ~plru_tree_q[idx_base + (i>>shift)];
                end
            end
            replace_en[i] = en;
        end
    end

    // sequential process
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            tags_q      <= '{default: 0};
            content_q   <= '{default: 0};
            plru_tree_q <= '{default: 0};
        end
        else begin
            tags_q      <= tags_n;
            content_q   <= content_n;
            plru_tree_q <= plru_tree_n;
        end
    end

endmodule