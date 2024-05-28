module dm_core_control (
    // system signal
    input                clk_i,
    input                rst_ni,
    // command control signal
    input                cmd_valid_i,          // valid to read command
    output reg           cmderror_valid_o,     // command error occur
    output reg [2:0]     cmderror_o,           // error kind
    output reg           cmdbusy_o,            // command is busy executing
    input                unsupported_command_i,// unsupported type
    
    // debug memory state
    output               go_o,                 // run command
    output               resume_o,             // resuming 
    input                going_i,              // running command
    input                exception_i,          // exception occur

    input                ndmreset_i,           // reset signal for non-debug-module

    // core state information
    input                halted_q_aligned_i,   // core is halted
    input                resumereq_aligned_i,  // DM requesting to resume the core
    input                resuming_q_aligned_i, // core is resuming
    input                haltreq_aligned_i,    // DM request to halt the core
    input                halted_aligned_i      
);
  localparam  Idle         = 0,
              Go           = 1,
              Resume       = 2,
              CmdExecuting = 3;

  localparam  CmdErrNone         = 0, 
              CmdErrBusy         = 1, 
              CmdErrNotSupported = 2,
              CmdErrorException  = 3, 
              CmdErrorHaltResume = 4,
              CmdErrorBus        = 5, 
              CmdErrorOther      = 7;

  reg  [1:0] state_d, state_q;
  reg   resume, go;

  always @(*) begin 
    // default assignment
    // no error
    cmderror_valid_o = 1'b0;       
    cmderror_o       = CmdErrNone; 
    state_d          = state_q;
    // FSM for debug memory
    case (state_q)
      Idle: begin
        cmdbusy_o = 1'b0;
        go        = 1'b0;
        resume    = 1'b0;
        if (cmd_valid_i && halted_q_aligned_i && !unsupported_command_i) begin
          // core is halted and command is valud -> run command
          state_d = Go;
        end else if (cmd_valid_i) begin
          // core is not halted -> can't run command
          cmderror_valid_o = 1'b1;
          cmderror_o = CmdErrorHaltResume;
        end
        if (resumereq_aligned_i && !resuming_q_aligned_i &&
            !haltreq_aligned_i && halted_q_aligned_i) begin
          // CSR want core to resume
          state_d = Resume;
        end
      end
      Go: begin
        // prepare to run abstract command or program buffer
        cmdbusy_o = 1'b1;
        go        = 1'b1;
        resume    = 1'b0;
        if (going_i) begin
          // run command
          state_d = CmdExecuting;
        end
      end

      Resume: begin
        cmdbusy_o = 1'b1;
        go        = 1'b0;
        resume    = 1'b1;
        if (resuming_q_aligned_i) begin
          // wait for the core to resume
          state_d = Idle;
        end
      end
      CmdExecuting: begin
        // executing abstract command
        cmdbusy_o = 1'b1;
        go        = 1'b0;
        resume    = 1'b0;
        if (halted_aligned_i) begin
          // wait for the core to halted
          state_d = Idle;
        end
      end

      default: begin
        cmdbusy_o = 1'b1;
        go        = 1'b0;
        resume    = 1'b0;
      end
    endcase
    // Error handling
    if (unsupported_command_i && cmd_valid_i) begin
      cmderror_valid_o = 1'b1;
      cmderror_o = CmdErrNotSupported;
    end
    if (exception_i) begin
      cmderror_valid_o = 1'b1;
      cmderror_o = CmdErrorException;
    end
    // reset the core -> dm_mem go to Idle
    if (ndmreset_i) begin
      state_d = Idle;
    end
  end

  always @(posedge clk_i or negedge rst_ni) begin 
    if (~rst_ni)  
        state_q <= Idle;
    else 
        state_q <= state_d;
  end

  // output assignment
  assign resume_o = resume;
  assign go_o     = go;
endmodule