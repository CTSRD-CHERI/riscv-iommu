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
// Description: RISC-V IOMMU Software Interface Wrapper.
//              Contains all modules from the software interface of the RISC-V IOMMU.
//              Register Map, HPM, CQ Handler, FQ Handler, WSI IG, MSI IG, Debug IF Controller.

module rv_iommu_sw_if_wrap
import rv_iommu_reg_pkg::*;
#(
    /// RISC-V IOMMU configuration struct
    parameter rv_iommu_cfg::rv_iommu_cfg_t RVIOMMUCfg = rv_iommu_cfg::NullCfg,

    /// Address data type
    parameter type addr_t = logic,
    /// Physical address data type
    parameter type paddr_t = logic,

    /// Translation request data type
    parameter type trans_req_data_t = logic,
    /// Debug response data type
    parameter type dbg_resp_t = logic,
    /// Fault data type
    parameter type fault_data_t = logic,

    /// AXI data types
    parameter type axi_req_t        = logic,
    parameter type axi_resp_t       = logic,
    /// Register data types
    parameter type iommu_reg_req_t  = logic,
    parameter type iommu_reg_rsp_t  = logic
) (
    input  logic clk_i,
    input  logic rst_ni,

    // From Prog IF
    input  iommu_reg_req_t regmap_req_i,
    output iommu_reg_rsp_t regmap_resp_o,

    // AXI ports directed to Data Structures Interface
    // CQ
    output axi_req_t    cq_axi_req_o,
    input  axi_resp_t   cq_axi_resp_i,
    // FQ
    output axi_req_t    fq_axi_req_o,
    input  axi_resp_t   fq_axi_resp_i,
    // PQ
    output axi_req_t    pq_axi_req_o,
    input  axi_resp_t   pq_axi_resp_i,
    // MSI IG
    output axi_req_t    msi_ig_axi_req_o,
    input  axi_resp_t   msi_ig_axi_resp_i,

    // Register values required by translation logic
    output iommu_reg2hw_capabilities_reg_t  capabilities_o,
    output iommu_reg2hw_fctl_reg_t          fctl_o,
    output iommu_reg2hw_ddtp_reg_t          ddtp_o,

    // Debug IF Request port
    output trans_req_data_t dbg_req_data_o,
    output logic            dbg_req_valid_o,
    input  logic            dbg_req_ready_i,

    // Debug IF Response port
    input  dbg_resp_t       dbg_resp_data_i,
    input  logic            dbg_resp_valid_i,
    output logic            dbg_resp_ready_o,

    // Cache invalidation
    output rv_iommu::iotlb_inval_t  iotinval_o,
    output rv_iommu::xdtc_inval_t   iodirinval_o,

    // HPM events
    input rv_iommu::hpm_event_t     hpm_events_i,

    // Translation logic fault port
    input  fault_data_t trans_fault_data_i,
    input  logic        trans_fault_valid_i,
    output logic        trans_fault_ready_o,

    // MRIF handler fault port
    input  fault_data_t mrif_fault_data_i,
    input  logic        mrif_fault_valid_i,
    output logic        mrif_fault_ready_o,

    // The IOMMU is currently processing a translation
    input  logic        in_flight_i,


    // ATS Invalidation
    output rv_iommu::cq_atsinval_t atsinval_o,
    output logic                   atsinval_valid_o,
    input  logic                   atsinval_ready_i,

    input  logic                   atsinval_to_i,
    input  logic                   atsinval_inflight_i,

    output logic                   ats_fence_valid_o,
    input  logic                   ats_fence_ready_i,

    output logic [31:0]            pq_head_o,
    output logic [31:0]            pq_tail_o,

    // Return PAGE_RESP from IOMMU
    output rv_iommu::cq_atsprgr_t atsprgr_o,
    output logic                  atsprgr_valid_o,
    input  logic                  atsprgr_ready_i,

    // Page input port
    input  rv_iommu::pq_record_t   pq_data_i,
    input  logic                   pq_valid_i,
    output logic                   pq_ready_o,
    output rv_iommu::pri_fault     pq_data_o,

    // Interrupt wires
    output logic [(RVIOMMUCfg.NumIntVec-1):0] wsi_wires_o
);

    // Register values
    iommu_reg2hw_t reg2hw;
    iommu_hw2reg_t hw2reg;

    // Register values required by translation logic
    assign capabilities_o   = reg2hw.capabilities;
    assign fctl_o           = reg2hw.fctl;
    assign ddtp_o           = reg2hw.ddtp;

    assign pq_tail_o = reg2hw.pqt.q;
    assign pq_head_o = reg2hw.pqh.q;


    //--------
    // Regmap
    //--------
    rv_iommu_regmap #(
        .RVIOMMUCfg     (RVIOMMUCfg),
        .DataWidth      (32),

        .iommu_reg_req_t(iommu_reg_req_t),
        .iommu_reg_rsp_t(iommu_reg_rsp_t)
    ) i_rv_iommu_regmap (
        .clk_i          (clk_i),
        .rst_ni         (rst_ni),

        .reg_req_i      (regmap_req_i),
        .reg_rsp_o      (regmap_resp_o),

        .reg2hw_o       (reg2hw),
        .hw2reg_i       (hw2reg),

        .devmode_i      (1'b0),
        .in_flight_i    (in_flight_i)
    );

    //-----------------------
    // Command Queue Handler
    //-----------------------
    rv_iommu_cq_handler #(
        .RVIOMMUCfg          (RVIOMMUCfg),

        .addr_t              (addr_t),
        .paddr_t             (paddr_t),

        .axi_req_t           (axi_req_t),
        .axi_resp_t          (axi_resp_t)
    ) i_rv_iommu_cq_handler (
        .clk_i               (clk_i),
        .rst_ni              (rst_ni),

        .cqb_ppn_i           (reg2hw.cqb.ppn.q),
        .cqb_size_i          (reg2hw.cqb.log2sz_1.q),

        .cq_tail_i           (reg2hw.cqt.q),
        .cq_head_i           (reg2hw.cqh.q),
        .cq_head_o           (hw2reg.cqh.d),
        .cq_head_wen_o       (hw2reg.cqh.de),

        .cqcsr_en_i          (reg2hw.cqcsr.cqen.q),
        .cqcsr_ie_i          (reg2hw.cqcsr.cie.q),
        .cqcsr_on_o          (hw2reg.cqcsr.cqon.d),
        .cqcsr_on_wen_o      (hw2reg.cqcsr.cqon.de),
        .cqcsr_busy_o        (hw2reg.cqcsr.busy.d),
        .cqcsr_busy_wen_o    (hw2reg.cqcsr.busy.de),

        .cqcsr_mf_i          (reg2hw.cqcsr.cqmf.q),
        .cqcsr_mf_o          (hw2reg.cqcsr.cqmf.d),
        .cqcsr_mf_wen_o      (hw2reg.cqcsr.cqmf.de),

        .cqcsr_to_i          (reg2hw.cqcsr.cmd_to.q),
        .cqcsr_to_o          (hw2reg.cqcsr.cmd_to.d),
        .cqcsr_to_wen_o      (hw2reg.cqcsr.cmd_to.de),

        .cqcsr_ill_i         (reg2hw.cqcsr.cmd_ill.q),
        .cqcsr_ill_o         (hw2reg.cqcsr.cmd_ill.d),
        .cqcsr_ill_wen_o     (hw2reg.cqcsr.cmd_ill.de),

        .cqcsr_fence_i       (reg2hw.cqcsr.fence_w_ip.q),
        .cqcsr_fence_o       (hw2reg.cqcsr.fence_w_ip.d),
        .cqcsr_fence_wen_o   (hw2reg.cqcsr.fence_w_ip.de),

        .ipsr_cip_o          (hw2reg.ipsr.cip.d),
        .ipsr_cip_wen_o      (hw2reg.ipsr.cip.de),

        .wsi_en_i            (reg2hw.fctl.wsi.q),

        .iodirinval_o        (iodirinval_o),
        .iotinval_o          (iotinval_o),

        .atsinval_o          (atsinval_o),
        .atsinval_valid_o    (atsinval_valid_o),
        .atsinval_ready_i    (atsinval_ready_i),

        .atsinval_to_i       (atsinval_to_i),
        .atsinval_inflight_i (atsinval_inflight_i),

        .ats_fence_valid_o   (ats_fence_valid_o),
        .ats_fence_ready_i   (ats_fence_ready_i),

        .atsprgr_o           (atsprgr_o),
        .atsprgr_valid_o     (atsprgr_valid_o),
        .atsprgr_ready_i     (atsprgr_ready_i),

        .mem_req_o           (cq_axi_req_o),
        .mem_resp_i          (cq_axi_resp_i)
    );

    //---------------
    // Fault Arbiter
    //---------------
    localparam int unsigned MrifFaultPort = (RVIOMMUCfg.MSITrans == rv_iommu_cfg::MSI_BT_MRIF) ? (32'd1) : (32'd0);
    localparam int unsigned MsiIgFaultPort = (RVIOMMUCfg.IGS != rv_iommu_cfg::WSI_ONLY) ? (32'd1) : (32'd0);
    localparam int unsigned NumFaultPorts = 32'd1 + MrifFaultPort + MsiIgFaultPort;

    fault_data_t    msi_ig_fault_data;
    logic           msi_ig_fault_valid;
    logic           msi_ig_fault_ready;

    fault_data_t [(NumFaultPorts-1):0]  fault_data;
    logic [(NumFaultPorts-1):0]         fault_valid;
    logic [(NumFaultPorts-1):0]         fault_ready;

    if (RVIOMMUCfg.MSITrans == rv_iommu_cfg::MSI_BT_MRIF) begin
        if (RVIOMMUCfg.IGS != rv_iommu_cfg::WSI_ONLY) begin
            assign fault_data = {trans_fault_data_i, mrif_fault_data_i, msi_ig_fault_data};
            assign fault_valid = {trans_fault_valid_i, mrif_fault_valid_i, msi_ig_fault_valid};
            assign trans_fault_ready_o = fault_ready[2];
            assign mrif_fault_ready_o = fault_ready[1];
            assign msi_ig_fault_ready = fault_ready[0];
        end
        else begin
            assign fault_data = {trans_fault_data_i, mrif_fault_data_i};
            assign fault_valid = {trans_fault_valid_i, mrif_fault_valid_i};
            assign trans_fault_ready_o = fault_ready[1];
            assign mrif_fault_ready_o = fault_ready[0];
            assign msi_ig_fault_ready = 1'b0;
        end
    end
    else begin
        if (RVIOMMUCfg.IGS != rv_iommu_cfg::WSI_ONLY) begin
            assign fault_data = {trans_fault_data_i, msi_ig_fault_data};
            assign fault_valid = {trans_fault_valid_i, msi_ig_fault_valid};
            assign trans_fault_ready_o = fault_ready[1];
            assign msi_ig_fault_ready = fault_ready[0];
            assign mrif_fault_ready_o = 1'b0;
        end
        else begin
            assign fault_data = trans_fault_data_i;
            assign fault_valid = trans_fault_valid_i;
            assign trans_fault_ready_o = fault_ready[0];
            assign mrif_fault_ready_o = 1'b0;
            assign msi_ig_fault_ready = 1'b0;
        end
    end

    rv_iommu::fq_record_t   fq_data;
    logic                   fq_valid;
    logic                   fq_ready;

    rv_iommu_fault_arbiter #(
        .RVIOMMUCfg        (RVIOMMUCfg),
        .NumFaultPorts     (NumFaultPorts),
        .fault_data_t      (fault_data_t)
    ) i_rv_iommu_fault_arbiter (
        .clk_i             (clk_i),
        .rst_ni            (rst_ni),

        .fault_data_i      (fault_data),
        .fault_valid_i     (fault_valid),
        .fault_ready_o     (fault_ready),

        .fq_data_o         (fq_data),
        .fq_valid_o        (fq_valid),
        .fq_ready_i        (fq_ready)
    );

    //---------------------
    // Fault Queue Handler
    //---------------------
    rv_iommu_fq_handler #(
        .RVIOMMUCfg         (RVIOMMUCfg),

        .addr_t             (addr_t),
        .paddr_t            (paddr_t),

        .axi_req_t          (axi_req_t),
        .axi_resp_t         (axi_resp_t)
    ) i_rv_iommu_fq_handler (
        .clk_i              (clk_i),
        .rst_ni             (rst_ni),

        .fqb_ppn_i          (reg2hw.fqb.ppn.q),
        .fqb_size_i         (reg2hw.fqb.log2sz_1.q),

        .fq_head_i          (reg2hw.fqh.q),
        .fq_tail_i          (reg2hw.fqt.q),
        .fq_tail_o          (hw2reg.fqt.d),
        .fq_tail_wen_o      (hw2reg.fqt.de),

        .fqcsr_en_i         (reg2hw.fqcsr.fqen.q),
        .fqcsr_ie_i         (reg2hw.fqcsr.fie.q),
        .fqcsr_on_o         (hw2reg.fqcsr.fqon.d),
        .fqcsr_on_wen_o     (hw2reg.fqcsr.fqon.de),
        .fqcsr_busy_o       (hw2reg.fqcsr.busy.d),
        .fqcsr_busy_wen_o   (hw2reg.fqcsr.busy.de),

        .fqcsr_mf_i         (reg2hw.fqcsr.fqmf.q),
        .fqcsr_mf_o         (hw2reg.fqcsr.fqmf.d),
        .fqcsr_mf_wen_o     (hw2reg.fqcsr.fqmf.de),

        .fqcsr_of_i         (reg2hw.fqcsr.fqof.q),
        .fqcsr_of_o         (hw2reg.fqcsr.fqof.d),
        .fqcsr_of_wen_o     (hw2reg.fqcsr.fqof.de),

        .ipsr_fip_o         (hw2reg.ipsr.fip.d),
        .ipsr_fip_wen_o     (hw2reg.ipsr.fip.de),

        .fq_data_i          (fq_data),
        .fq_ready_o         (fq_ready),
        .fq_valid_i         (fq_valid),

        .mem_req_o          (fq_axi_req_o),
        .mem_resp_i         (fq_axi_resp_i)
    );

    //---------------------
    // Page Queue Handler
    //---------------------
    rv_iommu_pq_handler #(
        .RVIOMMUCfg         (RVIOMMUCfg),

        .addr_t             (addr_t),
        .paddr_t            (paddr_t),

        .axi_req_t          (axi_req_t),
        .axi_resp_t         (axi_resp_t)
    ) i_rv_iommu_pq_handler (
        .clk_i              (clk_i),
        .rst_ni             (rst_ni),

        .pqb_ppn_i          (reg2hw.pqb.ppn.q),
        .pqb_size_i         (reg2hw.pqb.log2sz_1.q),

        .pq_head_i          (reg2hw.pqh.q),
        .pq_tail_i          (reg2hw.pqt.q),
        .pq_tail_o          (hw2reg.pqt.d),
        .pq_tail_wen_o      (hw2reg.pqt.de),

        .pqcsr_en_i         (reg2hw.pqcsr.pqen.q),
        .pqcsr_ie_i         (reg2hw.pqcsr.pie.q),
        .pqcsr_on_o         (hw2reg.pqcsr.pqon.d),
        .pqcsr_on_wen_o     (hw2reg.pqcsr.pqon.de),
        .pqcsr_busy_o       (hw2reg.pqcsr.busy.d),
        .pqcsr_busy_wen_o   (hw2reg.pqcsr.busy.de),

        .pqcsr_mf_i         (reg2hw.pqcsr.pqmf.q),
        .pqcsr_mf_o         (hw2reg.pqcsr.pqmf.d),
        .pqcsr_mf_wen_o     (hw2reg.pqcsr.pqmf.de),

        .pqcsr_of_i         (reg2hw.pqcsr.pqof.q),
        .pqcsr_of_o         (hw2reg.pqcsr.pqof.d),
        .pqcsr_of_wen_o     (hw2reg.pqcsr.pqof.de),

        .ipsr_pip_o         (hw2reg.ipsr.pip.d),
        .ipsr_pip_wen_o     (hw2reg.ipsr.pip.de),

        .pq_data_i          (pq_data_i),
        .pq_valid_i         (pq_valid_i),
        .pq_ready_o         (pq_ready_o),
        .pq_data_o          (pq_data_o),

        .mem_req_o          (pq_axi_req_o),
        .mem_resp_i         (pq_axi_resp_i)
    );

    //------------------------------
    // Hardware Performance Monitor
    //------------------------------
    genvar k;
    generate
    if (RVIOMMUCfg.NumHpmCounters > 0) begin : gen_hpm

        rv_iommu_hpm #(
            .RVIOMMUCfg        (RVIOMMUCfg)
        ) i_rv_iommu_hpm (
            .clk_i             (clk_i),
            .rst_ni            (rst_ni),

            .events_i          (hpm_events_i),

            .iocountinh_i      (reg2hw.iocountinh),
            .iohpmcycles_i     (reg2hw.iohpmcycles),
            .iohpmctr_i        (reg2hw.iohpmctr[RVIOMMUCfg.NumHpmCounters-1:0]),
            .iohpmevt_i        (reg2hw.iohpmevt[RVIOMMUCfg.NumHpmCounters-1:0]),

            .iohpmcycles_o     (hw2reg.iohpmcycles),
            .iohpmctr_o        (hw2reg.iohpmctr[RVIOMMUCfg.NumHpmCounters-1:0]),
            .iohpmevt_o        (hw2reg.iohpmevt[RVIOMMUCfg.NumHpmCounters-1:0]),

            .ipsr_pmip_o       (hw2reg.ipsr.pmip.d),
            .ipsr_pmip_wen_o   (hw2reg.ipsr.pmip.de)
        );

        // Hardwire unused counters to zero
        for (k = RVIOMMUCfg.NumHpmCounters; k < 31; k++) begin
            assign hw2reg.iohpmctr[k].counter.d     = '0;
            assign hw2reg.iohpmctr[k].counter.de    = 1'b0;
            assign hw2reg.iohpmevt[k].of.d          = 1'b0;
            assign hw2reg.iohpmevt[k].of.de         = 1'b0;
        end
    end : gen_hpm
    else begin : gen_hpm_disabled
        assign hw2reg.iohpmcycles   = '0;
        assign hw2reg.ipsr.pmip     = '0;

        for (k = 0; k < 31; k++) begin
            assign hw2reg.iohpmctr[k]   = '0;
            assign hw2reg.iohpmevt[k]   = '0;
        end
    end : gen_hpm_disabled
    endgenerate

    //----------------------
    // Interrupt Generation
    //----------------------
    logic [2:0][3:0] intv;
    assign intv = {
        reg2hw.icvec.pmiv.q,  // HPM
        reg2hw.icvec.fiv.q,   // FQ
        reg2hw.icvec.civ.q    // CQ
    };
    logic [2:0] intp;
    assign intp = {
        reg2hw.ipsr.pmip.q,  // HPM
        reg2hw.ipsr.fip.q,   // FQ
        reg2hw.ipsr.cip.q    // CQ
    };

    generate

    //--------------------------
    // MSI Interrupt Generation
    //--------------------------
    if (RVIOMMUCfg.IGS != rv_iommu_cfg::WSI_ONLY) begin : gen_msi_ig

        logic [15:0][53:0] msi_addr_x;
        logic [15:0][31:0] msi_data_x;
        logic [15:0] msi_vec_masked_x;
        assign msi_addr_x = reg2hw.msi_addr;
        assign msi_data_x = reg2hw.msi_data;
        assign msi_vec_masked_x = reg2hw.msi_vec_ctl;

        rv_iommu_msi_ig #(
            .RVIOMMUCfg         (RVIOMMUCfg),
            .fault_data_t       (fault_data_t),

            .addr_t             (addr_t),
            .paddr_t            (paddr_t),

            .axi_req_t          (axi_req_t),
            .axi_resp_t         (axi_resp_t)
        ) i_rv_iommu_msi_ig (
            .clk_i              (clk_i),
            .rst_ni             (rst_ni),

            .msi_ig_en_i        (~reg2hw.fctl.wsi.q),

            .intp_i             (intp),
            .intv_i             (intv),

            .msi_addr_x_i       (msi_addr_x),
            .msi_data_x_i       (msi_data_x),
            .msi_vec_masked_x_i (msi_vec_masked_x),

            .fault_data_o       (msi_ig_fault_data),
            .fault_valid_o      (msi_ig_fault_valid),
            .fault_ready_i      (msi_ig_fault_ready),

            .mem_req_o          (msi_ig_axi_req_o),
            .mem_resp_i         (msi_ig_axi_resp_i)
        );
    end : gen_msi_ig
    else begin : gen_msi_ig_disabled
        assign  msi_ig_fault_data   = '0;
        assign  msi_ig_fault_valid  = 1'b0;
        assign  msi_ig_axi_req_o    = '0;
    end : gen_msi_ig_disabled

    //--------------------------
    // WSI Interrupt Generation
    //--------------------------
    if (RVIOMMUCfg.IGS != rv_iommu_cfg::MSI_ONLY) begin : gen_wsi_ig

        rv_iommu_wsi_ig #(
            .RVIOMMUCfg (RVIOMMUCfg)
        ) i_rv_iommu_wsi_ig (

            .wsi_en_i   (reg2hw.fctl.wsi.q),

            .intp_i     (intp),

            .intv_i     (intv),

            .wsi_wires_o(wsi_wires_o)
        );
    end : gen_wsi_ig
    else begin : gen_wsi_ig_disabled
        assign wsi_wires_o  = '0;
    end : gen_wsi_ig_disabled
    endgenerate

    //--------------------------
    // Debug Register Interface
    //--------------------------
    generate
        if (RVIOMMUCfg.InclDbg) begin : gen_dbg_if

            //----------------------------
            // Debug Interface Controller
            //----------------------------
            rv_iommu_dbg_if_ctl #(
                .trans_req_data_t   (trans_req_data_t),
                .dbg_resp_t         (dbg_resp_t)
            ) rv_iommu_dbg_if_ctl_i (
                .clk_i              (clk_i),
                .rst_ni             (rst_ni),

                // Debug registers
                .dbg_iova_i         (reg2hw.tr_req_iova),
                .dbg_ctl_i          (reg2hw.tr_req_ctl),
                .dbg_resp_o         (hw2reg.tr_response),
                .dbg_ctl_o          (hw2reg.tr_req_ctl),

                // Request port
                .req_data_o         (dbg_req_data_o),
                .req_valid_o        (dbg_req_valid_o),
                .req_ready_i        (dbg_req_ready_i),

                // Response port
                .resp_data_i        (dbg_resp_data_i),
                .resp_valid_i       (dbg_resp_valid_i),
                .resp_ready_o       (dbg_resp_ready_o)
            );
        end : gen_dbg_if
        else begin : gen_dbg_if_disabled
            assign hw2reg.tr_response = '0;
            assign hw2reg.tr_req_ctl = '0;
            assign dbg_req_data_o = '0;
            assign dbg_req_valid_o = '0;
            assign dbg_resp_ready_o = '0;
        end : gen_dbg_if_disabled
    endgenerate


endmodule
