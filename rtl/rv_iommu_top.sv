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
// Description: RISC-V IOMMU Top Module.

`include "register_interface/typedef.svh"

module rv_iommu_top #(
    /// RISC-V IOMMU configuration struct
    parameter rv_iommu_cfg::rv_iommu_cfg_t RVIOMMUCfg = rv_iommu_cfg::NullCfg,

    /*** Translation Request Interface ***/
    parameter type axi_tr_aw_chan_t     = logic,
    parameter type axi_tr_w_chan_t      = logic,
    parameter type axi_tr_b_chan_t      = logic,
    parameter type axi_tr_ar_chan_t     = logic,
    parameter type axi_tr_r_chan_t      = logic,

    parameter type axi_tr_req_t         = logic,
    parameter type axi_tr_resp_t        = logic,

    /*** Completion Interface ***/
    parameter type axi_comp_aw_chan_t   = logic,
    parameter type axi_comp_w_chan_t    = logic,
    parameter type axi_comp_b_chan_t    = logic,
    parameter type axi_comp_ar_chan_t   = logic,
    parameter type axi_comp_r_chan_t    = logic,

    parameter type axi_comp_req_t       = logic,
    parameter type axi_comp_resp_t      = logic,
    
    /*** Data Structures Interface ***/
    parameter type axi_ds_aw_chan_t     = logic,
    parameter type axi_ds_w_chan_t      = logic,
    parameter type axi_ds_b_chan_t      = logic,
    parameter type axi_ds_ar_chan_t     = logic,
    parameter type axi_ds_r_chan_t      = logic,

    parameter type axi_ds_req_t         = logic,
    parameter type axi_ds_resp_t        = logic,
    
    /*** Programming Interface ***/
    parameter type axi_prog_aw_chan_t   = logic,
    parameter type axi_prog_w_chan_t    = logic,
    parameter type axi_prog_b_chan_t    = logic,
    parameter type axi_prog_ar_chan_t   = logic,
    parameter type axi_prog_r_chan_t    = logic,

    parameter type axi_prog_req_t       = logic,
    parameter type axi_prog_resp_t      = logic
) (
    input  logic clk_i,
    input  logic rst_ni,

    // Translation Request Interface (Slave)
    input  axi_tr_req_t    tr_req_i,
    output axi_tr_resp_t   tr_resp_o,

    // Translation Completion Interface (Master)
    input  axi_comp_resp_t comp_resp_i,
    output axi_comp_req_t  comp_req_o,

    // Data Structures Interface (Master)
    input  axi_ds_resp_t   ds_resp_i,
    output axi_ds_req_t    ds_req_o,

    // Programming Interface (Slave)
    input  axi_prog_req_t  prog_req_i,
    output axi_prog_resp_t prog_resp_o,

    output logic [(RVIOMMUCfg.NumIntVec-1):0] wsi_wires_o
);

    typedef logic [(RVIOMMUCfg.AxiAddrWidth-1):0] addr_t;
    typedef logic [(RVIOMMUCfg.PAddrWidth-1):0] paddr_t;

    // Register interface structs
    typedef logic [RVIOMMUCfg.AxiAddrWidth-1:0] reg_addr_t;
    typedef logic [31:0]                        reg_data_t;
    typedef logic [3:0]                         reg_strb_t;
    // Define iommu_reg_req_t and iommu_reg_rsp_t
    `REG_BUS_TYPEDEF_ALL(iommu_reg, reg_addr_t, reg_data_t, reg_strb_t)

    // Translation request structure
    typedef struct packed {
        addr_t                  iova;
        rv_iommu::device_id_t   did;
        logic                   pid_valid;
        rv_iommu::process_id_t  pid;
        rv_iommu::ttype_t       ttype;
        logic                   priv;
        logic                   is_debug;
    } trans_req_data_t;

    // Translation response structure
    typedef struct packed {
        logic                       error;
        logic                       ignore;
        paddr_t                     spaddr;
        logic                       is_mrif;
        rv_iommu::mrifc_content_t   mrif_data;
    } trans_resp_data_t;

    // Debug response structure
    typedef struct packed {
        logic           error;
        logic           is_superpage;
        logic [1:0]     pbmt;
        rv_iommu::ppn_t ppn;
    } dbg_resp_t;

    // Fault Data Struct
    typedef struct packed {
        rv_iommu::ttype_t               trans_type;
        rv_iommu::cause_t               cause_code;
        addr_t                          iova;
        logic [(rv_iommu::GPLEN39-1):0] gpaddr;
        rv_iommu::device_id_t           did;
        logic                           pv;
        rv_iommu::process_id_t          pid;
        logic                           is_supervisor;
        logic                           is_guest_pf;
        logic                           is_implicit;
    } fault_data_t;

    trans_req_data_t    trans_req_data;
    logic               trans_req_valid;
    logic               trans_req_ready;

    trans_resp_data_t   trans_resp_data;
    logic               trans_resp_valid;
    logic               trans_resp_ready;

    trans_req_data_t    debug_req_data;
    logic               debug_req_valid;
    logic               debug_req_ready;

    dbg_resp_t          debug_resp_data;
    logic               debug_resp_valid;
    logic               debug_resp_ready;

    rv_iommu_reg_pkg::iommu_reg2hw_capabilities_reg_t   capabilities;
    rv_iommu_reg_pkg::iommu_reg2hw_fctl_reg_t           fctl;
    rv_iommu_reg_pkg::iommu_reg2hw_ddtp_reg_t           ddtp;

    rv_iommu::iotlb_inval_t     iotinval;
    rv_iommu::xdtc_inval_t      iodirinval;

    rv_iommu::hpm_event_t       hpm_events;

    iommu_reg_req_t    regmap_req;
    iommu_reg_rsp_t    regmap_resp;

    axi_ds_req_t   ddtw_axi_req;
    axi_ds_resp_t  ddtw_axi_resp;
    axi_ds_req_t   pdtw_axi_req;
    axi_ds_resp_t  pdtw_axi_resp;
    axi_ds_req_t   ptw_axi_req;
    axi_ds_resp_t  ptw_axi_resp;
    axi_ds_req_t   msiptw_axi_req;
    axi_ds_resp_t  msiptw_axi_resp;
    axi_ds_req_t   mrif_handler_axi_req;
    axi_ds_resp_t  mrif_handler_axi_resp;
    axi_ds_req_t   cq_axi_req;
    axi_ds_resp_t  cq_axi_resp;
    axi_ds_req_t   fq_axi_req;
    axi_ds_resp_t  fq_axi_resp;
    axi_ds_req_t   msi_ig_axi_req;
    axi_ds_resp_t  msi_ig_axi_resp;

    fault_data_t    fault_data;
    logic           fault_valid;
    logic           fault_ready;

    fault_data_t    mrif_fault_data;
    logic           mrif_fault_valid;
    logic           mrif_fault_ready;

    logic in_flight;

    //-----------------------
    // Programming Interface
    //-----------------------
    rv_iommu_prog_if #(
        .RVIOMMUCfg         (RVIOMMUCfg),

        .axi_req_t          (axi_prog_req_t),
        .axi_resp_t         (axi_prog_resp_t),
        .iommu_reg_req_t    (iommu_reg_req_t),
        .iommu_reg_rsp_t    (iommu_reg_rsp_t)
    ) i_rv_iommu_prog_if (
        .clk_i          (clk_i),
        .rst_ni         (rst_ni),

        .prog_req_i     (prog_req_i),
        .prog_resp_o    (prog_resp_o),

        .regmap_req_o   (regmap_req),
        .regmap_resp_i  (regmap_resp)
    );

    //--------------------------
    // Data Structure Interface
    //--------------------------
    rv_iommu_ds_if #(
        .aw_chan_t  (axi_ds_aw_chan_t),
        .w_chan_t   (axi_ds_w_chan_t),
        .b_chan_t   (axi_ds_b_chan_t),
        .ar_chan_t  (axi_ds_ar_chan_t),
        .r_chan_t   (axi_ds_r_chan_t),

        .axi_req_t  (axi_ds_req_t),
        .axi_resp_t (axi_ds_resp_t)
    ) i_rv_iommu_ds_if (

        .clk_i                  (clk_i),
        .rst_ni                 (rst_ni),

        .ds_req_o               (ds_req_o),
        .ds_resp_i              (ds_resp_i),
        
        .ddtw_req_i             (ddtw_axi_req),
        .ddtw_resp_o            (ddtw_axi_resp),
        .pdtw_req_i             (pdtw_axi_req),
        .pdtw_resp_o            (pdtw_axi_resp),
        .ptw_req_i              (ptw_axi_req),
        .ptw_resp_o             (ptw_axi_resp),
        .msiptw_req_i           (msiptw_axi_req),
        .msiptw_resp_o          (msiptw_axi_resp),

        .mrif_handler_req_i     (mrif_handler_axi_req),
        .mrif_handler_resp_o    (mrif_handler_axi_resp),

        .cq_req_i               (cq_axi_req),
        .cq_resp_o              (cq_axi_resp),
        .fq_req_i               (fq_axi_req),
        .fq_resp_o              (fq_axi_resp),
        .msi_ig_req_i           (msi_ig_axi_req),
        .msi_ig_resp_o          (msi_ig_axi_resp)
    );

    //--------------------------------
    // Transaction Controller Wrapper
    //--------------------------------
    rv_iommu_trans_ctl_wrap #(
        .RVIOMMUCfg         (RVIOMMUCfg),

        .addr_t             (addr_t),
        .paddr_t            (paddr_t),
        .trans_req_data_t   (trans_req_data_t),
        .trans_resp_data_t  (trans_resp_data_t),
        .fault_data_t       (fault_data_t),

        .axi_tr_aw_chan_t   (axi_tr_aw_chan_t),
        .axi_tr_w_chan_t    (axi_tr_w_chan_t),
        .axi_tr_ar_chan_t   (axi_tr_ar_chan_t),
        .axi_tr_req_t       (axi_tr_req_t),
        .axi_tr_resp_t      (axi_tr_resp_t),

        .axi_comp_aw_chan_t (axi_comp_aw_chan_t),
        .axi_comp_w_chan_t  (axi_comp_w_chan_t),
        .axi_comp_b_chan_t  (axi_comp_b_chan_t),
        .axi_comp_ar_chan_t (axi_comp_ar_chan_t),
        .axi_comp_r_chan_t  (axi_comp_r_chan_t),
        .axi_comp_req_t     (axi_comp_req_t),
        .axi_comp_resp_t    (axi_comp_resp_t),

        .axi_ds_req_t       (axi_ds_req_t),
        .axi_ds_resp_t      (axi_ds_resp_t)
    ) i_rv_iommu_trans_ctl_wrap (
        .clk_i              (clk_i),
        .rst_ni             (rst_ni),

        .tr_axi_req_i       (tr_req_i),
        .tr_axi_resp_o      (tr_resp_o),

        .comp_axi_resp_i    (comp_resp_i),
        .comp_axi_req_o     (comp_req_o),

        .trans_req_data_o   (trans_req_data),
        .trans_req_valid_o  (trans_req_valid),
        .trans_req_ready_i  (trans_req_ready),

        .trans_resp_data_i  (trans_resp_data),
        .trans_resp_valid_i (trans_resp_valid),
        .trans_resp_ready_o (trans_resp_ready),

        .mrif_axi_req_o     (mrif_handler_axi_req),
        .mrif_axi_resp_i    (mrif_handler_axi_resp),

        .mrif_fault_data_o  (mrif_fault_data),
        .mrif_fault_valid_o (mrif_fault_valid),
        .mrif_fault_ready_i (mrif_fault_ready),

        .in_flight_o        (in_flight)
    );

    //---------------------------
    // Translation Logic Wrapper
    //---------------------------
    generate
    if (RVIOMMUCfg.MSITrans == rv_iommu_cfg::MSI_DISABLED) begin : gen_dc_base
        rv_iommu_tl_wrap #(
            .RVIOMMUCfg         (RVIOMMUCfg),

            .addr_t             (addr_t),
            .paddr_t            (paddr_t),
            .dc_t               (rv_iommu::dc_base_t),
            .ddtc_up_t          (rv_iommu::ddtc_up_base_t),
            .trans_req_data_t   (trans_req_data_t),
            .trans_resp_data_t  (trans_resp_data_t),
            .dbg_resp_t         (dbg_resp_t),
            .fault_data_t       (fault_data_t),

            .axi_req_t          (axi_ds_req_t),
            .axi_resp_t         (axi_ds_resp_t)
        ) i_rv_iommu_tl_wrap (
            .clk_i                  (clk_i),
            .rst_ni                 (rst_ni),

            .trans_req_data_i       (trans_req_data),
            .trans_req_valid_i      (trans_req_valid),
            .trans_req_ready_o      (trans_req_ready),

            .debug_req_data_i       (debug_req_data),
            .debug_req_valid_i      (debug_req_valid),
            .debug_req_ready_o      (debug_req_ready),

            .trans_resp_data_o      (trans_resp_data),
            .trans_resp_valid_o     (trans_resp_valid),
            .trans_resp_ready_i     (trans_resp_ready),

            .debug_resp_data_o      (debug_resp_data),
            .debug_resp_valid_o     (debug_resp_valid),
            .debug_resp_ready_i     (debug_resp_ready),

            .capabilities_i         (capabilities),
            .fctl_i                 (fctl),
            .ddtp_i                 (ddtp),

            .iotinval_i             (iotinval),
            .iodirinval_i           (iodirinval),

            .hpm_events_o           (hpm_events),

            .ddtw_axi_req_o         (ddtw_axi_req),
            .ddtw_axi_resp_i        (ddtw_axi_resp),
            .pdtw_axi_req_o         (pdtw_axi_req),
            .pdtw_axi_resp_i        (pdtw_axi_resp),
            .ptw_axi_req_o          (ptw_axi_req),
            .ptw_axi_resp_i         (ptw_axi_resp),
            .msiptw_axi_req_o       (msiptw_axi_req),
            .msiptw_axi_resp_i      (msiptw_axi_resp),

            .fault_data_o           (fault_data),
            .fault_valid_o          (fault_valid),
            .fault_ready_i          (fault_ready)
        );
    end
    else begin : gen_dc_ext
        rv_iommu_tl_wrap #(
            .RVIOMMUCfg         (RVIOMMUCfg),

            .addr_t             (addr_t),
            .paddr_t            (paddr_t),
            .dc_t               (rv_iommu::dc_ext_t),
            .ddtc_up_t          (rv_iommu::ddtc_up_ext_t),
            .trans_req_data_t   (trans_req_data_t),
            .trans_resp_data_t  (trans_resp_data_t),
            .dbg_resp_t         (dbg_resp_t),
            .fault_data_t       (fault_data_t),

            .axi_req_t          (axi_ds_req_t),
            .axi_resp_t         (axi_ds_resp_t)
        ) i_rv_iommu_tl_wrap (
            .clk_i                  (clk_i),
            .rst_ni                 (rst_ni),

            .trans_req_data_i       (trans_req_data),
            .trans_req_valid_i      (trans_req_valid),
            .trans_req_ready_o      (trans_req_ready),

            .debug_req_data_i       (debug_req_data),
            .debug_req_valid_i      (debug_req_valid),
            .debug_req_ready_o      (debug_req_ready),

            .trans_resp_data_o      (trans_resp_data),
            .trans_resp_valid_o     (trans_resp_valid),
            .trans_resp_ready_i     (trans_resp_ready),

            .debug_resp_data_o      (debug_resp_data),
            .debug_resp_valid_o     (debug_resp_valid),
            .debug_resp_ready_i     (debug_resp_ready),

            .capabilities_i         (capabilities),
            .fctl_i                 (fctl),
            .ddtp_i                 (ddtp),

            .iotinval_i             (iotinval),
            .iodirinval_i           (iodirinval),

            .hpm_events_o           (hpm_events),

            .ddtw_axi_req_o         (ddtw_axi_req),
            .ddtw_axi_resp_i        (ddtw_axi_resp),
            .pdtw_axi_req_o         (pdtw_axi_req),
            .pdtw_axi_resp_i        (pdtw_axi_resp),
            .ptw_axi_req_o          (ptw_axi_req),
            .ptw_axi_resp_i         (ptw_axi_resp),
            .msiptw_axi_req_o       (msiptw_axi_req),
            .msiptw_axi_resp_i      (msiptw_axi_resp),

            .fault_data_o           (fault_data),
            .fault_valid_o          (fault_valid),
            .fault_ready_i          (fault_ready)
        );
    end
    endgenerate

    //----------------------------
    // Software Interface Wrapper
    //----------------------------
    rv_iommu_sw_if_wrap #(
        .RVIOMMUCfg        (RVIOMMUCfg),

        .addr_t            (addr_t),
        .paddr_t           (paddr_t),
        .trans_req_data_t  (trans_req_data_t),
        .dbg_resp_t        (dbg_resp_t),
        .fault_data_t      (fault_data_t),

        .axi_req_t         (axi_ds_req_t),
        .axi_resp_t        (axi_ds_resp_t),
        .iommu_reg_req_t   (iommu_reg_req_t),
        .iommu_reg_rsp_t   (iommu_reg_rsp_t)
    ) i_rv_iommu_sw_if_wrap (
        .clk_i             (clk_i),
        .rst_ni            (rst_ni),

        .regmap_req_i      (regmap_req),
        .regmap_resp_o     (regmap_resp),

        .cq_axi_req_o      (cq_axi_req),
        .cq_axi_resp_i     (cq_axi_resp),
        .fq_axi_req_o      (fq_axi_req),
        .fq_axi_resp_i     (fq_axi_resp),
        .msi_ig_axi_req_o  (msi_ig_axi_req),
        .msi_ig_axi_resp_i (msi_ig_axi_resp),

        .capabilities_o    (capabilities),
        .fctl_o            (fctl),
        .ddtp_o            (ddtp),

        .dbg_req_data_o    (debug_req_data),
        .dbg_req_valid_o   (debug_req_valid),
        .dbg_req_ready_i   (debug_req_ready),

        .dbg_resp_data_i   (debug_resp_data),
        .dbg_resp_valid_i  (debug_resp_valid),
        .dbg_resp_ready_o  (debug_resp_ready),

        .iotinval_o        (iotinval),
        .iodirinval_o      (iodirinval),

        .hpm_events_i      (hpm_events),

        .trans_fault_data_i  (fault_data),
        .trans_fault_valid_i (fault_valid),
        .trans_fault_ready_o (fault_ready),

        .mrif_fault_data_i  (mrif_fault_data),
        .mrif_fault_valid_i (mrif_fault_valid),
        .mrif_fault_ready_o (mrif_fault_ready),

        .in_flight_i       (in_flight),

        .wsi_wires_o       (wsi_wires_o)
    );
    
endmodule