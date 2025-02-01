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
// Date: 30 /01/2025
//
// Authors:
// - Maicol Ciani <maicol.ciani@unibo.it>
//

module ats_dti_scoreboard #(
  parameter int unsigned DEPTH = 32
) (
  input  logic  clk_i,
  input  logic  rst_ni,
  input  logic  flush_i,

  //-------------------------------------------------------
  // PUSH (create a new entry)
  //-------------------------------------------------------
  input  logic         push_i,
  input  logic [4:0]   itag_i,
  input  logic [31:0]  sid_i,
  input  logic         t_bit_i,

  //-------------------------------------------------------
  // ACK (in-order)
  //-------------------------------------------------------
  input  logic         ack_i,

  //-------------------------------------------------------
  // COMPLETION (remove out-of-order by SID + ITAG + T bit)
  //-------------------------------------------------------
  input  logic         completion_i,
  input  logic [4:0]   comp_itag_i,
  input  logic [31:0]  comp_sid_i,
  input  logic         comp_t_bit_i,

  //-------------------------------------------------------
  // ACK (in-order)
  //-------------------------------------------------------
  output logic         sync_req_o, // to be defined

  //-------------------------------------------------------
  // TIMER / FREQUENCY
  //-------------------------------------------------------
  // freq_i = clock frequency in cycles/second (e.g. 100_000_000)
  // Used to compute 60-second timeouts.
  // timeout_o signals the timeout to the external logic
  //-------------------------------------------------------
  input  logic [31:0]  freq_i,
  output logic         timeout_o,
  //-------------------------------------------------------
  // OUTPUT Status
  //-------------------------------------------------------
  output logic  full_o,
  output logic  empty_o,
  output logic [$clog2(DEPTH+1)-1:0] usage_o
);

  // -----------------------------------------------
  // 1) Continuously Running 64-bit Timer
  // -----------------------------------------------
  // It increments every clock cycle, never resets.
  // Overflow after 2^64 cycles (~584 years at 1 GHz).
  logic [63:0] cycle_count_q, cycle_count_n;

  // -----------------------------------------------
  // 2) Scoreboard Entry Definition
  // -----------------------------------------------
  typedef struct packed {
    logic valid;
    logic acked;
    logic [4:0]    itag;
    logic [31:0]   sid;
    logic          t;

    // Insertion order for "ack in order"
    logic [15:0]   insertion_id;

    // Timestamp sampled at push
    logic [63:0]   timestamp;
  } scoreboard_entry_s;

  // The scoreboard array
  scoreboard_entry_s [DEPTH-1:0] sb_q, sb_n;

  // -----------------------------------------------
  // 3) Usage and Insertion IDs
  // -----------------------------------------------
  logic [$clog2(DEPTH+1)-1:0] usage_q, usage_n;
  logic [15:0] insertion_count_q, insertion_count_n;
  logic [15:0] next_ack_id_q,     next_ack_id_n;

  // -----------------------------------------------
  // 4) Free List
  // -----------------------------------------------
  logic [$clog2(DEPTH)-1:0] free_list_q [0:DEPTH-1];
  logic [$clog2(DEPTH)-1:0] free_list_n [0:DEPTH-1];

  logic [$clog2(DEPTH+1)-1:0] free_rd_ptr_q, free_rd_ptr_n;
  logic [$clog2(DEPTH+1)-1:0] free_wr_ptr_q, free_wr_ptr_n;

  logic [$clog2(DEPTH)-1:0] idx;

  logic ack_done;

  // 64-bit unsigned difference
  logic [63:0] diff;

  assign sync_req_o = '0;

  // -----------------------------------------------
  // 5) Combinational Next-State
  // -----------------------------------------------
  always_comb begin
    // Default next-state = current state
    sb_n               = sb_q;
    usage_n            = usage_q;
    insertion_count_n  = insertion_count_q;
    next_ack_id_n      = next_ack_id_q;
    free_list_n        = free_list_q;
    free_rd_ptr_n      = free_rd_ptr_q;
    free_wr_ptr_n      = free_wr_ptr_q;
    idx = free_list_q[free_rd_ptr_q];
    // Timer increments every cycle
    cycle_count_n = cycle_count_q + 1;
    timeout_o          = 1'b0;
    ack_done           = 1'b0;

    // ------------------------------------------
    // PUSH
    // ------------------------------------------
    if (push_i && (usage_q < DEPTH)) begin

      sb_n[idx].valid         = 1'b1;
      sb_n[idx].acked         = 1'b0;
      sb_n[idx].itag          = itag_i;
      sb_n[idx].sid           = sid_i;
      sb_n[idx].t             = t_bit_i;
      sb_n[idx].insertion_id  = insertion_count_q;
      sb_n[idx].timestamp     = cycle_count_q; // sample the current time
      ack_done                = 1'b0;
      free_rd_ptr_n           = free_rd_ptr_q + 1;
      usage_n                 = usage_q + 1;
      insertion_count_n       = insertion_count_q + 1;
    end

    // ------------------------------------------
    // ACK: Mark earliest un-acked entry
    // ------------------------------------------
    if (ack_i) begin
      ack_done = 1'b0;
      for (int i = 0; i < DEPTH; i++) begin
        if (!ack_done) begin
          if ( sb_q[i].valid &&
               !sb_q[i].acked &&
               (sb_q[i].insertion_id == next_ack_id_q))
          begin
            sb_n[i].acked = 1'b1;
            ack_done      = 1'b1;
            next_ack_id_n = next_ack_id_q + 1;
          end
        end
      end
    end

    // ------------------------------------------
    // COMPLETION: Remove by (comp_sid_i, comp_itag_i)
    // ------------------------------------------
    if (completion_i) begin
      for (int i = 0; i < DEPTH; i++) begin
        if (sb_q[i].valid &&
            (sb_q[i].sid  == comp_sid_i  ) &&
            (sb_q[i].t    == comp_t_bit_i) &&
            (sb_q[i].itag == comp_itag_i))
        begin
          // free this slot
          sb_n[i].valid = 1'b0;

          // return index to free-list
          free_list_n[free_wr_ptr_q] = i[($clog2(DEPTH)-1):0];
          free_wr_ptr_n             = free_wr_ptr_q + 1;

          usage_n = usage_q - 1;
          //break; // only handle one match per cycle
        end
      end
    end

    // ------------------------------------------
    // TIMEOUT CHECK (60 sec):
    //   For each valid entry, compute:
    //   diff = (cycle_count_q - sb_q[i].timestamp)
    //   If diff >= (60 * freq_i), remove it.
    // ------------------------------------------
    for (int i = 0; i < DEPTH; i++) begin
      diff = '0;
      if (sb_q[i].valid) begin
        diff = cycle_count_q - sb_q[i].timestamp;
        if (diff >= freq_i * 60) begin //to be defined
          // TIMEOUT => free the slot
          sb_n[i].valid = 1'b0;
          free_list_n[free_wr_ptr_n] = i[($clog2(DEPTH)-1):0];
          free_wr_ptr_n             = free_wr_ptr_n + 1;
          usage_n                   = usage_n - 1;
          timeout_o                 = 1'b1;
        end
      end
    end

    // ------------------------------------------
    // FLUSH
    // ------------------------------------------
    if (flush_i) begin
      for (int i = 0; i < DEPTH; i++) begin
        sb_n[i].valid = 1'b0;
      end
      for (int i = 0; i < DEPTH; i++) begin
        free_list_n[i] = i[($clog2(DEPTH)-1):0];
      end
      usage_n            = '0;
      insertion_count_n  = '0;
      next_ack_id_n      = '0;
      free_rd_ptr_n      = '0;
      free_wr_ptr_n      = DEPTH;

      // We do NOT reset the cycle_count or block it
      // from incrementing.  The timer just keeps going.
    end
  end // always_comb

  // -----------------------------------------------
  // 6) Sequential Logic
  // -----------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      // Reset scoreboard
      for (int i = 0; i < DEPTH; i++) begin
        sb_q[i].valid         <= 1'b0;
        sb_q[i].acked         <= 1'b0;
        sb_q[i].itag          <= '0;
        sb_q[i].sid           <= '0;
        sb_q[i].t             <= '0;
        sb_q[i].insertion_id  <= '0;
        sb_q[i].timestamp     <= '0;
      end

      usage_q           <= '0;
      insertion_count_q <= '0;
      next_ack_id_q     <= '0;

      for (int i = 0; i < DEPTH; i++) begin
        free_list_q[i] <= i[($clog2(DEPTH)-1):0];
      end
      free_rd_ptr_q <= '0;
      free_wr_ptr_q <= DEPTH;

      // Timer reset
      cycle_count_q <= '0;

    end else begin
      sb_q             <= sb_n;
      usage_q          <= usage_n;
      insertion_count_q <= insertion_count_n;
      next_ack_id_q    <= next_ack_id_n;

      free_list_q      <= free_list_n;
      free_rd_ptr_q    <= free_rd_ptr_n;
      free_wr_ptr_q    <= free_wr_ptr_n;

      cycle_count_q <= cycle_count_n;
    end
  end

  // -----------------------------------------------
  // 7) Outputs
  // -----------------------------------------------
  assign usage_o = usage_q;
  assign full_o  = (usage_q == DEPTH);
  assign empty_o = (usage_q == 0);

endmodule
