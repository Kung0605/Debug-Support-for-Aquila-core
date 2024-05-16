`timescale 1ns / 1ps

module debug_controller(
    // processor clock and reset signals
    input          clk_i, 
    input          rst_i,
    
    // pipeline signals
    input          stall_i,
    input          flush_i,
    // from debug module
    input          debug_strobe_i,
    // from csr
    input          debug_single_step_i,
    input          debug_trigger_match_i,
    // 
    input          debug_ebreak_i,
    // To Program Counter Unit
    output         debug_halt_req_o,
    // to CSRs 
    output         debug_save_dpc_o,
    output [2:0]   debug_cause_o,
    output         debug_cause_by_breakpoint_o,
    // From execute stage
    input          halted_i
);
    reg  [2:0] state_q, state_d;
    wire debug_halt_req;
    wire debug_step_req;
    reg  debugging;
    reg  [2:0] debug_cause_r;
    localparam  Running            = 0,
                Entering_halt      = 1,
                Entering_step      = 2,
                Halted             = 3,
                Wait_stall_halt    = 4,
                Wait_stall_step    = 5;

    localparam  Debug_none         = 0,
                Debug_ebreak       = 1,
                Debug_breakpoint   = 2,
                Debug_haltreq      = 3,
                Debug_step         = 4,
                Debug_resethaltreq = 5;

    always @(*) begin 
        case(state_q)
            Running: begin 
                if (debug_trigger_match_i)
                    state_d = stall_i ? Wait_stall_halt : Entering_halt;
                else if (debug_strobe_i)
                    state_d = stall_i ? Wait_stall_halt : Entering_halt;
                else if (debug_single_step_i)
                    state_d = stall_i ? Wait_stall_step : Entering_step;
                else if (debug_ebreak_i)
                    state_d = stall_i ? Wait_stall_halt : Entering_halt;
                else 
                    state_d = Running;
            end
            Entering_step: begin 
                if (halted_i)
                    state_d = Halted;
                else 
                    state_d = Entering_step;
            end
            Entering_halt: begin 
                if (halted_i) 
                    state_d = Halted;
                else 
                    state_d = Entering_halt;
            end 
            Halted: begin 
                if (~halted_i)
                    state_d = Running;
                else if (debug_ebreak_i)
                    state_d = stall_i ? Wait_stall_halt : Entering_halt;
                else 
                    state_d = Halted;
            end
            Wait_stall_halt: begin
                if (~stall_i)
                    state_d = Entering_halt;
                else 
                    state_d = Wait_stall_halt;
            end
            Wait_stall_step: begin 
                if (~stall_i) 
                    state_d = Entering_step;
                else 
                    state_d = Wait_stall_step;
            end
            default: state_d = Running;
        endcase
    end

    always @(posedge clk_i) begin 
        if (rst_i) 
            state_q <= Running;
        else 
            state_q <= state_d;
    end

    always @(posedge clk_i) begin
        if (rst_i)
            debugging <= 0;
        else if (debugging)
            debugging <= (state_d != Running);
        else 
            debugging <= (state_d == Halted);
    end

    always @(*) begin 
        if (debug_trigger_match_i)
            debug_cause_r = Debug_breakpoint;
        // else if (debug_ebreak_i)
        //     debug_cause_r = Debug_ebreak;
        else if (debug_halt_req)
            debug_cause_r = Debug_haltreq;
        else if (debug_step_req)
            debug_cause_r = Debug_step;
        else 
            debug_cause_r = Debug_none;
    end

    assign debug_halt_req = (state_q != Entering_halt && state_d == Entering_halt);
    assign debug_step_req = (state_q != Entering_step && state_d == Entering_step);

    assign debug_save_dpc_o = !debugging && debug_halt_req_o;

    // output signal
    assign debug_halt_req_o = debug_halt_req || debug_step_req;
    assign debug_cause_o = debug_cause_r;
    assign debug_cause_by_breakpoint_o = (debug_cause_r == Debug_breakpoint);
endmodule