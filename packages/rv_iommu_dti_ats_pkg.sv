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
// Description: this pkg defines the msg structures as from DTI-ATSv4 specification.
//

package rv_iommu_dti_ats_pkg;

  import rv_iommu::*;

  // --------------------------------------------------------------------------
  // Top-Level Payload Structure
  // --------------------------------------------------------------------------

  parameter int PAYLOAD_SIZE = 160;
  typedef logic [63:0] addr_t;
  typedef logic [55:0] paddr_t;

  typedef struct packed {
     logic [PAYLOAD_SIZE-1:0] data;
  } dti_payload_s;

  // -----------------------------------------------
  // Define Translation Scoreboard Structure
  // -----------------------------------------------

  typedef struct packed {
    logic [11:0]  trans_id;
    logic [31:0]  sid;
    logic         t;
  } dti_ats_sb_req_s;

  // --------------------------------------------------------------------------
  // Enums
  // --------------------------------------------------------------------------

  typedef enum logic [3:0] {
      DTI_ATS_CONDIS_REQ   = 4'h0,
      DTI_ATS_TRANS_REQ    = 4'h2,
      DTI_ATS_INV_ACK      = 4'hC,
      DTI_ATS_INV_COMP     = 4'hB,
      DTI_ATS_SYNC_ACK     = 4'hD,
      DTI_ATS_PAGE_REQ     = 4'h8,
      DTI_ATS_PAGE_RESPACK = 4'h9
  } dti_ats_msg_type_down_e;

  typedef enum logic [3:0] {
      DTI_ATS_CONDIS_ACK  = 4'h0,
      DTI_ATS_TRANS_FAULT = 4'h1,
      DTI_ATS_TRANS_RESP  = 4'h2,
      DTI_ATS_INV_REQ     = 4'hC,
      DTI_ATS_SYNC_REQ    = 4'hD,
      DTI_ATS_PAGE_ACK    = 4'h8,
      DTI_ATS_PAGE_RESP   = 4'h9
  } dti_ats_msg_type_up_e;

  typedef enum logic [7:0] {
      ATCI_NOPASID      = 8'h31,
      ATCI_PASID_GLOBAL = 8'h33,
      ATCI_PASID        = 8'h39
  } dti_ats_inv_op_t;

  typedef enum logic [1:0] {
     DISCONNECTED,
     REQ_CONNECTED,
     CONNECTED,
     REQ_DISCONNECTED
  } condis_cmd_state_e;

  // --------------------------------------------------------------------------
  // Structs for Messages
  // --------------------------------------------------------------------------

  //////////////////////////
  //// Con/Dis commands ////
  //////////////////////////

  typedef struct packed {
     logic [127:0] unused;
     logic [3:0]   tok_trans_req_msb;
     logic [1:0]   reserved_1;
     logic         sup_t;
     logic         no_trans;
     logic [3:0]   tok_inv_gnt;
     logic [7:0]   tok_trans_req_lsb;
     logic [3:0]   version;
     logic [1:0]   reserved_0;
     logic         protocol;
     logic         state;
     logic [3:0]   msg_type;
  } dti_ats_condis_req_s;

  typedef struct packed {
     logic [127:0] unused;
     logic [3:0]   tok_trans_gnt_msb;
     logic [1:0]   reserved_2;
     logic         sup_t;
     logic [3:0]   reserved_1;
     logic         sup_pri;
     logic [7:0]   tok_trans_gnt_lsb;
     logic [3:0]   version;
     logic [2:0]   reserved_0;
     logic         state;
     logic [3:0]   msg_type;
  } dti_ats_condis_ack_s;

  ////////////////////////////
  //// Inv/Synch Commands ////
  ////////////////////////////

  typedef struct packed {
     logic [31:0] unused;
     logic [51:0] untrans_addr;
     logic        s;
     logic [9:0]  reserved_2;
     logic        g;
     logic [7:0]  dseg;
     logic [15:0] rid;
     logic [5:0]  reserved_1;
     logic        dsv;
     logic        pv;
     logic [19:0] pid;
     logic [1:0]  reserved_0;
     logic [2:0]  func3;
     logic [6:0]  opcode;
  } rv_iommu_cq_inv_req_s;

  typedef struct packed {
     logic [31:0] unused;
     logic [51:0] va;
     logic [4:0]  itag;
     logic        t;
     logic [5:0]  range;
     logic [31:0] sid;
     logic [19:0] ssid;
     logic [7:0]  operation;
     logic [3:0]  msg_type;
  } dti_ats_inv_req_s;

  typedef struct packed {
     logic [151:0] unused;
     logic [3:0]   reserved;
     logic [3:0]   s_msg_type;
  } dti_ats_inv_ack_s;

  typedef struct packed {
     logic [31:0] unused;
     logic [19:0] reserved_2;
     logic [4:0]  itag;
     logic        t;
     logic [5:0]  reserved_1;
     logic [31:0] sid;
     logic [26:0] reserved_0;
     logic        error;
     logic [3:0]  s_msg_type;
  } dti_ats_inv_comp_s;

  typedef struct packed {
     logic [151:0] unused;
     logic [3:0]   reserved;
     logic [3:0]   s_msg_type;
  } dti_ats_sync_req_s;

  typedef struct packed {
     logic [151:0] unused;
     logic [2:0]   reserved;
     logic         error;
     logic [3:0]   s_msg_type;
  } dti_ats_sync_ack_s;

  //////////////////////////////
  //// Translation Commands ////
  //////////////////////////////

  typedef struct packed {
     logic [51:0] IA;
     logic [11:0] reserved_2;
     logic [19:0] ssid;
     logic [11:0] reserved_1;
     logic [31:0] sid;
     logic [3:0]  trans_id_msb;
     logic [4:0]  reserved_0;
     logic        CXL;
     logic        ssv;
     logic        t;
     logic        nW;
     logic        InD;
     logic        PnU;
     logic        protocol;
     logic [7:0]  trans_id_lsb;
     logic [3:0]  QoS;
     logic [3:0]  s_msg_type;
  } dti_ats_trans_req_s;

  typedef struct packed {
     logic [51:0] OA;
     logic [12:0] reserved_5;
     logic [2:0]  AMA;
     logic [7:0]  reserved_4;
     logic [3:0]  trans_rng;
     logic [3:0]  trans_id_msb;
     logic [4:0]  reserved_3;
     logic        te;
     logic [2:0]  reserved_2;
     logic        allow_x;
     logic        allow_w;
     logic        allow_r;
     logic [45:0] reserved_1;
     logic        bypass;
     logic [2:0]  reserved_0;
     logic        CLX_IO;
     logic        untrans;
     logic [7:0]  trans_id_lsb;
     logic [3:0]  s_msg_type;
  } dti_ats_trans_resp_s;

  typedef struct packed {
     logic [127:0] unused;
     logic [3:0] trans_id_msb;
     logic [8:0] reserved_2;
     logic [1:0] fault_type;
     logic [4:0] reserved_0;
     logic [7:0] trans_id_lsb;
     logic [3:0] s_msg_type;
  } dti_ats_trans_fault_s;

  ///////////////////////////////
  //// Page Request Commands ////
  ///////////////////////////////

  /*
  //Page Request Messages
  typedef struct packed {
  } dti_ats_page_req_s;

  typedef struct packed {
  } dti_ats_page_ack_s;

  typedef struct packed {
  } dti_ats_page_resp_s;

  typedef struct packed {
  } dti_ats_page_respack_s;
  */

endpackage
