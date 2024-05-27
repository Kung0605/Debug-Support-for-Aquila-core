module dmi_jtag (
  input           clk_i,      // DMI Clock
  input           rst_ni,     // Asynchronous reset active low
  input           testmode_i,

  // active-low glitch free reset signal. Is asserted for one dmi clock cycle
  // (clk_i) whenever the dmi_jtag is reset (POR or functional reset).
  output          dmi_rst_no,
  output [40:0]   dmi_req_o,
  output          dmi_req_valid_o,
  input           dmi_req_ready_i,

  input  [33:0]   dmi_resp_i,
  output          dmi_resp_ready_o,
  input           dmi_resp_valid_i
);
  localparam  DTM_NOP   = 0,
              DTM_READ  = 1,
              DTM_WRITE = 2;
  localparam  DTM_SUCCESS = 0,
              DTM_ERR     = 2,
              DTM_BUSY    = 3;
  localparam  DMINoError       = 2'h0, 
              DMIReservedError = 2'h1,
              DMIOPFailed      = 2'h2, 
              DMIBusy          = 2'h3;
  reg [1:0] error_d, error_q;

  wire tck;
  wire jtag_dmi_clear; // Synchronous reset of DMI triggered by TestLogicReset in
                        // jtag TAP
  wire dmi_clear; // Functional (warm) reset of the entire DMI
  wire update;
  wire capture;
  wire shift;
  wire tdi;

  wire dtmcs_select;

  wire trst_n;
  reg [31:0] dtmcs_d, dtmcs_q;
  assign dmi_clear = jtag_dmi_clear || (dtmcs_select && update && dtmcs_q[17]/*hardreset*/);
  assign trst_n = 1'b1; // force to not reset DTM  
  // -------------------------------
  // Debug Module Control and Status
  // -------------------------------


  always @(*) begin
    dtmcs_d = dtmcs_q;
    if (capture) begin
      if (dtmcs_select) begin
        dtmcs_d[31:18] = 0;
        dtmcs_d[17]    = 0;
        dtmcs_d[16]    = 0;
        dtmcs_d[15]    = 0;
        dtmcs_d[14:12] = 3'd1;    // idle: 1: Enter Run-Test/Idle and leave it immediately
        dtmcs_d[11:10] = error_q; // dmistat: 0: No error, 2: Op failed, 3: too fast
        dtmcs_d[9:4]   = 6'd7;    // abits: The size of address in dmi
        dtmcs_d[3:0]   = 4'd1;    // debug spec 0.13
      end
    end

    if (shift) begin
      if (dtmcs_select) begin 
          dtmcs_d  = {tdi, dtmcs_q[31:1]};
      end
    end
  end

  always @(posedge tck or negedge trst_n) begin
    if (!trst_n) begin
      dtmcs_q <= 0;
    end else begin
      dtmcs_q <= dtmcs_d;
    end
  end

  // ----------------------------
  // DMI (Debug Module Interface)
  // ----------------------------

  wire          dmi_select;
  wire          dmi_tdo;

  wire [40:0]   dmi_req;
  wire          dmi_req_ready;
  reg           dmi_req_valid;

  wire [33:0]   dmi_resp;
  wire          dmi_resp_valid;
  wire          dmi_resp_ready;

  // typedef struct packed {
  //   logic [6:0]  address;
  //   logic [31:0] data;
  //   logic [1:0]  op;
  // } dmi_t;
  localparam  Idle           = 0,
              Read           = 1,
              WaitReadValid  = 2,
              Write          = 3,
              WaitWriteValid = 4;
  reg [2:0] state_d, state_q;

  reg   [40:0] dr_d, dr_q;
  reg   [6:0]  address_d, address_q;
  reg   [31:0] data_d, data_q;

  wire  [40:0] dmi;
  assign dmi            = dr_q;
  assign dmi_req[40:34] = address_q;
  assign dmi_req[31:0]  = data_q;
  assign dmi_req[33:32] = (state_q == Write) ? DTM_WRITE : DTM_READ;
  // We will always be ready to accept the data we requested.
  assign dmi_resp_ready = 1'b1;

  reg    error_dmi_busy;
  reg    error_dmi_op_failed;

  always @(*) begin
    error_dmi_busy = 1'b0;
    error_dmi_op_failed = 1'b0;
    // default assignments
    state_d   = state_q;
    address_d = address_q;
    data_d    = data_q;
    error_d   = error_q;

    dmi_req_valid = 1'b0;

    if (dmi_clear) begin
      state_d   = Idle;
      data_d    = 0;
      error_d   = DMINoError;
      address_d = 0;
    end else begin
      case (state_q)
        Idle: begin
          // make sure that no error is sticky
          if (dmi_select && update && (error_q == DMINoError)) begin
            // save address and value
            address_d = dmi[40:34];
            data_d = dmi[33:2];
            if (dmi[1:0] == DTM_READ) begin
              state_d = Read;
            end else if (dmi[1:0] == DTM_WRITE) begin
              state_d = Write;
            end
            // else this is a nop and we can stay here
          end
        end

        Read: begin
          dmi_req_valid = 1'b1;
          if (dmi_req_ready) begin
            state_d = WaitReadValid;
          end
        end

        WaitReadValid: begin
          // load data into register and shift out
          if (dmi_resp_valid) begin
            case (dmi_resp[1:0])
              DTM_SUCCESS: begin
                data_d = dmi_resp[33:2];
              end
              DTM_ERR: begin
                data_d = 32'hDEAD_BEEF;
                error_dmi_op_failed = 1'b1;
              end
              DTM_BUSY: begin
                data_d = 32'hB051_B051;
                error_dmi_busy = 1'b1;
              end
              default: begin
                data_d = 32'hBAAD_C0DE;
              end
            endcase
            state_d = Idle;
          end
        end

        Write: begin
          dmi_req_valid = 1'b1;
          // request sent, wait for response before going back to idle
          if (dmi_req_ready) begin
            state_d = WaitWriteValid;
          end
        end

        WaitWriteValid: begin
          // got a valid answer go back to idle
          if (dmi_resp_valid) begin
            case (dmi_resp[1:0])
              DTM_ERR: error_dmi_op_failed = 1'b1;
              DTM_BUSY: error_dmi_busy = 1'b1;
              default: ;
            endcase
            state_d = Idle;
          end
        end

        default: begin
          // just wait for idle here
          if (dmi_resp_valid) begin
            state_d = Idle;
          end
        end
      endcase

      // update means we got another request but we didn't finish
      // the one in progress, this state is sticky
      if (update && state_q != Idle) begin
        error_dmi_busy = 1'b1;
      end

      // if capture goes high while we are in the read state
      // or in the corresponding wait state we are not giving back a valid word
      // -> throw an error
      if (capture && ((state_q == Read) || (state_q ==  WaitReadValid))) begin
        error_dmi_busy = 1'b1;
      end

      if (error_dmi_busy && error_q == DMINoError) begin
        error_d = DMIBusy;
      end

      if (error_dmi_op_failed && error_q == DMINoError) begin
        error_d = DMIOPFailed;
      end

      // clear sticky error flag
      if (update && dtmcs_q[16]/*dmireset*/ && dtmcs_select) begin
        error_d = DMINoError;
      end
    end
  end

  // shift register
  assign dmi_tdo = dr_q[0];

  always @(*) begin
    dr_d    = dr_q;
    if (dmi_clear) begin
      dr_d = 0;
    end else begin
      if (capture) begin
        if (dmi_select) begin
          if (error_q == DMINoError && !error_dmi_busy) begin
            dr_d = {address_q, data_q, DMINoError};
            // DMI was busy, report an error
          end else if (error_q == DMIBusy || error_dmi_busy) begin
            dr_d = {address_q, data_q, DMIBusy};
          end
        end
      end

      if (shift) begin
        if (dmi_select) begin
          dr_d = {tdi, dr_q[40:1]};
        end
      end
    end
  end

  always @(posedge tck or negedge trst_n) begin
    if (!trst_n) begin
      dr_q      <= 0;
      state_q   <= Idle;
      address_q <= 0;
      data_q    <= 0;
      error_q   <= DMINoError;
    end else begin
      dr_q      <= dr_d;
      state_q   <= state_d;
      address_q <= address_d;
      data_q    <= data_d;
      error_q   <= error_d;
    end
  end

  // ---------
  // TAP
  // ---------

  dmi_jtag_tap i_dmi_jtag_tap (
    .tck_o          ( tck              ),
    .dmi_clear_o    ( jtag_dmi_clear   ),
    .update_o       ( update           ),
    .capture_o      ( capture          ),
    .shift_o        ( shift            ),
    .tdi_o          ( tdi              ),
    .dtmcs_select_o ( dtmcs_select     ),
    .dtmcs_tdo_i    ( dtmcs_q[0]       ),
    .dmi_select_o   ( dmi_select       ),
    .dmi_tdo_i      ( dmi_tdo          )
  );

  // ---------
  // CDC
  // ---------
  dmi_cdc i_dmi_cdc (
    // JTAG side (master side)
    .tck_i                ( tck              ),
    .trst_ni              ( trst_n           ),
    .jtag_dmi_cdc_clear_i ( dmi_clear        ),
    .jtag_dmi_req_i       ( dmi_req          ),
    .jtag_dmi_ready_o     ( dmi_req_ready    ),
    .jtag_dmi_valid_i     ( dmi_req_valid    ),
    .jtag_dmi_resp_o      ( dmi_resp         ),
    .jtag_dmi_valid_o     ( dmi_resp_valid   ),
    .jtag_dmi_ready_i     ( dmi_resp_ready   ),
    // core side
    .clk_i                ( clk_i            ),
    .rst_ni               ( rst_ni           ),
    .core_dmi_rst_no      ( dmi_rst_no       ),
    .core_dmi_req_o       ( dmi_req_o        ),
    .core_dmi_valid_o     ( dmi_req_valid_o  ),
    .core_dmi_ready_i     ( dmi_req_ready_i  ),
    .core_dmi_resp_i      ( dmi_resp_i       ),
    .core_dmi_ready_o     ( dmi_resp_ready_o ),
    .core_dmi_valid_i     ( dmi_resp_valid_i )
  );

endmodule