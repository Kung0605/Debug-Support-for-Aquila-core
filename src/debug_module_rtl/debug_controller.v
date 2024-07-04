`timescale 1ns / 1ps
// =============================================================================
//  Program : debug_controller.v
//  Author  : Ta-Cheng Kung
//  Date    : Jul/04/2024
// -----------------------------------------------------------------------------
//  Description:
//  This is the debug state control unit for Aquila core.
// -----------------------------------------------------------------------------
//  Revision information:
//
//  None.
// -----------------------------------------------------------------------------
//  License information:
//
//  This software is released under the BSD-3-Clause Licence,
//  see https://opensource.org/licenses/BSD-3-Clause for details.
//  In the following license statements, "software" refers to the
//  "source code" of the complete hardware/software system.
//
//  Copyright 2019,
//                    Embedded Intelligent Systems Lab (EISL)
//                    Deparment of Computer Science
//                    National Chiao Tung Uniersity
//                    Hsinchu, Taiwan.
//
//  All rights reserved.
//
//  Redistribution and use in source and binary forms, with or without
//  modification, are permitted provided that the following conditions are met:
//
//  1. Redistributions of source code must retain the above copyright notice,
//     this list of conditions and the following disclaimer.
//
//  2. Redistributions in binary form must reproduce the above copyright notice,
//     this list of conditions and the following disclaimer in the documentation
//     and/or other materials provided with the distribution.
//
//  3. Neither the name of the copyright holder nor the names of its contributors
//     may be used to endorse or promote products derived from this software
//     without specific prior written permission.
//
//  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
//  AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
//  IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
//  ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
//  LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
//  CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
//  SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
//  INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
//  CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
//  ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
//  POSSIBILITY OF SUCH DAMAGE.
// =============================================================================
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
    input          sys_jump_dret_i,
    // 
    input          debug_ebreak_i,
    // To Program Counter Unit
    output         debug_halt_req_o,
    // to CSRs 
    output         debug_save_dpc_o,
    output [2:0]   debug_cause_o,
    output         debug_cause_by_breakpoint_o,
    // From execute stage
    input          halted_i,
    
    output         debugging_o
);
    reg  [2:0] state_q, state_d;
    wire debug_halt_req;
    wire debug_step_req;
    reg  debugging;
    reg  [2:0] debug_cause_r;

    // For branch handling
    reg  [1:0] flush_r;
    wire       flush_d;
    assign flush_d = |flush_r;
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
                if (debug_trigger_match_i && ~flush_d)
                    if (stall_i)
                        state_d = Wait_stall_halt;
                    else 
                        state_d = Entering_halt;
                else if (debug_strobe_i)
                    if (stall_i)
                        state_d = Wait_stall_halt;
                    else
                        state_d = Entering_halt;
                else if (debug_single_step_i && ~halted_i)
                    if (stall_i)
                        state_d = Wait_stall_step;
                    else 
                        state_d = Entering_step;
                else if (debug_ebreak_i)
                    if (stall_i)
                        state_d = Wait_stall_halt;
                    else 
                        state_d = Entering_halt;
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
                if (sys_jump_dret_i)
                    state_d = Running;
                else if (debug_ebreak_i)
                    if (stall_i)
                        state_d = Wait_stall_halt;
                    else 
                        state_d = Entering_halt;   
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
        if (debug_trigger_match_i && ~flush_d)
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

    always @(posedge clk_i) begin 
        if (rst_i)
            flush_r <= 2'b0;
        else 
            flush_r <= {flush_r[0], flush_i};
    end
    assign debug_halt_req = (state_q != Entering_halt && state_d == Entering_halt);
    assign debug_step_req = (state_q != Entering_step && state_d == Entering_step);

    assign debug_save_dpc_o = !halted_i && debug_halt_req_o;

    // output signal
    assign debug_halt_req_o = debug_halt_req || debug_step_req;
    assign debug_cause_o = debug_cause_r;
    assign debug_cause_by_breakpoint_o = debug_cause_r == Debug_breakpoint;

    assign debugging_o = debugging;
endmodule