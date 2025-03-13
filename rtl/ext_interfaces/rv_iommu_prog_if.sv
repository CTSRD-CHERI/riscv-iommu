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
// Date:   20/01/2025
// Acknowledges: SSRC - Technology Innovation Institute (TII)
//
// Description: Wrapper for the RISC-V IOMMU programming interface.
//              Performs conversion between AXI4 and Register Interface.

`include "register_interface/assign.svh"

`include "axi/assign.svh"
`include "axi/typedef.svh"

module rv_iommu_prog_if #(
    /// RISC-V IOMMU configuration struct
    parameter rv_iommu_cfg::rv_iommu_cfg_t RVIOMMUCfg = rv_iommu_cfg::NullCfg,

    /// AXI data types
    parameter type axi_req_t        = logic,
    parameter type axi_resp_t       = logic,
    /// Register data types
    parameter type iommu_reg_req_t  = logic,
    parameter type iommu_reg_rsp_t  = logic
) (
    input  logic     clk_i,
    input  logic     rst_ni,

    // From IOMMU programing interface
    input  axi_req_t        prog_req_i,
    output axi_resp_t       prog_resp_o,

    // To register map
    output iommu_reg_req_t  regmap_req_o,
    input  iommu_reg_rsp_t  regmap_resp_i
);

    logic                                   penable;
    logic                                   pwrite;
    logic [(RVIOMMUCfg.AxiAddrWidth-1):0]   paddr;
    logic                                   psel;
    logic [31:0]                            pwdata;
    logic [31:0]                            prdata;
    logic                                   pready;
    logic                                   pslverr;

    // AXI4 to APB IF
    rv_iommu_axi2apb_64_32 #(
        .AXI4_ADDRESS_WIDTH (RVIOMMUCfg.AxiAddrWidth),
        .AXI4_RDATA_WIDTH   (RVIOMMUCfg.AxiDataWidth),
        .AXI4_WDATA_WIDTH   (RVIOMMUCfg.AxiDataWidth),
        .AXI4_ID_WIDTH      (RVIOMMUCfg.AxiProgIdWidth),
        .AXI4_USER_WIDTH    (RVIOMMUCfg.AxiUserWidth),
        .BUFF_DEPTH_SLAVE   (2),
        .APB_ADDR_WIDTH     (RVIOMMUCfg.AxiAddrWidth)
    ) i_axi2apb_64_32_iommu (
        .clk_i     (clk_i),
        .rst_ni    (rst_ni),
        .test_en_i (1'b0),
        // AW
        .AWID_i    (prog_req_i.aw.id),
        .AWADDR_i  (prog_req_i.aw.addr),
        .AWLEN_i   (prog_req_i.aw.len),
        .AWSIZE_i  (prog_req_i.aw.size),
        .AWBURST_i (prog_req_i.aw.burst),
        .AWLOCK_i  (prog_req_i.aw.lock),
        .AWCACHE_i (prog_req_i.aw.cache),
        .AWPROT_i  (prog_req_i.aw.prot),
        .AWREGION_i(prog_req_i.aw.region),
        .AWUSER_i  (prog_req_i.aw.user),
        .AWQOS_i   (prog_req_i.aw.qos),
        .AWVALID_i (prog_req_i.aw_valid),
        .AWREADY_o (prog_resp_o.aw_ready),
        // W
        .WDATA_i   (prog_req_i.w.data),
        .WSTRB_i   (prog_req_i.w.strb),
        .WLAST_i   (prog_req_i.w.last),
        .WUSER_i   (prog_req_i.w.user),
        .WVALID_i  (prog_req_i.w_valid),
        .WREADY_o  (prog_resp_o.w_ready),
        // B
        .BID_o     (prog_resp_o.b.id),
        .BRESP_o   (prog_resp_o.b.resp),
        .BUSER_o   (prog_resp_o.b.user),
        .BVALID_o  (prog_resp_o.b_valid),
        .BREADY_i  (prog_req_i.b_ready),
        // AR
        .ARID_i    (prog_req_i.ar.id),
        .ARADDR_i  (prog_req_i.ar.addr),
        .ARLEN_i   (prog_req_i.ar.len),
        .ARSIZE_i  (prog_req_i.ar.size),
        .ARBURST_i (prog_req_i.ar.burst),
        .ARLOCK_i  (prog_req_i.ar.lock),
        .ARCACHE_i (prog_req_i.ar.cache),
        .ARPROT_i  (prog_req_i.ar.prot),
        .ARREGION_i(prog_req_i.ar.region),
        .ARUSER_i  (prog_req_i.ar.user),
        .ARQOS_i   (prog_req_i.ar.qos),
        .ARVALID_i (prog_req_i.ar_valid),
        .ARREADY_o (prog_resp_o.ar_ready),
        // R
        .RID_o     (prog_resp_o.r.id),
        .RDATA_o   (prog_resp_o.r.data),
        .RRESP_o   (prog_resp_o.r.resp),
        .RLAST_o   (prog_resp_o.r.last),
        .RUSER_o   (prog_resp_o.r.user),
        .RVALID_o  (prog_resp_o.r_valid),
        .RREADY_i  (prog_req_i.r_ready),
        // APB IF
        .PENABLE   (penable),
        .PWRITE    (pwrite),
        .PADDR     (paddr),
        .PSEL      (psel),
        .PWDATA    (pwdata),
        .PRDATA    (prdata),
        .PREADY    (pready),
        .PSLVERR   (pslverr)
    );

    // Reg req
    assign regmap_req_o.addr   = paddr;
    assign regmap_req_o.write  = pwrite;
    assign regmap_req_o.wdata  = pwdata;
    assign regmap_req_o.wstrb  = '1;
    assign regmap_req_o.valid  = psel & penable;

    // Reg resp
    assign pready   = regmap_resp_i.ready;
    assign pslverr  = regmap_resp_i.error;
    assign prdata   = regmap_resp_i.rdata;
/*
// Copyright Â© 2023 Manuel RodrÃ­guez & Zero-Day Labs, Lda.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// Licensed under the Solderpad Hardware License v 2.1 (the âLicenseâ); 
// you may not use this file except in compliance with the License, 
// or, at your option, the Apache License version 2.0. 
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/.
// Unless required by applicable law or agreed to in writing, 
// any work distributed under the License is distributed on an âAS ISâ BASIS, 
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. 
// See the License for the specific language governing permissions and limitations under the License.
//
// Author: Manuel RodrÃ­guez <manuel.cederog@gmail.com>
// Date:   02/02/2023
// Acknowledges: SSRC - Technology Innovation Institute (TII)
//
// Description: Wrapper module for the RISC-V IOMMU register programming interface.
//              Instantiates the IOMMU register map and performs conversion between 
//              register interface protocol and AXI4.
//

`include "register_interface/assign.svh"

