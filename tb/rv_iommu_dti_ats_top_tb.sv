// Copyright 2025 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Author: Maicol Ciani, University of Bologna <maicol.ciani@unibo.it>
// Date: 22/01/2025
//
// Description: Top level testbench module for IOMMU's ATS DTI top module
//

`timescale 1ps/1ps


module rv_iommu_dti_ats_top_tb;

   localparam int unsigned REFClockPeriod = 5ns; // 200MHz

   logic clk_i;
   logic rst_ni;


////////////////////
/// DUT Instance ///
////////////////////

   dti_ats_top #(
      .DATA_WIDTH ( 160 ),
      .axis_req_t (     ),
      .axis_rsp_t (     )
   ) DuT (
      .clk_i  ( clk_i  ),
      .rst_ni ( rst_ni ),
      .axis_req_up_o (        ),
      .axis_rsp_up_i (        ),
      .axis_req_dn_i (        ),
      .axis_rsp_dn_o (        )
   );

///////////////////////////
/// Processes and Tasks ///
///////////////////////////

   // Clock process
   initial begin
      clk_i = '0;
      forever
        #(REFClockPeriod/2) clk_i=~clk_i;
   end

   // Reset process
   initial begin
       rst_ni = 1'b0;
       repeat(100)
           @(posedge clk_i);
       rst_ni = 1'b1;
   end

endmodule
