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
// Date: 13/03/2025
//
// Authors:
// - Maicol Ciani <maicol.ciani@unibo.it>
//
// Description: Definition of agent to hanlde the VIP classes and the test framework.
//

`include "axi_stream/typedef.svh"
`include "axi_stream/assign.svh"

package rv_iommu_fix_pkg;

   import rv_iommu::*;
   import rv_iommu_cfg::*;
   import rv_iommu_vip_pkg::*;
   import rv_iommu_dti_ats_pkg::*;
   import pcie_ats_vip_pkg::*;
   import rv_iommu_tb_defs::*;

   // -----------------------------------------------------------------------------
   // 1) Scoreboard / Tracker Class
   // -----------------------------------------------------------------------------
   class ats_translation_tracker;

     ats_entry_t m_db[$];

     function void store_translation_req(dti_ats_trans_req_s req);
       ats_entry_t entry;
       entry.trans_id_lsb = req.trans_id_lsb;
       entry.gva          = req.IA;
       entry.valid        = 1'b1;
       entry.shared       = req.InD; // if InD=1 => device is caching
       entry.spa          = '0;
       entry.itag         = '0;
       m_db.push_back(entry);
       $display("[TRACKER] Stored Req: ID=%0d GVA=%h", req.trans_id_lsb, req.IA);
     endfunction

     function void store_translation_resp(dti_ats_trans_resp_s resp);
       foreach (m_db[i]) begin
         if (m_db[i].valid && (m_db[i].trans_id_lsb == resp.trans_id_lsb)) begin
           m_db[i].spa  = resp.OA;
           $display("[TRACKER] Updated Resp: ID=%0d => SPA=%h", resp.trans_id_lsb, resp.OA);
         end
       end
     endfunction

     function ats_entry_t get_translation();
       get_translation = m_db.pop_front();
     endfunction

   endclass

   // -----------------------------------------------------------------------------
   // 2) The test environment class
   // -----------------------------------------------------------------------------
   class rv_iommu_top_env #(
     parameter int unsigned AXIS_DATA_WIDTH = 64,
     parameter int unsigned AXIS_ID_WIDTH   = 4,
     parameter int unsigned AXIS_DEST_WIDTH = 64,
     parameter int unsigned AXIS_USER_WIDTH = 1,
     parameter int unsigned AXI_DATA_WIDTH = 64,
     parameter int unsigned AXI_ADDR_WIDTH = 64,
     parameter int unsigned AXI_ID_WIDTH   = 4,
     parameter int unsigned AXI_USER_WIDTH = 1,
     parameter int unsigned AXI_DEVID_WIDTH = 1,
     parameter int unsigned AXI_PROID_WIDTH = 1,
     parameter time         TestTime  = 0.75ns,
     parameter time         ApplTime  = 4.25ns
   );

     // Agents
     rv_iommu_vip_agent #(
       .DATA_WIDTH (AXI_DATA_WIDTH),
       .ADDR_WIDTH (AXI_ADDR_WIDTH),
       .ID_WIDTH   (AXI_ID_WIDTH),
       .USER_WIDTH (AXI_USER_WIDTH),
       .DevW       (AXI_DEVID_WIDTH),
       .ProW       (AXI_PROID_WIDTH),
       .TestTime   (TestTime),
       .ApplTime   (ApplTime)
     ) iommu_agent;

     pcie_ats_vip_agent #(
       .DATA_WIDTH (AXIS_DATA_WIDTH),
       .DEST_WIDTH (AXIS_DEST_WIDTH),
       .ID_WIDTH   (AXIS_ID_WIDTH),
       .USER_WIDTH (AXIS_USER_WIDTH),
       .TestTime   (TestTime),
       .ApplTime   (ApplTime)
     ) pcie_agent;

     // Scoreboard
     ats_translation_tracker tracker;

     // Config
     int NUM_TRANS_REQ;
     int NUM_INV;

     // Constructor
     function new(
        pcie_ats_vip_agent #(
          .DATA_WIDTH (AXIS_DATA_WIDTH),
          .DEST_WIDTH (AXIS_DEST_WIDTH),
          .ID_WIDTH   (AXIS_ID_WIDTH),
          .USER_WIDTH (AXIS_USER_WIDTH),
          .TestTime   (TestTime),
          .ApplTime   (ApplTime)
        ) pcie_agent,
        rv_iommu_vip_agent #(
          .DATA_WIDTH (AXI_DATA_WIDTH),
          .ADDR_WIDTH (AXI_ADDR_WIDTH),
          .ID_WIDTH   (AXI_ID_WIDTH),
          .USER_WIDTH (AXI_USER_WIDTH),
          .DevW       (AXI_DEVID_WIDTH),
          .ProW       (AXI_PROID_WIDTH),
          .TestTime   (TestTime),
          .ApplTime   (ApplTime)
       ) iommu_agent,
       ats_translation_tracker tracker,
       int NUM_TRANS_REQ,
       int NUM_INV
     );
       this.pcie_agent   = pcie_agent;
       this.iommu_agent  = iommu_agent;
       this.tracker      = tracker;
       this.NUM_TRANS_REQ= NUM_TRANS_REQ;
       this.NUM_INV      = NUM_INV;
     endfunction

     task run_test();
       dti_ats_condis_req_s  con_req, dis_req;
       dti_ats_condis_ack_s  con_ack, dis_ack;
       dti_ats_trans_resp_s  trans_resp;
       dti_ats_trans_resp_s  trans_resp_array[];

       dti_ats_inv_req_s inv_req_array[$];
       ats_entry_t ats_entry;
       ats_entry_t ats_tr_entry;

       cq_atsinval_t inval_cmd;
       cq_iofence_t  fence_command;
       cq_entry_t    command;

       logic [63:0] data;
       logic invalidation_completed;

       invalidation_completed = 1'b0;

       // 2) Reset agents
       pcie_agent.reset();
       iommu_agent.reset_drvs();
       $display("[ENV] ---- Reset drivers: done ----");

       iommu_agent.s1pt_init_hw();
       $display("[ENV] ---- S1PT init: done ----");
       iommu_agent.s2pt_init_hw();
       $display("[ENV] ---- S2PT init: done ----");
       iommu_agent.iommu_ddt_init_hw();
       $display("[ENV] ---- DDT init: done ----");
       iommu_agent.iommu_pq_init();
       $display("[ENV] ---- PQ init: done ----");
       iommu_agent.iommu_cq_init();
       $display("[ENV] ---- CQ init: done ----");

       repeat(30) @(posedge iommu_agent.axi_tr_drv.axi.clk_i);

       // 3) Connect
       pcie_agent.do_connect(con_req, con_ack);
       $display("[ENV] ---- Connect Done ----");
       repeat(20) @(posedge iommu_agent.axi_tr_drv.axi.clk_i);

       // 4) Send/Receive translations
       fork
         // Sending requests
         begin
           for (int i = 0; i < NUM_TRANS_REQ; i++) begin
             dti_ats_trans_req_s req = '0;
             req.s_msg_type   = DTI_ATS_TRANS_REQ;
             req.trans_id_lsb = i;
             req.protocol     = 1'b1;
             req.InD          = 1'b1;
             req.IA           = 52'h1_0000_0000 + i*52'h1000;
             req.sid          = 32'h1;
             tracker.store_translation_req(req);
             pcie_agent.pcie_send_trans_request(i, req);
             #10ns;
           end
         end

         // Receiving responses
         begin
           bit dummy_last;
           int count_resp = 0;
           trans_resp_array = new[NUM_TRANS_REQ];
           while (count_resp < NUM_TRANS_REQ) begin
             pcie_agent.slave_drv.recv(trans_resp, dummy_last);
             if (trans_resp.s_msg_type == DTI_ATS_TRANS_RESP) begin
               tracker.store_translation_resp(trans_resp);
               trans_resp_array[count_resp] = trans_resp;
               count_resp++;
             end
           end
         end
       join

       repeat(20) @(posedge iommu_agent.axi_tr_drv.axi.clk_i);

       // 5) Issue translated transactions
       for (int i = 0; i < NUM_TRANS_REQ; i++) begin
          ats_tr_entry = tracker.m_db[i];
          $display("[ENV] Sending transaction for GVA=%h", ats_tr_entry.gva);
          iommu_agent.axi_single_write_tr(ats_tr_entry.spa << 12,64'hDEADBEEF,1,1);
       end
       for (int i = 0; i < NUM_TRANS_REQ; i++) begin
          ats_tr_entry = tracker.m_db[i];
          iommu_agent.axi_single_read_tr(ats_tr_entry.spa << 12,1'b1,1'b1, data);
          if(data ==  64'hDEADBEEF)
            $display("[ENV] Read correct data %x @GVA=%x with translated SPA:%x", data, ats_tr_entry.gva, ats_tr_entry.spa << 12);
          else
            $display("[ENV] Read wrong data %x @GVA=%x with translated SPA:%x", data, ats_tr_entry.gva, ats_tr_entry.spa << 12);
       end

       repeat(20) @(posedge iommu_agent.axi_tr_drv.axi.clk_i);

       fork
         // CPU side sends invalidations
         begin
            for (int i = 0; i < NUM_INV; i++) begin
               ats_entry              = tracker.get_translation();
               inval_cmd              = '0;
               inval_cmd.rid          = 16'h1;
               inval_cmd.opcode       = ATS;
               inval_cmd.func3        = ATSINVAL;
               inval_cmd.untrans_addr = ats_entry.gva;
               command                = cq_entry_t'(inval_cmd);
               $display("[ENV] Sending invalidation for GVA=%h => %p", inval_cmd.untrans_addr, inval_cmd);
               iommu_agent.rv_iommu_write_command_in_queue(command);
            end
         end
         // PCIe side receives invalidation requests
         begin
            pcie_agent.do_receive_inv_requests(NUM_INV, inv_req_array, 0);
         end
       join

       repeat(20) @(posedge iommu_agent.axi_tr_drv.axi.clk_i);

       fork
          begin
             $display("[ENV] Received invalidations => sending completions...");
             pcie_agent.send_invalidation_completions(NUM_INV, inv_req_array);
             invalidation_completed = 1'b1;
          end

          begin
             $display("[ENV] IOMMU Fence command: wait for Inv to complete...");
             fence_command = '0;
             fence_command.opcode = IOFENCE;
             fence_command.func3 = IOFENCE_C;
             command = cq_entry_t'(fence_command);
             iommu_agent.rv_iommu_write_command_in_queue(command);
          end

          begin
             $display("[ENV] Receiving Synch Request. Resolving it when Invalidations have completed");
             pcie_agent.dti_synch_request(invalidation_completed);
          end
       join

       repeat(20) @(posedge iommu_agent.axi_tr_drv.axi.clk_i);

       // 6) Disconnect
       pcie_agent.do_disconnect(dis_req, dis_ack);
       repeat(20) @(posedge iommu_agent.axi_tr_drv.axi.clk_i);
       $display("[ENV] ---- Disconnect Done ----");
     endtask

   endclass

endpackage
