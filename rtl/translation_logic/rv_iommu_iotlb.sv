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
// Description: IO Translation Lookaside Buffer (IOTLB) for RISC-V IOMMU.
//              Compliant with the Sv39x4 virtual memory scheme, as defined
//              in the RISC-V Privileged Specification
//              This module is an adaptation of the Sv39 TLB developed
//              by Florian Zaruba and David Schaffenrath to the Sv39x4 standard.

module rv_iommu_iotlb #(
    /// RISC-V IOMMU configuration struct
    parameter rv_iommu_cfg::rv_iommu_cfg_t RVIOMMUCfg = rv_iommu_cfg::NullCfg
)(
    input  logic                        clk_i,
    input  logic                        rst_ni,

    // Flush
    input  rv_iommu::iotlb_inval_t      inval_i,

    // Update
    input  rv_iommu::iotlb_up_t         update_i,

    // Lookup
    input  logic                            lookup_i,
    input  logic [rv_iommu::GPPNW39-1:0]    lu_vpn_i,
    input  rv_iommu::pscid_t                lu_pscid_i,
    input  rv_iommu::gscid_t                lu_gscid_i,
    input  logic                            en_1S_i,
    input  logic                            en_2S_i,
    output logic                            lu_hit_o,
    output rv_iommu::iotlb_content_t        lu_content_o
);

    // Tags
    struct packed {
        logic [10:0]        vpn2;
        logic [8:0]         vpn1;
        logic [8:0]         vpn0;
        rv_iommu::pscid_t   pscid;
        rv_iommu::gscid_t   gscid;
        logic               en_1S;
        logic               en_2S;
        logic               valid;
    } [RVIOMMUCfg.NumIotlbEntries-1:0] tags_q, tags_n;

    // Contents
    rv_iommu::iotlb_content_t [RVIOMMUCfg.NumIotlbEntries-1:0] content_q, content_n;

    logic [8:0] vpn0, vpn1;
    logic [10:0] vpn2;
    logic [RVIOMMUCfg.NumIotlbEntries-1:0] lu_hit;
    logic [RVIOMMUCfg.NumIotlbEntries-1:0] replace_en;
    logic [RVIOMMUCfg.NumIotlbEntries-1:0] match_gscid;
    logic [RVIOMMUCfg.NumIotlbEntries-1:0] match_pscid;
    logic [RVIOMMUCfg.NumIotlbEntries-1:0] match_stage;
    logic [RVIOMMUCfg.NumIotlbEntries-1:0] is_1G;
    logic [RVIOMMUCfg.NumIotlbEntries-1:0] is_2M;

    //--------
    // Lookup
    //--------
    always_comb begin : lookup
        vpn0 = lu_vpn_i[8:0];
        vpn1 = lu_vpn_i[17:9];
        vpn2 = lu_vpn_i[rv_iommu::GPPNW39-1:18];

        lu_hit          = '{default: 0};
        lu_hit_o        = 1'b0;
        lu_content_o    = '{default: 0};

        match_pscid     = '{default: 0};
        match_gscid     = '{default: 0};
        match_stage     = '{default: 0};
        is_1G           = '{default: 0};
        is_2M           = '{default: 0};

        if (lookup_i) begin
            
            for (int unsigned i = 0; i < RVIOMMUCfg.NumIotlbEntries; i++) begin
        
                // PSCID match
                match_pscid[i] = (((lu_pscid_i == tags_q[i].pscid) || content_q[i].content_1S.g) && en_1S_i) || !en_1S_i;

                // GSCID match
                match_gscid[i] = (lu_gscid_i == tags_q[i].gscid && en_2S_i) || !en_2S_i;

                is_1G[i] = rv_iommu::is_trans_1G(   en_1S_i,
                                                    en_2S_i,
                                                    content_q[i].content_1S.is_1G,
                                                    content_q[i].content_2S.is_1G
                                                );

                is_2M[i] = rv_iommu::is_trans_2M(   en_1S_i,
                                                    en_2S_i,
                                                    content_q[i].content_1S.is_1G,
                                                    content_q[i].content_1S.is_2M,
                                                    content_q[i].content_2S.is_1G,
                                                    content_q[i].content_2S.is_2M
                                                );

                // Stage match
                match_stage[i] = (tags_q[i].en_2S == en_2S_i) && (tags_q[i].en_1S == en_1S_i);
                
                // Full match
                if (tags_q[i].valid && match_pscid[i] && match_gscid[i] && match_stage[i] && (vpn2 == tags_q[i].vpn2)) begin
                    
                    // 1G match | 2M match | 4k match
                    if (is_1G[i] || ((vpn1 == tags_q[i].vpn1) && (is_2M[i] || vpn0 == tags_q[i].vpn0))) begin
                        lu_content_o    = content_q[i];
                        lu_hit_o        = 1'b1;
                        lu_hit[i]       = 1'b1;
                    end
                end
            end
        end
    end

    //-------------------------
    // Invalidation and Update
    //-------------------------
    logic  [RVIOMMUCfg.NumIotlbEntries-1:0] vaddr_vpn0_match;
    logic  [RVIOMMUCfg.NumIotlbEntries-1:0] vaddr_vpn1_match;
    logic  [RVIOMMUCfg.NumIotlbEntries-1:0] vaddr_vpn2_match;
    logic  [RVIOMMUCfg.NumIotlbEntries-1:0] vaddr_4k_match;
    logic  [RVIOMMUCfg.NumIotlbEntries-1:0] vaddr_2M_match;
    logic  [RVIOMMUCfg.NumIotlbEntries-1:0] vaddr_1G_match;
    logic  [RVIOMMUCfg.NumIotlbEntries-1:0] gpaddr_gppn0_match;
    logic  [RVIOMMUCfg.NumIotlbEntries-1:0] gpaddr_gppn1_match;
    logic  [RVIOMMUCfg.NumIotlbEntries-1:0] gpaddr_gppn2_match;
    logic  [RVIOMMUCfg.NumIotlbEntries-1:0] gpaddr_4k_match;
    logic  [RVIOMMUCfg.NumIotlbEntries-1:0] gpaddr_2M_match;
    logic  [RVIOMMUCfg.NumIotlbEntries-1:0] gpaddr_1G_match;
    /*
        NOTE: 
        For IOTINVAL.GVMA command, any entry whose GVA maps to a GPA that matches 
        the given address in the ADDR field, and also matches the GSCID field, must be invalidated.
        This requires tagging entries with the GPA, which is hardware costly. A common implementation
        invalidates all entries that match the GSCID field.

        This implementation will assume the HW cost and perform the IOTINVAL.GVMA according to the specification.
    */
    logic  [RVIOMMUCfg.NumIotlbEntries-1:0] [(rv_iommu::GPPNW39-1):0] gppn;

    always_comb begin : update_flush
        tags_n    = tags_q;
        content_n = content_q;

        for (int unsigned i = 0; i < RVIOMMUCfg.NumIotlbEntries; i++) begin

            // GVA match
            vaddr_vpn0_match[i] = (inval_i.vpn[8:0] == tags_q[i].vpn0);
            vaddr_vpn1_match[i] = (inval_i.vpn[17:9] == tags_q[i].vpn1);
            vaddr_vpn2_match[i] = (inval_i.vpn[rv_iommu::VPNW39-1:18] == tags_q[i].vpn2[8:0]);

            vaddr_4k_match[i] = (vaddr_vpn2_match[i] && vaddr_vpn1_match[i] && vaddr_vpn0_match[i]);
            vaddr_2M_match[i] = (vaddr_vpn2_match[i] && vaddr_vpn1_match[i] && content_q[i].content_1S.is_2M);
            vaddr_1G_match[i] = (vaddr_vpn2_match[i] && content_q[i].content_1S.is_1G);

            // construct GPA's PPN according to first-stage pte data
            gppn[i] = rv_iommu::make_gppn(tags_q[i].en_1S, 
                                            content_q[i].content_1S.is_1G, content_q[i].content_1S.is_2M, 
                                            {tags_q[i].vpn2[8:0],tags_q[i].vpn1,tags_q[i].vpn0}, 
                                            content_q[i].content_1S.ppn);
            
            // GPA match
            gpaddr_gppn0_match[i] = (inval_i.vpn[8:0] == gppn[i][8:0]);
            gpaddr_gppn1_match[i] = (inval_i.vpn[17:9] == gppn[i][17:9]);
            gpaddr_gppn2_match[i] = (inval_i.vpn[rv_iommu::GPPNW39-1:18] == gppn[i][rv_iommu::GPPNW39-1:18]);

            gpaddr_4k_match[i] = (gpaddr_gppn2_match[i] && gpaddr_gppn1_match[i] && gpaddr_gppn0_match[i]);
            gpaddr_2M_match[i] = (gpaddr_gppn2_match[i] && gpaddr_gppn1_match[i] && content_q[i].content_2S.is_2M);
            gpaddr_1G_match[i] = (gpaddr_gppn2_match[i] && content_q[i].content_2S.is_1G);
            
            // IOTINVAL.VMA
            // Ensures that all previous stores made to the first-stage PTs by the harts, 
            // are observed by the IOMMU before all subsequent implicit reads from the IOMMU.
            // According to the value of GV, AV and PSCV, different entries are selected to be invalidated:
            /*
                |GV|AV|PSCV|

                |0 |0 |0   |    Invalidate all entries for all host address spaces (G-stage translation disabled), including those with G=1 
                                NOTE: Host address space entries are those with G-stage translation disabled. Some devices may be retained by the hypervisor or host OS
                |0 |0 |1   |    Invalidate all entries for the host address space identified by PSCID, except for those with G=1
                |0 |1 |0   |    Invalidate all entries identified by the IOVA in ADDR field, for all host address spaces, including those with G=1
                |0 |1 |1   |    Invalidate all entries identified by the IOVA in ADDR field, for the host address space identified by PSCID, except for those with G=1
                |1 |0 |0   |    Invalidate all entries for all address spaces associated to the VM identified by GSCID, including those with G=1
                |1 |0 |1   |    Invalidate all entries for the address space identified by PSCID, in the VM identified by GSCID, except for those with G=1
                |1 |1 |0   |    Invalidate all entries corresponding to the IOVA in ADDR field, associated to the VM identified by GSCID, including those with G=1
                |1 |1 |1   |    Invalidate all entries corresponding to the IOVA in ADDR field, for the VM address space identified by GSCID and PSCID.
            */
            if(inval_i.inval_vma) begin
                unique case ({inval_i.gv, inval_i.av, inval_i.pscv})
                    3'b000: begin
                        // all host address space entries are flushed
                        if(!tags_q[i].en_2S && tags_q[i].en_1S) begin
                            tags_n[i].valid = 1'b0;
                        end
                    end
                    3'b001: begin
                        // 2S disabled, 1S enabled, PSCID match, exclude global entries
                        if((!tags_q[i].en_2S && tags_q[i].en_1S) && (tags_q[i].pscid == inval_i.pscid) && !content_q[i].content_1S.g) begin
                            tags_n[i].valid = 1'b0;
                        end
                    end
                    3'b010: begin
                        // 2S disabled, 1S enabled, IOVA match, include global entries
                        if((!tags_q[i].en_2S && tags_q[i].en_1S) && 
                            (vaddr_4k_match[i] || vaddr_2M_match[i] || vaddr_1G_match[i])) begin
                                tags_n[i].valid = 1'b0;
                            end
                    end
                    3'b011: begin
                        // 2S disabled, 1S enabled, IOVA match, PSCID match, exclude global entries
                        if((!tags_q[i].en_2S && tags_q[i].en_1S) && 
                            (vaddr_4k_match[i] || vaddr_2M_match[i] || vaddr_1G_match[i]) &&
                              tags_q[i].pscid == inval_i.pscid && !content_q[i].content_1S.g) begin
                                tags_n[i].valid = 1'b0;
                            end
                    end
                    3'b100: begin
                        // 2S enabled, 1S enabled, GSCID match, include global mappings
                        if((tags_q[i].en_2S && tags_q[i].en_1S) && (tags_q[i].gscid == inval_i.gscid)) begin
                            tags_n[i].valid = 1'b0;
                        end
                    end
                    3'b101: begin
                        // 2S enabled, 1S enabled, GSCID and PSCID match, exclude global mappings
                        if( (tags_q[i].en_2S && tags_q[i].en_1S) && 
                            (tags_q[i].gscid == inval_i.gscid && tags_q[i].pscid == inval_i.pscid) &&
                             !content_q[i].content_1S.g) begin
                                tags_n[i].valid = 1'b0;
                            end
                    end
                    3'b110: begin
                        // 2S enabled, 1S enabled, GSCID and IOVA (39-bit GVA in this case) match, include global mappings
                        if( (tags_q[i].en_2S && tags_q[i].en_1S) && 
                            (vaddr_4k_match[i] || vaddr_2M_match[i] || vaddr_1G_match[i]) &&
                              tags_q[i].gscid == inval_i.gscid) begin
                                tags_n[i].valid = 1'b0;
                            end
                    end
                    3'b111: begin
                        // 2S enabled, 1S enabled, GSCID, PSCID and IOVA (39-bit GVA in this case) match, exclude global mappings
                        if( (tags_q[i].en_2S && tags_q[i].en_1S) && 
                            (vaddr_4k_match[i] || vaddr_2M_match[i] || vaddr_1G_match[i]) &&
                             (tags_q[i].gscid == inval_i.gscid && tags_q[i].pscid == inval_i.pscid) &&
                             !content_q[i].content_1S.g) begin
                                tags_n[i].valid = 1'b0;
                            end
                    end
                endcase
            end

            // IOTINVAL.GVMA
            // Ensures that all previous stores made to the 2S PTs by the harts 
            // are observed by the IOMMU before all subsequent implicit reads from the IOMMU.
            //
            // 1S entries whose GPA matches the ADDR field and GSCID field must be invalidated by these operations
            // According to the value of GV and AV, different entries are selected to be invalidated:
            /*
                |GV|AV|

                |0 |d |     Invalidate second-stage entries for all VM address spaces
                |1 |0 |     Invalidate second-stage entries for all VM address spaces identified by GSCID
                |1 |1 |     Invalidate second-stage entries corresponding to the IOVA (GPA) in the ADDR field, for all VM address spaces identified by GSCID.
            */
            else if(inval_i.inval_gvma) begin
                unique case ({inval_i.gv, inval_i.av})
                    2'b00, 2'b01: begin
                        // 2S enabled, 1S don't care
                        if(tags_q[i].en_2S) begin
                            tags_n[i].valid = 1'b0;
                        end
                    end
                    2'b10: begin
                        // 2S enabled, 1S don't care, GSCID match
                        if(tags_q[i].en_2S && tags_q[i].gscid == inval_i.gscid) begin
                            tags_n[i].valid = 1'b0;
                        end
                    end
                    2'b11: begin
                        // 2S enabled, 1S don't care, GSCID match, IOVA match
                        if(tags_q[i].en_2S && tags_q[i].gscid == inval_i.gscid && 
                           (gpaddr_4k_match[i] || gpaddr_2M_match[i] || gpaddr_1G_match[i])) begin
                            tags_n[i].valid = 1'b0;
                        end
                    end
                endcase
            end

            // update
            else if (update_i.update && replace_en[i]) begin

                tags_n[i] = '{
                    pscid:      update_i.pscid,
                    gscid:      update_i.gscid,
                    vpn2:       update_i.vpn[rv_iommu::GPPNW39-1:18],
                    vpn1:       update_i.vpn[17:9],
                    vpn0:       update_i.vpn[8:0],
                    en_1S:      en_1S_i,
                    en_2S:      en_2S_i,
                    valid:      1'b1
                };
                
                content_n[i] = update_i.content;
            end
        end
    end

    //-----------------------------------------------
    // PLRU - Pseudo Least Recently Used Replacement
    //-----------------------------------------------
    logic[(RVIOMMUCfg.NumIotlbEntries-2):0] plru_tree_q, plru_tree_n;

    always_comb begin : plru_replacement
        plru_tree_n = plru_tree_q;
        
        for (int unsigned i = 0; i < RVIOMMUCfg.NumIotlbEntries; i++) begin
            automatic int unsigned idx_base, shift, new_index;
            idx_base    = 0;
            shift       = 0;
            new_index   = 0;

            if (lu_hit[i]) begin
                for (int unsigned lvl = 0; lvl < $clog2(RVIOMMUCfg.NumIotlbEntries); lvl++) begin
                    idx_base = $unsigned((2**lvl)-1);
                    shift = $clog2(RVIOMMUCfg.NumIotlbEntries) - lvl;
                    new_index =  ~((i >> (shift-1)) & 32'b1);
                    plru_tree_n[idx_base + (i >> shift)] = new_index[0];
                end
            end
        end

        for (int unsigned i = 0; i < RVIOMMUCfg.NumIotlbEntries; i += 1) begin
            automatic logic en;
            automatic int unsigned idx_base, shift, new_index;
            en = 1'b1;

            for (int unsigned lvl = 0; lvl < $clog2(RVIOMMUCfg.NumIotlbEntries); lvl++) begin
                idx_base = $unsigned((2**lvl)-1);
                shift = $clog2(RVIOMMUCfg.NumIotlbEntries) - lvl;
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
        if(!rst_ni) begin
            tags_q      <= '{default: 0};
            content_q   <= '{default: 0};
            plru_tree_q <= '{default: 0};
        end else begin
            tags_q      <= tags_n;
            content_q   <= content_n;
            plru_tree_q <= plru_tree_n;
        end
    end

endmodule
