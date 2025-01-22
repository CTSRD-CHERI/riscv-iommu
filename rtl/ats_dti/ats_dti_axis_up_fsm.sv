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

module dti_ats_axis_up_fsm
  include dti_ats_pkg::*;
 #(
  parameter DATA_WIDTH = 160,
  parameter typer axis_req_t = logic,
  parameter typer axis_rsp_t = logic
) (
  input logic                   clk_i,
  input logic                   rst_ni,

  // AXI4-Stream Master Interface
  output axis_req_t             axis_req_up_o,
  input  axis_rsp_t             axis_rsp_up_i,

  // DTI-ATS Message Input
  input  logic [DATA_WIDTH-1:0] up_msg_i,
  input  logic                  up_msg_valid_i,
  output logic                  up_msg_ready_o
);

  // State Definition
  typedef enum logic {
   IDLE,
   SENDING
  } state_e;

  state_e current_state, next_state;

  // Internal Variables
  dti_ats_payload_s current_payload;
  logic msg_complete;

  // State Transition Logic
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)
      current_state <= IDLE;
    else
      current_state <= next_state;
  end

  // Next State Logic
  always_comb begin
    next_state = current_state;
    case (current_state)
      IDLE: begin
        if(up_msg_valid_i && up_msg_ready_o)
          next_state = SENDING;
        else
          next_state = IDLE;
      end
      SENDING: begin
        if(axis_rsp_up_i.tready && axis_req_up_o.tvalid)
          next_state = IDLE;
        else
          nest_state = SENDING;
      end
      default : next_state = IDLE;
    endcase
  end

  // Output and Payload Logic
  always_ff @(posedge clk_i) begin
    if(!rst_ni) begin
      axis_req_up_o.tvalid <= '0;
      axis_req_up_o.tdata <= '0;
      axis_req_up_o.tlast <= '0;
      axis_req_up_o.tuser <= '0;
      axis_req_up_o.tkeep <= '1;
      axis_req_up_o.tstrb <= '1;
      axis_req_up_o.tid    <= '0; // not implemented
      axis_req_up_o.tdest  <= '0; // TBD
      up_msg_ready_o       <= '0;
    end else begin
      axis_req_up_o.tvalid <= '0;
      axis_req_up_o.tdata  <= '0;
      axis_req_up_o.tlast  <= '0;
      axis_req_up_o.tuser  <= '0;
      axis_req_up_o.tkeep  <= '1;
      axis_req_up_o.tstrb  <= '1;
      axis_req_up_o.tid    <= '0;
      axis_req_up_o.tdest  <= '0;
      up_msg_ready_o       <= '0;
      case(current_state)
        IDLE: begin
          if(up_msg_valid_i) begin
            up_msg_ready_o <= 1'b1;
          end
        end
        SENDING: begin
          axis_req_up_o.tvalid <= 1'b1;
          axis_req_up_o.tdata  <= up_msg_i;
          axis_req_up_o.tlast  <= 1'b1;
          axis_req_up_o.tuser  <= '0;
          axis_req_up_o.tkeep  <= '1;
          axis_req_up_o.tstrb  <= '1;
          axis_req_up_o.tid    <= '0;
          axis_req_up_o.tdest  <= '0;
        end
      endcase
    end
  end

endmodule


/*
  output logic [1:0]            tid_o,     not impl
  output logic [1:0]            tdest_o    TBD
  output logic [1:0]            twakeup_o  TBD

  output logic [7:0]            tuser_o, '0
  output logic [3:0]            tstrb_o, '1
  output logic [3:0]            tkeep_o, '1
*/
