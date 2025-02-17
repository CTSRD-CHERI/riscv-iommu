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
// Description: VIP emulating DTI-ATS from PCIe RC.
//

`timescale 1ps/1ps

`include "axi_stream/typedef.svh"
`include "axi_stream/assign.svh"

module pcie_ats_vip #(
  parameter int unsigned DATA_WIDTH = 160,
  parameter int unsigned ID_WIDTH = 1,
  parameter int unsigned DEST_WIDTH = 1,
  parameter int unsigned USER_WIDTH = 1,
  parameter int unsigned REFClockPeriod = 5ns,
  parameter type axis_req_t = logic,
  parameter type axis_rsp_t = logic
) (
  input logic clk_i,
  input logic rst_ni,
  output      axis_req_t axis_mst_req,
  input       axis_rsp_t axis_mst_rsp,
  input       axis_req_t axis_slv_req,
  output      axis_rsp_t axis_slv_rsp
);

  import rv_iommu_dti_ats_pkg::*;
  // These imports match the data types you already have (e.g. dti_ats_trans_req_s, etc.)
  // Make sure to import or include what is needed for your AXI drivers, too.

  // -------------------------------------------------
  // AXI Stream Drivers/Receivers
  // -------------------------------------------------
  AXI_STREAM_BUS_DV #(
    .DataWidth (DATA_WIDTH),
    .IdWidth   (ID_WIDTH),
    .DestWidth (DEST_WIDTH),
    .UserWidth (USER_WIDTH)
  ) master_dv (.clk_i(clk_i));

  AXI_STREAM_BUS #(
    .DataWidth (DATA_WIDTH),
    .IdWidth   (ID_WIDTH),
    .DestWidth (DEST_WIDTH),
    .UserWidth (USER_WIDTH)
  ) master();

  typedef axi_stream_test::axi_stream_driver #(
    .DataWidth ( DATA_WIDTH ),
    .IdWidth   ( ID_WIDTH   ),
    .DestWidth ( DEST_WIDTH ),
    .UserWidth ( USER_WIDTH ),
    .TestTime  ( 0.85*REFClockPeriod ),
    .ApplTime  ( 0.15*REFClockPeriod )
  ) master_drv_t;

  // Slave side
  AXI_STREAM_BUS_DV #(
    .DataWidth (DATA_WIDTH),
    .IdWidth   (ID_WIDTH),
    .DestWidth (DEST_WIDTH),
    .UserWidth (USER_WIDTH)
  ) slave_dv (.clk_i(clk_i));

  AXI_STREAM_BUS #(
    .DataWidth (DATA_WIDTH),
    .IdWidth   (ID_WIDTH),
    .DestWidth (DEST_WIDTH),
    .UserWidth (USER_WIDTH)
  ) slave();

  typedef axi_stream_test::axi_stream_driver #(
    .DataWidth ( DATA_WIDTH ),
    .IdWidth   ( ID_WIDTH   ),
    .DestWidth ( DEST_WIDTH ),
    .UserWidth ( USER_WIDTH ),
    .TestTime  ( 0.85*REFClockPeriod ),
    .ApplTime  ( 0.15*REFClockPeriod )
  ) slave_drv_t;

  slave_drv_t  slave_drv  = new(slave_dv);
  master_drv_t master_drv = new(master_dv);

  dti_ats_inv_req_s inv_req_q[$];
  dti_ats_inv_req_s     req_item;
  dti_ats_inv_ack_s     inv_ack;

  // Wiring macros
  `AXI_STREAM_ASSIGN          ( master, master_dv    )
  `AXI_STREAM_ASSIGN_TO_REQ   ( axis_mst_req, master )
  `AXI_STREAM_ASSIGN_FROM_RSP ( master, axis_mst_rsp )

  `AXI_STREAM_ASSIGN          ( slave_dv, slave      )
  `AXI_STREAM_ASSIGN_FROM_REQ ( slave, axis_slv_req  )
  `AXI_STREAM_ASSIGN_TO_RSP   ( axis_slv_rsp, slave  )

  // --------------------------------------------------------------------------
  // DTI-ATS VIP: tasks for PCIe/DTI side
  // --------------------------------------------------------------------------

  task automatic reset();
    // Initialize drivers
    master_drv.reset_tx();
    master_drv.reset_rx();
    slave_drv.reset_tx();
    slave_drv.reset_rx();
  endtask

  // Connect
  task automatic do_connect(
    inout  dti_ats_condis_req_s  con_req,
    inout  dti_ats_condis_ack_s  con_ack
  );
 
    bit dummy_last;
    con_req = '0;
    con_req.protocol          = 1'b1;
    con_req.state             = 1'b1;
    con_req.tok_inv_gnt       = 4'hF;
    con_req.tok_trans_req_lsb = 8'd64;

    $display("[DTI-ATS VIP] Sending Connect message: %p", con_req);
    master_drv.send(con_req, 1'b1); // tlast = 1

    // Wait on the 'slave' side for ack
    slave_drv.recv(con_ack,dummy_last);
    $display("[DTI-ATS VIP] Received Connect Ack: %p", con_ack);
  endtask

  // Disconnect
  task automatic do_disconnect(
    inout  dti_ats_condis_req_s  dis_req,
    inout  dti_ats_condis_ack_s  dis_ack
  );
    bit dummy_last;
    dis_req = '0;
    dis_req.protocol = 1'b1;

    $display("[DTI-ATS VIP] Sending Disconnect message: %p", dis_req);
    master_drv.send(dis_req, 1'b1);

    slave_drv.recv(dis_ack, dummy_last);
    $display("[DTI-ATS VIP] Received Disconnect Ack: %p", dis_ack);
  endtask

  // Send a single PCIe->DTI translation request
  task automatic pcie_send_trans_request(
    input  byte id,
    inout  dti_ats_trans_req_s trans_req_pcie
  );
    trans_req_pcie              = '0;
    trans_req_pcie.s_msg_type   = DTI_ATS_TRANS_REQ;
    trans_req_pcie.trans_id_lsb = id;
    trans_req_pcie.protocol     = 1'b1;
    trans_req_pcie.nW           = 1'b1; // example usage
    trans_req_pcie.PnU          = 1'b0;
    trans_req_pcie.InD          = 1'b0;
    trans_req_pcie.IA           = 52'hCAD2E9A + id;
    trans_req_pcie.sid          = 32'hDEADF00D;

    $display("[DTI-ATS VIP] Sending Translation Request (PCIe->DTI) id=%0d => %p",
             id, trans_req_pcie);
    master_drv.send(trans_req_pcie, 1'b1);
  endtask

  // Send N translation requests in a loop
  task automatic send_n_trans_requests(
    input  int  num_trans_req,
    inout  dti_ats_trans_req_s trans_req_pcie
  );
    for (int i = 0; i < num_trans_req; i++) begin
      pcie_send_trans_request(i, trans_req_pcie);
      #10ns; // small delay or wait a couple cycles, as needed
    end
  endtask

  // Receive the final DTI translation responses on the AXI (slave side)
  task automatic receive_dti_translation_responses(
    input  int num_expected,
    inout  dti_ats_trans_resp_s dti_trans_resp
  );
    int count_resp = 0;
    bit dummy_last;
    $display("[DTI-ATS VIP] Waiting to receive %0d DTI translation responses...", num_expected);

    while (count_resp < num_expected) begin
      slave_drv.recv(dti_trans_resp, dummy_last);
      $display("[DTI-ATS VIP] Received: %p", dti_trans_resp);

      if (dti_trans_resp.s_msg_type == DTI_ATS_TRANS_RESP) begin
        count_resp++;
      end
    end

    $display("[DTI-ATS VIP] All DTI translation responses received: %0d total.", count_resp);
  endtask

  // Receive a single invalidation request from the DUT on the slave interface.
  // Store or queue it up for later completion.
  task automatic do_recv_one_inv_req(
    inout  dti_ats_inv_req_s inv_req,
    input  int j
  );
    bit dummy_last;
    // If your .recv() signature needs only the struct:
    slave_drv.recv(inv_req, dummy_last);

    // Put into queue for ack
    inv_req_q.push_back(inv_req[j]);

    $display("[DTI-ATS VIP] Received Invalidation Req index=%0d: %p", j, inv_req);
  endtask

  // Receive 'count' invalidation requests in a loop
  task automatic do_receive_inv_requests(
    input  int count,
    inout  dti_ats_inv_req_s inv_req_array[],
    input  int bias
  );
    for(int j = bias; j < bias + count; j++) begin
      do_recv_one_inv_req(inv_req_array[j], j);
      #10ns;
    end
  endtask

  // Send out-of-order invalidation completions
  task automatic send_invalidation_completions(
    input  int count,
    input  dti_ats_inv_req_s inv_req_array[]
  );
    dti_ats_inv_comp_s inv_comp;
    for(int i = count-1; i >= 0; i--) begin
      inv_comp              = '0;
      inv_comp.s_msg_type   = DTI_ATS_INV_COMP;
      inv_comp.sid          = inv_req_array[i].sid;
      inv_comp.itag         = inv_req_array[i].itag;
      inv_comp.t            = inv_req_array[i].t;

      $display("[DTI-ATS VIP] Sending Inv Comp OOO for index=%0d: %p", i, inv_comp);
      master_drv.send(inv_comp, 1'b1);

      #10ns;
    end
  endtask // send_invalidation_completions

  initial begin : ack_process
      wait(rst_ni); // wait for reset
      forever begin
         @(posedge clk_i);

         if (inv_req_q.size() > 0) begin
            req_item = inv_req_q.pop_front();

            inv_ack          = '0;
            inv_ack.s_msg_type = DTI_ATS_INV_ACK;

            $display("[ACK_PROCESS] Sending Inv Ack itag=%0d: %p",
                     req_item.itag, inv_ack);
            master_drv.send(inv_ack, 1'b1);

            repeat(3) @(posedge clk_i);
         end
      end
  end


endmodule
