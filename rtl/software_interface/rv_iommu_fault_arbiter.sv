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
// Description: RISC-V IOMMU Fault Arbiter.
//              Arbitrates faults from different sources.

module rv_iommu_fault_arbiter #(
    /// RISC-V IOMMU configuration struct
    parameter rv_iommu_cfg::rv_iommu_cfg_t RVIOMMUCfg = rv_iommu_cfg::NullCfg,
    
    /// Number of input fault ports
    parameter int unsigned NumFaultPorts    = 32'd0,
    /// Fault data type
    parameter type fault_data_t = logic
) (
    input   logic                           clk_i,
    input   logic                           rst_ni,

    // Input fault ports
    input  fault_data_t [(NumFaultPorts-1):0]   fault_data_i,
    input  logic [(NumFaultPorts-1):0]          fault_valid_i,
    output logic [(NumFaultPorts-1):0]          fault_ready_o,

    // Output FQ record port
    output rv_iommu::fq_record_t                fq_data_o,
    output logic                                fq_valid_o,
    input  logic                                fq_ready_i
);

    fault_data_t [(NumFaultPorts-1):0]  fault_data_q;
    logic [(NumFaultPorts-1):0]         fault_valid_q;
    logic [(NumFaultPorts-1):0]         fault_ready_n;

    for (genvar i = 0; i < NumFaultPorts; i++) begin
        spill_register #(
            .T          (fault_data_t),
            .Bypass     (1'b0)
        ) i_fault_spill_register (
            .clk_i      (clk_i),
            .rst_ni     (rst_ni),

            .data_i     (fault_data_i[i]),
            .valid_i    (fault_valid_i[i]),
            .ready_o    (fault_ready_o[i]),

            .data_o     (fault_data_q[i]),
            .valid_o    (fault_valid_q[i]),
            .ready_i    (fault_ready_n[i])
        );
    end

    fault_data_t    arbited_data_d;
    logic           arbited_valid_d;
    logic           arbited_ready_q;

    stream_arbiter #(
        .DATA_T     (fault_data_t),
        .N_INP      (NumFaultPorts),
        .ARBITER    ("rr")
    ) i_fault_stream_arbiter (
        .clk_i      (clk_i),
        .rst_ni     (rst_ni),

        .inp_data_i     (fault_data_q),
        .inp_valid_i    (fault_valid_q),
        .inp_ready_o    (fault_ready_n),

        .oup_data_o     (arbited_data_d),
        .oup_valid_o    (arbited_valid_d),
        .oup_ready_i    (arbited_ready_q)
    );

    fault_data_t    arbited_data_q;
    logic           arbited_valid_q;
    logic           arbited_ready_d;

    stream_fifo #(
        .DEPTH (RVIOMMUCfg.FaultFifoDepth),
        .T     (fault_data_t)
    ) i_fault_fifo (
        .clk_i      (clk_i),
        .rst_ni     (rst_ni),
        .flush_i    ('0),
        .testmode_i ('0),
        .usage_o    (  ),

        .data_i     (arbited_data_d),
        .valid_i    (arbited_valid_d),
        .ready_o    (arbited_ready_q),

        .data_o     (arbited_data_q),
        .valid_o    (arbited_valid_q),
        .ready_i    (arbited_ready_d)
    );

    // Convert error_report_t to fq_record_t
    always_comb begin : fq_record_generation

        fq_valid_o = arbited_valid_q;
        arbited_ready_d = fq_ready_i;

        fq_data_o = '0;
        fq_data_o.ttyp = arbited_data_q.trans_type;
        fq_data_o.cause = arbited_data_q.cause_code;
        fq_data_o.iotval = (arbited_data_q.trans_type != rv_iommu::PCIE_MSG_REQ) ? 
                            (arbited_data_q.iova) :
                            ('0);

        // From Spec:
        // The DID, PV, PID, and PRIV fields are 0 if TTYP is 0
        if (arbited_data_q.trans_type != rv_iommu::NONE) begin
            fq_data_o.did   = arbited_data_q.did;
            fq_data_o.pid   = (arbited_data_q.pv) ? (arbited_data_q.pid) : ('0);
            fq_data_o.priv  = arbited_data_q.pv & arbited_data_q.is_supervisor;
            fq_data_o.pv    = arbited_data_q.pv;
        end
        
        // From Spec:
        // If the CAUSE is a guest-page fault then bits 63:2 of the GPA are reported in iotval2[63:2].
        if (arbited_data_q.is_guest_pf) begin
            fq_data_o.iotval2       = {23'b0, arbited_data_q.gpaddr};    // zero-extended GPA
            fq_data_o.iotval2[0]    = arbited_data_q.is_implicit;        // Guest page fault was caused by an implicit access
            fq_data_o.iotval2[1]    = 1'b0;                          // Always zero since A/D update of bits is not implemented
        end
    end

endmodule