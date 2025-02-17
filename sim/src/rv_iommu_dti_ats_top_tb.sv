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


module rv_iommu_dti_ats_top_tb;

  import rv_iommu_dti_ats_pkg::*;
  // -------------------------------------------------
  // Parameters
  // -------------------------------------------------
  localparam int unsigned REFClockPeriod = 5ns; // 200MHz

  // AXI Stream parameters
  localparam int unsigned DATA_WIDTH = 160;
  localparam int unsigned KEEP_WIDTH = DATA_WIDTH/8;
  localparam int unsigned STRB_WIDTH = DATA_WIDTH/8;
  localparam int unsigned ID_WIDTH   = 1;
  localparam int unsigned DEST_WIDTH = 1;
  localparam int unsigned USER_WIDTH = 1;

  localparam int unsigned NUM_INV       = 16;
  localparam int unsigned NUM_REP       = 1;
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

  // Core to IOMMU invalidation interface
  logic                 cq_inv_valid;
  logic                 cq_inv_ready;
  rv_iommu_cq_inv_req_s cq_inv_req;

  // AXI-Stream for the DTI module
  axis_req_t axis_mst_req, axis_slv_req;
  axis_rsp_t axis_mst_rsp, axis_slv_rsp;

  // IOMMU <-> DTI translation interface
  rv_iommu_trans_req_s  trans_req;
  rv_iommu_trans_resp_s trans_resp;
  logic trans_req_valid,  trans_req_ready;
  logic trans_resp_valid, trans_resp_ready;

  // Additional signals
  logic         timeout;

  // For con/dis connect
  dti_ats_condis_req_s  condis_con_req, condis_discon_req;
  dti_ats_condis_ack_s  condis_con_ack, condis_discon_ack;

  // Invalidation
  dti_ats_inv_req_s   inv_req_array[200]; // store requests we receive from DUT
  dti_ats_inv_ack_s   inv_ack;
  dti_ats_inv_comp_s  inv_comp;

  // Translation request from PCIe side
  dti_ats_trans_req_s  trans_req_pcie;
  dti_ats_trans_resp_s dti_trans_resp; // used in receiving from slave
  // Sync (unused in example)
  dti_ats_sync_req_s   sync_req;
  dti_ats_sync_ack_s   sync_ack;

  // -------------------------------------------------
  // PCIe: ATS-DTI Verification IP
  // -------------------------------------------------
  pcie_ats_vip #(
    .DATA_WIDTH     ( DATA_WIDTH     ),
    .ID_WIDTH       ( ID_WIDTH       ),
    .DEST_WIDTH     ( DEST_WIDTH     ),
    .USER_WIDTH     ( USER_WIDTH     ),
    .REFClockPeriod ( REFClockPeriod ),
    .axis_req_t( axis_req_t     ),
    .axis_rsp_t( axis_rsp_t     )
  ) i_pcie_vip (
    .clk_i        ( clk_i        ),
    .rst_ni       ( rst_ni       ),
    .axis_mst_req ( axis_mst_req ),
    .axis_mst_rsp ( axis_mst_rsp ),
    .axis_slv_req ( axis_slv_req ),
    .axis_slv_rsp ( axis_slv_rsp )
  );

  // -------------------------------------------------
  // IOMMU: ATS-DTI Verification IP
  // -------------------------------------------------
  iommu_vip i_iommu_vip (
    .clk_i
  );

  // -------------------------------------------------
  // DUT Instance
  // -------------------------------------------------
  dti_ats_top #(
    .DATA_WIDTH (DATA_WIDTH),
    .axis_req_t (axis_req_t),
    .axis_rsp_t (axis_rsp_t)
  ) DuT (
    .clk_i  (clk_i),
    .rst_ni (rst_ni),

    // AXI-Stream Up (DUT "slave" side: TB receives from it)
    .axis_req_up_o (axis_slv_req),
    .axis_rsp_up_i (axis_slv_rsp),

    // AXI-Stream Down (DUT "master" side: TB drives it)
    .axis_req_dn_i (axis_mst_req),
    .axis_rsp_dn_o (axis_mst_rsp),

    // Invalidation interface
    .iommu_to_dti_inv_req_i   (cq_inv_req),
    .iommu_to_dti_inv_valid_i (cq_inv_valid),
    .iommu_to_dti_inv_ready_o (cq_inv_ready),

    // IOMMU <-> DTI translation interface
    .dti_to_iommu_trans_req_o   (trans_req),
    .dti_to_iommu_trans_valid_o (trans_req_valid),
    .dti_to_iommu_trans_ready_i (trans_req_ready),

    .iommu_to_dti_trans_resp_i  (trans_resp),
    .iommu_to_dti_trans_valid_i (trans_resp_valid),
    .iommu_to_dti_trans_ready_o (trans_resp_ready),

    .timeout_o (timeout)
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

    i_pcie_vip.reset();

    // Clear signals
    cq_inv_req       = '0;
    cq_inv_valid     = 1'b0;
    trans_req_ready  = 1'b0;
    trans_resp_valid = 1'b0;

    repeat(30) @(posedge clk_i);

    // 1) Perform Connect using the DTI-ATS VIP
    i_pcie_vip.do_connect(condis_con_req, condis_con_ack);
    $display("[TB] ---- Connect Done ----");
    repeat(20) @(posedge clk_i);

    // 2) Concurrency for Translation Requests
    fork
      begin : f1
        // Send N translation requests (PCIe->DTI)
        i_pcie_vip.send_n_trans_requests(
          NUM_TRANS_REQ, trans_req_pcie
        );
      end

      begin : f2
        // IOMMU side receiving from DUT
        i_iommu_vip.handle_iommu_translation(
          trans_req_valid, trans_req,
          trans_req_ready,
          trans_resp_valid, trans_resp,
          trans_resp_ready,
          NUM_TRANS_REQ
        );
      end

      begin : f3
        // The final ATS translation responses come out on the slave AXI
        i_pcie_vip.receive_dti_translation_responses(
          NUM_TRANS_REQ, dti_trans_resp
        );
      end
    join

    $display("[TB] ---- Translation Flow Done ----");
    repeat(20) @(posedge clk_i);

    // 3) Now do the invalidation sequence in 2 * NUM_INV
    for(int rep=0; rep<NUM_REP; rep++) begin
      repeat(30) @(posedge clk_i);

      // Parallel sending & receiving
      fork
        begin : sender
          // On the IOMMU side, drive the core->iommu invalidations
          i_iommu_vip.send_invals_process(
             cq_inv_valid, cq_inv_req, cq_inv_ready, NUM_INV
          );
          // Send another batch
          // or do_send_core_invalidations(...) again,
          // but we included both phases inside send_invals_process, for example.
        end

        begin : receiver
          // The DUT forwards them onto the AXI 'slave' side, so we receive them there
          i_pcie_vip.do_receive_inv_requests(
             2*NUM_INV, inv_req_array, 0
          );
        end
      join

      $display("[TB] ---- Invalidation Flow Done for iteration %0d ----", rep);

      // Possibly wait for the ack process to flush
      repeat(140) @(posedge clk_i);

      // 4) Send invalidation completions (DTI->PCIe) out-of-order for entire set
      //    using the array we stored them in:
      i_pcie_vip.send_invalidation_completions(
        2*NUM_INV,
        inv_req_array
      );

      repeat(10) @(posedge clk_i);
    end

    // 4) Disconnect
    i_pcie_vip.do_disconnect(condis_discon_req, condis_discon_ack);
    $display("[TB] ---- Disconnect Done ----");

    // Final wait
    repeat(100) @(posedge clk_i);
    $stop;
  end

endmodule
