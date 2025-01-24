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
// Description: Top level testbench for IOMMU's ATS DTI top module
//

`timescale 1ps/1ps

`include "axi_stream/typedef.svh"
`include "axi_stream/assign.svh"

import rv_iommu_dti_ats_pkg::*;

module rv_iommu_dti_ats_top_tb;

   localparam int unsigned REFClockPeriod = 5ns; // 200MHz

   // Axi Stream parameters
   localparam int unsigned DATA_WIDTH = 160;
   localparam int unsigned KEEP_WIDTH = DATA_WIDTH/8;
   localparam int unsigned STRB_WIDTH = DATA_WIDTH/8;
   localparam int unsigned ID_WIDTH   = 1;
   localparam int unsigned DEST_WIDTH = 1;
   localparam int unsigned USER_WIDTH = 1;

   typedef logic [DATA_WIDTH-1:0] tdata_t;
   typedef logic [ID_WIDTH-1:0]   tid_t;
   typedef logic [DEST_WIDTH-1:0] tdest_t;
   typedef logic [USER_WIDTH-1:0] tuser_t;
   typedef logic [STRB_WIDTH-1:0] tstrb_t;
   typedef logic [KEEP_WIDTH-1:0] tkeep_t;
   typedef logic                  tready_t;
   typedef logic                  tlast_t;

   `AXI_STREAM_TYPEDEF_ALL(axis, tdata_t, tstrb_t, tkeep_t, tid_t, tdest_t, tuser_t)

   logic clk_i;
   logic rst_ni;

   axis_req_t axis_mst_req, axis_slv_req;
   axis_rsp_t axis_mst_rsp, axis_slv_rsp;

////////////////////
/// DUT Instance ///
////////////////////

   dti_ats_top #(
      .DATA_WIDTH ( DATA_WIDTH ),
      .axis_req_t ( axis_req_t ),
      .axis_rsp_t ( axis_rsp_t )
   ) DuT (
      .clk_i  ( clk_i  ),
      .rst_ni ( rst_ni ),
      .axis_req_up_o ( axis_slv_req ),
      .axis_rsp_up_i ( axis_slv_rsp ),
      .axis_req_dn_i ( axis_mst_req ),
      .axis_rsp_dn_o ( axis_mst_rsp )
   );

//////////////////////////////////
/// AXI Stream Driver/Receiver ///
//////////////////////////////////

///////// Master driver //////////

   AXI_STREAM_BUS_DV #(
     .DataWidth ( DATA_WIDTH ),
     .IdWidth   ( ID_WIDTH   ),
     .DestWidth ( DEST_WIDTH ),
     .UserWidth ( USER_WIDTH )
   ) master_dv (
     .clk_i(clk_i)
   );

   AXI_STREAM_BUS #(
     .DataWidth ( DATA_WIDTH ),
     .IdWidth   ( ID_WIDTH   ),
     .DestWidth ( DEST_WIDTH ),
     .UserWidth ( USER_WIDTH )
   ) master();

     typedef axi_stream_test::axi_stream_driver #(
     .DataWidth ( DATA_WIDTH         ),
     .IdWidth   ( ID_WIDTH           ),
     .DestWidth ( DEST_WIDTH         ),
     .UserWidth ( USER_WIDTH         ),
     .TestTime  ( REFClockPeriod*0.9 ),
     .ApplTime  ( REFClockPeriod*0.1 )
   ) master_drv_t;

   master_drv_t master_drv = new(master_dv);

///////// Slave driver //////////

   AXI_STREAM_BUS_DV #(
     .DataWidth(DATA_WIDTH),
     .IdWidth  (ID_WIDTH),
     .DestWidth(DEST_WIDTH),
     .UserWidth(USER_WIDTH)
   ) slave_dv (
     .clk_i(clk_i)
   );

   AXI_STREAM_BUS #(
     .DataWidth(DATA_WIDTH),
     .IdWidth  (ID_WIDTH),
     .DestWidth(DEST_WIDTH),
     .UserWidth(USER_WIDTH)
   ) slave();

   typedef axi_stream_test::axi_stream_driver #(
     .DataWidth ( DATA_WIDTH         ),
     .IdWidth   ( ID_WIDTH           ),
     .DestWidth ( DEST_WIDTH         ),
     .UserWidth ( USER_WIDTH         ),
     .TestTime  ( REFClockPeriod*0.9 ),
     .ApplTime  ( REFClockPeriod*0.1 )
   ) slave_drv_t;

   slave_drv_t slave_drv = new(slave_dv);

///////// Assign to DUT strucutres //////////

   `AXI_STREAM_ASSIGN          ( master, master_dv    )
   `AXI_STREAM_ASSIGN_TO_REQ   ( axis_mst_req, master )
   `AXI_STREAM_ASSIGN_FROM_RSP ( master, axis_mst_rsp )
   `AXI_STREAM_ASSIGN          ( slave_dv, slave      )
   `AXI_STREAM_ASSIGN_FROM_REQ ( slave, axis_slv_req   )
   `AXI_STREAM_ASSIGN_TO_RSP   ( axis_slv_rsp, slave   )

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
   // Main test process
   initial begin
      logic [DATA_WIDTH-1:0] send_payload;
      logic [DATA_WIDTH-1:0] recv_payload;
      logic                  recv_last;

      // Initialize payload
      send_payload = 160'h0000_0000_0000_0000_0000_0000_0000_0030;

      // Wait for reset to complete
      wait(rst_ni);
      @(posedge clk_i);

      // Send a message from master to the DUT
      $display("Sending message: %h", send_payload);
      fork
         begin
            master_drv.send(send_payload, 1'b1); // Send payload with tlast=1
         end
         begin
            slave_drv.recv(recv_payload, recv_last); // Wait to receive from the slave interface
         end
      join

      // Verify the received message
      $display("Received message: %h", recv_payload);
      if (recv_payload === send_payload && recv_last === 1'b1) begin
         $display("Message received successfully.");
      end else begin
         $error("Message mismatch or tlast error. Expected: %h, Received: %h, tlast: %b",
                send_payload, recv_payload, recv_last);
      end

      // Simulation complete
      $stop;
   end

endmodule
