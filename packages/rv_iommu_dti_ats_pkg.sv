// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
//
// Author: Maicol Ciani <maicol.ciani@unibo.it>
//
// DTI ATS Package

package dti_ats_pkg;

  // --------------------------------------------------------------------------
  // Basic Data Types
  // --------------------------------------------------------------------------
  typedef logic [31:0]   addr_t;
  typedef logic [15:0]   id_t;
  typedef logic [11:0]   tok_t;
  typedef logic [7:0]    byte_t;

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

  // --------------------------------------------------------------------------
  // Structs for Messages (with Correct Field Ordering)
  // --------------------------------------------------------------------------

  // Connection and Disconnection Messages
  typedef struct packed {
     logic [127:0] unused;
     logic [3:0] tok_trans_req_msb;
     logic [1:0] reserved_1;
     logic       sup_t;
     logic       no_trans;
     logic [3:0] tok_inv_gnt;
     logic [7:0] tok_trans_req_lsb;
     logic [3:0] version;
     logic [1:0] reserved_0;
     logic       protocol;
     logic       state;
     logic [3:0] msg_type;
  } dti_ats_condis_req_s;

  typedef struct packed {
     logic [127:0] unused;
     logic [3:0] tok_trans_gnt_msb;
     logic [1:0] reserved_2;
     logic       sup_t;
     logic [3:0] reserved_1;
     logic       sup_pri;
     logic [7:0] tok_trans_gnt_lsb;
     logic [3:0] version;
     logic [2:0] reserved_0;
     logic       state;
     logic [3:0] msg_type;
  } dti_ats_condis_ack_s;

  //Translation Request Messages
  typedef struct packed {
      logic [3:0] m_msg_type;   // 4-bits (3:0)
      logic [3:0] qos;        // 4-bits (7:4)
      logic protocol;          // 1-bit (16)
      logic pnu;             // 1-bit (17)
      logic ident;        // 1-bit (27)
      logic ns;           // 1-bit (24)
      logic nse;            // 1-bit (25)
      logic [1:0] sec_sid;   // 2-bits (27,26 combined)
      logic [1:0] perm;     // 2-bits (23:22)
      logic [11:0] translation_id;     // 12-bits (31:20 combined)
      logic flow;   // 1-bit (71)
      logic [3:0] reserved_1;    // 4-bits (75:72)
      logic [19:0] ssid; // 20-bits (95:76)
      addr_t ia;    // 64-bits (159:96)
      logic [1:0] reserved_2; // 2-bit
       logic [108:0] reserved_3; // 108 bits of reserved padding
  } dti_ats_trans_req_s;

  typedef struct packed {
      logic [1:0] m_msg_type; // 2-bits
      logic [2:0] cont; // 3-bits
      logic [2:0] vm_id;   // 3-bits
      logic [6:0] attr;   // 7-bits
      logic [3:0] hw_attr; // 4-bits of hw attr
      logic [11:0] translation_id;   // 12-bits
      logic bypass;  //1-bit
      logic [1:0] sh;     // 2-bit shareability
      logic [10:0] partid;    // 10-bit PartId
      addr_t oa;   // 64-bit output address
      logic [103:0] reserved;   // 103 bits of padding.
  } dti_ats_trans_resp_s;

  typedef struct packed {
      logic [3:0]  m_msg_type; // 4-bit  message type
      logic[31:0] fault_type; //4-bit
      logic [11:0]  translation_id; // 12 bits
      logic[111:0] reserved; // 111 bits of reserved padding
  }dti_ats_trans_fault_s;

  // Invalidation and Synchronization Messages
  typedef struct packed {
      logic[3:0] s_msg_type; // 4 bit
      logic itag; //1-bit
      logic t;     //1-bit
      logic[7:0] operation;   //8 bit
      logic [19:0] ssid;   // 20-bit
      logic [31:0] sid;      // 32-bit
      logic[4:0] range;     // 5-bit
      addr_t va;      // 64-bit
      logic [23:0] reserved; // 23 bits of reserved padding
  } dti_ats_inv_req_s;

  typedef struct packed {
       logic [3:0] s_msg_type; // 4 bit
       logic [7:0] reserved;  //8 bits
       logic[147:0] reserved_1; // 147-bit padding.
  } dti_ats_inv_ack_s;


  typedef struct packed {
      logic [3:0] s_msg_type;  // 4 bits
      logic error;    // 1-bit
      logic itag;  // 1-bit
      logic [31:0] sid;    // 32-bits
      logic [7:0] reserved_1; //  8 bits
      logic [112:0] reserved_2;   // 112-bit padding
  } dti_ats_inv_comp_s;

  typedef struct packed {
      logic [3:0] s_msg_type;   //4 bit
      logic [7:0] reserved;  // 8 bits
      logic[148:0] reserved_1;  //148 bit padding.
  } dti_ats_sync_req_s;

  typedef struct packed {
      logic [3:0] s_msg_type;    // 4 bit
      logic error;      // 1-bit
      logic [7:0] reserved;  // 8 bits
      logic [146:0] reserved_1;   //146 bit padding
  } dti_ats_sync_ack_s;


  //Page Request Messages
  typedef struct packed {
      logic [3:0] m_msg_type; // 4 bit
      logic read;  // 1-bit (8)
      logic write;  // 1-bit (9)
      logic last; // 1-bit (10)
      logic ssv;  // 1-bit (3)
      logic protocol; // 1-bit (4)
      logic t;    // 1-bit (5)
      logic priv; // 1-bit (6)
      logic inst;  // 1-bit (7)
      logic [19:0] ssid; // 20-bits
      logic [31:0] sid;   // 32 bit
      logic [7:0] prg_index;   // 8-bit (72:64)
      addr_t addr;         // 64-bits (127:76)
      logic [31:0] reserved; // 31 bits of reserved padding
  } dti_ats_page_req_s;

  typedef struct packed {
      logic [3:0] s_msg_type;  // 4 bits
      logic [7:0] reserved;  //8 bits
      logic [148:0] reserved_1; // 148-bit padding.
  } dti_ats_page_ack_s;

  typedef struct packed {
      logic [3:0] s_msg_type;   // 4-bits
      logic t;    //1-bits
      logic  [1:0] resp; // 2 bits
      logic [7:0] reserved;  // 8 bits
      logic [7:0] prg_index;     // 8-bits (72:64)
      logic [19:0] ssid;  // 20-bits
      logic [31:0] sid;      // 32-bits
      addr_t addr;   // 64-bit
      logic [66:0] reserved_1;    // 66-bit padding.
  } dti_ats_page_resp_s;

  typedef struct packed {
      logic [3:0] s_msg_type;    // 4-bits
      logic [7:0] reserved;    // 8-bits
      logic [148:0] reserved_1;  // 148 bits of padding
  } dti_ats_page_respack_s;

  // --------------------------------------------------------------------------
  // Top-Level Payload Structure
  // --------------------------------------------------------------------------

  typedef struct packed {
      logic[159:0] data;
  } dti_payload_s;

endpackage
