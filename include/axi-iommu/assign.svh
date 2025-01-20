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

`endif
