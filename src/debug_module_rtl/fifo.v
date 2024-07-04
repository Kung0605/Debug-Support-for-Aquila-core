`timescale 1ns / 1ps
// =============================================================================
//  Program : fifo.v
//  Author  : Ta-Cheng Kung
//  Date    : Jul/04/2024
// -----------------------------------------------------------------------------
//  Description:
//  This is a simple FIFO(first-in-first-out) module for debug system to store 
//  debug requests and debug responses in the queue.
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
module fifo #(
    parameter DEPTH        = 8,    // fifo depth
    parameter n            = 1     // number of bits
  )(
    input              clk_i,            // system clock
    input              rst_ni,           // asynchronous reset (active low)
    input              flush_i,          // flush the fifo queue
    input              testmode_i,       // Not used
    // output status
    output             full_o,           // indicate fifo is full
    output             empty_o,          // indicate fifo is empty

    input  [n-1:0]     data_i,           // data to push in fifo
    input              push_i,           // put data_i in fifo

    output reg [n-1:0] data_o,           // data pop from fifo
    input              pop_i             // pop an element from fifo
  );
  parameter ADDR_DEPTH   = (DEPTH > 1) ? $clog2(DEPTH) : 1;
  // clock gating control
  reg  gate_clock;
  // pointer for read and write operation
  reg  [ADDR_DEPTH - 1:0] read_pointer_n, read_pointer_q, write_pointer_n, write_pointer_q;
  // status counter of fifo (which is number of element in fifo)
  reg  [ADDR_DEPTH:0] status_cnt_n, status_cnt_q;
  // fifo memory
  reg [n-1:0] mem_d[DEPTH - 1:0];
  reg [n-1:0] mem_q[DEPTH - 1:0];

  assign full_o       = (status_cnt_q == DEPTH[ADDR_DEPTH:0]);
  assign empty_o      = (status_cnt_q == 0);

  integer i;
  // read and write logic
  always @(*) begin
    // default assignment
    read_pointer_n  = read_pointer_q;
    write_pointer_n = write_pointer_q;
    status_cnt_n    = status_cnt_q;
    data_o          = mem_q[read_pointer_q];
    for (i = 0; i < DEPTH; i = i + 1)
      mem_d[i] = mem_q[i];
    // lock the state
    gate_clock      = 1'b1;

    // write a element in fifo
    if (push_i && ~full_o) begin
      // write new data at write pointer
      mem_d[write_pointer_q] = data_i;
      // unlock the fifo state
      gate_clock = 1'b0;
      // increment write pointer
      if (write_pointer_q == DEPTH[ADDR_DEPTH-1:0] - 1)
        write_pointer_n = 0;
      else
        write_pointer_n = write_pointer_q + 1;
      // increment the status counter
      status_cnt_n    = status_cnt_q + 1;
    end

    // read a element from fifo
    if (pop_i && ~empty_o) begin
      // increment read pointer
      if (read_pointer_n == DEPTH[ADDR_DEPTH-1:0] - 1)
        read_pointer_n = 0;
      else
        read_pointer_n = read_pointer_q + 1;
      // minus status corunter by 1
      status_cnt_n   = status_cnt_q - 1;
    end

    // if read dand write at same time -> counter will not change
    if (push_i && pop_i &&  ~full_o && ~empty_o)
      status_cnt_n = status_cnt_q;
  end

  // sequential logic
  always @(posedge clk_i or negedge rst_ni) begin
    if(~rst_ni) begin
      // reset pointer to 0
      read_pointer_q  <= 0;
      write_pointer_q <= 0;
      // reset counter to 0
      status_cnt_q    <= 0;
    end
    else begin
      if (flush_i) begin
        // flush the fifo
        read_pointer_q  <= 0;
        write_pointer_q <= 0;
        status_cnt_q    <= 0;
      end
      else begin
        read_pointer_q  <= read_pointer_n;
        write_pointer_q <= write_pointer_n;
        status_cnt_q    <= status_cnt_n;
      end
    end
  end

  always @(posedge clk_i or negedge rst_ni) begin
    if(~rst_ni) begin
      for (i = 0; i < DEPTH; i = i + 1)
        mem_q[i] <= 0;
    end
    else if (!gate_clock) begin
      // fifo state is unlocked -> update fifo memory
      for (i = 0; i < DEPTH; i = i + 1)
        mem_q[i] <= mem_d[i];
    end
  end

endmodule
