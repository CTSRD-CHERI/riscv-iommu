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
// Date: 18/02/2025
//
// Authors:
// - Maicol Ciani <maicol.ciani@unibo.it>
//
// Description: Top level testbench for IOMMU top module.
//

`timescale 1ps/1ps

module rv_iommu_top_tb;

  rv_iommu_top_fix fixture_i();

  initial begin
    wait(fixture_i.rst_ni)
    repeat(20)
      @(posedge fixture_i.clk_i);
    fixture_i.i_rv_iommu_vip.reset_drvs();
    $display("[MAIN TB] Configuring IOMMU");
    fixture_i.i_rv_iommu_vip.s2pt_init_hw();
    repeat(20)
      @(posedge fixture_i.clk_i);
    fixture_i.i_rv_iommu_vip.s1pt_init_hw();
    repeat(20)
      @(posedge fixture_i.clk_i);
    fixture_i.i_rv_iommu_vip.iommu_ddt_init_hw();
    repeat(20)
      @(posedge fixture_i.clk_i);
    fixture_i.i_rv_iommu_vip.iommu_cq_init();
    repeat(20)
      @(posedge fixture_i.clk_i);
    $display("[MAIN TB] End Configuration");
    repeat(20)
      @(posedge fixture_i.clk_i);

    fixture_i.dti_translation_request();
    repeat(20)
      @(posedge fixture_i.clk_i);

    $stop;
  end

endmodule
