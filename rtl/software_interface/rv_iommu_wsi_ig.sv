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
// Description: RISC-V IOMMU WSI Interrupt Generation Module.

module rv_iommu_wsi_ig #(
    /// RISC-V IOMMU configuration struct
    parameter rv_iommu_cfg::rv_iommu_cfg_t RVIOMMUCfg = rv_iommu_cfg::NullCfg
) (
    
    // fctl.wsi
    input  logic wsi_en_i,

    // Interrupt pending bits
    input  logic [2:0] intp_i,

    // Interrupt vectors
    input  logic [2:0][3:0] intv_i,

    // interrupt wires
    output logic [(RVIOMMUCfg.NumIntVec-1):0] wsi_wires_o
);

    localparam int unsigned LOG2_INTVEC = (RVIOMMUCfg.NumIntVec == 1) ? (32'd1) : 
                                            ($clog2(RVIOMMUCfg.NumIntVec));

    always_comb begin : wsi_support_comb
            
        wsi_wires_o = '0;

        for (int unsigned i = 0; i < 3; i++) begin
            wsi_wires_o[intv_i[i][(LOG2_INTVEC-1):0]] = intp_i[i] & wsi_en_i;
        end
    end
    
endmodule