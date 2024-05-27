module dm_core_control (
    input                clk_i,
    input                rst_ni,

    input                cmd_valid_i,
    output reg           cmderror_valid_o,
    output reg [2:0]     cmderror_o,
    output reg           cmdbusy_o,
    input                unsupported_command_i,
    
    output               go_o,
    output               resume_o,
    input                going_i,
    input                exception_i,

    input                ndmreset_i,

    input                halted_q_aligned_i,
    input                resumereq_aligned_i,
    input                resuming_q_aligned_i,
    input                haltreq_aligned_i,
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
    cmderror_valid_o = 1'b0;
    cmderror_o       = CmdErrNone;
    state_d          = state_q;

    case (state_q)
      Idle: begin
        cmdbusy_o = 1'b0;
        go        = 1'b0;
        resume    = 1'b0;
        if (cmd_valid_i && halted_q_aligned_i && !unsupported_command_i) begin
          // give the go signal
          state_d = Go;
        end else if (cmd_valid_i) begin
          // hart must be halted for all requests
          cmderror_valid_o = 1'b1;
          cmderror_o = CmdErrorHaltResume;
        end
        // CSRs want to resume, the request is ignored when the hart is
        // requested to halt or it didn't clear the resuming_q bit before
        if (resumereq_aligned_i && !resuming_q_aligned_i &&
            !haltreq_aligned_i && halted_q_aligned_i) begin
          state_d = Resume;
        end
      end
      Go: begin
        // we are already busy here since we scheduled the execution of a program
        cmdbusy_o = 1'b1;
        go        = 1'b1;
        resume    = 1'b0;
        // the thread is now executing the command, track its state
        if (going_i) begin
            state_d = CmdExecuting;
        end
      end

      Resume: begin
        cmdbusy_o = 1'b1;
        go        = 1'b0;
        resume    = 1'b1;
        if (resuming_q_aligned_i) begin
          state_d = Idle;
        end
      end
      CmdExecuting: begin
        cmdbusy_o = 1'b1;
        go        = 1'b0;
        resume    = 1'b0;
        // wait until the hart has halted again
        if (halted_aligned_i) begin
          state_d = Idle;
        end
      end

      default: begin
        cmdbusy_o = 1'b1;
        go        = 1'b0;
        resume    = 1'b0;
      end
    endcase

    // only signal once that cmd is unsupported so that we can clear cmderr
    // in subsequent writes to abstractcs
    if (unsupported_command_i && cmd_valid_i) begin
      cmderror_valid_o = 1'b1;
      cmderror_o = CmdErrNotSupported;
    end

    if (exception_i) begin
      cmderror_valid_o = 1'b1;
      cmderror_o = CmdErrorException;
    end

    if (ndmreset_i) begin
      // Clear state of hart and its control signals when it is being reset.
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