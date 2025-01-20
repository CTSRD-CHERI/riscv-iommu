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
// Description: Handler for MSI translations in MRIF mode.
//              Modifies the destination MRIF using read-modify-write operations.
//              Sends a notice MSI using the data provided by the MSI PTE if the IE bit 
//                  corresponding to the interrupt identity being processed is set.
//

module rv_iommu_mrif_handler #(
    /// RISC-V IOMMU configuration struct
    parameter rv_iommu_cfg::rv_iommu_cfg_t RVIOMMUCfg = rv_iommu_cfg::NullCfg,

    /// Address data type
    parameter type addr_t = logic,
    /// Physical address data type
    parameter type paddr_t = logic,

    /// MRIF Handler request data type
    parameter type mrif_req_data_t = logic,
    /// AXI write channel bus type
    parameter type w_chan_t = logic,
    /// W counter type
    parameter type w_cnt_t = logic,
    /// Fault data type
    parameter type fault_data_t = logic,

    /// AXI data types
    parameter type axi_req_t        = logic,
    parameter type axi_resp_t       = logic
) (
    input  logic    clk_i,
    input  logic    rst_ni,

    // Request port
    input  mrif_req_data_t  req_data_i,
    input  logic            req_valid_i,
    output logic            req_ready_o,

    // Write data bus
    input  w_chan_t         w_data_i,
    input  logic            w_valid_i,
    input  logic            w_ready_i,

    // Fault reporting port
    output logic            fault_valid_o,
    input  logic            fault_ready_i,
    output fault_data_t     fault_data_o,

    // Memory interface
    output axi_req_t        mem_req_o,
    input  axi_resp_t       mem_resp_i
);

    localparam int unsigned PLEN = RVIOMMUCfg.PAddrWidth;
    localparam int unsigned PPNW = PLEN-12;

    // States
    typedef enum logic [2:0] {
        IDLE            = 3'b000,
        WAIT_INT_ID     = 3'b001,
        MEM_ACCESS      = 3'b010,
        FETCH_MRIF      = 3'b011,
        WRITE_MRIF      = 3'b100,
        WRITE_NOTICE    = 3'b101,
        ERROR           = 3'b110
    } mrif_handler_state_t;
    mrif_handler_state_t state_q, state_n;

    assign req_ready_o = (state_q == IDLE);

    // Write FSM states
    typedef enum logic [1:0] {
        AW_REQ  = 2'b00,
        W_DATA  = 2'b01,
        B_RESP  = 2'b10
    } mrif_write_state_t;
    mrif_write_state_t wr_state_q, wr_state_n;

    // Physical pointer to access memory
    paddr_t pptr_q, pptr_n;

    // Request data
    mrif_req_data_t req_data_q, req_data_n;
    // Interrupt ID register
    logic [10:0] int_id_q, int_id_n;
    // MRIF IP register
    logic [63:0] mrif_ip_q, mrif_ip_n;
    // MRIF IE register
    logic [63:0] mrif_ie_q, mrif_ie_n;

    // Interrupt identity bit
    logic [63:0] int_id_bit;
    assign       int_id_bit   = (64'd1 << int_id_q[5:0]);

    // Fault data
    assign fault_data_o.trans_type       = req_data_q.req_data.ttype;
    assign fault_data_o.cause_code       = rv_iommu::MSI_PT_DATA_CORRUPTION;;
    assign fault_data_o.iova             = req_data_q.req_data.iova;
    assign fault_data_o.gpaddr           = '0;
    assign fault_data_o.did              = req_data_q.req_data.did;
    assign fault_data_o.pv               = req_data_q.req_data.pid_valid;
    assign fault_data_o.pid              = req_data_q.req_data.pid;
    assign fault_data_o.is_supervisor    = req_data_q.req_data.priv;
    assign fault_data_o.is_guest_pf      = 1'b0;
    assign fault_data_o.is_implicit      = 1'b0;

    //--------------------------------------
    // MRIF Handler FSM combinational logic
    //--------------------------------------
    always_comb begin : mrif_handler_comb

        // Default assignments
        // AXI signals
        // AW
        mem_req_o.aw        = '0;
        mem_req_o.aw.id     = 'd2;  // do not change unless you know what you are doing
        mem_req_o.aw.addr   = addr_t'(pptr_q);
        mem_req_o.aw.len    = 8'b0;
        mem_req_o.aw.size   = 3'b011;
        mem_req_o.aw.burst  = axi_pkg::BURST_INCR;

        mem_req_o.aw_valid   = 1'b0;

        // W
        mem_req_o.w.data    = '0;
        mem_req_o.w.strb    = '1;
        mem_req_o.w.last    = '0;
        mem_req_o.w.user    = '0;

        mem_req_o.w_valid   = 1'b0;

        // B
        mem_req_o.b_ready   = 1'b0;

        // AR
        mem_req_o.ar        = '0;
        mem_req_o.ar.id     = 'd5;  // do not change unless you know what you are doing
        mem_req_o.ar.addr   = addr_t'(pptr_q);
        mem_req_o.ar.len    = 8'b1;
        mem_req_o.ar.size   = 3'b011;
        mem_req_o.ar.burst  = axi_pkg::BURST_INCR;

        mem_req_o.ar_valid  = 1'b0;

        // R
        mem_req_o.r_ready   = 1'b0;

        fault_valid_o       = 1'b0;

        // Next values
        state_n         = state_q;
        wr_state_n      = wr_state_q;
        pptr_n          = pptr_q;
        req_data_n      = req_data_q;
        int_id_n        = int_id_q;
        mrif_ip_n       = mrif_ip_q;
        mrif_ie_n       = mrif_ie_q;

        unique case (state_q)

            // Monitor init signal
            IDLE: begin

                if (req_valid_i) begin
                    req_data_n      = req_data_i;
                    state_n         = WAIT_INT_ID;
                end
            end

            // Validate the interrupt identity and calculate the offset of the IP and IE DWs within the MRIF
            WAIT_INT_ID: begin

                // W handshake
                if (w_valid_i && w_ready_i && w_data_i.last) begin
                    // MRIF wdata
                    if (req_data_q.mrif_w_cnt == w_cnt_t'(0)) begin
                        // Valid interrupt identity
                        if ((|w_data_i.data[31:11]) == 1'b0) begin
                            pptr_n      = {req_data_q.mrif_data.addr[PLEN-9-1:0], w_data_i.data[10:6], 4'b0};
                            int_id_n    = w_data_i.data[10:0];
                            state_n     = MEM_ACCESS;
                        end
                        else begin
                            // else ignore transaction
                            state_n = IDLE;
                        end
                    end
                    else begin
                        req_data_n.mrif_w_cnt = req_data_q.mrif_w_cnt - w_cnt_t'(1);
                    end
                end
            end

            // Access memory to fetch IP and IE DWs
            MEM_ACCESS: begin
                mem_req_o.ar_valid = 1'b1;
                if (mem_resp_i.ar_ready) begin
                    state_n = FETCH_MRIF;
                end
            end

            // Save IP and IE DWs. Set the corresponding IP bit
            FETCH_MRIF: begin
                
                if (mem_resp_i.r_valid) begin

                    mem_req_o.r_ready   = 1'b1;
                    
                    // Second DW: IE
                    if (mem_resp_i.r.last) begin

                        mrif_ie_n = mem_resp_i.r.data[((64*1) & (RVIOMMUCfg.AxiDataWidth-1))+:64];

                        // If the IP bit corresponding to the interrupt ID is already set, there is no need to write back the IP DW to the MRIF
                        if (|(mrif_ip_q & int_id_bit)) begin
                            
                            // If the IE bit corresponding to the interrupt ID is not set, there is no need to send the MSI notice
                            if (|(mem_resp_i.r.data & int_id_bit)) begin
                                state_n     = WRITE_NOTICE;
                                wr_state_n  = AW_REQ;
                            end
                            else begin
                                state_n = IDLE;
                            end
                        end
                        else begin
                            state_n     = WRITE_MRIF;
                            wr_state_n  = AW_REQ;
                        end
                    end

                    // First DW: IP
                    else begin
                        mrif_ip_n = mem_resp_i.r.data[((64*0) & (RVIOMMUCfg.AxiDataWidth-1))+:64];
                    end

                    // Check for AXI errors
                    if (mem_resp_i.r.resp != axi_pkg::RESP_OKAY) begin
                        state_n         = ERROR;
                    end
                end
            end

            // Write back the IP DW to the MRIF.
            WRITE_MRIF: begin

                unique case (wr_state_q)
                    AW_REQ: begin
                        mem_req_o.aw_valid  = 1'b1;
                        if (mem_resp_i.aw_ready) begin
                            wr_state_n  = W_DATA;
                        end
                    end
                    W_DATA: begin

                        mem_req_o.w_valid   = 1'b1;
                        mem_req_o.w.last    = 1'b1;
                        mem_req_o.w.data    = mrif_ip_q | int_id_bit;
                        if(mem_resp_i.w_ready) begin
                            wr_state_n  = B_RESP;
                        end
                    end
                    B_RESP: begin

                        if (mem_resp_i.b_valid) begin
                            mem_req_o.b_ready   = 1'b1;
                            wr_state_n  = AW_REQ;

                            // Check IE bit to determine whether to send notice MSI
                            state_n = (|(mrif_ie_q & int_id_bit)) ? (WRITE_NOTICE) : (IDLE);

                            if (mem_resp_i.b.resp != axi_pkg::RESP_OKAY) begin
                                state_n = ERROR;
                            end
                        end
                    end

                    default: state_n = IDLE;
                endcase
            end

            // Send MSI notice using input NID and NPPN
            WRITE_NOTICE: begin
                
                unique case (wr_state_q)
                    AW_REQ: begin

                        mem_req_o.aw_valid  = 1'b1;
                        mem_req_o.aw.addr   = addr_t'({req_data_q.mrif_data.nppn[PPNW-1:0], 12'b0});
                        mem_req_o.aw.size   = 3'b010;
                        if (mem_resp_i.aw_ready) begin
                            wr_state_n  = W_DATA;
                        end
                    end
                    W_DATA: begin
                        
                        mem_req_o.w_valid       = 1'b1;
                        mem_req_o.w.strb        = 8'b0000_1111;
                        mem_req_o.w.last        = 1'b1;
                        mem_req_o.w.data[31:0]  = {21'b0, req_data_q.mrif_data.nid};
                        if(mem_resp_i.w_ready) begin
                            wr_state_n  = B_RESP;
                        end
                    end
                    B_RESP: begin

                        if (mem_resp_i.b_valid) begin
                            mem_req_o.b_ready   = 1'b1;
                            state_n             = IDLE;

                            // AXI error
                            if (mem_resp_i.b.resp != axi_pkg::RESP_OKAY) begin
                                state_n         = ERROR;
                            end
                        end
                    end

                    default: state_n = IDLE;
                endcase
            end

            ERROR: begin

                mem_req_o.r_ready   = 1'b1;
                fault_valid_o       = 1'b1;

                if (fault_ready_i) begin
                    state_n = IDLE;
                end
            end

            default: begin
                state_n = IDLE;
            end
        endcase
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin : mrif_handler_seq

        if (!rst_ni) begin
            state_q         <= IDLE;
            wr_state_q      <= AW_REQ;

            pptr_q          <= '0;
            req_data_q      <= '0;
            int_id_q        <= '0;
            mrif_ip_q       <= '0;
            mrif_ie_q       <= '0;
        end 
        
        else begin
            state_q         <= state_n;
            wr_state_q      <= wr_state_n;

            pptr_q          <= pptr_n;
            req_data_q      <= req_data_n;
            int_id_q        <= int_id_n;
            mrif_ip_q       <= mrif_ip_n;
            mrif_ie_q       <= mrif_ie_n;
        end
    end
    
endmodule