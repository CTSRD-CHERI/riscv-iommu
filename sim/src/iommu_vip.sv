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
// Description: VIP for emulating IOMMU's interface with DTI-ATS top
//

module iommu_vip(input logic clk_i);

  import rv_iommu_dti_ats_pkg::*;

  // --------------------------------------------------------------------------
  // IOMMU VIP: tasks for IOMMU side signals
  // --------------------------------------------------------------------------

  // This task emulates the IOMMU receiving translation requests from the DUT
  // (dti_to_iommu_trans_req_o + dti_to_iommu_trans_valid_o) and responding back.
  task automatic handle_iommu_translation(
      ref logic                  trans_req_valid,
      ref rv_iommu_trans_req_s   trans_req,
      ref logic                  trans_req_ready,
      ref logic                  trans_resp_valid,
      ref rv_iommu_trans_resp_s  trans_resp,
      ref logic                  trans_resp_ready,
      input int                  num_expected
  );
    int count_rcvd = 0;
    rv_iommu_trans_req_s local_req;

    $display("[IOMMU VIP] Start handling trans_req_valid. Expecting %0d requests.", num_expected);

    while (count_rcvd < num_expected) begin
      @(posedge clk_i);
      if (trans_req_valid) begin
        // Accept immediately in this example
        trans_req_ready = 1'b1;
        @(posedge clk_i);
        trans_req_ready = 1'b0;

        local_req = trans_req;
        $display("[IOMMU VIP] Received trans_req from DUT. idx=%0d => %p", count_rcvd, local_req);

        // Build a trans_resp to send back
        trans_resp       = '0;
        trans_resp.error = 1'b0;
        trans_resp.ignore= 1'b0;
        trans_resp.spaddr= local_req.iova + 52'h1000; // Example translation

        // Drive trans_resp_valid until the DUT asserts trans_resp_ready
        trans_resp_valid = 1'b1;
        wait (trans_resp_ready == 1'b1);
        @(posedge clk_i);
        trans_resp_valid = 1'b0;

        $display("[IOMMU VIP] Sent trans_resp for idx=%0d => %p", count_rcvd, trans_resp);

        count_rcvd++;
      end
    end

    $display("[IOMMU VIP] Done handling all %0d trans requests.", num_expected);
  endtask

  // Send a single invalidation request from “Core to IOMMU” side
  // (the interface signals: cq_inv_req + cq_inv_valid).
  task automatic do_send_one_inv_req(
    ref logic  cq_inv_valid,
    ref        rv_iommu_cq_inv_req_s cq_inv_req,
    input int  i,
    input int  cycles_to_wait = 3,
    input  wait_for_ready, // If you only set cq_inv_ready on your DUT
    ref logic  cq_inv_ready
  );

    cq_inv_req                 = '0;
    cq_inv_req.pid            = 20'hABBA + i;
    cq_inv_req.pv             = 1'b1;
    cq_inv_req.dsv            = 1'b1;
    cq_inv_req.dseg           = 8'hFF;
    cq_inv_req.rid            = 16'hB0DE + i;
    cq_inv_req.s              = 1'b1;
    cq_inv_req.untrans_addr   = 52'hBABABABA;

    $display("[IOMMU VIP] Attempting Invalidation Req i=%0d => %p", i, cq_inv_req);
    cq_inv_valid = 1'b1;

    if (wait_for_ready) begin
      wait (cq_inv_ready == 1'b1);
    end
    @(posedge clk_i);
    cq_inv_valid = 1'b0;

    repeat(cycles_to_wait) @(posedge clk_i);
  endtask

  // Send N invalidation requests in a loop
  task automatic do_send_core_invalidations(
    ref logic cq_inv_valid,
    ref rv_iommu_cq_inv_req_s cq_inv_req,
    ref logic cq_inv_ready,
    input int count,
    input int start_id
  );
    for (int i = start_id; i < start_id + count; i++) begin
      do_send_one_inv_req (cq_inv_valid, cq_inv_req, i, 3, 1, cq_inv_ready);
    end
  endtask

  // Simple wrapper for a multi-phase send:
  task automatic send_invals_process(
    ref logic cq_inv_valid,
    ref rv_iommu_cq_inv_req_s cq_inv_req,
    ref logic cq_inv_ready,
    input  int num_inv
  );
    $display("[IOMMU VIP] Starting core invalidation sender...");
    // Example: 2 * num_inv total
    do_send_core_invalidations(cq_inv_valid, cq_inv_req, cq_inv_ready, num_inv, 0);
    do_send_core_invalidations(cq_inv_valid, cq_inv_req, cq_inv_ready, num_inv, num_inv);
    $display("[IOMMU VIP] Done sending all core invalidations.");
  endtask

endmodule
