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
// Description: Definition of agent to hanlde PCIe ATS_DTI commands (AXI Stream ports).
//

package pcie_ats_vip_pkg;

   // Import needed types
   import rv_iommu_dti_ats_pkg::*;
   import axi_stream_test::*;
   import rv_iommu_tb_defs::*;

   // -----------------------------------------------------------------------------
   // 2) pcie_ats_vip_agent class
   // -----------------------------------------------------------------------------
   class pcie_ats_vip_agent #(
     parameter int unsigned DATA_WIDTH = 160,
     parameter int unsigned ID_WIDTH   = 1,
     parameter int unsigned DEST_WIDTH = 1,
     parameter int unsigned USER_WIDTH = 1,
     parameter time         TestTime  = 0ns,
     parameter time         ApplTime  = 0ns
   );

     // A typed reference that matches the same param set
     axi_stream_test::axi_stream_driver #(
       .DataWidth(DATA_WIDTH),
       .IdWidth  (ID_WIDTH),
       .DestWidth(DEST_WIDTH),
       .UserWidth(USER_WIDTH),
       .TestTime (TestTime),
       .ApplTime (ApplTime)
     ) master_drv, slave_drv;

     function new(
       axi_stream_test::axi_stream_driver #(
         .DataWidth(DATA_WIDTH),
         .IdWidth  (ID_WIDTH),
         .DestWidth(DEST_WIDTH),
         .UserWidth(USER_WIDTH),
         .TestTime (TestTime),
         .ApplTime (ApplTime)
       ) master_drv,
       axi_stream_test::axi_stream_driver #(
         .DataWidth(DATA_WIDTH),
         .IdWidth  (ID_WIDTH),
         .DestWidth(DEST_WIDTH),
         .UserWidth(USER_WIDTH),
         .TestTime (TestTime),
         .ApplTime (ApplTime)
       ) slave_drv
     );
       this.master_drv = master_drv;
       this.slave_drv  = slave_drv;
     endfunction

     // Simple reset
     function void reset();
       master_drv.reset_tx();
       master_drv.reset_rx();
       slave_drv.reset_tx();
       slave_drv.reset_rx();
     endfunction

     // Connect
     task automatic do_connect(
       ref dti_ats_condis_req_s con_req,
       ref dti_ats_condis_ack_s con_ack
     );
       bit dummy_last;
       con_req = '0;
       con_req.protocol          = 1'b1;
       con_req.state             = 1'b1;
       con_req.tok_inv_gnt       = 4'hF;
       con_req.tok_trans_req_lsb = 8'd64;

       $display("[PCIE_ATS_AGENT] Sending Connect message: %p", con_req);
       master_drv.send(con_req, 1'b1);

       slave_drv.recv(con_ack, dummy_last);
       $display("[PCIE_ATS_AGENT] Received Connect Ack: %p", con_ack);
     endtask

     // Disconnect
     task automatic do_disconnect(
       ref dti_ats_condis_req_s dis_req,
       ref dti_ats_condis_ack_s dis_ack
     );
       bit dummy_last;
       dis_req = '0;
       dis_req.protocol = 1'b1;

       $display("[PCIE_ATS_AGENT] Sending Disconnect message: %p", dis_req);
       master_drv.send(dis_req, 1'b1);

       slave_drv.recv(dis_ack, dummy_last);
       $display("[PCIE_ATS_AGENT] Received Disconnect Ack: %p", dis_ack);
     endtask

     // Send a single PCIe->DTI translation request
     task automatic pcie_send_trans_request(
       input byte id,
       inout dti_ats_trans_req_s trans_req_pcie
     );
       $display("[PCIE_ATS_AGENT] Sending Translation Req id=%0d => %p", id, trans_req_pcie);
       master_drv.send(trans_req_pcie, 1'b1);
     endtask

     // Send N translation requests
     task automatic send_n_trans_requests(input int num_trans_req);
       dti_ats_trans_req_s req;
       for (int i=0; i<num_trans_req; i++) begin
         req              = '0;
         req.s_msg_type   = DTI_ATS_TRANS_REQ;
         req.trans_id_lsb = i;
         req.protocol     = 1'b1;
         req.nW           = 1'b0;
         req.InD          = 1'b1;
         req.IA           = 52'h1_0000_0000 + i*52'h1000;
         req.sid          = 32'h1;

         pcie_send_trans_request(i, req);
         #10ns;
       end
     endtask

     // Receive N translation responses
     task automatic receive_dti_translation_responses(
       input  int num_expected,
       output dti_ats_trans_resp_s dti_trans_resp[]
     );
       bit dummy_last;
       int count_resp = 0;
       dti_ats_trans_resp_s local_resp;
       dti_trans_resp = new[num_expected];

       while (count_resp < num_expected) begin
         slave_drv.recv(local_resp, dummy_last);
         if (local_resp.s_msg_type == DTI_ATS_TRANS_RESP) begin
           dti_trans_resp[count_resp] = local_resp;
           $display("[PCIE_ATS_AGENT] Got TransResp idx=%0d => %p", count_resp, local_resp);
           count_resp++;
         end
       end
       $display("[PCIE_ATS_AGENT] Received %0d ATS responses total.", count_resp);
     endtask

     // Receive invalidation requests from the DUT
     task automatic do_receive_inv_requests(
       input  int count,
       output dti_ats_inv_req_s inv_req_array[$],
       input  int bias=0
     );
       bit dummy_last;
       for(int j = bias; j < bias+count; j++) begin
         dti_ats_inv_req_s tmp;
         slave_drv.recv(tmp, dummy_last);
         inv_req_array[j] = tmp;
         $display("[PCIE_ATS_AGENT] Invalidation Req index=%0d: %p", j, tmp);
         do_send_invalidation_ack(tmp);
         #10ns;
       end
     endtask

     // Receive invalidation requests from the DUT
     task automatic do_send_invalidation_ack(
       ref  dti_ats_inv_req_s inv_req_array
     );
       dti_ats_inv_ack_s inv_ack;

       inv_ack = '0;
       inv_ack.s_msg_type = DTI_ATS_INV_ACK;

       $display("[ACK_PROCESS] Sending Inv Ack itag=%0d: %p",
                 inv_req_array.itag, inv_ack);
       master_drv.send(inv_ack, 1'b1);

       repeat(3) @(posedge master_drv.axi_stream.clk_i);
     endtask

     // Send out-of-order invalidation completions
     task automatic send_invalidation_completions(
       input  int count,
       ref    dti_ats_inv_req_s inv_req_array[$]
     );
       dti_ats_inv_comp_s inv_comp;
       for(int i = count-1; i >= 0; i--) begin
         inv_comp            = '0;
         inv_comp.s_msg_type = DTI_ATS_INV_COMP;
         inv_comp.sid        = inv_req_array[i].sid;
         inv_comp.itag       = inv_req_array[i].itag;
         inv_comp.t          = inv_req_array[i].t;

         $display("[PCIE_ATS_AGENT] Sending Inv Comp OOO i=%0d => %p", i, inv_comp);
         master_drv.send(inv_comp, 1'b1);
         #10ns;
       end
     endtask

     // Receive N translation responses
     task automatic dti_synch_request(ref logic inv_completed);
        bit dummy_last;
        dti_ats_sync_req_s local_req;
        dti_ats_sync_ack_s local_resp;
        while(local_req.s_msg_type != DTI_ATS_SYNC_REQ)
          slave_drv.recv(local_req, dummy_last);

        @(posedge inv_completed);

        local_resp = '0;
        local_resp.s_msg_type = DTI_ATS_SYNC_ACK;
        $display("[PCIE_ATS_AGENT] Sync Request received... Responding with synch ack.");
        master_drv.send(local_resp, 1'b1);
     endtask

   endclass

endpackage
