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
  // Extra: DTI tokens
  //-------------------------------------------------------
  // Number of "granted" invalidation tokens that are allowed
  // to be in-flight (i.e., not yet acked).
  //-------------------------------------------------------
  input  logic [3:0]   granted_inv_tok_i,

  //-------------------------------------------------------
  // (Optional) Demand a sync if scoreboard is not empty?
  // Not used in this example, left as stub if needed.
  //-------------------------------------------------------
  output logic         sync_req_o,

  //-------------------------------------------------------
  // TIMER / FREQUENCY
  //-------------------------------------------------------
  input  logic [31:0]  freq_i,       // clock freq in cycles/second
  output logic         timeout_o,    // signal if a timeout event occurred

  //-------------------------------------------------------
  // OUTPUT Status
  //-------------------------------------------------------
  output logic  full_o,  // scoreboard can't accept more pushes
  output logic  empty_o, // scoreboard is empty
  output logic [$clog2(DEPTH+1)-1:0] usage_o
);

  // -----------------------------------------------
  // 1) Continuously Running 64-bit Timer
  // -----------------------------------------------
  logic [63:0] cycle_count_q, cycle_count_n;

  // -----------------------------------------------
  // 2) Scoreboard Entry Definition
  // -----------------------------------------------
  typedef struct packed {
    logic valid;
    logic acked;
    logic [4:0]    itag;
    logic [31:0]   sid;
    logic          t;         // T bit

    // Insertion order for "ack in order"
    logic [15:0]   insertion_id;

    // Timestamp sampled at push
    logic [63:0]   timestamp;
  } scoreboard_entry_s;

  scoreboard_entry_s [DEPTH-1:0] sb_q, sb_n;

  // -----------------------------------------------
  // 3) Usage, Insertion IDs, Unacked Counter
  // -----------------------------------------------
  logic [$clog2(DEPTH+1)-1:0] usage_q, usage_n;
  logic [15:0] insertion_count_q, insertion_count_n;
  logic [15:0] next_ack_id_q,     next_ack_id_n;

  // Count how many scoreboard entries are valid but not acked
  logic [$clog2(DEPTH+1)-1:0] unacked_q, unacked_n;

  // -----------------------------------------------
  // 4) Free List
  // -----------------------------------------------
  logic [$clog2(DEPTH)-1:0] free_list_q [0:DEPTH-1];
  logic [$clog2(DEPTH)-1:0] free_list_n [0:DEPTH-1];

  logic [$clog2(DEPTH+1)-1:0] free_rd_ptr_q, free_rd_ptr_n;
  logic [$clog2(DEPTH+1)-1:0] free_wr_ptr_q, free_wr_ptr_n;

  // Temporary signals
  logic [$clog2(DEPTH)-1:0] new_entry_idx;
  logic ack_done;
  logic [63:0] diff;

  // For now, we do not request a sync from inside the scoreboard
  // by default. If you need, you can implement logic that sets
  // sync_req_o = !empty_o or other policy.
  assign sync_req_o = 1'b0;

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
    unacked_n          = unacked_q;
    timeout_o          = 1'b0;
    ack_done           = 1'b0;

    new_entry_idx      = free_list_q[free_rd_ptr_q];

    // Timer increments every cycle
    cycle_count_n = cycle_count_q + 1;

    //------------------------------------------------
    //  A) PUSH
    //------------------------------------------------
    // We only accept push if push_i is asserted,
    // usage < DEPTH, AND unacked < granted_inv_tok_i.
    // The top-level might also gate push_i with scoreboard’s full_o,
    // but internally we also ensure we do not overflow unacked tokens.
    if (push_i && (usage_q < DEPTH) && (unacked_q < granted_inv_tok_i)) begin
      sb_n[new_entry_idx].valid         = 1'b1;
      sb_n[new_entry_idx].acked         = 1'b0;
      sb_n[new_entry_idx].itag          = itag_i;
      sb_n[new_entry_idx].sid           = sid_i;
      sb_n[new_entry_idx].t             = t_bit_i;
      sb_n[new_entry_idx].insertion_id  = insertion_count_q;
      sb_n[new_entry_idx].timestamp     = cycle_count_q;

      free_rd_ptr_n           = free_rd_ptr_q + 1;
      usage_n                 = usage_q + 1;
      insertion_count_n       = insertion_count_q + 1;

      // This is a new unacked request
      unacked_n               = unacked_q + 1;
    end

    //------------------------------------------------
    //  B) ACK (In-Order)
    //------------------------------------------------
    if (ack_i) begin
      ack_done = 1'b0;
      for (int i = 0; i < DEPTH; i++) begin
        if (!ack_done) begin
          if ( sb_q[i].valid &&
               !sb_q[i].acked &&
               (sb_q[i].insertion_id == next_ack_id_q))
          begin
            // Mark as acked
            sb_n[i].acked = 1'b1;
            ack_done      = 1'b1;
            // Move the next_ack pointer
            next_ack_id_n = next_ack_id_q + 1;

            // Because it was previously unacked, we decrement unacked_n
            unacked_n = unacked_q - 1;
          end
        end
      end
    end

    //------------------------------------------------
    //  C) COMPLETION (remove out-of-order)
    //     If we find an entry with matching SID/ITAG/T
    //------------------------------------------------
    if (completion_i) begin
      for (int i = 0; i < DEPTH; i++) begin
        if (sb_q[i].valid &&
            (sb_q[i].sid  == comp_sid_i)   &&
            (sb_q[i].itag == comp_itag_i)  &&
            (sb_q[i].t    == comp_t_bit_i) )
        begin
          // If it was unacked, then we reduce unacked count
          if (!sb_q[i].acked) begin
            unacked_n = unacked_n - 1;
          end

          // Free this slot
          sb_n[i].valid = 1'b0;
          free_list_n[free_wr_ptr_q] = i[($clog2(DEPTH)-1):0];
          free_wr_ptr_n             = free_wr_ptr_q + 1;
          usage_n                   = usage_n - 1;

          // "break;" if you only want to remove one per cycle
          // or keep going if multiple might match in the same cycle
          break;
        end
      end
    end

    //------------------------------------------------
    //  D) TIMEOUT CHECK (60 seconds)
    //     If an entry is valid and has been waiting
    //     too long => remove it & signal timeout
    //------------------------------------------------
    for (int i = 0; i < DEPTH; i++) begin
      if (sb_q[i].valid) begin
        diff = cycle_count_q - sb_q[i].timestamp;
        if (diff >= freq_i * 60) begin
          // TIMEOUT => free the slot
          sb_n[i].valid = 1'b0;
          free_list_n[free_wr_ptr_n] = i[($clog2(DEPTH)-1):0];
          free_wr_ptr_n             = free_wr_ptr_n + 1;
          usage_n                   = usage_n - 1;
          timeout_o                 = 1'b1;

          // If it was unacked => decrement unacked_n
          if (!sb_q[i].acked) begin
            unacked_n = unacked_n - 1;
          end
        end
      end
    end

    //------------------------------------------------
    //  E) FLUSH
    //------------------------------------------------
    if (flush_i) begin
      for (int i = 0; i < DEPTH; i++) begin
        sb_n[i].valid  = 1'b0;
        sb_n[i].acked  = 1'b0;
      end
      for (int i = 0; i < DEPTH; i++) begin
        free_list_n[i] = i[($clog2(DEPTH)-1):0];
      end
      usage_n            = '0;
      unacked_n          = '0;
      insertion_count_n  = '0;
      next_ack_id_n      = '0;
      free_rd_ptr_n      = '0;
      free_wr_ptr_n      = DEPTH;
      // Timer keeps running, not reset
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
      unacked_q         <= '0;
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
      unacked_q        <= unacked_n;
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

  // We must block pushes if we've used all memory or
  // if we have reached the max tokens (unacked >= granted).
  assign full_o  = (usage_q == DEPTH) || (unacked_q >= granted_inv_tok_i);

  assign empty_o = (usage_q == 0);

endmodule
