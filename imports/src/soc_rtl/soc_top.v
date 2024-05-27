`timescale 1ns / 1ps
// =============================================================================
//  Program : soc_top.v
//  Author  : Chun-Jen Tsai
//  Date    : Feb/16/2020
// -----------------------------------------------------------------------------
//  Description:
//  This is the top-level Aquila IP wrapper for an AXI-based processor SoC.
// -----------------------------------------------------------------------------
//  Revision information:
//
//  This module is based on the soc_top.v module written by Jin-you Wu
//  on Feb/28/2019. The original module was a stand-alone top-level module
//  for an SoC. This rework makes it a module embedded inside an AXI IP.
//
//  Jan/12/2020, by Chun-Jen Tsai:
//    Added a on-chip Tightly-Coupled Memory (TCM) to the aquila SoC.
//
//  Sep/12/2022, by Chun-Jen Tsai:
//    Fix an issue of missing reset signal across clock domains.
//    Use the clock wizard to generate the Aquila clock on Arty.
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
`include "aquila_config.vh"

module soc_top #( parameter XLEN = 32, parameter CLSIZE = `CLP )
(
    input           sysclk_i,
    input           resetn_i,

    // uart
    input           uart_rx,
    output          uart_tx,

    // buttons & leds
    input  [0 : `USRP-1]  usr_btn,
    output [0 : `USRP-1]  usr_led,
    
    //JTAG 
    input TMS,
    input TCK,
    input TDI_FPGA,
    input TDO_FPGA
);

wire usr_reset;
wire clk, rst;

