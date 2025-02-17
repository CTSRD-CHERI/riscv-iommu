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

module ats_dti_inv_sync_cmd_fsm
  import rv_iommu_dti_ats_pkg::*;
#(
  parameter int MAX_TOKENS = 16
) (
  input logic          clk_i,
  input logic          rst_ni,

  // Fence handle
  input logic          fence_i,
  output logic         fence_comp_o,

  // Frequency to handle timeouts
  input logic [31:0]   freq_i,

  // Forward messages to PCIe
  output dti_payload_s up_msg_o,
  output logic         up_msg_valid_o,
  input logic          up_msg_ready_i,

  // Receive messages from PCIe
  input  dti_payload_s dn_msg_i,
  input logic          dn_msg_valid_i,
  output logic         dn_msg_ready_o,

  // Incoming Invalidation Request (from CQ)
  input rv_iommu_cq_inv_req_s iommu_to_dti_inv_req_i,
  input logic                 iommu_to_dti_inv_valid_i,
  output logic                iommu_to_dti_inv_ready_o,

  input logic [3:0]           granted_inv_tok_i,

  // T bit support (defined during condis)
  input logic                 t_bit_i,
  // Connection status
  input  condis_cmd_state_e   link_status_i,
  // Timeout/error
  output logic                timeout_o
);

   // ---------------------------------------------------------------
   // Definitions and assignments
   // ---------------------------------------------------------------

   logic inv_req_valid, inv_req_ready;
   logic sync_req_valid, sync_req_ready, sync_ack_valid;

   logic fifo_empty, fifo_full, fifo_pop;
   logic dn_msg_comp_ready, dn_msg_ack_ready, dn_msg_sync_ack_ready;

   logic issue_sync_req, sb_sync_req;

   logic inv_ack_valid, inv_comp_valid;

   logic inv_comp_err, sync_ack_err, inv_req_timeout;

   logic sb_full, sb_empty;

   logic [5:0] r; // range field

   logic [7:0] segment;

   dti_ats_inv_op_t operation;

   logic [4:0] next_itag_q, next_itag_n;

   dti_payload_s [1:0] up_msg_arb;
   logic [1:0]   up_msg_valid_arb;
   logic [1:0]   up_msg_ready_arb;

   typedef enum logic {
     INV,
     SYNC
   } commands_t;

   typedef enum logic {
     SEND_CMD,
     WAIT_READY
   } inv_sync_req_state_t;

   rv_iommu_cq_inv_req_s iommu_to_dti_inv_req;

   dti_ats_inv_req_s     iommu_to_pcie_inv_req;
   dti_ats_inv_ack_s     pcie_to_iommu_inv_ack;
   dti_ats_inv_comp_s    pcie_to_iommu_inv_comp, dn_msg;

   dti_ats_sync_req_s    iommu_to_pcie_sync_req;
   dti_ats_sync_ack_s    pcie_to_iommu_sync_ack;

   inv_sync_req_state_t  inv_req_cs, inv_req_ns;
   inv_sync_req_state_t  sync_req_cs, sync_req_ns;

   assign up_msg_arb[INV]        = dti_payload_s'(iommu_to_pcie_inv_req);
   assign up_msg_arb[SYNC]       = dti_payload_s'(iommu_to_pcie_sync_req);
   assign up_msg_valid_arb[INV]  = inv_req_valid;
   assign up_msg_valid_arb[SYNC] = sync_req_valid;
   assign inv_req_ready          = up_msg_ready_arb[INV];
   assign sync_req_ready         = up_msg_ready_arb[SYNC];

   assign dn_msg_ready_o = dn_msg_comp_ready || dn_msg_ack_ready || dn_msg_sync_ack_ready;

   assign issue_sync_req = fence_i || sb_sync_req;

   assign timeout_o = inv_req_timeout || inv_comp_err || sync_ack_err;

   assign dn_msg = dti_ats_inv_comp_s'(dn_msg_i);

   assign iommu_to_dti_inv_ready_o = ~fifo_full;

   assign pcie_to_iommu_inv_comp = dti_ats_inv_comp_s'(dn_msg_i);
   assign pcie_to_iommu_inv_ack  = dti_ats_inv_ack_s'(dn_msg_i);

   assign pcie_to_iommu_sync_ack = dti_ats_sync_ack_s'(dn_msg_i);

   assign segment = iommu_to_dti_inv_req.dsv  ?
                    iommu_to_dti_inv_req.dseg :
                    8'b0;

   // ---------------------------------------------------------------
   // Arbiter to mux the the two output inv/sync request interfaces
   // ---------------------------------------------------------------
   stream_arbiter #(
      .DATA_T  ( dti_payload_s ),
      .N_INP   ( 2             ),
      .ARBITER ( "rr"          )
   ) i_inv_sync_req_arb (
      .clk_i       ( clk_i            ),
      .rst_ni      ( rst_ni           ),

      .inp_data_i  ( up_msg_arb       ),
      .inp_valid_i ( up_msg_valid_arb ),
      .inp_ready_o ( up_msg_ready_arb ),

      .oup_data_o  ( up_msg_o         ),
      .oup_valid_o ( up_msg_valid_o   ),
      .oup_ready_i ( up_msg_ready_i   )
   );

   // --------------------------------------------------------------
   // FIFO for buffering incoming input inv req from IOMMU
   // --------------------------------------------------------------
   fifo_v3 #(
     .FALL_THROUGH  ( 1'b0                  ),
     .DATA_WIDTH    ( PAYLOAD_SIZE          ),
     .DEPTH         ( 16                    ),
     .dtype         ( rv_iommu_cq_inv_req_s )
   ) i_inv_req_fifo (
     .clk_i     ( clk_i      ),
     .rst_ni    ( rst_ni     ),
     .flush_i   ( '0         ),
     .testmode_i( '0         ),
     .full_o    ( fifo_full  ),
     .empty_o   ( fifo_empty ),
     .usage_o   (            ),
     .data_i    ( iommu_to_dti_inv_req_i                 ),
     .push_i    ( ~fifo_full && iommu_to_dti_inv_valid_i ),
     .data_o    ( iommu_to_dti_inv_req                   ),
     .pop_i     ( fifo_pop                                )
   );

   // -------------------------------------------------------------
   // Out-of-order invalidation handler, scoreboard approach
   // -------------------------------------------------------------
   ats_dti_inv_scoreboard #(
     .DEPTH ( 32 )
   ) i_inv_scoreboard (
     .clk_i        ( clk_i           ),
     .rst_ni       ( rst_ni          ),
     .flush_i      ( 1'b0            ),
     // Timeout logic
     .freq_i       ( freq_i          ),
     .timeout_o    ( inv_req_timeout ),
     // Issue an inv request
     .push_i       ( ~sb_full && inv_req_valid && inv_req_ready ),
     .itag_i       ( iommu_to_pcie_inv_req.itag ),
     .sid_i        ( iommu_to_pcie_inv_req.sid  ),
     .t_bit_i      ( iommu_to_pcie_inv_req.t    ),
     // Acknolwdge an inv request
     .ack_i        ( inv_ack_valid  ),
     // Complete an invalidation request
     .completion_i ( inv_comp_valid ),
     .comp_itag_i  ( dn_msg.itag    ),
     .comp_sid_i   ( dn_msg.sid     ),
     .comp_t_bit_i ( dn_msg.t       ),
     // Invalidaiton tokens
     .granted_inv_tok_i ( granted_inv_tok_i ),
     // Sync request from sb (when unacknowledged inv reqs)
     .sync_req_o        ( sb_sync_req       ),
     // Scoreboard status
     .full_o            ( sb_full           ),
     .empty_o           ( sb_empty          ),
     .usage_o           (                   )
   );

   ////////////////////////////////
   //// Finite State Machines  ////
   ////////////////////////////////

   // -------------------------------------------------------------
   // Invalidation request logic
   // -------------------------------------------------------------

   always_comb begin : inv_req_range_field
     if (!iommu_to_dti_inv_req.s) begin
       // S == 0: Only a single 4KB page is used.
       r = 6'd0;
     end else begin
       // S == 1: Start with r = 1 (i.e. at least 2 pages = 8KB).
       r = 6'd1;
       // Loop through VA bits from bit 12 to bit 63.
       for (int i = 7; i < 52; i = i + 7) begin
         if (iommu_to_dti_inv_req.untrans_addr[i] == 1'b0) begin
           // Stop when a 0 is encountered.
           break;
         end
         r = r + 6'd1;
       end
       // Clamp r to a maximum of 52.
       if (r > 6'd52)
         r = 6'd52;
     end
   end

   always_comb begin : inv_req_op_field
      // By default, NOPASID inv req
      operation = ATCI_NOPASID;
      if(iommu_to_dti_inv_req.g)
        operation = ATCI_PASID_GLOBAL;
      else if (iommu_to_dti_inv_req.pv)
        operation = ATCI_PASID;
   end

   always_comb begin : send_inv_req
      fifo_pop = 1'b0;
      inv_req_valid = 1'b0;
      inv_req_ns = SEND_CMD;
      next_itag_n   = next_itag_q;
      iommu_to_pcie_inv_req = '0;
      // -------------------------------------------------------
      // Populate the fields from the FIFO data:
      // (iommu_to_dti_inv_req is the output of the FIFO)
      // -------------------------------------------------------
      // 1) Invalidate request message type
      iommu_to_pcie_inv_req.msg_type = DTI_ATS_INV_REQ; // 4'hC
      // 2) Virtual address
      //    Map "untrans_addr" -> "va"
      iommu_to_pcie_inv_req.va   = iommu_to_dti_inv_req.untrans_addr;
      // 3) Indicate whether it's a 'T' type invalidation
      //    Established during connection procedure
      iommu_to_pcie_inv_req.t    = t_bit_i;
      // 4) Range: Define the size of the addr region to invalidate
      iommu_to_pcie_inv_req.range = r;
      // 5) SID: concatenantion of RID and (if valid) the Segment (for multi-hier)
      iommu_to_pcie_inv_req.sid = {8'b0, segment, iommu_to_dti_inv_req.rid};

      // 6) SSID: populate this field iff we have ATCI_PASID operation
      iommu_to_pcie_inv_req.ssid = iommu_to_dti_inv_req.pv  ?
                                   iommu_to_dti_inv_req.pid :
                                   20'b0;
      // 7) Operation: we have 8 bits. Encoding according to DTI spec
      iommu_to_pcie_inv_req.operation = operation;
      // 8) ITAG (identifier unique for each inv req)
      iommu_to_pcie_inv_req.itag = next_itag_q;
      // The 32-bit "unused" can remain zero
      iommu_to_pcie_inv_req.unused = 32'h0;
      if(link_status_i == CONNECTED) begin
         case(inv_req_cs)
           SEND_CMD: begin
              if(~fifo_empty) begin
                 inv_req_valid = 1'b1;
                 if(inv_req_ready && inv_req_valid) begin
                   fifo_pop = 1'b1;
                   next_itag_n = next_itag_q + 1;
                   inv_req_ns = SEND_CMD;
                 end else begin
                   inv_req_ns = WAIT_READY;
                 end
              end
           end
           WAIT_READY: begin
              inv_req_valid = 1'b1;
              if(inv_req_ready && inv_req_valid) begin
                fifo_pop = 1'b1;
                next_itag_n = next_itag_q + 1;
                inv_req_ns = SEND_CMD;
              end else begin
                inv_req_ns = WAIT_READY;
              end
           end
           default: inv_req_ns = SEND_CMD;
         endcase
      end
   end

   // -------------------------------------------------------------
   // Invalidation Acknowledge logic
   // -------------------------------------------------------------
   always_comb begin : receive_inv_ack
      inv_ack_valid = 1'b0;
      dn_msg_ack_ready = 1'b0;
      if(link_status_i == CONNECTED) begin
         if(dn_msg_valid_i &&
            dn_msg_i[3:0] == DTI_ATS_INV_ACK) begin
            dn_msg_ack_ready = 1'b1;
            inv_ack_valid = 1'b1;
         end
      end
   end

   // -------------------------------------------------------------
   // Invalidation Completion logic
   // -------------------------------------------------------------
   always_comb begin : receive_inv_comp
      inv_comp_valid = 1'b0;
      dn_msg_comp_ready = 1'b0;
      inv_comp_err = 1'b0;
      if(link_status_i == CONNECTED) begin
         if(dn_msg_valid_i &&
            dn_msg_i[3:0] == DTI_ATS_INV_COMP) begin
            dn_msg_comp_ready = 1'b1;
            inv_comp_valid = 1'b1;
            if(pcie_to_iommu_inv_comp.error)
              inv_comp_err = 1'b1;
         end
      end
   end

   // -------------------------------------------------------------
   // // Synchronization Request logic
   // -------------------------------------------------------------
   always_comb begin : send_sync_req
      sync_req_valid = 1'b0;
      sync_req_ns = SEND_CMD;
      fence_comp_o = 1'b0;
      iommu_to_pcie_sync_req = '0;
      if(link_status_i == CONNECTED) begin
         case(sync_req_cs)
           SEND_CMD: begin
              if(issue_sync_req) begin
                 sync_req_valid = 1'b1;
                 if(sync_req_ready && sync_req_valid) begin
                   sync_req_ns = SEND_CMD;
                   if(fence_i)
                     fence_comp_o = 1'b1;
                 end else begin
                   sync_req_ns = WAIT_READY;
                 end
              end
           end
           WAIT_READY: begin
              sync_req_valid = 1'b1;
              if(sync_req_ready && sync_req_valid) begin
                 sync_req_ns = SEND_CMD;
                 if(fence_i)
                   fence_comp_o = 1'b1;
              end else begin
                 sync_req_ns = WAIT_READY;
              end
           end
           default: sync_req_ns = SEND_CMD;
         endcase
      end
   end

   // -------------------------------------------------------------
   // Synchronization Acknowledge logic
   // -------------------------------------------------------------
   always_comb begin : receive_sync_ack
      sync_ack_valid = 1'b0;
      sync_ack_err = 1'b0;
      dn_msg_sync_ack_ready = 1'b0;
      if(link_status_i == CONNECTED) begin
         if(dn_msg_valid_i &&
            dn_msg_i[3:0] == DTI_ATS_SYNC_ACK) begin
            dn_msg_sync_ack_ready = 1'b1;
            sync_ack_valid = 1'b1;
            if(pcie_to_iommu_sync_ack.error)
              sync_ack_err = 1'b1;
         end
      end
   end


   ///////////////////////////
   //// Sequential Logic  ////
   ///////////////////////////

   always_ff @(posedge clk_i or negedge rst_ni) begin : inv_sync_req_state_update
      if(~rst_ni) begin
        inv_req_cs  = SEND_CMD;
        sync_req_cs = SEND_CMD;
        // Initialize the ITAG to zero
        next_itag_q  = 5'b0;
      end else begin
        inv_req_cs  = inv_req_ns;
        sync_req_cs = sync_req_ns;
        // Initialize the ITAG to zero
        next_itag_q  = next_itag_n;
      end
   end

endmodule
