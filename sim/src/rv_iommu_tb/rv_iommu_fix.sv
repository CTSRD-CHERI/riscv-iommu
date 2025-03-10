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
// Description: Fixture including the DuT, tasks and processes for testing.
//

`timescale 1ps/1ps

`include "axi_stream/typedef.svh"
`include "axi_stream/assign.svh"

`include "axi-iommu/typedef.svh"
`include "axi-iommu/assign.svh"

module rv_iommu_top_fix;

   import rv_iommu_dti_ats_pkg::*;
   import rv_iommu_cfg::*;

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
        AxisDataWidth       : 32'd160,
        AxisUserWidth       : 32'd1,
        AxisKeepWidth       : 32'd20,
        AxisStrbWidth       : 32'd20,
        AxisIdWidth         : 32'd1,
        AxisDestWidth       : 32'd1
   };
   // -------------------------------------------------
   // Parameters
   // -------------------------------------------------
   localparam int unsigned REFClockPeriod = 5ns; // 200MHz

   localparam type addr_t    = logic[(RVIOMMUCfg.AxiAddrWidth-1):0];
   localparam type data_t    = logic[(RVIOMMUCfg.AxiDataWidth-1):0];
   localparam type strb_t    = logic[((RVIOMMUCfg.AxiDataWidth/8)-1):0];
   localparam type id_t      = logic[(RVIOMMUCfg.AxiIdWidth-1):0];
   localparam type id_prog_t = logic[(RVIOMMUCfg.AxiProgIdWidth-1):0];
   localparam type user_t    = logic[(RVIOMMUCfg.AxiUserWidth-1):0];
   localparam type sid_t     = logic[(rv_iommu::DevIdWidth-1):0];
   localparam type ssid_t    = logic[(rv_iommu::ProcIdWidth-1):0];
   localparam type ssidv_t   = logic;


   // AXI Stream parameters
   localparam int unsigned DATA_WIDTH = 160;
   localparam int unsigned KEEP_WIDTH = DATA_WIDTH/8;
   localparam int unsigned STRB_WIDTH = DATA_WIDTH/8;
   localparam int unsigned ID_WIDTH   = 1;
   localparam int unsigned DEST_WIDTH = 1;
   localparam int unsigned USER_WIDTH = 1;

   localparam int unsigned NUM_INV       = 16;
   localparam int unsigned NUM_REP       = 1;
   localparam int unsigned NUM_TRANS_REQ = 50;

   typedef logic                  tvalid_t;
   typedef logic [DATA_WIDTH-1:0] tdata_t;
   typedef logic [ID_WIDTH-1:0]   tid_t;
   typedef logic [DEST_WIDTH-1:0] tdest_t;
   typedef logic [USER_WIDTH-1:0] tuser_t;
   typedef logic [STRB_WIDTH-1:0] tstrb_t;
   typedef logic [KEEP_WIDTH-1:0] tkeep_t;
   typedef logic                  tready_t;
   typedef logic                  tlast_t;

   `AXI_STREAM_TYPEDEF_ALL(axis, tdata_t, tstrb_t, tkeep_t, tid_t, tdest_t, tuser_t)
   `AXI_TYPEDEF_EXT_ALL(axi_tr, addr_t, id_t, data_t, strb_t, user_t, sid_t, ssidv_t, ssid_t)
   `AXI_TYPEDEF_ALL(axi_comp, addr_t, id_t, data_t, strb_t, user_t)
   `AXI_TYPEDEF_ALL(axi_prog, addr_t, id_prog_t, data_t, strb_t, user_t)
   `AXI_TYPEDEF_ALL(axi_ds, addr_t, id_t, data_t, strb_t, user_t)

   axis_req_t axis_mst_req, axis_slv_req;
   axis_rsp_t axis_mst_rsp, axis_slv_rsp;

   axi_tr_req_t    axi_iommu_tr_req;
   axi_tr_resp_t   axi_iommu_tr_resp;

   axi_comp_req_t  axi_iommu_comp_req;
   axi_comp_resp_t axi_iommu_comp_resp;

   axi_ds_req_t    axi_iommu_ds_req;
   axi_ds_resp_t   axi_iommu_ds_resp;

   axi_prog_req_t  axi_iommu_prog_req;
   axi_prog_resp_t axi_iommu_prog_resp;

   // For con/dis connect
   dti_ats_condis_req_s  condis_con_req, condis_discon_req;
   dti_ats_condis_ack_s  condis_con_ack, condis_discon_ack;

   // For ATS translation request
   dti_ats_trans_req_s trans_req_pcie;
   dti_ats_trans_resp_s dti_trans_resp;

   // -------------------------------------------------
   // DUT IO Signals
   // -------------------------------------------------
   logic clk_i;
   logic rst_ni;

   /*** Translation Request Interface (Slave) ***/
   logic                s_axi_tr_awvalid;
   id_t                 s_axi_tr_awid;
   addr_t               s_axi_tr_awaddr;
   axi_pkg::len_t       s_axi_tr_awlen;
   axi_pkg::size_t      s_axi_tr_awsize;
   axi_pkg::burst_t     s_axi_tr_awburst;
   logic                s_axi_tr_awlock;
   axi_pkg::cache_t     s_axi_tr_awcache;
   axi_pkg::prot_t      s_axi_tr_awprot;
   axi_pkg::qos_t       s_axi_tr_awqos;
   axi_pkg::region_t    s_axi_tr_awregion;
   axi_pkg::atop_t      s_axi_tr_awatop;
   user_t               s_axi_tr_awuser;
   sid_t                s_axi_tr_aw_stream_id;
   ssid_t               s_axi_tr_aw_substream_id;
   ssidv_t              s_axi_tr_aw_ss_id_valid;
   logic                s_axi_tr_wvalid;
   data_t               s_axi_tr_wdata;
   strb_t               s_axi_tr_wstrb;
   logic                s_axi_tr_wlast;
   user_t               s_axi_tr_wuser;
   logic                s_axi_tr_bready;
   logic                s_axi_tr_arvalid;
   id_t                 s_axi_tr_arid;
   addr_t               s_axi_tr_araddr;
   axi_pkg::len_t       s_axi_tr_arlen;
   axi_pkg::size_t      s_axi_tr_arsize;
   axi_pkg::burst_t     s_axi_tr_arburst;
   logic                s_axi_tr_arlock;
   axi_pkg::cache_t     s_axi_tr_arcache;
   axi_pkg::prot_t      s_axi_tr_arprot;
   axi_pkg::qos_t       s_axi_tr_arqos;
   axi_pkg::region_t    s_axi_tr_arregion;
   user_t               s_axi_tr_aruser;
   sid_t                s_axi_tr_ar_stream_id;
   ssid_t               s_axi_tr_ar_substream_id;
   ssidv_t              s_axi_tr_ar_ss_id_valid;
   logic                s_axi_tr_rready;
   logic                s_axi_tr_awready;
   logic                s_axi_tr_wready;
   logic                s_axi_tr_bvalid;
   id_t                 s_axi_tr_bid;
   axi_pkg::resp_t      s_axi_tr_bresp;
   user_t               s_axi_tr_buser;
   logic                s_axi_tr_arready;
   logic                s_axi_tr_rvalid;
   id_t                 s_axi_tr_rid;
   data_t               s_axi_tr_rdata;
   axi_pkg::resp_t      s_axi_tr_rresp;
   logic                s_axi_tr_rlast;
   user_t               s_axi_tr_ruser;

   /*** Completion Interface (Master) ***/
   logic                m_axi_comp_awvalid;
   id_t                 m_axi_comp_awid;
   addr_t               m_axi_comp_awaddr;
   axi_pkg::len_t       m_axi_comp_awlen;
   axi_pkg::size_t      m_axi_comp_awsize;
   axi_pkg::burst_t     m_axi_comp_awburst;
   logic                m_axi_comp_awlock;
   axi_pkg::cache_t     m_axi_comp_awcache;
   axi_pkg::prot_t      m_axi_comp_awprot;
   axi_pkg::qos_t       m_axi_comp_awqos;
   axi_pkg::region_t    m_axi_comp_awregion;
   axi_pkg::atop_t      m_axi_comp_awatop;
   user_t               m_axi_comp_awuser;
   logic                m_axi_comp_wvalid;
   data_t               m_axi_comp_wdata;
   strb_t               m_axi_comp_wstrb;
   logic                m_axi_comp_wlast;
   user_t               m_axi_comp_wuser;
   logic                m_axi_comp_bready;
   logic                m_axi_comp_arvalid;
   id_t                 m_axi_comp_arid;
   addr_t               m_axi_comp_araddr;
   axi_pkg::len_t       m_axi_comp_arlen;
   axi_pkg::size_t      m_axi_comp_arsize;
   axi_pkg::burst_t     m_axi_comp_arburst;
   logic                m_axi_comp_arlock;
   axi_pkg::cache_t     m_axi_comp_arcache;
   axi_pkg::prot_t      m_axi_comp_arprot;
   axi_pkg::qos_t       m_axi_comp_arqos;
   axi_pkg::region_t    m_axi_comp_arregion;
   user_t               m_axi_comp_aruser;
   logic                m_axi_comp_rready;
   logic                m_axi_comp_awready;
   logic                m_axi_comp_wready;
   logic                m_axi_comp_bvalid;
   id_t                 m_axi_comp_bid;
   axi_pkg::resp_t      m_axi_comp_bresp;
   logic                m_axi_comp_buser;
   logic                m_axi_comp_arready;
   logic                m_axi_comp_rvalid;
   id_t                 m_axi_comp_rid;
   data_t               m_axi_comp_rdata;
   axi_pkg::resp_t      m_axi_comp_rresp;
   logic                m_axi_comp_rlast;
   logic                m_axi_comp_ruser;

   /*** Data Structures Interface (Master) ***/
   logic                m_axi_ds_awvalid;
   id_t                 m_axi_ds_awid;
   addr_t               m_axi_ds_awaddr;
   axi_pkg::len_t       m_axi_ds_awlen;
   axi_pkg::size_t      m_axi_ds_awsize;
   axi_pkg::burst_t     m_axi_ds_awburst;
   logic                m_axi_ds_awlock;
   axi_pkg::cache_t     m_axi_ds_awcache;
   axi_pkg::prot_t      m_axi_ds_awprot;
   axi_pkg::qos_t       m_axi_ds_awqos;
   axi_pkg::region_t    m_axi_ds_awregion;
   user_t               m_axi_ds_awuser;
   axi_pkg::atop_t      m_axi_ds_awatop;
   logic                m_axi_ds_wvalid;
   data_t               m_axi_ds_wdata;
   strb_t               m_axi_ds_wstrb;
   logic                m_axi_ds_wlast;
   user_t               m_axi_ds_wuser;
   logic                m_axi_ds_bready;
   logic                m_axi_ds_arvalid;
   id_t                 m_axi_ds_arid;
   addr_t               m_axi_ds_araddr;
   axi_pkg::len_t       m_axi_ds_arlen;
   axi_pkg::size_t      m_axi_ds_arsize;
   axi_pkg::burst_t     m_axi_ds_arburst;
   logic                m_axi_ds_arlock;
   axi_pkg::cache_t     m_axi_ds_arcache;
   axi_pkg::prot_t      m_axi_ds_arprot;
   axi_pkg::qos_t       m_axi_ds_arqos;
   axi_pkg::region_t    m_axi_ds_arregion;
   user_t               m_axi_ds_aruser;
   logic                m_axi_ds_rready;
   logic                m_axi_ds_awready;
   logic                m_axi_ds_wready;
   logic                m_axi_ds_bvalid;
   id_t                 m_axi_ds_bid;
   axi_pkg::resp_t      m_axi_ds_bresp;
   logic                m_axi_ds_buser;
   logic                m_axi_ds_arready;
   logic                m_axi_ds_rvalid;
   id_t                 m_axi_ds_rid;
   data_t               m_axi_ds_rdata;
   axi_pkg::resp_t      m_axi_ds_rresp;
   logic                m_axi_ds_rlast;
   logic                m_axi_ds_ruser;

   /*** Programming Interface (Slave) ***/
   logic                s_axi_prog_awvalid;
   id_prog_t            s_axi_prog_awid;
   addr_t               s_axi_prog_awaddr;
   axi_pkg::len_t       s_axi_prog_awlen;
   axi_pkg::size_t      s_axi_prog_awsize;
   axi_pkg::burst_t     s_axi_prog_awburst;
   logic                s_axi_prog_awlock;
   axi_pkg::cache_t     s_axi_prog_awcache;
   axi_pkg::prot_t      s_axi_prog_awprot;
   axi_pkg::qos_t       s_axi_prog_awqos;
   axi_pkg::region_t    s_axi_prog_awregion;
   axi_pkg::atop_t      s_axi_prog_awatop;
   user_t               s_axi_prog_awuser;
   logic                s_axi_prog_wvalid;
   data_t               s_axi_prog_wdata;
   strb_t               s_axi_prog_wstrb;
   logic                s_axi_prog_wlast;
   user_t               s_axi_prog_wuser;
   logic                s_axi_prog_bready;
   logic                s_axi_prog_arvalid;
   id_prog_t            s_axi_prog_arid;
   addr_t               s_axi_prog_araddr;
   axi_pkg::len_t       s_axi_prog_arlen;
   axi_pkg::size_t      s_axi_prog_arsize;
   axi_pkg::burst_t     s_axi_prog_arburst;
   logic                s_axi_prog_arlock;
   axi_pkg::cache_t     s_axi_prog_arcache;
   axi_pkg::prot_t      s_axi_prog_arprot;
   axi_pkg::qos_t       s_axi_prog_arqos;
   axi_pkg::region_t    s_axi_prog_arregion;
   user_t               s_axi_prog_aruser;
   logic                s_axi_prog_rready;
   logic                s_axi_prog_awready;
   logic                s_axi_prog_wready;
   logic                s_axi_prog_bvalid;
   id_prog_t            s_axi_prog_bid;
   axi_pkg::resp_t      s_axi_prog_bresp;
   user_t               s_axi_prog_buser;
   logic                s_axi_prog_arready;
   logic                s_axi_prog_rvalid;
   id_prog_t            s_axi_prog_rid;
   data_t               s_axi_prog_rdata;
   axi_pkg::resp_t      s_axi_prog_rresp;
   logic                s_axi_prog_rlast;
   user_t               s_axi_prog_ruser;

   /*** AXI Stream Upstream Interface (Master) ***/
   tvalid_t             m_axis_upstream_tvalid;
   tdata_t              m_axis_upstream_tdata;
   tstrb_t              m_axis_upstream_tstrb;
   tuser_t              m_axis_upstream_tuser;
   tkeep_t              m_axis_upstream_tkeep;
   tid_t                m_axis_upstream_tid;
   tdest_t              m_axis_upstream_tdest;
   tlast_t              m_axis_upstream_tlast;
   tready_t             m_axis_upstream_tready;

   tvalid_t             s_axis_downstream_tvalid;
   tdata_t              s_axis_downstream_tdata;
   tstrb_t              s_axis_downstream_tstrb;
   tuser_t              s_axis_downstream_tuser;
   tkeep_t              s_axis_downstream_tkeep;
   tid_t                s_axis_downstream_tid;
   tdest_t              s_axis_downstream_tdest;
   tlast_t              s_axis_downstream_tlast;
   tready_t             s_axis_downstream_tready;

   /*** Interrupt wires ***/
   logic [RVIOMMUCfg.NumIntVec-1:0] wsi_wires_o;

   //-------------------------------------------------
   // Assignments
   //-------------------------------------------------

   // Connect flat module wires to interface structs
   `AXI_ASSIGN_FLAT_TO_SLAVE(tr, axi_iommu_tr_req, axi_iommu_tr_resp)
   `AXI_ASSIGN_FLAT_TO_MASTER(comp, axi_iommu_comp_req, axi_iommu_comp_resp)
   `AXI_ASSIGN_FLAT_TO_MASTER(ds, axi_iommu_ds_req, axi_iommu_ds_resp)
   `AXI_ASSIGN_FLAT_TO_SLAVE(prog, axi_iommu_prog_req, axi_iommu_prog_resp)
   `AXI_STREAM_ASSIGN_FLAT_TO_SLAVE(downstream, axis_mst_req, axis_mst_rsp )
   `AXI_STREAM_ASSIGN_FLAT_TO_MASTER(upstream, axis_slv_req, axis_slv_rsp)

   assign s_axi_tr_awatop   = axi_iommu_tr_req.aw.atop;
   assign s_axi_prog_awatop = axi_iommu_prog_req.aw.atop;
   assign axi_iommu_comp_req.aw.atop = m_axi_comp_awatop;
   assign axi_iommu_ds_req.aw.atop   = m_axi_ds_awatop;

   assign s_axi_tr_ar_stream_id    = axi_iommu_tr_req.ar.stream_id;
   assign s_axi_tr_ar_substream_id = axi_iommu_tr_req.ar.substream_id;
   assign s_axi_tr_ar_ss_id_valid  = axi_iommu_tr_req.ar.ss_id_valid;

   assign s_axi_tr_aw_stream_id    = axi_iommu_tr_req.aw.stream_id;
   assign s_axi_tr_aw_substream_id = axi_iommu_tr_req.aw.substream_id;
   assign s_axi_tr_aw_ss_id_valid  = axi_iommu_tr_req.aw.ss_id_valid;

   // -------------------------------------------------
   // PCIe: ATS-DTI Verification IP
   // -------------------------------------------------
   pcie_ats_vip #(
     .DATA_WIDTH     ( DATA_WIDTH     ),
     .ID_WIDTH       ( ID_WIDTH       ),
     .DEST_WIDTH     ( DEST_WIDTH     ),
     .USER_WIDTH     ( USER_WIDTH     ),
     .REFClockPeriod ( REFClockPeriod ),
     .axis_req_t( axis_req_t ),
     .axis_rsp_t( axis_rsp_t )
   ) i_pcie_vip (
     .clk_i        ( clk_i        ),
     .rst_ni       ( rst_ni       ),
     .axis_mst_req ( axis_mst_req ),
     .axis_mst_rsp ( axis_mst_rsp ),
     .axis_slv_req ( axis_slv_req ),
     .axis_slv_rsp ( axis_slv_rsp )
   );

   // -------------------------------------------------
   // IOMMU Verification IP
   // -------------------------------------------------
   rv_iommu_vip #(
     .DATA_WIDTH      ( RVIOMMUCfg.AxiDataWidth ),
     .ID_WIDTH        ( RVIOMMUCfg.AxiIdWidth   ),
     .ADDR_WIDTH      ( RVIOMMUCfg.AxiAddrWidth ),
     .USER_WIDTH      ( RVIOMMUCfg.AxiUserWidth ),
     .REFClockPeriod  ( REFClockPeriod  ),
     .axi_tr_req_t    ( axi_tr_req_t    ),
     .axi_tr_resp_t   ( axi_tr_resp_t   ),
     .axi_comp_req_t  ( axi_comp_req_t  ),
     .axi_comp_resp_t ( axi_comp_resp_t ),
     .axi_ds_req_t    ( axi_ds_req_t    ),
     .axi_ds_resp_t   ( axi_ds_resp_t   ),
     .axi_prog_req_t  ( axi_prog_req_t  ),
     .axi_prog_resp_t ( axi_prog_resp_t )
   ) i_rv_iommu_vip (
     .clk_i  ( clk_i  ),
     .rst_ni ( rst_ni ),
     // Translation Request Interface
     .axi_iommu_tr_req_o    ( axi_iommu_tr_req    ),
     .axi_iommu_tr_resp_i   ( axi_iommu_tr_resp   ),
     // Translation Completion Interface
     .axi_iommu_comp_req_i  ( axi_iommu_comp_req  ),
     .axi_iommu_comp_resp_o ( axi_iommu_comp_resp ),
     // Data Structure Interface
     .axi_iommu_ds_req_i    ( axi_iommu_ds_req    ),
     .axi_iommu_ds_resp_o   ( axi_iommu_ds_resp   ),
     // Programming Interface
     .axi_iommu_prog_req_o  ( axi_iommu_prog_req  ),
     .axi_iommu_prog_resp_i ( axi_iommu_prog_resp )
   );

   // -------------------------------------------------
   // DUT Instance
   // -------------------------------------------------
   rv_iommu_wrap #(
     .RVIOMMUCfg(RVIOMMUCfg)
   ) DuT (
     .clk_i  (clk_i),
     .rst_ni (rst_ni),
     .*
   );

   // -------------------------------------------------
   // Clock and Reset
   // -------------------------------------------------
   initial begin
     clk_i = 1'b0;
     forever #(REFClockPeriod/2) clk_i = ~clk_i;
   end

   initial begin
     rst_ni = 1'b0;
     repeat(100) @(posedge clk_i);
     rst_ni = 1'b1;
   end

   // -------------------------------------------------
   // Tasks and Functions
   // -------------------------------------------------

   // -------------------------------------------------
   // DTI Translation Request Test
   // -------------------------------------------------
   task automatic dti_translation_request();
     // Wait for reset
     wait(rst_ni);
     @(posedge clk_i);

     i_pcie_vip.reset();
     repeat(30) @(posedge clk_i);

     // 1) Perform Connect using the DTI-ATS VIP
     i_pcie_vip.do_connect(condis_con_req, condis_con_ack);
     $display("[TB] ---- Connect Done ----");
     repeat(20) @(posedge clk_i);

     fork
       begin : f1
         // Send N translation requests (PCIe->DTI)
         i_pcie_vip.send_n_trans_requests(NUM_TRANS_REQ, trans_req_pcie);
       end

       begin : f2
         // The final ATS translation responses come out on the slave AXI
         i_pcie_vip.receive_dti_translation_responses(
           NUM_TRANS_REQ, dti_trans_resp
         );
       end
     join

     repeat(20) @(posedge clk_i);    // 4) Disconnect
     i_pcie_vip.do_disconnect(condis_discon_req, condis_discon_ack);
     $display("[TB] ---- Disconnect Done ----");
   endtask

endmodule
