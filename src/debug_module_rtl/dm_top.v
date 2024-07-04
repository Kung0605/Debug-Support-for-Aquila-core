`timescale 1ns / 1ps
// =============================================================================
//  Program : dm_top.v
//  Author  : Ta-Cheng Kung
//  Date    : Jul/04/2024
// -----------------------------------------------------------------------------
//  Description:
//  This is the top-level module for Aquila's debug system.
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
module dm_top #(
  parameter                     BusWidth         = 32,
  parameter                     DmBaseAddress    = 'h1000
) (
  // system signals
  input                         clk_i,        // system clock
  input                         rst_ni,       // asynchronous reset
  // debug signals
  input                         testmode_i,   // Not used
  output                        ndmreset_o,   // non-debug module reset
  output                        dmactive_o,   // debug module is active
  output                        debug_req_o,  // async debug request
  input                         unavailable_i,// core is unavailalble
  // memory interface
  input                         slave_req_i,  
  input                         slave_we_i,
  input        [BusWidth-1:0]   slave_addr_i,
  input        [BusWidth/8-1:0] slave_be_i,
  input        [BusWidth-1:0]   slave_wdata_i,
  output       [BusWidth-1:0]   slave_rdata_o
);

  localparam                        ProgBufSize = 8;
  localparam                        DataCount   = 2;
  // debug CSRs
  // core control and status 
  wire                              halted;         // core is halted
  wire                              resumeack;      // core acked the resume request
  wire                              haltreq;        // halt request to core
  wire                              resumereq;      // resume request to core
  wire                              clear_resumeack;// ask core to clear resume request
  // abstract command control and status
  wire                              cmd_valid;      // command is valid
  wire  [31:0]                      cmd;            // abstract command
  wire                              cmderror_valid; // error occur in command 
  wire  [2:0]                       cmderror;       // kind of error
  wire                              cmdbusy;        // busy executing abstract command
  // memory signals
  wire  [ProgBufSize*32-1:0]        progbuf;        // program buffer
  wire  [DataCount*32-1:0]          data_csrs_mem;  // data from debug CSRs
  wire  [DataCount*32-1:0]          data_mem_csrs;  // data from debug memory
  wire                              data_valid;     // data is valid to read
  // control signals
  wire                              ndmreset;       // non-debug module reset
  wire  [19:0]                      hartsel;        // core selection (can only be 0)

  wire                              dmi_rst_n;      // debug module interface reset (active low)
  // debug request
  wire                              dmi_req_valid;
  wire                              dmi_req_ready;
  wire  [40:0]                      dmi_req;
  // debug response
  wire                              dmi_resp_valid;
  wire                              dmi_resp_ready;
  wire  [33:0]                      dmi_resp;

  assign ndmreset_o = ndmreset;

  dm_csrs #(
    .BusWidth(BusWidth)
  ) i_dm_csrs (
    .clk_i                   ( clk_i                 ),
    .rst_ni                  ( rst_ni                ),
    .testmode_i              ( testmode_i            ),
    .dmi_rst_ni              ( dmi_rst_n             ),
    .dmi_req_valid_i         ( dmi_req_valid         ),
    .dmi_req_ready_o         ( dmi_req_ready         ),
    .dmi_req_i               ( dmi_req               ),
    .dmi_resp_valid_o        ( dmi_resp_valid        ),
    .dmi_resp_ready_i        ( dmi_resp_ready        ),
    .dmi_resp_o              ( dmi_resp              ),
    .ndmreset_o              ( ndmreset              ),
    .dmactive_o              ( dmactive_o            ),
    .hartsel_o               ( hartsel               ),
    .halted_i                ( halted                ),
    .unavailable_i           ( unavailable_i         ),
    .resumeack_i             ( resumeack             ),
    .haltreq_o               ( haltreq               ),
    .resumereq_o             ( resumereq             ),
    .clear_resumeack_o       ( clear_resumeack       ),
    .cmd_valid_o             ( cmd_valid             ),
    .cmd_o                   ( cmd                   ),
    .cmderror_valid_i        ( cmderror_valid        ),
    .cmderror_i              ( cmderror              ),
    .cmdbusy_i               ( cmdbusy               ),
    .progbuf_o_flatten       ( progbuf               ),
    .data_i_flatten          ( data_mem_csrs         ),
    .data_valid_i            ( data_valid            ),
    .data_o_flatten          ( data_csrs_mem         )
  );

  dm_mem #(
    .BusWidth(BusWidth),
    .DmBaseAddress(DmBaseAddress)
  ) i_dm_mem (
    .clk_i                   ( clk_i                 ),
    .rst_ni                  ( rst_ni                ),
    .debug_req_o             ( debug_req_o           ),
    .ndmreset_i              ( ndmreset              ),
    .hartsel_i               ( hartsel               ),
    .haltreq_i               ( haltreq               ),
    .resumereq_i             ( resumereq             ),
    .clear_resumeack_i       ( clear_resumeack       ),
    .halted_o                ( halted                ),
    .resuming_o              ( resumeack             ),
    .cmd_valid_i             ( cmd_valid             ),
    .cmd_i                   ( cmd                   ),
    .cmderror_valid_o        ( cmderror_valid        ),
    .cmderror_o              ( cmderror              ),
    .cmdbusy_o               ( cmdbusy               ),
    .progbuf_i_flatten       ( progbuf               ),
    .data_i_flatten          ( data_csrs_mem         ),
    .data_o_flatten          ( data_mem_csrs         ),
    .data_valid_o            ( data_valid            ),
    .req_i                   ( slave_req_i           ),
    .we_i                    ( slave_we_i            ),
    .addr_i                  ( slave_addr_i          ),
    .wdata_i                 ( slave_wdata_i         ),
    .be_i                    ( slave_be_i            ),
    .rdata_o                 ( slave_rdata_o         )
  );

  dmi_jtag i_dmi_jtag (
    .clk_i                  ( clk_i             ),
    .rst_ni                 ( rst_ni            ),
    .testmode_i             ( testmode_i        ),

    .dmi_rst_no             ( dmi_rst_n         ),

    .dmi_req_o              ( dmi_req           ),
    .dmi_req_valid_o        ( dmi_req_valid     ),
    .dmi_req_ready_i        ( dmi_req_ready     ),

    .dmi_resp_i             ( dmi_resp          ),
    .dmi_resp_valid_i       ( dmi_resp_valid    ),
    .dmi_resp_ready_o       ( dmi_resp_ready    )
  );
endmodule