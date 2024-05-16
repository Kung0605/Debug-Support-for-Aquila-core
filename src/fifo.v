// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License. You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

// Author: Florian Zaruba <zarubaf@iis.ee.ethz.ch>

module fifo #(
    parameter DEPTH        = 8,    // depth can be arbitrary from 0 to 2**32
    parameter n            = 1,
    // DO NOT OVERWRITE THIS PARAMETER
    parameter ADDR_DEPTH   = (DEPTH > 1) ? $clog2(DEPTH) : 1
)(
    input              clk_i,            // Clock
    input              rst_ni,           // Asynchronous reset active low
    input              flush_i,          // flush the queue
    input              testmode_i,       // test_mode to bypass clock gating
    // status flags
    output             full_o,           // queue is full
    output             empty_o,          // queue is empty
    // as long as the queue is not full we can push new data
    input  [n-1:0]     data_i,           // data to push into the queue
    input              push_i,           // data is valid and can be pushed to the queue
    // as long as the queue is not empty we can pop new elements
    output reg [n-1:0] data_o,           // output data
    input              pop_i             // pop head from queue
);

    // local parameter

    // clock gating control
    reg  gate_clock;
    // pointer to the read and write section of the queue
    reg  [ADDR_DEPTH - 1:0] read_pointer_n, read_pointer_q, write_pointer_n, write_pointer_q;
    // keep a counter to keep track of the current queue status
    // this integer will be truncated by the synthesis tool
    reg  [ADDR_DEPTH:0] status_cnt_n, status_cnt_q;
    // actual memory
    reg [n-1:0] mem_n[DEPTH - 1:0];
    reg [n-1:0] mem_q[DEPTH - 1:0];


    if (DEPTH == 0) begin : gen_pass_through
        assign empty_o     = ~push_i;
        assign full_o      = ~pop_i;
    end else begin : gen_fifo
        assign full_o       = (status_cnt_q == DEPTH[ADDR_DEPTH:0]);
        assign empty_o      = (status_cnt_q == 0);
    end
    // status flags
    integer i;
    // read and write queue logic
    always @(*) begin
        // default assignment
        read_pointer_n  = read_pointer_q;
        write_pointer_n = write_pointer_q;
        status_cnt_n    = status_cnt_q;
        data_o          = (DEPTH == 0) ? data_i : mem_q[read_pointer_q];
        for (i = 0; i < DEPTH; i = i + 1) 
            mem_n[i] = mem_q[i];
        gate_clock      = 1'b1;

        // push a new element to the queue
        if (push_i && ~full_o) begin
            // push the data onto the queue
            mem_n[write_pointer_q] = data_i;
            // un-gate the clock, we want to write something
            gate_clock = 1'b0;
            // increment the write counter
            // this is dead code when DEPTH is a power of two
            if (write_pointer_q == DEPTH[ADDR_DEPTH-1:0] - 1)
                write_pointer_n = 0;
            else
                write_pointer_n = write_pointer_q + 1;
            // increment the overall counter
            status_cnt_n    = status_cnt_q + 1;
        end

        if (pop_i && ~empty_o) begin
            // read from the queue is a default assignment
            // but increment the read pointer...
            // this is dead code when DEPTH is a power of two
            if (read_pointer_n == DEPTH[ADDR_DEPTH-1:0] - 1)
                read_pointer_n = 0;
            else
                read_pointer_n = read_pointer_q + 1;
            // ... and decrement the overall count
            status_cnt_n   = status_cnt_q - 1;
        end

        // keep the count pointer stable if we push and pop at the same time
        if (push_i && pop_i &&  ~full_o && ~empty_o)
            status_cnt_n   = status_cnt_q;
    end

    // sequential process
    always @(posedge clk_i or negedge rst_ni) begin
        if(~rst_ni) begin
            read_pointer_q  <= 0;
            write_pointer_q <= 0;
            status_cnt_q    <= 0;
        end else begin
            if (flush_i) begin
                read_pointer_q  <= 0;
                write_pointer_q <= 0;
                status_cnt_q    <= 0;
             end else begin
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
        end else if (!gate_clock) begin
            for (i = 0; i < DEPTH; i = i + 1)
                mem_q[i] <= mem_n[i];
        end
    end

endmodule // fifo_v2