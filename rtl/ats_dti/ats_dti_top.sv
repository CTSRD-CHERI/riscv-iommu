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
// Authors:
// - Maicol Ciani <maicol.ciani@unibo.it>
//

module dti_ats_top
  import rv_iommu_dti_ats_pkg::*;
#(
  parameter      DATA_WIDTH = 160,
  parameter      MAX_TOKENS = 16,
  parameter type axis_req_t = logic,
  parameter type axis_rsp_t = logic
) (
  input  logic      clk_i,
  input  logic      rst_ni,

  // AXI4-Stream Slave Interface DTI_ATS->PCIe
  input  axis_req_t axis_req_dn_i,
  output axis_rsp_t axis_rsp_dn_o,

  // AXI4-Stream Master Interface PCIe->DTI_ATS
  output axis_req_t axis_req_up_o,
  input  axis_rsp_t axis_rsp_up_i,

  // Invalidation Request IOMMU -> DTI_ATS
  input  dti_ats_inv_req_s inv_req_cmd_i,
  input  logic             inv_req_cmd_valid_i,
  output logic             inv_req_cmd_ready_o

  // TBD ...
  // TBD ...
  // TBD ...
  // TBD ...

);

/////////////////////////////
//// Parameters and Defs ////
/////////////////////////////

   dti_payload_s dn_msg, up_msg;

   logic         up_msg_valid, up_msg_ready;
   logic         dn_msg_valid, dn_msg_ready;

   logic         connected; // Link status
   logic         condis_ack_valid, condis_req_ready;

   assign dn_msg_ready = condis_req_ready;
   assign up_msg_valid = condis_ack_valid;

/////////////////////////
//// Transport layer ////
/////////////////////////

   //Downstream AXIS Receiver
   dti_ats_axis_dn_fsm #(
     .DATA_WIDTH ( DATA_WIDTH ),
     .axis_req_t ( axis_req_t ),
     .axis_rsp_t ( axis_rsp_t )
   ) i_downstream_fsm (
     .clk_i          ( clk_i         ),
     .rst_ni         ( rst_ni        ),
     .axis_req_dn_i  ( axis_req_dn_i ),
     .axis_rsp_dn_o  ( axis_rsp_dn_o ),
     .dn_msg_o       ( dn_msg        ),
     .dn_msg_valid_o ( dn_msg_valid  ),
     .dn_msg_ready_i ( dn_msg_ready  )
   );

   //Upstream AXIS Driver
   dti_ats_axis_up_fsm #(
     .DATA_WIDTH ( DATA_WIDTH ),
     .axis_req_t ( axis_req_t ),
     .axis_rsp_t ( axis_rsp_t )
   ) i_upstream_fsm (
     .clk_i          ( clk_i         ),
     .rst_ni         ( rst_ni        ),
     .axis_req_up_o  ( axis_req_up_o ),
     .axis_rsp_up_i  ( axis_rsp_up_i ),
     .up_msg_i       ( up_msg        ),
     .up_msg_valid_i ( up_msg_valid  ),
     .up_msg_ready_o ( up_msg_ready  )
   );

////////////////////////////////
//// Finite State Machines  ////
////////////////////////////////

   ats_dti_condis_cmd_fsm #(
     .MAX_TOKENS     ( MAX_TOKENS       )
   ) i_condis_fsm (
     .clk_i          ( clk_i            ),
     .rst_ni         ( rst_ni           ),
     .up_msg_o       ( up_msg           ),
     .up_msg_valid_o ( condis_ack_valid ),
     .up_msg_ready_i ( up_msg_ready     ),
     .dn_msg_i       ( dn_msg           ),
     .dn_msg_valid_i ( dn_msg_valid     ),
     .dn_msg_ready_o ( condis_req_ready ),
     .connected_o    ( connected        )
   );

   // token stuff: counters to keep track of the tokens
   // fifos to keep the outstanding commands

 endmodule















