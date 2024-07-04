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
  reg                               dmi_req_valid;
  wire                              dmi_req_ready;
  reg  [40:0]                       dmi_req;
  // wire                              dmi_req_valid;
  // wire                              dmi_req_ready;
  // wire  [40:0]                      dmi_req;
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

  // dmi_jtag i_dmi_jtag (
  //   .clk_i                  ( clk_i             ),
  //   .rst_ni                 ( rst_ni            ),
  //   .testmode_i             ( testmode_i        ),

  //   .dmi_rst_no             ( dmi_rst_n         ),

  //   .dmi_req_o              ( dmi_req           ),
  //   .dmi_req_valid_o        ( dmi_req_valid     ),
  //   .dmi_req_ready_i        ( dmi_req_ready     ),

  //   .dmi_resp_i             ( dmi_resp          ),
  //   .dmi_resp_valid_i       ( dmi_resp_valid    ),
  //   .dmi_resp_ready_o       ( dmi_resp_ready    )
  // );
  initial begin 
    #150050
    dmi_req = {8'h10, 2'h2, 32'h40000001};
    dmi_req_valid = 1;
    #50
    dmi_req_valid = 0;
    #10000
    dmi_req = {8'h10, 2'h2, 32'h40000001};
    dmi_req_valid = 1;
    #50
    dmi_req_valid = 0;
    #10000
    dmi_req = {8'h10, 2'h2, 32'h40000001};
    dmi_req_valid = 1;
    #50
    dmi_req_valid = 0;
    #10000
    dmi_req = {8'h10, 2'h2, 32'h40000001};
    dmi_req_valid = 1;
    #50
    dmi_req_valid = 0;
    
  end

endmodule