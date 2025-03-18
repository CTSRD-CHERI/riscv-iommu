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
// Date: 13/03/2025
//
// Authors:
// - Maicol Ciani <maicol.ciani@unibo.it>
//
// Description: Definition for testbench
//

package rv_iommu_tb_defs;


   // Import the same environment references
   import rv_iommu::*;
   import rv_iommu_cfg::*;
   import rv_iommu_dti_ats_pkg::*;
   import axi_test::*;

   localparam rv_iommu_cfg_t RVIOMMUCfg = rv_iommu_cfg::rv_iommu_cfg_t'{
        NumOutstandingTrans : 32'd8,
        WFifoDepth          : 32'd32,
        MrifFifoDepth       : 32'd8,
        FaultFifoDepth      : 32'd8,
        NumIotlbEntries     : 32'd16,
        NumDdtcEntries      : 32'd8,
        NumPdtcEntries      : 32'd8,
        NumMrifcEntries     : 32'd8,
        InclPC              : 1'b1,
        InclAxiBC           : 1'b1,
        InclDbg             : 1'b1,
        InclATS             : 1'b1,
        MSITrans            : rv_iommu_cfg::MSI_BT_MRIF,
        IGS                 : rv_iommu_cfg::BOTH,
        NumIntVec           : 32'd16,
        NumHpmCounters      : 32'd31,
        PAddrWidth          : 32'd56,
        AxiAddrWidth        : 32'd64,
        AxiDataWidth        : 32'd64,
        AxiIdWidth          : 32'd4,
        AxiProgIdWidth      : 32'd6,
        AxiUserWidth        : 32'd1,
        AxiProIdWidth       : 32'd20,
        AxiDevIdWidth       : 32'd24,
        AxisDataWidth       : 32'd160,
        AxisUserWidth       : 32'd1,
        AxisKeepWidth       : 32'd20,
        AxisStrbWidth       : 32'd20,
        AxisIdWidth         : 32'd1,
        AxisDestWidth       : 32'd1,
        Freq                : 32'd100
   };

   // --------------------------------------------------------------------------
   // Proposed memory map assignments (example)
   // --------------------------------------------------------------------------
   // s1pt[6][512] = 6*512 = 3072 PTEs => each PTE is 8 bytes => total 24KiB
   localparam logic [43:0]  S1PT_BASE         = 44'h8002C;
   // s2pt_root[2048] => 2048 PTEs => 16KiB
   localparam logic [43:0]  S2PT_ROOT_BASE    = 44'h80028;
   // s2pt[5][512] = 5*512=2560 => 20KiB
   localparam logic [43:0]  S2PT_BASE         = 44'h8002A;

   // Define DDT (IOMMU) mode
   localparam logic [3:0] DDTP_MODE_OFF   = 4'h0;
   localparam logic [3:0] DDTP_MODE_BARE  = 4'h1;
   localparam logic [3:0] DDTP_MODE_1LVL  = 4'h2;
   localparam logic [3:0] DDTP_MODE_2LVL  = 4'h3;
   localparam logic [3:0] DDTP_MODE_3LVL  = 4'h4;
   // --------------------------------------------------------------------------
   // Define the fundamental sizing and addresses from your C code
   // --------------------------------------------------------------------------
   localparam logic [63:0] PAGE_SIZE_4K   = 64'h0000_1000; // 4 KiB
   localparam logic [63:0] SUPERPAGE_1G   = 64'h4000_0000; // 1 GiB
   localparam logic [63:0] SUPERPAGE_2M   = 64'h0020_0000; // 2 MiB

   // For shifting the PPN portion
   localparam logic [63:0] PTE_PPN_MSK    = 64'h3FFFFFFFFFFC00;

   // The original code used e.g. MEM_BASE=0x8000_0000, MEM_SIZE=256MB
   localparam logic [63:0] MEM_BASE       = 64'h8000_0000;
   localparam logic [63:0] MEM_SIZE       = 64'h1000_0000;  // 256MB

   // C code used these addresses
   localparam logic [63:0] TEST_VPAGE_BASE= 64'h1_0000_0000; // 0x100000000
   localparam logic [63:0] TEST_PPAGE_BASE= (MEM_BASE + (MEM_SIZE>>1)); // 0x88000000

   // Example “stress” region, or set them to 0 if unused
   localparam int STRESS_START      = 300;
   localparam int N_MAPPINGS        = 20;
   localparam int STRESS_TOP        = STRESS_START + N_MAPPINGS;

   // --------------------------------------------------------------------------
   // Basic PTE flag bits (matching your C macros)
   // --------------------------------------------------------------------------
   localparam logic [63:0] PTE_V    = 64'h0000_0000_0000_0001; // bit0
   localparam logic [63:0] PTE_R    = 64'h0000_0000_0000_0002; // bit1
   localparam logic [63:0] PTE_W    = 64'h0000_0000_0000_0004; // bit2
   localparam logic [63:0] PTE_X    = 64'h0000_0000_0000_0008; // bit3 001000000
   localparam logic [63:0] PTE_U    = 64'h0000_0000_0000_0010; // bit4
   localparam logic [63:0] PTE_AD   = 64'h0000_0000_0000_00C0; // bits6,7
   localparam logic [63:0] PTE_RWX  = (PTE_R | PTE_W | PTE_X);
   localparam logic [63:0] PTE_RW   = (PTE_R | PTE_W);
   localparam logic [63:0] PTE_RX   = (PTE_R | PTE_X);

   // For 1GiB / 2MiB “leaf” perms, as in C:
   localparam logic [63:0] STAGE1_PERM_1GIB = (PTE_V | PTE_AD | PTE_U | PTE_RWX);
   localparam logic [63:0] STAGE1_PERM_2MIB = (PTE_V | PTE_AD | PTE_U | PTE_RWX);
   localparam logic [63:0] STAGE2_PERM_1GIB = (PTE_V | PTE_AD | PTE_U | PTE_RWX);
   localparam logic [63:0] STAGE2_PERM_2MIB = (PTE_V | PTE_AD | PTE_U | PTE_RWX);

   // --------------------------------------------------------------------------
   // Enumerations from your C code (partial)
   // --------------------------------------------------------------------------
   localparam int IOMMU_OFF_R       =  0;
   localparam int IOMMU_OFF_W       =  1;
   localparam int IOMMU_BARE_R      =  2;
   localparam int IOMMU_BARE_W      =  3;
   localparam int BARE_TRANS_R1     =  4;
   localparam int BARE_TRANS_R2     =  5;
   localparam int BARE_TRANS_W1     =  6;
   localparam int BARE_TRANS_W2     =  7;
   localparam int S2_ONLY_R         =  8;
   localparam int S2_ONLY_W         =  9;
   localparam int MSI_R1            = 10;
   localparam int TWO_STAGE_R4K     = 11;
   localparam int TWO_STAGE_R2M     = 12;
   localparam int TWO_STAGE_R1G     = 13;
   localparam int MSI_R2            = 14;
   localparam int TWO_STAGE_W4K     = 15;
   localparam int IOTINVAL_R1       = 16;
   localparam int IOTINVAL_R2       = 17;
   localparam int WSI_R             = 18;
   localparam int WSI_W             = 19;
   localparam int MSI_GEN_R         = 20;
   localparam int MSI_GEN_W         = 21;
   localparam int HPM_R             = 22;
   localparam int HPM_W             = 23;
   localparam int MSI_R3            = 24;
   localparam int MSI_R4            = 25;
   localparam int MSI_R5            = 26;
   localparam int SWITCH1           = 27;
   localparam int SWITCH2           = 28;
   localparam int STRESS_START_ENUM = 29; // (In the C code it was 30, just an example)

   localparam int PT_TOP            = 511;
   localparam int TEST_PAGE_MAX     = 512;

   localparam logic [31:0] OFF_TC                = 32'h00;
   localparam logic [31:0] OFF_IOHGATP           = 32'h08;
   localparam logic [31:0] OFF_TA                = 32'h10;
   localparam logic [31:0] OFF_FSC               = 32'h18;
   localparam logic [31:0] OFF_MSIPTP            = 32'h20;
   localparam logic [31:0] OFF_OFF_MSI_ADDR_MASK = 32'h28;
   localparam logic [31:0] OFF_MSI_ADDR_PATT     = 32'h30;
   localparam logic [31:0] OFF_RESERVED          = 32'h38;

   localparam logic [31:0] GSCID_OFF            = 32'd44;
   localparam logic [31:0] PSCID_OFF            = 32'd12;

   localparam logic [63:0] ROOT_DDT_BASE = 64'h00;
   localparam logic [31:0] ROOT_DDT_SIZE = 32'h40;

   localparam int DDT_N_ENTRIES     = 64;
   localparam int DID_MIN           = 1;
   localparam int DID_MAX           = 25;

   localparam logic [63:0] IOHGATP_MODE_BARE = 64'h0;
   localparam logic [63:0] IOSATP_MODE_BARE  = 64'h0;

   localparam logic [63:0] IOHGATP_MODE_SV39X4 = 64'h8;
   localparam logic [63:0] IOSATP_MODE_SV39    = 64'h8;

   localparam int MemDepth = 1024*1024;
   localparam int MemAddWidth = $clog2(MemDepth);

   localparam logic [31:0] COMMAND_QUEUE_BASE = 32'h00EF_0000;

   // Command queue mapping
   // Offsets as defined by the structure layout
   localparam logic [31:0] IOMMU_CAP_ADDR    = 32'h00;
   localparam logic [31:0] IOMMU_FCTL_ADDR   = 32'h08;
   localparam logic [31:0] IOMMU_DDTP_ADDR   = 32'h10;
   localparam logic [31:0] IOMMU_CQB_ADDR    = 32'h18;
   localparam logic [31:0] IOMMU_CQH_ADDR    = 32'h20;
   localparam logic [31:0] IOMMU_CQT_ADDR    = 32'h24;
   localparam logic [31:0] IOMMU_FQB_ADDR    = 32'h28;
   localparam logic [31:0] IOMMU_FQH_ADDR    = 32'h30;
   localparam logic [31:0] IOMMU_FQT_ADDR    = 32'h34;
   localparam logic [31:0] IOMMU_PQB_ADDR    = 32'h38;
   localparam logic [31:0] IOMMU_PQH_ADDR    = 32'h40;
   localparam logic [31:0] IOMMU_PQT_ADDR    = 32'h44;
   localparam logic [31:0] IOMMU_CQCSR_ADDR  = 32'h48;
   localparam logic [31:0] IOMMU_FQCSR_ADDR  = 32'h4C;
   localparam logic [31:0] IOMMU_PQCSR_ADDR  = 32'h50;
   localparam logic [31:0] IOMMU_IPSR_ADDR   = 32'h54;

   // Constant definitions for CQ
   localparam logic [63:0] CQB_PPN_MASK   = 64'h3FFFFFFFFFFC00;
   localparam logic [63:0] CQ_LOG2SZ_1    = 64'h1; // For example, log2(queue size)=1
   localparam logic [31:0] CQCSR_CQEN     = 32'h1;
   localparam logic [31:0] CQCSR_CIE      = 32'h2;
   localparam logic [31:0] CQCSR_CQON     = 32'h0001_0000;
   // For addressing the command queue buffer (32-bit mask on the base address)
   localparam logic [31:0] CQ_PPN_MASK32  = 32'hFFFF_F000;

endpackage
