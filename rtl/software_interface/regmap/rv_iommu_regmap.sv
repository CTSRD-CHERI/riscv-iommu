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
// Description: IOMMU memory-mapped register interface package.
//              Defines data structures and other register-related data.
//              This module was developed using LowRISC `reggen` tool.

`include "common_cells/assertions.svh" 

module rv_iommu_regmap #(
  /// RISC-V IOMMU configuration struct
  parameter rv_iommu_cfg::rv_iommu_cfg_t RVIOMMUCfg = rv_iommu_cfg::NullCfg,
  /// Register data width
  parameter int unsigned DataWidth = 32,

  /// Register data types
  parameter type iommu_reg_req_t  = logic,
  parameter type iommu_reg_rsp_t  = logic
  ) (
  input  logic      clk_i,
  input  logic      rst_ni,
  // From SW
  input  iommu_reg_req_t reg_req_i,
  output iommu_reg_rsp_t reg_rsp_o,
  // To HW
  output rv_iommu_reg_pkg::iommu_reg2hw_t reg2hw_o,
  input  rv_iommu_reg_pkg::iommu_hw2reg_t hw2reg_i,

  input  logic devmode_i,   // If 1, explicit error return for unmapped register access
  input  logic in_flight_i  // The IOMMU is currently processing a translation
);

  import rv_iommu_reg_pkg::* ;
  import rv_iommu_field_pkg::* ;

  localparam int unsigned StrbWidth = (DataWidth / 8);

  // Aux parameters to avoid verilator warnings
  localparam int unsigned NZ_NHPMCTR  = (RVIOMMUCfg.NumHpmCounters > 0) ? (RVIOMMUCfg.NumHpmCounters) : (32'd1);
  localparam int unsigned LOG2_INTVEC = (RVIOMMUCfg.NumIntVec == 1) ? (32'd1) : ($clog2(RVIOMMUCfg.NumIntVec));

  // register signals
  // EXP: Register signals to connect the SW register interface port to the register file.
  logic           			  reg_we;
  logic           			  reg_re;
  logic [12-1:0]          reg_addr;
  logic [DataWidth-1:0]   reg_wdata;
  logic [StrbWidth-1:0] 	reg_be;
  logic [DataWidth-1:0]   reg_rdata;
  logic           			  reg_error;

  logic addrmiss;
  logic [215:0] wr_err;
  logic [DataWidth-1:0] reg_rdata_next;

  assign reg_we = reg_req_i.valid & reg_req_i.write;
  assign reg_re = reg_req_i.valid & ~reg_req_i.write;
  assign reg_addr = reg_req_i.addr[11:0];
  assign reg_wdata = reg_req_i.wdata;
  assign reg_be = reg_req_i.wstrb;
  assign reg_rsp_o.rdata = reg_rdata;
  assign reg_rsp_o.error = reg_error;
  assign reg_rsp_o.ready = 1'b1;

  assign reg_rdata = reg_re ? reg_rdata_next : '0;
  assign reg_error = (devmode_i & addrmiss) | (reg_we & |wr_err);

  // caps (low)
  logic [7:0] 	capabilities_version_qs;
  logic 		    capabilities_sv32_qs;
  logic 		    capabilities_sv39_qs;
  logic 		    capabilities_sv48_qs;
  logic 		    capabilities_sv57_qs;
  logic 		    capabilities_svpbmt_qs;
  logic 		    capabilities_sv32x4_qs;
  logic 		    capabilities_sv39x4_qs;
  logic 		    capabilities_sv48x4_qs;
  logic 		    capabilities_sv57x4_qs;
  logic 		    capabilities_amo_mrif_qs;
  logic 		    capabilities_msi_flat_qs;
  logic 		    capabilities_msi_mrif_qs;
  logic 		    capabilities_amo_hwad_qs;
  logic 		    capabilities_ats_qs;
  logic 		    capabilities_t2gpa_qs;
  logic 		    capabilities_endi_qs;
  logic [1:0] 	capabilities_igs_qs;
  logic 		    capabilities_hpm_qs;
  logic 		    capabilities_dbg_qs;

  // caps (high)
  logic [5:0] 	capabilities_pas_qs;
  logic 		    capabilities_pd8_qs;
  logic 		    capabilities_pd17_qs;
  logic 		    capabilities_pd20_qs;
  logic 		    capabilities_qosid_qs;

  // fctl
  logic 		    fctl_be_qs;
  logic 		    fctl_wsi_qs;
  logic 		    fctl_wsi_wd;
  logic 		    fctl_wsi_we;
  logic 		    fctl_gxl_qs;
  logic 		    fctl_gxl_wd;
  logic 		    fctl_gxl_we;

  // ddtp
  logic         ddtp_l_we;
  logic         ddtp_h_we;
  logic [3:0] 	ddtp_iommu_mode_qs;
  logic [3:0] 	ddtp_iommu_mode_wd;
  logic 		    ddtp_iommu_mode_we;
  logic         ddtp_busy_d;
  logic         ddtp_busy_de;
  logic 		    ddtp_busy_qs;
  logic [21:0] 	ddtp_ppn_l_qs;
  logic [21:0] 	ddtp_ppn_l_wd;
  logic 		    ddtp_ppn_l_we;
  logic [21:0] 	ddtp_ppn_h_qs;
  logic [21:0] 	ddtp_ppn_h_wd;
  logic 		    ddtp_ppn_h_we;

  logic         write_l_n, write_l_q;
  logic         write_h_n, write_h_q;
  logic [3:0]   ddtp_iommu_mode_n, ddtp_iommu_mode_q;
  logic [21:0]  ddtp_ppn_l_n, ddtp_ppn_l_q;
  logic [21:0]  ddtp_ppn_h_n, ddtp_ppn_h_q;

  // cqb (low)
  logic [4:0] 	cqb_log2sz_1_qs;
  logic [4:0] 	cqb_log2sz_1_wd;
  logic 		    cqb_log2sz_1_we;
  logic [21:0] 	cqb_ppn_l_qs;
  logic [21:0] 	cqb_ppn_l_wd;
  logic 		    cqb_ppn_l_we;

  // cqb (high)
  logic [21:0] 	cqb_ppn_h_qs;
  logic [21:0] 	cqb_ppn_h_wd;
  logic 		    cqb_ppn_h_we;

  // cqh
  logic [31:0] 	cqh_qs;

  // cqt
  logic [31:0] 	cqt_qs;
  logic [31:0] 	cqt_wd;
  logic         cqt_we;

  // fqb (low)
  logic [4:0] 	fqb_log2sz_1_qs;
  logic [4:0] 	fqb_log2sz_1_wd;
  logic 		    fqb_log2sz_1_we;
  logic [21:0] 	fqb_ppn_l_qs;
  logic [21:0] 	fqb_ppn_l_wd;
  logic 		    fqb_ppn_l_we;

  // fqb (high)
  logic [21:0] 	fqb_ppn_h_qs;
  logic [21:0] 	fqb_ppn_h_wd;
  logic 		    fqb_ppn_h_we;

  // fqh
  logic [31:0] 	fqh_qs;
  logic [31:0] 	fqh_wd;
  logic fqh_we;

  // fqt
  logic [31:0] 	fqt_qs;

  // cqcsr
  logic 		    cqcsr_cqen_qs;
  logic 		    cqcsr_cqen_wd;
  logic 		    cqcsr_cqen_we;
  logic 		    cqcsr_cie_qs;
  logic 		    cqcsr_cie_wd;
  logic 		    cqcsr_cie_we;
  logic 		    cqcsr_cqmf_qs;
  logic 		    cqcsr_cqmf_wd;
  logic 		    cqcsr_cqmf_we;
  logic 		    cqcsr_cmd_to_qs;
  logic 		    cqcsr_cmd_to_wd;
  logic 		    cqcsr_cmd_to_we;
  logic 		    cqcsr_cmd_ill_qs;
  logic 		    cqcsr_cmd_ill_wd;
  logic 		    cqcsr_cmd_ill_we;
  logic 		    cqcsr_fence_w_ip_qs;
  logic 		    cqcsr_fence_w_ip_wd;
  logic 		    cqcsr_fence_w_ip_we;
  logic 		    cqcsr_cqon_qs;
  logic 		    cqcsr_busy_qs;

  // fqcsr
  logic 		    fqcsr_fqen_qs;
  logic 		    fqcsr_fqen_wd;
  logic 		    fqcsr_fqen_we;
  logic 		    fqcsr_fie_qs;
  logic 		    fqcsr_fie_wd;
  logic 		    fqcsr_fie_we;
  logic 		    fqcsr_fqmf_qs;
  logic 		    fqcsr_fqmf_wd;
  logic 		    fqcsr_fqmf_we;
  logic 		    fqcsr_fqof_qs;
  logic 		    fqcsr_fqof_wd;
  logic 		    fqcsr_fqof_we;
  logic 		    fqcsr_fqon_qs;
  logic 		    fqcsr_busy_qs;

  // iocountinh
  logic 		    iocountinh_cy_qs;
  logic 		    iocountinh_cy_wd;
  logic 		    iocountinh_cy_we;
  logic [30:0]	iocountinh_hpm_qs;
  logic [30:0]	iocountinh_hpm_wd;
  logic 		    iocountinh_hpm_we;

  // iohpmcycles (low)
  logic [31:0]	iohpmcycles_counter_l_qs;
  logic [31:0]	iohpmcycles_counter_l_wd;
  logic 		    iohpmcycles_counter_l_we;

  // iohpmcycles (high)
  logic [30:0]	iohpmcycles_counter_h_qs;
  logic [30:0]	iohpmcycles_counter_h_wd;
  logic 		    iohpmcycles_counter_h_we;
  logic 		    iohpmcycles_of_qs;
  logic 		    iohpmcycles_of_wd;
  logic 		    iohpmcycles_of_we;

  // iohpmctr (low)
  logic [31:0]	iohpmctr_counter_l_qs   [0:30];
  logic [31:0]	iohpmctr_counter_l_wd   [0:30];
  logic 		    iohpmctr_counter_l_we   [0:30];

  // iohpmctr (high)
  logic [31:0]	iohpmctr_counter_h_qs   [0:30];
  logic [31:0]	iohpmctr_counter_h_wd   [0:30];
  logic 		    iohpmctr_counter_h_we   [0:30];

  // iohpmevt (low)
  logic [14:0]	iohpmevt_eventid_qs     [0:30];
  logic [14:0]	iohpmevt_eventid_wd     [0:30];
  logic 		    iohpmevt_eventid_we     [0:30];
  logic 	      iohpmevt_dmask_qs       [0:30];
  logic 	      iohpmevt_dmask_wd       [0:30];
  logic 		    iohpmevt_dmask_we       [0:30];
  logic [15:0]	iohpmevt_pid_pscid_l_qs [0:30];
  logic [15:0]	iohpmevt_pid_pscid_l_wd [0:30];
  logic 		    iohpmevt_pid_pscid_l_we [0:30];

  // iohpmevt (high)
  logic [3:0]	  iohpmevt_pid_pscid_h_qs [0:30];
  logic [3:0]	  iohpmevt_pid_pscid_h_wd [0:30];
  logic 		    iohpmevt_pid_pscid_h_we [0:30];
  logic [23:0]	iohpmevt_did_gscid_qs   [0:30];
  logic [23:0]	iohpmevt_did_gscid_wd   [0:30];
  logic 		    iohpmevt_did_gscid_we   [0:30];
  logic 	      iohpmevt_pv_pscv_qs     [0:30];
  logic 	      iohpmevt_pv_pscv_wd     [0:30];
  logic 		    iohpmevt_pv_pscv_we     [0:30];
  logic 	      iohpmevt_dv_gscv_qs     [0:30];
  logic 	      iohpmevt_dv_gscv_wd     [0:30];
  logic 		    iohpmevt_dv_gscv_we     [0:30];
  logic 	      iohpmevt_idt_qs         [0:30];
  logic 	      iohpmevt_idt_wd         [0:30];
  logic 		    iohpmevt_idt_we         [0:30];
  logic 	      iohpmevt_of_qs          [0:30];
  logic 	      iohpmevt_of_wd          [0:30];
  logic 		    iohpmevt_of_we          [0:30];

  logic [19:0]  tr_req_iova_vpn_l_qs;
  logic [19:0]  tr_req_iova_vpn_l_wd;
  logic         tr_req_iova_vpn_l_we;
  logic [31:0]  tr_req_iova_vpn_h_qs;
  logic [31:0]  tr_req_iova_vpn_h_wd;
  logic         tr_req_iova_vpn_h_we;
  logic         tr_req_ctl_go_qs;
  logic         tr_req_ctl_go_wd;
  logic         tr_req_ctl_go_we;
  logic         tr_req_ctl_priv_qs;
  logic         tr_req_ctl_priv_wd;
  logic         tr_req_ctl_priv_we;
  logic         tr_req_ctl_exe_qs;
  logic         tr_req_ctl_exe_wd;
  logic         tr_req_ctl_exe_we;
  logic         tr_req_ctl_nw_qs;
  logic         tr_req_ctl_nw_wd;
  logic         tr_req_ctl_nw_we;
  logic [19:0]  tr_req_ctl_pid_qs;
  logic [19:0]  tr_req_ctl_pid_wd;
  logic         tr_req_ctl_pid_we;
  logic         tr_req_ctl_pv_qs;
  logic         tr_req_ctl_pv_wd;
  logic         tr_req_ctl_pv_we;
  logic [23:0]  tr_req_ctl_did_qs;
  logic [23:0]  tr_req_ctl_did_wd;
  logic         tr_req_ctl_did_we;
  logic         tr_response_fault_qs;
  logic [1:0]   tr_response_pbmt_qs;
  logic         tr_response_s_qs;
  logic [21:0]  tr_response_ppn_h_qs;
  logic [21:0]  tr_response_ppn_l_qs;
  
  // ipsr
  logic 		ipsr_cip_qs;
  logic 		ipsr_cip_wd;
  logic 		ipsr_cip_we;
  logic 		ipsr_fip_qs;
  logic 		ipsr_fip_wd;
  logic 		ipsr_fip_we;
  logic 		ipsr_pmip_qs;
  logic 		ipsr_pmip_wd;
  logic 		ipsr_pmip_we;

  // icvec (low)
  logic [3:0] 	icvec_civ_qs;
  logic [3:0] 	icvec_civ_wd;
  logic         icvec_civ_we;
  logic [3:0] 	icvec_fiv_qs;
  logic [3:0] 	icvec_fiv_wd;
  logic 		    icvec_fiv_we;
  logic [3:0] 	icvec_pmiv_qs;
  logic [3:0] 	icvec_pmiv_wd;
  logic 		    icvec_pmiv_we;

  // MSI configuration table
  logic [29:0]  msi_addr_l_qs   [0:15];
  logic [29:0]  msi_addr_l_wd   [0:15];
  logic         msi_addr_l_we   [0:15];
  logic [23:0]  msi_addr_h_qs   [0:15];
  logic [23:0]  msi_addr_h_wd   [0:15];
  logic         msi_addr_h_we   [0:15];
  logic [31:0]  msi_data_qs     [0:15];
  logic [31:0]  msi_data_wd     [0:15];
  logic         msi_data_we     [0:15];
  logic         msi_vec_ctl_qs  [0:15];
  logic         msi_vec_ctl_wd  [0:15];
  logic         msi_vec_ctl_we  [0:15];

  //-------------------
  // Register instances
  //-------------------

  // R[capabilities]: V(False)

  //   F[version]: 7:0
  assign reg2hw_o.capabilities.version.q = 8'h10;
  assign capabilities_version_qs = 8'h10;


  //   F[sv32]: 8:8
  assign reg2hw_o.capabilities.sv32.q = 1'h0;
  assign capabilities_sv32_qs = 1'h0;


  //   F[sv39]: 9:9
  assign reg2hw_o.capabilities.sv39.q = 1'h1;
  assign capabilities_sv39_qs = 1'h1;

  //   F[sv48]: 10:10
  assign reg2hw_o.capabilities.sv48.q = 1'h0;
  assign capabilities_sv48_qs = 1'h0;


  //   F[sv57]: 11:11
  assign reg2hw_o.capabilities.sv57.q = 1'h0;
  assign capabilities_sv57_qs = 1'h0;


  //   F[svpbmt]: 15:15
  assign reg2hw_o.capabilities.svpbmt.q = 1'h0;
  assign capabilities_svpbmt_qs = 1'h0;


  //   F[sv32x4]: 16:16
  assign reg2hw_o.capabilities.sv32x4.q = 1'h0;
  assign capabilities_sv32x4_qs = 1'h0;


  //   F[sv39x4]: 17:17
  assign reg2hw_o.capabilities.sv39x4.q = 1'h1;
  assign capabilities_sv39x4_qs = 1'h1;


  //   F[sv48x4]: 18:18
  assign reg2hw_o.capabilities.sv48x4.q = 1'h0;
  assign capabilities_sv48x4_qs = 1'h0;


  //   F[sv57x4]: 19:19
  assign reg2hw_o.capabilities.sv57x4.q = 1'h0;
  assign capabilities_sv57x4_qs = 1'h0;

  //   F[amo_mrif]: 21:21
  assign reg2hw_o.capabilities.amo_mrif.q = 1'h0;
  assign capabilities_amo_mrif_qs = 1'h0;

  //   F[msi_flat]: 22:22
  if (RVIOMMUCfg.MSITrans != rv_iommu_cfg::MSI_DISABLED) begin
    assign reg2hw_o.capabilities.msi_flat.q = 1'h1;
    assign capabilities_msi_flat_qs = 1'h1;
  end

  else begin
    assign reg2hw_o.capabilities.msi_flat.q = 1'h0;
    assign capabilities_msi_flat_qs = 1'h0;
  end


  //   F[msi_mrif]: 23:23
  if (RVIOMMUCfg.MSITrans == rv_iommu_cfg::MSI_BT_MRIF) begin
    assign reg2hw_o.capabilities.msi_mrif.q = 1'h1;
    assign capabilities_msi_mrif_qs = 1'h1;
  end

  else begin
    assign reg2hw_o.capabilities.msi_mrif.q = 1'h0;
    assign capabilities_msi_mrif_qs = 1'h0;
  end
  
  //   F[amo_hwad]: 24:24
  assign reg2hw_o.capabilities.amo_hwad.q = 1'h0;
  assign capabilities_amo_hwad_qs = 1'h0;


  //   F[ats]: 25:25
  assign reg2hw_o.capabilities.ats.q = 1'h0;
  assign capabilities_ats_qs = 1'h0;


  //   F[t2gpa]: 26:26
  assign reg2hw_o.capabilities.t2gpa.q = 1'h0;
  assign capabilities_t2gpa_qs = 1'h0;


  //   F[endi]: 27:27
  assign reg2hw_o.capabilities.endi.q = 1'h0;
  assign capabilities_endi_qs = 1'h0;


  //   F[igs]: 29:28
  // MSI support only
  if (RVIOMMUCfg.IGS == rv_iommu_cfg::MSI_ONLY) begin
      assign reg2hw_o.capabilities.igs.q = 2'h0;
      assign capabilities_igs_qs = 2'h0;
  end

  // WSI support only
  else if (RVIOMMUCfg.IGS == rv_iommu_cfg::WSI_ONLY) begin
      assign reg2hw_o.capabilities.igs.q = 2'h1;
      assign capabilities_igs_qs = 2'h1;
  end

  // MSI and WSI support
  else if (RVIOMMUCfg.IGS == rv_iommu_cfg::BOTH) begin
      assign reg2hw_o.capabilities.igs.q = 2'h2;
      assign capabilities_igs_qs = 2'h2;
  end

  //   F[hpm]: 30:30
  if (RVIOMMUCfg.NumHpmCounters > 0) begin
    assign reg2hw_o.capabilities.hpm.q = 1'h1;
    assign capabilities_hpm_qs = 1'h1;
  end
  else begin
    assign reg2hw_o.capabilities.hpm.q = 1'h0;
    assign capabilities_hpm_qs = 1'h0;
  end

  //   F[dbg]: 31:31
  if (RVIOMMUCfg.InclDbg) begin
    assign reg2hw_o.capabilities.dbg.q = 1'h1;
    assign capabilities_dbg_qs = 1'h1;
  end
  else begin
    assign reg2hw_o.capabilities.dbg.q = 1'h0;
    assign capabilities_dbg_qs = 1'h0;
  end

  //   F[pas]: 37:32
  assign reg2hw_o.capabilities.pas.q = 6'h38;
  assign capabilities_pas_qs = 6'h38;


  //   F[pd8]: 38:38
  assign reg2hw_o.capabilities.pd8.q = 1'h1;
  assign capabilities_pd8_qs = 1'h1;


  //   F[pd17]: 39:39
  assign reg2hw_o.capabilities.pd17.q = 1'h1;
  assign capabilities_pd17_qs = 1'h1;


  //   F[pd20]: 40:40
  assign reg2hw_o.capabilities.pd20.q = 1'h1;
  assign capabilities_pd20_qs = 1'h1;

  //   F[qosid]: 41:41
  assign reg2hw_o.capabilities.qosid.q = 1'h0;
  assign capabilities_qosid_qs = 1'h0;


  // R[fctl]: V(False)

  //   F[be]: 0:0
  assign reg2hw_o.fctl.be.q   = 1'h0;
	assign fctl_be_qs	        = 1'h0;


  //   F[wsi]: 1:1
  rv_iommu_field #(
    .DataWidth      (1),
    .SwAccess(SwAccessRW),
    .RESVAL  ((RVIOMMUCfg.IGS == rv_iommu_cfg::MSI_ONLY) ? (1'h0) : (1'h1))
  ) u_fctl_wsi (
    .clk_i   (clk_i    ),
    .rst_ni  (rst_ni  ),

    // from register interface
    .we     (fctl_wsi_we),
    .wd     (fctl_wsi_wd),

    // from internal hardware
    .de     ('0),
    .d      ('0),
    .ds     (),

    // to internal hardware
    .qe     (),
    .q      (reg2hw_o.fctl.wsi.q ),

    // to register interface (read)
    .qs     (fctl_wsi_qs)
  );


  //   F[gxl]: 2:2
  rv_iommu_field #(
    .DataWidth      (1),
    .SwAccess(SwAccessRW),
    .RESVAL  (1'h0)
  ) u_fctl_gxl (
    .clk_i   (clk_i    ),
    .rst_ni  (rst_ni  ),

    // from register interface
    .we     (fctl_gxl_we),
    .wd     (fctl_gxl_wd),

    // from internal hardware
    .de     ('0),
    .d      ('0),
    .ds     (),

    // to internal hardware
    .qe     (),
    .q      (reg2hw_o.fctl.gxl.q ),

    // to register interface (read)
    .qs     (fctl_gxl_qs)
  );


  // R[ddtp]: V(False)

  //   F[iommu_mode]: 3:0
  rv_iommu_field #(
    .DataWidth      (4),
    .SwAccess(SwAccessRW),
    .RESVAL  (4'h0)
  ) u_ddtp_iommu_mode (
    .clk_i   (clk_i    ),
    .rst_ni  (rst_ni  ),

    // from register interface
    .we     (ddtp_iommu_mode_we),
    .wd     (ddtp_iommu_mode_wd),

    // from internal hardware
    .de     ('0),
    .d      ('0),
    .ds     (),

    // to internal hardware
    .qe     (),
    .q      (reg2hw_o.ddtp.iommu_mode.q ),

    // to register interface (read)
    .qs     (ddtp_iommu_mode_qs)
  );


  //   F[busy]: 4:4
  rv_iommu_field #(
    .DataWidth      (1),
    .SwAccess(SwAccessRO),
    .RESVAL  (1'h0)
  ) u_ddtp_busy (
    .clk_i   (clk_i    ),
    .rst_ni  (rst_ni  ),

    .we     (1'b0),
    .wd     ('0  ),

    // from internal hardware
    .de     (ddtp_busy_de),
    .d      (ddtp_busy_d),
    .ds     (),

    // to internal hardware
    .qe     (),
    .q      (),

    // to register interface (read)
    .qs     (ddtp_busy_qs)
  );


  //   F[ppn_low]: 31:10
  rv_iommu_field #(
    .DataWidth      (22),
    .SwAccess(SwAccessRW),
    .RESVAL  (22'h0)
  ) u_ddtp_ppn_l (
    .clk_i   (clk_i    ),
    .rst_ni  (rst_ni  ),

    // from register interface
    .we     (ddtp_ppn_l_we),
    .wd     (ddtp_ppn_l_wd),

    // from internal hardware
    .de     ('0),
    .d      ('0),
    .ds     (),

    // to internal hardware
    .qe     (),
    .q      (reg2hw_o.ddtp.ppn.q[21:0] ),

    // to register interface (read)
    .qs     (ddtp_ppn_l_qs)
  );

  //   F[ppn_high]: 21:0
  rv_iommu_field #(
    .DataWidth      (22),
    .SwAccess(SwAccessRW),
    .RESVAL  (22'h0)
  ) u_ddtp_ppn_h (
    .clk_i   (clk_i    ),
    .rst_ni  (rst_ni  ),

    // from register interface
    .we     (ddtp_ppn_h_we),
    .wd     (ddtp_ppn_h_wd),

    // from internal hardware
    .de     ('0),
    .d      ('0),
    .ds     (),

    // to internal hardware
    .qe     (),
    .q      (reg2hw_o.ddtp.ppn.q[43:22] ),

    // to register interface (read)
    .qs     (ddtp_ppn_h_qs)
  );


  // R[cqb]: V(False)

  //   F[log2sz_1]: 4:0
  rv_iommu_field #(
    .DataWidth      (5),
    .SwAccess(SwAccessRW),
    .RESVAL  (5'h0)
  ) u_cqb_log2sz_1 (
    .clk_i   (clk_i    ),
    .rst_ni  (rst_ni  ),

    // from register interface
    .we     (cqb_log2sz_1_we),
    .wd     (cqb_log2sz_1_wd),

    // from internal hardware
    .de     ('0),
    .d      ('0),
    .ds     (),

    // to internal hardware
    .qe     (),
    .q      (reg2hw_o.cqb.log2sz_1.q ),

    // to register interface (read)
    .qs     (cqb_log2sz_1_qs)
  );


  //   F[ppn_low]: 31:10
  rv_iommu_field #(
    .DataWidth      (22),
    .SwAccess(SwAccessRW),
    .RESVAL  (22'h0)
  ) u_cqb_ppn_l (
    .clk_i   (clk_i    ),
    .rst_ni  (rst_ni  ),

    // from register interface
    .we     (cqb_ppn_l_we),
    .wd     (cqb_ppn_l_wd),

    // from internal hardware
    .de     ('0),
    .d      ('0),
    .ds     (),

    // to internal hardware
    .qe     (),
    .q      (reg2hw_o.cqb.ppn.q[21:0] ),

    // to register interface (read)
    .qs     (cqb_ppn_l_qs)
  );

  //   F[ppn_high]: 21:0
  rv_iommu_field #(
    .DataWidth      (22),
    .SwAccess(SwAccessRW),
    .RESVAL  (22'h0)
  ) u_cqb_ppn_h (
    .clk_i   (clk_i    ),
    .rst_ni  (rst_ni  ),

    // from register interface
    .we     (cqb_ppn_h_we),
    .wd     (cqb_ppn_h_wd),

    // from internal hardware
    .de     ('0),
    .d      ('0),
    .ds     (),

    // to internal hardware
    .qe     (),
    .q      (reg2hw_o.cqb.ppn.q[43:22] ),

    // to register interface (read)
    .qs     (cqb_ppn_h_qs)
  );


  // R[cqh]: V(False)

  rv_iommu_field #(
    .DataWidth      (32),
    .SwAccess(SwAccessRO),
    .RESVAL  (32'h0)
  ) u_cqh (
    .clk_i   (clk_i    ),
    .rst_ni  (rst_ni  ),

    .we     (1'b0),
    .wd     ('0  ),

    // from internal hardware
    .de     (hw2reg_i.cqh.de),
    .ds     (),
    .d      (hw2reg_i.cqh.d ),

    // to internal hardware
    .qe     (),
    .q      (reg2hw_o.cqh.q ),

    // to register interface (read)
    .qs     (cqh_qs)
  );


  // R[cqt]: V(False)

  rv_iommu_field #(
    .DataWidth      (32),
    .SwAccess(SwAccessRW),
    .RESVAL  (32'h0)
  ) u_cqt (
    .clk_i   (clk_i    ),
    .rst_ni  (rst_ni  ),

    // from register interface
    .we     (cqt_we),
    .wd     (cqt_wd),

    // from internal hardware
    .de     ('0),
    .d      ('0),
    .ds     (),

    // to internal hardware
    .qe     (),
    .q      (reg2hw_o.cqt.q ),

    // to register interface (read)
    .qs     (cqt_qs)
  );


  // R[fqb]: V(False)

  //   F[log2sz_1]: 4:0
  rv_iommu_field #(
    .DataWidth      (5),
    .SwAccess(SwAccessRW),
    .RESVAL  (5'h0)
  ) u_fqb_log2sz_1 (
    .clk_i   (clk_i    ),
    .rst_ni  (rst_ni  ),

    // from register interface
    .we     (fqb_log2sz_1_we),
    .wd     (fqb_log2sz_1_wd),

    // from internal hardware
    .de     ('0),
    .d      ('0),
    .ds     (),

    // to internal hardware
    .qe     (),
    .q      (reg2hw_o.fqb.log2sz_1.q ),

    // to register interface (read)
    .qs     (fqb_log2sz_1_qs)
  );


  //   F[ppn]: 31:10
  rv_iommu_field #(
    .DataWidth      (22),
    .SwAccess(SwAccessRW),
    .RESVAL  (22'h0)
  ) u_fqb_ppn_l (
    .clk_i   (clk_i    ),
    .rst_ni  (rst_ni  ),

    // from register interface
    .we     (fqb_ppn_l_we),
    .wd     (fqb_ppn_l_wd),

    // from internal hardware
    .de     ('0),
    .d      ('0),
    .ds     (),

    // to internal hardware
    .qe     (),
    .q      (reg2hw_o.fqb.ppn.q[21:0] ),

    // to register interface (read)
    .qs     (fqb_ppn_l_qs)
  );


  //   F[ppn]: 21:0
  rv_iommu_field #(
    .DataWidth      (22),
    .SwAccess(SwAccessRW),
    .RESVAL  (22'h0)
  ) u_fqb_ppn_h (
    .clk_i   (clk_i    ),
    .rst_ni  (rst_ni  ),

    // from register interface
    .we     (fqb_ppn_h_we),
    .wd     (fqb_ppn_h_wd),

    // from internal hardware
    .de     ('0),
    .d      ('0),
    .ds     (),

    // to internal hardware
    .qe     (),
    .q      (reg2hw_o.fqb.ppn.q[43:22] ),

    // to register interface (read)
    .qs     (fqb_ppn_h_qs)
  );


  // R[fqh]: V(False)

  rv_iommu_field #(
    .DataWidth      (32),
    .SwAccess(SwAccessRW),
    .RESVAL  (32'h0)
  ) u_fqh (
    .clk_i   (clk_i    ),
    .rst_ni  (rst_ni  ),

    // from register interface
    .we     (fqh_we),
    .wd     (fqh_wd),

    // from internal hardware
    .de     ('0),
    .d      ('0),
    .ds     (),

    // to internal hardware
    .qe     (),
    .q      (reg2hw_o.fqh.q ),

    // to register interface (read)
    .qs     (fqh_qs)
  );


  // R[fqt]: V(False)

  rv_iommu_field #(
    .DataWidth      (32),
    .SwAccess(SwAccessRO),
    .RESVAL  (32'h0)
  ) u_fqt (
    .clk_i   (clk_i    ),
    .rst_ni  (rst_ni  ),

    .we     (1'b0),
    .wd     ('0  ),

    // from internal hardware
    .de     (hw2reg_i.fqt.de),
    .ds     (),
    .d      (hw2reg_i.fqt.d ),

    // to internal hardware
    .qe     (),
    .q      (reg2hw_o.fqt.q ),

    // to register interface (read)
    .qs     (fqt_qs)
  );


  // R[cqcsr]: V(False)

  //   F[cqen]: 0:0
  rv_iommu_field #(
    .DataWidth      (1),
    .SwAccess(SwAccessRW),
    .RESVAL  (1'h0)
  ) u_cqcsr_cqen (
    .clk_i   (clk_i    ),
    .rst_ni  (rst_ni  ),

    // from register interface
    .we     (cqcsr_cqen_we),
    .wd     (cqcsr_cqen_wd),

    // from internal hardware
    .de     ('0),
    .d      ('0),
    .ds     (),

    // to internal hardware
    .qe     (),
    .q      (reg2hw_o.cqcsr.cqen.q ),

    // to register interface (read)
    .qs     (cqcsr_cqen_qs)
  );


  //   F[cie]: 1:1
  rv_iommu_field #(
    .DataWidth      (1),
    .SwAccess(SwAccessRW),
    .RESVAL  (1'h0)
  ) u_cqcsr_cie (
    .clk_i   (clk_i    ),
    .rst_ni  (rst_ni  ),

    // from register interface
    .we     (cqcsr_cie_we),
    .wd     (cqcsr_cie_wd),

    // from internal hardware
    .de     ('0),
    .d      ('0),
    .ds     (),

    // to internal hardware
    .qe     (),
    .q      (reg2hw_o.cqcsr.cie.q ),

    // to register interface (read)
    .qs     (cqcsr_cie_qs)
  );


  //   F[cqmf]: 8:8
  rv_iommu_field #(
    .DataWidth      (1),
    .SwAccess(SwAccessW1C),
    .RESVAL  (1'h0)
  ) u_cqcsr_cqmf (
    .clk_i   (clk_i    ),
    .rst_ni  (rst_ni  ),

    // from register interface
    .we     (cqcsr_cqmf_we),
    .wd     (cqcsr_cqmf_wd),

    // from internal hardware
    .de     (hw2reg_i.cqcsr.cqmf.de),
    .ds     (),
    .d      (hw2reg_i.cqcsr.cqmf.d ),

    // to internal hardware
    .qe     (),
    .q      (reg2hw_o.cqcsr.cqmf.q ),

    // to register interface (read)
    .qs     (cqcsr_cqmf_qs)
  );


  //   F[cmd_to]: 9:9
  rv_iommu_field #(
    .DataWidth      (1),
    .SwAccess(SwAccessW1C),
    .RESVAL  (1'h0)
  ) u_cqcsr_cmd_to (
    .clk_i   (clk_i    ),
    .rst_ni  (rst_ni  ),

    // from register interface
    .we     (cqcsr_cmd_to_we),
    .wd     (cqcsr_cmd_to_wd),

    // from internal hardware
    .de     (hw2reg_i.cqcsr.cmd_to.de),
    .ds     (),
    .d      (hw2reg_i.cqcsr.cmd_to.d ),

    // to internal hardware
    .qe     (),
    .q      (reg2hw_o.cqcsr.cmd_to.q ),

    // to register interface (read)
    .qs     (cqcsr_cmd_to_qs)
  );


  //   F[cmd_ill]: 10:10
  rv_iommu_field #(
    .DataWidth      (1),
    .SwAccess(SwAccessW1C),
    .RESVAL  (1'h0)
  ) u_cqcsr_cmd_ill (
    .clk_i   (clk_i    ),
    .rst_ni  (rst_ni  ),

    // from register interface
    .we     (cqcsr_cmd_ill_we),
    .wd     (cqcsr_cmd_ill_wd),

    // from internal hardware
    .de     (hw2reg_i.cqcsr.cmd_ill.de),
    .ds     (),
    .d      (hw2reg_i.cqcsr.cmd_ill.d ),

    // to internal hardware
    .qe     (),
    .q      (reg2hw_o.cqcsr.cmd_ill.q ),

    // to register interface (read)
    .qs     (cqcsr_cmd_ill_qs)
  );


  //   F[fence_w_ip]: 11:11
  rv_iommu_field #(
    .DataWidth      (1),
    .SwAccess(SwAccessW1C),
    .RESVAL  (1'h0)
  ) u_cqcsr_fence_w_ip (
    .clk_i   (clk_i    ),
    .rst_ni  (rst_ni  ),

    // from register interface
    .we     (cqcsr_fence_w_ip_we),
    .wd     (cqcsr_fence_w_ip_wd),

    // from internal hardware
    .de     (hw2reg_i.cqcsr.fence_w_ip.de),
    .ds     (),
    .d      (hw2reg_i.cqcsr.fence_w_ip.d ),

    // to internal hardware
    .qe     (),
    .q      (reg2hw_o.cqcsr.fence_w_ip.q ),

    // to register interface (read)
    .qs     (cqcsr_fence_w_ip_qs)
  );


  //   F[cqon]: 16:16
  rv_iommu_field #(
    .DataWidth      (1),
    .SwAccess(SwAccessRO),
    .RESVAL  (1'h0)
  ) u_cqcsr_cqon (
    .clk_i   (clk_i    ),
    .rst_ni  (rst_ni  ),

    .we     (1'b0),
    .wd     ('0  ),

    // from internal hardware
    .de     (hw2reg_i.cqcsr.cqon.de),
    .ds     (),
    .d      (hw2reg_i.cqcsr.cqon.d ),

    // to internal hardware
    .qe     (),
    .q      (),

    // to register interface (read)
    .qs     (cqcsr_cqon_qs)
  );


  //   F[busy]: 17:17
  rv_iommu_field #(
    .DataWidth      (1),
    .SwAccess(SwAccessRO),
    .RESVAL  (1'h0)
  ) u_cqcsr_busy (
    .clk_i   (clk_i    ),
    .rst_ni  (rst_ni  ),

    .we     (1'b0),
    .wd     ('0  ),

    // from internal hardware
    .de     (hw2reg_i.cqcsr.busy.de),
    .ds     (),
    .d      (hw2reg_i.cqcsr.busy.d ),

    // to internal hardware
    .qe     (),
    .q      (),

    // to register interface (read)
    .qs     (cqcsr_busy_qs)
  );


  // R[fqcsr]: V(False)

  //   F[fqen]: 0:0
  rv_iommu_field #(
    .DataWidth      (1),
    .SwAccess(SwAccessRW),
    .RESVAL  (1'h0)
  ) u_fqcsr_fqen (
    .clk_i   (clk_i    ),
    .rst_ni  (rst_ni  ),

    // from register interface
    .we     (fqcsr_fqen_we),
    .wd     (fqcsr_fqen_wd),

    // from internal hardware
    .de     ('0),
    .d      ('0),
    .ds     (),

    // to internal hardware
    .qe     (),
    .q      (reg2hw_o.fqcsr.fqen.q ),

    // to register interface (read)
    .qs     (fqcsr_fqen_qs)
  );


  //   F[fie]: 1:1
  rv_iommu_field #(
    .DataWidth      (1),
    .SwAccess(SwAccessRW),
    .RESVAL  (1'h0)
  ) u_fqcsr_fie (
    .clk_i   (clk_i    ),
    .rst_ni  (rst_ni  ),

    // from register interface
    .we     (fqcsr_fie_we),
    .wd     (fqcsr_fie_wd),

    // from internal hardware
    .de     ('0),
    .d      ('0),
    .ds     (),

    // to internal hardware
    .qe     (),
    .q      (reg2hw_o.fqcsr.fie.q ),

    // to register interface (read)
    .qs     (fqcsr_fie_qs)
  );


  //   F[fqmf]: 8:8
  rv_iommu_field #(
    .DataWidth      (1),
    .SwAccess(SwAccessW1C),
    .RESVAL  (1'h0)
  ) u_fqcsr_fqmf (
    .clk_i   (clk_i    ),
    .rst_ni  (rst_ni  ),

    // from register interface
    .we     (fqcsr_fqmf_we),
    .wd     (fqcsr_fqmf_wd),

    // from internal hardware
    .de     (hw2reg_i.fqcsr.fqmf.de),
    .ds     (),
    .d      (hw2reg_i.fqcsr.fqmf.d ),

    // to internal hardware
    .qe     (),
    .q      (reg2hw_o.fqcsr.fqmf.q ),

    // to register interface (read)
    .qs     (fqcsr_fqmf_qs)
  );


  //   F[fqof]: 9:9
  rv_iommu_field #(
    .DataWidth      (1),
    .SwAccess(SwAccessW1C),
    .RESVAL  (1'h0)
  ) u_fqcsr_fqof (
    .clk_i   (clk_i    ),
    .rst_ni  (rst_ni  ),

    // from register interface
    .we     (fqcsr_fqof_we),
    .wd     (fqcsr_fqof_wd),

    // from internal hardware
    .de     (hw2reg_i.fqcsr.fqof.de),
    .ds     (),
    .d      (hw2reg_i.fqcsr.fqof.d ),

    // to internal hardware
    .qe     (),
    .q      (reg2hw_o.fqcsr.fqof.q ),

    // to register interface (read)
    .qs     (fqcsr_fqof_qs)
  );


  //   F[fqon]: 16:16
  rv_iommu_field #(
    .DataWidth      (1),
    .SwAccess(SwAccessRO),
    .RESVAL  (1'h0)
  ) u_fqcsr_fqon (
    .clk_i   (clk_i    ),
    .rst_ni  (rst_ni  ),

    .we     (1'b0),
    .wd     ('0  ),

    // from internal hardware
    .de     (hw2reg_i.fqcsr.fqon.de),
    .ds     (),
    .d      (hw2reg_i.fqcsr.fqon.d ),

    // to internal hardware
    .qe     (),
    .q      (),

    // to register interface (read)
    .qs     (fqcsr_fqon_qs)
  );


  //   F[busy]: 17:17
  rv_iommu_field #(
    .DataWidth      (1),
    .SwAccess(SwAccessRO),
    .RESVAL  (1'h0)
  ) u_fqcsr_busy (
    .clk_i   (clk_i    ),
    .rst_ni  (rst_ni  ),

    .we     (1'b0),
    .wd     ('0  ),

    // from internal hardware
    .de     (hw2reg_i.fqcsr.busy.de),
    .ds     (),
    .d      (hw2reg_i.fqcsr.busy.d ),

    // to internal hardware
    .qe     (),
    .q      (),

    // to register interface (read)
    .qs     (fqcsr_busy_qs)
  );


  // R[ipsr]: V(False)

  //   F[cip]: 0:0
  rv_iommu_field #(
    .DataWidth      (1),
    .SwAccess(SwAccessW1C),
    .RESVAL  (1'h0)
  ) u_ipsr_cip (
    .clk_i   (clk_i    ),
    .rst_ni  (rst_ni  ),

    // from register interface
    .we     (ipsr_cip_we),
    .wd     (ipsr_cip_wd),

    // from internal hardware
    .de     (hw2reg_i.ipsr.cip.de),
    .ds     (),
    .d      (hw2reg_i.ipsr.cip.d ),

    // to internal hardware
    .qe     (),
    .q      (reg2hw_o.ipsr.cip.q ),

    // to register interface (read)
    .qs     (ipsr_cip_qs)
  );


  //   F[fip]: 1:1
  rv_iommu_field #(
    .DataWidth      (1),
    .SwAccess(SwAccessW1C),
    .RESVAL  (1'h0)
  ) u_ipsr_fip (
    .clk_i   (clk_i    ),
    .rst_ni  (rst_ni  ),

    // from register interface
    .we     (ipsr_fip_we),
    .wd     (ipsr_fip_wd),

    // from internal hardware
    .de     (hw2reg_i.ipsr.fip.de),
    .ds     (),
    .d      (hw2reg_i.ipsr.fip.d ),

    // to internal hardware
    .qe     (),
    .q      (reg2hw_o.ipsr.fip.q ),

    // to register interface (read)
    .qs     (ipsr_fip_qs)
  );


  //   F[pmip]: 2:2
  rv_iommu_field #(
    .DataWidth      (1),
    .SwAccess(SwAccessW1C),
    .RESVAL  (1'h0)
  ) u_ipsr_pmip (
    .clk_i   (clk_i    ),
    .rst_ni  (rst_ni  ),

    // from register interface
    .we     (ipsr_pmip_we),
    .wd     (ipsr_pmip_wd),

    // from internal hardware
    .de     (hw2reg_i.ipsr.pmip.de),
    .ds     (),
    .d      (hw2reg_i.ipsr.pmip.d ),

    // to internal hardware
    .qe     (),
    .q      (reg2hw_o.ipsr.pmip.q ),

    // to register interface (read)
    .qs     (ipsr_pmip_qs)
  );

  genvar k;
  generate
  if (RVIOMMUCfg.NumHpmCounters > 0) begin : gen_hpm_fields

    // R[iocountinh]: V(False)

    //   F[cy]: 0:0
    rv_iommu_field #(
      .DataWidth      (1),
      .SwAccess(SwAccessRW),
      .RESVAL  (1'h1)
    ) u_iocountinh_cy (
      .clk_i   (clk_i    ),
      .rst_ni  (rst_ni  ),

      // from register interface
      .we     (iocountinh_cy_we),
      .wd     (iocountinh_cy_wd),

      // from internal hardware
      .de     ('0),
      .ds     (),
      .d      ('0),

      // to internal hardware
      .qe     (),
      .q      (reg2hw_o.iocountinh.cy.q ),

      // to register interface (read)
      .qs     (iocountinh_cy_qs)
    );

    //   F[hpm]: 31:1
    rv_iommu_field #(
      .DataWidth      (31),
      .SwAccess(SwAccessRW),
      .RESVAL  ('1)
    ) u_iocountinh_hpm (
      .clk_i   (clk_i    ),
      .rst_ni  (rst_ni  ),

      // from register interface
      .we     (iocountinh_hpm_we),
      .wd     (iocountinh_hpm_wd),

      // from internal hardware
      .de     ('0),
      .ds     (),
      .d      ('0),

      // to internal hardware
      .qe     (),
      .q      (reg2hw_o.iocountinh.hpm.q),

      // to register interface (read)
      .qs     (iocountinh_hpm_qs)
    );

    // R[iohpmcycles]: V(False)

    //   F[counter_low]: 31:0
    rv_iommu_field #(
      .DataWidth      (32),
      .SwAccess(SwAccessRW),
      .RESVAL  (32'h0)
    ) u_iohpmcycles_counter_l (
      .clk_i   (clk_i    ),
      .rst_ni  (rst_ni  ),

      // from register interface
      .we     (iohpmcycles_counter_l_we),
      .wd     (iohpmcycles_counter_l_wd),

      // from internal hardware
      .de     (hw2reg_i.iohpmcycles.counter.de),
      .ds     (),
      .d      (hw2reg_i.iohpmcycles.counter.d[31:0] ),

      // to internal hardware
      .qe     (),
      .q      (reg2hw_o.iohpmcycles.counter.q[31:0] ),

      // to register interface (read)
      .qs     (iohpmcycles_counter_l_qs)
    );

    //   F[counter_high]: 30:0
    rv_iommu_field #(
      .DataWidth      (31),
      .SwAccess(SwAccessRW),
      .RESVAL  (31'h0)
    ) u_iohpmcycles_counter_h (
      .clk_i   (clk_i    ),
      .rst_ni  (rst_ni  ),

      // from register interface
      .we     (iohpmcycles_counter_h_we),
      .wd     (iohpmcycles_counter_h_wd),

      // from internal hardware
      .de     (hw2reg_i.iohpmcycles.counter.de),
      .ds     (),
      .d      (hw2reg_i.iohpmcycles.counter.d[62:32] ),

      // to internal hardware
      .qe     (),
      .q      (reg2hw_o.iohpmcycles.counter.q[62:32] ),

      // to register interface (read)
      .qs     (iohpmcycles_counter_h_qs)
    );

    //   F[of]: 31:31
    rv_iommu_field #(
      .DataWidth      (1),
      .SwAccess(SwAccessRW),
      .RESVAL  (1'h0)
    ) u_iohpmcycles_of (
      .clk_i   (clk_i    ),
      .rst_ni  (rst_ni  ),

      // from register interface
      .we     (iohpmcycles_of_we),
      .wd     (iohpmcycles_of_wd),

      // from internal hardware
      .de     (hw2reg_i.iohpmcycles.of.de),
      .ds     (),
      .d      (hw2reg_i.iohpmcycles.of.d ),

      // to internal hardware
      .qe     (),
      .q      (reg2hw_o.iohpmcycles.of.q ),

      // to register interface (read)
      .qs     (iohpmcycles_of_qs)
    );

    for (k = 0; k < RVIOMMUCfg.NumHpmCounters; k++) begin

      // R[iohpmctr]: V(False)

      //   F[counter_low]: 31:0
      rv_iommu_field #(
        .DataWidth      (32),
        .SwAccess(SwAccessRW),
        .RESVAL  (32'h0)
      ) u_iohpmctr_counter_l (
        .clk_i   (clk_i    ),
        .rst_ni  (rst_ni  ),

        // from register interface
        .we     (iohpmctr_counter_l_we[k]),
        .wd     (iohpmctr_counter_l_wd[k]),

        // from internal hardware
        .de     (hw2reg_i.iohpmctr[k].counter.de),
        .ds     (),
        .d      (hw2reg_i.iohpmctr[k].counter.d[31:0] ),

        // to internal hardware
        .qe     (),
        .q      (reg2hw_o.iohpmctr[k].counter.q[31:0] ),

        // to register interface (read)
        .qs     (iohpmctr_counter_l_qs[k])
      );

      //   F[counter_high]: 31:0
      rv_iommu_field #(
        .DataWidth      (32),
        .SwAccess(SwAccessRW),
        .RESVAL  (32'h0)
      ) u_iohpmctr_counter_h (
        .clk_i   (clk_i    ),
        .rst_ni  (rst_ni  ),

        // from register interface
        .we     (iohpmctr_counter_h_we[k]),
        .wd     (iohpmctr_counter_h_wd[k]),

        // from internal hardware
        .de     (hw2reg_i.iohpmctr[k].counter.de),
        .ds     (),
        .d      (hw2reg_i.iohpmctr[k].counter.d[63:32] ),

        // to internal hardware
        .qe     (),
        .q      (reg2hw_o.iohpmctr[k].counter.q[63:32] ),

        // to register interface (read)
        .qs     (iohpmctr_counter_h_qs[k])
      );

      // R[iohpmevt]: V(False)

      //   F[eventid]: 14:0
      rv_iommu_field #(
        .DataWidth      (15),
        .SwAccess(SwAccessRW),
        .RESVAL  (15'h0)
      ) u_iohpmevt_eventid (
        .clk_i   (clk_i    ),
        .rst_ni  (rst_ni  ),

        // from register interface
        .we     (iohpmevt_eventid_we[k]),
        .wd     (iohpmevt_eventid_wd[k]),

        // from internal hardware
        .de     ('0),
        .ds     (),
        .d      ('0),

        // to internal hardware
        .qe     (),
        .q      (reg2hw_o.iohpmevt[k].eventid.q ),

        // to register interface (read)
        .qs     (iohpmevt_eventid_qs[k])
      );

      //   F[dmask]: 15:15
      rv_iommu_field #(
        .DataWidth      (1),
        .SwAccess(SwAccessRW),
        .RESVAL  (1'h0)
      ) u_iohpmevt_dmask (
        .clk_i   (clk_i    ),
        .rst_ni  (rst_ni  ),

        // from register interface
        .we     (iohpmevt_dmask_we[k]),
        .wd     (iohpmevt_dmask_wd[k]),

        // from internal hardware
        .de     ('0),
        .ds     (),
        .d      ('0),

        // to internal hardware
        .qe     (),
        .q      (reg2hw_o.iohpmevt[k].dmask.q ),

        // to register interface (read)
        .qs     (iohpmevt_dmask_qs[k])
      );

      //   F[pid_pscid_low]: 31:16
      rv_iommu_field #(
        .DataWidth      (16),
        .SwAccess(SwAccessRW),
        .RESVAL  (16'h0)
      ) u_iohpmevt_pid_pscid_l (
        .clk_i   (clk_i    ),
        .rst_ni  (rst_ni  ),

        // from register interface
        .we     (iohpmevt_pid_pscid_l_we[k]),
        .wd     (iohpmevt_pid_pscid_l_wd[k]),

        // from internal hardware
        .de     ('0),
        .ds     (),
        .d      ('0),

        // to internal hardware
        .qe     (),
        .q      (reg2hw_o.iohpmevt[k].pid_pscid.q[15:0] ),

        // to register interface (read)
        .qs     (iohpmevt_pid_pscid_l_qs[k])
      );

      //   F[pid_pscid_high]: 31:16
      rv_iommu_field #(
        .DataWidth      (4),
        .SwAccess(SwAccessRW),
        .RESVAL  (4'h0)
      ) u_iohpmevt_pid_pscid_h (
        .clk_i   (clk_i    ),
        .rst_ni  (rst_ni  ),

        // from register interface
        .we     (iohpmevt_pid_pscid_h_we[k]),
        .wd     (iohpmevt_pid_pscid_h_wd[k]),

        // from internal hardware
        .de     ('0),
        .ds     (),
        .d      ('0),

        // to internal hardware
        .qe     (),
        .q      (reg2hw_o.iohpmevt[k].pid_pscid.q[19:16] ),

        // to register interface (read)
        .qs     (iohpmevt_pid_pscid_h_qs[k])
      );

      //   F[did_gscid]: 59:36
      rv_iommu_field #(
        .DataWidth      (24),
        .SwAccess(SwAccessRW),
        .RESVAL  (24'h0)
      ) u_iohpmevt_did_gscid (
        .clk_i   (clk_i    ),
        .rst_ni  (rst_ni  ),

        // from register interface
        .we     (iohpmevt_did_gscid_we[k]),
        .wd     (iohpmevt_did_gscid_wd[k]),

        // from internal hardware
        .de     ('0),
        .ds     (),
        .d      ('0),

        // to internal hardware
        .qe     (),
        .q      (reg2hw_o.iohpmevt[k].did_gscid.q ),

        // to register interface (read)
        .qs     (iohpmevt_did_gscid_qs[k])
      );

      //   F[pv_pscv]: 60:60
      rv_iommu_field #(
        .DataWidth      (1),
        .SwAccess(SwAccessRW),
        .RESVAL  (1'h0)
      ) u_iohpmevt_pv_pscv (
        .clk_i   (clk_i    ),
        .rst_ni  (rst_ni  ),

        // from register interface
        .we     (iohpmevt_pv_pscv_we[k]),
        .wd     (iohpmevt_pv_pscv_wd[k]),

        // from internal hardware
        .de     ('0),
        .ds     (),
        .d      ('0),

        // to internal hardware
        .qe     (),
        .q      (reg2hw_o.iohpmevt[k].pv_pscv.q ),

        // to register interface (read)
        .qs     (iohpmevt_pv_pscv_qs[k])
      );

      //   F[dv_gscv]: 61:61
      rv_iommu_field #(
        .DataWidth      (1),
        .SwAccess(SwAccessRW),
        .RESVAL  (1'h0)
      ) u_iohpmevt_dv_gscv (
        .clk_i   (clk_i    ),
        .rst_ni  (rst_ni  ),

        // from register interface
        .we     (iohpmevt_dv_gscv_we[k]),
        .wd     (iohpmevt_dv_gscv_wd[k]),

        // from internal hardware
        .de     ('0),
        .ds     (),
        .d      ('0),

        // to internal hardware
        .qe     (),
        .q      (reg2hw_o.iohpmevt[k].dv_gscv.q ),

        // to register interface (read)
        .qs     (iohpmevt_dv_gscv_qs[k])
      );

      //   F[idtype]: 62:62
      rv_iommu_field #(
        .DataWidth      (1),
        .SwAccess(SwAccessRW),
        .RESVAL  (1'h0)
      ) u_iohpmevt_idt (
        .clk_i   (clk_i    ),
        .rst_ni  (rst_ni  ),

        // from register interface
        .we     (iohpmevt_idt_we[k]),
        .wd     (iohpmevt_idt_wd[k]),

        // from internal hardware
        .de     ('0),
        .ds     (),
        .d      ('0),

        // to internal hardware
        .qe     (),
        .q      (reg2hw_o.iohpmevt[k].idtype.q ),

        // to register interface (read)
        .qs     (iohpmevt_idt_qs[k])
      );

      //   F[of]: 63:63
      rv_iommu_field #(
        .DataWidth      (1),
        .SwAccess(SwAccessRW),
        .RESVAL  (1'h0)
      ) u_iohpmevt_of (
        .clk_i   (clk_i    ),
        .rst_ni  (rst_ni  ),

        // from register interface
        .we     (iohpmevt_of_we[k]),
        .wd     (iohpmevt_of_wd[k]),

        // from internal hardware
        .de     (hw2reg_i.iohpmevt[k].of.de),
        .ds     (),
        .d      (hw2reg_i.iohpmevt[k].of.d),

        // to internal hardware
        .qe     (),
        .q      (reg2hw_o.iohpmevt[k].of.q ),

        // to register interface (read)
        .qs     (iohpmevt_of_qs[k])
      );
    end
  end : gen_hpm_fields

  else begin : gen_hpm_fields_disabled
    
    assign iocountinh_cy_qs         = 1'b0;
    assign iocountinh_hpm_qs        = '0;

    assign iohpmcycles_counter_l_qs = '0;
    assign iohpmcycles_counter_h_qs = '0;
    assign iohpmcycles_of_qs        = '0;

    assign reg2hw_o.iocountinh.cy.q       = 1'b0;
    assign reg2hw_o.iocountinh.hpm.q      = '0;

    assign reg2hw_o.iohpmcycles.counter.q = '0;
    assign reg2hw_o.iohpmcycles.of.q      = '0;
  end : gen_hpm_fields_disabled
  endgenerate

  // Hardwire unused wires to zero
  for (genvar i = RVIOMMUCfg.NumHpmCounters; i < 31; i++) begin

    assign iohpmctr_counter_l_qs[i]       = '0;
    assign iohpmctr_counter_h_qs[i]       = '0;

    assign iohpmevt_eventid_qs[i]         = '0;
    assign iohpmevt_dmask_qs[i]           = '0;
    assign iohpmevt_pid_pscid_l_qs[i]     = '0;
    assign iohpmevt_pid_pscid_h_qs[i]     = '0;
    assign iohpmevt_did_gscid_qs[i]       = '0;
    assign iohpmevt_pv_pscv_qs[i]         = '0;
    assign iohpmevt_dv_gscv_qs[i]         = '0;
    assign iohpmevt_idt_qs[i]             = '0;
    assign iohpmevt_of_qs[i]              = '0;

    assign reg2hw_o.iohpmctr[i].counter.q   = '0;

    assign reg2hw_o.iohpmevt[i].eventid.q   = '0;
    assign reg2hw_o.iohpmevt[i].dmask.q     = '0;
    assign reg2hw_o.iohpmevt[i].pid_pscid.q = '0;
    assign reg2hw_o.iohpmevt[i].did_gscid.q = '0;
    assign reg2hw_o.iohpmevt[i].pv_pscv.q   = '0;
    assign reg2hw_o.iohpmevt[i].dv_gscv.q   = '0;
    assign reg2hw_o.iohpmevt[i].idtype.q    = '0;
    assign reg2hw_o.iohpmevt[i].of.q        = '0;
  end

  // Debug Register Interface
  generate
    
    // Include Debug Register Interface
    if (RVIOMMUCfg.InclDbg) begin : gen_dbg_if_fields

      // R[tr_req_iova]: V(False)
      
      //   F[vpn_low]
      rv_iommu_field #(
        .DataWidth      (20),
        .SwAccess(SwAccessRW),
        .RESVAL  ('0)
      ) u_tr_req_iova_vpn_l (
        .clk_i   (clk_i   ),
        .rst_ni  (rst_ni  ),

        // from register interface
        .we     (tr_req_iova_vpn_l_we),
        .wd     (tr_req_iova_vpn_l_wd),

        // from internal hardware
        .de     ('0),
        .d      ('0),
        .ds     (),

        // to internal hardware
        .qe     (),
        .q      (reg2hw_o.tr_req_iova.vpn.q[19:0]),

        // to register interface (read)
        .qs     (tr_req_iova_vpn_l_qs)
      );

      //   F[vpn_high]
      rv_iommu_field #(
        .DataWidth      (32),
        .SwAccess(SwAccessRW),
        .RESVAL  ('0)
      ) u_tr_req_iova_vpn_h (
        .clk_i   (clk_i   ),
        .rst_ni  (rst_ni  ),

        // from register interface
        .we     (tr_req_iova_vpn_h_we),
        .wd     (tr_req_iova_vpn_h_wd),

        // from internal hardware
        .de     ('0),
        .d      ('0),
        .ds     (),

        // to internal hardware
        .qe     (),
        .q      (reg2hw_o.tr_req_iova.vpn.q[51:20]),

        // to register interface (read)
        .qs     (tr_req_iova_vpn_h_qs)
      );

      // R[tr_req_ctl]: V(False)
      
      //   F[go/busy]
      rv_iommu_field #(
        .DataWidth      (1),
        .SwAccess(SwAccessW1S),
        .RESVAL  ('0)
      ) u_tr_req_ctl_go (
        .clk_i   (clk_i   ),
        .rst_ni  (rst_ni  ),

        // from register interface
        .we     (tr_req_ctl_go_we),
        .wd     (tr_req_ctl_go_wd),

        // from internal hardware
        .de     (hw2reg_i.tr_req_ctl.busy.de),
        .d      (hw2reg_i.tr_req_ctl.busy.d),
        .ds     (),

        // to internal hardware
        .qe     (),
        .q      (reg2hw_o.tr_req_ctl.go.q),

        // to register interface (read)
        .qs     (tr_req_ctl_go_qs)
      );

      //   F[priv]
      rv_iommu_field #(
        .DataWidth      (1),
        .SwAccess(SwAccessRW),
        .RESVAL  ('0)
      ) u_tr_req_ctl_priv (
        .clk_i   (clk_i   ),
        .rst_ni  (rst_ni  ),

        // from register interface
        .we     (tr_req_ctl_priv_we),
        .wd     (tr_req_ctl_priv_wd),

        // from internal hardware
        .de     ('0),
        .d      ('0),
        .ds     (),

        // to internal hardware
        .qe     (),
        .q      (reg2hw_o.tr_req_ctl.priv.q),

        // to register interface (read)
        .qs     (tr_req_ctl_priv_qs)
      );

      //   F[exe]
      rv_iommu_field #(
        .DataWidth      (1),
        .SwAccess(SwAccessRW),
        .RESVAL  ('0)
      ) u_tr_req_ctl_exe (
        .clk_i   (clk_i   ),
        .rst_ni  (rst_ni  ),

        // from register interface
        .we     (tr_req_ctl_exe_we),
        .wd     (tr_req_ctl_exe_wd),

        // from internal hardware
        .de     ('0),
        .d      ('0),
        .ds     (),

        // to internal hardware
        .qe     (),
        .q      (reg2hw_o.tr_req_ctl.exe.q),

        // to register interface (read)
        .qs     (tr_req_ctl_exe_qs)
      );

      //   F[nw]
      rv_iommu_field #(
        .DataWidth      (1),
        .SwAccess(SwAccessRW),
        .RESVAL  ('0)
      ) u_tr_req_ctl_nw (
        .clk_i   (clk_i   ),
        .rst_ni  (rst_ni  ),

        // from register interface
        .we     (tr_req_ctl_nw_we),
        .wd     (tr_req_ctl_nw_wd),

        // from internal hardware
        .de     ('0),
        .d      ('0),
        .ds     (),

        // to internal hardware
        .qe     (),
        .q      (reg2hw_o.tr_req_ctl.nw.q),

        // to register interface (read)
        .qs     (tr_req_ctl_nw_qs)
      );

      // Only generate PID field if PID is supported
      if (RVIOMMUCfg.InclPC) begin : gen_pc_support_dbg_if
        
        //   F[pid]
        rv_iommu_field #(
          .DataWidth      (20),
          .SwAccess(SwAccessRW),
          .RESVAL  ('0)
        ) u_tr_req_ctl_pid (
          .clk_i   (clk_i   ),
          .rst_ni  (rst_ni  ),

          // from register interface
          .we     (tr_req_ctl_pid_we),
          .wd     (tr_req_ctl_pid_wd),

          // from internal hardware
          .de     ('0),
          .d      ('0),
          .ds     (),

          // to internal hardware
          .qe     (),
          .q      (reg2hw_o.tr_req_ctl.pid.q),

          // to register interface (read)
          .qs     (tr_req_ctl_pid_qs)
        );

        //   F[pv]
        rv_iommu_field #(
          .DataWidth      (1),
          .SwAccess(SwAccessRW),
          .RESVAL  ('0)
        ) u_tr_req_ctl_pv (
          .clk_i   (clk_i   ),
          .rst_ni  (rst_ni  ),

          // from register interface
          .we     (tr_req_ctl_pv_we),
          .wd     (tr_req_ctl_pv_wd),

          // from internal hardware
          .de     ('0),
          .d      ('0),
          .ds     (),

          // to internal hardware
          .qe     (),
          .q      (reg2hw_o.tr_req_ctl.pv.q),

          // to register interface (read)
          .qs     (tr_req_ctl_pv_qs)
        );
      end : gen_pc_support_dbg_if
      
      else begin : gen_pc_support_dbg_if_disabled

        assign reg2hw_o.tr_req_ctl.pid.q  = '0;
        assign tr_req_ctl_pid_qs        = '0;
        assign reg2hw_o.tr_req_ctl.pv.q   = 1'b0;
        assign tr_req_ctl_pv_qs         = 1'b0;
        
      end : gen_pc_support_dbg_if_disabled

      //   F[did]
      rv_iommu_field #(
        .DataWidth      (24),
        .SwAccess(SwAccessRW),
        .RESVAL  ('0)
      ) u_tr_req_ctl_did (
        .clk_i   (clk_i   ),
        .rst_ni  (rst_ni  ),

        // from register interface
        .we     (tr_req_ctl_did_we),
        .wd     (tr_req_ctl_did_wd),

        // from internal hardware
        .de     ('0),
        .d      ('0),
        .ds     (),

        // to internal hardware
        .qe     (),
        .q      (reg2hw_o.tr_req_ctl.did.q),

        // to register interface (read)
        .qs     (tr_req_ctl_did_qs)
      );

      // R[tr_response]: V(False)

      //   F[fault]
      rv_iommu_field #(
        .DataWidth      (1),
        .SwAccess(SwAccessRO),
        .RESVAL  ('0)
      ) u_tr_response_fault (
        .clk_i   (clk_i   ),
        .rst_ni  (rst_ni  ),

        // from register interface
        .we     (1'b0),
        .wd     ('0),

        // from internal hardware
        .de     (hw2reg_i.tr_response.fault.de),
        .d      (hw2reg_i.tr_response.fault.d),
        .ds     (),

        // to internal hardware
        .qe     (),
        .q      (),

        // to register interface (read)
        .qs     (tr_response_fault_qs)
      );

      //   F[pbmt]
      rv_iommu_field #(
        .DataWidth      (2),
        .SwAccess(SwAccessRO),
        .RESVAL  ('0)
      ) u_tr_response_pbmt (
        .clk_i   (clk_i   ),
        .rst_ni  (rst_ni  ),

        // from register interface
        .we     (1'b0),
        .wd     ('0),

        // from internal hardware
        .de     (hw2reg_i.tr_response.pbmt.de),
        .d      (hw2reg_i.tr_response.pbmt.d),
        .ds     (),

        // to internal hardware
        .qe     (),
        .q      (),

        // to register interface (read)
        .qs     (tr_response_pbmt_qs)
      );

      //   F[s]
      rv_iommu_field #(
        .DataWidth      (1),
        .SwAccess(SwAccessRO),
        .RESVAL  ('0)
      ) u_tr_response_s (
        .clk_i   (clk_i   ),
        .rst_ni  (rst_ni  ),

        // from register interface
        .we     (1'b0),
        .wd     ('0),

        // from internal hardware
        .de     (hw2reg_i.tr_response.s.de),
        .d      (hw2reg_i.tr_response.s.d),
        .ds     (),

        // to internal hardware
        .qe     (),
        .q      (),

        // to register interface (read)
        .qs     (tr_response_s_qs)
      );

      //   F[ppn_low]
      rv_iommu_field #(
        .DataWidth      (22),
        .SwAccess(SwAccessRO),
        .RESVAL  ('0)
      ) u_tr_response_ppn_l (
        .clk_i   (clk_i   ),
        .rst_ni  (rst_ni  ),

        // from register interface
        .we     (1'b0),
        .wd     ('0),

        // from internal hardware
        .de     (hw2reg_i.tr_response.ppn.de),
        .d      (hw2reg_i.tr_response.ppn.d[21:0]),
        .ds     (),

        // to internal hardware
        .qe     (),
        .q      (),

        // to register interface (read)
        .qs     (tr_response_ppn_l_qs)
      );

      //   F[ppn_high]
      rv_iommu_field #(
        .DataWidth      (22),
        .SwAccess(SwAccessRO),
        .RESVAL  ('0)
      ) u_tr_response_ppn_h (
        .clk_i   (clk_i   ),
        .rst_ni  (rst_ni  ),

        // from register interface
        .we     (1'b0),
        .wd     ('0),

        // from internal hardware
        .de     (hw2reg_i.tr_response.ppn.de),
        .d      (hw2reg_i.tr_response.ppn.d[43:22]),
        .ds     (),

        // to internal hardware
        .qe     (),
        .q      (),

        // to register interface (read)
        .qs     (tr_response_ppn_h_qs)
      );

    end : gen_dbg_if_fields
    
    else begin : gen_dbg_if_fields_disabled

      assign reg2hw_o.tr_req_iova.vpn.q   = '0;
      assign tr_req_iova_vpn_h_qs       = '0;
      assign tr_req_iova_vpn_l_qs       = '0;

      assign reg2hw_o.tr_req_ctl.go.q     = 1'b0;
      assign tr_req_ctl_go_qs           = 1'b0;
      assign reg2hw_o.tr_req_ctl.priv.q   = 1'b0;
      assign tr_req_ctl_priv_qs         = 1'b0;
      assign reg2hw_o.tr_req_ctl.exe.q    = 1'b0;
      assign tr_req_ctl_exe_qs          = 1'b0;
      assign reg2hw_o.tr_req_ctl.pid.q    = '0;
      assign tr_req_ctl_pid_qs          = '0;
      assign reg2hw_o.tr_req_ctl.pv.q     = 1'b0;
      assign tr_req_ctl_pv_qs           = 1'b0;
      assign reg2hw_o.tr_req_ctl.did.q    = '0;
      assign tr_req_ctl_did_qs          = '0;
      assign reg2hw_o.tr_req_ctl.nw.q     = 1'b0;
      assign tr_req_ctl_nw_qs           = 1'b0;

      assign tr_response_fault_qs       = 1'b0;
      assign tr_response_pbmt_qs        = '0;
      assign tr_response_s_qs           = 1'b0;
      assign tr_response_ppn_h_qs       = '0;
      assign tr_response_ppn_l_qs       = '0;

    end : gen_dbg_if_fields_disabled
  endgenerate

  // R[icvec]: V(False)

  generate
  if (RVIOMMUCfg.NumIntVec > 1) begin : gen_icvec_fields
    
    //   F[civ]
    rv_iommu_field #(
      .DataWidth      (4),
      .SwAccess(SwAccessRW),
      .RESVAL  ('0)
    ) u_icvec_civ (
      .clk_i   (clk_i   ),
      .rst_ni  (rst_ni  ),

      // from register interface
      .we     (icvec_civ_we),
      .wd     (icvec_civ_wd),

      // from internal hardware
      .de     ('0),
      .d      ('0),
      .ds     (),

      // to internal hardware
      .qe     (),
      .q      (reg2hw_o.icvec.civ.q),

      // to register interface (read)
      .qs     (icvec_civ_qs)
    );


    //   F[fiv]
    rv_iommu_field #(
      .DataWidth      (4),
      .SwAccess(SwAccessRW),
      .RESVAL  ('0)
    ) u_icvec_fiv (
      .clk_i   (clk_i    ),
      .rst_ni  (rst_ni  ),

      // from register interface
      .we     (icvec_fiv_we),
      .wd     (icvec_fiv_wd),

      // from internal hardware
      .de     ('0),
      .d      ('0),
      .ds     (),

      // to internal hardware
      .qe     (),
      .q      (reg2hw_o.icvec.fiv.q),

      // to register interface (read)
      .qs     (icvec_fiv_qs)
    );

    if (RVIOMMUCfg.NumHpmCounters > 0) begin : gen_pmiv

      //   F[pmiv]
      rv_iommu_field #(
        .DataWidth      (4),
        .SwAccess(SwAccessRW),
        .RESVAL  ('0)
      ) u_icvec_pmiv (
        .clk_i   (clk_i    ),
        .rst_ni  (rst_ni  ),

        // from register interface
        .we     (icvec_pmiv_we),
        .wd     (icvec_pmiv_wd),

        // from internal hardware
        .de     ('0),
        .d      ('0),
        .ds     (),

        // to internal hardware
        .qe     (),
        .q      (reg2hw_o.icvec.pmiv.q),

        // to register interface (read)
        .qs     (icvec_pmiv_qs)
      );
    end : gen_pmiv

    else begin : gen_pmiv_disabled

      assign icvec_pmiv_qs = '0;
      assign reg2hw_o.icvec.pmiv.q = '0;
    end: gen_pmiv_disabled
  end : gen_icvec_fields

  else begin : gen_icvec_fields_disabled
    assign icvec_civ_qs = '0;
    assign reg2hw_o.icvec.civ.q = '0;

    assign icvec_fiv_qs = '0;
    assign reg2hw_o.icvec.fiv.q = '0;

    assign icvec_pmiv_qs = '0;
    assign reg2hw_o.icvec.pmiv.q = '0;
  end : gen_icvec_fields_disabled
  endgenerate
  
  genvar j;
  generate
  // Generate MSI Configuration Table if IOMMU includes MSI gen support
  if (RVIOMMUCfg.IGS != rv_iommu_cfg::WSI_ONLY) begin : gen_msi_cfg_tbl

    for (j = 0; j < RVIOMMUCfg.NumIntVec; j++) begin
      
      // R[msi_addr_x]: V(False)

      //   F[addr_low]: 31:2
      rv_iommu_field #(
        .DataWidth      (30),
        .SwAccess(SwAccessRW),
        .RESVAL  (30'h0)
      ) u_msi_addr_x_l (
        .clk_i   (clk_i    ),
        .rst_ni  (rst_ni  ),

        // from register interface
        .we     (msi_addr_l_we[j]),
        .wd     (msi_addr_l_wd[j]),

        // from internal hardware
        .de     ('0),
        .d      ('0),
        .ds     (),

        // to internal hardware
        .qe     (),
        .q      (reg2hw_o.msi_addr[j].addr.q[29:0] ),

        // to register interface (read)
        .qs     (msi_addr_l_qs[j])
      );


      //   F[addr_high]: 23:0
      rv_iommu_field #(
        .DataWidth      (24),
        .SwAccess(SwAccessRW),
        .RESVAL  (24'h0)
      ) u_msi_addr_x_h (
        .clk_i   (clk_i    ),
        .rst_ni  (rst_ni  ),

        // from register interface
        .we     (msi_addr_h_we[j]),
        .wd     (msi_addr_h_wd[j]),

        // from internal hardware
        .de     ('0),
        .d      ('0),
        .ds     (),

        // to internal hardware
        .qe     (),
        .q      (reg2hw_o.msi_addr[j].addr.q[53:30] ),

        // to register interface (read)
        .qs     (msi_addr_h_qs[j])
      );


      // R[msi_data_x]: V(False)

      rv_iommu_field #(
        .DataWidth      (32),
        .SwAccess(SwAccessRW),
        .RESVAL  (32'h0)
      ) u_msi_data_x (
        .clk_i   (clk_i    ),
        .rst_ni  (rst_ni  ),

        // from register interface
        .we     (msi_data_we[j]),
        .wd     (msi_data_wd[j]),

        // from internal hardware
        .de     ('0),
        .d      ('0),
        .ds     (),

        // to internal hardware
        .qe     (),
        .q      (reg2hw_o.msi_data[j].data.q ),

        // to register interface (read)
        .qs     (msi_data_qs[j])
      );


      // R[msi_vec_ctl_x]: V(False)

      rv_iommu_field #(
        .DataWidth      (1),
        .SwAccess(SwAccessRW),
        .RESVAL  (1'h0)
      ) u_msi_vec_ctl_x (
        .clk_i   (clk_i    ),
        .rst_ni  (rst_ni  ),

        // from register interface
        .we     (msi_vec_ctl_we[j]),
        .wd     (msi_vec_ctl_wd[j]),

        // from internal hardware
        .de     ('0),
        .d      ('0),
        .ds     (),

        // to internal hardware
        .qe     (),
        .q      (reg2hw_o.msi_vec_ctl[j].m.q ),

        // to register interface (read)
        .qs     (msi_vec_ctl_qs[j])
      );
    end

    // Hardwire unimplemented vectors to zero 
    for (j = RVIOMMUCfg.NumIntVec; j < 16; j++) begin

      assign msi_addr_l_qs[j]   = '0;
      assign msi_addr_h_qs[j]   = '0;
      assign msi_data_qs[j]     = '0;
      assign msi_vec_ctl_qs[j]  = 1'b0;
      
      assign reg2hw_o.msi_addr[j].addr.q  = '0;
      assign reg2hw_o.msi_data[j].data.q  = '0;
      assign reg2hw_o.msi_vec_ctl[j].m.q  = 1'b0;
    end
  end : gen_msi_cfg_tbl

  else begin : gen_msi_cfg_tbl_disabled
    for (j = 0; j < 16; j++) begin

      assign msi_addr_l_qs[j]   = '0;
      assign msi_addr_h_qs[j]   = '0;
      assign msi_data_qs[j]     = '0;
      assign msi_vec_ctl_qs[j]  = 1'b0;
      
      assign reg2hw_o.msi_addr[j].addr.q  = '0;
      assign reg2hw_o.msi_data[j].data.q  = '0;
      assign reg2hw_o.msi_vec_ctl[j].m.q  = 1'b0;
    end
  end : gen_msi_cfg_tbl_disabled
  endgenerate
  

  //-------------------
  // Address hit logic
  //-------------------
  logic [215:0] addr_hit;

  /*
    Address hit map:
    [ 0]      Capabilities (low)
    [ 1]      Capabilities (high)
    [ 2]      fctl
    [ 3]      ddtp (low)
    [ 4]      ddtp (high)
    [ 5]      cqb (low)
    [ 6]      cqb (high)
    [ 7]      cqh
    [ 8]      cqt
    [ 9]      fqb (low)
    [10]      fqb (high)
    [11]      fqh
    [12]      fqt
    [13]      cqcsr
    [14]      fqcsr
    [15]      ipsr
    [16]      iocntovf
    [17]      iocntinh
    [18]      iohpmcycles (low)
    [19]      iohpmcycles (high)
    [50:20]   iohpmctr_n (low)
    [81:51]   iohpmctr_n (high)
    [112:82]  iohpmevt_n (low)
    [143:113] iohpmevt_n (high)
    [144]     tr_req_iova (low)
    [145]     tr_req_iova (high)
    [146]     tr_req_ctl  (low)
    [147]     tr_req_ctl  (high)
    [148]     tr_response (low)
    [149]     tr_response (high)
    [150]     icvec (low)
    [151]     icvec (high)
    [167:152] msi_addr_x (low)
    [183:168] msi_addr_x (high)
    [199:184] msi_data_x
    [215:200] msi_vec_ctl_x
  */

  // Mandatory registers
  assign addr_hit[ 0] = (reg_addr == IOMMU_CAPABILITIES_OFFSET_L);
  assign addr_hit[ 1] = (reg_addr == IOMMU_CAPABILITIES_OFFSET_H);
  assign addr_hit[ 2] = (reg_addr == IOMMU_FCTL_OFFSET);
  assign addr_hit[ 3] = (reg_addr == IOMMU_DDTP_OFFSET_L);
  assign addr_hit[ 4] = (reg_addr == IOMMU_DDTP_OFFSET_H);
  assign addr_hit[ 5] = (reg_addr == IOMMU_CQB_OFFSET_L);
  assign addr_hit[ 6] = (reg_addr == IOMMU_CQB_OFFSET_H);
  assign addr_hit[ 7] = (reg_addr == IOMMU_CQH_OFFSET);
  assign addr_hit[ 8] = (reg_addr == IOMMU_CQT_OFFSET);
  assign addr_hit[ 9] = (reg_addr == IOMMU_FQB_OFFSET_L);
  assign addr_hit[10] = (reg_addr == IOMMU_FQB_OFFSET_H);
  assign addr_hit[11] = (reg_addr == IOMMU_FQH_OFFSET);
  assign addr_hit[12] = (reg_addr == IOMMU_FQT_OFFSET);
  assign addr_hit[13] = (reg_addr == IOMMU_CQCSR_OFFSET);
  assign addr_hit[14] = (reg_addr == IOMMU_FQCSR_OFFSET);
  assign addr_hit[15] = (reg_addr == IOMMU_IPSR_OFFSET);

  // HPM
  assign addr_hit[16] = (RVIOMMUCfg.NumHpmCounters > 0) ? (reg_addr == IOMMU_IOCNTOVF_OFFSET)      : 1'b0;
  assign addr_hit[17] = (RVIOMMUCfg.NumHpmCounters > 0) ? (reg_addr == IOMMU_IOCNTINH_OFFSET)      : 1'b0;
  assign addr_hit[18] = (RVIOMMUCfg.NumHpmCounters > 0) ? (reg_addr == IOMMU_IOHPMCYCLES_OFFSET_L) : 1'b0;
  assign addr_hit[19] = (RVIOMMUCfg.NumHpmCounters > 0) ? (reg_addr == IOMMU_IOHPMCYCLES_OFFSET_H) : 1'b0;
  for (genvar i = 0; i < RVIOMMUCfg.NumHpmCounters; i++) begin
    assign addr_hit[20+i]   = (reg_addr == (IOMMU_IOHPMCTR_OFFSET_L + i*8));
    assign addr_hit[51+i]   = (reg_addr == (IOMMU_IOHPMCTR_OFFSET_H + i*8));
    assign addr_hit[82+i]   = (reg_addr == (IOMMU_IOHPMEVT_OFFSET_L + i*8));
    assign addr_hit[113+i]  = (reg_addr == (IOMMU_IOHPMEVT_OFFSET_H + i*8));
  end
  // Hardwire unused bits to 0
  for (genvar i = RVIOMMUCfg.NumHpmCounters; i < 31; i++) begin
    assign addr_hit[20+i]  = 1'b0;
    assign addr_hit[51+i]  = 1'b0;
    assign addr_hit[82+i]  = 1'b0;
    assign addr_hit[113+i] = 1'b0;
  end

  // Debug Register IF
  if (RVIOMMUCfg.InclDbg) begin : gen_dbg_if_addr_hit
    assign addr_hit[144] = (reg_addr == IOMMU_TR_REQ_IOVA_OFFSET_L);
    assign addr_hit[145] = (reg_addr == IOMMU_TR_REQ_IOVA_OFFSET_H);
    assign addr_hit[146] = (reg_addr == IOMMU_TR_REQ_CTL_OFFSET_L);
    assign addr_hit[147] = (reg_addr == IOMMU_TR_REQ_CTL_OFFSET_H);
    assign addr_hit[148] = (reg_addr == IOMMU_TR_RESPONSE_OFFSET_L);
    assign addr_hit[149] = (reg_addr == IOMMU_TR_RESPONSE_OFFSET_H);
  end : gen_dbg_if_addr_hit
  else begin : gen_dbg_if_disabled_addr_hit
    assign addr_hit[149:144] = '0;
  end : gen_dbg_if_disabled_addr_hit

  assign addr_hit[150] = (reg_addr == IOMMU_ICVEC_OFFSET_L);
  assign addr_hit[151] = (reg_addr == IOMMU_ICVEC_OFFSET_H);

  // MSI Config Table
  for (genvar i = 0; i < RVIOMMUCfg.NumIntVec; i++) begin
    assign addr_hit[152+i] = (reg_addr == (IOMMU_MSI_ADDR_OFFSET_L  + i*16));
    assign addr_hit[168+i] = (reg_addr == (IOMMU_MSI_ADDR_OFFSET_H  + i*16));
    assign addr_hit[184+i] = (reg_addr == (IOMMU_MSI_DATA_OFFSET    + i*16));
    assign addr_hit[200+i] = (reg_addr == (IOMMU_MSI_VEC_CTL_OFFSET + i*16));
  end
  // Hardwire unimplemented vectors to zero
  for (genvar i = RVIOMMUCfg.NumIntVec; i < 16; i++) begin
    assign addr_hit[152+i] = 1'b0;
    assign addr_hit[168+i] = 1'b0;
    assign addr_hit[184+i] = 1'b0;
    assign addr_hit[200+i] = 1'b0;
  end

  assign addrmiss = (reg_re || reg_we) ? ~|addr_hit : 1'b0 ;  // a miss occurs when reading or writing and no addr_hit flag is set

  //-------------
  // Write Check
  //-------------

  // Mandatory registers
  for (genvar i = 0; i < 20; i++) begin
    assign wr_err[i] = (addr_hit[i] & (|(IOMMU_PERMIT[i] & ~reg_be)));
  end

  // HPM
  for (genvar i = 0; i < RVIOMMUCfg.NumHpmCounters; i++) begin
    assign wr_err[20+i]   = (addr_hit[20+i ] & (|(IOMMU_PERMIT[20] & ~reg_be)));
    assign wr_err[51+i]   = (addr_hit[51+i ] & (|(IOMMU_PERMIT[21] & ~reg_be)));
    assign wr_err[82+i]   = (addr_hit[82+i ] & (|(IOMMU_PERMIT[22] & ~reg_be)));
    assign wr_err[113+i]  = (addr_hit[113+i] & (|(IOMMU_PERMIT[23] & ~reg_be)));
  end
  // Hardwire unused bits to 0
  for (genvar i = RVIOMMUCfg.NumHpmCounters; i < 31; i++) begin
    assign wr_err[20+i]   = 1'b0;
    assign wr_err[51+i]   = 1'b0;
    assign wr_err[82+i]   = 1'b0;
    assign wr_err[113+i]  = 1'b0;
  end

  // Debug register IF
  if (RVIOMMUCfg.InclDbg) begin : gen_dbg_if_wr_err
    assign wr_err[144] = (addr_hit[144] & (|(IOMMU_PERMIT[24] & ~reg_be)));
    assign wr_err[145] = (addr_hit[145] & (|(IOMMU_PERMIT[25] & ~reg_be)));
    assign wr_err[146] = (addr_hit[146] & (|(IOMMU_PERMIT[26] & ~reg_be)));
    assign wr_err[147] = (addr_hit[147] & (|(IOMMU_PERMIT[27] & ~reg_be)));
    assign wr_err[148] = (addr_hit[148] & (|(IOMMU_PERMIT[28] & ~reg_be)));
    assign wr_err[149] = (addr_hit[149] & (|(IOMMU_PERMIT[29] & ~reg_be)));
  end : gen_dbg_if_wr_err
  else begin : gen_dbg_if_disabled_wr_err
    assign wr_err[149:144] = '0;
  end : gen_dbg_if_disabled_wr_err

  // icvec
  assign wr_err[150] = (addr_hit[150] & (|(IOMMU_PERMIT[30] & ~reg_be)));
  assign wr_err[151] = (addr_hit[151] & (|(IOMMU_PERMIT[31] & ~reg_be)));

  // MSI Config Table
  for (genvar i = 0; i < RVIOMMUCfg.NumIntVec; i++) begin
    assign wr_err[152+i] = (addr_hit[152+i] & (|(IOMMU_PERMIT[32] & ~reg_be)));
    assign wr_err[168+i] = (addr_hit[168+i] & (|(IOMMU_PERMIT[33] & ~reg_be)));
    assign wr_err[184+i] = (addr_hit[184+i] & (|(IOMMU_PERMIT[34] & ~reg_be)));
    assign wr_err[200+i] = (addr_hit[200+i] & (|(IOMMU_PERMIT[35] & ~reg_be)));
  end
  // Hardwire unused bits to zero
  for (genvar i = RVIOMMUCfg.NumIntVec; i < 16; i++) begin
    assign wr_err[152+i] = 1'b0;
    assign wr_err[168+i] = 1'b0;
    assign wr_err[184+i] = 1'b0;
    assign wr_err[200+i] = 1'b0;
  end

  //------------------
  // Write data logic
  //------------------

  // fctl
  // Interrupts can not be generated as MSI (0) if caps.IGS != {0,2}, and can not be generated as WSI (1) if caps.IGS != {1,2}
  assign fctl_wsi_we = (addr_hit[2] & reg_we & !reg_error) & 
    (((reg_wdata[1] == 1'b0) & (reg2hw_o.capabilities.igs.q inside {2'b00, 2'b10})) | 
     ((reg_wdata[1] == 1'b1) & (reg2hw_o.capabilities.igs.q inside {2'b01, 2'b10})));
  assign fctl_wsi_wd = reg_wdata[1];

  assign fctl_gxl_we = addr_hit[2] & reg_we & !reg_error;
  assign fctl_gxl_wd = reg_wdata[2];

  /*  
    If there is any in-flight transaction going through the IOMMU, we must wait 
    until the transaction ends to modify the ddtp register.

    Writes to the ddtp register received during in-flight transactions are 
    registered and committed after the transaction ends
  */

  // ddtp (low)
  assign ddtp_l_we = addr_hit[3] & reg_we & !reg_error;
  // ddtp (high)
  assign ddtp_h_we = addr_hit[4] & reg_we & !reg_error;

  always_comb begin : ddtp_write_comb

    ddtp_iommu_mode_we  = 1'b0;
    ddtp_iommu_mode_wd  = ddtp_iommu_mode_q;
    ddtp_ppn_l_we       = 1'b0;
    ddtp_ppn_l_wd       = ddtp_ppn_l_q;
    ddtp_ppn_h_we       = 1'b0;
    ddtp_ppn_h_wd       = ddtp_ppn_h_q;

    write_l_n           = write_l_q;
    write_h_n           = write_h_q;
    ddtp_iommu_mode_n   = ddtp_iommu_mode_q;
    ddtp_ppn_l_n        = ddtp_ppn_l_q;
    ddtp_ppn_h_n        = ddtp_ppn_h_q;

    ddtp_busy_de        = 1'b0;
    ddtp_busy_d         = 1'b0;

    // There is pending data to be written to ddtp
    if ((write_h_q || write_l_q)) begin
      
      // Write data if there is no in-flight transaction
      if (!in_flight_i) begin
        if (write_l_q) begin
          write_l_n           = 1'b0;
          ddtp_iommu_mode_we  = 1'b1;
          ddtp_ppn_l_we       = 1'b1;
        end
      
        if (write_h_q) begin
          write_h_n           = 1'b0;
          ddtp_ppn_h_we       = 1'b1;
        end

        // Clear busy bit
        ddtp_busy_de      = 1'b1;
      end
    end

    // There is no pending data to be written to ddtp
    else begin

      // SW is trying to write to the low half of ddtp
      if (ddtp_l_we) begin

        // Check whether the IOMMU has in-flight transactions
        if (in_flight_i) begin
          // Wait for all in-flight transactions to finish
          write_l_n         = 1'b1;
          // Set busy bit
          ddtp_busy_de      = 1'b1;
          ddtp_busy_d       = 1'b1;
          // Save input values
          ddtp_iommu_mode_n = reg_wdata[3:0];
          ddtp_ppn_l_n      = reg_wdata[31:10];
        end

        // There are no in-flight transactions. We can modify ddtp
        else begin
          ddtp_iommu_mode_we  = 1'b1;
          ddtp_ppn_l_we       = 1'b1;
          ddtp_iommu_mode_wd  = reg_wdata[3:0];
          ddtp_ppn_l_wd       = reg_wdata[31:10];
        end
      end

      // SW is trying to write to the high half of ddtp
      if (ddtp_h_we) begin

        // Check whether the IOMMU has in-flight transactions
        if (in_flight_i) begin
          // Wait for all in-flight transactions to finish
          write_h_n     = 1'b1;
          // Set busy bit
          ddtp_busy_de  = 1'b1;
          ddtp_busy_d   = 1'b1;
          // Save input values
          ddtp_ppn_h_n  = reg_wdata[21:0];
        end

        // There are no in-flight transactions. We can modify ddtp
        else begin
          ddtp_ppn_h_we = 1'b1;
          ddtp_ppn_h_wd = reg_wdata[21:0];
        end
      end
    end
  end : ddtp_write_comb

  always_ff @(posedge clk_i or negedge rst_ni) begin : ddtp_write_ff

        if (!rst_ni) begin
          write_l_q         <= 1'b0;
          write_h_q         <= 1'b0;
          ddtp_iommu_mode_q <= '0;
          ddtp_ppn_l_q      <= '0;
          ddtp_ppn_h_q      <= '0;

        end else begin
          write_l_q         <= write_l_n;
          write_h_q         <= write_h_n;
          ddtp_iommu_mode_q <= ddtp_iommu_mode_n;
          ddtp_ppn_l_q      <= ddtp_ppn_l_n;
          ddtp_ppn_h_q      <= ddtp_ppn_h_n;
        end
    end : ddtp_write_ff

  // cqb (low)
  assign cqb_log2sz_1_we = addr_hit[5] & reg_we & !reg_error;
  assign cqb_log2sz_1_wd = reg_wdata[4:0];

  assign cqb_ppn_l_we = addr_hit[5] & reg_we & !reg_error;
  assign cqb_ppn_l_wd = reg_wdata[31:10];

  // cqb (high)
  assign cqb_ppn_h_we = addr_hit[6] & reg_we & !reg_error;
  assign cqb_ppn_h_wd = reg_wdata[21:0];

  // cqt
  // Only LOG2SZ-1:0 bits are writable.
  assign cqt_we = addr_hit[8] & reg_we & !reg_error;
  assign cqt_wd = reg_wdata[31:0] & ({32{1'b1}} >> (31 - cqb_log2sz_1_qs));

  // fqb (low)
  assign fqb_log2sz_1_we = addr_hit[9] & reg_we & !reg_error;
  assign fqb_log2sz_1_wd = reg_wdata[4:0];

  assign fqb_ppn_l_we = addr_hit[9] & reg_we & !reg_error;
  assign fqb_ppn_l_wd = reg_wdata[31:10];

  // fqb (high)
  assign fqb_ppn_h_we = addr_hit[10] & reg_we & !reg_error;
  assign fqb_ppn_h_wd = reg_wdata[21:0];

  // fqh
  // Only LOG2SZ-1:0 bits are writable.
  assign fqh_we = addr_hit[11] & reg_we & !reg_error;
  assign fqh_wd = reg_wdata[31:0] & ({32{1'b1}} >> (31 - fqb_log2sz_1_qs));

  // cqcsr
  assign cqcsr_cqen_we = addr_hit[13] & reg_we & !reg_error;
  assign cqcsr_cqen_wd = reg_wdata[0];

  assign cqcsr_cie_we = addr_hit[13] & reg_we & !reg_error;
  assign cqcsr_cie_wd = reg_wdata[1];

  assign cqcsr_cqmf_we = addr_hit[13] & reg_we & !reg_error;
  assign cqcsr_cqmf_wd = reg_wdata[8];

  assign cqcsr_cmd_to_we = addr_hit[13] & reg_we & !reg_error;
  assign cqcsr_cmd_to_wd = reg_wdata[9];

  assign cqcsr_cmd_ill_we = addr_hit[13] & reg_we & !reg_error;
  assign cqcsr_cmd_ill_wd = reg_wdata[10];

  assign cqcsr_fence_w_ip_we = addr_hit[13] & reg_we & !reg_error;
  assign cqcsr_fence_w_ip_wd = reg_wdata[11];

  // fqcsr
  assign fqcsr_fqen_we = addr_hit[14] & reg_we & !reg_error;
  assign fqcsr_fqen_wd = reg_wdata[0];

  assign fqcsr_fie_we = addr_hit[14] & reg_we & !reg_error;
  assign fqcsr_fie_wd = reg_wdata[1];

  assign fqcsr_fqmf_we = addr_hit[14] & reg_we & !reg_error;
  assign fqcsr_fqmf_wd = reg_wdata[8];

  assign fqcsr_fqof_we = addr_hit[14] & reg_we & !reg_error;
  assign fqcsr_fqof_wd = reg_wdata[9];

  // ipsr
  assign ipsr_cip_we = addr_hit[15] & reg_we & !reg_error;
  assign ipsr_cip_wd = reg_wdata[0];

  assign ipsr_fip_we = addr_hit[15] & reg_we & !reg_error;
  assign ipsr_fip_wd = reg_wdata[1];

  assign ipsr_pmip_we = addr_hit[15] & reg_we & !reg_error;
  assign ipsr_pmip_wd = reg_wdata[2];

  // HPM
  if (RVIOMMUCfg.NumHpmCounters > 0) begin : gen_hpm_write_logic  
    // iocntinh
    assign iocountinh_cy_we = addr_hit[17] & reg_we & !reg_error;
    assign iocountinh_cy_wd = reg_wdata[0];
    assign iocountinh_hpm_we = addr_hit[17] & reg_we & !reg_error;
    assign iocountinh_hpm_wd = reg_wdata[31:1];
    // iohpmcycles (low)
    assign iohpmcycles_counter_l_we = addr_hit[18] & reg_we & !reg_error;
    assign iohpmcycles_counter_l_wd = reg_wdata[31:0];
    // iohpmcycles (high)
    assign iohpmcycles_counter_h_we = addr_hit[19] & reg_we & !reg_error;
    assign iohpmcycles_counter_h_wd = reg_wdata[30:0];
    assign iohpmcycles_of_we = addr_hit[19] & reg_we & !reg_error;
    assign iohpmcycles_of_wd = reg_wdata[31];
    for (genvar i = 0; i < RVIOMMUCfg.NumHpmCounters; i++) begin
      // iohpmctr_n (low)
      assign iohpmctr_counter_l_we[i]   = addr_hit[20+i] & reg_we & !reg_error;
      assign iohpmctr_counter_l_wd[i]   = reg_wdata[31:0];
      // iohpmctr_n (high)
      assign iohpmctr_counter_h_we[i]   = addr_hit[51+i] & reg_we & !reg_error;
      assign iohpmctr_counter_h_wd[i]   = reg_wdata[31:0];
      // iohpmevt_n (low)
      assign iohpmevt_eventid_we[i]     = addr_hit[82+i] & reg_we & !reg_error;
      assign iohpmevt_eventid_wd[i]     = reg_wdata[14:0];
      assign iohpmevt_dmask_we[i]       = addr_hit[82+i] & reg_we & !reg_error;
      assign iohpmevt_dmask_wd[i]       = reg_wdata[15];
      assign iohpmevt_pid_pscid_l_we[i] = addr_hit[82+i] & reg_we & !reg_error;
      assign iohpmevt_pid_pscid_l_wd[i] = reg_wdata[31:16];
      // iohpmevt_n (high)
      assign iohpmevt_pid_pscid_h_we[i] = addr_hit[113+i] & reg_we & !reg_error;
      assign iohpmevt_pid_pscid_h_wd[i] = reg_wdata[3:0];
      assign iohpmevt_did_gscid_we[i]   = addr_hit[113+i] & reg_we & !reg_error;
      assign iohpmevt_did_gscid_wd[i]   = reg_wdata[27:4];
      assign iohpmevt_pv_pscv_we[i]     = addr_hit[113+i] & reg_we & !reg_error;
      assign iohpmevt_pv_pscv_wd[i]     = reg_wdata[28];
      assign iohpmevt_dv_gscv_we[i]     = addr_hit[113+i] & reg_we & !reg_error;
      assign iohpmevt_dv_gscv_wd[i]     = reg_wdata[29];
      assign iohpmevt_idt_we[i]         = addr_hit[113+i] & reg_we & !reg_error;
      assign iohpmevt_idt_wd[i]         = reg_wdata[30];
      assign iohpmevt_of_we[i]          = addr_hit[113+i] & reg_we & !reg_error;
      assign iohpmevt_of_wd[i]          = reg_wdata[31];
    end
  end : gen_hpm_write_logic
  // No HPM
  else begin : gen_hpm_write_logic_disabled
    assign iocountinh_cy_we = 1'b0;
    assign iocountinh_cy_wd = '0;
    assign iocountinh_hpm_we = 1'b0;
    assign iocountinh_hpm_wd = '0;
    assign iohpmcycles_counter_l_we = 1'b0;
    assign iohpmcycles_counter_l_wd = '0;
    assign iohpmcycles_counter_h_we = 1'b0;
    assign iohpmcycles_counter_h_wd = '0;
    assign iohpmcycles_of_we = 1'b0;
    assign iohpmcycles_of_wd = '0;
  end : gen_hpm_write_logic_disabled

  // Hardwire unused wires to zero
  for (genvar i = RVIOMMUCfg.NumHpmCounters; i < 31; i++) begin
      assign iohpmctr_counter_l_we[i]   = 1'b0;
      assign iohpmctr_counter_l_wd[i]   = '0;
      assign iohpmctr_counter_h_we[i]   = 1'b0;
      assign iohpmctr_counter_h_wd[i]   = '0;
      assign iohpmevt_eventid_we[i]     = 1'b0;
      assign iohpmevt_eventid_wd[i]     = '0;
      assign iohpmevt_dmask_we[i]       = 1'b0;
      assign iohpmevt_dmask_wd[i]       = '0;
      assign iohpmevt_pid_pscid_l_we[i] = 1'b0;
      assign iohpmevt_pid_pscid_l_wd[i] = '0;
      assign iohpmevt_pid_pscid_h_we[i] = 1'b0;
      assign iohpmevt_pid_pscid_h_wd[i] = '0;
      assign iohpmevt_did_gscid_we[i]   = 1'b0;
      assign iohpmevt_did_gscid_wd[i]   = '0;
      assign iohpmevt_pv_pscv_we[i]     = 1'b0;
      assign iohpmevt_pv_pscv_wd[i]     = '0;
      assign iohpmevt_dv_gscv_we[i]     = 1'b0;
      assign iohpmevt_dv_gscv_wd[i]     = '0;
      assign iohpmevt_idt_we[i]         = 1'b0;
      assign iohpmevt_idt_wd[i]         = '0;
      assign iohpmevt_of_we[i]          = 1'b0;
      assign iohpmevt_of_wd[i]          = '0;
    end

  // Debug Register IF
    if (RVIOMMUCfg.InclDbg) begin : gen_dbg_if_write_logic
      assign tr_req_iova_vpn_l_we = addr_hit[144] & reg_we & !reg_error;
      assign tr_req_iova_vpn_l_wd = reg_wdata[31:12];
      assign tr_req_iova_vpn_h_we = addr_hit[145] & reg_we & !reg_error;
      assign tr_req_iova_vpn_h_wd = reg_wdata[31:0];
      assign tr_req_ctl_go_we = addr_hit[146] & reg_we & !reg_error;
      assign tr_req_ctl_go_wd = reg_wdata[0];
      assign tr_req_ctl_priv_we = addr_hit[146] & reg_we & !reg_error;
      assign tr_req_ctl_priv_wd = reg_wdata[1];
      assign tr_req_ctl_exe_we = addr_hit[146] & reg_we & !reg_error;
      assign tr_req_ctl_exe_wd = reg_wdata[2];
      assign tr_req_ctl_nw_we = addr_hit[146] & reg_we & !reg_error;
      assign tr_req_ctl_nw_wd = reg_wdata[3];
      if (RVIOMMUCfg.InclPC) begin : gen_pc_support_dbg_if_write_logic
        assign tr_req_ctl_pid_we = addr_hit[146] & reg_we & !reg_error;
        assign tr_req_ctl_pid_wd = reg_wdata[31:12];
        assign tr_req_ctl_pv_we = addr_hit[147] & reg_we & !reg_error;
        assign tr_req_ctl_pv_wd = reg_wdata[0];
      end : gen_pc_support_dbg_if_write_logic
      else begin : gen_pc_support_dbg_if_write_logic_disabled
        assign tr_req_ctl_pid_we = 1'b0;
        assign tr_req_ctl_pid_wd = '0;
        assign tr_req_ctl_pv_we = 1'b0;
        assign tr_req_ctl_pv_wd = '0;
      end : gen_pc_support_dbg_if_write_logic_disabled
      assign tr_req_ctl_did_we = addr_hit[147] & reg_we & !reg_error;
      assign tr_req_ctl_did_wd = reg_wdata[31:8];
    end : gen_dbg_if_write_logic
    else begin : gen_dbg_if_disabled_write_logic
      assign tr_req_iova_vpn_l_we = 1'b0;
      assign tr_req_iova_vpn_l_wd = '0;
      assign tr_req_iova_vpn_h_we = 1'b0;
      assign tr_req_iova_vpn_h_wd = '0;
      assign tr_req_ctl_go_we = 1'b0;
      assign tr_req_ctl_go_wd = '0;
      assign tr_req_ctl_priv_we = 1'b0;
      assign tr_req_ctl_priv_wd = '0;
      assign tr_req_ctl_exe_we = 1'b0;
      assign tr_req_ctl_exe_wd = '0;
      assign tr_req_ctl_nw_we = 1'b0;
      assign tr_req_ctl_nw_wd = '0;
      assign tr_req_ctl_pid_we = 1'b0;
      assign tr_req_ctl_pid_wd = '0;
      assign tr_req_ctl_pv_we = 1'b0;
      assign tr_req_ctl_pv_wd = '0;
      assign tr_req_ctl_did_we = 1'b0;
      assign tr_req_ctl_did_wd = '0;  
    end : gen_dbg_if_disabled_write_logic

  // icvec
  if (RVIOMMUCfg.NumIntVec > 1) begin : gen_icvec_write_logic
    assign icvec_civ_we = addr_hit[150] & reg_we & !reg_error;
    assign icvec_civ_wd = {{4-LOG2_INTVEC{1'b0}}, reg_wdata[(LOG2_INTVEC-1)+0:0]};
    assign icvec_fiv_we = addr_hit[150] & reg_we & !reg_error;
    assign icvec_fiv_wd = {{4-LOG2_INTVEC{1'b0}}, reg_wdata[(LOG2_INTVEC-1)+4:4]};
    assign icvec_pmiv_we = addr_hit[150] & reg_we & !reg_error;
    assign icvec_pmiv_wd = {{4-LOG2_INTVEC{1'b0}}, reg_wdata[(LOG2_INTVEC-1)+8:8]};
  end : gen_icvec_write_logic
  else begin : gen_icvec_write_logic_disabled
    assign icvec_civ_we = 1'b0;
    assign icvec_civ_wd = '0;
    assign icvec_fiv_we = 1'b0;
    assign icvec_fiv_wd = '0;
    assign icvec_pmiv_we = 1'b0;
    assign icvec_pmiv_wd = '0;
  end : gen_icvec_write_logic_disabled

  // MSI Config Table
  for (genvar i = 0; i < RVIOMMUCfg.NumIntVec; i++) begin : gen_msi_cfg_tbl_write_logic
    // msi_addr_x (low)
    assign msi_addr_l_we[i] = addr_hit[152+i] & reg_we & !reg_error;
    assign msi_addr_l_wd[i] = reg_wdata[31:2];
    // msi_addr_x (high)
    assign msi_addr_h_we[i] = addr_hit[168+i] & reg_we & !reg_error;
    assign msi_addr_h_wd[i] = reg_wdata[23:0];
    // msi_data_x
    assign msi_data_we[i] = addr_hit[184+i] & reg_we & !reg_error;
    assign msi_data_wd[i] = reg_wdata[31:0];
    // msi_vec_ctl_x
    assign msi_vec_ctl_we[i] = addr_hit[200+i] & reg_we & !reg_error;
    assign msi_vec_ctl_wd[i] = reg_wdata[0];
  end : gen_msi_cfg_tbl_write_logic
  // Hardwire unused bits to zero
  for (genvar i = RVIOMMUCfg.NumIntVec; i < 16; i++) begin
    assign msi_addr_l_we[i] = 1'b0;
    assign msi_addr_l_wd[i] = '0;
    assign msi_addr_h_we[i] = 1'b0;
    assign msi_addr_h_wd[i] = '0;
    assign msi_data_we[i] = 1'b0;
    assign msi_data_wd[i] = '0;
    assign msi_vec_ctl_we[i] = 1'b0;
    assign msi_vec_ctl_wd[i] = '0;
  end

  //-----------------
  // Read data logic
  //-----------------
  
  logic   iohpmctr_l_hit_vector, iohpmctr_h_hit_vector;
  logic   iohpmevt_l_hit_vector, iohpmevt_h_hit_vector;
  assign  iohpmctr_l_hit_vector = (RVIOMMUCfg.NumHpmCounters > 0) ? 
                                  (|addr_hit[(20+NZ_NHPMCTR-1):20])   : ('0);
  assign  iohpmctr_h_hit_vector = (RVIOMMUCfg.NumHpmCounters > 0) ? 
                                  (|addr_hit[(51+NZ_NHPMCTR-1):51])   : ('0);
  assign  iohpmevt_l_hit_vector = (RVIOMMUCfg.NumHpmCounters > 0) ? 
                                  (|addr_hit[(82+NZ_NHPMCTR-1):82])   : ('0);
  assign  iohpmevt_h_hit_vector = (RVIOMMUCfg.NumHpmCounters > 0) ? 
                                  (|addr_hit[(113+NZ_NHPMCTR-1):113]) : ('0);

  logic msi_addr_l_hit_vector;
  logic msi_addr_h_hit_vector;
  logic msi_data_hit_vector;
  logic msi_vect_hit_vector;
  assign msi_addr_l_hit_vector = (RVIOMMUCfg.NumIntVec > 0) ? 
                                 (|addr_hit[(152+RVIOMMUCfg.NumIntVec-1):152]) : '0;
  assign msi_addr_h_hit_vector = (RVIOMMUCfg.NumIntVec > 0) ? 
                                 (|addr_hit[(168+RVIOMMUCfg.NumIntVec-1):168]) : '0;
  assign msi_data_hit_vector   = (RVIOMMUCfg.NumIntVec > 0) ? 
                                 (|addr_hit[(184+RVIOMMUCfg.NumIntVec-1):184]) : '0;
  assign msi_vect_hit_vector   = (RVIOMMUCfg.NumIntVec > 0) ? 
                                 (|addr_hit[(200+RVIOMMUCfg.NumIntVec-1):200]) : '0;

  always_comb begin
    reg_rdata_next = '0;
    unique case (1'b1)

      // caps (low)
      addr_hit[0]: begin
        reg_rdata_next[7:0]   = capabilities_version_qs;
        reg_rdata_next[8]     = capabilities_sv32_qs;
        reg_rdata_next[9]     = capabilities_sv39_qs;
        reg_rdata_next[10]    = capabilities_sv48_qs;
        reg_rdata_next[11]    = capabilities_sv57_qs;
        reg_rdata_next[14:12] = '0;
        reg_rdata_next[15]    = capabilities_svpbmt_qs;
        reg_rdata_next[16]    = capabilities_sv32x4_qs;
        reg_rdata_next[17]    = capabilities_sv39x4_qs;
        reg_rdata_next[18]    = capabilities_sv48x4_qs;
        reg_rdata_next[19]    = capabilities_sv57x4_qs;
        reg_rdata_next[20]    = capabilities_amo_mrif_qs;
        reg_rdata_next[21]    = '0;
        reg_rdata_next[22]    = capabilities_msi_flat_qs;
        reg_rdata_next[23]    = capabilities_msi_mrif_qs;
        reg_rdata_next[24]    = capabilities_amo_hwad_qs;
        reg_rdata_next[25]    = capabilities_ats_qs;
        reg_rdata_next[26]    = capabilities_t2gpa_qs;
        reg_rdata_next[27]    = capabilities_endi_qs;
        reg_rdata_next[29:28] = capabilities_igs_qs;
        reg_rdata_next[30]    = capabilities_hpm_qs;
        reg_rdata_next[31]    = capabilities_dbg_qs;
      end
      // caps (high)
      addr_hit[1]: begin
        reg_rdata_next[5:0]   = capabilities_pas_qs;
        reg_rdata_next[6]     = capabilities_pd8_qs;
        reg_rdata_next[7]     = capabilities_pd17_qs;
        reg_rdata_next[8]     = capabilities_pd20_qs;
        reg_rdata_next[9]     = capabilities_qosid_qs;
        reg_rdata_next[31:10] = '0;
      end

      // fctl
      addr_hit[2]: begin
        reg_rdata_next[0]     = fctl_be_qs;
        reg_rdata_next[1]     = fctl_wsi_qs;
        reg_rdata_next[2]     = fctl_gxl_qs;
        reg_rdata_next[15:3]  = '0;
        reg_rdata_next[31:16] = '0;
      end

      // ddtp (low)
      addr_hit[3]: begin
        reg_rdata_next[3:0]   = ddtp_iommu_mode_qs;
        reg_rdata_next[4]     = ddtp_busy_qs;
        reg_rdata_next[9:5]   = '0;
        reg_rdata_next[31:10] = ddtp_ppn_l_qs;
      end
      // ddtp (high)
      addr_hit[4]: begin
        reg_rdata_next[21:0]  = ddtp_ppn_h_qs;
        reg_rdata_next[31:22] = '0;
      end

      // cqb (low)
      addr_hit[5]: begin
        reg_rdata_next[4:0]   = cqb_log2sz_1_qs;
        reg_rdata_next[9:5]   = '0;
        reg_rdata_next[31:10] = cqb_ppn_l_qs;
      end
      // cqb (high)
      addr_hit[6]: begin
        reg_rdata_next[21:0]  = cqb_ppn_h_qs;
        reg_rdata_next[31:22] = '0;
      end
      // cqh
      addr_hit[7]: begin
        reg_rdata_next[31:0]  = cqh_qs;
      end
      // cqt
      addr_hit[8]: begin
        reg_rdata_next[31:0]  = cqt_qs;
      end

      // fqb (low)
      addr_hit[9]: begin
        reg_rdata_next[4:0]   = fqb_log2sz_1_qs;
        reg_rdata_next[9:5]   = '0;
        reg_rdata_next[31:10] = fqb_ppn_l_qs;
      end
      // fqb (high)
      addr_hit[10]: begin
        reg_rdata_next[21:0]  = fqb_ppn_h_qs;
        reg_rdata_next[31:22] = '0;
      end
      // fqh
      addr_hit[11]: begin
        reg_rdata_next[31:0]  = fqh_qs;
      end
      // fqt
      addr_hit[12]: begin
        reg_rdata_next[31:0]  = fqt_qs;
      end

      // cqcsr
      addr_hit[13]: begin
        reg_rdata_next[0]     = cqcsr_cqen_qs;
        reg_rdata_next[1]     = cqcsr_cie_qs;
        reg_rdata_next[7:2]   = '0;
        reg_rdata_next[8]     = cqcsr_cqmf_qs;
        reg_rdata_next[9]     = cqcsr_cmd_to_qs;
        reg_rdata_next[10]    = cqcsr_cmd_ill_qs;
        reg_rdata_next[11]    = cqcsr_fence_w_ip_qs;
        reg_rdata_next[15:12] = '0;
        reg_rdata_next[16]    = cqcsr_cqon_qs;
        reg_rdata_next[17]    = cqcsr_busy_qs;
        reg_rdata_next[27:18] = '0;
        reg_rdata_next[31:28] = '0;
      end

      // fqcsr
      addr_hit[14]: begin
        reg_rdata_next[0]     = fqcsr_fqen_qs;
        reg_rdata_next[1]     = fqcsr_fie_qs;
        reg_rdata_next[7:2]   = '0;
        reg_rdata_next[8]     = fqcsr_fqmf_qs;
        reg_rdata_next[9]     = fqcsr_fqof_qs;
        reg_rdata_next[15:10] = '0;
        reg_rdata_next[16]    = fqcsr_fqon_qs;
        reg_rdata_next[17]    = fqcsr_busy_qs;
        reg_rdata_next[27:18] = '0;
        reg_rdata_next[31:28] = '0;
      end

      // ipsr
      addr_hit[15]: begin
        reg_rdata_next[0]     = ipsr_cip_qs;
        reg_rdata_next[1]     = ipsr_fip_qs;
        reg_rdata_next[2]     = ipsr_pmip_qs;
        reg_rdata_next[3]     = 1'b0;
        reg_rdata_next[31:4]  = '0;
      end

      // HPM
      // iocountovf
      addr_hit[16]: begin
        reg_rdata_next[0] = iohpmcycles_of_qs;
        for (int unsigned i = 0; i < 31; i++) begin
          reg_rdata_next[i+1] = iohpmevt_of_qs[i];
        end
      end
      // iocountinh
      addr_hit[17]: begin
        reg_rdata_next[0]     = iocountinh_cy_qs;
        reg_rdata_next[31:1]  = iocountinh_hpm_qs;
      end
      // iohpmcycles (low)
      addr_hit[18]: begin
        reg_rdata_next[31:0]  = iohpmcycles_counter_l_qs;
      end
      // iohpmcycles (high)
      addr_hit[19]: begin
        reg_rdata_next[30:0]  = iohpmcycles_counter_h_qs;
        reg_rdata_next[31]    = iohpmcycles_of_qs;
      end
      // iohpmctr_n (low)
      (iohpmctr_l_hit_vector): begin
        for (int unsigned i = 0; i < NZ_NHPMCTR; i++) begin
          if (addr_hit[i+20])
            reg_rdata_next[31:0] = iohpmctr_counter_l_qs[i];
        end
      end
      // iohpmctr_n (high)
      (iohpmctr_h_hit_vector): begin
        for (int unsigned i = 0; i < NZ_NHPMCTR; i++) begin
          if (addr_hit[i+51])
            reg_rdata_next[31:0] = iohpmctr_counter_h_qs[i];
        end
      end
      // iohpmevt_n (low)
      (iohpmevt_l_hit_vector): begin
        for (int unsigned i = 0; i < NZ_NHPMCTR; i++) begin
          if (addr_hit[i+82]) begin
            reg_rdata_next[14:0]  = iohpmevt_eventid_qs[i];
            reg_rdata_next[15]    = iohpmevt_dmask_qs[i];
            reg_rdata_next[31:16] = iohpmevt_pid_pscid_l_qs[i];
          end 
        end
      end
      // iohpmevt_n (high)
      (iohpmevt_h_hit_vector): begin
        for (int unsigned i = 0; i < NZ_NHPMCTR; i++) begin
          if (addr_hit[i+113]) begin
            reg_rdata_next[3:0]   = iohpmevt_pid_pscid_h_qs[i];
            reg_rdata_next[27:4]  = iohpmevt_did_gscid_qs[i];
            reg_rdata_next[28]    = iohpmevt_pv_pscv_qs[i];
            reg_rdata_next[29]    = iohpmevt_dv_gscv_qs[i];
            reg_rdata_next[30]    = iohpmevt_idt_qs[i];
            reg_rdata_next[31]    = iohpmevt_of_qs[i];
          end 
        end
      end

      // Debug Register IF
      // tr_req_iova (low)
      addr_hit[144]: begin
        reg_rdata_next[31:12] = tr_req_iova_vpn_l_qs;
        reg_rdata_next[11:0]  = '0;
      end
      // tr_req_iova (high)
      addr_hit[145]: begin
        reg_rdata_next[31:0]  = tr_req_iova_vpn_h_qs;
      end
      // tr_req_ctl  (low)
      addr_hit[146]: begin
        reg_rdata_next[0]     = tr_req_ctl_go_qs;
        reg_rdata_next[1]     = tr_req_ctl_priv_qs;
        reg_rdata_next[2]     = tr_req_ctl_exe_qs;
        reg_rdata_next[3]     = tr_req_ctl_nw_qs;
        reg_rdata_next[31:12] = tr_req_ctl_pid_wd;
      end
      // tr_req_ctl  (high)
      addr_hit[147]: begin
        reg_rdata_next[0]     = tr_req_ctl_pv_qs;
        reg_rdata_next[31:8]  = tr_req_ctl_did_qs;
      end
      // tr_response (low)
      addr_hit[148]: begin
        reg_rdata_next[0]     = tr_response_fault_qs;
        reg_rdata_next[8:7]   = tr_response_pbmt_qs;
        reg_rdata_next[9]     = tr_response_s_qs;
        reg_rdata_next[31:10] = tr_response_ppn_l_qs;
      end
      // tr_response (high)
      addr_hit[149]: begin
        reg_rdata_next[21:0]  = tr_response_ppn_h_qs;
      end

      // icvec (low)
      addr_hit[150]: begin
        reg_rdata_next[3:0]   = icvec_civ_qs;
        reg_rdata_next[7:4]   = icvec_fiv_qs;
        reg_rdata_next[11:8]  = icvec_pmiv_qs;
        reg_rdata_next[15:12] = '0;
        reg_rdata_next[31:16] = '0;
      end
      // icvec (high)
      addr_hit[151]: begin
        reg_rdata_next[31:0] = '0;
      end

      // msi_addr_x (low)
      (msi_addr_l_hit_vector): begin
        for (int unsigned i = 0; i < RVIOMMUCfg.NumIntVec; i++) begin
          if (addr_hit[i+152]) begin
            reg_rdata_next[1:0] = '0;
            reg_rdata_next[31:2] = msi_addr_l_qs[i];
          end
        end
      end
      // msi_addr_x (high)
      (msi_addr_h_hit_vector): begin
        for (int unsigned i = 0; i < RVIOMMUCfg.NumIntVec; i++) begin
          if (addr_hit[i+168]) begin
            reg_rdata_next[23:0] = msi_addr_h_qs[i];
            reg_rdata_next[31:24] = '0;
          end
        end
      end
      // msi_data_x
      (msi_data_hit_vector): begin
        for (int unsigned i = 0; i < RVIOMMUCfg.NumIntVec; i++) begin
          if (addr_hit[i+184]) begin
            reg_rdata_next[31:0] = msi_data_qs[i];
          end
        end
      end
      // msi_vec_ctl_x
      (msi_vect_hit_vector): begin
        for (int unsigned i = 0; i < RVIOMMUCfg.NumIntVec; i++) begin
          if (addr_hit[i+200]) begin
            reg_rdata_next[0] = msi_vec_ctl_qs[i];
            reg_rdata_next[31:1] = '0;
          end
        end
      end

      default: begin
        reg_rdata_next = '0;
      end
    endcase
  end

  // * Unused signal tieoff

  // wdata / byte enable are not always fully used
  // add a blanket unused statement to handle lint waivers
  logic unused_wdata;
  logic unused_be;
  assign unused_wdata = ^reg_wdata;
  assign unused_be = ^reg_be;

  // Assertions for Register Interface
  `ASSERT(en2addrHit, (reg_we || reg_re) |-> $onehot0(addr_hit))

endmodule
