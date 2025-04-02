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
// Date: 26/03/2025
//
// Authors:
// - Maicol Ciani <maicol.ciani@unibo.it>
//

module ats_dti_page_req_cmd_fsm
  import rv_iommu::*;
  import rv_iommu_dti_ats_pkg::*;
(
  input logic       clk_i,
  input logic       rst_ni,

  // Upstream messages toward PCIe
  output dti_payload_s up_msg_o,
  output logic         up_msg_valid_o,
  input  logic         up_msg_ready_i,

  // Downstream messages from PCIe
  input  dti_payload_s dn_msg_i,
  input  logic         dn_msg_valid_i,
  output logic         dn_msg_ready_o,

  // Forward PAGE_REQ toward IOMMU
  output pq_record_t dti_to_iommu_page_req_o,
  output logic       dti_to_iommu_page_valid_o,
  input  logic       dti_to_iommu_page_ready_i,
  input  pri_fault   dti_to_iommu_page_fault_i,

  // Return PAGE_RESP from IOMUM
  input  cq_atsprgr_t iommu_to_dti_page_resp_i,
  input  logic        iommu_to_dti_page_valid_i,
  output logic        iommu_to_dti_page_ready_o,

  // Link status
  input condis_cmd_state_e link_status_i,

  // DDT interface
  output device_id_t ats_ddtc_did_o,
  output logic       ats_ddtc_valid_o,
  input  ats_tc_t    ats_ddtc_tc_i,
  input  logic       ats_ddtc_ready_i,
  input  cause_t     ats_ddtc_fault_i,

  input logic [31:0] pq_head_i,
  input logic [31:0] pq_tail_i,

  input logic [3:0]  ddtp_iommu_mode_i,
  input logic        t_bit_i,
  input logic        sup_pri_i
);

   // -------------------------------------------------------------
   // Defines
   // -------------------------------------------------------------

   // FSM States
   enum logic [1:0] {
       IDLE_RESP,
       SEND_RESP,
       WAIT_RESPACK
   } state_resp_q, state_resp_n;

   enum logic [1:0] {
       IDLE,
       FETCH_TC,
       WRITE_PQ,
       ERROR
   } state_q, state_n;

   localparam int FIFO_DEPTH = 8;

   dti_ats_page_resp_s page_resp_msg;
   dti_ats_page_ack_s  page_ack_msg;

   logic is_page_req;
   logic is_page_respack;

   logic page_ack_valid, page_ack_ready;

   dti_payload_s [1:0] up_msg_arb;
   logic         [1:0] up_valid_arb;
   logic         [1:0] up_ready_arb;

   dti_ats_page_req_s fifo_in,   fifo_out;
   logic              fifo_full, fifo_empty;
   logic              fifo_push, fifo_pop;

   logic page_resp_valid, page_resp_ready;

   logic page_err_resp_valid;

   logic new_req_stored;

   logic stored_dly;

   logic [1:0] dn_msg_ready;

   logic [7:0] segment;

   // -------------------------------------------------------------
   // Assignments
   // -------------------------------------------------------------
   assign fifo_in  = dti_ats_page_req_s'(dn_msg_i);
   assign fifo_pop = dti_to_iommu_page_valid_o && dti_to_iommu_page_ready_i;

   assign up_msg_arb[0]    = dti_payload_s'(page_ack_msg);
   assign up_valid_arb[0]  = page_ack_valid;
   assign page_ack_ready   = up_ready_arb[0];

   assign up_msg_arb[1]    = dti_payload_s'(page_resp_msg);
   assign up_valid_arb[1]  = page_resp_valid | page_err_resp_valid;
   assign page_resp_ready  = up_ready_arb[1];

   //assign iommu_to_dti_page_ready_o = page_resp_ready;

   assign page_ack_valid = stored_dly;

   assign dn_msg_ready_o = dn_msg_ready[0] | dn_msg_ready[1];

   assign segment = iommu_to_dti_page_resp_i.dsv  ?
                    iommu_to_dti_page_resp_i.dseg :
                    8'b0;

   // -------------------------------------------------------------
   // Modules instances
   // -------------------------------------------------------------
   fifo_v3 #(
     .DATA_WIDTH   ( $bits(dti_ats_page_req_s)),
     .FALL_THROUGH ( 1'b0               ),
     .DEPTH        ( FIFO_DEPTH         ),
     .dtype        ( dti_ats_page_req_s)
   ) i_page_req_fifo (
     .clk_i      ( clk_i       ),
     .rst_ni     ( rst_ni      ),
     .flush_i    ( '0          ),
     .testmode_i ( '0          ),
     .full_o     ( fifo_full   ),
     .empty_o    ( fifo_empty  ),
     .usage_o    (             ),
     .data_i     ( fifo_in     ),
     .push_i     ( fifo_push   ),
     .data_o     ( fifo_out    ),
     .pop_i      ( fifo_pop    )
   );

   stream_arbiter #(
     .DATA_T  ( dti_payload_s ),
     .N_INP   ( 2             ),
     .ARBITER ( "rr"          )
   ) i_page_req_arb (
     .clk_i       ( clk_i          ),
     .rst_ni      ( rst_ni         ),
     .inp_data_i  ( up_msg_arb     ),
     .inp_valid_i ( up_valid_arb   ),
     .inp_ready_o ( up_ready_arb   ),
     .oup_data_o  ( up_msg_o       ),
     .oup_valid_o ( up_msg_valid_o ),
     .oup_ready_i ( up_msg_ready_i )
   );

   // -------------------------------------------------------------
   // FSMs and comb logic
   // -------------------------------------------------------------
   always_comb begin
     is_page_req     = 1'b0;
     is_page_respack = 1'b0;
     if (link_status_i == CONNECTED && dn_msg_valid_i) begin
       if (dn_msg_i[3:0] == DTI_ATS_PAGE_REQ) begin
         is_page_req = 1'b1;
       end
       else if (dn_msg_i[3:0] == DTI_ATS_PAGE_RESPACK) begin
         is_page_respack = 1'b1;
       end
     end
   end

   always_comb begin
     dn_msg_ready[0]  = 1'b0;
     fifo_push        = 1'b0;
     new_req_stored   = 1'b0;
     if (is_page_req && (link_status_i == CONNECTED) && ~fifo_full) begin
        dn_msg_ready[0] = 1'b1;
        fifo_push       = 1'b1;
        new_req_stored  = 1'b1;
     end
   end

   always_comb begin : send_page_request
      state_n                   = state_q;
      ats_ddtc_did_o            = '0;
      ats_ddtc_valid_o          = 1'b0;
      dti_to_iommu_page_valid_o = 1'b0;
      page_err_resp_valid       = 1'b0;
      if (link_status_i == CONNECTED) begin
         case(state_q)
            IDLE: begin
               if(~fifo_empty)
                  state_n = FETCH_TC;
            end
            FETCH_TC: begin
               ats_ddtc_did_o = fifo_out.sid;
               ats_ddtc_valid_o = 1'b1;
               if(ats_ddtc_ready_i) begin
                  if(ats_ddtc_tc_i.en_pri == 1'b1 &&
                     ats_ddtc_tc_i.en_ats == 1'b1 &&
                     ddtp_iommu_mode_i != 4'b0 &&
                     ddtp_iommu_mode_i != 4'b1 ) begin
                     state_n = WRITE_PQ;
                  end else begin
                     // These requests do not require a resp, silently discarted when error.
                     if((fifo_out.last == 1'b1 && fifo_out.write == 1'b0 && fifo_out.read == 1'b0) ||
                         fifo_out.last == 1'b1)
                       state_n = IDLE;
                     else
                       state_n = ERROR;
                  end
               end
            end
            WRITE_PQ: begin
               dti_to_iommu_page_valid_o = 1'b1;
               if(dti_to_iommu_page_ready_i) begin
                  // No error occured during PQ usage, return to IDLE.
                  if(dti_to_iommu_page_fault_i.pq_mem_f  == 1'b0 &&
                     dti_to_iommu_page_fault_i.pq_en == 1'b1     &&
                     dti_to_iommu_page_fault_i.pq_of == 1'b0   ) begin
                     state_n = IDLE;
                  end else begin
                     // These requests do not require a resp, silently discarted.
                     if((fifo_out.last == 1'b1 && fifo_out.write == 1'b0 && fifo_out.read == 1'b0) ||
                         fifo_out.last == 1'b1)
                       state_n = IDLE;
                     else
                       state_n = ERROR;
                  end
               end
            end
            ERROR: begin
               page_err_resp_valid = 1'b1;
               if(page_resp_ready) begin
                  state_n = IDLE;
               end
            end
            default: state_n = ERROR;
         endcase
      end
   end

   always_comb begin
      iommu_to_dti_page_ready_o = 1'b0;
      page_resp_valid           = 1'b0;
      state_resp_n              = state_resp_q;
      dn_msg_ready[1]           = 1'b0;
      if(link_status_i==CONNECTED) begin
         case(state_resp_q)
            IDLE_RESP: begin
               // Receive ATS.PRGR command from CQ
               if(iommu_to_dti_page_valid_i) begin
                  state_resp_n = SEND_RESP;
               end
            end
            SEND_RESP: begin
               page_resp_valid = 1'b1;
               // Send Page Resp from CQ to PCIe
               if(page_resp_ready)
                  state_resp_n = WAIT_RESPACK;
            end
            WAIT_RESPACK: begin
               // Wait for Page Resp Ack from PCIe
               if(is_page_respack) begin
                  dn_msg_ready[1] = 1'b1;
                  // Completion signal to CQ.
                  iommu_to_dti_page_ready_o = 1'b1;
                  state_resp_n = IDLE_RESP;
               end
            end
         endcase
      end
   end

   // -------------------------------------------------------------
   // Payloads
   // -------------------------------------------------------------
   always_comb begin : page_req_group_resp
     // IOMMU generated error responce if allowed.
     if(state_q == ERROR) begin
        page_resp_msg            = '0;
        page_resp_msg.s_msg_type = DTI_ATS_PAGE_RESP;
        page_resp_msg.t          = t_bit_i;
        // Provide ssv only if PRPR=1, otherwise no PASID shall be returned.
        page_resp_msg.ssv        = ats_ddtc_tc_i.prpr ? fifo_out.ssv : 1'b0;
        page_resp_msg.ssid       = page_resp_msg.ssv ? fifo_out.ssid : '0;
        page_resp_msg.sid        = fifo_out.sid;
        page_resp_msg.prg_index  = fifo_out.prg_index;
        if(ddtp_iommu_mode_i                   == 1'b0                      ||
           ats_ddtc_fault_i                    == DDT_ENTRY_LD_ACCESS_FAULT ||
           ats_ddtc_fault_i                    == DDT_ENTRY_MISCONFIGURED   ||
           ats_ddtc_fault_i                    == DDT_ENTRY_INVALID         ||
           dti_to_iommu_page_fault_i.pq_mem_f  == 1'b1                      ||
           dti_to_iommu_page_fault_i.pq_en     == 1'b0 ) begin
           page_resp_msg.resp       = ResponseFailure;
        end else if( ddtp_iommu_mode_i    == 1'b0 ||
                     ats_ddtc_tc_i.en_pri == 1'b0 ) begin
           page_resp_msg.resp       = InvalidRequest;
        end else if( dti_to_iommu_page_fault_i.pq_of == 1'b1 ||
                     (pq_tail_i - pq_head_i) == 32'b1 ) begin
           page_resp_msg.resp       = Success;
        end
     // Page Group Resp taken from CQ
     end else begin
        page_resp_msg            = '0;
        page_resp_msg.s_msg_type = DTI_ATS_PAGE_RESP;
        page_resp_msg.t          = t_bit_i;
        page_resp_msg.ssv        = iommu_to_dti_page_resp_i.pv;
        page_resp_msg.ssid       = iommu_to_dti_page_resp_i.pid;
        page_resp_msg.sid        = {segment, iommu_to_dti_page_resp_i.rid};
        page_resp_msg.prg_index  = iommu_to_dti_page_resp_i.page_index;
        if(iommu_to_dti_page_resp_i.resp == 4'b0000)
          page_resp_msg.resp       = Success;
        else if (iommu_to_dti_page_resp_i.resp == 4'b0001)
          page_resp_msg.resp       = InvalidRequest;
        else if (iommu_to_dti_page_resp_i.resp == 4'b1111)
          page_resp_msg.resp       = ResponseFailure;
     end
   end

   always_comb begin
     dti_to_iommu_page_req_o           = '0;
     dti_to_iommu_page_req_o.pv        = fifo_out.ssv;
     dti_to_iommu_page_req_o.pid       = dti_to_iommu_page_req_o.pv ? fifo_out.ssid : '0;
     dti_to_iommu_page_req_o.priv      = fifo_out.priv;
     dti_to_iommu_page_req_o.exec      = fifo_out.inst;
     dti_to_iommu_page_req_o.did       = fifo_out.sid;
     dti_to_iommu_page_req_o.r         = fifo_out.read;
     dti_to_iommu_page_req_o.w         = fifo_out.write;
     dti_to_iommu_page_req_o.l         = fifo_out.last;
     dti_to_iommu_page_req_o.page_idx  = fifo_out.prg_index;
     dti_to_iommu_page_req_o.page_addr = fifo_out.addr;
   end

   always_comb begin
     page_ack_msg = '0;
     page_ack_msg.s_msg_type = DTI_ATS_PAGE_ACK;
   end

   // -------------------------------------------------------------
   // Sequential logic
   // -------------------------------------------------------------
   always_ff @(posedge clk_i or negedge rst_ni) begin
     if (~rst_ni) begin
       stored_dly <= 1'b0;
       state_q    <= IDLE;
     end else begin
       stored_dly   <= new_req_stored;
       state_resp_q <= state_resp_n;
       state_q      <= state_n;
     end
   end

endmodule
