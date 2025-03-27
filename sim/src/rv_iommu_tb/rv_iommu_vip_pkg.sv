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
// Description: Definition of class with tasks driving IOMMU's AXI Stream Ports
//

package rv_iommu_vip_pkg;

   import rv_iommu::*;
   import rv_iommu_tb_defs::*;

   // -----------------------------------------------------------------------------
   // 2) rv_iommu_vip_agent: class-based approach for the IOMMU side
   //    Provides tasks for single-beat read/write, s1pt/s2pt init, etc.
   // -----------------------------------------------------------------------------
   class rv_iommu_vip_agent #(
     parameter int unsigned DATA_WIDTH = 64,
     parameter int unsigned ADDR_WIDTH = 64,
     parameter int unsigned ID_WIDTH   = 4,
     parameter int unsigned USER_WIDTH = 1,
     parameter int unsigned DevW = 0 ,
     parameter int unsigned ProW = 0 ,
     parameter time         TestTime  = 0ns,
     parameter time         ApplTime  = 0ns
   );

     virtual MEM_INTF_DV #(
       .ADDR_WIDTH(ADDR_WIDTH),
       .DATA_WIDTH(DATA_WIDTH)
     ) sram_intf;

     typedef axi_test::axi_driver #(
       .AW( DATA_WIDTH ),
       .DW( ADDR_WIDTH ),
       .IW( ID_WIDTH   ),
       .UW( USER_WIDTH ),
       .TA( ApplTime ),
       .TT( TestTime )
     ) axi_driver_t;

     typedef rv_iommu_axi_test::rv_iommu_axi_driver #(
       .AW  ( DATA_WIDTH ),
       .DW  ( ADDR_WIDTH ),
       .IW  ( ID_WIDTH   ),
       .UW  ( USER_WIDTH ),
       .DevW( DevW       ),
       .ProW( ProW       ),
       .TA  ( ApplTime   ),
       .TT  ( TestTime   )
     ) rv_iommu_axi_driver_t;

     axi_driver_t axi_prog_drv;

     rv_iommu_axi_driver_t axi_tr_drv;

     // Constructor
     function new(
        virtual MEM_INTF_DV #(
          .ADDR_WIDTH(ADDR_WIDTH),
          .DATA_WIDTH(DATA_WIDTH)
        ) sram_intf,
        rv_iommu_axi_test::rv_iommu_axi_driver #(
          .AW  ( DATA_WIDTH ),
          .DW  ( ADDR_WIDTH ),
          .IW  ( ID_WIDTH   ),
          .UW  ( USER_WIDTH ),
          .DevW( DevW       ),
          .ProW( ProW       ),
          .TA  ( ApplTime   ),
          .TT  ( TestTime   )
        ) axi_tr_drv,
        axi_test::axi_driver #(
          .AW( DATA_WIDTH ),
          .DW( ADDR_WIDTH ),
          .IW( ID_WIDTH   ),
          .UW( USER_WIDTH ),
          .TA( ApplTime ),
          .TT( TestTime )
        ) axi_prog_drv
     );
       this.axi_tr_drv   = axi_tr_drv;
       this.axi_prog_drv = axi_prog_drv;
       this.sram_intf    = sram_intf;
     endfunction

     //----------------------------------------------------------------
     // A “reset” method for the IOMMU VIP drivers
     //----------------------------------------------------------------
     function void reset_drvs();
       axi_tr_drv.reset_master();
       axi_prog_drv.reset_master();
     endfunction

     //----------------------------------------------------------------
     // Single-beat write (64-bit) to "translation" interface
     //----------------------------------------------------------------
     task automatic axi_single_write_tr(
       logic [63:0] addr,
       logic [63:0] data,
       logic        transalted,
       logic        atst
     );
       // The code from your snippet:
       rv_iommu_axi_driver_t::ax_beat_t aw_beat = new();
       rv_iommu_axi_driver_t::w_beat_t  w_beat  = new();
       rv_iommu_axi_driver_t::b_beat_t  b_beat  = new();

       aw_beat.ax_id    = 0;
       aw_beat.ax_addr  = addr;
       aw_beat.ax_len   = 0;
       aw_beat.ax_size  = $clog2(64/8); // 8 bytes
       aw_beat.ax_burst = axi_pkg::BURST_INCR;
       aw_beat.ax_lock  = 0;
       aw_beat.ax_cache = 4'b0011;
       aw_beat.ax_prot  = 3'b000;
       aw_beat.ax_qos   = '0;
       aw_beat.ax_region= '0;
       aw_beat.ax_atop  = '0;
       aw_beat.ax_user  = '0;
       // AXI untransalted transaction extension
       aw_beat.ax_stream_id    = 24'b1;
       aw_beat.ax_substream_id = 20'b0;
       aw_beat.ax_ss_id_valid  = 1'b0;
       aw_beat.ax_mmu_flow     = 2'b0;
       aw_beat.ax_mmu_secsid   = 1'b0;
       aw_beat.ax_mmu_atst     = atst;
       aw_beat.ax_mmu_valid    = !transalted;

       w_beat.w_data  = addr[3:0] == 4'h4 ? {data[31:0], 32'h0} : data;
       w_beat.w_strb  = addr[3:0] == 4'h4 ? 8'b11110000 : 8'b11111111;
       w_beat.w_last    = 1'b1;
       w_beat.w_user    = '0;

       // Send AW/W via the programming interface driver
       axi_tr_drv.send_aw(aw_beat);
       axi_tr_drv.send_w(w_beat);
       axi_tr_drv.recv_b(b_beat);
     endtask

     //----------------------------------------------------------------
     // Single-beat read (64-bit) from "translation" interface
     //----------------------------------------------------------------
     task automatic axi_single_read_tr(
       logic        transalted,
       logic        atst,
       logic        [63:0] addr,
       output logic [63:0] data_out
     );
       rv_iommu_axi_driver_t::ax_beat_t ar_beat = new();
       rv_iommu_axi_driver_t::r_beat_t  r_beat;

       ar_beat.ax_id     = 0;
       ar_beat.ax_addr   = addr;
       ar_beat.ax_len    = 0;
       ar_beat.ax_size   = $clog2(64/8);
       ar_beat.ax_burst  = axi_pkg::BURST_INCR;
       ar_beat.ax_lock   = 1'b0;
       ar_beat.ax_cache  = 4'b0011;
       ar_beat.ax_prot   = 3'b000;
       ar_beat.ax_qos    = '0;
       ar_beat.ax_region = '0;
       ar_beat.ax_atop   = '0;
       ar_beat.ax_user   = '0;
       // AXI untransalted transaction extension
       ar_beat.ax_stream_id    = 24'b1;
       ar_beat.ax_substream_id = 20'b0;
       ar_beat.ax_ss_id_valid  = 1'b0;
       ar_beat.ax_mmu_flow     = 2'b0;
       ar_beat.ax_mmu_secsid   = 1'b0;
       ar_beat.ax_mmu_atst     = atst;
       ar_beat.ax_mmu_valid    = !transalted;

       axi_tr_drv.send_ar(ar_beat);
       axi_tr_drv.recv_r(r_beat);
       data_out = r_beat.r_data;
     endtask

     //----------------------------------------------------------------
     // Single-beat write (64-bit) to "prog" interface
     //----------------------------------------------------------------
     task automatic axi_single_write_prog(
       logic [63:0] addr,
       logic [63:0] data
     );
       // The code from your snippet:
       axi_driver_t::ax_beat_t aw_beat = new();
       axi_driver_t::w_beat_t  w_beat  = new();
       axi_driver_t::b_beat_t  b_beat  = new();

       aw_beat.ax_id    = 0;
       aw_beat.ax_addr  = addr;
       aw_beat.ax_len   = 0;
       aw_beat.ax_size  = $clog2(64/8); // 4 bytes
       aw_beat.ax_burst = axi_pkg::BURST_INCR;
       aw_beat.ax_lock  = 0;
       aw_beat.ax_cache = 4'b0011;
       aw_beat.ax_prot  = 3'b000;
       aw_beat.ax_qos   = '0;
       aw_beat.ax_region= '0;
       aw_beat.ax_atop  = '0;
       aw_beat.ax_user  = '0;

       w_beat.w_data  = addr[3:0] == 4'h4 ? {data[31:0], 32'h0} : data;
       w_beat.w_strb  = addr[3:0] == 4'h4 ? 8'b11110000 : 8'b00001111;
       w_beat.w_last    = 1'b1;
       w_beat.w_user    = '0;

       // Send AW/W via the programming interface driver
       axi_prog_drv.send_aw(aw_beat);
       axi_prog_drv.send_w(w_beat);
       axi_prog_drv.recv_b(b_beat);
     endtask

     //----------------------------------------------------------------
     // Single-beat read (64-bit) from "prog" interface
     //----------------------------------------------------------------
     task automatic axi_single_read_prog(
       logic [63:0]      addr,
       output logic [63:0] data_out
     );
       axi_driver_t::ax_beat_t ar_beat = new();
       axi_driver_t::r_beat_t  r_beat;

       ar_beat.ax_id     = 0;
       ar_beat.ax_addr   = addr;
       ar_beat.ax_len    = 0;
       ar_beat.ax_size   = $clog2(64/8);
       ar_beat.ax_burst  = axi_pkg::BURST_INCR;
       ar_beat.ax_lock   = 1'b0;
       ar_beat.ax_cache  = 4'b0011;
       ar_beat.ax_prot   = 3'b000;
       ar_beat.ax_qos    = '0;
       ar_beat.ax_region = '0;
       ar_beat.ax_atop   = '0;
       ar_beat.ax_user   = '0;

       axi_prog_drv.send_ar(ar_beat);
       axi_prog_drv.recv_r(r_beat);
       data_out = r_beat.r_data;
     endtask

     // --------------------------------------------------------------------------
     // "Test page permission table" from your C code, as functions
     // --------------------------------------------------------------------------
     // For brevity, we replicate your lines as a “case” approach:
     function logic [63:0] get_stage1_perm(int idx);
       case (idx)
         IOMMU_OFF_R, IOMMU_OFF_W,
         IOMMU_BARE_R, IOMMU_BARE_W,
         BARE_TRANS_R1, BARE_TRANS_R2, BARE_TRANS_W1, BARE_TRANS_W2,
         SWITCH1, SWITCH2,
         HPM_R, HPM_W:
           return (PTE_V | PTE_U | PTE_RWX);

         // S2_ONLY_R => stage1=0
         S2_ONLY_R:
           return 64'h0;

         // S2_ONLY_W => stage1=0
         S2_ONLY_W:
           return 64'h0;

         // TWO_STAGE_R4K => PTE_V|PTE_U|PTE_R
         TWO_STAGE_R4K, TWO_STAGE_R2M, TWO_STAGE_R1G, MSI_R2,
         IOTINVAL_R1, IOTINVAL_R2, MSI_R3, MSI_R4, MSI_R5:
           return (PTE_V | PTE_U | PTE_R);

         // TWO_STAGE_W4K => PTE_V|PTE_U|PTE_RW
         TWO_STAGE_W4K:
           return (PTE_V | PTE_U | PTE_RW);

         // WSI_R => PTE_V|PTE_U|PTE_X
         WSI_R, MSI_GEN_R:
           return (PTE_V | PTE_U | PTE_X);

         // WSI_W => PTE_V|PTE_U|PTE_RW
         WSI_W, MSI_GEN_W:
           return (PTE_V | PTE_U | PTE_RW);

         default:
           // By default, map everything else as R/W/X to not crash
           return (PTE_V | PTE_U | PTE_RWX);
       endcase
     endfunction

     function logic [63:0] get_stage2_perm(int idx);
       case (idx)
         IOMMU_OFF_R, IOMMU_OFF_W,
         IOMMU_BARE_R, IOMMU_BARE_W,
         BARE_TRANS_R1, BARE_TRANS_R2, BARE_TRANS_W1, BARE_TRANS_W2,
         SWITCH1, SWITCH2,
         HPM_R, HPM_W:
           return (PTE_V | PTE_U | PTE_RWX);

         // S2_ONLY_R => PTE_V|PTE_U|PTE_R
         S2_ONLY_R:
           return (PTE_V | PTE_U | PTE_R);

         // S2_ONLY_W => PTE_V|PTE_U|PTE_RW
         S2_ONLY_W:
           return (PTE_V | PTE_U | PTE_RW);

         // TWO_STAGE_R4K => PTE_V|PTE_U|PTE_R
         TWO_STAGE_R4K, TWO_STAGE_R2M, TWO_STAGE_R1G, MSI_R2,
         IOTINVAL_R1, IOTINVAL_R2, MSI_R3, MSI_R4, MSI_R5:
           return (PTE_V | PTE_U | PTE_R);

         // TWO_STAGE_W4K => PTE_V|PTE_U|PTE_RW
         TWO_STAGE_W4K:
           return (PTE_V | PTE_U | PTE_RW);

         // WSI_R => PTE_V|PTE_U|PTE_R
         WSI_R, MSI_GEN_R:
           return (PTE_V | PTE_U | PTE_R);

         // WSI_W => PTE_V|PTE_U|PTE_RX
         WSI_W, MSI_GEN_W:
           return (PTE_V | PTE_U | PTE_RX);

         default:
           // Fallback
           return (PTE_V | PTE_U | PTE_RWX);
       endcase
     endfunction

     // (Below you place the tasks that were in the module, e.g. s1pt_init_hw,
     //  s2pt_init_hw, iommu_ddt_init_hw, etc.
     //  For brevity, we show stubs. You can copy your full code in.)

     // --------------------------------------------------------------------------
     // Address helper functions (where to store s1pt[x][y], s2pt[x][y], etc.)
     // Each PTE is 8 bytes
     // --------------------------------------------------------------------------
     function logic [31:0] s1pt_addr(input int i, input int j);
       // i in [0..5], j in [0..511]
       s1pt_addr = {S1PT_BASE,12'b0} + ((i*512 + j) * 8);
     endfunction

     function logic [31:0] s2pt_addr(input int i, input int j);
       // i in [0..4], j in [0..511]
       s2pt_addr = {S2PT_BASE,12'b0} + ((i*512 + j) * 8);
     endfunction

     function logic [31:0] s2pt_root_addr(input int idx);
       // idx in [0..2047]
       s2pt_root_addr = {S2PT_ROOT_BASE,12'b0} + (idx * 8);
     endfunction

     // --------------------------------------------------------------------------
     // Low-level “write one 64-bit word to SRAM” task
     // You may need to adapt cycles or handshake depending on your memory model
     // --------------------------------------------------------------------------
     task  mem_write(
       input logic [31:0]  addr,
       input logic [63:0]  data
     );

       @(posedge axi_tr_drv.axi.clk_i);
       sram_intf.req   <= 1'b1;
       sram_intf.wen   <= 1'b1;
       sram_intf.addr  <= addr;
       sram_intf.wdata <= data;
       sram_intf.be    <= 8'hFF;   // all byte lanes active
       @(posedge axi_tr_drv.axi.clk_i);
       sram_intf.req   <= 1'b0;
       sram_intf.wen   <= 1'b0;
       sram_intf.addr  <= 'h0;
       sram_intf.wdata <= 'h0;
       sram_intf.be    <= 'h0;

     endtask

     task  s1pt_init_hw();
        int i;
        logic [63:0] addr;
        logic [63:0] pte_val;
        logic [63:0] base_ptr;

        // Clear s1pt[1][..]
        for (i=0; i<512; i++) begin
          mem_write( s1pt_addr(0,i), 64'h0 );
          mem_write( s1pt_addr(1,i), 64'h0 );
          mem_write( s1pt_addr(2,i), 64'h0 );
        end

        // s1pt[0][3] = PTE_V | ((&s1pt[1][0] >>2) & PTE_PPN_MSK)
        base_ptr = s1pt_addr(1,0);
        pte_val  = PTE_V | ((base_ptr >> 2) & PTE_PPN_MSK);
        mem_write( s1pt_addr(0,0), pte_val );
        mem_write( s1pt_addr(0,4), pte_val );
        mem_write( s1pt_addr(0,8), pte_val );

        // s1pt[0][4] = PTE_V | ((&s1pt[2][0] >>2) & PTE_PPN_MSK)
        base_ptr = s1pt_addr(2,0);
        pte_val  = PTE_V | ((base_ptr >> 2) & PTE_PPN_MSK);
        mem_write( s1pt_addr(1,0), pte_val );
        mem_write( s1pt_addr(1,4), pte_val );
        mem_write( s1pt_addr(1,4), pte_val );
        mem_write( s1pt_addr(1,511), pte_val );

        // Fill s1pt[3][i] with 4KiB PTEs
        addr = TEST_VPAGE_BASE + 64'h0008_0000;  // The C code used TEST_VPAGE_BASE
        for (i=0; i<TEST_PAGE_MAX; i++) begin
          // s1pt[3][i] = (addr >>2) | PTE_AD | PTE_V|PTE_U|PTE_RWX
          pte_val = (addr >> 2) | PTE_AD | PTE_V | PTE_U | PTE_RWX;
          mem_write( s1pt_addr(2,i), pte_val );
          addr += PAGE_SIZE_4K;
        end

     endtask

     task  s2pt_init_hw();
        int i;
        logic [63:0] addr;
        logic [63:0] pte_val;
        logic [63:0] base_ptr;

        // Clear root table [0..2047]
        for (i=0; i<2048; i++) begin
          mem_write( s2pt_root_addr(i), 64'h0 );
        end
        // Clear s2pt[0][..]
        for (i=0; i<512; i++) begin
          mem_write( s2pt_addr(0,i), 64'h0 );
        end

        // s2pt_root[4] = PTE_V | ((&s2pt[1][0] >>2) & PTE_PPN_MSK)
        base_ptr = 32'h8000_0000;
        pte_val  = PTE_V | ((base_ptr >> 2) | PTE_AD | PTE_V | PTE_U | PTE_RWX);
        mem_write( s2pt_root_addr(2), pte_val );

        base_ptr = s2pt_addr(0,0);
        pte_val  = PTE_V | ((base_ptr >> 2) & PTE_PPN_MSK);
        mem_write( s2pt_root_addr(4), pte_val );

        // s2pt_root[2047] = PTE_V | ((&s2pt[1][0] >>2) & PTE_PPN_MSK)
        mem_write( s2pt_root_addr(2047), pte_val );

        // s2pt[1][0] = PTE_V | ((&s2pt[2][0] >>2) & PTE_PPN_MSK)
        // s2pt[1][511] = PTE_V | ((&s2pt[2][0] >>2) & PTE_PPN_MSK)
        base_ptr = s2pt_addr(1,0);
        pte_val  = PTE_V | ((base_ptr >> 2) & PTE_PPN_MSK);
        mem_write( s2pt_addr(0,0), pte_val );
        mem_write( s2pt_addr(0,31), pte_val );
        mem_write( s2pt_addr(0,511), pte_val );

        // Fill s2pt[2][i] with 4KiB PTEs
        addr = TEST_PPAGE_BASE;  // e.g. 0x88000000
        for (i=0; i<TEST_PAGE_MAX; i++) begin
        //  if ((i >= STRESS_START) && (i < STRESS_TOP)) begin
          pte_val = (addr >> 2) | PTE_AD | PTE_V | PTE_U | PTE_RWX;
        //  end
        //  else begin
        //    pte_val = (addr >> 2) | PTE_AD | get_stage2_perm(i);
        //  end
          mem_write( s2pt_addr(1,i), pte_val );
          addr += PAGE_SIZE_4K;
        end
     endtask

     task automatic iommu_ddt_init_hw();
        logic [63:0] val64;
        logic [31:0] entry_base;
        logic [63:0] ddtp;
        // --------------------------------------------------------------------------
        // (1) Init all entries to zero
        // --------------------------------------------------------------------------
        for (int i = 0; i < DDT_N_ENTRIES; i++) begin
          entry_base = ROOT_DDT_BASE + i*ROOT_DDT_SIZE;
          // Write zero to each field we care about:
          mem_write(entry_base + 64'h00, 64'h0);
          mem_write(entry_base + 64'h08, 64'h0);
          mem_write(entry_base + 64'h10, 64'h0);
          mem_write(entry_base + 64'h18, 64'h0);
          mem_write(entry_base + 64'h20, 64'h0);  // Not used if MSI disabled
          mem_write(entry_base + 64'h28, 64'h0);  // ...
          mem_write(entry_base + 64'h30, 64'h0);
          mem_write(entry_base + 64'h38, 64'h0);
        end

        // --------------------------------------------------------------------------
        // (2) Configure DCs in the root DDT (1LVL mode)
        // --------------------------------------------------------------------------
        for (int i = 0; i <= 2; i++) begin
          entry_base = ROOT_DDT_BASE + i*ROOT_DDT_SIZE;

          // root_ddt[i].tc = test_dc_tc_table[BASIC];
          mem_write(entry_base + OFF_TC, 32'b11);

          // root_ddt[i].iohgatp = ((s2pt_root >> 12) | IOHGATP_MODE_BARE);
          //  and also add  (GSCID_ARRAY[i] << GSCID_OFF)
          val64 = {IOHGATP_MODE_SV39X4, 16'b0, S2PT_ROOT_BASE};
          mem_write(entry_base + OFF_IOHGATP, val64);

          // root_ddt[i].fsc = ((s1pt >> 12) | IOSATP_MODE_BARE);
          val64 = {IOSATP_MODE_SV39, 16'b0, S1PT_BASE};
          mem_write(entry_base + OFF_FSC, val64);
        end // for (int i = DID_MIN; i <= DID_MAX; i++)

        ddtp = {10'b0,
                ROOT_DDT_BASE[43:0],
                6'b0,
                DDTP_MODE_1LVL};

        axi_single_write_prog(64'h10,ddtp[31:0]);
        axi_single_write_prog(64'h14,ddtp[63:32]);


     endtask

     // Page Queue config
     task automatic iommu_pq_init();
        // Local variables for 64-bit and 32-bit data
        logic [63:0] pqb_val;
        logic [31:0] pqh_val;
        logic [31:0] reg_data;

        pqb_val = (((COMMAND_QUEUE_BASE >> 2) & PQB_PPN_MASK) | PQ_LOG2SZ_1);

        // Program the 64-bit cqb register using two 32-bit writes.
        axi_single_write_prog(IOMMU_PQB_ADDR, pqb_val[31:0]);
        axi_single_write_prog(IOMMU_PQB_ADDR + 4, pqb_val[63:32]);

        // Read the current command-queue head (cqh) using the programming interface.
        axi_single_read_prog(IOMMU_PQH_ADDR, pqh_val);
        // Set cqt (tail) equal to cqh.
        axi_single_write_prog(IOMMU_PQT_ADDR, pqh_val);

        // Enable the command queue by writing (CQCSR_CQEN | CQCSR_CIE) to cqcsr.
        axi_single_write_prog(IOMMU_PQCSR_ADDR, (PQCSR_CQEN | PQCSR_CIE));

        // Poll until the CQON bit is set in the cqcsr register.
        do begin
          axi_single_read_prog(IOMMU_PQCSR_ADDR, reg_data);
          @(posedge axi_tr_drv.axi.clk_i);
        end while ((reg_data & PQCSR_CQON) == 0);
     endtask

     // Command queue config
     task automatic iommu_cq_init();
        // Local variables for 64-bit and 32-bit data
        logic [63:0] cqb_val;
        logic [31:0] cqh_val;
        logic [31:0] reg_data;
        // Compute the value for the command-queue base register:
        //   cqb_val = ( (COMMAND_QUEUE_BASE >> 2) & CQB_PPN_MASK ) | CQ_LOG2SZ_1;

        cqb_val = (((COMMAND_QUEUE_BASE >> 2) & CQB_PPN_MASK) | CQ_LOG2SZ_1);

        // Program the 64-bit cqb register using two 32-bit writes.
        axi_single_write_prog(IOMMU_CQB_ADDR, cqb_val[31:0]);
        axi_single_write_prog(IOMMU_CQB_ADDR + 4, cqb_val[63:32]);

        // Read the current command-queue head (cqh) using the programming interface.
        axi_single_read_prog(IOMMU_CQH_ADDR, cqh_val);
        // Set cqt (tail) equal to cqh.
        axi_single_write_prog(IOMMU_CQT_ADDR, cqh_val);

        // Enable the command queue by writing (CQCSR_CQEN | CQCSR_CIE) to cqcsr.
        axi_single_write_prog(IOMMU_CQCSR_ADDR, (CQCSR_CQEN | CQCSR_CIE));

        // Poll until the CQON bit is set in the cqcsr register.
        do begin
          axi_single_read_prog(IOMMU_CQCSR_ADDR, reg_data);
          @(posedge axi_tr_drv.axi.clk_i);
        end while ((reg_data & CQCSR_CQON) == 0);
     endtask

     // Write a 128-bit command into the command queue
     task automatic rv_iommu_write_command_in_queue(ref cq_atsinval_t inval_i);
        logic [31:0] cqt;
        logic [31:0] cq_entry_addr;
        // Read the current command-queue tail index (cqt)
        axi_single_read_prog(64'h24, cqt);

        // Compute the address of the next CQ entry:
        // Each entry is 16 bytes (2×64-bit words) so we shift cqt by 4 bits.
        cq_entry_addr = (COMMAND_QUEUE_BASE & CQ_PPN_MASK32) | (cqt << 4);

        // Write the first 64-bit word at the computed command queue address.
        mem_write(cq_entry_addr,      inval_i[63:0]);
        mem_write(cq_entry_addr + 8,  inval_i[127:64]);

        // Increment the command-queue tail pointer and program it back.
        cqt = cqt + 1;
        axi_single_write_prog(64'h24, cqt);
     endtask

   endclass

endpackage
