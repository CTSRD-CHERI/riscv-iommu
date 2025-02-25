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
// Description: Macros to assign AXI Interfaces and Structs extended 
//              with support for untranslated transactions.
//              See AMBA AXI Spec, Chapter A14.

`ifndef AXI_IOMMU_ASSIGN_SVH_
`define AXI_IOMMU_ASSIGN_SVH_

`include "axi/assign.svh"

////////////////////////////////////////////////////////////////////////////////////////////////////
// Internal implementation for assigning one extended AXI struct or interface to another struct or interface.
// The path to the signals on each side is defined by the `__sep*` arguments.  The `__opt_as`
// argument allows to use this standalone (with `__opt_as = assign`) or in assignments inside
// processes (with `__opt_as` void).
`define __AXI_TO_AW_EXT(__opt_as, __lhs, __lhs_sep, __rhs, __rhs_sep)       \
  __opt_as __lhs``__lhs_sep``id           = __rhs``__rhs_sep``id;           \
  __opt_as __lhs``__lhs_sep``addr         = __rhs``__rhs_sep``addr;         \
  __opt_as __lhs``__lhs_sep``len          = __rhs``__rhs_sep``len;          \
  __opt_as __lhs``__lhs_sep``size         = __rhs``__rhs_sep``size;         \
  __opt_as __lhs``__lhs_sep``burst        = __rhs``__rhs_sep``burst;        \
  __opt_as __lhs``__lhs_sep``lock         = __rhs``__rhs_sep``lock;         \
  __opt_as __lhs``__lhs_sep``cache        = __rhs``__rhs_sep``cache;        \
  __opt_as __lhs``__lhs_sep``prot         = __rhs``__rhs_sep``prot;         \
  __opt_as __lhs``__lhs_sep``qos          = __rhs``__rhs_sep``qos;          \
  __opt_as __lhs``__lhs_sep``region       = __rhs``__rhs_sep``region;       \
  __opt_as __lhs``__lhs_sep``atop         = __rhs``__rhs_sep``atop;         \
  __opt_as __lhs``__lhs_sep``user         = __rhs``__rhs_sep``user;         \
  __opt_as __lhs``__lhs_sep``stream_id    = __rhs``__rhs_sep``stream_id;    \
  __opt_as __lhs``__lhs_sep``ss_id_valid  = __rhs``__rhs_sep``ss_id_valid;  \
  __opt_as __lhs``__lhs_sep``substream_id = __rhs``__rhs_sep``substream_id;
`define __AXI_TO_AR_EXT(__opt_as, __lhs, __lhs_sep, __rhs, __rhs_sep)       \
  __opt_as __lhs``__lhs_sep``id           = __rhs``__rhs_sep``id;           \
  __opt_as __lhs``__lhs_sep``addr         = __rhs``__rhs_sep``addr;         \
  __opt_as __lhs``__lhs_sep``len          = __rhs``__rhs_sep``len;          \
  __opt_as __lhs``__lhs_sep``size         = __rhs``__rhs_sep``size;         \
  __opt_as __lhs``__lhs_sep``burst        = __rhs``__rhs_sep``burst;        \
  __opt_as __lhs``__lhs_sep``lock         = __rhs``__rhs_sep``lock;         \
  __opt_as __lhs``__lhs_sep``cache        = __rhs``__rhs_sep``cache;        \
  __opt_as __lhs``__lhs_sep``prot         = __rhs``__rhs_sep``prot;         \
  __opt_as __lhs``__lhs_sep``qos          = __rhs``__rhs_sep``qos;          \
  __opt_as __lhs``__lhs_sep``region       = __rhs``__rhs_sep``region;       \
  __opt_as __lhs``__lhs_sep``user         = __rhs``__rhs_sep``user;         \
  __opt_as __lhs``__lhs_sep``stream_id    = __rhs``__rhs_sep``stream_id;    \
  __opt_as __lhs``__lhs_sep``ss_id_valid  = __rhs``__rhs_sep``ss_id_valid;  \
  __opt_as __lhs``__lhs_sep``substream_id = __rhs``__rhs_sep``substream_id;
`define __AXI_TO_REQ_EXT(__opt_as, __lhs, __lhs_sep, __rhs, __rhs_sep)  \
  `__AXI_TO_AW_EXT(__opt_as, __lhs.aw, __lhs_sep, __rhs.aw, __rhs_sep)  \
  __opt_as __lhs.aw_valid = __rhs.aw_valid;                             \
  `__AXI_TO_W(__opt_as, __lhs.w, __lhs_sep, __rhs.w, __rhs_sep)         \
  __opt_as __lhs.w_valid = __rhs.w_valid;                               \
  __opt_as __lhs.b_ready = __rhs.b_ready;                               \
  `__AXI_TO_AR_EXT(__opt_as, __lhs.ar, __lhs_sep, __rhs.ar, __rhs_sep)  \
  __opt_as __lhs.ar_valid = __rhs.ar_valid;                             \
  __opt_as __lhs.r_ready = __rhs.r_ready;
////////////////////////////////////////////////////////////////////////////////////////////////////

////////////////////////////////////////////////////////////////////////////////////////////////////
// Assigning an interface from extended channel or request/response structs outside a process.
//
// The request macro `AXI_ASSIGN_FROM_REQ_EXT(axi_if, req_struct)` assigns all request channels (AW, W,
// AR) and the request-side handshake signals (AW, W, and AR valid and B and R ready) of the extended
// `axi_if` interface from the signals in `req_struct`.
//
// Usage Example:
// `AXI_ASSIGN_FROM_REQ_EXT(my_if, my_req_struct)
`define AXI_ASSIGN_FROM_REQ_EXT(axi_if, req_struct)   `__AXI_TO_REQ_EXT(assign, axi_if, _, req_struct, .)

