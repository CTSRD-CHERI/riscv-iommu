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

module dti_ats_top
  import rv_iommu_dti_ats_pkg::*;
#(
  parameter DATA_WIDTH = 160,
  parameter MAX_INV_TOKENS = 16,
  parameter MAX_TRANS_TOKENS = 64,
  parameter FREQUENCY = 10,
  parameter type axis_req_t = logic,
  parameter type axis_rsp_t = logic,
  parameter type trans_req_data_t = logic,
  parameter type trans_resp_data_t = logic
) (
  input  logic      clk_i,
  input  logic      rst_ni,

  // AXI4-Stream Slave Interface DTI_ATS -> PCIe
  input  axis_req_t axis_req_dn_i,
  output axis_rsp_t axis_rsp_dn_o,

  // AXI4-Stream Master Interface PCIe -> DTI_ATS
  output axis_req_t axis_req_up_o,
  input  axis_rsp_t axis_rsp_up_i,

  // Incoming Invalidation Request (from CQ)
  input  rv_iommu_cq_inv_req_s iommu_to_dti_inv_req_i,
  input  logic                 iommu_to_dti_inv_valid_i,
  output logic                 iommu_to_dti_inv_ready_o,

  // Translation request towards IOMMU's trans logic
  output trans_req_data_t  dti_to_iommu_trans_req_o,
  output logic             dti_to_iommu_trans_valid_o,
  input  logic             dti_to_iommu_trans_ready_i,


  // Translation response from IOMMU
  input  trans_resp_data_t iommu_to_dti_trans_resp_i,
  input  logic             iommu_to_dti_trans_valid_i,
  output logic             iommu_to_dti_trans_ready_o,

  // Timeout and inflight invalidations
  output logic             inv_to_o,
  output logic             inv_inflight_o
);

  /////////////////////////////
  //// Parameters and Defs ////
  /////////////////////////////

   localparam int NUM_CMD = 3;

   typedef enum logic [1:0] {
     CONDIS,
     INV,
     TRANS
   } commands_t;

   dti_payload_s dn_msg, up_msg,
                 up_msg_condis,
                 up_msg_inv,
                 up_msg_trans;

   logic up_msg_valid, up_msg_ready;

   dti_payload_s [NUM_CMD-1:0] up_msg_arb;
   logic [NUM_CMD-1:0] up_msg_valid_arb, up_msg_ready_arb;

   logic up_msg_condis_ready, up_msg_condis_valid;
   logic up_msg_inv_ready, up_msg_inv_valid;

   logic up_msg_trans_ready, up_msg_trans_valid;

   logic dn_msg_valid, dn_msg_ready;
   logic dn_msg_condis_ready, dn_msg_inv_ready;

   logic dn_msg_trans_ready;

   condis_cmd_state_e link_status;

   logic [3:0]  granted_inv_tok;
   logic [11:0] granted_trans_tok;

   logic [31:0] frequency = FREQUENCY;

   logic        t_bit;

   assign dn_msg_ready = dn_msg_condis_ready ||
                         dn_msg_inv_ready    ||
                         dn_msg_trans_ready;

   assign up_msg_arb[CONDIS]       = up_msg_condis;
   assign up_msg_arb[INV]          = up_msg_inv;
   assign up_msg_arb[TRANS]        = up_msg_trans;

   assign up_msg_valid_arb[CONDIS] = up_msg_condis_valid;
   assign up_msg_valid_arb[INV]    = up_msg_inv_valid;
   assign up_msg_valid_arb[TRANS]  = up_msg_trans_valid;

   assign up_msg_condis_ready      = up_msg_ready_arb[CONDIS];
   assign up_msg_inv_ready         = up_msg_ready_arb[INV];
   assign up_msg_trans_ready       = up_msg_ready_arb[TRANS];

   /////////////////////////
   //// Transport layer ////
   /////////////////////////

   // ---------------------------------------------------------------
   // Downstream AXIS Receiver
   // ---------------------------------------------------------------
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

   // ---------------------------------------------------------------
   // Upstream AXIS Driver
   // ---------------------------------------------------------------
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

   // ---------------------------------------------------------------
   // Arbiter to mux the the AXIS upstream interface
   // ---------------------------------------------------------------
   stream_arbiter #(
      .DATA_T  ( dti_payload_s ),
      .N_INP   ( NUM_CMD       ),
      .ARBITER ( "rr"          )
   ) i_inv_sync_req_arb (
      .clk_i       ( clk_i            ),
      .rst_ni      ( rst_ni           ),

      .inp_data_i  ( up_msg_arb       ),
      .inp_valid_i ( up_msg_valid_arb ),
      .inp_ready_o ( up_msg_ready_arb ),

      .oup_data_o  ( up_msg           ),
      .oup_valid_o ( up_msg_valid     ),
      .oup_ready_i ( up_msg_ready     )
   );

   ////////////////////////////////
   //// Finite State Machines  ////
   ////////////////////////////////

   // ---------------------------------------------------------------
   // Con/Discon Message Handler
   // ---------------------------------------------------------------
   ats_dti_condis_cmd_fsm #(
     .MAX_TOKENS     ( MAX_TRANS_TOKENS )
   ) i_condis_fsm (
     .clk_i          ( clk_i  ),
     .rst_ni         ( rst_ni ),
     // Upstream traffic
     .up_msg_o       ( up_msg_condis       ),
     .up_msg_valid_o ( up_msg_condis_valid ),
     .up_msg_ready_i ( up_msg_condis_ready ),
     // Downstram traffic
     .dn_msg_i       ( dn_msg              ),
     .dn_msg_valid_i ( dn_msg_valid        ),
     .dn_msg_ready_o ( dn_msg_condis_ready ),
     .link_status_o  ( link_status         ),
     // Tokens
     .granted_inv_tok_o   ( granted_inv_tok   ),
     .granted_trans_tok_o ( granted_trans_tok ),
     // T bit
     .t_bit_o             ( t_bit )
   );

   // ---------------------------------------------------------------
   // Invalidation Message Handler
   // ---------------------------------------------------------------
   ats_dti_inv_sync_cmd_fsm #(
     .MAX_TOKENS     ( MAX_INV_TOKENS       )
   ) i_inv_sync_fsm (
     .clk_i          ( clk_i            ),
     .rst_ni         ( rst_ni           ),
     .freq_i         ( frequency        ),
     // IOMMU IFENCE command
     .fence_i        ( 1'b0             ), //TBD
     .fence_comp_o   (                  ), //TBD
     // Upstream traffic
     .up_msg_o       ( up_msg_inv       ),
     .up_msg_valid_o ( up_msg_inv_valid ),
     .up_msg_ready_i ( up_msg_inv_ready ),
     // Upstream traffic
     .dn_msg_i       ( dn_msg           ),
     .dn_msg_valid_i ( dn_msg_valid     ),
     .dn_msg_ready_o ( dn_msg_inv_ready ),
     // Upstream traffic
     .iommu_to_dti_inv_req_i   ( iommu_to_dti_inv_req_i   ),
     .iommu_to_dti_inv_valid_i ( iommu_to_dti_inv_valid_i ),
     .iommu_to_dti_inv_ready_o ( iommu_to_dti_inv_ready_o ),

     .dti_to_iommu_inv_inflight_o ( inv_inflight_o        ),

     // Timeout and status signals
     .granted_inv_tok_i        ( granted_inv_tok ),
     .timeout_o                ( inv_to_o        ),
     .t_bit_i                  ( t_bit           ),
     .link_status_i            ( link_status     )
   );

   // ---------------------------------------------------------------
   // Translation Message Handler
   // ---------------------------------------------------------------
   ats_dti_trans_cmd_fsm #(
     .MAX_TOKENS     ( MAX_TRANS_TOKENS ),
     .trans_req_data_t  ( trans_req_data_t  ),
     .trans_resp_data_t ( trans_resp_data_t )
   ) i_trans_fsm (
     .clk_i          ( clk_i            ),
     .rst_ni         ( rst_ni           ),
     // Upstream traffic
     .up_msg_o       ( up_msg_trans       ),
     .up_msg_valid_o ( up_msg_trans_valid ),
     .up_msg_ready_i ( up_msg_trans_ready ),
     // Upstream traffic
     .dn_msg_i       ( dn_msg             ),
     .dn_msg_valid_i ( dn_msg_valid       ),
     .dn_msg_ready_o ( dn_msg_trans_ready ),
     // Translation request towards IOMMU
     .dti_to_iommu_trans_req_o   ( dti_to_iommu_trans_req_o   ),
     .dti_to_iommu_trans_valid_o ( dti_to_iommu_trans_valid_o ),
     .dti_to_iommu_trans_ready_i ( dti_to_iommu_trans_ready_i ),
     // Translation response from IOMMU
     .iommu_to_dti_trans_resp_i  ( iommu_to_dti_trans_resp_i  ),
     .iommu_to_dti_trans_valid_i ( iommu_to_dti_trans_valid_i ),
     .iommu_to_dti_trans_ready_o ( iommu_to_dti_trans_ready_o ),
     // Timeout and status signals
     .gnt_trans_tok_i ( granted_trans_tok          ),
     .t_bit_i         ( t_bit                      ),
     .link_status_i   ( link_status                )
   );

   // ---------------------------------------------------------------
   // Page Request Message Handler: TODO
   // ---------------------------------------------------------------

 endmodule
