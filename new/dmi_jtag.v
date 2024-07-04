module dmi_jtag (
    input           clk_i,          // DMI Clock
    input           rst_ni,         // Asynchronous reset active low
    input           testmode_i,     // Not used
    output          dmi_rst_no,     // indicate debug module interface has reset
    // debug request to debug CSRs
    output [40:0]   dmi_req_o,
    output          dmi_req_valid_o,
    input           dmi_req_ready_i,
    // debug response from debug CSRs
    input  [33:0]   dmi_resp_i,
    output          dmi_resp_ready_o,
    input           dmi_resp_valid_i
  );
  // Debug transport module option
  localparam  DTM_NOP   = 0,
              DTM_READ  = 1,
              DTM_WRITE = 2;
  // Debug transport module status
  localparam  DTM_SUCCESS = 0,
              DTM_ERR     = 2,
              DTM_BUSY    = 3;
  // Debug module interface status
  localparam  DMINoError       = 2'h0,
              DMIReservedError = 2'h1,
              DMIOPFailed      = 2'h2,
              DMIBusy          = 2'h3;
  reg [1:0] error_d, error_q;

  wire dmi_clear;      // Functional (warm) reset of the entire DMI
  wire jtag_dmi_clear; // Synchronous reset of DMI triggered by TestLogicReset in
  // jtag TAP

  // JTAG control signals
  wire tck;
  wire update;
  wire capture;
  wire shift;
  wire tdi;
  wire trst_n;

  wire dtmcs_select;
  // Debug transport module CSRs
  reg [31:0] dtmcs_d, dtmcs_q;
  assign dmi_clear = jtag_dmi_clear || (dtmcs_select && update && dtmcs_q[17]/*hardreset*/);
  assign trst_n = 1'b1; // force to not reset DTM

  always @(*) begin
    dtmcs_d = dtmcs_q;            // default assignment
    if (capture) begin
      if (dtmcs_select) begin
        dtmcs_d[31:15] = 0;
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
    end
    else begin
      dtmcs_q <= dtmcs_d;
    end
  end

  // Access debug module CSRs
  wire          dmi_select;
  wire          dmi_tdo;
  // debug request
  wire [40:0]   dmi_req;
  wire          dmi_req_ready;
  reg           dmi_req_valid;
  // debug response
  wire [33:0]   dmi_resp;
  wire          dmi_resp_valid;
  wire          dmi_resp_ready;

  // debug module interface state
  localparam  Idle           = 0,
              Read           = 1,
              WaitReadValid  = 2,
              Write          = 3,
              WaitWriteValid = 4;

  reg [2:0] state_d, state_q;

  // data register
  reg   [40:0] dr_d, dr_q;
  reg   [6:0]  address_d, address_q;
  reg   [31:0] data_d, data_q;
  // actual debug request sent to host debugger
  wire  [40:0] dmi;
  assign dmi            = dr_q;
  assign dmi_req[40:34] = address_q;
  assign dmi_req[31:0]  = data_q;
  assign dmi_req[33:32] = (state_q == Write) ? DTM_WRITE : DTM_READ;
  // can always read data which is requested
  assign dmi_resp_ready = 1'b1;
  // debug module interface error signals
  reg    error_dmi_busy;
  reg    error_dmi_op_failed;

  // JTAG control logic
  always @(*) begin
    // default assignments
    error_dmi_busy = 1'b0;
    error_dmi_op_failed = 1'b0;
    
    state_d   = state_q;
    address_d = address_q;
    data_d    = data_q;
    error_d   = error_q;

    dmi_req_valid = 1'b0;

    // reset debug module interface
    if (dmi_clear) begin
      state_d   = Idle;
      data_d    = 0;
      error_d   = DMINoError;
      address_d = 0;
    end
    else begin
      case (state_q)
        Idle: begin
          // check if ther is an error
          if (dmi_select && update && (error_q == DMINoError)) begin
            // assign request address and data
            address_d = dmi[40:34];
            data_d = dmi[33:2];
            if (dmi[1:0] == DTM_READ) begin
              // operation is read 
              state_d = Read;
            end
            else if (dmi[1:0] == DTM_WRITE) begin
              // operation is write
              state_d = Write;
            end
          end
        end

        Read: begin
          // debug request is valid to read
          dmi_req_valid = 1'b1;
          if (dmi_req_ready) begin
            state_d = WaitReadValid;
          end
        end

        WaitReadValid: begin
          if (dmi_resp_valid) begin
            // debug response is valid to return
            case (dmi_resp[1:0])
              DTM_SUCCESS: begin
                // request cuccess
                data_d = dmi_resp[33:2];
              end
              DTM_ERR: begin
                // error occur in request
                data_d = 32'hDEAD_BEEF;
                error_dmi_op_failed = 1'b1;
              end
              DTM_BUSY: begin
                // debug module is busy
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
          // debug request is valid to read
          dmi_req_valid = 1'b1;
          if (dmi_req_ready) begin
            state_d = WaitWriteValid;
          end
        end

        WaitWriteValid: begin
          // debug response is valid to return
          if (dmi_resp_valid) begin
            case (dmi_resp[1:0])
              DTM_ERR: 
                error_dmi_op_failed = 1'b1; // error occur
              DTM_BUSY:
                error_dmi_busy = 1'b1;      // debug module is busy
              default:
                ;                           // avoid error
            endcase
            state_d = Idle;
          end
        end

        default: begin 
          if (dmi_resp_valid) begin
            // wait for return to Idle
            state_d = Idle;
          end
        end
      endcase
      // receive a new debug request when state is not Idle
      if (update && state_q != Idle) begin
        error_dmi_busy = 1'b1;
      end
      // capture go up in incorrect state -> error
      if (capture && ((state_q == Read) || (state_q ==  WaitReadValid))) begin
        error_dmi_busy = 1'b1;
      end
      // save error state
      if (error_dmi_busy && error_q == DMINoError) begin
        error_d = DMIBusy;
      end
      if (error_dmi_op_failed && error_q == DMINoError) begin
        error_d = DMIOPFailed;
      end
      // if dmireset -> clear error state
      if (update && dtmcs_q[16]/*dmireset*/ && dtmcs_select) begin
        error_d = DMINoError;
      end
    end
  end

  // shift register
  assign dmi_tdo = dr_q[0];
  // data register assignment
  always @(*) begin
    dr_d    = dr_q;
    if (dmi_clear) begin
      // reset -> clear data registers
      dr_d = 0;
    end
    else begin
      if (capture) begin
        if (dmi_select) begin
          if (error_q == DMINoError && !error_dmi_busy) begin
            // success
            dr_d = {address_q, data_q, DMINoError};
          end
          else if (error_q == DMIBusy || error_dmi_busy) begin
            // dmi is busy
            dr_d = {address_q, data_q, DMIBusy};
          end
        end
      end

      if (shift) begin
        if (dmi_select) begin
          // shift registers
          dr_d = {tdi, dr_q[40:1]};
        end
      end
    end
  end

  // sequential logic
  always @(posedge tck or negedge trst_n) begin
    if (!trst_n) begin
      dr_q      <= 0;
      state_q   <= Idle;
      address_q <= 0;
      data_q    <= 0;
      error_q   <= DMINoError;
    end
    else begin
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
