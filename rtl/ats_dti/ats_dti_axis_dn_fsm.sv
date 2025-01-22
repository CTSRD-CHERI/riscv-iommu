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

module dti_ats_axis_dn_fsm
  include dti_ats_pkg::*;
#(
  parameter DATA_WIDTH = 160,
  parameter typer axis_req_t = logic,
  parameter typer axis_rsp_t = logic
) (
  input  logic                 clk_i,
  input  logic                 rst_ni,

  // AXI4-Stream Slave Interface
  input  axis_req_t            axis_req_dn_i,
  output axis_rsp_t            axis_rsp_dn_o,

  // DTI-ATS Message Output
  output logic [DATA_WIDTH-1:0] dn_msg_o,
  output logic                  dn_msg_valid_o,
  input  logic                  dn_msg_ready_i
);

  // State Definition
  typedef enum logic {
    IDLE,
    RECEIVING
  } state_e;

  state_e current_state, next_state;

  // Internal Variables
  dti_ats_msg_type_up_e msg_type;

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
         if (axis_req_dn_i.tvalid && axis_rsp_dn_o.tready)
           next_state = RECEIVING;
         else
           next_state = IDLE;
      end
      RECEIVING: begin
         if(msg_complete && dn_msg_ready_i)
           next_state = IDLE;
         else
           next_state = RECEIVING;
      end
      default : next_state = IDLE;
    endcase
  end

  // Output and Payload Logic
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      axis_rsp_dn_o.tready <= 1'b0;
      dn_msg_valid_o       <= 1'b0;
      dn_msg_o             <= '0;
      dn_msg_type_o        <= '0;
      msg_complete         <= 1'b0;
    end else begin
      axis_rsp_dn_o.tready <= 1'b0;
      dn_msg_valid_o       <= 1'b0;
      dn_msg_o             <= '0;
      dn_msg_type_o        <= '0;
      msg_complete         <= 1'b0;
      case(current_state)
        IDLE: begin
          if(axis_req_dn_i.tvalid) begin
            axis_rsp_dn_o.tready <= 1'b1;
          end
        end
        RECEIVING: begin
          axis_rsp_dn_o.tready <= 1'b1;
          if (axis_req_dn_i.tlast) begin
             msg_complete <= 1'b1;
          end
          dn_msg_o <= axis_req_dn_i.tdata;
          dn_msg_valid_o <= 1'b1;
        end
      endcase
    end
  end

endmodule

/*
  input logic  [1:0]           tid_i,     TBD
  output logic [1:0]           tdest_i    not impl
  output logic [1:0]           twakeup_i  TBD

  input logic  [3:0]           tstrb_i,  don't care
  input logic  [3:0]           tkeep_i,  don't care
  output logic [7:0]           tuser_i,  don't care
*/

/*
 case(msg_type)
             DTI_ATS_CONDIS_ACK: begin
                dn_msg_o.condis_ack  <= axis_req_dn_i.tdata;
                dn_msg_valid_o       <= 1'b1;
                dn_msg_type_o        <= msg_type;
             end
             DTI_ATS_TRANS_FAULT: begin
                dn_msg_o.trans_fault <= axis_req_dn_i.tdata;
                dn_msg_valid_o       <= 1'b1;
                dn_msg_type_o        <= msg_type;
             DTI_ATS_TRANS_RESP: begin
                dn_msg_o.trans_resp  <= axis_req_dn_i.tdata;
                dn_msg_valid_o       <= 1'b1;
                dn_msg_type_o        <= msg_type;
             end
             DTI_ATS_INV_REQ: begin
                dn_msg_o.inv_req     <= axis_req_dn_i.tdata;
                dn_msg_valid_o       <= 1'b1;
                dn_msg_type_o        <= msg_type;
             end
             DTI_ATS_SYNC_REQ: begin
                dn_msg_o.sync_req    <= axis_req_dn_i.tdata;
                dn_msg_valid_o       <= 1'b1;
                dn_msg_type_o        <= msg_type;
             end
             DTI_ATS_PAGE_ACK: begin
                dn_msg_o.page_ack    <= axis_req_dn_i.tdata;
                dn_msg_valid_o       <= 1'b1;
                dn_msg_type_o        <= msg_type;
             end
             DTI_ATS_PAGE_RESP: begin
                dn_msg_o.page_resp   <= axis_req_dn_i.tdata;
                dn_msg_valid_o        <= 1'b1;
                dn_msg_type_o        <= msg_type;
             end
             default:  dn_msg_o <= '0;
          endcase
 */