module rv_iommu_prog_if #(    
    parameter rv_iommu_cfg::rv_iommu_cfg_t RVIOMMUCfg = rv_iommu_cfg::NullCfg,
    /// AXI Full request struct type
    parameter type  axi_req_t = logic,
    /// AXI Full response struct type
    parameter type  axi_rsp_t = logic,
    /// Regbus request struct type.
    parameter type  reg_req_t = logic,
    /// Regbus response struct type.
    parameter type  reg_rsp_t = logic
) (
    // rising-edge clock 
    input  logic     clk_i,
    // asynchronous reset, active low
    input  logic     rst_ni,

    // From IOMMU programing interface
    input  axi_req_t prog_req_i,
    output axi_rsp_t prog_resp_o,

    // To register map
    output reg_req_t regmap_req_o,
    input  reg_rsp_t regmap_resp_i
);

    localparam int ADDR_WIDTH = RVIOMMUCfg.AxiAddrWidth;
    localparam int DATA_WIDTH = RVIOMMUCfg.AxiDataWidth;
    localparam int ID_WIDTH = RVIOMMUCfg.AxiProgIdWidth;
    localparam int USER_WIDTH = RVIOMMUCfg.AxiUserWidth;

    REG_BUS #(
        .ADDR_WIDTH ( 32  ),
        .DATA_WIDTH ( 32  )
    ) iommu_reg_bus (clk_i);

    logic                       penable;
    logic                       pwrite;
    logic [31:0]                paddr;
    logic                       psel;
    logic [31:0]                pwdata;
    logic [31:0]                prdata;
    logic                       pready;
    logic                       pslverr;

    // AXI4 to APB IF
    axi2apb_64_32 #(
        .AXI4_ADDRESS_WIDTH ( ADDR_WIDTH  ),
        .AXI4_RDATA_WIDTH   ( DATA_WIDTH  ),
        .AXI4_WDATA_WIDTH   ( DATA_WIDTH  ),
        .AXI4_ID_WIDTH      ( ID_WIDTH    ),
        .AXI4_USER_WIDTH    ( USER_WIDTH  ),
        .BUFF_DEPTH_SLAVE   ( 2           ),
        .APB_ADDR_WIDTH     ( 32          )
    ) i_axi2apb_64_32_iommu (
        .ACLK      ( clk_i          ),
        .ARESETn   ( rst_ni         ),
        .test_en_i ( 1'b0           ),
        // AW
        .AWID_i    ( prog_req_i.aw.id     ),
        .AWADDR_i  ( prog_req_i.aw.addr   ),
        .AWLEN_i   ( prog_req_i.aw.len    ),
        .AWSIZE_i  ( prog_req_i.aw.size   ),
        .AWBURST_i ( prog_req_i.aw.burst  ),
        .AWLOCK_i  ( prog_req_i.aw.lock   ),
        .AWCACHE_i ( prog_req_i.aw.cache  ),
        .AWPROT_i  ( prog_req_i.aw.prot   ),
        .AWREGION_i( prog_req_i.aw.region ),
        .AWUSER_i  ( prog_req_i.aw.user   ),
        .AWQOS_i   ( prog_req_i.aw.qos    ),
        .AWVALID_i ( prog_req_i.aw_valid  ),
        .AWREADY_o ( prog_resp_o.aw_ready ),
        // W
        .WDATA_i   ( prog_req_i.w.data    ),
        .WSTRB_i   ( prog_req_i.w.strb    ),
        .WLAST_i   ( prog_req_i.w.last    ),
        .WUSER_i   ( prog_req_i.w.user    ),
        .WVALID_i  ( prog_req_i.w_valid   ),
        .WREADY_o  ( prog_resp_o.w_ready  ),
        // B
        .BID_o     ( prog_resp_o.b.id     ),
        .BRESP_o   ( prog_resp_o.b.resp   ),
        .BUSER_o   ( prog_resp_o.b.user   ),
        .BVALID_o  ( prog_resp_o.b_valid  ),
        .BREADY_i  ( prog_req_i.b_ready   ),
        // AR
        .ARID_i    ( prog_req_i.ar.id     ),
        .ARADDR_i  ( prog_req_i.ar.addr   ),
        .ARLEN_i   ( prog_req_i.ar.len    ),
        .ARSIZE_i  ( prog_req_i.ar.size   ),
        .ARBURST_i ( prog_req_i.ar.burst  ),
        .ARLOCK_i  ( prog_req_i.ar.lock   ),
        .ARCACHE_i ( prog_req_i.ar.cache  ),
        .ARPROT_i  ( prog_req_i.ar.prot   ),
        .ARREGION_i( prog_req_i.ar.region ),
        .ARUSER_i  ( prog_req_i.ar.user   ),
        .ARQOS_i   ( prog_req_i.ar.qos    ),
        .ARVALID_i ( prog_req_i.ar_valid  ),
        .ARREADY_o ( prog_resp_o.ar_ready ),
        // R
        .RID_o     ( prog_resp_o.r.id     ),
        .RDATA_o   ( prog_resp_o.r.data   ),
        .RRESP_o   ( prog_resp_o.r.resp   ),
        .RLAST_o   ( prog_resp_o.r.last   ),
        .RUSER_o   ( prog_resp_o.r.user   ),
        .RVALID_o  ( prog_resp_o.r_valid  ),
        .RREADY_i  ( prog_req_i.r_ready   ),
        // APB IF
        .PENABLE   ( penable              ),
        .PWRITE    ( pwrite               ),
        .PADDR     ( paddr                ),
        .PSEL      ( psel                 ),
        .PWDATA    ( pwdata               ),
        .PRDATA    ( prdata               ),
        .PREADY    ( pready               ),
        .PSLVERR   ( pslverr              )
    );

    // APB to REG IF
    apb_to_reg i_apb_to_reg (
        .clk_i     ( clk_i          ),
        .rst_ni    ( rst_ni         ),
        .penable_i ( penable        ),
        .pwrite_i  ( pwrite         ),
        .paddr_i   ( paddr          ),
        .psel_i    ( psel           ),
        .pwdata_i  ( pwdata         ),
        .prdata_o  ( prdata         ),
        .pready_o  ( pready         ),
        .pslverr_o ( pslverr        ),
        .reg_o     ( iommu_reg_bus  )
    );

    // assign REG_BUS.out to (req_t, rsp_t) pair
    `REG_BUS_ASSIGN_TO_REQ(regmap_req_o, iommu_reg_bus)
    `REG_BUS_ASSIGN_FROM_RSP(iommu_reg_bus, regmap_resp_i)
*/
endmodule
