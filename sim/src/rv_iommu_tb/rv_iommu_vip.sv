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
// Date: 17/02/2025
//
// Authors:
// - Maicol Ciani <maicol.ciani@unibo.it>
//
// Description: Fixture including IOMMU DuT, tasks and processes for testing.
//

`timescale 1ps/1ps

`include "axi/typedef.svh"
`include "axi/assign.svh"

module rv_iommu_vip #(
   parameter int unsigned DATA_WIDTH       = -1,
   parameter int unsigned ID_WIDTH         = -1,
   parameter int unsigned ADDR_WIDTH       = -1,
   parameter int unsigned USER_WIDTH       = -1,
   parameter int unsigned REFClockPeriod   = -1,
   parameter type axi_tr_req_t    = logic,
   parameter type axi_tr_resp_t   = logic,
   parameter type axi_comp_req_t  = logic,
   parameter type axi_comp_resp_t = logic,
   parameter type axi_ds_req_t    = logic,
   parameter type axi_ds_resp_t   = logic,
   parameter type axi_prog_req_t  = logic,
   parameter type axi_prog_resp_t = logic
) (
   input logic clk_i,
   input logic rst_ni,

   // Translation Request Interface
   output axi_tr_req_t    axi_iommu_tr_req_o,
   input  axi_tr_resp_t   axi_iommu_tr_resp_i,

   // Translation Completion Interface
   input  axi_comp_req_t  axi_iommu_comp_req_i,
   output axi_comp_resp_t axi_iommu_comp_resp_o,

   // Data Structure Interface
   input  axi_ds_req_t    axi_iommu_ds_req_i,
   output axi_ds_resp_t   axi_iommu_ds_resp_o,

   // Programming Interface
   output axi_prog_req_t  axi_iommu_prog_req_o,
   input  axi_prog_resp_t axi_iommu_prog_resp_i
);

   import rv_iommu_dti_ats_pkg::*;
   import rv_iommu::*;

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

   typedef axi_test::axi_driver #(
     .AW( ADDR_WIDTH ),
     .DW( DATA_WIDTH ),
     .IW( ID_WIDTH   ),
     .UW( USER_WIDTH ),
     .TA( 0.15*REFClockPeriod ),
     .TT( 0.85*REFClockPeriod )
   ) axi_driver_t;

   typedef struct packed {
       logic [63:0] tc;
       logic [63:0] iohgatp;
       logic [63:0] ta;
       logic [63:0] fsc;
       logic [63:0] msiptp;
       logic [63:0] msi_addr_mask;
       logic [63:0] msi_addr_pattern;
       logic [63:0] reserved;
   } ddt_t;

   typedef struct packed {
      logic                      req;
      logic [ADDR_WIDTH-1:0]     addr;
      logic                      wen;
      logic [DATA_WIDTH-1:0]     wdata;
      logic [(DATA_WIDTH/8)-1:0] be;
   } mem_struct_t;

   // AXI Drivers' DV Buses
   AXI_BUS_DV #(
     .AXI_ADDR_WIDTH(ADDR_WIDTH),
     .AXI_DATA_WIDTH(DATA_WIDTH),
     .AXI_ID_WIDTH(ID_WIDTH),
     .AXI_USER_WIDTH(USER_WIDTH)
   ) axi_tr_drv_intf_dv (clk_i);

   AXI_BUS_DV #(
     .AXI_ADDR_WIDTH(ADDR_WIDTH),
     .AXI_DATA_WIDTH(DATA_WIDTH),
     .AXI_ID_WIDTH(ID_WIDTH),
     .AXI_USER_WIDTH(USER_WIDTH)
   ) axi_comp_drv_intf_dv (clk_i);

   AXI_BUS_DV #(
     .AXI_ADDR_WIDTH(ADDR_WIDTH),
     .AXI_DATA_WIDTH(DATA_WIDTH),
     .AXI_ID_WIDTH(ID_WIDTH),
     .AXI_USER_WIDTH(USER_WIDTH)
   ) axi_prog_drv_intf_dv (clk_i);

   // AXI Drivers' Buses
   AXI_BUS #(
     .AXI_ADDR_WIDTH(ADDR_WIDTH),
     .AXI_DATA_WIDTH(DATA_WIDTH),
     .AXI_ID_WIDTH(ID_WIDTH),
     .AXI_USER_WIDTH(USER_WIDTH)
   ) axi_tr_drv_intf();

   AXI_BUS #(
     .AXI_ADDR_WIDTH(ADDR_WIDTH),
     .AXI_DATA_WIDTH(DATA_WIDTH),
     .AXI_ID_WIDTH(ID_WIDTH),
     .AXI_USER_WIDTH(USER_WIDTH)
   ) axi_comp_drv_intf();

   AXI_BUS #(
     .AXI_ADDR_WIDTH(ADDR_WIDTH),
     .AXI_DATA_WIDTH(DATA_WIDTH),
     .AXI_ID_WIDTH(ID_WIDTH),
     .AXI_USER_WIDTH(USER_WIDTH)
   ) axi_ds_drv_intf();

   AXI_BUS #(
     .AXI_ADDR_WIDTH(ADDR_WIDTH),
     .AXI_DATA_WIDTH(DATA_WIDTH),
     .AXI_ID_WIDTH(ID_WIDTH),
     .AXI_USER_WIDTH(USER_WIDTH)
   ) axi_prog_drv_intf();

   mem_struct_t mem_req, task_req, iommu_req;
   logic [DATA_WIDTH-1:0] rdata;
   logic [31:0] GSCID_ARRAY;
   logic [31:0] PSCID_ARRAY;

   assign GSCID_ARRAY = 32'hDAB0D1DA;
   assign PSCID_ARRAY = 32'hDAD10BAD;

   // -------------------------------------------------
   // AXI Drivers
   // -------------------------------------------------
   axi_driver_t axi_tr_drv   = new(axi_tr_drv_intf_dv);
   axi_driver_t axi_comp_drv = new(axi_comp_drv_intf_dv);
   axi_driver_t axi_prog_drv = new(axi_prog_drv_intf_dv);

   // Connect AXI drivers to IOMMU's buses
   `AXI_ASSIGN(axi_tr_drv_intf, axi_tr_drv_intf_dv)
   `AXI_ASSIGN(axi_comp_drv_intf_dv, axi_comp_drv_intf)
   `AXI_ASSIGN(axi_prog_drv_intf, axi_prog_drv_intf_dv)

   // Connect AXI Buses to IOMMU I/O
   `AXI_ASSIGN_TO_REQ(axi_iommu_tr_req_o,axi_tr_drv_intf)
   `AXI_ASSIGN_FROM_RESP(axi_tr_drv_intf,axi_iommu_tr_resp_i)

   `AXI_ASSIGN_TO_REQ(axi_iommu_prog_req_o,axi_prog_drv_intf)
   `AXI_ASSIGN_FROM_RESP(axi_prog_drv_intf,axi_iommu_prog_resp_i)

   `AXI_ASSIGN_FROM_REQ(axi_comp_drv_intf,axi_iommu_comp_req_i)
   `AXI_ASSIGN_TO_RESP(axi_iommu_comp_resp_o,axi_comp_drv_intf)

   `AXI_ASSIGN_FROM_REQ(axi_ds_drv_intf,axi_iommu_ds_req_i)
   `AXI_ASSIGN_TO_RESP(axi_iommu_ds_resp_o,axi_ds_drv_intf)

   assign axi_iommu_tr_req_o.aw.stream_id = 24'b1;
   assign axi_iommu_tr_req_o.aw.ss_id_valid = 1'b0;
   assign axi_iommu_tr_req_o.aw.substream_id = 20'b0;

   assign axi_iommu_tr_req_o.ar.stream_id = 24'b1;
   assign axi_iommu_tr_req_o.ar.ss_id_valid = 1'b0;
   assign axi_iommu_tr_req_o.ar.substream_id = 20'b0;

   // -------------------------------------------------
   // Simulation Memory
   // -------------------------------------------------

   axi2mem #(
      .AXI_ID_WIDTH   ( ID_WIDTH   ),
      .AXI_ADDR_WIDTH ( ADDR_WIDTH ),
      .AXI_DATA_WIDTH ( DATA_WIDTH ),
      .AXI_USER_WIDTH ( USER_WIDTH )
   ) i_axi2mem (
      .clk_i   ( clk_i           ),
      .rst_ni  ( rst_ni          ),
      .slave   ( axi_ds_drv_intf ),
      .req_o   ( iommu_req.req   ),
      .we_o    ( iommu_req.wen   ),
      .addr_o  ( iommu_req.addr  ),
      .be_o    ( iommu_req.be    ),
      .data_o  ( iommu_req.wdata ),
      .data_i  ( rdata           )
   );

   // ---------------------------------------------------------------
   // Arbiter to mux the the AXIS upstream interface
   // ---------------------------------------------------------------
   stream_arbiter #(
      .DATA_T  ( mem_struct_t ),
      .N_INP   ( 2            ),
      .ARBITER ( "rr"         )
   ) i_inv_sync_req_arb (
      .clk_i       ( clk_i            ),
      .rst_ni      ( rst_ni           ),

      .inp_data_i  ( {iommu_req, task_req}         ),
      .inp_valid_i ( {iommu_req.req, task_req.req} ),
      .inp_ready_o (                  ),

      .oup_data_o  ( mem_req          ),
      .oup_valid_o (         b        ),
      .oup_ready_i ( 1'b1             )
   );

   tc_sram #(
      .NumWords  ( MemDepth   ),
      .DataWidth ( DATA_WIDTH ),
      .NumPorts  ( 1          ),
      .SimInit   ( "zeros"    )
   ) i_sim_ram (
      .clk_i   ( clk_i  ),
      .rst_ni  ( rst_ni ),
      .addr_i  ( {2'b0, mem_req.addr[MemAddWidth-1:2]} ),
      .req_i   ( mem_req.req   ),
      .wdata_i ( mem_req.wdata ),
      .rdata_o ( rdata         ),
      .we_i    ( mem_req.wen   ),
      .be_i    ( mem_req.be    )
   );

   // -------------------------------------------------
   // Drivers' Tasks
   // -------------------------------------------------

   task automatic reset_drvs();
      axi_tr_drv.reset_master();
      axi_comp_drv.reset_slave();
      axi_prog_drv.reset_master();
   endtask

   // Select one of the four drivers by string
   function automatic axi_driver_t select_driver(input string driver_name);
      axi_driver_t selected;
      if (driver_name == "tr") begin
         selected = axi_tr_drv;
      end
      else if (driver_name == "comp") begin
         selected = axi_comp_drv;
      end
      else if (driver_name == "prog") begin
         selected = axi_prog_drv;
      end
      else begin
         // In case of unknown string, return some default or throw an error
         $error("select_driver: Unknown driver_name \"%s\". Defaulting to 'tr' driver.", driver_name);
         selected = axi_tr_drv;
      end
      return selected;
   endfunction: select_driver

   // Single-beat AXI Write: picks one of the four drivers by name
   task automatic axi_single_write_select (
     input string           driver_name,
     input logic [ADDR_WIDTH-1:0] addr,
     input logic [DATA_WIDTH-1:0] data,
     input logic [ID_WIDTH-1:0]   id          = '0,
     input axi_pkg::burst_t        burst_type = axi_pkg::BURST_INCR
   );
      axi_driver_t local_drv = select_driver(driver_name);
      axi_single_write(local_drv, addr, data, id, burst_type);
   endtask: axi_single_write_select

   // Single-beat AXI Read: picks one of the four drivers by name
   task automatic axi_single_read_select (
     input  string            driver_name,
     input  logic [ADDR_WIDTH-1:0]  addr,
     output logic [DATA_WIDTH-1:0]  read_data,
     input  logic [ID_WIDTH-1:0]    id          = '0,
     input  axi_pkg::burst_t         burst_type = axi_pkg::BURST_INCR
   );
      axi_driver_t local_drv = select_driver(driver_name);
      axi_single_read(local_drv, addr, read_data, id, burst_type);
   endtask: axi_single_read_select

   /*
   * Single-beat AXI write:
   * Sends AW, writes a single data beat (W), then waits for B response.
   *
   *  @param drv        Reference to your instantiated axi_driver
   *  @param addr       Address to write
   *  @param data       Single word of data to be written
   *  @param id         (Optional) AXI ID for this transaction
   *  @param burst_type (Optional) AXI burst type (typically INCR or FIXED
   */

   task automatic axi_single_write (
     inout axi_driver_t drv,
     input  logic [ADDR_WIDTH-1:0] addr,
     input  logic [DATA_WIDTH-1:0] data,
     input  logic [ID_WIDTH-1:0] id = '0,
     input  axi_pkg::burst_t burst_type = axi_pkg::BURST_INCR
   );
     // Local variables for AW/W/B beats
     axi_driver_t::ax_beat_t aw_beat = new();
     axi_driver_t::w_beat_t  w_beat  = new();
     axi_driver_t::b_beat_t  b_beat  = new();

     //--------------------------------------------------------------------------
     // Construct AW beat (single-beat burst => ax_len = 0)
     //--------------------------------------------------------------------------
     aw_beat.ax_id     = id;
     aw_beat.ax_addr   = addr;
     aw_beat.ax_len    = 0; // Single beat
     aw_beat.ax_size   = $clog2(DATA_WIDTH/8);
     aw_beat.ax_burst  = burst_type;
     aw_beat.ax_lock   = 1'b0;
     aw_beat.ax_cache  = 4'b0011;     // e.g., Normal non-cacheable bufferable
     aw_beat.ax_prot   = 3'b000;
     aw_beat.ax_qos    = '0;
     aw_beat.ax_region = '0;
     aw_beat.ax_atop   = '0; // No atomic operation
     aw_beat.ax_user   = '0;

     //--------------------------------------------------------------------------
     // Construct W beat
     //--------------------------------------------------------------------------
     w_beat.w_data  = addr[3:0] == 4'h4 ? {data[31:0], 32'h0} : data;
     w_beat.w_strb  = addr[3:0] == 4'h4 ? 8'b11110000 : 8'b11111111;
     w_beat.w_last  = 1'b1;
     w_beat.w_user  = '0;

     fork
   //      Send AW
       begin
           drv.send_aw(aw_beat);
        end
    //     Send W
        begin
           drv.send_w(w_beat);
        end
     join

     //--------------------------------------------------------------------------
     // Receive B response
     //--------------------------------------------------------------------------
     drv.recv_b(b_beat);

       // Optionally, check b_beat.b_resp if you want to verify correct response
       // e.g. if (b_beat.b_resp != axi_pkg::RESP_OKAY) ...
   endtask: axi_single_write

   /**
    * Single-beat AXI read:
    * Sends AR, receives a single R data beat, and returns that word.
    *
    *  @param drv        Reference to your instantiated axi_driver
    *  @param addr       Address to read
    *  @param read_data  Returned data word from the R channel
    *  @param id         (Optional) AXI ID for this transaction
    *  @param burst_type (Optional) AXI burst type (typically INCR or FIXED)
    */
   task automatic axi_single_read (
     inout axi_driver_t drv,
     input  logic [ADDR_WIDTH-1:0]  addr,
     output logic [DATA_WIDTH-1:0]  read_data,
     input  logic [ID_WIDTH-1:0]  id = '0,
     input  axi_pkg::burst_t burst_type = axi_pkg::BURST_INCR
   );
     // Local variables for AR/R beats
     axi_driver_t::ax_beat_t ar_beat = new();
     axi_driver_t::r_beat_t  r_beat;

     //--------------------------------------------------------------------------
     // Construct AR beat (single-beat burst => ax_len = 0)
     //--------------------------------------------------------------------------
     ar_beat.ax_id     = id;
     ar_beat.ax_addr   = addr;
     ar_beat.ax_len    = 0; // Single beat
     ar_beat.ax_size   = $clog2(DATA_WIDTH/8);
     ar_beat.ax_burst  = burst_type;
     ar_beat.ax_lock   = 1'b0;
     ar_beat.ax_cache  = 4'b0011;     // e.g., Normal non-cacheable bufferable
     ar_beat.ax_prot   = 3'b000;
     ar_beat.ax_qos    = '0;
     ar_beat.ax_region = '0;
     ar_beat.ax_atop   = '0; // Not used for read
     ar_beat.ax_user   = '0;

     // Send AR
     drv.send_ar(ar_beat);

     //--------------------------------------------------------------------------
     // Receive R data (single beat)
     //--------------------------------------------------------------------------
     drv.recv_r(r_beat);

     // Copy the data out
     read_data = r_beat.r_data;

     // Optionally, check r_beat.r_resp if you want to verify correct response
     // e.g. if (r_beat.r_resp != axi_pkg::RESP_OKAY) ...
   endtask: axi_single_read
   //-------------------------------------------------------------------------
   // 32-bit Versions of Single-beat AXI Write/Read Tasks
   //-------------------------------------------------------------------------

   // Single-beat AXI Write: selects one of the drivers (using "prog") and performs
   // a 32-bit transaction.
   task automatic axi_single_write_select_32 (
     input string                   driver_name,
     input logic [ADDR_WIDTH-1:0]     addr,
     input logic [31:0]               data,
     input logic [ID_WIDTH-1:0]       id          = '0,
     input axi_pkg::burst_t           burst_type  = axi_pkg::BURST_INCR
   );
      axi_driver_t local_drv = select_driver(driver_name);
      axi_single_write_32(local_drv, addr, data, id, burst_type);
   endtask: axi_single_write_select_32

   // 32-bit Single-beat AXI Write: performs a 32-bit transaction.
   task automatic axi_single_write_32 (
     inout axi_driver_t              drv,
     input  logic [ADDR_WIDTH-1:0]    addr,
     input  logic [31:0]              data,
     input  logic [ID_WIDTH-1:0]      id         = '0,
     input  axi_pkg::burst_t          burst_type = axi_pkg::BURST_INCR
   );
      // Local variables for AW/W/B beats
      axi_driver_t::ax_beat_t aw_beat = new();
      axi_driver_t::w_beat_t  w_beat  = new();
      axi_driver_t::b_beat_t  b_beat  = new();

      // Construct AW beat (single-beat burst => ax_len = 0)
      aw_beat.ax_id     = id;
      aw_beat.ax_addr   = addr;
      aw_beat.ax_len    = 0; // Single beat
      aw_beat.ax_size   = $clog2(32/8); // 32-bit = 4 bytes => log2(4)=2
      aw_beat.ax_burst  = burst_type;
      aw_beat.ax_lock   = 1'b0;
      aw_beat.ax_cache  = 4'b0011;     // Normal non-cacheable, bufferable
      aw_beat.ax_prot   = 3'b000;
      aw_beat.ax_qos    = '0;
      aw_beat.ax_region = '0;
      aw_beat.ax_atop   = '0;          // No atomic operation
      aw_beat.ax_user   = '0;

      // Construct W beat
      w_beat.w_data  = data;
      w_beat.w_strb  = { (32/8) {1'b1} }; // 4 bytes, all valid
      w_beat.w_last  = 1'b1;               // Single beat, so last = 1
      w_beat.w_user  = '0;

    //  fork
        // Send AW
     //   begin
           drv.send_aw(aw_beat);
     //   end
        // Send W
      //  begin
           drv.send_w(w_beat);
       // end
    // join

      // Receive B response
      drv.recv_b(b_beat);
      // (Optionally, check b_beat.b_resp here)
   endtask: axi_single_write_32

   // Single-beat AXI Read: selects one of the drivers (using "prog") and performs
   // a 32-bit transaction.
   task automatic axi_single_read_select_32 (
     input string                 driver_name,
     input logic [ADDR_WIDTH-1:0] addr,
     output logic [63:0]          read_data,
     input logic [ID_WIDTH-1:0]   id = '0,
     input logic [7:0]            byte_enable = 8'hFF,
     input                        axi_pkg::burst_t burst_type = axi_pkg::BURST_INCR
   );
      axi_driver_t local_drv = select_driver(driver_name);
      axi_single_read_32(local_drv, addr, read_data, id, burst_type);
   endtask: axi_single_read_select_32

   // 32-bit Single-beat AXI Read: performs a 32-bit transaction.
   task automatic axi_single_read_32 (
     inout axi_driver_t              drv,
     input  logic [ADDR_WIDTH-1:0]    addr,
     output logic [31:0]              read_data,
     input  logic [ID_WIDTH-1:0]      id         = '0,
     input  axi_pkg::burst_t          burst_type = axi_pkg::BURST_INCR
   );
      // Local variables for AR/R beats
      axi_driver_t::ax_beat_t ar_beat = new();
      axi_driver_t::r_beat_t  r_beat;

      // Construct AR beat (single-beat burst => ax_len = 0)
      ar_beat.ax_id     = id;
      ar_beat.ax_addr   = addr;
      ar_beat.ax_len    = 0; // Single beat
      ar_beat.ax_size   = $clog2(32/8); // 32-bit = 4 bytes => log2(4)=2
      ar_beat.ax_burst  = burst_type;
      ar_beat.ax_lock   = 1'b0;
      ar_beat.ax_cache  = 4'b0011;     // Normal non-cacheable, bufferable
      ar_beat.ax_prot   = 3'b000;
      ar_beat.ax_qos    = '0;
      ar_beat.ax_region = '0;
      ar_beat.ax_atop   = '0;          // Not used for read
      ar_beat.ax_user   = '0;

      // Send AR beat
      drv.send_ar(ar_beat);

      // Receive R data (single beat)
      drv.recv_r(r_beat);
      read_data = r_beat.r_data;
      // (Optionally, check r_beat.r_resp here)
   endtask: axi_single_read_32

   // --------------------------------------------------------------------------
   // "Test page permission table" from your C code, as functions
   // --------------------------------------------------------------------------
   // For brevity, we replicate your lines as a “case” approach:
   function logic [63:0] get_stage1_perm(int idx);
     case (idx)
       IOMMU_OFF_R, IOMMU_OFF_W,
       IOMMU_BARE_R, IOMMU_BARE_W,
       BARE_TRANS_R1, BARE_TRANS_R2, BARE_TRANS_W1, BARE_TRANS_W2,
       SWITCH1, SWITCH2,
       HPM_R, HPM_W:
         return (PTE_V | PTE_U | PTE_RWX);

       // S2_ONLY_R => stage1=0
       S2_ONLY_R:
         return 64'h0;

       // S2_ONLY_W => stage1=0
       S2_ONLY_W:
         return 64'h0;

       // TWO_STAGE_R4K => PTE_V|PTE_U|PTE_R
       TWO_STAGE_R4K, TWO_STAGE_R2M, TWO_STAGE_R1G, MSI_R2,
       IOTINVAL_R1, IOTINVAL_R2, MSI_R3, MSI_R4, MSI_R5:
         return (PTE_V | PTE_U | PTE_R);

       // TWO_STAGE_W4K => PTE_V|PTE_U|PTE_RW
       TWO_STAGE_W4K:
         return (PTE_V | PTE_U | PTE_RW);

       // WSI_R => PTE_V|PTE_U|PTE_X
       WSI_R, MSI_GEN_R:
         return (PTE_V | PTE_U | PTE_X);

       // WSI_W => PTE_V|PTE_U|PTE_RW
       WSI_W, MSI_GEN_W:
         return (PTE_V | PTE_U | PTE_RW);

       default:
         // By default, map everything else as R/W/X to not crash
         return (PTE_V | PTE_U | PTE_RWX);
     endcase
   endfunction

   function logic [63:0] get_stage2_perm(int idx);
     case (idx)
       IOMMU_OFF_R, IOMMU_OFF_W,
       IOMMU_BARE_R, IOMMU_BARE_W,
       BARE_TRANS_R1, BARE_TRANS_R2, BARE_TRANS_W1, BARE_TRANS_W2,
       SWITCH1, SWITCH2,
       HPM_R, HPM_W:
         return (PTE_V | PTE_U | PTE_RWX);

       // S2_ONLY_R => PTE_V|PTE_U|PTE_R
       S2_ONLY_R:
         return (PTE_V | PTE_U | PTE_R);

       // S2_ONLY_W => PTE_V|PTE_U|PTE_RW
       S2_ONLY_W:
         return (PTE_V | PTE_U | PTE_RW);

       // TWO_STAGE_R4K => PTE_V|PTE_U|PTE_R
       TWO_STAGE_R4K, TWO_STAGE_R2M, TWO_STAGE_R1G, MSI_R2,
       IOTINVAL_R1, IOTINVAL_R2, MSI_R3, MSI_R4, MSI_R5:
         return (PTE_V | PTE_U | PTE_R);

       // TWO_STAGE_W4K => PTE_V|PTE_U|PTE_RW
       TWO_STAGE_W4K:
         return (PTE_V | PTE_U | PTE_RW);

       // WSI_R => PTE_V|PTE_U|PTE_R
       WSI_R, MSI_GEN_R:
         return (PTE_V | PTE_U | PTE_R);

       // WSI_W => PTE_V|PTE_U|PTE_RX
       WSI_W, MSI_GEN_W:
         return (PTE_V | PTE_U | PTE_RX);

       default:
         // Fallback
         return (PTE_V | PTE_U | PTE_RWX);
     endcase
   endfunction

   // --------------------------------------------------------------------------
   // Address helper functions (where to store s1pt[x][y], s2pt[x][y], etc.)
   // Each PTE is 8 bytes
   // --------------------------------------------------------------------------
   function logic [31:0] s1pt_addr(input int i, input int j);
     // i in [0..5], j in [0..511]
     s1pt_addr = {S1PT_BASE,12'b0} + ((i*512 + j) * 8);
   endfunction

   function logic [31:0] s2pt_addr(input int i, input int j);
     // i in [0..4], j in [0..511]
     s2pt_addr = {S2PT_BASE,12'b0} + ((i*512 + j) * 8);
   endfunction

   function logic [31:0] s2pt_root_addr(input int idx);
     // idx in [0..2047]
     s2pt_root_addr = {S2PT_ROOT_BASE,12'b0} + (idx * 8);
   endfunction

   // --------------------------------------------------------------------------
   // Low-level “write one 64-bit word to SRAM” task
   // You may need to adapt cycles or handshake depending on your memory model
   // --------------------------------------------------------------------------
   task automatic mem_write(
     input logic [31:0]  addr,
     input logic [63:0]  data
   );
     @(posedge clk_i);
       task_req.req   <= 1'b1;
       task_req.wen   <= 1'b1;
       task_req.addr  <= addr;
       task_req.wdata <= data;
       task_req.be    <= 8'hFF;   // all byte lanes active
     @(posedge clk_i);
       task_req.req   <= 1'b0;
       task_req.wen   <= 1'b0;
       task_req.addr  <= 'h0;
       task_req.wdata <= 'h0;
       task_req.be    <= 'h0;
   endtask

   // --------------------------------------------------------------------------
   // s1pt_init() replica
   // --------------------------------------------------------------------------
   task automatic s1pt_init_hw();
     int i;
     logic [63:0] addr;
     logic [63:0] pte_val;
     logic [63:0] base_ptr;

     // Clear s1pt[1][..]
     for (i=0; i<512; i++) begin
       mem_write( s1pt_addr(0,i), 64'h0 );
       mem_write( s1pt_addr(1,i), 64'h0 );
       mem_write( s1pt_addr(2,i), 64'h0 );
     end

     // s1pt[0][3] = PTE_V | ((&s1pt[1][0] >>2) & PTE_PPN_MSK)
     base_ptr = s1pt_addr(1,0);
     pte_val  = PTE_V | ((base_ptr >> 2) & PTE_PPN_MSK);
     mem_write( s1pt_addr(0,0), pte_val );
     mem_write( s1pt_addr(0,4), pte_val );
     mem_write( s1pt_addr(0,8), pte_val );

     // s1pt[0][4] = PTE_V | ((&s1pt[2][0] >>2) & PTE_PPN_MSK)
     base_ptr = s1pt_addr(2,0);
     pte_val  = PTE_V | ((base_ptr >> 2) & PTE_PPN_MSK);
     mem_write( s1pt_addr(1,0), pte_val );
     mem_write( s1pt_addr(1,4), pte_val );
     mem_write( s1pt_addr(1,4), pte_val );
     mem_write( s1pt_addr(1,511), pte_val );

     // Fill s1pt[3][i] with 4KiB PTEs
     addr = TEST_VPAGE_BASE + 64'h0008_0000;  // The C code used TEST_VPAGE_BASE
     for (i=0; i<TEST_PAGE_MAX; i++) begin
       // s1pt[3][i] = (addr >>2) | PTE_AD | PTE_V|PTE_U|PTE_RWX
       pte_val = (addr >> 2) | PTE_AD | PTE_V | PTE_U | PTE_RWX;
       mem_write( s1pt_addr(2,i), pte_val );
       addr += PAGE_SIZE_4K;
     end

   endtask

   // --------------------------------------------------------------------------
   // s2pt_init() replica
   // --------------------------------------------------------------------------
   task automatic s2pt_init_hw();
     int i;
     logic [63:0] addr;
     logic [63:0] pte_val;
     logic [63:0] base_ptr;

     // Clear root table [0..2047]
     for (i=0; i<2048; i++) begin
       mem_write( s2pt_root_addr(i), 64'h0 );
     end
     // Clear s2pt[0][..]
     for (i=0; i<512; i++) begin
       mem_write( s2pt_addr(0,i), 64'h0 );
     end

     // s2pt_root[4] = PTE_V | ((&s2pt[1][0] >>2) & PTE_PPN_MSK)
     base_ptr = 32'h8000_0000;
     pte_val  = PTE_V | ((base_ptr >> 2) | PTE_AD | PTE_V | PTE_U | PTE_RWX);
     mem_write( s2pt_root_addr(2), pte_val );

     base_ptr = s2pt_addr(0,0);
     pte_val  = PTE_V | ((base_ptr >> 2) & PTE_PPN_MSK);
     mem_write( s2pt_root_addr(4), pte_val );

     // s2pt_root[2047] = PTE_V | ((&s2pt[1][0] >>2) & PTE_PPN_MSK)
     mem_write( s2pt_root_addr(2047), pte_val );

     // s2pt[1][0] = PTE_V | ((&s2pt[2][0] >>2) & PTE_PPN_MSK)
     // s2pt[1][511] = PTE_V | ((&s2pt[2][0] >>2) & PTE_PPN_MSK)
     base_ptr = s2pt_addr(1,0);
     pte_val  = PTE_V | ((base_ptr >> 2) & PTE_PPN_MSK);
     mem_write( s2pt_addr(0,0), pte_val );
     mem_write( s2pt_addr(0,31), pte_val );
     mem_write( s2pt_addr(0,511), pte_val );

     // Fill s2pt[2][i] with 4KiB PTEs
     addr = TEST_PPAGE_BASE;  // e.g. 0x88000000
     for (i=0; i<TEST_PAGE_MAX; i++) begin
     //  if ((i >= STRESS_START) && (i < STRESS_TOP)) begin
       pte_val = (addr >> 2) | PTE_AD | PTE_V | PTE_U | PTE_RWX;
     //  end
     //  else begin
     //    pte_val = (addr >> 2) | PTE_AD | get_stage2_perm(i);
     //  end
       mem_write( s2pt_addr(1,i), pte_val );
       addr += PAGE_SIZE_4K;
     end
   endtask // s2pt_init_hw

   task automatic iommu_ddt_init_hw();
     logic [63:0] val64;
     logic [31:0] entry_base;
     logic [63:0] ddtp;
     // --------------------------------------------------------------------------
     // (1) Init all entries to zero
     // --------------------------------------------------------------------------
     for (int i = 0; i < DDT_N_ENTRIES; i++) begin
       entry_base = ROOT_DDT_BASE + i*ROOT_DDT_SIZE;
       // Write zero to each field we care about:
       mem_write(entry_base + 64'h00, 64'h0);
       mem_write(entry_base + 64'h08, 64'h0);
       mem_write(entry_base + 64'h10, 64'h0);
       mem_write(entry_base + 64'h18, 64'h0);
       mem_write(entry_base + 64'h20, 64'h0);  // Not used if MSI disabled
       mem_write(entry_base + 64'h28, 64'h0);  // ...
       mem_write(entry_base + 64'h30, 64'h0);
       mem_write(entry_base + 64'h38, 64'h0);
     end

     // --------------------------------------------------------------------------
     // (2) Configure DCs in the root DDT (1LVL mode)
     // --------------------------------------------------------------------------
     for (int i = DID_MIN; i <= DID_MAX; i++) begin
       entry_base = ROOT_DDT_BASE + i*ROOT_DDT_SIZE;

       // root_ddt[i].tc = test_dc_tc_table[BASIC];
       mem_write(entry_base + OFF_TC, 32'b11);

       // root_ddt[i].iohgatp = ((s2pt_root >> 12) | IOHGATP_MODE_BARE);
       //  and also add  (GSCID_ARRAY[i] << GSCID_OFF)
       val64 = {IOHGATP_MODE_SV39X4, 16'b0, S2PT_ROOT_BASE};
       mem_write(entry_base + OFF_IOHGATP, val64);

       // root_ddt[i].fsc = ((s1pt >> 12) | IOSATP_MODE_BARE);
       val64 = {IOSATP_MODE_SV39, 16'b0, S1PT_BASE};
       mem_write(entry_base + OFF_FSC, val64);
     end // for (int i = DID_MIN; i <= DID_MAX; i++)

     ddtp = {10'b0,
             ROOT_DDT_BASE[43:0],
             6'b0,
             DDTP_MODE_1LVL};

     axi_single_write_select("prog",64'h10,ddtp[31:0]);
     axi_single_write_select("prog",64'h14,ddtp[63:32]);

   endtask // iommu_ddt_init_hw

   //----------------------------------------------------------------
   // Task: iommu_cq_init
   // Configures the command-queue registers:
   //  - Programs the cqb register with the physical address and size of the CQ.
   //  - Copies the head pointer (cqh) into the tail pointer (cqt).
   //  - Enables the CQ by writing to the cqcsr register.
   //  - Polls until the CQON bit is set in cqcsr.
   //----------------------------------------------------------------
   task automatic iommu_cq_init();
     // Local variables for 64-bit and 32-bit data
     logic [63:0] cqb_val;
     logic [31:0] cqh_val;
     logic [31:0] reg_data;
     // Compute the value for the command-queue base register:
     //   cqb_val = ( (COMMAND_QUEUE_BASE >> 2) & CQB_PPN_MASK ) | CQ_LOG2SZ_1;
      
     cqb_val = (((COMMAND_QUEUE_BASE >> 2) & CQB_PPN_MASK) | CQ_LOG2SZ_1);

     // Program the 64-bit cqb register using two 32-bit writes.
     axi_single_write_select("prog", IOMMU_CQB_ADDR, cqb_val[31:0]);
     axi_single_write_select("prog", IOMMU_CQB_ADDR + 4, cqb_val[63:32]);

     // Read the current command-queue head (cqh) using the programming interface.
     axi_single_read_select("prog", IOMMU_CQH_ADDR, cqh_val);
     // Set cqt (tail) equal to cqh.
     axi_single_write_select("prog", IOMMU_CQT_ADDR, cqh_val);

     // Enable the command queue by writing (CQCSR_CQEN | CQCSR_CIE) to cqcsr.
     axi_single_write_select("prog", IOMMU_CQCSR_ADDR, (CQCSR_CQEN | CQCSR_CIE));

     // Poll until the CQON bit is set in the cqcsr register.
     do begin
       axi_single_read_select("prog", IOMMU_CQCSR_ADDR, reg_data);
       @(posedge clk_i);
     end while ((reg_data & CQCSR_CQON) == 0);
   endtask

   //----------------------------------------------------------------
   // Task: rv_iommu_write_command_in_queue
   // Writes a two-word (64-bit ×2) command into the command queue buffer.
   // It uses the current tail pointer (cqt) to compute the target address in the
   // command queue memory and then writes the two words. Finally, it increments cqt.
   //----------------------------------------------------------------
   task automatic rv_iommu_write_command_in_queue(
     ref cq_atsinval_t inval_i
   );
     logic [31:0] cqt;
     logic [31:0] cq_entry_addr;

     // Read the current command-queue tail index (cqt)
     axi_single_read_select("prog", 64'h24, cqt);

     // Compute the address of the next CQ entry:
     // Each entry is 16 bytes (2×64-bit words) so we shift cqt by 4 bits.
     cq_entry_addr = (COMMAND_QUEUE_BASE & CQ_PPN_MASK32) | (cqt << 4);

     // Write the first 64-bit word at the computed command queue address.
     mem_write(cq_entry_addr,      inval_i[63:0]);
     mem_write(cq_entry_addr + 8,  inval_i[127:64]);

     // Increment the command-queue tail pointer and program it back.
     cqt = cqt + 1;
     axi_single_write_select("prog", 64'h24, cqt);
   endtask

endmodule
