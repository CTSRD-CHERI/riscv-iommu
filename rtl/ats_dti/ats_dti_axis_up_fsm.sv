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
  parameter DATA_WIDTH       = 160,
  parameter type axis_req_t  = logic,
  parameter type axis_rsp_t  = logic
) (
  input  logic          clk_i,
  input  logic          rst_ni,

  // AXI4-Stream Master Interface
  output axis_req_t     axis_req_up_o,
  input  axis_rsp_t     axis_rsp_up_i,

  // DTI-ATS Message Input
  input  dti_payload_s  up_msg_i,
  input  logic          up_msg_valid_i,
  output logic          up_msg_ready_o
);

  // ----------------------------------------------------
  // 1) Internal Register/Pipeline
  //    - 'stored_data' holds the message from up_msg_i
  //    - 'stored_valid' indicates we currently have valid data to send
  // ----------------------------------------------------
  dti_payload_s stored_data;
  logic         stored_valid;

  // ----------------------------------------------------
  // 2) State Machine Definition
  // ----------------------------------------------------
  typedef enum logic [1:0] {
    IDLE,
    SENDING
  } state_e;

  state_e current_state, next_state;

  // ----------------------------------------------------
  // 3) Synchronous (Sequential) Logic
  // ----------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      current_state <= IDLE;
      stored_valid  <= 1'b0;
      stored_data   <= '0;
    end else begin
      current_state <= next_state;

      case (current_state)

        IDLE: begin
          // If we do not already hold data and the upstream handshake occurs,
          // latch in the new message.
          if (!stored_valid && up_msg_ready_o && up_msg_valid_i) begin
            stored_data  <= up_msg_i;
            stored_valid <= 1'b1;
          end
        end

        SENDING: begin
          // Once AXI handshake completes, clear 'stored_valid'
          if (axis_req_up_o.tvalid && axis_rsp_up_i.tready) begin
            stored_valid <= 1'b0;
          end
        end

      endcase
    end
  end

  // ----------------------------------------------------
  // 4) Combinational Next-State Logic and Output Control
  // ----------------------------------------------------
  always_comb begin
    // Default assignments
    next_state              = current_state;
    up_msg_ready_o          = 1'b0;

    // Drive AXI request output from the stored register
    axis_req_up_o.tvalid    = stored_valid;
    axis_req_up_o.t.data    = stored_data;
    axis_req_up_o.t.last    = 1'b1;
    axis_req_up_o.t.user    = '0;
    axis_req_up_o.t.keep    = '1;
    axis_req_up_o.t.strb    = '1;
    axis_req_up_o.t.id      = '0;
    axis_req_up_o.t.dest    = '0;

    case (current_state)

      // ------------------------------------------------
      // IDLE State
      // ------------------------------------------------
      IDLE: begin
        // If we have no stored data, we can accept a new message
        if (!stored_valid) begin
          up_msg_ready_o = 1'b1;  // Tell upstream we can take data
          // If upstream actually gives us valid data, next cycle we'll have it stored
          if (up_msg_valid_i) begin
            next_state = SENDING;
          end
        end
      end

      // ------------------------------------------------
      // SENDING State
      // ------------------------------------------------
      SENDING: begin
        // Keep driving tvalid=1 until handshake with downstream
        axis_req_up_o.tvalid = stored_valid;
        // On successful handshake => go back to IDLE
        if (axis_req_up_o.tvalid && axis_rsp_up_i.tready) begin
          next_state = IDLE;
        end
      end

      default: begin
        next_state = IDLE;
      end

    endcase
  end

endmodule
