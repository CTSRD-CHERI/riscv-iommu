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

module dti_ats_axis_dn_fsm
  import rv_iommu_dti_ats_pkg::*;
#(
  parameter DATA_WIDTH = 160,
  parameter type axis_req_t = logic,
  parameter type axis_rsp_t = logic
) (
  input  logic         clk_i,
  input  logic         rst_ni,

  // AXI4-Stream Slave Interface
  input  axis_req_t    axis_req_dn_i,
  output axis_rsp_t    axis_rsp_dn_o,

  // DTI-ATS Message Output
  output dti_payload_s dn_msg_o,
  output logic         dn_msg_valid_o,
  input  logic         dn_msg_ready_i
);

  // State Definition
  typedef enum logic {
    IDLE,
    RECEIVING
  } state_e;

  state_e current_state, next_state;

  // Internal Variables
  dti_ats_msg_type_up_e msg_type;

  // State Transition Logic
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)
        current_state = IDLE;
    else
        current_state = next_state;
  end

  // Next State Logic
  always_comb begin
    next_state = current_state;
    case (current_state)
      IDLE: begin
         if (axis_req_dn_i.tvalid && axis_rsp_dn_o.tready)
           next_state = RECEIVING;
         else
           next_state = IDLE;
      end
      RECEIVING: begin
         if(dn_msg_valid_o && dn_msg_ready_i)
           next_state = IDLE;
         else
           next_state = RECEIVING;
      end
      default : next_state = IDLE;
    endcase
  end

  // Output and Payload Logic
  always_comb begin
    axis_rsp_dn_o.tready = 1'b0;
    dn_msg_valid_o       = 1'b0;
    case(current_state)
      IDLE: begin
        if(axis_req_dn_i.tvalid) begin
          axis_rsp_dn_o.tready = 1'b1;
        end
      end
      RECEIVING: begin
        dn_msg_valid_o = 1'b1;
      end
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : dn_condis_req
     if(~rst_ni)
       dn_msg_o = '0;
     else if (axis_req_dn_i.tvalid && axis_rsp_dn_o.tready)
       dn_msg_o = axis_req_dn_i.t.data;
  end

endmodule
