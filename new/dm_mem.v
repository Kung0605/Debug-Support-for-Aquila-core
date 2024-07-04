module dm_mem #(
    parameter         BusWidth         = 32,
    parameter         DmBaseAddress    = 0,
    parameter         ProgBufSize      = 8,
    parameter         DataCount        = 2
  ) (
    input                               clk_i,       // Clock
    input                               rst_ni,      // debug module reset

    output                              debug_req_o, // debug request to halt a core
    input                               ndmreset_i,  // non-debug module reset
    input   [19:0]                      hartsel_i,   // core select (can only be 1)
    // from dm_csrs
    input                               haltreq_i,   // request to halt a core
    input                               resumereq_i, // request to resume a core
    input                               clear_resumeack_i, // clear resumeack for previous resumeack

    // core status bit
    output                              halted_o,    // indicate the core is halted
    output                              resuming_o,  // indicate the core is resuming

    input   [ProgBufSize*32-1:0]        progbuf_i_flatten,    // program buffer

    input   [DataCount*32-1:0]          data_i_flatten,       // data in
    output reg [DataCount*32-1:0]       data_o_flatten,       // data out
    output reg                          data_valid_o,         // data out is valid
    // abstract command interface
    input                               cmd_valid_i,          // command is valid
    input  [31:0]                       cmd_i,                // abstract command
    output                              cmderror_valid_o,     // error occur
    output     [2:0]                    cmderror_o,           // kind of error
    output                              cmdbusy_o,            // indicate the cmd is busy executing
    // debug memory interface
    input                               req_i,                // memory strobe
    input                               we_i,                 // write enable
    input   [BusWidth-1:0]              addr_i,               // request memory address
    input   [BusWidth-1:0]              wdata_i,              // data to write into memory
    input   [BusWidth/8-1:0]            be_i,                 // byte enable
    output  [BusWidth-1:0]              rdata_o               // returned data from memory
  );
  localparam  DbgAddressBits = 12;
  localparam  MaxAar         = 3;
  // memory address mapping
  localparam  LoadBaseAddr   = 5'd10;
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

  // command type (only AccessRegister is supported currently)
  localparam  AccessRegister = 8'h0,
              QuickAccess    = 8'h1,
              AccessMemory   = 8'h2;

  function [31:0] jal (input [4:0]  rd, input [20:0] imm);
    jal = {imm[20], imm[10:1], imm[11], imm[19:12], rd, 7'h6f};
  endfunction

  // program buffer
  wire  [63:0] progbuf [ProgBufSize/2-1:0];
  // abstract command
  wire  [63:0] abstract_cmd [7:0];
  // core status register
  reg          halted_d;
  reg          halted_q;
  reg          resuming_d;
  reg          resuming_q;
  // dm_mem state register
  wire         resume, go;
  reg          going;
  reg          exception;
  wire         unsupported_command;
  // returned data from debug rom
  wire  [63:0] rom_rdata;
  reg   [63:0] rdata_d, rdata_q;
  reg   word_enable32_q;            // select correct value from a 64-bits returned data

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

  // select target core (can only be 0)
  wire  hartsel, wdata_hartsel;

  assign hartsel       = hartsel_i[0];
  assign wdata_hartsel = wdata_i[0];

  reg    halted;

  // select data is returned from RAM part or ROM part
  wire  fwd_rom_d;
  reg   fwd_rom_q;

  // Abstract Command Access Register
  wire  [ 7:0] cmd_cmdtype;
  wire  transfer;                  // run abstract command
  wire  postexec;                  // run program buffer
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
                     .halted_q_i            ( halted_q                    ),
                     .resumereq_i           ( resumereq_i                 ),
                     .resuming_q_i          ( resuming_q                  ),
                     .haltreq_i             ( haltreq_i                   ),
                     .halted_i              ( halted                      )
                   );

  // word mux for 32bit and 64bit buses
  wire  [63:0] word_mux;
  // if memory address is in debug_rom then return rom_data
  assign word_mux = (fwd_rom_q) ? rom_rdata : rdata_q;
  assign rdata_o = (word_enable32_q) ? word_mux[32 +: 32] : word_mux[0 +: 32];

  // read/write logic
  reg   [31:0] data_bits [DataCount-1:0];
  reg   [ 7:0] rdata [7:0];

  // the valid address for debug_rom is only lower 12 bits
  wire  [DbgAddressBits-1:0] debug_addr;
  assign debug_addr = addr_i[DbgAddressBits-1:0];
  integer dc;
  always @(*) begin
    // default assignment
    halted_d   = halted_q;
    resuming_d = resuming_q;
    rdata_d            = rdata_q;
    for (i = 0; i < DataCount; i = i + 1)
      data_bits[i]     = data_i[i];
    for (i = 0; i < 8; i = i + 1)
      rdata[i]         = 0;

    data_valid_o   = 1'b0;
    exception      = 1'b0;
    halted = 0;
    going          = 1'b0;

    // clear the resuming state
    if (clear_resumeack_i) begin
      resuming_d = 1'b0;
    end
    // new memory request is comming
    if (req_i) begin
      if (we_i) begin
        if (debug_addr == HaltedAddr) begin
          // write to HaltedAddr -> core is halted
          halted = 1'b1;
          halted_d = 1'b1;
        end
        else if (debug_addr == GoingAddr) begin
          // write to goingAddr -> command going
          going = 1'b1;
        end
        else if (debug_addr == ResumingAddr) begin
          // start resume -> clear halted flag, set resuming flag
          halted_d = 1'b0;
          resuming_d = 1'b1;
        end
        // exception occur
        else if (debug_addr == ExceptionAddr)
          exception = 1'b1;
        else if (debug_addr >= DataBaseAddr && debug_addr <= DataEndAddr) begin
          // core write to Data
          data_valid_o = 1'b1;   // tell DM to know they can read Data for response
          for (dc = 0; dc < DataCount; dc = dc + 1) begin
            // For each Data address
            if ((addr_i[DbgAddressBits-1:2] - DataBaseAddr[DbgAddressBits-1:2]) == dc) begin
              // check which Data to write to
              for (i = 0; i < (BusWidth/8); i = i + 1) begin
                // for each byte in Data
                if (be_i[i]) begin
                  data_bits[dc][i*8+:8] = wdata_i[i*8+:8];
                end
              end
            end
          end
        end
      end
      else begin
        // deug rom part
        if (debug_addr == WhereToAddr) begin
          // jump to abstract, program buffer or resumeaddr
          if (resumereq_i) begin
            // core start resume -> jump to resumeaddr
            rdata_d = {32'b0, jal(5'b0, ResumeAddress[11:0] - WhereToAddr)};
          end
          if (cmdbusy_o) begin
            // cmdbusy_o is set indicate that there are instructions in abstract command or program buffer
            if (cmd_cmdtype == AccessRegister &&
                !transfer && postexec) begin
              // if transfer is not set and postexec is set -> directly jump to program buffer
              rdata_d = {32'b0, jal(5'b0, ProgBufBaseAddr-WhereToAddr)};
            end
            else begin
              // jump to abstract command
              rdata_d = {32'b0, jal(5'b0, AbstractCmdBaseAddr-WhereToAddr)};
            end
          end
        end
        else if (debug_addr >= DataBaseAddr && debug_addr <= DataEndAddr) begin
          // return data stored in Data to put in debug response
          // use lowest 12 bits as address to get Data
          rdata_d = {
                    data_i[((addr_i[DbgAddressBits-1:3] - DataBaseAddr[DbgAddressBits-1:3]) << 1) + 1'b1],
                    data_i[((addr_i[DbgAddressBits-1:3] - DataBaseAddr[DbgAddressBits-1:3]) << 1)]
                  };
        end
        else if (debug_addr >= ProgBufBaseAddr && debug_addr <= ProgBufEndAddr) begin
          // return instructions stored in program buffer
          rdata_d = progbuf[addr_i[DbgAddressBits-1:3] - ProgBufBaseAddr[DbgAddressBits-1:3]];
        end
        else if (debug_addr >= AbstractCmdBaseAddr && debug_addr <= AbstractCmdEndAddr) begin
          // return instructions stored in abstract command
          rdata_d = abstract_cmd[addr_i[DbgAddressBits-1:3] - AbstractCmdBaseAddr[DbgAddressBits-1:3]];
        end
        else if (debug_addr >= FlagsBaseAddr && debug_addr <= FlagsEndAddr) begin
          // read Flag to check hart is halted, going, resuming, or running normally
          if (({addr_i[DbgAddressBits-1:3], 3'b0} - FlagsBaseAddr[DbgAddressBits-1:0]) ==
              (hartsel & {{(DbgAddressBits-3){1'b1}}, 3'b0})) begin
            rdata[hartsel & 3'b111] = {6'b0, resume, go};
          end
          for (i = 0; i < 8; i = i + 1)
            rdata_d[i*8 +: 8] = rdata[i];
        end
      end
    end
    // core is not resuming and not halted when they are reset
    if (ndmreset_i) begin
      halted_d   = 0;
      resuming_d = 0;
    end
    // assign output data
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


  // 64-bits address to compatible to debug_rom                          
  wire  [63:0] rom_addr;
  assign rom_addr = {32'b0, addr_i};

  debug_rom i_debug_rom (
              .clk_i   ( clk_i     ),
              .rst_ni  ( rst_ni    ),
              .req_i   ( req_i     ),
              .addr_i  ( rom_addr  ),
              .rdata_o ( rom_rdata )
            );

  // check if data should be forward from debug_rom or debug_ram
  assign fwd_rom_d = debug_addr >= HaltAddress[DbgAddressBits-1:0];

  // sequential logic
  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      fwd_rom_q       <= 1'b0;
      rdata_q         <= 0;
      word_enable32_q <= 1'b0;

      halted_q   <= 1'b0;
      resuming_q <= 1'b0;
    end
    else begin
      fwd_rom_q       <= fwd_rom_d;
      rdata_q         <= rdata_d;
      word_enable32_q <= addr_i[2];    // to retrive correct part of data inside 64-bits

      halted_q   <= halted_d;
      resuming_q <= resuming_d;
    end
  end
endmodule
