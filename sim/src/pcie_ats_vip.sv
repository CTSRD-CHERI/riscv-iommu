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
// Date: 17/02/2025
//
// Authors:
// - Maicol Ciani <maicol.ciani@unibo.it>
//
//
// Description: "VIP module" for PCIe ATS, plus a class-based agent that
// implements tasks like connect/disconnect, sending translation requests, etc.
//

`timescale 1ps/1ps

`include "axi_stream/typedef.svh"
`include "axi_stream/assign.svh"

module pcie_ats_vip
  import rv_iommu_dti_ats_pkg::*;
  import pcie_ats_vip_pkg::*;
#(
  parameter int unsigned DATA_WIDTH = 160,
  parameter int unsigned ID_WIDTH   = 1,
  parameter int unsigned DEST_WIDTH = 1,
  parameter int unsigned USER_WIDTH = 1,
  parameter int unsigned REFClockPeriod = 5ns,
  parameter type axis_req_t = logic,
  parameter type axis_rsp_t = logic
) (
  input  logic clk_i,
  input  logic rst_ni,

  // AXI-Stream Master side (PCIe->DTI direction)
  output axis_req_t axis_mst_req,
  input  axis_rsp_t axis_mst_rsp,

  // AXI-Stream Slave side (DTI->PCIe direction)
  input  axis_req_t axis_slv_req,
  output axis_rsp_t axis_slv_rsp
);

  // --------------------------------------------------
  // AXI Stream Drivers/Receivers
  // These AXI_DV buses will be attached to the classes
  // --------------------------------------------------
  AXI_STREAM_BUS_DV #(
    .DataWidth (DATA_WIDTH),
    .IdWidth   (ID_WIDTH),
    .DestWidth (DEST_WIDTH),
    .UserWidth (USER_WIDTH)
  ) master_dv (.clk_i(clk_i));

  AXI_STREAM_BUS_DV #(
    .DataWidth (DATA_WIDTH),
    .IdWidth   (ID_WIDTH),
    .DestWidth (DEST_WIDTH),
    .UserWidth (USER_WIDTH)
  ) slave_dv  (.clk_i(clk_i));

  AXI_STREAM_BUS #(
    .DataWidth (DATA_WIDTH),
    .IdWidth   (ID_WIDTH),
    .DestWidth (DEST_WIDTH),
    .UserWidth (USER_WIDTH)
  ) master();

  AXI_STREAM_BUS #(
    .DataWidth (DATA_WIDTH),
    .IdWidth   (ID_WIDTH),
    .DestWidth (DEST_WIDTH),
    .UserWidth (USER_WIDTH)
  ) slave();

  // Wire up using macros
  `AXI_STREAM_ASSIGN          ( master, master_dv    )
  `AXI_STREAM_ASSIGN_TO_REQ   ( axis_mst_req, master )
  `AXI_STREAM_ASSIGN_FROM_RSP ( master, axis_mst_rsp )

  `AXI_STREAM_ASSIGN          ( slave_dv, slave      )
  `AXI_STREAM_ASSIGN_FROM_REQ ( slave, axis_slv_req  )
  `AXI_STREAM_ASSIGN_TO_RSP   ( axis_slv_rsp, slave  )

endmodule
