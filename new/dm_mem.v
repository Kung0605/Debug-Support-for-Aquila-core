module dm_mem #(
  parameter         NrHarts          =  1,
  parameter         BusWidth         = 32,
  parameter         SelectableHarts  = {NrHarts{1'b1}},
  parameter         DmBaseAddress    = 0,
  parameter         ProgBufSize      = 8,
  parameter         DataCount        = 2
) (
  input                               clk_i,       // Clock
  input                               rst_ni,      // debug module reset

  output  [NrHarts-1:0]               debug_req_o,
  input                               ndmreset_i,
  input   [19:0]                      hartsel_i,
  // from Ctrl and Status register
  input   [NrHarts-1:0]               haltreq_i,
  input   [NrHarts-1:0]               resumereq_i,
  input                               clear_resumeack_i,

  // state bits
  output  [NrHarts-1:0]               halted_o,    // hart acknowledge halt
  output  [NrHarts-1:0]               resuming_o,  // hart is resuming

  input   [ProgBufSize*32-1:0]        progbuf_i_flatten,    // program buffer to expose

  input   [DataCount*32-1:0]          data_i_flatten,       // data in
  output reg [DataCount*32-1:0]       data_o_flatten,       // data out
  output reg                          data_valid_o, // data out is valid
  // abstract command interface
  input                               cmd_valid_i,
  input  [31:0]                       cmd_i,
  output                              cmderror_valid_o,
  output     [2:0]                    cmderror_o,
  output                              cmdbusy_o,
  // data interface

  // SRAM interface
  input                               req_i,
  input                               we_i,
  input   [BusWidth-1:0]              addr_i,
  input   [BusWidth-1:0]              wdata_i,
  input   [BusWidth/8-1:0]            be_i,
  output  [BusWidth-1:0]              rdata_o
);
  localparam  DbgAddressBits = 12;
  localparam  HartSelLen     = (NrHarts == 1) ? 1 : $clog2(NrHarts);
  localparam  NrHartsAligned = 2**HartSelLen;
  localparam  MaxAar         = 3;
  // Depending on whether we are at the zero page or not we either use `x0` or `x10/a0`
  localparam  LoadBaseAddr   = (DmBaseAddress == 0) ? 5'd0 : 5'd10;

  localparam  DataAddr            = 32'h380;
  localparam  HaltAddress         = 64'h800;
  localparam  ResumeAddress       = HaltAddress + 8;
  localparam  ExceptionAddress    = HaltAddress + 16;
  localparam  DataBaseAddr        = DataAddr;
  localparam  DataEndAddr         = DataAddr + 4*DataCount - 1;
  localparam  ProgBufBaseAddr     = DataAddr - 4*ProgBufSize;
  localparam  ProgBufEndAddr      = DataAddr - 1;
  localparam  AbstractCmdBaseAddr = ProgBufBaseAddr - 4*10;
  localparam  AbstractCmdEndAddr  = ProgBufBaseAddr - 1;

  localparam  WhereToAddr   = 32'h300;
  localparam  FlagsBaseAddr = 32'h400;
  localparam  FlagsEndAddr  = 32'h7FF;

  localparam  HaltedAddr    = 32'h100;
  localparam  GoingAddr     = 32'h108;
  localparam  ResumingAddr  = 32'h110;
  localparam  ExceptionAddr = 32'h118;

  localparam  AccessRegister = 8'h0,
              QuickAccess    = 8'h1,
              AccessMemory   = 8'h2;

  function [31:0] jal (input [4:0]  rd, input [20:0] imm);
    jal = {imm[20], imm[10:1], imm[11], imm[19:12], rd, 7'h6f};
  endfunction
  wire  [63:0] progbuf [ProgBufSize/2-1:0];
  wire  [63:0] abstract_cmd [7:0];
  wire  [NrHarts-1:0] halted_d;
  reg   [NrHarts-1:0] halted_q;
  wire  [NrHarts-1:0] resuming_d;
  reg   [NrHarts-1:0] resuming_q;
  // reg   resume, go, going;
  wire resume, go;
  reg  going;
  reg   exception;
  wire  unsupported_command;

  wire  [63:0] rom_rdata;
  reg   [63:0] rdata_d, rdata_q;
  reg   word_enable32_q;

  // flatten I/O signal
  reg   [31:0] progbuf_i [ProgBufSize-1:0];
  integer i;
  always @(*) begin 
    for (i = 0; i < ProgBufSize; i = i + 1) begin 
      progbuf_i[i] = progbuf_i_flatten[i*32+:32];
    end
  end
  reg   [31:0] data_o [DataCount-1:0];
  always @(*) begin
    for (i = 0; i < DataCount; i = i + 1) begin 
      data_o_flatten[i*32+:32] = data_o[i];
    end
  end
  reg   [31:0] data_i [DataCount-1:0];
  always @(*) begin
    for (i = 0; i < DataCount; i = i + 1) begin 
      data_i[i] = data_i_flatten[i*32+:32];
    end
  end
  
  wire  [HartSelLen-1:0] hartsel, wdata_hartsel;

  assign hartsel       = hartsel_i[HartSelLen-1:0];
  assign wdata_hartsel = wdata_i[HartSelLen-1:0];

  wire  [NrHartsAligned-1:0]  resumereq_aligned, haltreq_aligned,
                              halted_q_aligned, resumereq_wdata_aligned,
                              resuming_q_aligned;
  reg   [NrHartsAligned-1:0]  halted_d_aligned, halted_aligned,
                              resuming_d_aligned;

  assign resumereq_aligned       = resumereq_i;
  assign haltreq_aligned         = haltreq_i;
  assign resumereq_wdata_aligned = resumereq_i;

  assign halted_q_aligned        = halted_q;
  assign halted_d                = halted_d_aligned;
  assign resuming_q_aligned      = resuming_q;
  assign resuming_d              = resuming_d_aligned;

  
  wire  fwd_rom_d;
  reg   fwd_rom_q;

  // Abstract Command Access Register
  wire  [ 7:0] cmd_cmdtype;
  wire  transfer;
  wire  postexec;
  assign debug_req_o = haltreq_i;
  assign halted_o    = halted_q;
  assign resuming_o  = resuming_q;

  // reshape progbuf
  genvar gi;
  generate 
  for (gi = 0; gi < ProgBufSize / 2; gi = gi + 1) begin 
    assign progbuf[gi] = {progbuf_i[gi*2 + 1], progbuf_i[gi*2]};
  end
  endgenerate
  dm_core_control  i_dm_core_control (
    .clk_i                 ( clk_i                       ),
    .rst_ni                ( rst_ni                      ),
    .cmd_valid_i           ( cmd_valid_i                 ),
    .cmderror_valid_o      ( cmderror_valid_o            ),
    .cmderror_o            ( cmderror_o                  ),
    .cmdbusy_o             ( cmdbusy_o                   ),
    .unsupported_command_i ( unsupported_command         ),
    .go_o                  ( go                          ),
    .resume_o              ( resume                      ),
    .going_i               ( going                       ),
    .exception_i           ( exception                   ),
    .ndmreset_i            ( ndmreset_i                  ),
    .halted_q_aligned_i    ( halted_q_aligned[hartsel]   ),
    .resumereq_aligned_i   ( resumereq_aligned[hartsel]  ),
    .resuming_q_aligned_i  ( resuming_q_aligned[hartsel] ),
    .haltreq_aligned_i     ( haltreq_aligned[hartsel]    ),
    .halted_aligned_i      ( halted_aligned[hartsel]     )
  );
  // reg  [1:0] state_d, state_q;
  
  // // hart ctrl queue
  // always @(*) begin 
  //   cmderror_valid_o = 1'b0;
  //   cmderror_o       = CmdErrNone;
  //   state_d          = state_q;

  //   case (state_q)
  //     Idle: begin
  //       cmdbusy_o = 1'b0;
  //       go        = 1'b0;
  //       resume    = 1'b0;
  //       if (cmd_valid_i && halted_q_aligned[hartsel] && !unsupported_command) begin
  //         // give the go signal
  //         state_d = Go;
  //       end else if (cmd_valid_i) begin
  //         // hart must be halted for all requests
  //         cmderror_valid_o = 1'b1;
  //         cmderror_o = CmdErrorHaltResume;
  //       end
  //       // CSRs want to resume, the request is ignored when the hart is
  //       // requested to halt or it didn't clear the resuming_q bit before
  //       if (resumereq_aligned[hartsel] && !resuming_q_aligned[hartsel] &&
  //           !haltreq_aligned[hartsel] && halted_q_aligned[hartsel]) begin
  //         state_d = Resume;
  //       end
  //     end
  //     Go: begin
  //       // we are already busy here since we scheduled the execution of a program
  //       cmdbusy_o = 1'b1;
  //       go        = 1'b1;
  //       resume    = 1'b0;
  //       // the thread is now executing the command, track its state
  //       if (going) begin
  //           state_d = CmdExecuting;
  //       end
  //     end

  //     Resume: begin
  //       cmdbusy_o = 1'b1;
  //       go        = 1'b0;
  //       resume    = 1'b1;
  //       if (resuming_q_aligned[hartsel]) begin
  //         state_d = Idle;
  //       end
  //     end
  //     CmdExecuting: begin
  //       cmdbusy_o = 1'b1;
  //       go        = 1'b0;
  //       resume    = 1'b0;
  //       // wait until the hart has halted again
  //       if (halted_aligned[hartsel]) begin
  //         state_d = Idle;
  //       end
  //     end

  //     default: begin
  //       cmdbusy_o = 1'b1;
  //       go        = 1'b0;
  //       resume    = 1'b0;
  //     end
  //   endcase

  //   // only signal once that cmd is unsupported so that we can clear cmderr
  //   // in subsequent writes to abstractcs
  //   if (unsupported_command && cmd_valid_i) begin
  //     cmderror_valid_o = 1'b1;
  //     cmderror_o = CmdErrNotSupported;
  //   end

  //   if (exception) begin
  //     cmderror_valid_o = 1'b1;
  //     cmderror_o = CmdErrorException;
  //   end

  //   if (ndmreset_i) begin
  //     // Clear state of hart and its control signals when it is being reset.
  //     state_d = Idle;
  //   end
  // end

  // word mux for 32bit and 64bit buses
  wire  [63:0] word_mux;
  assign word_mux = (fwd_rom_q) ? rom_rdata : rdata_q;

  assign rdata_o = (word_enable32_q) ? word_mux[32 +: 32] : word_mux[0 +: 32];

  // read/write logic
  reg   [31:0] data_bits [DataCount-1:0];
  reg   [ 7:0] rdata [7:0];

  wire  [DbgAddressBits-1:0] debug_addr = addr_i[DbgAddressBits-1:0];
  integer dc;
  always @(*) begin 
    halted_d_aligned   = halted_q;
    resuming_d_aligned = resuming_q;
    rdata_d        = rdata_q;
    for (i = 0; i < DataCount; i = i + 1)
        data_bits[i]      = data_i[i];
    for (i = 0; i < 8; i = i + 1)
        rdata[i] = 0;

    // write data in csr register
    data_valid_o   = 1'b0;
    exception      = 1'b0;
    halted_aligned = 0;
    going          = 1'b0;

    // The resume ack signal is lowered when the resume request is deasserted
    if (clear_resumeack_i) begin
      resuming_d_aligned[hartsel] = 1'b0;
    end
    // we've got a new request
    if (req_i) begin
      // this is a write
      if (we_i) begin
          if (debug_addr == HaltedAddr) begin
            halted_aligned[wdata_hartsel] = 1'b1;
            halted_d_aligned[wdata_hartsel] = 1'b1;
          end
          else if (debug_addr == GoingAddr) begin
            going = 1'b1;
          end
          else if (debug_addr == ResumingAddr) begin
            // clear the halted flag as the hart resumed execution
            halted_d_aligned[wdata_hartsel] = 1'b0;
            // set the resuming flag which needs to be cleared by the debugger
            resuming_d_aligned[wdata_hartsel] = 1'b1;
          end
          // an exception occurred during execution
          else if (debug_addr == ExceptionAddr) exception = 1'b1;
          else if (debug_addr >= DataBaseAddr && debug_addr <= DataEndAddr) begin 
          // core can write data registers
            data_valid_o = 1'b1;
            for (dc = 0; dc < DataCount; dc = dc + 1) begin
              if ((addr_i[DbgAddressBits-1:2] - DataBaseAddr[DbgAddressBits-1:2]) == dc) begin
                for (i = 0; i < (BusWidth/8); i = i + 1) begin
                  if (be_i[i]) begin
                    if (i>3) begin // for upper 32bit data write (only used for BusWidth ==  64)
                      if ((dc+1) < DataCount) begin // ensure we write to an implemented data register
                        data_bits[dc+1][(i-4)*8+:8] = wdata_i[i*8+:8];
                      end
                    end else begin // for lower 32bit data write
                      data_bits[dc][i*8+:8] = wdata_i[i*8+:8];
                    end
                  end
                end
              end
            end
          end

      // this is a read
      end 
      else begin
          // variable ROM content
          if (debug_addr == WhereToAddr) begin
            // variable jump to abstract cmd, program_buffer or resume
            if (resumereq_wdata_aligned[wdata_hartsel]) begin
              rdata_d = {32'b0, jal(5'b0, ResumeAddress[11:0] - WhereToAddr)};
            end

            // there is a command active so jump there
            if (cmdbusy_o) begin
              // transfer not set is shortcut to the program buffer if postexec is set
              // keep this statement narrow to not catch invalid commands
              if (cmd_cmdtype == AccessRegister &&
                  !transfer && postexec) begin
                rdata_d = {32'b0, jal(5'b0, ProgBufBaseAddr-WhereToAddr)};
              // this is a legit abstract cmd -> execute it
              end else begin
                rdata_d = {32'b0, jal(5'b0, AbstractCmdBaseAddr-WhereToAddr)};
              end
            end
          end
        
          else if (debug_addr >= DataBaseAddr && debug_addr <= DataEndAddr) begin
            rdata_d = {
                      data_i[((addr_i[DbgAddressBits-1:3] - DataBaseAddr[DbgAddressBits-1:3]) << 1) + 1'b1],
                      data_i[((addr_i[DbgAddressBits-1:3] - DataBaseAddr[DbgAddressBits-1:3]) << 1)]
                      };
          end
          else if (debug_addr >= ProgBufBaseAddr && debug_addr <= ProgBufEndAddr) begin
            rdata_d = progbuf[addr_i[DbgAddressBits-1:3] - ProgBufBaseAddr[DbgAddressBits-1:3]];
          end
          else if (debug_addr >= AbstractCmdBaseAddr && debug_addr <= AbstractCmdEndAddr) begin
            // return the correct address index
            rdata_d = abstract_cmd[addr_i[DbgAddressBits-1:3] - AbstractCmdBaseAddr[DbgAddressBits-1:3]];
          end
          else if (debug_addr >= FlagsBaseAddr && debug_addr <= FlagsEndAddr) begin
            // release the corresponding hart
            if (({addr_i[DbgAddressBits-1:3], 3'b0} - FlagsBaseAddr[DbgAddressBits-1:0]) ==
              (hartsel & {{(DbgAddressBits-3){1'b1}}, 3'b0})) begin
              rdata[hartsel & 3'b111] = {6'b0, resume, go};
            end
            for (i = 0; i < 8; i = i + 1)
                rdata_d[i*8 +: 8] = rdata[i];
          end
      end
    end

    if (ndmreset_i) begin
      // When harts are reset, they are neither halted nor resuming.
      halted_d_aligned   = 0;
      resuming_d_aligned = 0;
    end

    for (i = 0; i < DataCount; i = i + 1)
        data_o[i] = data_bits[i];
  end

  dm_abstractcmd_generator i_dm_abstractcmd_generator(
    .cmd_i                 ( cmd_i               ),
    .cmd_cmdtype_o         ( cmd_cmdtype         ),
    .abstract_cmd0_o       ( abstract_cmd[0]     ),
    .abstract_cmd1_o       ( abstract_cmd[1]     ),
    .abstract_cmd2_o       ( abstract_cmd[2]     ),
    .abstract_cmd3_o       ( abstract_cmd[3]     ),
    .abstract_cmd4_o       ( abstract_cmd[4]     ),
    .abstract_cmd5_o       ( abstract_cmd[5]     ),
    .abstract_cmd6_o       ( abstract_cmd[6]     ),
    .abstract_cmd7_o       ( abstract_cmd[7]     ),
    .unsupported_command_o ( unsupported_command ),
    .transfer_o            ( transfer            ),
    .postexec_o            ( postexec            )
  );
  

  wire  [63:0] rom_addr;
  assign rom_addr = {32'b0, addr_i};

  debug_rom i_debug_rom (
    .clk_i   ( clk_i     ),
    .rst_ni  ( rst_ni    ),
    .req_i   ( req_i     ),
    .addr_i  ( rom_addr  ),
    .rdata_o ( rom_rdata )
  );


  assign fwd_rom_d = debug_addr >= HaltAddress[DbgAddressBits-1:0];

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      fwd_rom_q       <= 1'b0;
      rdata_q         <= 0;
      // state_q         <= Idle;
      word_enable32_q <= 1'b0;
    end else begin
      fwd_rom_q       <= fwd_rom_d;
      rdata_q         <= rdata_d;
      // state_q         <= state_d;
      word_enable32_q <= addr_i[2];
    end
  end

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      halted_q   <= 1'b0;
      resuming_q <= 1'b0;
    end else begin
      halted_q   <= SelectableHarts & halted_d;
      resuming_q <= SelectableHarts & resuming_d;
    end
  end
  
endmodule