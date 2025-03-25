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

module ats_dti_trans_cmd_fsm
  import rv_iommu_dti_ats_pkg::*;
  import rv_iommu::*;
#(
  parameter int MAX_TOKENS = 16,
  parameter type trans_req_data_t  = logic,
  parameter type trans_resp_data_t = logic
) (
  input logic          clk_i,
  input logic          rst_ni,

  // Forward messages to PCIe
  output dti_payload_s up_msg_o,
  output logic         up_msg_valid_o,
  input logic          up_msg_ready_i,

  // Receive messages from PCIe
  input  dti_payload_s dn_msg_i,
  input logic          dn_msg_valid_i,
  output logic         dn_msg_ready_o,

  // Translation request towards IOMMU
  output trans_req_data_t  dti_to_iommu_trans_req_o,
  output logic             dti_to_iommu_trans_valid_o,
  input  logic             dti_to_iommu_trans_ready_i,

  // Translation response from IOMMU
  input  trans_resp_data_t iommu_to_dti_trans_resp_i,
  input  logic             iommu_to_dti_trans_valid_i,
  output logic             iommu_to_dti_trans_ready_o,

  // Maximum outstandin requests
  input logic [11:0]   gnt_trans_tok_i,

  // T bit support (defined during condis)
  input logic          t_bit_i,

  // Connection status
  input  condis_cmd_state_e link_status_i
);

   // ---------------------------------------------------------------
   // Definitions and assignments
   // ---------------------------------------------------------------

   logic fifo_push, fifo_pop, fifo_full;
   logic [$clog2(MAX_TOKENS)-1:0] fifo_usage;

   logic [11:0] trans_id_n, trans_id_c;

   logic sample_trans_rsp;

   typedef enum logic [1:0] {
     SEND_TRANS_REQ,
     WAIT_TRANS_RSP,
     SEND_FAULT,
     SEND_COMPL
   } trans_req_state_t;

   trans_req_state_t     trans_rsp_cs, trans_rsp_ns;

   dti_ats_trans_req_s   trans_req;
   dti_ats_trans_req_s   fifo_trans_req;

   trans_resp_data_t     iommu_trans_resp;

   dti_ats_trans_resp_s  dti_trans_compl;
   dti_ats_trans_fault_s dti_trans_fault;

   assign fifo_push        = ~fifo_full && dn_msg_valid_i && dn_msg_ready_o;
   assign fifo_trans_req   = dti_ats_trans_req_s'(dn_msg_i);
   assign sample_trans_rsp = iommu_to_dti_trans_valid_i && iommu_to_dti_trans_ready_o;

   // --------------------------------------------------------------
   // FIFO for buffering incoming input trans request from PCIe
   // --------------------------------------------------------------
   fifo_v3 #(
     .FALL_THROUGH  ( 1'b0                ),
     .DATA_WIDTH    ( PAYLOAD_SIZE        ),
     .DEPTH         ( MAX_TOKENS          ),
     .dtype         ( dti_ats_trans_req_s )
   ) i_inv_req_fifo (
     .clk_i         ( clk_i          ),
     .rst_ni        ( rst_ni         ),
     .flush_i       ( '0             ),
     .testmode_i    ( '0             ),
     .full_o        ( fifo_full      ),
     .empty_o       ( fifo_empty     ),
     .usage_o       ( fifo_usage     ),
     .data_i        ( fifo_trans_req ),
     .push_i        ( fifo_push      ),
     .data_o        ( trans_req      ),
     .pop_i         ( fifo_pop       )
   );

   //////////////
   //// FSM  ////
   //////////////

   // -------------------------------------------------------------
   // Translation Request Receiver
   // -------------------------------------------------------------
   always_comb begin : receive_trans_req
      dn_msg_ready_o   = 1'b0;
      if(link_status_i == CONNECTED) begin
         if(dn_msg_valid_i                     &&
            dn_msg_i[3:0] == DTI_ATS_TRANS_REQ &&
            fifo_usage <= gnt_trans_tok_i) begin
            dn_msg_ready_o = 1'b1;
         end
      end
   end

   // -------------------------------------------------------------
   // Translation Fault/Completion handler
   // -------------------------------------------------------------
   always_comb begin : send_trans_comp_fault_to_pcie
      up_msg_o                   = '0;
      up_msg_valid_o             = 1'b0;
      fifo_pop                   = 1'b0;
      dti_to_iommu_trans_req_o   = '0;
      dti_to_iommu_trans_valid_o = 1'b0;
      iommu_to_dti_trans_ready_o = 1'b0;
      dti_trans_compl            = '0;
      dti_trans_fault            = '0;
      trans_rsp_ns               = trans_rsp_cs;
      trans_id_n                 = trans_id_c;
      if(link_status_i == CONNECTED) begin
         case(trans_rsp_cs)
           SEND_TRANS_REQ: begin
              if(~fifo_empty) begin
                 dti_to_iommu_trans_req_o.iova      = trans_req.IA;
                 dti_to_iommu_trans_req_o.did       = trans_req.sid[DevIdWidth-1:0];
                 dti_to_iommu_trans_req_o.pid_valid = trans_req.ssv;
                 dti_to_iommu_trans_req_o.pid       = trans_req.ssv ? trans_req.ssid : '0;
                 dti_to_iommu_trans_req_o.ttype     = PCIE_ATS_TRANS_REQ;
                 dti_to_iommu_trans_req_o.priv      = trans_req.ssv ? trans_req.PnU  : '0;
                 dti_to_iommu_trans_req_o.is_debug  = 1'b0;
                 dti_to_iommu_trans_valid_o         = 1'b1;
                 if(dti_to_iommu_trans_valid_o &&
                    dti_to_iommu_trans_ready_i) begin
                   trans_rsp_ns = WAIT_TRANS_RSP;
                   trans_id_n = {trans_req.trans_id_msb, trans_req.trans_id_msb};
                 end
              end
           end
           WAIT_TRANS_RSP: begin
              if(iommu_to_dti_trans_valid_i) begin
                 iommu_to_dti_trans_ready_o = 1'b1;
                 if(iommu_to_dti_trans_resp_i.error)
                   trans_rsp_ns = SEND_FAULT;
                 else
                   trans_rsp_ns = SEND_COMPL;
              end
           end
           SEND_FAULT: begin
              dti_trans_fault              = '0;
              // This default is forbidden, must be correctly overwritten when needed.
              dti_trans_fault.fault_type   = 2'b11;
              dti_trans_fault.s_msg_type   = DTI_ATS_TRANS_FAULT;
              dti_trans_fault.trans_id_lsb = trans_req.trans_id_lsb;
              dti_trans_fault.trans_id_msb = trans_req.trans_id_msb;
              // Handle the Fault Type according to the IOMMU Spec section 2.6
              if(iommu_trans_resp.fault_code == INSTR_ACCESS_FAULT        ||
                 iommu_trans_resp.fault_code == LD_ACCESS_FAULT           ||
                 iommu_trans_resp.fault_code == ST_ACCESS_FAULT           ||
                 iommu_trans_resp.fault_code == MSI_PTE_LD_ACCESS_FAULT   ||
                 iommu_trans_resp.fault_code == MSI_PTE_MISCONFIGURED     ||
                 iommu_trans_resp.fault_code == PDT_ENTRY_LD_ACCESS_FAULT ||
                 iommu_trans_resp.fault_code == PDT_ENTRY_MISCONFIGURED) begin
                 dti_trans_fault.fault_type   = 2'b01;
              end else if(iommu_trans_resp.fault_code == ALL_INB_TRANSACTIONS_DISALLOWED ||
                          iommu_trans_resp.fault_code == DDT_ENTRY_LD_ACCESS_FAULT       ||
                          iommu_trans_resp.fault_code == DDT_ENTRY_INVALID               ||
                          iommu_trans_resp.fault_code == DDT_ENTRY_MISCONFIGURED         ||
                          iommu_trans_resp.fault_code == TRANS_TYPE_DISALLOWED) begin
                 dti_trans_fault.fault_type   = 2'b10;
              end else if(trans_req.ssv && trans_req.PnU && iommu_trans_resp.u && !iommu_trans_resp.sum ||
                          trans_req.ssv && !trans_req.PnU && !iommu_trans_resp.u ||
                          iommu_trans_resp.x && !iommu_trans_resp.r              ||
                          iommu_trans_resp.fault_code == INSTR_PAGE_FAULT        ||
                          iommu_trans_resp.fault_code == LOAD_PAGE_FAULT         ||
                          iommu_trans_resp.fault_code == STORE_PAGE_FAULT        ||
                          iommu_trans_resp.fault_code == INSTR_GUEST_PAGE_FAULT  ||
                          iommu_trans_resp.fault_code == LOAD_GUEST_PAGE_FAULT   ||
                          iommu_trans_resp.fault_code == MSI_PTE_INVALID         ||
                          iommu_trans_resp.fault_code == PDT_ENTRY_INVALID) begin
                 dti_trans_fault.fault_type   = 2'b00;
              end
              up_msg_o = dti_payload_s'(dti_trans_fault);
              up_msg_valid_o = 1'b1;
              if(up_msg_ready_i) begin
                trans_rsp_ns = SEND_TRANS_REQ;
                fifo_pop = 1'b1;
              end
           end
           SEND_COMPL: begin
              dti_trans_compl              = '0;
              dti_trans_compl.s_msg_type   = DTI_ATS_TRANS_RESP;
              dti_trans_compl.trans_id_lsb = trans_req.trans_id_lsb;
              dti_trans_compl.trans_id_msb = trans_req.trans_id_msb;
              dti_trans_compl.untrans      = iommu_trans_resp.is_mrif;
              dti_trans_compl.CXL_IO       = !trans_req.CXL ? 1'b0 : iommu_trans_resp.is_mrif || iommu_trans_resp.t2gpa;
              dti_trans_compl.bypass       = iommu_trans_resp.bypass;
              // Grant read permission if requested and granted by tl logic. if mrif, r,w,u = 1
              dti_trans_compl.allow_r      = !iommu_trans_resp.is_mrif ? trans_req.nW && iommu_trans_resp.r : 1'b1;
              // Grant write permission if requested, granted by tl logic, and read is granted as well. if mrif, r,w,u = 1
              dti_trans_compl.allow_w      = !iommu_trans_resp.is_mrif ? !trans_req.nW && iommu_trans_resp.w && iommu_trans_resp.r : 1'b1;
              // Grant exe permission if requested, if read is granted, if InD=1 and X granted.
              dti_trans_compl.allow_x      = iommu_trans_resp.r ? trans_req.InD && iommu_trans_resp.x : 1'b0;
              dti_trans_compl.te           = t_bit_i; // ask Cristiano
              dti_trans_compl.trans_rng    = iommu_trans_resp.range;
              dti_trans_compl.AMA          = '0 ;
              dti_trans_compl.OA           = {8'b0, iommu_trans_resp.spaddr[55:12]};
              up_msg_o = dti_payload_s'(dti_trans_compl);
              up_msg_valid_o = 1'b1;
              if(up_msg_ready_i) begin
                trans_rsp_ns = SEND_TRANS_REQ;
                fifo_pop = 1'b1;
              end
           end
           default: trans_rsp_ns = SEND_TRANS_REQ;
         endcase
      end
   end

   //////////////
   //// FFs  ////
   //////////////
   always_ff @(posedge clk_i or negedge rst_ni) begin
      if(~rst_ni) begin
        trans_rsp_cs <= SEND_TRANS_REQ;
      end else begin
        trans_rsp_cs <= trans_rsp_ns;
      end
   end

   always_ff @(posedge clk_i or negedge rst_ni or posedge sample_trans_rsp) begin
      if(~rst_ni) begin
        iommu_trans_resp <= '0;
      end else if(sample_trans_rsp) begin
        iommu_trans_resp <= iommu_to_dti_trans_resp_i;
      end
   end

endmodule
