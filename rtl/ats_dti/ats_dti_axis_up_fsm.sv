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

module dti_ats_axis_up_fsm
  import rv_iommu_dti_ats_pkg::*;
 #(
  parameter DATA_WIDTH = 160,
  parameter type axis_req_t = logic,
  parameter type axis_rsp_t = logic
) (
  input logic          clk_i,
  input logic          rst_ni,

  // AXI4-Stream Master Interface
  output axis_req_t    axis_req_up_o,
  input  axis_rsp_t    axis_rsp_up_i,

  // DTI-ATS Message Input
  input  dti_payload_s up_msg_i,
  input  logic         up_msg_valid_i,
  output logic         up_msg_ready_o
);

  // State Definition
  typedef enum logic {
   IDLE,
   SENDING
  } state_e;

  state_e current_state, next_state;

  dti_payload_s payload_q, payload_n;

  // State Transition Logic
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      current_state <= IDLE;
      payload_q     <= '0;
    end else begin
      current_state <= next_state;
      payload_q     <= payload_n;
    end
  end

  // Next State Logic
  always_comb begin
    payload_n = payload_q;
    next_state = current_state;
    case (current_state)
      IDLE: begin
        if(up_msg_valid_i && up_msg_ready_o) begin
          payload_n <= up_msg_i;
          next_state = SENDING;
        end else begin
          next_state = IDLE;
        end
      end
      SENDING: begin
        if(axis_rsp_up_i.tready && axis_req_up_o.tvalid)
          next_state = IDLE;
        else
          next_state = SENDING;
      end
      default : next_state = IDLE;
    endcase
  end

  // Output and Payload Logic
  always_ff @(posedge clk_i) begin
    if(!rst_ni) begin
      axis_req_up_o.tvalid <= '0;
      axis_req_up_o.t.data <= '0;
      axis_req_up_o.t.last <= '0;
      axis_req_up_o.t.user <= '0;
      axis_req_up_o.t.keep <= '1;
      axis_req_up_o.t.strb <= '1;
      axis_req_up_o.t.id   <= '0; // not implemented
      axis_req_up_o.t.dest <= '0; // TBD
      up_msg_ready_o       <= '0;
    end else begin
      axis_req_up_o.tvalid  <= '0;
      axis_req_up_o.t.data  <= '0;
      axis_req_up_o.t.last  <= '0;
      axis_req_up_o.t.user  <= '0;
      axis_req_up_o.t.keep  <= '1;
      axis_req_up_o.t.strb  <= '1;
      axis_req_up_o.t.id    <= '0;
      axis_req_up_o.t.dest  <= '0;
      up_msg_ready_o        <= '0;
      case(current_state)
        IDLE: begin
          if(up_msg_valid_i) begin
            up_msg_ready_o <= 1'b1;
          end
        end
        SENDING: begin
          axis_req_up_o.tvalid  <= 1'b1;
          axis_req_up_o.t.data  <= payload_q;
          axis_req_up_o.t.last  <= 1'b1;
          axis_req_up_o.t.user  <= '0;
          axis_req_up_o.t.keep  <= '1;
          axis_req_up_o.t.strb  <= '1;
          axis_req_up_o.t.id    <= '0;
          axis_req_up_o.t.dest  <= '0;
        end
      endcase
    end
  end

endmodule
