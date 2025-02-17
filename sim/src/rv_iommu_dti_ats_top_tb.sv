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

`include "axi_stream/typedef.svh"
`include "axi_stream/assign.svh"

import rv_iommu_dti_ats_pkg::*;

module rv_iommu_dti_ats_top_tb;

  // -------------------------------------------------
  // Parameters and Typedefs
  // -------------------------------------------------
  localparam int unsigned REFClockPeriod = 5ns; // 200MHz

  // AXI Stream parameters
  localparam int unsigned DATA_WIDTH = 160;
  localparam int unsigned KEEP_WIDTH = DATA_WIDTH/8;
  localparam int unsigned STRB_WIDTH = DATA_WIDTH/8;
  localparam int unsigned ID_WIDTH   = 1;
  localparam int unsigned DEST_WIDTH = 1;
  localparam int unsigned USER_WIDTH = 1;

  localparam int unsigned NUM_INV = 16;
  localparam int unsigned NUM_REP = 1;
  localparam int unsigned NUM_TRANS_REQ = 32;

  typedef logic [DATA_WIDTH-1:0] tdata_t;
  typedef logic [ID_WIDTH-1:0]   tid_t;
  typedef logic [DEST_WIDTH-1:0] tdest_t;
  typedef logic [USER_WIDTH-1:0] tuser_t;
  typedef logic [STRB_WIDTH-1:0] tstrb_t;
  typedef logic [KEEP_WIDTH-1:0] tkeep_t;
  typedef logic                  tready_t;
  typedef logic                  tlast_t;

  `AXI_STREAM_TYPEDEF_ALL(axis, tdata_t, tstrb_t, tkeep_t, tid_t, tdest_t, tuser_t)

  // -------------------------------------------------
  // DUT IO Signals
  // -------------------------------------------------
  logic clk_i;
  logic rst_ni;

  int count_rcvd = 0;
  int count_resp = 0;

  // Core to IOMMU invalidation interface
  logic                  cq_inv_valid;
  logic                  cq_inv_ready;
  rv_iommu_cq_inv_req_s  cq_inv_req;

  // AXI-Stream for the DTI module
  axis_req_t axis_mst_req, axis_slv_req;
  axis_rsp_t axis_mst_rsp, axis_slv_rsp;

  // IOMMU <-> DTI translation interface
  rv_iommu_trans_req_s  trans_req;
  rv_iommu_trans_resp_s trans_resp;
  logic trans_req_valid,  trans_req_ready;
  logic trans_resp_valid, trans_resp_ready;

  // Additional signals
  logic         recv_last;
  logic         send_ack;
  logic         timeout;

  // For con/dis connect
  dti_ats_condis_req_s  condis_con_req, condis_discon_req;
  dti_ats_condis_ack_s  condis_con_ack, condis_discon_ack;

  // Invalidation
  dti_ats_inv_req_s     inv_req[100];
  dti_ats_inv_ack_s     inv_ack;
  dti_ats_inv_comp_s    inv_comp;

  // Translation request from PCIe side (DTI-ATS)
  dti_ats_trans_req_s  trans_req_pcie;
  dti_ats_trans_resp_s dti_trans_resp;

  // We'll also see DTI-ATS trans responses on the AXI stream eventually.

  // Sync
  dti_ats_sync_req_s    sync_req;
  dti_ats_sync_ack_s    sync_ack;

  rv_iommu_trans_req_s  local_req;

  dti_ats_inv_req_s inv_req_q[$];

  // -------------------------------------------------
  // AXI Stream Drivers/Receivers
  // -------------------------------------------------
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
    .DataWidth ( DATA_WIDTH ),
    .IdWidth   ( ID_WIDTH   ),
    .DestWidth ( DEST_WIDTH ),
    .UserWidth ( USER_WIDTH ),
    .TestTime  ( 0.85*REFClockPeriod ),
    .ApplTime  ( 0.15*REFClockPeriod )
  ) master_drv_t;

  master_drv_t master_drv = new(master_dv);

  // Slave driver
  AXI_STREAM_BUS_DV #(
    .DataWidth ( DATA_WIDTH ),
    .IdWidth   ( ID_WIDTH   ),
    .DestWidth ( DEST_WIDTH ),
    .UserWidth ( USER_WIDTH )
  ) slave_dv (
    .clk_i(clk_i)
  );

  AXI_STREAM_BUS #(
    .DataWidth ( DATA_WIDTH ),
    .IdWidth   ( ID_WIDTH   ),
    .DestWidth ( DEST_WIDTH ),
    .UserWidth ( USER_WIDTH )
  ) slave();

  typedef axi_stream_test::axi_stream_driver #(
    .DataWidth ( DATA_WIDTH ),
    .IdWidth   ( ID_WIDTH   ),
    .DestWidth ( DEST_WIDTH ),
    .UserWidth ( USER_WIDTH ),
    .TestTime  ( 0.85*REFClockPeriod ),
    .ApplTime  ( 0.15*REFClockPeriod )
  ) slave_drv_t;

  slave_drv_t slave_drv = new(slave_dv);

  // Wiring macros
  `AXI_STREAM_ASSIGN          ( master, master_dv    )
  `AXI_STREAM_ASSIGN_TO_REQ   ( axis_mst_req, master )
  `AXI_STREAM_ASSIGN_FROM_RSP ( master, axis_mst_rsp )

  `AXI_STREAM_ASSIGN          ( slave_dv, slave      )
  `AXI_STREAM_ASSIGN_FROM_REQ ( slave, axis_slv_req  )
  `AXI_STREAM_ASSIGN_TO_RSP   ( axis_slv_rsp, slave  )

  // -------------------------------------------------
  // DUT Instance
  // -------------------------------------------------
  dti_ats_top #(
    .DATA_WIDTH ( DATA_WIDTH ),
    .axis_req_t ( axis_req_t ),
    .axis_rsp_t ( axis_rsp_t )
  ) DuT (
    .clk_i  ( clk_i  ),
    .rst_ni ( rst_ni ),

    // AXI-Stream Up (DUT's "slave" side, TB receives from it)
    .axis_req_up_o ( axis_slv_req ),
    .axis_rsp_up_i ( axis_slv_rsp ),

    // AXI-Stream Down (DUT's "master" side, TB drives it)
    .axis_req_dn_i ( axis_mst_req ),
    .axis_rsp_dn_o ( axis_mst_rsp ),

    // Invalidation interface
    .iommu_to_dti_inv_req_i   ( cq_inv_req   ),
    .iommu_to_dti_inv_valid_i ( cq_inv_valid ),
    .iommu_to_dti_inv_ready_o ( cq_inv_ready ),

    // IOMMU <-> DTI translation interface
    .dti_to_iommu_trans_req_o   ( trans_req       ),
    .dti_to_iommu_trans_valid_o ( trans_req_valid ),
    .dti_to_iommu_trans_ready_i ( trans_req_ready ),

    .iommu_to_dti_trans_resp_i  ( trans_resp       ),
    .iommu_to_dti_trans_valid_i ( trans_resp_valid ),
    .iommu_to_dti_trans_ready_o ( trans_resp_ready ),

    .timeout_o ( timeout )
  );

  // -------------------------------------------------
  // Clock and Reset
  // -------------------------------------------------
  initial begin
    clk_i = 1'b0;
    forever #(REFClockPeriod/2) clk_i = ~clk_i;
  end

  initial begin
    rst_ni = 1'b0;
    repeat(100) @(posedge clk_i);
    rst_ni = 1'b1;
  end

  // -------------------------------------------------
  // Main Test Sequence
  // -------------------------------------------------
  initial begin
    // Wait for reset
    wait(rst_ni);
    @(posedge clk_i);

    // Initialize drivers
    master_drv.reset_tx();
    master_drv.reset_rx();
    slave_drv.reset_tx();
    slave_drv.reset_rx();

    // Clear signals
    cq_inv_req       = '0;
    cq_inv_valid     = 1'b0;
    trans_req_ready  = 1'b0;
    trans_resp_valid = 1'b0;
    send_ack         = 1'b0;

    repeat(30) @(posedge clk_i);

    // 1) Perform Connect
    do_connect();
    $display("[TB] ---- Connect Done ----");
    repeat(20) @(posedge clk_i);

    // 2) First, test Translation Requests
    //    We'll do concurrency:
    //    - Send 32 requests from PCIe side
    //    - Meanwhile, handle them as IOMMU (trans_req_valid)
    //    - Then we also expect final trans responses on the AXI
    fork
      begin : f1
        send_32_trans_requests();
      end

      begin : f2
        handle_iommu_translation(); // Receives from dti_to_iommu_trans_req_o, replies
      end

      begin : f3
        receive_dti_translation_responses(); // Reads final responses from AXI
      end
    join

    $display("[TB] ---- Translation Flow Done ----");
    repeat(20) @(posedge clk_i);

    // 3) Now do the invalidation sequence (like your existing logic).
    //    For example:
    for(int i=0;i<NUM_REP;i++) begin
        repeat(30) @(posedge clk_i);

        // 2) Parallel sending & receiving
        fork
           begin : sender
              send_invals_process();
           end
           begin : receiver
              recv_invals_process();
           end
        join

        $display("end inv_req / inv_ack");
        // Once both are done, the ack_process may still be sending final acks
        // if anything is left in the queue. We can wait a few cycles for it to flush:
        repeat(140) @(posedge clk_i);

        // 3) Send invalidation completions (out-of-order) for the entire set
        //    (2*NUM_INV total requests).
        send_invalidation_completions(2*NUM_INV);

        repeat(10) @(posedge clk_i);
    end
    $display("[TB] ---- Invalidation Flow Done ----");

    // 4) Disconnect
    do_disconnect();
    $display("[TB] ---- Disconnect Done ----");

    // Final wait
    repeat(100) @(posedge clk_i);
    $stop;
  end

  // -------------------------------------------------
  // Tasks: Connect, Disconnect, etc.
  // -------------------------------------------------
  task do_connect();
    begin
      condis_con_req = '0;
      condis_con_req.protocol          = 1'b1;
      condis_con_req.state             = 1'b1;
      condis_con_req.tok_inv_gnt       = 4'hF;
      condis_con_req.tok_trans_req_lsb = 8'd64;

      $display("[TB] Sending Connect message: %p", condis_con_req);
      master_drv.send(condis_con_req, 1'b1); // tlast = 1

      // Wait on slave side for ack
      slave_drv.recv(condis_con_ack, recv_last);
      $display("[TB] Received Connect Ack: %p", condis_con_ack);
    end
  endtask

  task do_disconnect();
    begin
      condis_discon_req          = '0;
      condis_discon_req.protocol = 1'b1;

      $display("[TB] Sending Disconnect message: %p", condis_discon_req);
      master_drv.send(condis_discon_req, 1'b1);

      slave_drv.recv(condis_discon_ack, recv_last);
      $display("[TB] Received Disconnect Ack: %p", condis_discon_ack);
    end
  endtask

  // -------------------------------------------------
  // TASK: pcie_send_trans_request
  //  - Sends a single translation request from the PCIe side
  //    into the DUT's AXI stream (downstream interface).
  // -------------------------------------------------
  task pcie_send_trans_request(byte id);
    trans_req_pcie              = '0;
    trans_req_pcie.s_msg_type   = DTI_ATS_TRANS_REQ;
    trans_req_pcie.trans_id_lsb = id;
    trans_req_pcie.protocol     = 1'b1;
    trans_req_pcie.nW           = 1'b1; // example usage
    trans_req_pcie.PnU          = 1'b0;
    trans_req_pcie.InD          = 1'b0;
    trans_req_pcie.IA           = 52'hCAD2E9A + id;
    trans_req_pcie.sid          = 32'hDEADF00D;

    $display("[TB] Sending Translation Request (PCIe->DTI) id=%0d => %p", id, trans_req_pcie);
    master_drv.send(trans_req_pcie, 1'b1);
  endtask

  // -------------------------------------------------
  // TASKS: Sending 32 Trans Requests
  //        + concurrency to handle them in the DUT
  // -------------------------------------------------
  task send_32_trans_requests();
    for (int i = 0; i < NUM_TRANS_REQ; i++) begin
      pcie_send_trans_request(i);
      repeat(2) @(posedge clk_i);
    end
  endtask

  // -------------------------------------------------
  // IOMMU Emulation: we expect the DUT to drive
  //   trans_req_valid = 1, with trans_req containing
  //   the fields from "dti_to_iommu_trans_req_o".
  //
  // We'll collect them, then respond with "trans_resp".
  // -------------------------------------------------
  task handle_iommu_translation();
    count_rcvd = 0;

    $display("[IOMMU] Start waiting for trans_req_valid...");
    while (count_rcvd < NUM_TRANS_REQ) begin
      // Wait for the DUT to drive valid
      @(posedge clk_i);
      if (trans_req_valid) begin
        // We accept immediately
        trans_req_ready <= 1'b1;
        @(posedge clk_i);
        trans_req_ready <= 1'b0;

        // Capture the request
        local_req = trans_req; 
        $display("[IOMMU] Received trans_req from DUT. count=%0d => %p", 
                 count_rcvd, local_req);

        // Emulate some “address translation”
        // Build a trans_resp that we send back.
        trans_resp = '0;
        trans_resp.error  = 1'b0;
        trans_resp.ignore = 1'b0;
        trans_resp.spaddr = local_req.iova[51:0] + 52'h1000; // example
        // Possibly set other fields

        // Now drive trans_resp_valid until the DUT asserts trans_resp_ready
        trans_resp_valid <= 1'b1;
        wait (trans_resp_ready == 1'b1);
        @(posedge clk_i);
        trans_resp_valid <= 1'b0;

        $display("[IOMMU] Sent trans_resp back to DUT for count=%0d => %p", 
                 count_rcvd, trans_resp);

        count_rcvd++;
      end
    end
    $display("[IOMMU] Done handling all trans requests.");
  endtask

  // -------------------------------------------------
  // We also want to see how the DUT sends out
  // final “translation responses” on the AXI stream
  // ( i.e. dti_ats_trans_resp_s ) once it’s processed
  // the IOMMU’s answer. 
  // We can receive them on the slave interface.
  // -------------------------------------------------
  task receive_dti_translation_responses();
    count_resp = 0;

    // We expect one final DTI response per original request,
    // so we can loop up to NUM_TRANS_REQ.
    $display("[TB] Waiting to receive final DTI translation responses on AXI...");
    while (count_resp < NUM_TRANS_REQ) begin
      // Use the slave driver to recv from the DUT
      slave_drv.recv(dti_trans_resp, recv_last);

      if (dti_trans_resp.s_msg_type == DTI_ATS_TRANS_RESP) begin
        $display("[TB] Received DTI Trans Resp idx=%0d => %p",
                 count_resp, dti_trans_resp);
        count_resp++;
      end
      else begin
        $display("[TB] Received something else on slave: %p", dti_trans_resp);
      end

      repeat(2) @(posedge clk_i);
    end

    $display("[TB] All DTI translation responses received: %0d total.", count_resp);
  endtask

  // -------------------------------------------------
  // Invalidation tasks (similar to your existing code)
  // -------------------------------------------------
  task do_send_one_inv_req(int i);
    cq_inv_req         = '0;
    cq_inv_req.pid     = 20'hABBA + i;
    cq_inv_req.pv      = 1'b1;
    cq_inv_req.dsv     = 1'b1;
    cq_inv_req.dseg    = 8'hFF;
    cq_inv_req.rid     = 16'hB0DE + i;
    cq_inv_req.s       = 1'b1;
    cq_inv_req.untrans_addr = 52'hBABABABA;

    $display("[CORE_SEND] Attempting Invalidation Req i=%0d => %p", i, cq_inv_req);

    cq_inv_valid = 1'b1;
    wait (cq_inv_ready);
    @(posedge clk_i);
    cq_inv_valid = 1'b0;

    repeat(3) @(posedge clk_i);
  endtask

  task do_send_core_invalidations(int count, int start_id);
    for (int i = start_id; i < start_id + count; i++) begin
      do_send_one_inv_req(i);
    end
  endtask

  // Receives a single invalidation request from the DUT
  // and push to the queue for ack.
  task do_recv_one_inv_req(int j);
     slave_drv.recv(inv_req[j], recv_last);
     $display("[RECV_INV] Received Invalidation Req index=%0d: %p", j, inv_req[j]);
     // Put into queue for ack
     inv_req_q.push_back(inv_req[j]);

     repeat(6) @(posedge clk_i);
  endtask

  // Receives 'count' requests in a loop
  task do_receive_inv_requests(int count, int bias);
     for(int j = bias; j < bias + count; j++) begin
        do_recv_one_inv_req(j);
     end
  endtask

  // Send out-of-order completions
  task send_invalidation_completions(int count);
     for(int i = count-2; i >= 0; i--) begin
        inv_comp          = '0;
        inv_comp.s_msg_type = DTI_ATS_INV_COMP;
        inv_comp.sid      = inv_req[i].sid;
        inv_comp.itag     = inv_req[i].itag;
        inv_comp.t        = inv_req[i].t;

        $display("[COMP_SEND] Sending Inv Comp OOO for index=%0d: %p", i, inv_comp);
        master_drv.send(inv_comp, 1'b1);
        repeat(3) @(posedge clk_i);
     end
  endtask

  // This process sends a certain number of invalidations from the core
  // in a loop or multiple phases.
  task automatic send_invals_process();
     $display("[SEND_PROCESS] Starting core invalidation sender...");
     // Example: 2 * NUM_INV total in two phases
     do_send_core_invalidations(NUM_INV, 0);
     do_send_core_invalidations(NUM_INV, NUM_INV);
     $display("[SEND_PROCESS] Done sending all core invalidations.");
  endtask

  // This process receives them from the DUT (via slave driver).
  task automatic recv_invals_process();
     $display("[RECV_PROCESS] Starting to receive forwarded invalidations...");
     // We know we expect 2 * NUM_INV
     do_receive_inv_requests(NUM_INV, 0);
     do_receive_inv_requests(NUM_INV, NUM_INV);
     $display("[RECV_PROCESS] Done receiving all forwarded invalidations.");
  endtask

endmodule
