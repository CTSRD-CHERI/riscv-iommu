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
// Date: 22/01/2025
//
// Authors:
// - Maicol Ciani <maicol.ciani@unibo.it>
//
// Description: Top level testbench for IOMMU's ATS DTI top module
//

`timescale 1ps/1ps

module rv_iommu_dti_ats_top_tb;

  rv_iommu_dti_ats_top_fix fixture_i();

  initial begin
    $display("[MAIN TB] Starting fixture test run...");
    fixture_i.dti_ats_standalone_test();
    $display("[MAIN TB] Completed fixture test run.");

    $stop;
  end

endmodule
