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

module ats_dti_condis_cmd_fsm
  import rv_iommu_dti_ats_pkg::*;
#(
  parameter int MAX_TOKENS = 16
) (
  input logic  clk_i,
  input logic  rst_ni,

  // Upstream msgs
  output dti_payload_s up_msg_o,
  output logic         up_msg_valid_o,
  input  logic         up_msg_ready_i,

  // Downstream msgs
  input  dti_payload_s dn_msg_i,
  input logic          dn_msg_valid_i,
  output logic         dn_msg_ready_o,

  // Granted Tokens
  output logic [11:0]  granted_trans_tok_o,
  output logic [3:0]   granted_inv_tok_o,

  // Link status
  output logic [1:0]   link_status_o,

  // T bit support
  output logic         t_bit_o,
  output logic         sup_pri_o
);


///////////////////////////////
//// Finite State Machines  ////
////////////////////////////////

   condis_cmd_state_e condis_cmd_cs, condis_cmd_ns;

   dti_ats_condis_req_s condis_req;
   dti_ats_condis_ack_s condis_ack;

   logic        sample_tokens;

   assign link_status_o = condis_cmd_cs;

   // PRI supported
   assign sup_pri_o = 1'b1;


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
      dn_msg_ready_o               <= 1'b0;
      up_msg_valid_o               <= 1'b0;
      up_msg_o                     <= '0;
      sample_tokens                <= 1'b0;
      t_bit_o                      <= 1'b0;

      case(condis_cmd_cs)
        DISCONNECTED: begin
           if(dn_msg_valid_i && dn_msg_i[3:0] == DTI_ATS_CONDIS_REQ) begin
             dn_msg_ready_o <= 1'b1;
             condis_cmd_ns <= REQ_CONNECTED;
           end else begin
             condis_cmd_ns <= DISCONNECTED;
           end
        end
        REQ_CONNECTED: begin
           if(condis_req.protocol == 1'b1 && condis_req.state == 1'b1
              && {condis_req.tok_trans_req_msb, condis_req.tok_trans_req_lsb} <= MAX_TOKENS) begin
             condis_ack.state <= 1'b1;
             up_msg_valid_o <= 1'b1;
             up_msg_o <= dti_payload_s'(condis_ack);
             sample_tokens <= 1'b1;
             if(up_msg_ready_i && up_msg_valid_o)
               condis_cmd_ns <= CONNECTED;
             else
               condis_cmd_ns <= REQ_CONNECTED;
           end else begin
             up_msg_valid_o <= 1'b1;
             if(up_msg_ready_i && up_msg_valid_o)
               condis_cmd_ns <= DISCONNECTED;
             else
               condis_cmd_ns <= REQ_CONNECTED;
           end
        end
        CONNECTED: begin
           t_bit_o <= condis_req.sup_t;
           if(dn_msg_valid_i && dn_msg_i[3:0] == DTI_ATS_CONDIS_REQ) begin
             dn_msg_ready_o <= 1'b1;
             condis_cmd_ns <= REQ_DISCONNECTED;
           end else begin
             condis_cmd_ns <= CONNECTED;
           end
        end
        REQ_DISCONNECTED: begin // check what to do when the state=1 even if for a disconnect req. not clear from spec.
          up_msg_valid_o <= 1'b1;
          up_msg_o <= dti_payload_s'(condis_ack);
           if(up_msg_ready_i && up_msg_valid_o) begin
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
      else if (dn_msg_i[3:0] == DTI_ATS_CONDIS_REQ && dn_msg_valid_i && dn_msg_ready_o)
        condis_req <= dti_ats_condis_req_s'(dn_msg_i);
   end

   always_ff @(posedge clk_i or negedge rst_ni) begin : token_assignment
      if(~rst_ni) begin
         granted_trans_tok_o <= '0;
         granted_inv_tok_o   <= '0;
      end else if (condis_cmd_cs == DISCONNECTED) begin
         granted_trans_tok_o <= '0;
         granted_inv_tok_o   <= '0;
      end else if (sample_tokens) begin
         granted_trans_tok_o <= {condis_ack.tok_trans_gnt_msb,condis_ack.tok_trans_gnt_lsb};
         granted_inv_tok_o <= condis_req.tok_inv_gnt;
      end
   end

endmodule
