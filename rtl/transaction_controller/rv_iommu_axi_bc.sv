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
// Description: AXI 4-kiB Boundary Checker module for RISC-V IOMMU: 
//              Checks whether an AXI transaction crosses a 4-kiB address boundary, 
//              which is illegal in AXI4 transactions.

module rv_iommu_axi_bc #(
    /// Address data type
    parameter type addr_t = logic
) (
    // AxVALID
    input  logic                check_i,
    // AxADDR
    input  addr_t addr_i,
    // AxBURST
    input  axi_pkg::burst_t     burst_type_i,
    // AxLEN
    input  axi_pkg::len_t       burst_length_i,
    // AxSIZE
    input  axi_pkg::size_t      n_bytes_i,

    // To indicate valid requests or boundary violations
    output logic                allow_request_o
);

    addr_t fixed_faddr;
    assign fixed_faddr = (addr_i & 'hfff) + ('h1 << n_bytes_i);

    addr_t incr_faddr;
    assign incr_faddr = (addr_i & 'hfff) + ((addr_t'(burst_length_i) + 1) << (n_bytes_i - 1));

    logic [2:0] log2_len;
    addr_t wrap_boundary;
    addr_t wrap_faddr;
    always_comb begin : wrap_bursts
        
        // For wrap bursts, N of transfers must be {2, 4, 8, 16}
        // So, ARLEN must be {1, 3, 7, 15}
        unique case (burst_length_i)
            8'd1:    log2_len = 3'b001;
            8'd3:    log2_len = 3'b010;
            8'd7:    log2_len = 3'b011;
            8'd15:   log2_len = 3'b100;
            default: log2_len = 3'b111;  // invalid
        endcase

        // The lowest address within a wrapping burst
        // Wrap_Boundary = (INT(Start_Address / (Burst_Length x Number_Bytes))) x (Burst_Length x Number_Bytes)
        wrap_boundary   = (addr_i >> (log2_len + n_bytes_i)) << (log2_len + n_bytes_i);

        // Highest addr_i = Wrap_Boundary + (Burst_Length x Number_Bytes)
        wrap_faddr      = (wrap_boundary & 'hfff) + ((addr_t'(burst_length_i) + 1) << (n_bytes_i -1));
    end

    always_comb begin : boundary_check

        allow_request_o = 1'b0;

        unique case (burst_type_i)

            // The final address is Start Addr + size
            axi_pkg::BURST_FIXED: begin
                if ((fixed_faddr & ~('hfff)) == '0) begin
                    allow_request_o = check_i;
                end
            end

            // The final address is the Wrap Boundary (Lower address) + size of the transfer
            axi_pkg::BURST_WRAP: begin
                if (!(&log2_len) && ((wrap_faddr & ~('hfff)) == '0)) begin
                    allow_request_o  = check_i;     // Allow transaction
                end
            end

            // The final address is Start Addr + Burst_Length * Number_Bytes
            axi_pkg::BURST_INCR: begin
                if ((incr_faddr & ~('hfff)) == '0) begin
                    allow_request_o  = check_i;
                end
            end

            default:;
        endcase
    end
    
endmodule
