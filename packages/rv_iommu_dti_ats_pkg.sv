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
      DTI_ATS_CONDIS_REQ  = 4'h0,
      DTI_ATS_TRANS_REQ   = 4'h2,
      DTI_ATS_INV_ACK     = 4'hC,
      DTI_ATS_INV_COMP    = 4'hB,
      DTI_ATS_SYNC_ACK    = 4'hD,
      DTI_ATS_PAGE_REQ    = 4'h8,
      DTI_ATS_PAGE_RESPACK = 4'h9
  } dti_ats_msg_type_down_e;

  typedef enum logic [3:0] {
      DTI_ATS_CONDIS_ACK  = 4'h0,
      DTI_ATS_TRANS_FAULT = 4'h1,
      DTI_ATS_TRANS_RESP  = 4'h2,
      DTI_ATS_INV_REQ     = 4'hC,
      DTI_ATS_SYNC_REQ    = 4'hD,
      DTI_ATS_PAGE_ACK    = 4'h8,
      DTI_ATS_PAGE_RESP    = 4'h9
  } dti_ats_msg_type_up_e;

  // --------------------------------------------------------------------------
  // Structs for Messages (with Correct Field Ordering)
  // --------------------------------------------------------------------------

  // Connection and Disconnection Messages
  typedef struct packed {
      logic [3:0] m_msg_type; //4 bits
      logic [3:0] state;    // 1-bit
      logic [1:0] reserved_2;
      logic sup_t;      // 1-bit
      tok_t tok_trans_req;     // 12 bits (11:8 and 7:0 combined)
      logic [119:0] reserved; //119 bits
  } dti_ats_condis_req_s;

  typedef struct packed {
      logic [3:0] s_msg_type;
      logic state;        // 1 bit
      logic [1:0] reserved_1;
      logic [2:0] oas;    // 3 bits
      tok_t tok_trans_gnt;     // 12 bits (11:8 and 7:0 combined)
      logic [7:0] version;    // 8-bits
      logic [120:0] reserved_2;
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
  } dti_ats_payload_s;

endpackage


/*
  // Union to encapsulate all ATS messages
  typedef union packed {
      dti_ats_condis_req_s    condis_req;
      dti_ats_condis_ack_s    condis_ack;
      dti_ats_trans_req_s    trans_req;
      dti_ats_trans_resp_s   trans_resp;
      dti_ats_trans_fault_s trans_fault;
      dti_ats_inv_req_s   inv_req;
      dti_ats_inv_ack_s   inv_ack;
      dti_ats_inv_comp_s  inv_comp;
      dti_ats_sync_req_s sync_req;
      dti_ats_sync_ack_s sync_ack;
      dti_ats_page_req_s page_req;
      dti_ats_page_ack_s page_ack;
      dti_ats_page_resp_s page_resp;
      dti_ats_page_respack_s page_respack;
      logic [159:0] raw; // fallback representation
  }dti_ats_msg_u;
*/

/*
  `define ASSIGN_MSG_PAYLOAD(payload, msg, msg_type) \
      case(msg_type) \
         DTI_ATS_CONDIS_REQ : payload.data = msg.condis_req; \
         DTI_ATS_TRANS_REQ : payload.data = msg.trans_req; \
         DTI_ATS_INV_ACK : payload.data = msg.inv_ack; \
         DTI_ATS_INV_COMP : payload.data = msg.inv_comp; \
         DTI_ATS_SYNC_ACK : payload.data = msg.sync_ack; \
         DTI_ATS_PAGE_REQ : payload.data = msg.page_req; \
         DTI_ATS_PAGE_RESPACK : payload.data = msg.page_respack; \
         DTI_ATS_CONDIS_ACK: payload.data =  msg.condis_ack; \
         DTI_ATS_TRANS_FAULT: payload.data =  msg.trans_fault; \
         DTI_ATS_TRANS_RESP: payload.data =  msg.trans_resp; \
         DTI_ATS_INV_REQ:  payload.data =  msg.inv_req; \
         DTI_ATS_SYNC_REQ: payload.data = msg.sync_req; \
         DTI_ATS_PAGE_ACK:  payload.data =  msg.page_ack; \
         DTI_ATS_PAGE_RESP:  payload.data = msg.page_resp; \
         default:  payload.data = 160'bx; \
      endcase

 `define ASSIGN_TO_PAYLOAD(msg, payload, msg_type) \
      msg = '{default:0}; \
      case(msg_type) \
         DTI_ATS_CONDIS_ACK: msg.condis_ack = payload.data; \
         DTI_ATS_TRANS_FAULT: msg.trans_fault = payload.data; \
         DTI_ATS_TRANS_RESP: msg.trans_resp= payload.data; \
         DTI_ATS_INV_REQ:  msg.inv_req = payload.data; \
         DTI_ATS_SYNC_REQ:  msg.sync_req= payload.data; \
         DTI_ATS_PAGE_ACK:  msg.page_ack= payload.data; \
         DTI_ATS_PAGE_RESP: msg.page_resp = payload.data; \
         default:  msg.raw = payload.data; \
      endcase
*/
