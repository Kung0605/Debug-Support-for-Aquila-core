module debug_rom (
  input           clk_i,
  input           rst_ni,
  input           req_i,
  input   [63:0]  addr_i,
  output  [63:0]  rdata_o
);

  localparam RomSize = 20;

  wire [63:0] mem[RomSize-1:0];
  assign mem[0]  = 64'h00000013_0180006f;
  assign mem[1]  = 64'h00000013_0840006f;
  assign mem[2]  = 64'h00000013_0500006f;
  assign mem[3]  = 64'h7b241073_0ff0000f;
  assign mem[4]  = 64'h00000517_7b351073;
  assign mem[5]  = 64'h00c51513_00c55513;
  assign mem[6]  = 64'h10852023_f1402473;
  assign mem[7]  = 64'h40044403_00a40433;
  assign mem[8]  = 64'h02041c63_00147413;
  assign mem[9]  = 64'h00a40433_f1402473;
  assign mem[10] = 64'h00247413_40044403;
  assign mem[11] = 64'hfd5ff06f_fa0418e3;
  assign mem[12] = 64'h00c55513_00000517;
  assign mem[13] = 64'h10052c23_00c51513;
  assign mem[14] = 64'h7b202473_7b302573;
  assign mem[15] = 64'h10052423_00100073;
  assign mem[16] = 64'h7b202473_7b302573;
  assign mem[17] = 64'hf1402473_a79ff06f;
  assign mem[18] = 64'h7b302573_10852823;
  assign mem[19] = 64'h7b200073_7b202473;

  wire [$clog2(RomSize)-1:0] addr_d;
  reg  [$clog2(RomSize)-1:0] addr_q;

  assign addr_d = req_i ? addr_i[$clog2(RomSize)-1+3:3] : addr_q;

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      addr_q <= 0;
    end else begin
      addr_q <= addr_d;
    end
  end
  assign rdata_o = (addr_q < RomSize) ? mem[addr_q] : 0;

endmodule
// content of debug rom, which is downloaded from rocket chip 
// // The debugger can assume as second scratch register.
// // # define SND_SCRATCH 1
// // These are implementation-specific addresses in the Debug Module
// #define HALTED    0x100
// #define GOING     0x108
// #define RESUMING  0x110
// #define EXCEPTION 0x118

// // Region of memory where each hart has 1
// // byte to read.
// #define FLAGS 0x400
// #define FLAG_GO     0
// #define FLAG_RESUME 1

//         .option norvc
//         .global entry
//         .global exception

//         // Entry location on ebreak, Halt, or Breakpoint
//         // It is the same for all harts. They branch when
//         // their GO or RESUME bit is set.

// entry:
// 800       jal zero, _entry
// 804       nop
// resume:
// 808       jal zero, _resume
// 80c       nop
// exception:
// 810       jal zero, _exception
// 814       nop



// _entry:
// 818        fence
// 81c        csrw CSR_DSCRATCH0, s0       // Save s0 to allow signaling MHARTID
// 820        csrw CSR_DSCRATCH1, a0       // Save a0 to allow loading arbitrary DM base
// 824        auipc a0, 0                  // Get PC
// 828        srli a0, a0, 12              // And throw away lower 12 bits to get the DM base
// 82c        slli a0, a0, 12
// entry_loop:
// 830        csrr s0, CSR_MHARTID
// 834        sw   s0, HALTED(a0)
// 838        add  s0, s0, a0
// 83c        lbu  s0, FLAGS(s0) // 1 byte flag per hart. Only one hart advances here.
// 840        andi s0, s0, (1 << FLAG_GO)
// 844        bnez s0, going
// 848        csrr s0, CSR_MHARTID
// 84c	   add  s0, s0, a0
// 850        lbu  s0, FLAGS(s0) // multiple harts can resume  here
// 854        andi s0, s0, (1 << FLAG_RESUME)
// 858        bnez s0, resume
// 85c        jal  zero, entry_loop
// _exception:
// 860        auipc a0, 0                  // Get POC
// 864        srli a0, a0, 12              // And throw away lower 12 bits to get the DM base
// 868        slli a0, a0, 12
// 86c        sw   zero, EXCEPTION(a0)     // Let debug module know you got an exception.
// 870        csrr a0, CSR_DSCRATCH1       // Restore a0 here
// 874        csrr s0, CSR_DSCRATCH0       // Restore s0 here
// 878        ebreak
// going:
// 87c        sw zero, GOING(a0)          // When debug module sees this write, the GO flag is reset.
// 880        csrr a0, CSR_DSCRATCH1      // Restore a0 here
// 884        csrr s0, CSR_DSCRATCH0      // Restore s0 here
// 888        jal zero, whereto
// _resume:
// 88c        csrr s0, CSR_MHARTID
// 890        sw   s0, RESUMING(a0)   // When Debug Module sees this write, the RESUME flag is reset.
// 894        csrr a0, CSR_DSCRATCH1  // Restore a0 here
// 898        csrr s0, CSR_DSCRATCH0  // Restore s0 here
// 89c        dret

//         // END OF ACTUAL "ROM" CONTENTS. BELOW IS JUST FOR LINKER SCRIPT.

// .section .whereto
// whereto:
//         nop
//         // Variable "ROM" This is : jal x0 abstract, jal x0 program_buffer,
//         //                or jal x0 resume, as desired.
//         //                Debug Module state machine tracks what is 'desired'.
//         //                We don't need/want to use jalr here because all of the
//         //                Variable ROM contents are set by
//         //                Debug Module before setting the OK_GO byte.