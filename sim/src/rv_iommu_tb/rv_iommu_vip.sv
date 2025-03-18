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
// Minimal "VIP module" for the IOMMU side, plus a class-based agent that
// provides tasks to do single-beat AXI reads/writes, initialize s1pt/s2pt, etc.
//
// -----------------------------------------------------------------------------

`timescale 1ps/1ps

`include "axi/typedef.svh"
`include "axi/assign.svh"

// For your dti_ats_inval structure or other shared definitions:
import rv_iommu_vip_pkg::*;
import rv_iommu_dti_ats_pkg::*;
import rv_iommu::*;
import rv_iommu_tb_defs::*;

// -----------------------------------------------------------------------------
// 1) The rv_iommu_vip module
// -----------------------------------------------------------------------------
module rv_iommu_vip #(
   parameter int unsigned DATA_WIDTH       = -1,
   parameter int unsigned ID_WIDTH         = -1,
   parameter int unsigned ADDR_WIDTH       = -1,
   parameter int unsigned USER_WIDTH       = -1,
   parameter int unsigned DEVID_WIDTH      = -1,
   parameter int unsigned PROID_WIDTH      = -1,
   parameter int unsigned REFClockPeriod   = -1,
   parameter int unsigned MEM_DEPTH        = 1024*1024,
   parameter type axi_tr_req_t    = logic,
   parameter type axi_tr_resp_t   = logic,
   parameter type axi_comp_req_t  = logic,
   parameter type axi_comp_resp_t = logic,
   parameter type axi_ds_req_t    = logic,
   parameter type axi_ds_resp_t   = logic,
   parameter type axi_prog_req_t  = logic,
   parameter type axi_prog_resp_t = logic,
   parameter type mem_struct_t    = logic
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
   input  axi_prog_resp_t axi_iommu_prog_resp_i,

   MEM_INTF.Slave         mem_intf
);
   logic [$clog2(MEM_DEPTH)-1:0] iommu_addr, mem_addr, tr_comp_addr;

   MEM_INTF #(
     .ADDR_WIDTH(ADDR_WIDTH),
     .DATA_WIDTH(DATA_WIDTH)
   ) sram_intf[2]();

   MEM_INTF #(
     .ADDR_WIDTH(ADDR_WIDTH),
     .DATA_WIDTH(DATA_WIDTH)
   ) iommu_intf();

   MEM_INTF #(
     .ADDR_WIDTH(ADDR_WIDTH),
     .DATA_WIDTH(DATA_WIDTH)
   ) tr_comp_intf();

   // The AXI_Bus "DV" interface for each interface:
   AXI_EXT_BUS_DV #(
     .AXI_ADDR_WIDTH  (ADDR_WIDTH),
     .AXI_DATA_WIDTH  (DATA_WIDTH),
     .AXI_ID_WIDTH    (ID_WIDTH),
     .AXI_USER_WIDTH  (USER_WIDTH),
     .AXI_PROCID_WIDTH (PROID_WIDTH),
     .AXI_DEVID_WIDTH (DEVID_WIDTH)
   ) axi_tr_drv_intf_dv (clk_i);

   AXI_BUS_DV #(
     .AXI_ADDR_WIDTH(ADDR_WIDTH),
     .AXI_DATA_WIDTH(DATA_WIDTH),
     .AXI_ID_WIDTH  (ID_WIDTH),
     .AXI_USER_WIDTH(USER_WIDTH)
   ) axi_prog_drv_intf_dv (clk_i);

   // Actual AXI bus signals
   AXI_EXT_BUS #(
     .AXI_ADDR_WIDTH(ADDR_WIDTH),
     .AXI_DATA_WIDTH(DATA_WIDTH),
     .AXI_ID_WIDTH  (ID_WIDTH),
     .AXI_USER_WIDTH(USER_WIDTH),
     .AXI_PROCID_WIDTH(PROID_WIDTH),
     .AXI_DEVID_WIDTH (DEVID_WIDTH)
   ) axi_tr_drv_intf();

   AXI_BUS #(
     .AXI_ADDR_WIDTH(ADDR_WIDTH),
     .AXI_DATA_WIDTH(DATA_WIDTH),
     .AXI_ID_WIDTH  (ID_WIDTH),
     .AXI_USER_WIDTH(USER_WIDTH)
   ) axi_comp_drv_intf();

   AXI_BUS #(
     .AXI_ADDR_WIDTH(ADDR_WIDTH),
     .AXI_DATA_WIDTH(DATA_WIDTH),
     .AXI_ID_WIDTH  (ID_WIDTH),
     .AXI_USER_WIDTH(USER_WIDTH)
   ) axi_prog_drv_intf();

   AXI_BUS #(
     .AXI_ADDR_WIDTH(ADDR_WIDTH),
     .AXI_DATA_WIDTH(DATA_WIDTH),
     .AXI_ID_WIDTH  (ID_WIDTH),
     .AXI_USER_WIDTH(USER_WIDTH)
   ) axi_ds_drv_intf();

   // Connect to the top-level I/O
   `AXI_ASSIGN_TO_REQ   (axi_iommu_tr_req_o,    axi_tr_drv_intf)
   `AXI_ASSIGN_FROM_RESP(axi_tr_drv_intf,       axi_iommu_tr_resp_i)

   `AXI_ASSIGN_TO_REQ   (axi_iommu_prog_req_o,  axi_prog_drv_intf)
   `AXI_ASSIGN_FROM_RESP(axi_prog_drv_intf,     axi_iommu_prog_resp_i)

   `AXI_ASSIGN_FROM_REQ (axi_comp_drv_intf,     axi_iommu_comp_req_i)
   `AXI_ASSIGN_TO_RESP  (axi_iommu_comp_resp_o, axi_comp_drv_intf)

   `AXI_ASSIGN_FROM_REQ (axi_ds_drv_intf,       axi_iommu_ds_req_i)
   `AXI_ASSIGN_TO_RESP  (axi_iommu_ds_resp_o,   axi_ds_drv_intf)

   `AXI_ASSIGN(axi_tr_drv_intf, axi_tr_drv_intf_dv)
   `AXI_ASSIGN(axi_prog_drv_intf, axi_prog_drv_intf_dv)

   // Force certain signals for AW/AR substream ID, etc.
   assign axi_iommu_tr_req_o.aw.stream_id     = axi_tr_drv_intf.aw_stream_id;
   assign axi_iommu_tr_req_o.aw.ss_id_valid   = axi_tr_drv_intf.aw_ss_id_valid;
   assign axi_iommu_tr_req_o.aw.substream_id  = axi_tr_drv_intf.aw_substream_id;
   assign axi_iommu_tr_req_o.aw.mmu_flow      = axi_tr_drv_intf.aw_mmu_flow;
   assign axi_iommu_tr_req_o.aw.mmu_secsid    = axi_tr_drv_intf.aw_mmu_secsid;
   assign axi_iommu_tr_req_o.aw.mmu_atst      = axi_tr_drv_intf.aw_mmu_atst;
   assign axi_iommu_tr_req_o.aw.mmu_valid     = axi_tr_drv_intf.aw_mmu_valid;

   assign axi_iommu_tr_req_o.ar.stream_id     = axi_tr_drv_intf.ar_stream_id;
   assign axi_iommu_tr_req_o.ar.ss_id_valid   = axi_tr_drv_intf.ar_ss_id_valid;
   assign axi_iommu_tr_req_o.ar.substream_id  = axi_tr_drv_intf.ar_substream_id;
   assign axi_iommu_tr_req_o.ar.mmu_flow      = axi_tr_drv_intf.ar_mmu_flow;
   assign axi_iommu_tr_req_o.ar.mmu_secsid    = axi_tr_drv_intf.ar_mmu_secsid;
   assign axi_iommu_tr_req_o.ar.mmu_atst      = axi_tr_drv_intf.ar_mmu_atst;
   assign axi_iommu_tr_req_o.ar.mmu_valid     = axi_tr_drv_intf.ar_mmu_valid;

   assign axi_tr_drv_intf.aw_stream_id     = axi_tr_drv_intf_dv.aw_stream_id;
   assign axi_tr_drv_intf.aw_ss_id_valid   = axi_tr_drv_intf_dv.aw_ss_id_valid;
   assign axi_tr_drv_intf.aw_substream_id  = axi_tr_drv_intf_dv.aw_substream_id;
   assign axi_tr_drv_intf.aw_mmu_flow      = axi_tr_drv_intf_dv.aw_mmu_flow;
   assign axi_tr_drv_intf.aw_mmu_secsid    = axi_tr_drv_intf_dv.aw_mmu_secsid;
   assign axi_tr_drv_intf.aw_mmu_atst      = axi_tr_drv_intf_dv.aw_mmu_atst;
   assign axi_tr_drv_intf.aw_mmu_valid     = axi_tr_drv_intf_dv.aw_mmu_valid;

   assign axi_tr_drv_intf.ar_stream_id     = axi_tr_drv_intf_dv.ar_stream_id;
   assign axi_tr_drv_intf.ar_ss_id_valid   = axi_tr_drv_intf_dv.ar_ss_id_valid;
   assign axi_tr_drv_intf.ar_substream_id  = axi_tr_drv_intf_dv.ar_substream_id;
   assign axi_tr_drv_intf.ar_mmu_flow      = axi_tr_drv_intf_dv.ar_mmu_flow;
   assign axi_tr_drv_intf.ar_mmu_secsid    = axi_tr_drv_intf_dv.ar_mmu_secsid;
   assign axi_tr_drv_intf.ar_mmu_atst      = axi_tr_drv_intf_dv.ar_mmu_atst;
   assign axi_tr_drv_intf.ar_mmu_valid     = axi_tr_drv_intf_dv.ar_mmu_valid;

   assign iommu_addr   = {3'b000, iommu_intf.addr[$clog2(MEM_DEPTH)-1:3]};
   assign mem_addr     = {3'b000, mem_intf.addr[$clog2(MEM_DEPTH)-1:3]};
   assign tr_comp_addr = {3'b000, tr_comp_intf.addr[$clog2(MEM_DEPTH)-1:3]};

   // -------------------------------------------------
   // Simulation Memories
   // -------------------------------------------------

   // Data Structure Memory
   axi2mem #(
      .AXI_ID_WIDTH   ( ID_WIDTH   ),
      .AXI_ADDR_WIDTH ( ADDR_WIDTH ),
      .AXI_DATA_WIDTH ( DATA_WIDTH ),
      .AXI_USER_WIDTH ( USER_WIDTH )
   ) i_axi2mem_ds (
      .clk_i   ( clk_i           ),
      .rst_ni  ( rst_ni          ),
      .slave   ( axi_ds_drv_intf ),
      .req_o   ( iommu_intf.req   ),
      .we_o    ( iommu_intf.wen   ),
      .addr_o  ( iommu_intf.addr  ),
      .be_o    ( iommu_intf.be    ),
      .data_o  ( iommu_intf.wdata ),
      .data_i  ( iommu_intf.rdata )
   );

   tc_sram #(
      .NumWords  ( MEM_DEPTH  ),
      .DataWidth ( DATA_WIDTH ),
      .NumPorts  ( 2          ),
      .SimInit   ( "zeros"    )
   ) i_data_structure (
      .clk_i   ( clk_i  ),
      .rst_ni  ( rst_ni ),
      .req_i   ( { iommu_intf.req   , mem_intf.req   } ),
      .we_i    ( { iommu_intf.wen   , mem_intf.wen   } ),
      .be_i    ( { iommu_intf.be    , mem_intf.be    } ),
      .wdata_i ( { iommu_intf.wdata , mem_intf.wdata } ),
      .rdata_o ( { iommu_intf.rdata , mem_intf.rdata } ),
      .addr_i  ( { iommu_addr       , mem_addr       } )
   );

   // Translation Completion Memory

   axi2mem #(
      .AXI_ID_WIDTH   ( ID_WIDTH   ),
      .AXI_ADDR_WIDTH ( ADDR_WIDTH ),
      .AXI_DATA_WIDTH ( DATA_WIDTH ),
      .AXI_USER_WIDTH ( USER_WIDTH )
   ) i_axi2mem_tc_comp (
      .clk_i   ( clk_i               ),
      .rst_ni  ( rst_ni              ),
      .slave   ( axi_comp_drv_intf   ),
      .req_o   ( tr_comp_intf.req    ),
      .we_o    ( tr_comp_intf.wen    ),
      .addr_o  ( tr_comp_intf.addr   ),
      .be_o    ( tr_comp_intf.be     ),
      .data_o  ( tr_comp_intf.wdata  ),
      .data_i  ( tr_comp_intf.rdata  )
   );

   tc_sram #(
      .NumWords  ( MEM_DEPTH  ),
      .DataWidth ( DATA_WIDTH ),
      .NumPorts  ( 1          ),
      .SimInit   ( "zeros"    )
   ) i_memory (
      .clk_i   ( clk_i  ),
      .rst_ni  ( rst_ni ),
      .req_i   ( tr_comp_intf.req   ),
      .we_i    ( tr_comp_intf.wen   ),
      .be_i    ( tr_comp_intf.be    ),
      .wdata_i ( tr_comp_intf.wdata ),
      .rdata_o ( tr_comp_intf.rdata ),
      .addr_i  ( tr_comp_addr       )
   );


endmodule
