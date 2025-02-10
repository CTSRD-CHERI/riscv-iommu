module ats_dti_trans_scoreboard #(
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
  // freq_i = clock frequency in cycles/second
  // if ANY entry is older than 60s, remove it + raise 'timeout_o'
  //-------------------------------------------------------
  input  logic [31:0]  freq_i,
  output logic         timeout_o,

  //-------------------------------------------------------
  // OUTPUT Status
  //-------------------------------------------------------
  output logic         full_o,   // scoreboard can't accept more pushes
  output logic         empty_o,  // scoreboard is empty
  output logic [$clog2(DEPTH+1)-1:0] usage_o
);

  // ------------------------------------------------------
  // 1) 64-bit Free-Running Timer
  // ------------------------------------------------------
  logic [63:0] cycle_count_q, cycle_count_n;

  // ------------------------------------------------------
  // 2) Scoreboard Entry
  // ------------------------------------------------------
  typedef struct packed {
    logic valid;
    logic acked;
    logic [4:0]   itag;
    logic [31:0]  sid;
    logic         t;       // T bit

    // For in-order ACK
    logic [15:0]  insertion_id;

    // Timestamp at push
    logic [63:0]  timestamp;
  } scoreboard_entry_s;

  // The scoreboard storage
  scoreboard_entry_s [DEPTH-1:0] sb_q, sb_n;

  // ------------------------------------------------------
  // 3) Usage, Insertion IDs, Unacked
  // ------------------------------------------------------
  logic [$clog2(DEPTH+1)-1:0] usage_q, usage_n;
  logic [$clog2(DEPTH+1)-1:0] unacked_q, unacked_n;

  logic [15:0] insertion_count_q, insertion_count_n;
  logic [15:0] next_ack_id_q,     next_ack_id_n;

  // ------------------------------------------------------
  // 4) Free List (Ring)
  // ------------------------------------------------------
  logic [$clog2(DEPTH)-1:0] free_list_q [0:DEPTH-1];
  logic [$clog2(DEPTH)-1:0] free_list_n [0:DEPTH-1];

  logic [$clog2(DEPTH):0] free_rd_ptr_q, free_rd_ptr_n;
  logic [$clog2(DEPTH):0] free_wr_ptr_q, free_wr_ptr_n;

  // ------------------------------------------------------
  // 5) Local signals
  // ------------------------------------------------------
  // We do not define them inside always blocks
  logic [$clog2(DEPTH)-1:0] new_entry_idx;
  logic [$clog2(DEPTH):0]   local_free_wr_ptr;
  logic [63:0]              diff;

  // Accumulators for usage/unacked net changes
  integer push_count;
  integer ack_count;
  integer comp_count;
  integer comp_unacked_count;
  integer timeout_count;
  integer timeout_unacked_count;

  // A bit vector to indicate which entries are timing out
  logic [DEPTH-1:0] timeouts_vec;

  // By default, scoreboard doesn't request sync
  assign sync_req_o = 1'b0;

  // ------------------------------------------------------
  // 6) Next-State Combinational Logic
  // ------------------------------------------------------
  always_comb begin : scoreboard_comb

    // Default next-state
    sb_n             = sb_q;
    usage_n          = usage_q;
    unacked_n        = unacked_q;
    insertion_count_n= insertion_count_q;
    next_ack_id_n    = next_ack_id_q;

    free_list_n      = free_list_q;
    free_rd_ptr_n    = free_rd_ptr_q;
    free_wr_ptr_n    = free_wr_ptr_q;

    // Timer increments each cycle
    cycle_count_n = cycle_count_q + 1;

    // Initialize local increments
    push_count          = 0;
    ack_count           = 0;
    comp_count          = 0;
    comp_unacked_count  = 0;
    timeout_count       = 0;
    timeout_unacked_count = 0;

    // Initialize all timeouts to 0
    // We do not define timeouts_vec here, but we can assign it:
    for (int i = 0; i < DEPTH; i++) begin
      timeouts_vec[i] = 1'b0;
    end

    // ----------------------------------------
    // A) PUSH
    // ----------------------------------------
    if (push_i && usage_q < DEPTH && unacked_q < granted_inv_tok_i) begin
      new_entry_idx = free_list_q[free_rd_ptr_q[$clog2(DEPTH)-1:0]];

      sb_n[new_entry_idx].valid         = 1'b1;
      sb_n[new_entry_idx].acked         = 1'b0;
      sb_n[new_entry_idx].itag          = itag_i;
      sb_n[new_entry_idx].sid           = sid_i;
      sb_n[new_entry_idx].t             = t_bit_i;
      sb_n[new_entry_idx].insertion_id  = insertion_count_q;
      sb_n[new_entry_idx].timestamp     = cycle_count_q;

      // Ring pointer increment
      free_rd_ptr_n = (free_rd_ptr_q == (DEPTH-1)) ? '0 : (free_rd_ptr_q + 1);

      insertion_count_n = insertion_count_q + 1;
      push_count        = 1;
    end

    // ----------------------------------------
    // B) ACK (in-order)
    // ----------------------------------------
    if (ack_i) begin
      for (int i = 0; i < DEPTH; i++) begin
        if (sb_q[i].valid && !sb_q[i].acked &&
            (sb_q[i].insertion_id == next_ack_id_q)) 
        begin
          sb_n[i].acked = 1'b1;
          next_ack_id_n = next_ack_id_q + 1;
          ack_count     = 1;
          break;
        end
      end
    end

    // ----------------------------------------
    // C) COMPLETION (out-of-order)
    // ----------------------------------------
    if (completion_i) begin
      for (int i = 0; i < DEPTH; i++) begin
        if (sb_q[i].valid &&
            (sb_q[i].sid  == comp_sid_i) &&
            (sb_q[i].itag == comp_itag_i) &&
            (sb_q[i].t    == comp_t_bit_i))
        begin
          sb_n[i].valid = 1'b0;

          free_list_n[free_wr_ptr_q[$clog2(DEPTH)-1:0]] = i[$clog2(DEPTH)-1:0];
          free_wr_ptr_n = (free_wr_ptr_q == (DEPTH-1)) ? '0 : (free_wr_ptr_q + 1);

          comp_count += 1;
          if (!sb_q[i].acked) 
            comp_unacked_count += 1;

          break;
        end
      end
    end

    // ----------------------------------------
    // D) TIMEOUT CHECK
    // ----------------------------------------
    // Remove any entry older than 60 seconds
    // We'll do a ring increment for each removed entry.
    local_free_wr_ptr = free_wr_ptr_q;

    for (int i = 0; i < DEPTH; i++) begin
      if (sb_q[i].valid) begin
        diff = cycle_count_q - sb_q[i].timestamp;
        if (diff >= freq_i * 60) begin
          // This entry times out => forcibly remove it
          sb_n[i].valid = 1'b0;

          // Return to free list
          free_list_n[local_free_wr_ptr[$clog2(DEPTH)-1:0]] = i[$clog2(DEPTH)-1:0];
          local_free_wr_ptr = (local_free_wr_ptr == (DEPTH-1)) ? '0 : (local_free_wr_ptr + 1);

          // Mark that we removed it for timeout
          timeouts_vec[i] = 1'b1;
          timeout_count += 1;
          if (!sb_q[i].acked)
            timeout_unacked_count += 1;
        end
      end
    end

    // Update the real free_wr_ptr_n from local_free_wr_ptr
    free_wr_ptr_n = local_free_wr_ptr;

    // We'll OR-reduce timeouts_vec for the final timeout_o output 
    // but we must do that *after* the loop:
    // (We'll do it outside this loop in a moment.)

    // ----------------------------------------
    // E) FLUSH
    // ----------------------------------------
    if (flush_i) begin
      for (int i = 0; i < DEPTH; i++) begin
        sb_n[i].valid = 1'b0;
        sb_n[i].acked = 1'b0;
      end
      for (int i = 0; i < DEPTH; i++) begin
        free_list_n[i] = i[$clog2(DEPTH)-1:0];
      end

      usage_n           = '0;
      unacked_n         = '0;
      insertion_count_n = '0;
      next_ack_id_n     = '0;
      free_rd_ptr_n     = '0;
      free_wr_ptr_n     = DEPTH; 
    end
    else begin
      // Net usage/unacked after all events
      usage_n = usage_q + push_count - comp_count - timeout_count;
      unacked_n 
        = unacked_q
        + push_count
        - ack_count
        - comp_unacked_count
        - timeout_unacked_count;
    end

    // Finally, we set 'timeout_o' if ANY entry timed out this cycle
    timeout_o = |timeouts_vec; // OR-reduce
  end // always_comb

  // ------------------------------------------------------
  // 7) Sequential Logic
  // ------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      // Reset scoreboard
      for (int i = 0; i < DEPTH; i++) begin
        sb_q[i].valid         <= 1'b0;
        sb_q[i].acked         <= 1'b0;
        sb_q[i].itag          <= '0;
        sb_q[i].sid           <= '0;
        sb_q[i].t             <= 1'b0;
        sb_q[i].insertion_id  <= '0;
        sb_q[i].timestamp     <= '0;
      end

      usage_q           <= '0;
      unacked_q         <= '0;
      insertion_count_q <= '0;
      next_ack_id_q     <= '0;

      for (int i = 0; i < DEPTH; i++) begin
        free_list_q[i] <= i[$clog2(DEPTH)-1:0];
      end

      free_rd_ptr_q <= '0;
      free_wr_ptr_q <= DEPTH;
      cycle_count_q <= '0;
    end 
    else begin
      sb_q             <= sb_n;
      usage_q          <= usage_n;
      unacked_q        <= unacked_n;
      insertion_count_q<= insertion_count_n;
      next_ack_id_q    <= next_ack_id_n;

      free_list_q      <= free_list_n;
      free_rd_ptr_q    <= free_rd_ptr_n;
      free_wr_ptr_q    <= free_wr_ptr_n;

      cycle_count_q    <= cycle_count_n;
    end
  end

  // ------------------------------------------------------
  // 8) Outputs
  // ------------------------------------------------------
  assign usage_o = usage_q;

  // "Full" if physically at capacity or out of tokens
  assign full_o  = (usage_q == DEPTH) || (unacked_q >= granted_inv_tok_i);

  // "Empty" if usage == 0
  assign empty_o = (usage_q == 0);

endmodule
