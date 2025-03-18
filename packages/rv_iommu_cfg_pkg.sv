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
// Author:  Manuel Rodríguez <manuel.cederog@gmail.com>
// Date:    20/01/2025
// Acknowledges: SSRC - Technology Innovation Institute (TII)
//
// Description: RISC-V IOMMU Configuration package.

`ifndef RV_IOMMU_CFG_PKG
`define RV_IOMMU_CFG_PKG

package rv_iommu_cfg;

    /*************************************************************************/
    /*                    Input Configuration Parameters                     */
    /*************************************************************************/

    /// MSI Translation Support
    typedef enum logic[1:0] {
        MSI_DISABLED  = 2'b00,
        MSI_BT_ONLY   = 2'b01,
        MSI_BT_MRIF   = 2'b10
    } msi_trans_t;

    /// Interrupt Generation Support
    typedef enum logic[1:0] {
        MSI_ONLY  = 2'b00,
        WSI_ONLY  = 2'b01,
        BOTH      = 2'b10
    } igs_t;

    /*************************************************************************/
    /*                 RISC-V IOMMU Configuration Structure                  */
    /*************************************************************************/
    typedef struct packed {
        /// Maximum number of outstanding R/W transactions
        int unsigned NumOutstandingTrans;
        /// Number of entries in the W FIFO
        int unsigned WFifoDepth;
        /// Number of entries in the MRIF FIFO
        int unsigned MrifFifoDepth;
        /// Number of entries in the Fault Arbiter FIFO
        int unsigned FaultFifoDepth;

        /// Number of IOTLB entries
        int unsigned NumIotlbEntries;
        /// Number of DDTC entries
        int unsigned NumDdtcEntries;
        /// Number of PDTC entries
        int unsigned NumPdtcEntries;
        /// Number of MRIF cache entries
        int unsigned NumMrifcEntries;
        
        /// Include Process Context support
        bit          InclPC;
        /// Include AXI4 address boundary check
        bit          InclAxiBC;
        /// Include debug register interface
        bit          InclDbg;
        /// Include Address Translation Services support
        bit          InclATS;
        /// MSI translation upport
        msi_trans_t  MSITrans;
        /// Interrupt Generation Support
        igs_t        IGS;
        /// Number of interrupt vectors supported [1 - 16]
        int unsigned NumIntVec;
        /// Number of Performance monitoring event counters [0 - 31]
        int unsigned NumHpmCounters;

        /// Physical Addr width
        int unsigned PAddrWidth;

        /// AXI address width
        int unsigned AxiAddrWidth;
        /// AXI data width
        int unsigned AxiDataWidth;
        /// AXI ID width
        int unsigned AxiIdWidth;
        /// AXI ID width for the Programming Interface
        int unsigned AxiProgIdWidth;
        /// AXI user width
        int unsigned AxiUserWidth;
        /// AXI process id width
        int unsigned AxiProIdWidth;
        /// AXI device id width
        int unsigned AxiDevIdWidth;
        /// AXIS Data Width
        int unsigned AxisDataWidth;
        /// AXIS Dest Width
        int unsigned AxisDestWidth;
        /// AXIS User Width
        int unsigned AxisUserWidth;
        /// AXIS Strb Width
        int unsigned AxisStrbWidth;
        /// AXIS Keep Width
        int unsigned AxisKeepWidth;
        /// AXIS ID Width
        int unsigned AxisIdWidth;
        /// Frequency, for Invalidation timeouts
        int unsigned Freq;
    } rv_iommu_cfg_t;

    /*************************************************************************/
    /*                     NULL Configuration Structure                      */
    /*************************************************************************/
    localparam rv_iommu_cfg_t NullCfg = rv_iommu_cfg_t'{
        NumOutstandingTrans : 32'd0,
        WFifoDepth          : 32'd0,
        MrifFifoDepth       : 32'd0,
        FaultFifoDepth      : 32'd0,
        NumIotlbEntries     : 32'd0,
        NumDdtcEntries      : 32'd0,
        NumPdtcEntries      : 32'd0,
        NumMrifcEntries     : 32'd0,
        InclPC              : 1'b0,
        InclAxiBC           : 1'b0,
        InclDbg             : 1'b0,
        InclATS             : 1'b0,
        MSITrans            : MSI_DISABLED,
        IGS                 : WSI_ONLY,
        NumIntVec           : 32'd0,
        NumHpmCounters      : 32'd0,
        PAddrWidth          : 32'd0,
        AxiAddrWidth        : 32'd0,
        AxiDataWidth        : 32'd0,
        AxiIdWidth          : 32'd0,
        AxiProgIdWidth      : 32'd0,
        AxiUserWidth        : 32'd0,
        AxiDevIdWidth       : 32'd0,
        AxiProIdWidth       : 32'd0,
        AxisDataWidth       : 32'd0,
        AxisUserWidth       : 32'd0,
        AxisKeepWidth       : 32'd0,
        AxisStrbWidth       : 32'd0,
        AxisIdWidth         : 32'd0,
        AxisDestWidth       : 32'd0,
        Freq                : 32'd0
    };

endpackage

`endif  /* RISCV_IOMMU_CFG_PKG */
