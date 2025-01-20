// Copyright © 2025 Manuel Rodríguez & Zero-Day Labs, Lda.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// Licensed under the Solderpad Hardware License v 2.1 (the “License”); 
// you may not use this file except in compliance with the License, 
// or, at your option, the Apache License version 2.0. 
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/.
// Unless required by applicable law or agreed to in writing, 
// any work distributed under the License is distributed on an “AS IS” BASIS, 
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. 
// See the License for the specific language governing permissions and limitations under the License.
//
// Author:  Manuel Rodríguez <manuel.cederog@gmail.com>
// Date:    20/01/2025
//
// Description: RISC-V IOMMU SV package.
//

`ifndef RV_IOMMU_PKG
`define RV_IOMMU_PKG

package rv_iommu;

    // ----------------
    //# Address Length
    // ----------------

    localparam VLEN39   = 39;
    localparam GPLEN39  = 41;

    localparam VPNW39   = 27;
    localparam GPPNW39  = 29;

    localparam int unsigned DevIdWidth = 24;
    localparam int unsigned ProcIdWidth = 20;

    typedef logic [43:0]            ppn_t;
    typedef logic [DevIdWidth-1:0]  device_id_t;
    typedef logic [ProcIdWidth-1:0] process_id_t;
    typedef logic [15:0]            gscid_t;
    typedef logic [19:0]            pscid_t;

    //------------------------------
    // RISC-V Virtual Memory Schemes
    //------------------------------
    typedef enum logic [3:0] {
        ModeBare = 0,
        ModeSv32 = 1,
        ModeSv39 = 8,
        ModeSv48 = 9,
        ModeSv57 = 10
    } vm_mode_t;

    // -----------
    // PTE Struct
    // -----------
    typedef struct packed {
        logic [9:0]  reserved;
        logic [44-1:0] ppn; // PPN length for
        logic [1:0]  rsw;
        logic d;
        logic a;
        logic g;
        logic u;
        logic x;
        logic w;
        logic r;
        logic v;
    } pte_t;

    //-------------------------------
    // Device/Process Context Fields
    //-------------------------------

    // MSI Address Pattern
    typedef struct packed {
        logic [11:0]        reserved;
        logic [(52-1):0]    pattern;
    } msi_addr_pattern_t;

    // MSI Address Mask
    typedef struct packed {
        logic [11:0]        reserved;
        logic [(52-1):0]    mask;
    } msi_addr_mask_t;

    // MSI Page Table Pointer
    typedef struct packed {
        logic [3:0]     mode;
        logic [15:0]    reserved;
        ppn_t           ppn;
    } msiptp_t;

    // First Stage Context
    typedef struct packed {
        logic [3:0]     mode;
        logic [15:0]    reserved;
        ppn_t           ppn;
    } fsc_t;

    // Translation Attributes for Device Context
    typedef struct packed {
        logic [31:0] reserved_2;
        pscid_t      pscid;
        logic [11:0] reserved_1;
    } dc_ta_t;

    // Translation Attributes for Process Context
    typedef struct packed {
        logic [31:0]    reserved_2;
        pscid_t         pscid;
        logic [8:0]     reserved_1;
        logic           sum;
        logic           ens;
        logic           v;
    } pc_ta_t;

    // IO Hypervisor Guest Address Translation and Protection
    typedef struct packed {
        logic [3:0]     mode;
        logic [15:0]    gscid;
        ppn_t           ppn;
    } iohgatp_t;

    // Translation Control
   typedef struct packed {
        logic [31:0]    reserved_2;
        logic [7:0]     custom;
        logic [11:0]    reserved_1;
        logic           sxl;
        logic           sbe;
        logic           dpe;
        logic           sade;
        logic           gade;
        logic           prpr;
        logic           pdtv;
        logic           dtf;
        logic           t2gpa;
        logic           en_pri;
        logic           en_ats;
        logic           v;
   } tc_t;

   // Non-leaf DDT/PDT entry (64-bits)
    typedef struct packed {
        logic [9:0] reserved_2;
        ppn_t       ppn;
        logic [8:0] reserved_1;
        logic       v;
    } nl_entry_t;

    //------------------------
    // Device Context Structs
    //------------------------

    // Base format Device Context
    typedef struct packed {
        fsc_t       fsc;
        dc_ta_t     ta;
        iohgatp_t   iohgatp;
        tc_t        tc;
    } dc_base_t;
    
    // Extended format Device Context
    typedef struct packed {
        logic [63:0]        reserved;
        msi_addr_pattern_t  msi_addr_pattern;
        msi_addr_mask_t     msi_addr_mask;
        msiptp_t            msiptp;
        fsc_t               fsc;
        dc_ta_t             ta;
        iohgatp_t           iohgatp;
        tc_t                tc;
    } dc_ext_t;

    //------------------------
    // Process Context Struct
    //------------------------

    // Process Context
    typedef struct packed {
        fsc_t   fsc;
        pc_ta_t ta;
    } pc_t;

    //-------------------------
    // MSI Address Translation
    //-------------------------

    typedef enum logic [1:0] {
        RSV_1           = 2'b00,
        MRIF            = 2'b01,
        RSV_2           = 2'b10,
        BT              = 2'b11
    } msi_pte_mode_e;

    // MSI PTE (Basic-Translate mode)
    typedef struct packed {
        logic           c;
        logic [8:0]     __rsv_2;
        logic [44-1:0]  ppn;
        logic [6:0]     __rsv_1;
        msi_pte_mode_e  m;
        logic           v;
    } msi_pte_bt_t;

    // MSI PTE (MRIF mode)
    typedef struct packed {
        logic [2:0]     __rsv_2;
        logic           nid_10;
        logic [5:0]     __rsv_1;
        logic [44-1:0]  nppn;
        logic [9:0]     nid_9_0;
    } msi_pte_notice_t;

    typedef struct packed {
        logic           c;
        logic [8:0]     __rsv_2;
        logic [47-1:0]  addr;
        logic [3:0]     __rsv_1;
        msi_pte_mode_e  m;
        logic           v;
    } msi_pte_mrif_t;

    //---------------------
    // Cache/IOTLB Structs
    //---------------------

    // DDTC update
    typedef struct packed {
        logic       update;
        device_id_t did;
        dc_base_t   dc;
    } ddtc_up_base_t;
    typedef struct packed {
        logic       update;
        device_id_t did;
        dc_ext_t    dc;
    } ddtc_up_ext_t;

    // PDTC update
    typedef struct packed {
        logic           update;
        device_id_t     did;
        process_id_t    pid;
        pc_t            pc;
    } pdtc_up_t;

    // DDTC/PDTC invalidation
    typedef struct packed {
        logic           inval_ddtc;
        logic           inval_pdtc;
        logic           dv;
        device_id_t     did;
        process_id_t    pid;
    } xdtc_inval_t;

    // IOTLB content
    typedef struct packed {
        logic   is_1G;
        logic   is_2M;
        ppn_t   ppn;
        logic   g;
        logic   u;
        logic   x;
        logic   w;
        logic   r;
        logic   v;
    } iotlb_stage_content_t;
    typedef struct packed {
        iotlb_stage_content_t content_1S;
        iotlb_stage_content_t content_2S;
    } iotlb_content_t;

    // IOTLB update
    typedef struct packed {
        logic               update;
        logic [GPPNW39-1:0] vpn;
        pscid_t             pscid;
        gscid_t             gscid;
        iotlb_content_t     content;
    } iotlb_up_t;

    // IOTLB invalidation
    typedef struct packed {
        logic               inval_vma;
        logic               inval_gvma;
        logic               av;
        logic               gv;
        logic               pscv;
        logic [GPPNW39-1:0] vpn;
        gscid_t             gscid;
        pscid_t             pscid;
    } iotlb_inval_t;

    // MRIFC content
    typedef struct packed {
        logic [11-1:0]  nid;
        logic [44-1:0]  nppn;
        logic [47-1:0]  addr;
    } mrifc_content_t;

    // MRIFC update
    typedef struct packed {
        logic                   update;
        logic [(GPPNW39-1):0]   vpn;
        pscid_t                 pscid;
        gscid_t                 gscid;
        iotlb_stage_content_t   content_1S;
        mrifc_content_t         msi_content;
    } mrifc_up_t;

    //---------------------
    // IOMMU Command Queue
    //---------------------
    // Opcodes
    localparam logic [6:0] IOTINVAL  = 7'd1;
    localparam logic [6:0] IOFENCE   = 7'd2;
    localparam logic [6:0] IODIR     = 7'd3;
    localparam logic [6:0] ATS       = 7'd4;

    // Func3
    localparam logic [2:0] VMA       = 3'b000;
    localparam logic [2:0] GVMA      = 3'b001;

    localparam logic [2:0] IOFENCE_C = 3'b000;

    localparam logic [2:0] DDT       = 3'b000;
    localparam logic [2:0] PDT       = 3'b001;

    // Generic CQ entry
    typedef struct packed {
        logic [117:0]   operands;
        logic [2:0]     func3;
        logic [6:0]     opcode;
    } cq_entry_t;

    // IOTINVAL
    typedef struct packed {
        logic [1:0]     reserved_4;
        logic [51:0]    addr;
        logic [13:0]    reserved_3;
        gscid_t         gscid;
        logic [9:0]     reserved_2;
        logic           gv;
        logic           pscv;
        pscid_t         pscid;
        logic           reserved_1;
        logic           av;
        logic [2:0]     func3;
        logic [6:0]     opcode;
    } cq_iotinval_t;

    // IOFENCE
    typedef struct packed {
        logic [1:0]     reserved_2;
        logic [61:0]    addr;
        logic [31:0]    data;
        logic [17:0]    reserved_1;
        logic           pw;
        logic           pr;
        logic           wsi;
        logic           av;
        logic [2:0]     func3;
        logic [6:0]     opcode;
    } cq_iofence_t;

    // IODIR
    typedef struct packed {
        logic [63:0]    reserved_4;
        device_id_t     did;
        logic [5:0]     reserved_3;
        logic           dv;
        logic           reserved_2;
        process_id_t    pid;
        logic [1:0]     reserved_1;
        logic [2:0]     func3;
        logic [6:0]     opcode;
    } cq_iodir_t;

    //----------------------
    // Fault CAUSE Encoding
    //----------------------
    typedef logic [11:0] cause_t;

    // Privilege Spec Causes
    localparam cause_t INSTR_ACCESS_FAULT     = 1;
    localparam cause_t LD_ADDR_MISALIGNED     = 4;
    localparam cause_t LD_ACCESS_FAULT        = 5;
    localparam cause_t ST_ADDR_MISALIGNED     = 6;
    localparam cause_t ST_ACCESS_FAULT        = 7;
    localparam cause_t INSTR_PAGE_FAULT       = 12;
    localparam cause_t LOAD_PAGE_FAULT        = 13;
    localparam cause_t STORE_PAGE_FAULT       = 15;
    localparam cause_t INSTR_GUEST_PAGE_FAULT = 20;
    localparam cause_t LOAD_GUEST_PAGE_FAULT  = 21;
    localparam cause_t STORE_GUEST_PAGE_FAULT = 23;

    // RISC-V IOMMU Causes
    localparam cause_t ALL_INB_TRANSACTIONS_DISALLOWED    = 256;
    localparam cause_t DDT_ENTRY_LD_ACCESS_FAULT          = 257;
    localparam cause_t DDT_ENTRY_INVALID                  = 258;
    localparam cause_t DDT_ENTRY_MISCONFIGURED            = 259;
    localparam cause_t TRANS_TYPE_DISALLOWED              = 260;
    localparam cause_t MSI_PTE_LD_ACCESS_FAULT            = 261;
    localparam cause_t MSI_PTE_INVALID                    = 262;
    localparam cause_t MSI_PTE_MISCONFIGURED              = 263;
    localparam cause_t MRIF_ACCESS_FAULT                  = 264;
    localparam cause_t PDT_ENTRY_LD_ACCESS_FAULT          = 265;
    localparam cause_t PDT_ENTRY_INVALID                  = 266;
    localparam cause_t PDT_ENTRY_MISCONFIGURED            = 267;
    localparam cause_t DDT_DATA_CORRUPTION                = 268;
    localparam cause_t PDT_DATA_CORRUPTION                = 269;
    localparam cause_t MSI_PT_DATA_CORRUPTION             = 270;
    localparam cause_t MSI_MRIF_DATA_CORRUPTION           = 271;
    localparam cause_t INTERN_DATAPATH_FAULT              = 272;
    localparam cause_t MSI_ST_ACCESS_FAULT                = 273;
    localparam cause_t PT_DATA_CORRUPTION                 = 274;
    // cause encondings 275 to 2047 are reserved. Encodings 2048 through 4095 are for custom use.

    //---------------------------
    // Transaction type encoding
    //---------------------------
    localparam TTYP_LEN = 6;
    typedef logic [(TTYP_LEN-1):0] ttype_t;

    localparam ttype_t NONE                = 6'b000000;
    // Untranslated (!b3 && !b2)
    localparam ttype_t UNTRANSLATED_RX     = 6'b00_0_0_01;
    localparam ttype_t UNTRANSLATED_R      = 6'b00_0_0_10;
    localparam ttype_t UNTRANSLATED_W      = 6'b00_0_0_11;
    // Translated (!b3 && b2)
    localparam ttype_t TRANSLATED_RX       = 6'b00_0_1_01;
    localparam ttype_t TRANSLATED_R        = 6'b00_0_1_10;
    localparam ttype_t TRANSLATED_W        = 6'b00_0_1_11;
    // PCIe (b3)
    localparam ttype_t PCIE_ATS_TRANS_REQ  = 6'b00_1_0_00;
    localparam ttype_t PCIE_MSG_REQ        = 6'b00_1_0_01;

    //---------------------------
    // Fault Queue Record Struct
    //---------------------------
    typedef struct packed {
        logic [63:0]    iotval2;
        logic [63:0]    iotval;
        device_id_t     did;
        ttype_t         ttyp;
        logic           priv;
        logic           pv;
        process_id_t    pid;
        cause_t         cause;
    } fq_record_t;

    //---------------
    // HPM Event IDs
    //---------------
    typedef enum logic [14:0] {
      NOT_COUNT     = 15'd0,
      UT_REQ        = 15'd1,
      T_REQ         = 15'd2,
      ATS_REQ       = 15'd3,
      IOTLB_MISS    = 15'd4,
      DDTW          = 15'd5,
      PDTW          = 15'd6,
      S1_PTW        = 15'd7,
      S2_PTW        = 15'd8
      // rsv [1 , 16383]
      // custom [16384 , 32767]
    } hpm_event_type_t;

    localparam int unsigned NumETypes = 8;
    typedef logic [NumETypes:0] hpm_etype_mask_t;

    typedef struct packed {
        device_id_t     did;  
        logic           pid_v;
        process_id_t    pid;  
        logic           gscid_v;
        gscid_t         gscid;
        logic           pscid_v;
        pscid_t         pscid;
    } hpm_event_filters_t;

    typedef struct packed {
        logic valid;
        hpm_etype_mask_t etype_msk;
        hpm_event_filters_t filters;
    } hpm_event_t;

    //--------------------------
    //#  IOMMU functions
    //--------------------------

    // Checks if final translation page size is 1G
    // Adapted from the CVA6 MMU's function in ariane_pkg
    function automatic logic is_trans_1G(
        input logic S1_en, input logic S2_en,
        input logic is_1S_1G, input logic is_2S_1G
    );
        // Two-stage
        if (S1_en && S2_en) begin
            // return true if both stages are at least 1GiB
            return (is_1S_1G && is_2S_1G);
        end
        // Single-stage
        else begin
            // return true if the enabled stage is 1GiB
            return ((is_1S_1G && S1_en) || (is_2S_1G && S2_en));
        end
    endfunction : is_trans_1G

    // Checks if final translation page size is 2M
    // Adapted from the CVA6 MMU's function in ariane_pkg
    function automatic logic is_trans_2M(
        input logic S1_en, input logic S2_en,
        input logic is_1S_1G, input logic is_1S_2M,
        input logic is_2S_1G, input logic is_2S_2M
    );
        // Two-stage
        if (S1_en && S2_en) begin
            // return true if both stages are at least 2M
            return ((is_1S_1G && (is_2S_1G || is_2S_2M)) || 
                    (is_2S_1G && (is_1S_1G || is_1S_2M)));
        end
        else begin
            // return true if the enabled stage is 2M
            return ((is_1S_2M && S1_en) || (is_2S_2M && S2_en));
        end
    endfunction : is_trans_2M

    // Computes the final gppn based on the guest physical address
    // Adapted from MMU function in ariane_pkg
    function automatic logic [(GPPNW39-1):0] make_gppn(
        input logic S1_en, 
        input logic is_1G, input logic is_2M, 
        input logic [(VPNW39-1):0] vpn, input ppn_t ppn
    );
        logic [(GPPNW39-1):0] gppn;

        // Two-stage
        if (S1_en) begin
            gppn = ppn[(GPPNW39-1):0];

            // 1GiB superpage
            if (is_1G)      gppn[17:0] = vpn[17:0];
            // 2MiB superpage
            if (is_2M)      gppn[8:0] = vpn[8:0];
        end 
        
        // Second-stage only
        else begin
            gppn = {{GPPNW39-VPNW39{1'b0}}, vpn};
        end
        return gppn;
    endfunction : make_gppn

    // Extract Interrupt File number from GPA
    // The resulting IF number is used to index the corresponding MSI PTE in memory.
    function automatic logic [(GPPNW39-1):0] extract_imsic_num(input logic [(GPPNW39-1):0] gppn, 
                                                                input logic [(GPPNW39-1):0] mask);
        logic [(GPPNW39-1):0] masked_gppn, imsic_num;
        int unsigned i;

        masked_gppn = gppn & mask;
        imsic_num = '0;
        i = 0;
        for (int unsigned k = 0 ; k < GPPNW39; k++) begin
            if (mask[k]) begin
                imsic_num[i[4:0]] = masked_gppn[k];
                i++;
            end
        end

        return imsic_num;
    endfunction : extract_imsic_num

    // Check if the given HPM counter is programmed to count one of the 
    // events indicated in the given mask
    function automatic logic hpm_event_match(hpm_event_type_t ctr_event, hpm_etype_mask_t mask);

        hpm_etype_mask_t masked_event;

        masked_event = (mask & (hpm_etype_mask_t'(1) << ctr_event));

        return (|masked_event);
    endfunction : hpm_event_match

endpackage

`endif  /* RISCV_IOMMU_PKG */