////////////////////////////////////////////////////////////////////////////////////////////////////

////////////////////////////////////////////////////////////////////////////////////////////////////
// Assigning extended channel or request/response structs from an interface outside a process.
//
// The request macro `AXI_ASSIGN_TO_REQ_EXT(axi_if, req_struct)` assigns all signals of `req_struct`
// (i.e., extended request channel (AW, W, AR) payload and request-side handshake signals (AW, W, and AR
// valid and B and R ready)) to the signals in the extended `axi_if` interface.
//
// Usage Example:
// `AXI_ASSIGN_TO_REQ_EXT(my_req_struct, my_if)
`define AXI_ASSIGN_TO_REQ_EXT(req_struct, axi_if)   `__AXI_TO_REQ_EXT(assign, req_struct, ., axi_if, _)
////////////////////////////////////////////////////////////////////////////////////////////////////

////////////////////////////////////////////////////////////////////////////////////////////////////
// Macros for assigning req/resp AXI structs from flattened AXI ports.
// Flat AXI ports are required by the Vivado IP Integrator. Vivado naming convention is followed.
//
// Usage Example:
// `AXI_ASSIGN_FLAT_TO_MASTER("my_bus", my_req_struct, my_rsp_struct)
`define AXI_ASSIGN_FLAT_TO_SLAVE(pat, req, rsp) \
  assign s_axi_``pat``_awvalid  = req.aw_valid;  \
  assign s_axi_``pat``_awid     = req.aw.id;     \
  assign s_axi_``pat``_awaddr   = req.aw.addr;   \
  assign s_axi_``pat``_awlen    = req.aw.len;    \
  assign s_axi_``pat``_awsize   = req.aw.size;   \
  assign s_axi_``pat``_awburst  = req.aw.burst;  \
  assign s_axi_``pat``_awlock   = req.aw.lock;   \
  assign s_axi_``pat``_awcache  = req.aw.cache;  \
  assign s_axi_``pat``_awprot   = req.aw.prot;   \
  assign s_axi_``pat``_awqos    = req.aw.qos;    \
  assign s_axi_``pat``_awregion = req.aw.region; \
  assign s_axi_``pat``_awuser   = req.aw.user;   \
                                                 \
  assign s_axi_``pat``_wvalid   = req.w_valid;   \
  assign s_axi_``pat``_wdata    = req.w.data;    \
  assign s_axi_``pat``_wstrb    = req.w.strb;    \
  assign s_axi_``pat``_wlast    = req.w.last;    \
  assign s_axi_``pat``_wuser    = req.w.user;    \
                                                 \
  assign s_axi_``pat``_bready   = req.b_ready;   \
                                                 \
  assign s_axi_``pat``_arvalid  = req.ar_valid;  \
  assign s_axi_``pat``_arid     = req.ar.id;     \
  assign s_axi_``pat``_araddr   = req.ar.addr;   \
  assign s_axi_``pat``_arlen    = req.ar.len;    \
  assign s_axi_``pat``_arsize   = req.ar.size;   \
  assign s_axi_``pat``_arburst  = req.ar.burst;  \
  assign s_axi_``pat``_arlock   = req.ar.lock;   \
  assign s_axi_``pat``_arcache  = req.ar.cache;  \
  assign s_axi_``pat``_arprot   = req.ar.prot;   \
  assign s_axi_``pat``_arqos    = req.ar.qos;    \
  assign s_axi_``pat``_arregion = req.ar.region; \
  assign s_axi_``pat``_aruser   = req.ar.user;   \
                                                 \
  assign s_axi_``pat``_rready   = req.r_ready;   \
                                                 \
  assign rsp.aw_ready = s_axi_``pat``_awready;   \
  assign rsp.ar_ready = s_axi_``pat``_arready;   \
  assign rsp.w_ready  = s_axi_``pat``_wready;    \
                                                 \
  assign rsp.b_valid  = s_axi_``pat``_bvalid;    \
  assign rsp.b.id     = s_axi_``pat``_bid;       \
  assign rsp.b.resp   = s_axi_``pat``_bresp;     \
  assign rsp.b.user   = s_axi_``pat``_buser;     \
                                                 \
  assign rsp.r_valid  = s_axi_``pat``_rvalid;    \
  assign rsp.r.id     = s_axi_``pat``_rid;       \
  assign rsp.r.data   = s_axi_``pat``_rdata;     \
  assign rsp.r.resp   = s_axi_``pat``_rresp;     \
  assign rsp.r.last   = s_axi_``pat``_rlast;     \
  assign rsp.r.user   = s_axi_``pat``_ruser;

`define AXI_ASSIGN_FLAT_TO_MASTER(pat, req, rsp)  \
  assign req.aw_valid  = m_axi_``pat``_awvalid;  \
  assign req.aw.id     = m_axi_``pat``_awid;     \
  assign req.aw.addr   = m_axi_``pat``_awaddr;   \
  assign req.aw.len    = m_axi_``pat``_awlen;    \
  assign req.aw.size   = m_axi_``pat``_awsize;   \
  assign req.aw.burst  = m_axi_``pat``_awburst;  \
  assign req.aw.lock   = m_axi_``pat``_awlock;   \
  assign req.aw.cache  = m_axi_``pat``_awcache;  \
  assign req.aw.prot   = m_axi_``pat``_awprot;   \
  assign req.aw.qos    = m_axi_``pat``_awqos;    \
  assign req.aw.region = m_axi_``pat``_awregion; \
  assign req.aw.user   = m_axi_``pat``_awuser;   \
                                                 \
  assign req.w_valid   = m_axi_``pat``_wvalid;   \
  assign req.w.data    = m_axi_``pat``_wdata;    \
  assign req.w.strb    = m_axi_``pat``_wstrb;    \
  assign req.w.last    = m_axi_``pat``_wlast;    \
  assign req.w.user    = m_axi_``pat``_wuser;    \
                                                 \
  assign req.b_ready   = m_axi_``pat``_bready;   \
                                                 \
  assign req.ar_valid  = m_axi_``pat``_arvalid;  \
  assign req.ar.id     = m_axi_``pat``_arid;     \
  assign req.ar.addr   = m_axi_``pat``_araddr;   \
  assign req.ar.len    = m_axi_``pat``_arlen;    \
  assign req.ar.size   = m_axi_``pat``_arsize;   \
  assign req.ar.burst  = m_axi_``pat``_arburst;  \
  assign req.ar.lock   = m_axi_``pat``_arlock;   \
  assign req.ar.cache  = m_axi_``pat``_arcache;  \
  assign req.ar.prot   = m_axi_``pat``_arprot;   \
  assign req.ar.qos    = m_axi_``pat``_arqos;    \
  assign req.ar.region = m_axi_``pat``_arregion; \
  assign req.ar.user   = m_axi_``pat``_aruser;   \
                                                 \
  assign req.r_ready   = m_axi_``pat``_rready;   \
                                                 \
  assign m_axi_``pat``_awready = rsp.aw_ready;   \
  assign m_axi_``pat``_arready = rsp.ar_ready;   \
  assign m_axi_``pat``_wready  = rsp.w_ready;    \
                                                 \
  assign m_axi_``pat``_bvalid  = rsp.b_valid;    \
  assign m_axi_``pat``_bid     = rsp.b.id;       \
  assign m_axi_``pat``_bresp   = rsp.b.resp;     \
  assign m_axi_``pat``_buser   = rsp.b.user;     \
                                                 \
  assign m_axi_``pat``_rvalid  = rsp.r_valid;    \
  assign m_axi_``pat``_rid     = rsp.r.id;       \
  assign m_axi_``pat``_rdata   = rsp.r.data;     \
  assign m_axi_``pat``_rresp   = rsp.r.resp;     \
  assign m_axi_``pat``_rlast   = rsp.r.last;     \
  assign m_axi_``pat``_ruser   = rsp.r.user;
////////////////////////////////////////////////////////////////////////////////////////////////////

`endif
