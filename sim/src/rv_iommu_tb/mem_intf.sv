// Copyright (c) 2025 ETH Zurich, University of Bologna
//
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Date: 13/03/2025
//
// Authors:
// - Maicol Ciani <maicol.ciani@unibo.it>
//
// Description: Definition of a SRAM interface to be used by classes.
//

interface MEM_INTF #(
  parameter int unsigned ADDR_WIDTH = 0,
  parameter int unsigned DATA_WIDTH = 0
);

  logic                    req;
  logic                    wen;
  logic [ADDR_WIDTH-1:0]   addr;
  logic [DATA_WIDTH-1:0]   wdata;
  logic [DATA_WIDTH-1:0]   rdata;
  logic [DATA_WIDTH/8-1:0] be;

  modport Master (
    output req, wen, be, addr, wdata,
    input  rdata
  );

  modport Slave (
    input  req, wen, be, addr, wdata,
    output rdata
  );

endinterface

interface MEM_INTF_DV #(
  parameter int unsigned ADDR_WIDTH = 0,
  parameter int unsigned DATA_WIDTH = 0
) (
   input logic clk,
   input logic rst_ni
  );

  logic                    req;
  logic                    wen;
  logic [ADDR_WIDTH-1:0]   addr;
  logic [DATA_WIDTH-1:0]   wdata;
  logic [DATA_WIDTH-1:0]   rdata;
  logic [DATA_WIDTH/8-1:0] be;

  modport Master (
    output req, wen, be, addr, wdata,
    input  rdata
  );

  modport Slave (
    input  req, wen, be, addr, wdata,
    output rdata
  );

endinterface
