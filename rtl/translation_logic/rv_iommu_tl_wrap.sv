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
// Description: RISC-V IOMMU Translation Logic Wrapper
//              Encompasses all address translation modules
//              Supports Sv39x4 only


module rv_iommu_tl_wrap
  import rv_iommu_reg_pkg::*;
  import rv_iommu::*;
#(
    /// RISC-V IOMMU configuration struct
    parameter rv_iommu_cfg::rv_iommu_cfg_t RVIOMMUCfg = rv_iommu_cfg::NullCfg,

    /// Address data type
    parameter type addr_t = logic,
    /// Physical address data type
    parameter type paddr_t = logic,

    /// Device Context type
    parameter type dc_t = logic,
    /// DDTC update structure type
    parameter type ddtc_up_t = logic,

    /// Translation request data type
    parameter type trans_req_data_t = logic,
    /// Translation response data type
    parameter type trans_resp_data_t = logic,
    /// Debug response data type
    parameter type dbg_resp_t = logic,
    /// Fault data type
    parameter type fault_data_t = logic,

    /// AXI data types
    parameter type axi_req_t = logic,
    parameter type axi_resp_t = logic
) (
    input  logic    clk_i,
    input  logic    rst_ni,

    // Transaction controller request port
    input  trans_req_data_t     trans_req_data_i,
    input  logic                trans_req_valid_i,
    output logic                trans_req_ready_o,

    // ATS Transaction controller request port
    input  trans_req_data_t     ats_trans_req_data_i,
    input  logic                ats_trans_req_valid_i,
    output logic                ats_trans_req_ready_o,

    // Debug IF controller request port
    input  trans_req_data_t     debug_req_data_i,
    input  logic                debug_req_valid_i,
    output logic                debug_req_ready_o,

    // Transaction controller response port
    output trans_resp_data_t    trans_resp_data_o,
    output logic                trans_resp_valid_o,
    input  logic                trans_resp_ready_i,

    // ATS Transaction controller response port
    output trans_resp_data_t    ats_trans_resp_data_o,
    output logic                ats_trans_resp_valid_o,
    input  logic                ats_trans_resp_ready_i,

    // ATS Page Request related interface
    input  logic                ats_ddtc_valid_i,
    input  device_id_t          ats_ddtc_did_i,
    output logic                ats_ddtc_ready_o,
    output ats_tc_t             ats_ddtc_tc_o,

    // Debug IF controller response port
    output dbg_resp_t           debug_resp_data_o,
    output logic                debug_resp_valid_o,
    input  logic                debug_resp_ready_i,

    // From Regmap
    input  iommu_reg2hw_capabilities_reg_t  capabilities_i,
    input  iommu_reg2hw_fctl_reg_t          fctl_i,
    input  iommu_reg2hw_ddtp_reg_t          ddtp_i,

    // Invalidation signals
    input  rv_iommu::iotlb_inval_t      iotinval_i,
    input  rv_iommu::xdtc_inval_t       iodirinval_i,

    // HPM translation events
    output rv_iommu::hpm_event_t        hpm_events_o,

    // AXI ports directed to DS Interface
    // DDTW
    output axi_req_t    ddtw_axi_req_o,
    input  axi_resp_t   ddtw_axi_resp_i,
    // PDTW
    output axi_req_t    pdtw_axi_req_o,
    input  axi_resp_t   pdtw_axi_resp_i,
    // PTW
    output axi_req_t    ptw_axi_req_o,
    input  axi_resp_t   ptw_axi_resp_i,
    // MSI PTW
    output axi_req_t    msiptw_axi_req_o,
    input  axi_resp_t   msiptw_axi_resp_i,

    // Translation fault reporting port
    output fault_data_t fault_data_o,
    output logic        fault_valid_o,
    input  logic        fault_ready_i
);

    localparam int unsigned PLEN = RVIOMMUCfg.PAddrWidth;
    localparam int unsigned PPNW = PLEN-12;

    typedef enum logic [2:0] {
        IDLE        = 3'b000,
        DDT         = 3'b001,
        PDT         = 3'b010,
        PT          = 3'b011,
        MSI         = 3'b100,
        ERROR       = 3'b101,
        COMPLETE    = 3'b110
    } tl_wrap_state_t;
    tl_wrap_state_t state_q, state_n;

    //-----------------
    // Request Arbiter
    //-----------------
    trans_req_data_t    arb_req_data;
    logic               arb_req_valid;
    logic               arb_req_ready;
    trans_req_data_t    req_data;
    logic               req_valid;
    logic               req_ready;
    assign req_ready = (debug_resp_valid_o & debug_resp_ready_i) |
                       (trans_resp_valid_o & trans_resp_ready_i) |
                       (ats_trans_resp_valid_o & ats_trans_resp_ready_i) ;

    // Priority is given to normal transactions
    // We can keep the arbitrer in any case, as data_i and valid_i are '0
    // when debug/ATS are unsupported
    stream_arbiter #(
        .DATA_T   (trans_req_data_t),
        .N_INP    (3),
        .ARBITER  ("prio")
    ) i_req_arbiter (
        .clk_i          (clk_i),
        .rst_ni         (rst_ni),

        .inp_data_i     ({ats_trans_req_data_i,     debug_req_data_i,     trans_req_data_i }),
        .inp_valid_i    ({ats_trans_req_valid_i,    debug_req_valid_i,    trans_req_valid_i}),
        .inp_ready_o    ({ats_trans_req_ready_o,    debug_req_ready_o,    trans_req_ready_o}),

        .oup_data_o     (arb_req_data),
        .oup_valid_o    (arb_req_valid),
        .oup_ready_i    (arb_req_ready)
    );

    spill_register #(
        .T          (trans_req_data_t),
        .Bypass     (1'b0)
    ) i_req_spill_register (
        .clk_i      (clk_i),
        .rst_ni     (rst_ni),

        .data_i     (arb_req_data),
        .valid_i    (arb_req_valid),
        .ready_o    (arb_req_ready),

        .data_o     (req_data),
        .valid_o    (req_valid),
        .ready_i    (req_ready)
    );

    //-----------------------
    // Translation Data Regs
    //-----------------------
    dc_t                dc_q,           dc_n;
    rv_iommu::pc_t      pc_q,           pc_n;
    logic               en_1S_q,        en_1S_n;
    logic               en_2S_q,        en_2S_n;
    rv_iommu::gscid_t   gscid_q,        gscid_n;
    rv_iommu::pscid_t   pscid_q,        pscid_n;
    rv_iommu::ppn_t     iohgatp_ppn_q,  iohgatp_ppn_n;
    rv_iommu::ppn_t     iosatp_ppn_q,   iosatp_ppn_n;
    paddr_t             spaddr_q,       spaddr_n;
    logic               r_q,            r_n;
    logic               w_q,            w_n;
    logic               x_q,            x_n;
    logic               u_q,            u_n;
    logic               g_q,            g_n;
    logic               sum_q,          sum_n;
    logic               t2gpa_q,        t2gpa_n;
    logic               bypass_q,       bypass_n;
    logic [2:0]         range_q,        range_n;



    //-------------
    // IOATC Wires
    //-------------
    // DDTC
    logic                    ddtc_lu;
    rv_iommu::device_id_t    ddtc_lu_did;
    logic                    ddtc_lu_hit;
    dc_t                     ddtc_dc;
    ddtc_up_t                ddtc_update;
    assign ddtc_lu          = (state_q == DDT) | ats_ddtc_valid_i;
    assign ddtc_lu_did      = ats_ddtc_valid_i ? ats_ddtc_did_i : req_data.did;
    assign ats_ddtc_ready_o = ~ddtc_lu_hit;
    assign ats_ddtc_tc_o.en_pri = dc_q.tc.en_pri;
    assign ats_ddtc_tc_o.en_ats = dc_q.tc.en_ats;
    assign ats_ddtc_tc_o.prpr   = dc_q.tc.prpr;

    // PDTC
    logic                    pdtc_lu_hit;
    rv_iommu::pc_t           pdtc_lu_content;
    // IOTLB
    logic                           iotlb_lu;
    logic [rv_iommu::GPPNW39-1:0]   iotlb_lu_vpn;
    rv_iommu::pscid_t               iotlb_lu_pscid;
    rv_iommu::gscid_t               iotlb_lu_gscid;
    logic                           iotlb_lu_hit;
    rv_iommu::iotlb_content_t       iotlb_lu_content;
    rv_iommu::iotlb_up_t            ptw_iotlb_update, msi_iotlb_update;
    rv_iommu::iotlb_up_t            iotlb_update;
    assign iotlb_lu         = (state_q == PT) | (state_q == MSI);
    assign iotlb_lu_vpn     = req_data.iova[rv_iommu::GPLEN39-1:12];
    assign iotlb_lu_pscid   = pscid_q;
    assign iotlb_lu_gscid   = gscid_q;
    assign iotlb_update     = (msi_iotlb_update.update) ?
                              (msi_iotlb_update) :
                              (ptw_iotlb_update);

    //-----------------
    // Walkers Control
    //-----------------
    // DDTW
    logic ddtw_init;
    assign ddtw_init = ddtc_lu & ~ddtc_lu_hit;
    logic ddtw_error;
    rv_iommu::cause_t ddtw_cause;
    logic ddtw_imp_init;
    rv_iommu::ppn_t ddtw_pdt_gppn;
    rv_iommu::ppn_t iohgatp_ppn_fw;
    rv_iommu::ppn_t ddtw_pdt_ppn;
    assign ddtw_pdt_ppn = ptw_iotlb_update.content.content_2S.ppn;
    // PDTW
    logic pdtw_error;
    rv_iommu::cause_t pdtw_cause;
    logic pdtw_imp_init;
    rv_iommu::ppn_t pdtw_pdt_gppn;
    // PTW
    logic ptw_init;
    assign ptw_init = (state_q == PT) & ~iotlb_lu_hit;
    logic ptw_error;
    logic ptw_error_2S;
    logic ptw_error_2S_int;
    logic [rv_iommu::GPLEN39-1:0] ptw_bad_gpaddr;
    rv_iommu::cause_t ptw_cause;
    logic ddt_imp_trans_q, ddt_imp_trans_n;
    logic pdt_imp_trans_q, pdt_imp_trans_n;
    logic imp_done;
    logic imp_err;
    rv_iommu::ppn_t pdt_gppn_q, pdt_gppn_n;
    // MSI Translation
    logic msi_enabled;
    logic [rv_iommu::GPPNW39-1:0] msi_mask;
    logic [rv_iommu::GPPNW39-1:0] msi_pattern;
    logic gpaddr_is_msi;
    rv_iommu::iotlb_stage_content_t msi_1S_content;

    //-----------
    // Aux Wires
    //-----------
    // To determine if request is translated or untranslated
    logic is_translated;
    assign is_translated = (!req_data.ttype[3] && req_data.ttype[2]);
    // To determine if request is a PCIe ATS TR
    logic is_pcie_ats_req;
    assign is_pcie_ats_req = (req_data.ttype == rv_iommu::PCIE_ATS_TRANS_REQ);
    // To determine if request is a PCIe ATS PR
    logic is_pcie_page_req;
    assign is_pcie_page_req = (req_data.ttype == rv_iommu::PCIE_MSG_REQ);
    // To check whether the process_id is wider than supported
    logic pid_invalid;
    assign pid_invalid = (((ddtc_dc.fsc.mode == 4'b0001) &
                           (|req_data.pid[19:8])) |
                          ((ddtc_dc.fsc.mode == 4'b0010) &
                           (|req_data.pid[19:17])));
    // If DC.tc.DPE is 1 and no valid process_id is given by the device, default value of zero is used
    rv_iommu::process_id_t process_id;
    assign process_id = (!req_data.pid_valid && ddtc_dc.tc.dpe) ? '0 : req_data.pid;
    // To determine if transaction is a store
    logic is_store;
    assign is_store = ((&req_data.ttype[1:0]) & (~req_data.ttype[3]));
    // To determine if transaction is read-for-execute
    logic is_rx;
    assign is_rx = (!req_data.ttype[3] & !req_data.ttype[1] & req_data.ttype[0]);

    //---------------
    // Error Signals
    //---------------
    logic [(rv_iommu::GPPNW39-1):0] iotlb_bad_gppn;
    assign iotlb_bad_gppn = rv_iommu::make_gppn(en_1S_q,
                                          iotlb_lu_content.content_1S.is_1G,
                                          iotlb_lu_content.content_1S.is_2M,
                                          req_data.iova[(rv_iommu::VLEN39-1):12],
                                          iotlb_lu_content.content_1S.ppn);
    logic                           error_q,        error_n;
    rv_iommu::cause_t               error_code_q,   error_code_n;
    logic [rv_iommu::GPLEN39-1:0]   error_gpaddr_q, error_gpaddr_n;
    logic                           error_2S_q,     error_2S_n;
    logic                           error_2S_int_q, error_2S_int_n;

    assign fault_data_o.trans_type       = req_data.ttype;
    assign fault_data_o.cause_code       = error_code_q;
    assign fault_data_o.iova             = req_data.iova;
    assign fault_data_o.gpaddr           = error_gpaddr_q;
    assign fault_data_o.did              = req_data.did;
    assign fault_data_o.pv               = req_data.pid_valid;
    assign fault_data_o.pid              = req_data.pid;
    assign fault_data_o.is_supervisor    = req_data.priv;
    assign fault_data_o.is_guest_pf      = error_2S_q;
    assign fault_data_o.is_implicit      = error_2S_int_q;

    //-------------------
    // Debug IF response
    //-------------------
    logic is_superpage_n, is_superpage_q;
    assign debug_resp_data_o.error          = error_q;
    assign debug_resp_data_o.is_superpage   = is_superpage_q;
    assign debug_resp_data_o.pbmt           = '0;
    assign debug_resp_data_o.ppn            = {{56-PLEN{1'b0}}, spaddr_q[PLEN-1:12]};

    //----------------------
    // Translation response
    //----------------------
    logic ignore_q, ignore_n;
    logic is_mrif_q, is_mrif_n;
    rv_iommu::mrifc_content_t mrif_q, mrif_n;
    assign trans_resp_data_o.error      = error_q;
    assign trans_resp_data_o.ignore     = ignore_q;
    assign trans_resp_data_o.spaddr     = spaddr_q;
    assign trans_resp_data_o.is_mrif    = is_mrif_q;
    assign trans_resp_data_o.mrif_data  = mrif_q;
    assign trans_resp_data_o.range      = range_q;
    assign trans_resp_data_o.bypass     = bypass_q;
    assign trans_resp_data_o.fault_code = error_code_q;
    assign trans_resp_data_o.w          = w_q;
    assign trans_resp_data_o.r          = r_q;
    assign trans_resp_data_o.x          = x_q;
    assign trans_resp_data_o.sum        = sum_q;
    assign trans_resp_data_o.g          = g_q;
    assign trans_resp_data_o.u          = u_q;
    assign trans_resp_data_o.t2gpa      = t2gpa_q;

    //----------------------
    // ATS Translation response
    //----------------------
    assign ats_trans_resp_data_o.error      = error_q;
    assign ats_trans_resp_data_o.ignore     = ignore_q;
    assign ats_trans_resp_data_o.spaddr     = spaddr_q;
    assign ats_trans_resp_data_o.is_mrif    = is_mrif_q;
    assign ats_trans_resp_data_o.mrif_data  = mrif_q;
    assign ats_trans_resp_data_o.range      = range_q;
    assign ats_trans_resp_data_o.bypass     = bypass_q;
    assign ats_trans_resp_data_o.fault_code = error_code_q;
    assign ats_trans_resp_data_o.w          = w_q;
    assign ats_trans_resp_data_o.r          = r_q;
    assign ats_trans_resp_data_o.x          = x_q;
    assign ats_trans_resp_data_o.sum        = sum_q;
    assign ats_trans_resp_data_o.g          = g_q;
    assign ats_trans_resp_data_o.u          = u_q;
    assign ats_trans_resp_data_o.t2gpa      = t2gpa_q;

    //------------------------------
    // Device Directory Table Cache
    //------------------------------
    rv_iommu_ddtc #(
        .RVIOMMUCfg     (RVIOMMUCfg),
        .dc_t           (dc_t),
        .ddtc_up_t      (ddtc_up_t)
    ) i_rv_iommu_ddtc (
        .clk_i          (clk_i),
        .rst_ni         (rst_ni),

        .inval_i        (iodirinval_i),

        .update_i       (ddtc_update),

        .lookup_i       (ddtc_lu),
        .lu_did_i       (ddtc_lu_did),
        .lu_content_o   (ddtc_dc),
        .lu_hit_o       (ddtc_lu_hit)
    );

    //-------------------------------
    // Device Directory Table Walker
    //-------------------------------
    rv_iommu_ddtw #(
        .RVIOMMUCfg         (RVIOMMUCfg),
        .addr_t             (addr_t),
        .paddr_t            (paddr_t),
        .dc_t               (dc_t),
        .ddtc_up_t          (ddtc_up_t),
        .axi_req_t          (axi_req_t),
        .axi_resp_t         (axi_resp_t)
    ) i_rv_iommu_ddtw (
        .clk_i              (clk_i),
        .rst_ni             (rst_ni),

        .init_ddtw_i        (ddtw_init),

        .active_o           ( ),
        .error_o            (ddtw_error),
        .cause_code_o       (ddtw_cause),

        .capabilities_i     (capabilities_i),
        .fctl_i             (fctl_i),
        .ddtp_i             (ddtp_i),

        .mem_req_o          (ddtw_axi_req_o),
        .mem_resp_i         (ddtw_axi_resp_i),

        .update_o           (ddtc_update),

        .req_did_i          (req_data.did),

        .imp_init_o         (ddtw_imp_init),
        .pdt_gppn_o         (ddtw_pdt_gppn),
        .iohgatp_ppn_fw_o   (iohgatp_ppn_fw),
        .imp_done_i         (imp_done),
        .imp_err_i          (imp_err),
        .pdt_ppn_i          (ddtw_pdt_ppn)
    );

    generate
    // PC supported
    if (RVIOMMUCfg.InclPC) begin : gen_pdt_modules

        // PDTC
        logic                    pdtc_lu;
        rv_iommu::device_id_t    pdtc_lu_did;
        rv_iommu::process_id_t   pdtc_lu_pid;
        assign pdtc_lu      = (state_q == PDT);
        assign pdtc_lu_did  = req_data.did;
        assign pdtc_lu_pid  = req_data.pid;

        logic pdtw_init;
        assign pdtw_init = pdtc_lu & ~pdtc_lu_hit;
        rv_iommu::ppn_t pdtw_pdt_ppn;
        assign pdtw_pdt_ppn = ptw_iotlb_update.content.content_2S.ppn;

        rv_iommu::pdtc_up_t pdtc_update;

        //-------------------------------
        // Process Directory Table Cache
        //-------------------------------
        rv_iommu_pdtc #(
            .RVIOMMUCfg     (RVIOMMUCfg)
        ) i_rv_iommu_pdtc (
            .clk_i          (clk_i),
            .rst_ni         (rst_ni),

            .inval_i        (iodirinval_i),

            .update_i       (pdtc_update),

            .lookup_i       (pdtc_lu),
            .lu_did_i       (pdtc_lu_did),
            .lu_pid_i       (pdtc_lu_pid),
            .lu_content_o   (pdtc_lu_content),
            .lu_hit_o       (pdtc_lu_hit)
        );

        //--------------------------------
        // Process Directory Table Walker
        //--------------------------------
        rv_iommu_pdtw #(
            .RVIOMMUCfg         (RVIOMMUCfg),
            .addr_t             (addr_t),
            .paddr_t            (paddr_t),
            .axi_req_t          (axi_req_t),
            .axi_resp_t         (axi_resp_t)
        ) i_rv_iommu_pdtw (
            .clk_i              (clk_i),
            .rst_ni             (rst_ni),

            .init_pdtw_i        (pdtw_init),

            .active_o           ( ),
            .error_o            (pdtw_error),
            .cause_code_o       (pdtw_cause),

            .capabilities_i     (capabilities_i),

            .mem_req_o          (pdtw_axi_req_o),
            .mem_resp_i         (pdtw_axi_resp_i),

            .update_o           (pdtc_update),

            .req_did_i          (req_data.did),
            .req_pid_i          (req_data.pid),

            .dc_sxl_i           (dc_q.tc.sxl),
            .en_2S_i            (dc_q.iohgatp.mode != rv_iommu::ModeBare),
            .pdtp_ppn_i         (dc_q.fsc.ppn),
            .pdtp_mode_i        (dc_q.fsc.mode),

            .imp_init_o         (pdtw_imp_init),
            .pdt_gppn_o         (pdtw_pdt_gppn),
            .imp_done_i         (imp_done),
            .imp_err_i          (imp_err),
            .pdt_ppn_i          (pdtw_pdt_ppn)
        );
    end
    else begin : no_pdt_modules
        assign pdtc_lu_content = '0;
        assign pdtc_lu_hit     = 1'b0;

        assign pdtw_error      = 1'b0;
        assign pdtw_cause      = '0;
        assign pdtw_axi_req_o  = '0;
        assign pdtw_imp_init   = 1'b0;
        assign pdtw_pdt_gppn   = '0;
    end
    endgenerate

    //----------------------------------
    // IO Translation Look-aside Buffer
    //----------------------------------
    rv_iommu_iotlb #(
        .RVIOMMUCfg     (RVIOMMUCfg)
    ) i_rv_iommu_iotlb (
        .clk_i          (clk_i),
        .rst_ni         (rst_ni),

        .inval_i        (iotinval_i),

        .update_i       (iotlb_update),

        .lookup_i       (iotlb_lu),
        .lu_vpn_i       (iotlb_lu_vpn),
        .lu_pscid_i     (iotlb_lu_pscid),
        .lu_gscid_i     (iotlb_lu_gscid),
        .en_1S_i        (en_1S_q),
        .en_2S_i        (en_2S_q),
        .lu_hit_o       (iotlb_lu_hit),
        .lu_content_o   (iotlb_lu_content)
    );

    //-------------------
    // Page Table Walker
    //-------------------
    rv_iommu_ptw #(
        .RVIOMMUCfg         (RVIOMMUCfg),
        .addr_t             (addr_t),
        .paddr_t            (paddr_t),
        .axi_req_t          (axi_req_t),
        .axi_resp_t         (axi_resp_t)
    ) i_rv_iommu_ptw (
        .clk_i              (clk_i),
        .rst_ni             (rst_ni),

        .init_ptw_i         (ptw_init),

        .active_o           ( ),
        .error_o            (ptw_error),
        .error_2S_o         (ptw_error_2S),
        .error_2S_int_o     (ptw_error_2S_int),
        .bad_gpaddr_o       (ptw_bad_gpaddr),
        .cause_code_o       (ptw_cause),

        .en_1S_i            (en_1S_q),
        .en_2S_i            (en_2S_q),
        .is_store_i         (is_store),
        .is_rx_i            (is_rx),
        .iosatp_ppn_i       (iosatp_ppn_q),
        .iohgatp_ppn_i      (iohgatp_ppn_q),

        .mem_resp_i         (ptw_axi_resp_i),
        .mem_req_o          (ptw_axi_req_o),

        .iova_i             (req_data.iova),
        .pscid_i            (pscid_q),
        .gscid_i            (gscid_q),
        .update_o           (ptw_iotlb_update),

        .msi_en_i           (msi_enabled),
        .msi_addr_mask_i    (msi_mask),
        .msi_addr_pattern_i (msi_pattern),
        .gpaddr_is_msi_o    (gpaddr_is_msi),
        .msi_1S_content_o   (msi_1S_content),

        .imp_init_i         (ddt_imp_trans_q | pdt_imp_trans_q),
        .pdt_gppn_i         (pdt_gppn_q),
        .imp_done_o         (imp_done),
        .imp_err_o          (imp_err)
    );

    //-------------------------
    // MSI Translation Support
    //-------------------------
    logic iova_is_msi;
    logic iova_is_msi_q, iova_is_msi_n;

    // MSI PTW
    logic msi_ptw_error;
    logic msi_ptw_ignore;
    rv_iommu::cause_t msi_ptw_cause;
    rv_iommu::iotlb_stage_content_t msi_1S_data_q, msi_1S_data_n;

    // MRIFC
    logic                        mrifc_lu_hit;
    rv_iommu::mrifc_content_t    mrifc_lu_content;

    generate
        // MSI Translation Enabled
        if (RVIOMMUCfg.MSITrans != rv_iommu_cfg::MSI_DISABLED) begin : gen_msi_support_tl

            rv_iommu::ppn_t msiptp_ppn;
            assign msiptp_ppn = dc_q.msiptp.ppn;

            logic msi_ptw_init;
            assign msi_ptw_init = (state_q == MSI) & ~iotlb_lu_hit & ~mrifc_lu_hit;

            rv_iommu::mrifc_up_t mrifc_update;

            assign iova_is_msi  =   (ddtc_dc.msiptp.mode != 4'b0000) & (is_store) &
                                    ((req_data.iova[rv_iommu::VLEN39-1:12] &
                                        ~ddtc_dc.msi_addr_mask.mask[rv_iommu::VPNW39-1:0]) ==
                                     (ddtc_dc.msi_addr_pattern.pattern[rv_iommu::VPNW39-1:0] &
                                        ~ddtc_dc.msi_addr_mask.mask[rv_iommu::VPNW39-1:0]));
            assign msi_enabled  = (dc_q.msiptp.mode != 4'b0000);
            assign msi_mask     = dc_q.msi_addr_mask.mask[rv_iommu::GPPNW39-1:0];
            assign msi_pattern  = dc_q.msi_addr_pattern.pattern[rv_iommu::GPPNW39-1:0];

            //-----------------------
            // MSI Page Table Walker
            //-----------------------
            rv_iommu_msiptw #(
                .RVIOMMUCfg         (RVIOMMUCfg),
                .addr_t             (addr_t),
                .paddr_t            (paddr_t),
                .axi_req_t          (axi_req_t),
                .axi_resp_t         (axi_resp_t)
            ) i_rv_iommu_msiptw (
                .clk_i              (clk_i),
                .rst_ni             (rst_ni),

                .init_msi_ptw_i     (msi_ptw_init),

                .error_o            (msi_ptw_error),
                .cause_code_o       (msi_ptw_cause),
                .ignore_o           (msi_ptw_ignore),

                .req_iova_i         (req_data.iova),
                .pscid_i            (pscid_q),
                .gscid_i            (gscid_q),
                .en_1S_i            (en_1S_q),
                .is_rx_i            (is_rx),

                .msiptp_ppn_i       (msiptp_ppn),
                .msi_addr_mask_i    (msi_mask),

                .content_1S_i       (msi_1S_data_q),

                .iotlb_update_o     (msi_iotlb_update),
                .mrifc_update_o     (mrifc_update),

                .mem_resp_i         (msiptw_axi_resp_i),
                .mem_req_o          (msiptw_axi_req_o)
            );

            //----------------------------------------
            // Memory-Resident Interrupt File Support
            //----------------------------------------

            // MRIF Support enabled
            if (RVIOMMUCfg.MSITrans == rv_iommu_cfg::MSI_BT_MRIF) begin : gen_mrif_support_tl

                logic                           mrifc_lu;
                logic [rv_iommu::GPPNW39-1:0]   mrifc_lu_vpn;
                rv_iommu::pscid_t               mrifc_lu_pscid;
                rv_iommu::gscid_t               mrifc_lu_gscid;
                assign mrifc_lu         = (state_q == PT) || (state_q == MSI);
                assign mrifc_lu_vpn     = req_data.iova[rv_iommu::GPLEN39-1:12];
                assign mrifc_lu_pscid   = pscid_q;
                assign mrifc_lu_gscid   = gscid_q;

                //--------------------------------------
                // Memory-Resident Interrupt File Cache
                //--------------------------------------
                rv_iommu_mrifc #(
                    .RVIOMMUCfg     (RVIOMMUCfg)
                ) i_rv_iommu_mrifc (
                    .clk_i          (clk_i),
                    .rst_ni         (rst_ni),

                    .inval_i        (iotinval_i),

                    .update_i       (mrifc_update),

                    .lookup_i       (mrifc_lu),
                    .lu_vpn_i       (mrifc_lu_vpn),
                    .lu_pscid_i     (mrifc_lu_pscid),
                    .lu_gscid_i     (mrifc_lu_gscid),
                    .en_1S_i        (en_1S_q),
                    .en_2S_i        (en_2S_q),
                    .lu_hit_o       (mrifc_lu_hit),
                    .lu_content_o   (mrifc_lu_content)
                );
            end

            // MRIF Support disabled
            else begin : gen_mrif_support_tl_disabled

                assign mrifc_lu_hit     = 1'b0;
                assign mrifc_lu_content = '0;
            end
        end

        // MSI Translation Disabled
        else begin : gen_msi_support_tl_disabled

            assign iova_is_msi      = 1'b0;

            assign msi_enabled      = 1'b0;
            assign msi_mask         = '0;
            assign msi_pattern      = '0;

            assign msi_ptw_error    = 1'b0;
            assign msi_ptw_ignore   = 1'b0;
            assign msi_ptw_cause    = '0;

            assign msi_iotlb_update = '0;

            assign msiptw_axi_req_o = '0;
        end
    endgenerate

    //---------------------
    // Translation Control
    //---------------------
    always_comb begin : translation_ctl_comb

        // Default values
        debug_resp_valid_o     = 1'b0;
        trans_resp_valid_o     = 1'b0;
        ats_trans_resp_valid_o = 1'b0;
        fault_valid_o          = 1'b0;

        hpm_events_o                = '0;
        hpm_events_o.filters.did    = req_data.did;
        hpm_events_o.filters.pid_v  = req_data.pid_valid;
        hpm_events_o.filters.pid    = req_data.pid;
        hpm_events_o.filters.gscid  = gscid_q;
        hpm_events_o.filters.pscid  = pscid_q;

        state_n         = state_q;

        dc_n            = dc_q;
        pc_n            = pc_q;
        en_1S_n         = en_1S_q;
        en_2S_n         = en_2S_q;
        gscid_n         = gscid_q;
        pscid_n         = pscid_q;
        iohgatp_ppn_n   = iohgatp_ppn_q;
        iosatp_ppn_n    = iosatp_ppn_q;
        spaddr_n        = spaddr_q;
        ddt_imp_trans_n = ddt_imp_trans_q;
        pdt_imp_trans_n = pdt_imp_trans_q;
        pdt_gppn_n      = pdt_gppn_q;

        error_n         = error_q;
        error_code_n    = error_code_q;
        error_gpaddr_n  = error_gpaddr_q;
        error_2S_n      = error_2S_q;
        error_2S_int_n  = error_2S_int_q;

        ignore_n        = ignore_q;
        is_superpage_n  = is_superpage_q;
        is_mrif_n       = is_mrif_q;
        iova_is_msi_n   = iova_is_msi_q;
        msi_1S_data_n   = msi_1S_data_q;
        mrif_n          = mrif_q;

        range_n         = range_q;
        bypass_n        = bypass_q;
        x_n             = x_q;
        w_n             = w_q;
        r_n             = r_q;
        u_n             = u_q;
        g_n             = g_q;
        t2gpa_n         = t2gpa_q;
        sum_n           = sum_q;

        unique case (state_q)

            // Preliminary checks
            IDLE: begin

                if (req_valid) begin

                    // Clear error registers
                    error_n         = 1'b0;
                    error_2S_n      = 1'b0;
                    error_2S_int_n  = 1'b0;
                    error_gpaddr_n  = '0;
                    ignore_n        = 1'b0;
                    is_mrif_n       = 1'b0;

                    // default
                    spaddr_n        = paddr_t'(req_data.iova);
                    state_n         = COMPLETE;
                    error_code_n    = rv_iommu::TRANS_TYPE_DISALLOWED;

                    // Signal event
                    hpm_events_o.valid = 1'b1;
                    hpm_events_o.etype_msk = (is_translated) ?
                                             (rv_iommu::hpm_etype_mask_t'(1) << rv_iommu::T_REQ) :
                                             ((is_pcie_ats_req) ?
                                              (rv_iommu::hpm_etype_mask_t'(1) << rv_iommu::ATS_REQ) :
                                              (rv_iommu::hpm_etype_mask_t'(1) << rv_iommu::UT_REQ));
                    hpm_events_o.filters.gscid_v    = 1'b0;
                    hpm_events_o.filters.pscid_v    = 1'b0;

                    // From Spec:
                    // If ddtp.iommu_mode == Off then stop and report "All inbound transactions disallowed" (cause = 256).
                    if (ddtp_i.iommu_mode.q == 4'b0000) begin
                        state_n         = ERROR;
                        error_code_n    = rv_iommu::ALL_INB_TRANSACTIONS_DISALLOWED;
                    end

                    // From Spec:
                    // If ddtp.iommu_mode == Bare and any of the following conditions (*) hold
                    // then stop and report "Transaction type disallowed" (cause = 260).
                    else if (ddtp_i.iommu_mode.q == 4'b0001) begin

                        // (*) If the transaction is a translated request or a PCIe ATS request
                        if (is_translated || is_pcie_ats_req) begin
                            state_n = ERROR;
                        end

                        // else the translation process is completed with the IOVA as the translated address
                    end

                    // From Spec:
                    // If the device_id is wider than supported by the IOMMU, then stop
                    // and report "Transaction type disallowed" (cause = 260).
                    else if ((ddtp_i.iommu_mode.q == 4'b0011 && (|req_data.did[23:15])) ||
                                (ddtp_i.iommu_mode.q == 4'b0010 && (|req_data.did[23:6]))) begin
                        state_n = ERROR;
                    end

                    // IOMMU is not in bare mode and no errors ocurred. Lookup DDTC
                    else begin
                        state_n = DDT;
                    end
                end
            end

            // DDTC lookup and DDT Walk
            DDT: begin

                // default
                error_code_n    = rv_iommu::TRANS_TYPE_DISALLOWED;

                // Signal DDT Walk if occurred
                hpm_events_o.valid              = ~ddtc_lu_hit;
                hpm_events_o.etype_msk          = (rv_iommu::hpm_etype_mask_t'(1) << rv_iommu::DDTW);
                hpm_events_o.filters.gscid_v    = 1'b0;
                hpm_events_o.filters.pscid_v    = 1'b0;

                /*
                  A DDT Walk may end in:
                    (1) Error;
                    (2) Implicit 2nd-stage translation;
                    (3) DDTC update and hit
                */

                // (1) DDTW error
                if (ddtw_error) begin
                    error_code_n    = ddtw_cause;
                    state_n         = ERROR;
                end

                // (2) Request implicit 2nd-stage translation
                if (ddtw_imp_init) begin
                    ddt_imp_trans_n = 1'b1;
                    en_1S_n         = 1'b0;
                    en_2S_n         = 1'b1;
                    pdt_gppn_n      = ddtw_pdt_gppn;
                    iohgatp_ppn_n   = iohgatp_ppn_fw;
                    state_n         = PT;
                end

                // (3) DDTC hit
                if (ddtc_lu_hit) begin
                    dc_n            = ddtc_dc;
                    iova_is_msi_n   = iova_is_msi;
                    state_n         = COMPLETE;

                    // From Spec:
                    // If any of the following conditions hold then stop and report "Transaction type disallowed" (cause = 260).
                    //  -   Transaction type is a Translated request or is a PCIe ATS Translation request and DC.tc.EN_ATS is 0.
                    //  -   Transaction type is PCIe Page request and DC.tc.EN_ATS or DC.tc.EN_PRI is 0.
                    //  -   Transaction has a valid process_id and DC.tc.PDTV is 0.
                    //  -   Transaction has a valid process_id and DC.tc.PDTV is 1 and the process_id is
                    //      wider than that supported by pdtp.MODE.
                    //  -   Transaction type is not supported by the IOMMU.
                    //  -   For requests without a process_id the privilege mode must be User.
                    if (((is_translated || is_pcie_ats_req) && !ddtc_dc.tc.en_ats)          ||
                        (is_pcie_page_req && (!ddtc_dc.tc.en_ats || !ddtc_dc.tc.en_pri))    ||
                        (req_data.pid_valid && !ddtc_dc.tc.pdtv)                            ||
                        (req_data.pid_valid && ddtc_dc.tc.pdtv && pid_invalid)              ||
                        (!req_data.pid_valid && !ddtc_dc.tc.dpe && req_data.priv)) begin
                        state_n = (ddtc_dc.tc.dtf) ? (COMPLETE) : (ERROR);
                    end

                    else begin

                        // Translated request
                        if (is_translated) begin

                            // If DC.tc.T2GPA = 1, translated requests are performed using a GPA
                            if (ddtc_dc.tc.t2gpa) begin
                                // MSI / Normal translation
                                if (ddtc_dc.iohgatp.mode != rv_iommu::ModeBare) begin
                                    en_1S_n = 1'b0;
                                    en_2S_n = 1'b1;
                                    gscid_n = ddtc_dc.iohgatp.gscid;
                                    iohgatp_ppn_n = ddtc_dc.iohgatp.ppn;
                                    state_n = (iova_is_msi) ? (MSI) : (PT);
                                end

                                // else is a Bare translation
                                // Translation completed
                            end

                            // When DC.tc.T2GPA = 0, translated requests are performed using an SPA
                            // Translation completed
                        end

                        // Untranslated request
                        else begin

                            // No Process Context associated with the device
                            if (!ddtc_dc.tc.pdtv) begin
                                // MSI / Normal translation
                                if ((ddtc_dc.fsc.mode != rv_iommu::ModeBare) ||
                                    (ddtc_dc.iohgatp.mode != rv_iommu::ModeBare)) begin
                                    en_1S_n         = (ddtc_dc.fsc.mode != rv_iommu::ModeBare);
                                    en_2S_n         = (ddtc_dc.iohgatp.mode != rv_iommu::ModeBare);
                                    gscid_n         = ddtc_dc.iohgatp.gscid;
                                    pscid_n         = ddtc_dc.ta.pscid;
                                    iohgatp_ppn_n   = ddtc_dc.iohgatp.ppn;
                                    iosatp_ppn_n    = ddtc_dc.fsc.ppn;
                                    state_n = (iova_is_msi && (ddtc_dc.fsc.mode == rv_iommu::ModeBare)) ?
                                              (MSI) :
                                              (PT);
                                end

                                // else is a Bare translation
                                // Translation completed
                            end

                            // Process Context associated with the device
                            else begin

                                // From Spec:
                                // If DC.tc.DPE is 0 and there is no process_id associated with the transaction, or if
                                // pdtp.MODE = Bare perform first-stage translation in Bare mode
                                if ((!req_data.pid_valid && !ddtc_dc.tc.dpe) || (ddtc_dc.fsc.mode == 4'b0000)) begin
                                    // MSI / Normal translation
                                    if (ddtc_dc.iohgatp.mode != rv_iommu::ModeBare) begin
                                        en_1S_n         = 1'b0;
                                        en_2S_n         = 1'b1;
                                        gscid_n         = ddtc_dc.iohgatp.gscid;
                                        iohgatp_ppn_n   = ddtc_dc.iohgatp.ppn;
                                        state_n         = (iova_is_msi) ? (MSI) : (PT);
                                    end

                                    // else is a Bare translation
                                    // Translation completed
                                end
                                else begin
                                    state_n = PDT;
                                end
                            end
                        end
                    end
                end
            end

            // PDTC lookup and PDT Walk
            PDT: begin

                // PC supported
                if (RVIOMMUCfg.InclPC) begin : gen_pdt_state

                    // default
                    error_code_n = rv_iommu::TRANS_TYPE_DISALLOWED;

                    // Signal DDT Walk if occurred
                    hpm_events_o.valid              = ~pdtc_lu_hit;
                    hpm_events_o.etype_msk          = (rv_iommu::hpm_etype_mask_t'(1) << rv_iommu::PDTW);
                    hpm_events_o.filters.gscid_v    = 1'b1;
                    hpm_events_o.filters.gscid      = dc_q.iohgatp.gscid;
                    hpm_events_o.filters.pscid_v    = 1'b0;

                    /*
                      A PDT Walk may end in:
                        (1) Error;
                        (2) Implicit 2nd-stage translation;
                        (3) PDTC update and hit
                    */

                    // (1) PDTW error
                    if (pdtw_error) begin
                        error_code_n    = pdtw_cause;
                        state_n = (dc_q.tc.dtf) ? (COMPLETE) : (ERROR);
                    end

                    // (2) Request implicit 2nd-stage translation
                    if (pdtw_imp_init) begin
                        pdt_imp_trans_n = 1'b1;
                        en_1S_n         = 1'b0;
                        en_2S_n         = 1'b1;
                        pdt_gppn_n      = pdtw_pdt_gppn;
                        iohgatp_ppn_n   = dc_q.iohgatp.ppn;
                        state_n         = PT;
                    end

                    // (3) PDTC hit
                    if (pdtc_lu_hit) begin
                        pc_n    = pdtc_lu_content;
                        state_n = COMPLETE;

                        // From Spec:
                        // Hold and stop if the transaction requests supervisor privilege but PC.ta.ENS is not set"
                        if (req_data.priv && !pdtc_lu_content.ta.ens) begin
                            state_n = (dc_q.tc.dtf) ? (COMPLETE) : (ERROR);
                        end

                        else begin
                            // MSI / Normal translation
                            if ((pdtc_lu_content.fsc.mode != rv_iommu::ModeBare) ||
                                        (dc_q.iohgatp.mode != rv_iommu::ModeBare)) begin
                                en_1S_n         = (pdtc_lu_content.fsc.mode != rv_iommu::ModeBare);
                                en_2S_n         = (dc_q.iohgatp.mode != rv_iommu::ModeBare);
                                gscid_n         = dc_q.iohgatp.gscid;
                                pscid_n         = pdtc_lu_content.ta.pscid;
                                iohgatp_ppn_n   = dc_q.iohgatp.ppn;
                                iosatp_ppn_n    = pdtc_lu_content.fsc.ppn;
                                state_n = (iova_is_msi_q && (pdtc_lu_content.fsc.mode == rv_iommu::ModeBare)) ?
                                        (MSI) :
                                        (PT);
                            end

                            // else is a Bare translation
                            // Translation completed
                        end
                    end
                end

                // PC not supported
                else begin : no_pdt_state
                    state_n = ERROR;
                    error_code_n = rv_iommu::TRANS_TYPE_DISALLOWED;
                end

            end

            // IOTLB lookup and PTW Walk
            PT: begin

                msi_1S_data_n = msi_1S_content;

                // Signal PT Walk if occurred
                hpm_events_o.valid              = ~iotlb_lu_hit;
                hpm_events_o.etype_msk          = (rv_iommu::hpm_etype_mask_t'(1) << rv_iommu::IOTLB_MISS) |
                                                  (rv_iommu::hpm_etype_mask_t'(en_1S_q) << rv_iommu::S1_PTW) |
                                                  (rv_iommu::hpm_etype_mask_t'(en_2S_q) << rv_iommu::S2_PTW);
                hpm_events_o.filters.gscid_v    = 1'b1;
                hpm_events_o.filters.pscid_v    = 1'b1;

                /*
                  A Page Table Walk may end in:
                    (1) Error;
                    (2) Successful implicit 2nd-stage translation;
                    (3) MSI GPA;
                    (4) IOTLB update and hit
                */

                // (1) PTW error
                if (ptw_error) begin
                    error_2S_n      = ptw_error_2S;
                    error_2S_int_n  = ptw_error_2S_int;
                    error_gpaddr_n  = ptw_bad_gpaddr;
                    error_code_n    = ptw_cause;
                    state_n         = (dc_q.tc.dtf) ?
                                        (COMPLETE) :
                                        (ERROR);
                end

                // (2) Implicit 2nd-stage translation completed
                if (imp_done) begin
                    if (ddt_imp_trans_q) begin
                        ddt_imp_trans_n = 1'b0;
                        state_n         = DDT;
                    end
                    else if (pdt_imp_trans_q) begin
                        pdt_imp_trans_n = 1'b0;
                        state_n         = PDT;
                    end
                end

                // (3) GPA is MSI address
                if (gpaddr_is_msi) begin
                    state_n = MSI;
                end

                // (4) IOTLB hit
                if (iotlb_lu_hit) begin
                    state_n         = COMPLETE;
                    is_superpage_n  = iotlb_lu_content.content_1S.is_2M |
                                      iotlb_lu_content.content_1S.is_1G |
                                      iotlb_lu_content.content_2S.is_2M |
                                      iotlb_lu_content.content_2S.is_1G;

                    if(en_2S_q && en_2S_q) begin
                       x_n = iotlb_lu_content.content_2S.x;
                       w_n = iotlb_lu_content.content_2S.w;
                       r_n = iotlb_lu_content.content_2S.r;
                       g_n = iotlb_lu_content.content_2S.g;
                       u_n = iotlb_lu_content.content_2S.u;
                    end else if(en_2S_q) begin
                       x_n = iotlb_lu_content.content_2S.x;
                       w_n = iotlb_lu_content.content_2S.w;
                       r_n = iotlb_lu_content.content_2S.r;
                       g_n = iotlb_lu_content.content_2S.g;
                       u_n = iotlb_lu_content.content_2S.u;
                    end else if(en_1S_q) begin
                       x_n = iotlb_lu_content.content_1S.x;
                       w_n = iotlb_lu_content.content_1S.w;
                       r_n = iotlb_lu_content.content_1S.r;
                       g_n = iotlb_lu_content.content_1S.g;
                       u_n = iotlb_lu_content.content_1S.u;
                    end
                    // Identity tranlsation: GVA=SPA
                    bypass_n = dc_q.iohgatp.mode == ModeBare &&
                               dc_q.fsc.mode == ModeBare;
                    range_n  = iotlb_lu_content.content_1S.is_2M ?
                               3'b011 :
                               iotlb_lu_content.content_1S.is_1G ?
                               3'b110 :
                               3'b000 ;
                    sum_n    = pc_q.ta.sum;
                    t2gpa_n  = ddtc_dc.tc.t2gpa;

                    /*
                        First-stage checks: A fault is generated if:
                        - (1): W transaction and pte.w=0;
                        - (2): RX transaction and pte.x=0;
                        - (3): U-mode transaction and pte.u=0;
                        - (4): S-mode transaction, pte.u=1 and (PC.SUM=0 or transaction is RX)
                    */
                    if (en_1S_q && (
                        (is_store && !iotlb_lu_content.content_1S.w                                 ) ||    // (1)
                        (is_rx && !iotlb_lu_content.content_1S.r && !iotlb_lu_content.content_1S.x  ) ||    // (2)
                        (!req_data.priv && !iotlb_lu_content.content_1S.u                           ) ||    // (3)
                        (req_data.priv && iotlb_lu_content.content_1S.u && (!pc_q.ta.sum || is_rx)  ))      // (4)
                    ) begin
                            state_n = (dc_q.tc.dtf) ? (COMPLETE) : (ERROR);
                            if (is_store)
                                error_code_n = rv_iommu::STORE_PAGE_FAULT;
                            else
                                error_code_n = rv_iommu::LOAD_PAGE_FAULT;
                    end

                    /*
                        Second-stage checks: A fault is generated if:
                        - (1): W transaction and pte.w=0;
                        - (2): RX transaction and pte.x=0;
                    */
                    else if (en_2S_q && (
                             (is_store && !iotlb_lu_content.content_2S.w) ||    // (1)
                             (is_rx && !iotlb_lu_content.content_2S.x   ))      // (2)
                    ) begin

                            state_n = (dc_q.tc.dtf) ? (COMPLETE) : (ERROR);
                            error_gpaddr_n  = {iotlb_bad_gppn, req_data.iova[11:0]};
                            error_2S_n      = 1'b1;
                            if (is_store)
                                error_code_n = rv_iommu::STORE_GUEST_PAGE_FAULT;
                            else
                                error_code_n = rv_iommu::LOAD_GUEST_PAGE_FAULT;
                    end

                    else begin

                        // Start from the PPN if 2S is enabled
                        spaddr_n = {((en_2S_q) ?
                                     (iotlb_lu_content.content_2S.ppn[PPNW-1:0]) :
                                     (iotlb_lu_content.content_1S.ppn[PPNW-1:0])
                                    ), req_data.iova[11:0]};

                        // Superpages
                        if (en_1S_q && en_2S_q) begin
                            unique case ({iotlb_lu_content.content_1S.is_2M,
                                           iotlb_lu_content.content_1S.is_1G,
                                            iotlb_lu_content.content_2S.is_2M,
                                             iotlb_lu_content.content_2S.is_1G})

                                // 1-S: 4k | 2-S: 2M:   {PPN[2], PPN[1],  GPPN[0], OFF}
                                4'b0010:    spaddr_n[20:12] = iotlb_lu_content.content_1S.ppn[20:12];

                                // 1-S: 2M | 2-S: 2M:   {PPN[2], PPN[1],  VPN[0],  OFF}
                                // 1-S: 1G | 2-S: 2M:   {PPN[2], PPN[1],  VPN[0],  OFF}
                                4'b1010, 4'b0110:   spaddr_n[20:12] = req_data.iova[20:12];

                                // 1-S: 4k | 2-S: 1G:   {PPN[2], GPPN[1], GPPN[0], OFF}
                                4'b0001:    spaddr_n[29:12] = iotlb_lu_content.content_1S.ppn[29:12];

                                // 1-S: 1G | 2-S: 1G:   {PPN[2], VPN[1],  VPN[0],  OFF}
                                4'b0101:    spaddr_n[29:12] = req_data.iova[29:12];

                                // 1-S: 2M | 2-S: 1G:   {PPN[2], GPPN[1], VPN[0],  OFF}
                                4'b1001:    spaddr_n[29:12] = {iotlb_lu_content.content_1S.ppn[29:21], req_data.iova[20:12]};

                                default:;
                                    // 1-S: 4k | 2-S: 4k:   {PPN[2], PPN[1],  PPN[0],  OFF}
                                    // 1-S: 2M | 2-S: 4k:   {PPN[2], PPN[1],  PPN[0],  OFF}
                                    // 1-S: 1G | 2-S: 4k:   {PPN[2], PPN[1],  PPN[0],  OFF}
                            endcase
                        end
                        else begin
                            if (iotlb_lu_content.content_2S.is_1G || iotlb_lu_content.content_1S.is_1G)
                                spaddr_n[29:12] = req_data.iova[29:12];
                            if (iotlb_lu_content.content_2S.is_2M || iotlb_lu_content.content_1S.is_2M)
                                spaddr_n[20:12] = req_data.iova[20:12];
                        end

                        // Encode translated PPN acording to the size
                        if (req_data.is_debug) begin
                            if (iotlb_lu_content.content_2S.is_2M || iotlb_lu_content.content_1S.is_2M)
                                spaddr_n[20:12] = {1'b0, {8{1'b1}}};
                            else if (iotlb_lu_content.content_2S.is_1G || iotlb_lu_content.content_1S.is_1G)
                                spaddr_n[29:12] = {1'b0, {17{1'b1}}};
                        end
                    end
                end
            end

            // IOTLB/MRIFC lookup and PTW Walk
            MSI: begin

                // MSI Translation supported
                if (RVIOMMUCfg.MSITrans != rv_iommu_cfg::MSI_DISABLED) begin

                    // default
                    error_code_n    = rv_iommu::TRANS_TYPE_DISALLOWED;
                    spaddr_n        = {iotlb_lu_content.content_2S.ppn[PPNW-1:0],
                                        req_data.iova[11:0]};
                    mrif_n          = mrifc_lu_content;

                    /*
                      An MSI Page Table Walk may end in:
                        (1) Error;
                        (2) Ignored transaction;
                        (3) IOTLB update and hit;
                        (4) MRIFC update and hit
                    */

                    // (1) MSI PTW error
                    if (msi_ptw_error) begin
                        error_code_n = msi_ptw_cause;
                        state_n = (dc_q.tc.dtf) ? (COMPLETE) : (ERROR);
                    end

                    // (2) Ignore transaction
                    if (msi_ptw_ignore) begin
                        ignore_n    = 1'b1;
                        state_n     = COMPLETE;
                    end

                    // (3) MSI PTE in BT mode
                    if (iotlb_lu_hit) begin
                        state_n     = COMPLETE;
                    end

                    // (4) MSI PTE in MRIF mode
                    if (mrifc_lu_hit) begin
                        state_n     = COMPLETE;
                        is_mrif_n   = 1'b1;
                        if (req_data.is_debug) begin
                            state_n = ERROR;
                        end
                    end
                end

                // MSI Translation not supported
                else begin
                    state_n         = ERROR;
                    error_code_n    = rv_iommu::TRANS_TYPE_DISALLOWED;
                end
            end

            ERROR: begin
                if(req_data.ttype == rv_iommu::PCIE_ATS_TRANS_REQ) begin
                    if( error_code_q != INSTR_PAGE_FAULT       &&
                        error_code_q != LOAD_PAGE_FAULT        &&
                        error_code_q != STORE_PAGE_FAULT       &&
                        error_code_q != INSTR_GUEST_PAGE_FAULT &&
                        error_code_q != LOAD_GUEST_PAGE_FAULT  &&
                        error_code_q != STORE_GUEST_PAGE_FAULT &&
                        error_code_q != MSI_PTE_INVALID        &&
                        error_code_q != PDT_ENTRY_INVALID) begin

                        error_n = 1'b1;
                        state_n = COMPLETE;
                    end else begin
                        error_n = 1'b1;
                        fault_valid_o = 1'b1;
                        if (fault_ready_i) begin
                            state_n = COMPLETE;
                        end
                    end
                end else begin
                    error_n = 1'b1;
                    fault_valid_o = 1'b1;
                    if (fault_ready_i) begin
                        state_n = COMPLETE;
                    end
                end
            end

            // Translation completion
            COMPLETE: begin

                // Debug translation
                if (req_data.is_debug) begin
                    debug_resp_valid_o  = 1'b1;
                    if (debug_resp_ready_i) begin
                        state_n = IDLE;
                    end
                end
                // ATS transltion
                else if(req_data.ttype == rv_iommu::PCIE_ATS_TRANS_REQ) begin
                    ats_trans_resp_valid_o  = 1'b1;
                    if (ats_trans_resp_ready_i) begin
                        state_n = IDLE;
                    end
                end
                // Normal translation
                else begin
                    trans_resp_valid_o  = 1'b1;
                    if (trans_resp_ready_i) begin
                        state_n = IDLE;
                    end
                end
            end

            default: begin
                state_n = IDLE;
            end
        endcase
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin : translation_ctl_seq
        if (!rst_ni) begin
            state_q         <= IDLE;

            dc_q            <= '0;
            pc_q            <= '0;
            en_1S_q         <= 1'b0;
            en_2S_q         <= 1'b0;
            gscid_q         <= '0;
            pscid_q         <= '0;
            iohgatp_ppn_q   <= '0;
            iosatp_ppn_q    <= '0;
            spaddr_q        <= '0;
            pdt_gppn_q      <= '0;

            error_q         <= 1'b0;
            error_code_q    <= '0;
            error_gpaddr_q  <= '0;
            error_2S_q      <= 1'b0;
            error_2S_int_q  <= 1'b0;

            ignore_q        <= 1'b0;
            ddt_imp_trans_q <= 1'b0;
            pdt_imp_trans_q <= 1'b0;
            is_superpage_q  <= 1'b0;
            is_mrif_q       <= 1'b0;
            iova_is_msi_q   <= 1'b0;
            msi_1S_data_q   <= '0;
            mrif_q          <= '0;
            range_q         <= '0;
            bypass_q        <= '0;
            x_q             <= '0;
            w_q             <= '0;
            r_q             <= '0;
            sum_q           <= '0;
            u_q             <= '0;
            g_q             <= '0;
            t2gpa_q         <= '0;
        end

        else begin
            state_q         <= state_n;

            dc_q            <= dc_n;
            pc_q            <= pc_n;
            en_1S_q         <= en_1S_n;
            en_2S_q         <= en_2S_n;
            gscid_q         <= gscid_n;
            pscid_q         <= pscid_n;
            iohgatp_ppn_q   <= iohgatp_ppn_n;
            iosatp_ppn_q    <= iosatp_ppn_n;
            spaddr_q        <= spaddr_n;
            ddt_imp_trans_q <= ddt_imp_trans_n;
            pdt_imp_trans_q <= pdt_imp_trans_n;
            pdt_gppn_q      <= pdt_gppn_n;

            error_q         <= error_n;
            error_code_q    <= error_code_n;
            error_gpaddr_q  <= error_gpaddr_n;
            error_2S_q      <= error_2S_n;
            error_2S_int_q  <= error_2S_int_n;

            ignore_q        <= ignore_n;
            is_superpage_q  <= is_superpage_n;
            is_mrif_q       <= is_mrif_n;
            iova_is_msi_q   <= iova_is_msi_n;
            msi_1S_data_q   <= msi_1S_data_n;
            mrif_q          <= mrif_n;
            range_q         <= range_n;
            bypass_q        <= bypass_n;
            x_q             <= x_n;
            w_q             <= w_n;
            r_q             <= r_n;
            u_q             <= u_n;
            g_q             <= g_n;
            sum_q           <= sum_n;
            t2gpa_q         <= t2gpa_n;
        end
    end

endmodule
