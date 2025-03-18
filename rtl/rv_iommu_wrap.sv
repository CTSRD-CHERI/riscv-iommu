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
// Author: Manuel Rodríguez <manuel.cederog@gmail.com>
// Date: 20/01/2025
// Acknowledges: SSRC - Technology Innovation Institute (TII)
//
// Description: RISC-V IOMMU Wrapper Module.
//              Instantiates the RISC-V IOMMU module using flat signals.

`include "axi/assign.svh"
`include "axi_stream/typedef.svh"
`include "axi-iommu/typedef.svh"
`include "axi-iommu/assign.svh"

module rv_iommu_wrap #(
    parameter rv_iommu_cfg::rv_iommu_cfg_t RVIOMMUCfg = rv_iommu_cfg::rv_iommu_cfg_t'{
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
    },

    parameter type addr_t = logic[(RVIOMMUCfg.AxiAddrWidth-1):0],
    parameter type data_t = logic[(RVIOMMUCfg.AxiDataWidth-1):0],
    parameter type strb_t = logic[((RVIOMMUCfg.AxiDataWidth/8)-1):0],
    parameter type id_t = logic[(RVIOMMUCfg.AxiIdWidth-1):0],
    parameter type id_prog_t = logic[(RVIOMMUCfg.AxiProgIdWidth-1):0],
    parameter type user_t = logic[(RVIOMMUCfg.AxiUserWidth-1):0],
    parameter type sid_t = logic [(rv_iommu::DevIdWidth-1):0],
    parameter type ssid_t = logic [(rv_iommu::ProcIdWidth-1):0],
    parameter type ssidv_t = logic,
    parameter type mmu_flow_t = logic[1:0],

    parameter type tdata_t  = logic [(RVIOMMUCfg.AxisDataWidth-1):0],
    parameter type tid_t    = logic [(RVIOMMUCfg.AxisIdWidth-1  ):0],
    parameter type tdest_t  = logic [(RVIOMMUCfg.AxisDestWidth-1):0],
    parameter type tuser_t  = logic [(RVIOMMUCfg.AxisUserWidth-1):0],
    parameter type tstrb_t  = logic [(RVIOMMUCfg.AxisStrbWidth-1):0],
    parameter type tkeep_t  = logic [(RVIOMMUCfg.AxisKeepWidth-1):0],
    parameter type tvalid_t = logic,
    parameter type tready_t = logic,
    parameter type tlast_t  = logic
) (
    input logic clk_i,
    input logic rst_ni,

    /*** Translation Request Interface (Slave) ***/
    input  logic                s_axi_tr_awvalid,
    input  id_t                 s_axi_tr_awid,
    input  addr_t               s_axi_tr_awaddr,
    input  axi_pkg::len_t       s_axi_tr_awlen,
    input  axi_pkg::size_t      s_axi_tr_awsize,
    input  axi_pkg::burst_t     s_axi_tr_awburst,
    input  logic                s_axi_tr_awlock,
    input  axi_pkg::cache_t     s_axi_tr_awcache,
    input  axi_pkg::prot_t      s_axi_tr_awprot,
    input  axi_pkg::qos_t       s_axi_tr_awqos,
    input  axi_pkg::region_t    s_axi_tr_awregion,
    input  axi_pkg::atop_t      s_axi_tr_awatop,
    input  user_t               s_axi_tr_awuser,
    input  sid_t                s_axi_tr_aw_stream_id,
    input  ssidv_t              s_axi_tr_aw_ss_id_valid,
    input  ssid_t               s_axi_tr_aw_substream_id,
    input  mmu_flow_t           s_axi_tr_aw_mmu_flow,
    input  logic                s_axi_tr_aw_mmu_secsid,
    input  logic                s_axi_tr_aw_mmu_atst,
    input  logic                s_axi_tr_aw_mmu_valid,

    input  logic                s_axi_tr_wvalid,
    input  data_t               s_axi_tr_wdata,
    input  strb_t               s_axi_tr_wstrb,
    input  logic                s_axi_tr_wlast,
    input  user_t               s_axi_tr_wuser,

    input  logic                s_axi_tr_bready,

    input  logic                s_axi_tr_arvalid,
    input  id_t                 s_axi_tr_arid,
    input  addr_t               s_axi_tr_araddr,
    input  axi_pkg::len_t       s_axi_tr_arlen,
    input  axi_pkg::size_t      s_axi_tr_arsize,
    input  axi_pkg::burst_t     s_axi_tr_arburst,
    input  logic                s_axi_tr_arlock,
    input  axi_pkg::cache_t     s_axi_tr_arcache,
    input  axi_pkg::prot_t      s_axi_tr_arprot,
    input  axi_pkg::qos_t       s_axi_tr_arqos,
    input  axi_pkg::region_t    s_axi_tr_arregion,
    input  user_t               s_axi_tr_aruser,
    input  sid_t                s_axi_tr_ar_stream_id,
    input  ssid_t               s_axi_tr_ar_substream_id,
    input  ssidv_t              s_axi_tr_ar_ss_id_valid,
    input  mmu_flow_t           s_axi_tr_ar_mmu_flow,
    input  logic                s_axi_tr_ar_mmu_secsid,
    input  logic                s_axi_tr_ar_mmu_atst,
    input  logic                s_axi_tr_ar_mmu_valid,


    input  logic                s_axi_tr_rready,

    output logic                s_axi_tr_awready,

    output logic                s_axi_tr_wready,

    output logic                s_axi_tr_bvalid,
    output id_t                 s_axi_tr_bid,
    output axi_pkg::resp_t      s_axi_tr_bresp,
    output user_t               s_axi_tr_buser,

    output logic                s_axi_tr_arready,

    output logic                s_axi_tr_rvalid,
    output id_t                 s_axi_tr_rid,
    output data_t               s_axi_tr_rdata,
    output axi_pkg::resp_t      s_axi_tr_rresp,
    output logic                s_axi_tr_rlast,
    output user_t               s_axi_tr_ruser,

    /*** Completion Interface (Master) ***/
    output logic                m_axi_comp_awvalid,
    output id_t                 m_axi_comp_awid,
    output addr_t               m_axi_comp_awaddr,
    output axi_pkg::len_t       m_axi_comp_awlen,
    output axi_pkg::size_t      m_axi_comp_awsize,
    output axi_pkg::burst_t     m_axi_comp_awburst,
    output logic                m_axi_comp_awlock,
    output axi_pkg::cache_t     m_axi_comp_awcache,
    output axi_pkg::prot_t      m_axi_comp_awprot,
    output axi_pkg::qos_t       m_axi_comp_awqos,
    output axi_pkg::region_t    m_axi_comp_awregion,
    output axi_pkg::atop_t      m_axi_comp_awatop,
    output user_t               m_axi_comp_awuser,

    output logic                m_axi_comp_wvalid,
    output data_t               m_axi_comp_wdata,
    output strb_t               m_axi_comp_wstrb,
    output logic                m_axi_comp_wlast,
    output user_t               m_axi_comp_wuser,

    output logic                m_axi_comp_bready,

    output logic                m_axi_comp_arvalid,
    output id_t                 m_axi_comp_arid,
    output addr_t               m_axi_comp_araddr,
    output axi_pkg::len_t       m_axi_comp_arlen,
    output axi_pkg::size_t      m_axi_comp_arsize,
    output axi_pkg::burst_t     m_axi_comp_arburst,
    output logic                m_axi_comp_arlock,
    output axi_pkg::cache_t     m_axi_comp_arcache,
    output axi_pkg::prot_t      m_axi_comp_arprot,
    output axi_pkg::qos_t       m_axi_comp_arqos,
    output axi_pkg::region_t    m_axi_comp_arregion,
    output user_t               m_axi_comp_aruser,

    output logic                m_axi_comp_rready,

    input  logic                m_axi_comp_awready,

    input  logic                m_axi_comp_wready,

    input  logic                m_axi_comp_bvalid,
    input  id_t                 m_axi_comp_bid,
    input  axi_pkg::resp_t      m_axi_comp_bresp,
    input  logic                m_axi_comp_buser,

    input  logic                m_axi_comp_arready,

    input  logic                m_axi_comp_rvalid,
    input  id_t                 m_axi_comp_rid,
    input  data_t               m_axi_comp_rdata,
    input  axi_pkg::resp_t      m_axi_comp_rresp,
    input  logic                m_axi_comp_rlast,
    input  logic                m_axi_comp_ruser,

    /*** Data Structures Interface (Master) ***/
    output logic                m_axi_ds_awvalid,
    output id_t                 m_axi_ds_awid,
    output addr_t               m_axi_ds_awaddr,
    output axi_pkg::len_t       m_axi_ds_awlen,
    output axi_pkg::size_t      m_axi_ds_awsize,
    output axi_pkg::burst_t     m_axi_ds_awburst,
    output logic                m_axi_ds_awlock,
    output axi_pkg::cache_t     m_axi_ds_awcache,
    output axi_pkg::prot_t      m_axi_ds_awprot,
    output axi_pkg::qos_t       m_axi_ds_awqos,
    output axi_pkg::region_t    m_axi_ds_awregion,
    output user_t               m_axi_ds_awuser,
    output axi_pkg::atop_t      m_axi_ds_awatop,

    output logic                m_axi_ds_wvalid,
    output data_t               m_axi_ds_wdata,
    output strb_t               m_axi_ds_wstrb,
    output logic                m_axi_ds_wlast,
    output user_t               m_axi_ds_wuser,

    output logic                m_axi_ds_bready,

    output logic                m_axi_ds_arvalid,
    output id_t                 m_axi_ds_arid,
    output addr_t               m_axi_ds_araddr,
    output axi_pkg::len_t       m_axi_ds_arlen,
    output axi_pkg::size_t      m_axi_ds_arsize,
    output axi_pkg::burst_t     m_axi_ds_arburst,
    output logic                m_axi_ds_arlock,
    output axi_pkg::cache_t     m_axi_ds_arcache,
    output axi_pkg::prot_t      m_axi_ds_arprot,
    output axi_pkg::qos_t       m_axi_ds_arqos,
    output axi_pkg::region_t    m_axi_ds_arregion,
    output user_t               m_axi_ds_aruser,

    output logic                m_axi_ds_rready,

    input  logic                m_axi_ds_awready,

    input  logic                m_axi_ds_wready,

    input  logic                m_axi_ds_bvalid,
    input  id_t                 m_axi_ds_bid,
    input  axi_pkg::resp_t      m_axi_ds_bresp,
    input  logic                m_axi_ds_buser,

    input  logic                m_axi_ds_arready,

    input  logic                m_axi_ds_rvalid,
    input  id_t                 m_axi_ds_rid,
    input  data_t               m_axi_ds_rdata,
    input  axi_pkg::resp_t      m_axi_ds_rresp,
    input  logic                m_axi_ds_rlast,
    input  logic                m_axi_ds_ruser,

    /*** Programming Interface (Slave) ***/
    input  logic                s_axi_prog_awvalid,
    input  id_prog_t            s_axi_prog_awid,
    input  addr_t               s_axi_prog_awaddr,
    input  axi_pkg::len_t       s_axi_prog_awlen,
    input  axi_pkg::size_t      s_axi_prog_awsize,
    input  axi_pkg::burst_t     s_axi_prog_awburst,
    input  logic                s_axi_prog_awlock,
    input  axi_pkg::cache_t     s_axi_prog_awcache,
    input  axi_pkg::prot_t      s_axi_prog_awprot,
    input  axi_pkg::qos_t       s_axi_prog_awqos,
    input  axi_pkg::region_t    s_axi_prog_awregion,
    input  axi_pkg::atop_t      s_axi_prog_awatop,
    input  user_t               s_axi_prog_awuser,

    input  logic                s_axi_prog_wvalid,
    input  data_t               s_axi_prog_wdata,
    input  strb_t               s_axi_prog_wstrb,
    input  logic                s_axi_prog_wlast,
    input  user_t               s_axi_prog_wuser,

    input  logic                s_axi_prog_bready,

    input  logic                s_axi_prog_arvalid,
    input  id_prog_t            s_axi_prog_arid,
    input  addr_t               s_axi_prog_araddr,
    input  axi_pkg::len_t       s_axi_prog_arlen,
    input  axi_pkg::size_t      s_axi_prog_arsize,
    input  axi_pkg::burst_t     s_axi_prog_arburst,
    input  logic                s_axi_prog_arlock,
    input  axi_pkg::cache_t     s_axi_prog_arcache,
    input  axi_pkg::prot_t      s_axi_prog_arprot,
    input  axi_pkg::qos_t       s_axi_prog_arqos,
    input  axi_pkg::region_t    s_axi_prog_arregion,
    input  user_t               s_axi_prog_aruser,

    input  logic                s_axi_prog_rready,

    output logic                s_axi_prog_awready,

    output logic                s_axi_prog_wready,

    output logic                s_axi_prog_bvalid,
    output id_prog_t            s_axi_prog_bid,
    output axi_pkg::resp_t      s_axi_prog_bresp,
    output user_t               s_axi_prog_buser,

    output logic                s_axi_prog_arready,

    output logic                s_axi_prog_rvalid,
    output id_prog_t            s_axi_prog_rid,
    output data_t               s_axi_prog_rdata,
    output axi_pkg::resp_t      s_axi_prog_rresp,
    output logic                s_axi_prog_rlast,
    output user_t               s_axi_prog_ruser,

    /*** AXI Stream Upstream Interface (Master) ***/
    output tvalid_t             m_axis_upstream_tvalid,
    output tdata_t              m_axis_upstream_tdata,
    output tstrb_t              m_axis_upstream_tstrb,
    output tuser_t              m_axis_upstream_tuser,
    output tkeep_t              m_axis_upstream_tkeep,
    output tid_t                m_axis_upstream_tid,
    output tdest_t              m_axis_upstream_tdest,
    output tlast_t              m_axis_upstream_tlast,
    input  tready_t             m_axis_upstream_tready,

    /*** AXI Stream Downstream Interface (Slave) ***/
    input  tvalid_t             s_axis_downstream_tvalid,
    input  tdata_t              s_axis_downstream_tdata,
    input  tstrb_t              s_axis_downstream_tstrb,
    input  tuser_t              s_axis_downstream_tuser,
    input  tkeep_t              s_axis_downstream_tkeep,
    input  tid_t                s_axis_downstream_tid,
    input  tdest_t              s_axis_downstream_tdest,
    input  tlast_t              s_axis_downstream_tlast,
    output tready_t             s_axis_downstream_tready,

    /*** Interrupt wires ***/
    output logic [RVIOMMUCfg.NumIntVec-1:0] wsi_wires_o
);

    `AXI_TYPEDEF_EXT_ALL(axi_tr, addr_t, id_t, data_t, strb_t, user_t,
                            sid_t, ssidv_t, ssid_t)
    axi_tr_req_t axi_iommu_tr_req;
    axi_tr_resp_t axi_iommu_tr_resp;

    `AXI_TYPEDEF_ALL(axi_comp, addr_t, id_t, data_t, strb_t, user_t)
    axi_comp_req_t  axi_iommu_comp_req;
    axi_comp_resp_t axi_iommu_comp_resp;

    `AXI_TYPEDEF_ALL(axi_ds, addr_t, id_t, data_t, strb_t, user_t)
    axi_ds_req_t  axi_iommu_ds_req;
    axi_ds_resp_t axi_iommu_ds_resp;

    `AXI_TYPEDEF_ALL(axi_prog, addr_t, id_prog_t, data_t, strb_t, user_t)
    axi_prog_req_t axi_iommu_prog_req;
    axi_prog_resp_t axi_iommu_prog_resp;

    // AXI Stream Strucutre
    `AXI_STREAM_TYPEDEF_ALL(axis, tdata_t, tstrb_t, tkeep_t, tid_t, tdest_t, tuser_t)
    axis_req_t ats_axis_upstream_req,  ats_axis_downstream_req;
    axis_rsp_t ats_axis_upstream_resp, ats_axis_downstream_resp;

    // Connect flat module wires to interface structs
    `AXI_ASSIGN_SLAVE_TO_FLAT(tr, axi_iommu_tr_req, axi_iommu_tr_resp)
    `AXI_ASSIGN_MASTER_TO_FLAT(comp, axi_iommu_comp_req, axi_iommu_comp_resp)
    `AXI_ASSIGN_MASTER_TO_FLAT(ds, axi_iommu_ds_req, axi_iommu_ds_resp)
    `AXI_ASSIGN_SLAVE_TO_FLAT(prog, axi_iommu_prog_req, axi_iommu_prog_resp)

    // Connect ATS AXI Stream structure
    `AXI_STREAM_ASSIGN_MASTER_TO_FLAT(upstream, ats_axis_upstream_req, ats_axis_upstream_resp)
    `AXI_STREAM_ASSIGN_SLAVE_TO_FLAT(downstream, ats_axis_downstream_req, ats_axis_downstream_resp)

    assign axi_iommu_tr_req.aw.atop = s_axi_tr_awatop;
    assign axi_iommu_prog_req.aw.atop = s_axi_prog_awatop;
    assign m_axi_comp_awatop = axi_iommu_comp_req.aw.atop;
    assign m_axi_ds_awatop = axi_iommu_ds_req.aw.atop;

    assign axi_iommu_tr_req.ar.stream_id = s_axi_tr_ar_stream_id;
    assign axi_iommu_tr_req.ar.substream_id = s_axi_tr_ar_substream_id;
    assign axi_iommu_tr_req.ar.ss_id_valid = s_axi_tr_ar_ss_id_valid;
    assign axi_iommu_tr_req.ar.mmu_flow = s_axi_tr_aw_mmu_flow;
    assign axi_iommu_tr_req.ar.mmu_atst = s_axi_tr_aw_mmu_atst;
    assign axi_iommu_tr_req.ar.mmu_valid = s_axi_tr_aw_mmu_valid;
    assign axi_iommu_tr_req.ar.mmu_secsid = s_axi_tr_aw_mmu_secsid;

    assign axi_iommu_tr_req.aw.stream_id = s_axi_tr_aw_stream_id;
    assign axi_iommu_tr_req.aw.substream_id = s_axi_tr_aw_substream_id;
    assign axi_iommu_tr_req.aw.ss_id_valid = s_axi_tr_aw_ss_id_valid;
    assign axi_iommu_tr_req.aw.mmu_flow = s_axi_tr_aw_mmu_flow;
    assign axi_iommu_tr_req.aw.mmu_atst = s_axi_tr_aw_mmu_atst;
    assign axi_iommu_tr_req.aw.mmu_valid = s_axi_tr_aw_mmu_valid;
    assign axi_iommu_tr_req.aw.mmu_secsid = s_axi_tr_aw_mmu_secsid;

    //--------------
    // RISC-V IOMMU
    //--------------
    rv_iommu_top #(
        .RVIOMMUCfg         (RVIOMMUCfg),

        .axi_tr_aw_chan_t   (axi_tr_aw_chan_t),
        .axi_tr_w_chan_t    (axi_tr_w_chan_t),
        .axi_tr_b_chan_t    (axi_tr_b_chan_t),
        .axi_tr_ar_chan_t   (axi_tr_ar_chan_t),
        .axi_tr_r_chan_t    (axi_tr_r_chan_t),
        .axi_tr_req_t       (axi_tr_req_t),
        .axi_tr_resp_t      (axi_tr_resp_t),
        
        .axi_comp_aw_chan_t (axi_comp_aw_chan_t),
        .axi_comp_w_chan_t  (axi_comp_w_chan_t),
        .axi_comp_b_chan_t  (axi_comp_b_chan_t),
        .axi_comp_ar_chan_t (axi_comp_ar_chan_t),
        .axi_comp_r_chan_t  (axi_comp_r_chan_t),
        .axi_comp_req_t     (axi_comp_req_t),
        .axi_comp_resp_t    (axi_comp_resp_t),

        .axi_ds_aw_chan_t   (axi_ds_aw_chan_t),
        .axi_ds_w_chan_t    (axi_ds_w_chan_t),
        .axi_ds_b_chan_t    (axi_ds_b_chan_t),
        .axi_ds_ar_chan_t   (axi_ds_ar_chan_t),
        .axi_ds_r_chan_t    (axi_ds_r_chan_t),
        .axi_ds_req_t       (axi_ds_req_t),
        .axi_ds_resp_t      (axi_ds_resp_t),
        
        .axi_prog_aw_chan_t (axi_prog_aw_chan_t),
        .axi_prog_w_chan_t  (axi_prog_w_chan_t),
        .axi_prog_b_chan_t  (axi_prog_b_chan_t),
        .axi_prog_ar_chan_t (axi_prog_ar_chan_t),
        .axi_prog_r_chan_t  (axi_prog_r_chan_t),
        .axi_prog_req_t     (axi_prog_req_t),
        .axi_prog_resp_t    (axi_prog_resp_t),

        .axis_req_t         (axis_req_t),
        .axis_rsp_t         (axis_rsp_t)
    ) i_riscv_iommu (
        .clk_i                 (clk_i),
        .rst_ni                (rst_ni),
        .tr_req_i              (axi_iommu_tr_req),
        .tr_resp_o             (axi_iommu_tr_resp),
        .comp_resp_i           (axi_iommu_comp_resp),
        .comp_req_o            (axi_iommu_comp_req),
        .ds_resp_i             (axi_iommu_ds_resp),
        .ds_req_o              (axi_iommu_ds_req),
        .prog_req_i            (axi_iommu_prog_req),
        .prog_resp_o           (axi_iommu_prog_resp),
        .ats_upstream_req_o    (ats_axis_upstream_req),
        .ats_upstream_resp_i   (ats_axis_upstream_resp),
        .ats_downstream_req_i  (ats_axis_downstream_req),
        .ats_downstream_resp_o (ats_axis_downstream_resp),
        .wsi_wires_o           (wsi_wires_o)
    );
    
endmodule