// --------- External memory interface -----------------------------------------
// Instruction memory ports (Not used for HW#0 ~ HW#2)
wire                IMEM_strobe;
wire [XLEN-1 : 0]   IMEM_addr;
wire                IMEM_done = 0;
wire [CLSIZE-1 : 0] IMEM_data = {CLSIZE{1'b0}};


// Data memory ports (Not used for HW#0 ~ HW#2)
wire                DMEM_strobe;
wire [XLEN-1 : 0]   DMEM_addr;
wire                DMEM_rw;
wire [CLSIZE-1 : 0] DMEM_wt_data;
wire                DMEM_done = 0;
wire [CLSIZE-1 : 0] DMEM_rd_data = {CLSIZE{1'b0}};

// --------- I/O device interface ----------------------------------------------
// Device bus signals
wire                dev_strobe;
wire [XLEN-1 : 0]   dev_addr;
wire                dev_we;
wire [XLEN/8-1 : 0] dev_be;
wire [XLEN-1 : 0]   dev_din;
wire [XLEN-1 : 0]   dev_dout;
wire                dev_ready;

// DSA device signals (Not used for HW#0 ~ HW#4)
wire                dsa_sel;
wire [XLEN-1 : 0]   dsa_dout;
wire                dsa_ready;

// Uart
wire                uart_sel;
wire [XLEN-1 : 0]   uart_dout;
wire                uart_ready;

// Debug Module signals
wire                dm_sel;
wire [XLEN-1 : 0]   dm_dout;
wire                dm_ready;

// ----------------------------------------------------------------------------
//  Debug Module signals
// 
//////////////////////////////////////////////// 
wire rst_ni;
assign rst_ni = resetn_i;

wire                test_en;
wire                ndmreset;
wire                dmactive;
wire                debug_req;
wire                unavailable;

wire                debug_strobe;

wire        dm_device_req;
wire [31:0] dm_device_addr;
wire        dm_device_we;
wire [ 3:0] dm_device_be;
wire [31:0] dm_device_wdata;
reg         dm_device_rvalid;
wire [31:0] dm_device_rdata;

// Device signals.
localparam  NrDevices = 3;
localparam  NrHosts   = 2;
// Host signals.
wire        host_req      [NrHosts-1:0];
reg         host_gnt      [NrHosts-1:0];
wire [31:0] host_addr     [NrHosts-1:0];
wire        host_we       [NrHosts-1:0];
wire [ 3:0] host_be       [NrHosts-1:0];
wire [31:0] host_wdata    [NrHosts-1:0];
reg         host_rvalid   [NrHosts-1:0];
reg  [31:0] host_rdata    [NrHosts-1:0];
wire        host_err      [NrHosts-1:0];
// Device signals.
wire        device_req    [NrDevices-1:0];
wire [31:0] device_addr   [NrDevices-1:0];
wire        device_we     [NrDevices-1:0];
wire [ 3:0] device_be     [NrDevices-1:0];
wire [31:0] device_wdata  [NrDevices-1:0];
wire        device_rvalid [NrDevices-1:0];
wire [31:0] device_rdata  [NrDevices-1:0];
wire        device_err    [NrDevices-1:0];

wire mem_instr_req;
wire dm_instr_req;
reg  core_instr_sel_dbg;
reg  core_instr_rvalid;
////////////////////////////////////////////////
// --------- System Clock Generator --------------------------------------------
// Generates a 41.66667 MHz system clock from the 100MHz oscillator on the PCB.
assign usr_reset = ~resetn_i;

clk_wiz_0 Clock_Generator(
    .clk_in1(sysclk_i),  // Board oscillator clock
    .clk_out1(clk)       // System clock for the Aquila SoC
);

// -----------------------------------------------------------------------------
// Synchronize the system reset signal (usr_reset) across the clock domains
//   to the Aquila SoC domains (rst).
//
// For the Aquila Core, the reset (rst) should lasts for at least 5 cycles
//   to initialize all the pipeline registers.
//
localparam SR_N = 8;
reg [SR_N-1:0] sync_reset = {SR_N{1'b1}};
assign rst = sync_reset[SR_N-1];

always @(posedge clk) begin
    if (usr_reset)
        sync_reset <= {SR_N{1'b1}};
    else
        sync_reset <= {sync_reset[SR_N-2 : 0], 1'b0};
end

// debug memory
wire               debug_mem_req;
wire [XLEN-1:0]    debug_mem_addr;
wire               debug_mem_ready;
wire [XLEN-1:0]    debug_mem_rdata;

// -----------------------------------------------------------------------------
//  Aquila processor core.
//
aquila_top Aquila_SoC
(
    .clk_i(clk),
    .rst_i(rst | ndmreset),          // level-sensitive reset signal.
    .base_addr_i(32'b0),  // initial program counter.

    // External instruction memory ports.
    .M_IMEM_strobe_o(IMEM_strobe),
    .M_IMEM_addr_o(IMEM_addr),
    .M_IMEM_done_i(IMEM_done),
    .M_IMEM_data_i(IMEM_data),

    // External data memory ports.
    .M_DMEM_strobe_o(DMEM_strobe),
    .M_DMEM_addr_o(DMEM_addr),
    .M_DMEM_rw_o(DMEM_rw),
    .M_DMEM_data_o(DMEM_wt_data),
    .M_DMEM_done_i(DMEM_done),
    .M_DMEM_data_i(DMEM_rd_data),

    // I/O device ports.
    .M_DEVICE_strobe_o(dev_strobe),
    .M_DEVICE_addr_o(dev_addr),
    .M_DEVICE_rw_o(dev_we),
    .M_DEVICE_byte_enable_o(dev_be),
    .M_DEVICE_data_o(dev_din),
    .M_DEVICE_data_ready_i(dev_ready),
    .M_DEVICE_data_i(dev_dout),

    // Debug Signals.
    .debug_req_i(debug_req),
    .debug_strobe_i(debug_strobe),

    .debug_mem_req_o(debug_mem_req),
    .debug_mem_addr_o(debug_mem_addr),
    .debug_mem_rdata_i(debug_mem_rdata),
    .debug_mem_ready_i(debug_mem_ready)
);

// -----------------------------------------------------------------------------
//  Device address decoder.
//
//       [0] 0xC000_0000 - 0xC0FF_FFFF : UART device
//       [1] 0xC200_0000 - 0xC2FF_FFFF : DSA device
//       [2] 0xCD00_0000 - 0xCDFF_FFFF : Debug Memory
`ifdef DEBUG
assign uart_sel  = (dev_addr[XLEN-1:XLEN-8] == 8'hC0);
assign dsa_sel   = (dev_addr[XLEN-1:XLEN-8] == 8'hC2);
assign dm_sel    = (dev_addr[XLEN-1:XLEN-8] == 8'hCD);
assign dev_dout  = (dm_sel)? dm_device_rdata : (uart_sel)? uart_dout : (dsa_sel)? dsa_dout : {XLEN{1'b0}};
assign dev_ready = (dm_sel)? dm_device_rvalid : (uart_sel)? uart_ready : (dsa_sel)? dsa_ready : {XLEN{1'b0}};
`else  
assign uart_sel  = (dev_addr[XLEN-1:XLEN-8] == 8'hC0);
assign dsa_sel   = (dev_addr[XLEN-1:XLEN-8] == 8'hC2); 
assign dev_dout  = (uart_sel)? uart_dout : (dsa_sel)? dsa_dout : {XLEN{1'b0}};
assign dev_ready = (uart_sel)? uart_ready : (dsa_sel)? dsa_ready : {XLEN{1'b0}};
`endif
// ----------------------------------------------------------------------------
//  UART Controller with a simple memory-mapped I/O interface.
//
`define BAUD_RATE	115200

uart #(.BAUD(`SOC_CLK/`BAUD_RATE))
UART(
    .clk(clk),
    .rst(rst),

    .EN(dev_strobe & uart_sel),
    .ADDR(dev_addr[3:2]),
    .WR(dev_we),
    .BE(dev_be),
    .DATAI(dev_din),
    .DATAO(uart_dout),
    .READY(uart_ready),

    .RXD(uart_rx),
    .TXD(uart_tx)
);
wire               dm_host_req;
wire [XLEN-1:0]    dm_host_add;
wire               dm_host_we;
wire [XLEN-1:0]    dm_host_wdata;
wire [XLEN/8-1:0]  dm_host_be;
wire               dm_host_gnt;
wire               dm_host_r_valid;
wire [XLEN-1:0]    dm_host_r_rdata;


// --------------------------------------
// localparam NB_PERIPHERALS = Debug + 1;
assign unavailable = 1'b0;
assign test_en = 1'b0;
localparam DbgDev = 2;
wire [31:0] MEM_SIZE      = 64 * 1024; // 64 KiB
wire [31:0] MEM_START     = 32'h00000000;
wire [31:0] MEM_MASK      = ~(MEM_SIZE-1);

wire [31:0] DEBUG_SIZE    = 64 * 1024; // 64 KiB
wire [31:0] DEBUG_START   = 32'hCD000000;
wire [31:0] DEBUG_MASK    = ~(DEBUG_SIZE-1);


assign mem_instr_req = IMEM_strobe &((IMEM_addr & MEM_MASK) == MEM_START);

assign dm_instr_req  = debug_mem_req;

assign debug_mem_ready = mem_instr_req | (dm_instr_req & ~device_req[DbgDev]);
assign debug_mem_rdata = dm_device_rdata;
///////////////////////////////////////////////////////////////////////////////////////////////
assign device_req[DbgDev]   = dev_strobe & dm_sel;
assign device_addr[DbgDev]  = dev_addr;
assign device_we[DbgDev]    = dev_we;
assign device_be[DbgDev]    = dev_be;
assign device_wdata[DbgDev] = dev_din;

assign dm_device_req        = device_req[DbgDev] | dm_instr_req;
assign dm_device_we         = device_req[DbgDev] & device_we[DbgDev];
assign dm_device_addr       = device_req[DbgDev] ? device_addr[DbgDev] : debug_mem_addr;
assign dm_device_be         = device_be[DbgDev];
assign dm_device_wdata      = device_wdata[DbgDev];
assign device_rvalid[DbgDev] = dm_device_rvalid;
assign device_rdata[DbgDev]  = dm_device_rdata;
///////////////////////////////////////////////////////////////////////////////////////////////
always @(posedge clk or negedge rst_ni) begin
    if (~rst_ni) begin
      dm_device_rvalid <= 1'b0;
    end else begin
      dm_device_rvalid <= device_req[DbgDev];
    end
end

// dm_top
dm_top # (
    .NrHarts              ( 1                 ),
    .BusWidth             ( XLEN              ),
    .DmBaseAddress        ( `DmBaseAddress    ),
    .SelectableHarts      ( 1'b1              )
) i_dm_top (
    .clk_i                ( clk               ),
    .rst_ni               ( rst_ni            ),

    .testmode_i           ( test_en           ),
    .ndmreset_o           ( ndmreset          ),
    .dmactive_o           ( dmactive          ),
    .debug_req_o          ( debug_req         ),
    .unavailable_i        ( 32'b0             ),

    .slave_req_i          ( dm_device_req     ),
    .slave_we_i           ( dm_device_we      ),
    .slave_addr_i         ( dm_device_addr    ),
    .slave_be_i           ( dm_device_be      ),
    .slave_wdata_i        ( dm_device_wdata   ),
    .slave_rdata_o        ( dm_device_rdata   ),

    .master_req_o           ( dm_host_req       ),
    .master_add_o           ( dm_host_add       ),
    .master_we_o            ( dm_host_we        ),
    .master_wdata_o         ( dm_host_wdata     ),
    .master_be_o            ( dm_host_be        ), 
    .master_gnt_i           ( dm_host_gnt       ),
    .master_r_valid_i       ( dm_host_r_valid   ),
    .master_r_err_i         (                   ),
    .master_r_other_err_i   (                   ),
    .master_r_rdata_i       ( dm_host_r_rdata   )
);

reg debug_req_prev;
always @(posedge clk or negedge rst_ni) begin
    if (~rst_ni) begin
        debug_req_prev <= 1'b0;
    end else begin
        debug_req_prev <= debug_req;
    end
end

assign debug_strobe = debug_req & ~debug_req_prev;

assign dm_dout = dm_device_rdata;
assign dm_ready = dm_device_rvalid;
endmodule