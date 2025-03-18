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
// Description: Macros to define AXI Request/Response Structs extended 
//              with support for untranslated transactions.
//              See AMBA AXI Spec, Chapter A14.

`ifndef AXI_IOMMU_TYPEDEF_SVH_
`define AXI_IOMMU_TYPEDEF_SVH_

`include "axi/typedef.svh"

////////////////////////////////////////////////////////////////////////////////////////////////////
// AXI4+ATOP Channel and Request/Response Structs
//
// Usage Example:
// `AXI_TYPEDEF_AW_CHAN_EXT_T(axi_aw_chan_t, axi_addr_t, axi_id_t, axi_user_t, iommu_sid_t, iommu_ssidv_t, iommu_ssid_t)
// `AXI_TYPEDEF_AR_CHAN_EXT_T(axi_ar_chan_t, axi_addr_t, axi_id_t, axi_user_t, iommu_sid_t, iommu_ssidv_t, iommu_ssid_t)
// `AXI_TYPEDEF_REQ_EXT_T(axi_req_t, axi_aw_chan_t, axi_w_chan_t, axi_aw_chan_t)
//
// This defines `axi_req_t` extended request struct as well as `axi_aw_chan_t`,
// `axi_w_chan_t`, and `axi_ar_chan_t` channel structs.
`define AXI_TYPEDEF_AW_CHAN_EXT_T(aw_chan_ext_t, addr_t, id_t, user_t, iommu_sid_t, iommu_ssidv_t, iommu_ssid_t)  \
  typedef struct packed {                                       \
    id_t              id;                                       \
    addr_t            addr;                                     \
    axi_pkg::len_t    len;                                      \
    axi_pkg::size_t   size;                                     \
    axi_pkg::burst_t  burst;                                    \
    logic             lock;                                     \
    axi_pkg::cache_t  cache;                                    \
    axi_pkg::prot_t   prot;                                     \
    axi_pkg::qos_t    qos;                                      \
    axi_pkg::region_t region;                                   \
    axi_pkg::atop_t   atop;                                     \
    user_t            user;                                     \
    iommu_sid_t       stream_id;                                \
    iommu_ssidv_t     ss_id_valid;                              \
    iommu_ssid_t      substream_id;                             \
    logic [1:0]       mmu_flow;                                 \
    logic             mmu_atst;                                 \
    logic             mmu_secsid;                               \
    logic             mmu_valid;                                \
  } aw_chan_ext_t;
`define AXI_TYPEDEF_AR_CHAN_EXT_T(ar_chan_ext_t, addr_t, id_t, user_t, iommu_sid_t, iommu_ssidv_t, iommu_ssid_t)  \
  typedef struct packed {                                       \
    id_t              id;                                       \
    addr_t            addr;                                     \
    axi_pkg::len_t    len;                                      \
    axi_pkg::size_t   size;                                     \
    axi_pkg::burst_t  burst;                                    \
    logic             lock;                                     \
    axi_pkg::cache_t  cache;                                    \
    axi_pkg::prot_t   prot;                                     \
    axi_pkg::qos_t    qos;                                      \
    axi_pkg::region_t region;                                   \
    user_t            user;                                     \
    iommu_sid_t       stream_id;                                \
    iommu_ssidv_t     ss_id_valid;                              \
    iommu_ssid_t      substream_id;                             \
    logic [1:0]       mmu_flow;                                 \
    logic             mmu_atst;                                 \
    logic             mmu_secsid;                               \
    logic             mmu_valid;                                \
  } ar_chan_ext_t;
`define AXI_TYPEDEF_REQ_EXT_T(req_ext_t, aw_chan_ext_t, w_chan_t, ar_chan_ext_t)  \
  typedef struct packed {                                       \
    aw_chan_ext_t aw;                                           \
    logic         aw_valid;                                     \
    w_chan_t      w;                                            \
    logic         w_valid;                                      \
    logic         b_ready;                                      \
    ar_chan_ext_t ar;                                           \
    logic         ar_valid;                                     \
    logic         r_ready;                                      \
  } req_ext_t;
////////////////////////////////////////////////////////////////////////////////////////////////////

////////////////////////////////////////////////////////////////////////////////////////////////////
// All Extended AXI4+ATOP Channels and Request/Response Structs in One Macro
//
// This can be used whenever the user is not interested in "precise" control of the naming of the
// individual channels.
//
// Usage Example:
// `AXI_TYPEDEF_EXT_ALL(axi, addr_t, id_t, data_t, strb_t, user_t, sid_t, ssidv_t, ssid_t)
//
// This defines `axi_req_t` (extended) and `axi_resp_t` request/response structs as well as `axi_aw_chan_t`,
// `axi_w_chan_t`, `axi_b_chan_t`, `axi_ar_chan_t`, and `axi_r_chan_t` channel structs.
`define AXI_TYPEDEF_EXT_ALL(__name, __addr_t, __id_t, __data_t, __strb_t, __user_t, __iommu_sid_t, __iommu_ssidv_t, __iommu_ssid_t) \
  `AXI_TYPEDEF_AW_CHAN_EXT_T(__name``_aw_chan_t, __addr_t, __id_t, __user_t, __iommu_sid_t, __iommu_ssidv_t, __iommu_ssid_t)         \
  `AXI_TYPEDEF_W_CHAN_T(__name``_w_chan_t, __data_t, __strb_t, __user_t)                                                                               \
  `AXI_TYPEDEF_B_CHAN_T(__name``_b_chan_t, __id_t, __user_t)                                                                                           \
  `AXI_TYPEDEF_AR_CHAN_EXT_T(__name``_ar_chan_t, __addr_t, __id_t, __user_t, __iommu_sid_t, __iommu_ssidv_t, __iommu_ssid_t)         \
  `AXI_TYPEDEF_R_CHAN_T(__name``_r_chan_t, __data_t, __id_t, __user_t)                                                                                 \
  `AXI_TYPEDEF_REQ_EXT_T(__name``_req_t, __name``_aw_chan_t, __name``_w_chan_t, __name``_ar_chan_t)                                                    \
  `AXI_TYPEDEF_RESP_T(__name``_resp_t, __name``_b_chan_t, __name``_r_chan_t)
////////////////////////////////////////////////////////////////////////////////////////////////////


`endif
