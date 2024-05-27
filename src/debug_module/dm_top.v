module dm_top #(
  parameter                     NrHarts          = 1,
  parameter                     BusWidth         = 32,
  parameter                     DmBaseAddress    = 'h1000, // default to non-zero page
  // Bitmask to select physically available harts for systems
  // that don't use hart numbers in a contiguous fashion.
  parameter                     SelectableHarts  = 1,
  // toggle new behavior to drive master_be_o during a read
  parameter                     ReadByteEnable   = 1
) (
  input                         clk_i,       // clock
  // asynchronous reset active low, connect PoR here, not the system reset
  input                         rst_ni,
  input                         testmode_i,
  output                        ndmreset_o,  // non-debug module reset
  output                        dmactive_o,  // debug module is active
  output       [NrHarts-1:0]    debug_req_o, // async debug request
  // communicate whether the hart is unavailable (e.g.: power down)
  input        [NrHarts-1:0]    unavailable_i,

  input                         slave_req_i,
  input                         slave_we_i,
  input        [BusWidth-1:0]   slave_addr_i,
  input        [BusWidth/8-1:0] slave_be_i,
  input        [BusWidth-1:0]   slave_wdata_i,
  output       [BusWidth-1:0]   slave_rdata_o
);

  localparam                        ProgBufSize = 8;
  localparam                        DataCount   = 2;
  // Debug CSRs
  wire  [NrHarts-1:0]               halted;
  // logic [NrHarts-1:0]               running;
  wire  [NrHarts-1:0]               resumeack;
  wire  [NrHarts-1:0]               haltreq;
  wire  [NrHarts-1:0]               resumereq;
  wire                              clear_resumeack;
  wire                              cmd_valid;
  wire  [31:0]                      cmd;

  wire                              cmderror_valid;
  wire  [2:0]                       cmderror;
  wire                              cmdbusy;
  wire  [ProgBufSize*32-1:0]        progbuf;
  wire  [DataCount*32-1:0]          data_csrs_mem;
  wire  [DataCount*32-1:0]          data_mem_csrs;
  wire                              data_valid;
  wire                              ndmreset;
  wire  [19:0]                      hartsel;

  wire                              dmi_rst_n;

  wire                              dmi_req_valid;
  wire                              dmi_req_ready;
  wire  [40:0]                      dmi_req;
  // reg                               dmi_req_valid;
  // wire                              dmi_req_ready;
  // reg   [40:0]                      dmi_req;

  wire                              dmi_resp_valid;
  wire                              dmi_resp_ready;
  wire  [33:0]                      dmi_resp;

  assign ndmreset_o = ndmreset;

  dm_csrs #(
    .NrHarts(NrHarts),
    .BusWidth(BusWidth),
    .SelectableHarts(SelectableHarts)
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
    .NrHarts(NrHarts),
    .BusWidth(BusWidth),
    .SelectableHarts(SelectableHarts),
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
  // initial begin 
  // #0
  // dmi_req_valid = 0;
  // dmi_req = 0;
  // #250
  // dmi_req_valid = 1;
  // dmi_req = {8'h10, 2'h2, 32'h80000001};
  // #50 
  // dmi_req_valid = 0;
  // #500
  // dmi_req_valid = 1;
  // dmi_req = {8'h10, 2'h2, 32'h40000001};
  // #50
  // dmi_req_valid = 0;
  // #500
  // dmi_req_valid = 1;
  // dmi_req = {8'h10, 2'h2, 32'h40000001};
  // #50
  // dmi_req_valid = 0;
  // end
endmodule