/*
   typedef enum logic [1:0] {
     DISCONNECTED,
     REQ_CONNECTED,
     CONNECTED,
     REQ_DISCONNECTED
   } condis_cmd_state_e;

   condis_cmd_state_e condis_cmd_cs, condis_cmd_ns;

   dti_ats_condis_req_s condis_req;
   dti_ats_condis_ack_s condis_ack;

   always_comb begin : condis_cmd_fsm
      // Message condis ack defaults
      condis_ack.msg_type          <= DTI_ATS_CONDIS_ACK;           // condis ack encoding
      condis_ack.state             <= 1'b0;                         // by default, disconnected
      condis_ack.reserved_0        <= 3'b0;                         // SBZ
      condis_ack.version           <= 4'b0011;                       // DTI-ATSv4 encoding
      condis_ack.tok_trans_gnt_lsb <= condis_req.tok_trans_req_lsb;
      condis_ack.sup_pri           <= 1'b1;                         // Page Request Intf supported
      condis_ack.reserved_1        <= 4'b0;                         // SBZ
      condis_ack.sup_t             <= condis_req.sup_t;
      condis_ack.reserved_2        <= 2'b0;                         // SBZ
      condis_ack.tok_trans_gnt_msb <= condis_req.tok_trans_req_msb;
      condis_ack.unused            <= 128'b0;
      // Handshake signals
      condis_ack_valid             <= 1'b0;
      condis_req_ready             <= 1'b0;
      // Link status
      connected                    <= 1'b0;

      case(condis_cmd_cs)
        DISCONNECTED: begin
           if(dn_msg_valid && dn_msg[3:0] == DTI_ATS_CONDIS_REQ) begin
             condis_req_ready <= 1'b1;
             condis_cmd_ns <= REQ_CONNECTED;
           end else begin
             condis_cmd_ns <= DISCONNECTED;
           end
        end
        REQ_CONNECTED: begin
           if(condis_req.protocol == 1'b1 && condis_req.state == 1'b1
              && {condis_req.tok_trans_req_msb, condis_req.tok_trans_req_lsb} <= MAX_TOKENS) begin
             condis_ack.state <= 1'b1;
             condis_ack_valid <= 1'b1;
             if(up_msg_ready && up_msg_valid)
               condis_cmd_ns <= CONNECTED;
             else
               condis_cmd_ns <= REQ_CONNECTED;
           end else begin
             condis_ack_valid <= 1'b1;
             if(up_msg_ready && up_msg_valid)
               condis_cmd_ns <= DISCONNECTED;
             else
               condis_cmd_ns <= REQ_CONNECTED;
           end
        end
        CONNECTED: begin
           connected <= 1'b1;
           if(dn_msg_valid && dn_msg[3:0] == DTI_ATS_CONDIS_REQ) begin
             condis_req_ready <= 1'b1;
             condis_cmd_ns <= REQ_DISCONNECTED;
           end else begin
             condis_cmd_ns <= CONNECTED;
           end
        end
        REQ_DISCONNECTED: begin         // check what to do when the state=1 even if for a disconnect req. not clear from spec.
          condis_ack_valid <= 1'b1;
           if(up_msg_ready && up_msg_valid) begin
             condis_cmd_ns <= DISCONNECTED;
           end else begin
             condis_cmd_ns <= REQ_DISCONNECTED;
           end
        end
        default: begin
           condis_cmd_ns <= DISCONNECTED;
        end
      endcase
   end

///////////////////////////
//// Sequential Logic  ////
///////////////////////////

   always_ff @(posedge clk_i or negedge rst_ni) begin : condis_state_update
      if(~rst_ni)
        condis_cmd_cs <= DISCONNECTED;
      else
        condis_cmd_cs <= condis_cmd_ns;
   end

   always_ff @(posedge clk_i or negedge rst_ni) begin : dn_condis_req
      if(~rst_ni)
        condis_req <= '0;
      else if (dn_msg[3:0] == DTI_ATS_CONDIS_REQ && dn_msg_valid && dn_msg_ready)
        condis_req <= dti_ats_condis_req_s'(dn_msg);
   end

   always_ff @(posedge clk_i or negedge rst_ni) begin : up_condis_ack
      if(~rst_ni)
        up_msg <= '0;
      else if (up_msg_valid && up_msg_ready)
        up_msg <= dti_payload_s'(condis_ack);
   end
*/
