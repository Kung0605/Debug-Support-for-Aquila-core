module dm_csrs #(
    parameter                     BusWidth         = 32,
    parameter                     SelectableHarts  = 1,
    parameter                     ProgBufSize      = 8,
    parameter                     DataCount        = 2
  ) (
    input                                     clk_i,           // system clock
    input                                     rst_ni,          // Asynchronous reset active low
    input                                     testmode_i,
    input                                     dmi_rst_ni,      // synchronous reset from host
    input                                     dmi_req_valid_i, // Host has prepared new dedbug request
    output                                    dmi_req_ready_o, // DM can receive new debug request
    input        [40:0]                       dmi_req_i,

    output                                    dmi_resp_valid_o, // DM has prepared new debug response
    input                                     dmi_resp_ready_i, // Host can receive new debug response
    output       [33:0]                       dmi_resp_o,
    // global control signal
    output                                    ndmreset_o,       // reset signal to non-debug module
    output                                    dmactive_o,       // indicate the debug module is active
    // core status
    input                                     halted_i,         // the core is halted
    input                                     unavailable_i,    // Not used
    input                                     resumeack_i,      // core has received resume request
    // core control signal
    output       [19:0]                       hartsel_o,        // select target core (but hardcore to 0 here)
    output reg                                haltreq_o,        // request to halt target core
    output reg                                resumereq_o,      // request to resume target core
    output reg                                clear_resumeack_o,

    // abstract command
    output                                    cmd_valid_o,      // valid to write to cmd
    output       [31:0]                       cmd_o,            // abstract command
    input                                     cmderror_valid_i, // indicating an error occur while cmd executing
    input        [2:0]                        cmderror_i,       // kind of cmd error
    input                                     cmdbusy_i,        // indicating cmdd is busy executing

    output reg   [ProgBufSize*32-1:0]         progbuf_o_flatten,// program buffer

    output reg   [DataCount*32-1:0]           data_o_flatten,   // Data0, Data1 in debug memory
    input        [DataCount*32-1:0]           data_i_flatten,
    input                                     data_valid_i
  );

  wire [1:0] dtm_op;
  assign dtm_op = dmi_req_i[33:32];

  wire         resp_queue_full;
  wire         resp_queue_empty;
  wire         resp_queue_push;
  wire         resp_queue_pop;

  // dm_csr address
  localparam    Data0        = 8'h04,
                Data1        = 8'h05,
                Data2        = 8'h06,
                Data3        = 8'h07,
                Data4        = 8'h08,
                Data5        = 8'h09,
                Data6        = 8'h0A,
                Data7        = 8'h0B,
                Data8        = 8'h0C,
                Data9        = 8'h0D,
                Data10       = 8'h0E,
                Data11       = 8'h0F,
                DMControl    = 8'h10,
                DMStatus     = 8'h11,
                Hartinfo     = 8'h12,
                HaltSum1     = 8'h13,
                HAWindowSel  = 8'h14,
                HAWindow     = 8'h15,
                AbstractCS   = 8'h16,
                Command      = 8'h17,
                AbstractAuto = 8'h18,
                DevTreeAddr0 = 8'h19,
                DevTreeAddr1 = 8'h1A,
                DevTreeAddr2 = 8'h1B,
                DevTreeAddr3 = 8'h1C,
                NextDM       = 8'h1D,
                ProgBuf0     = 8'h20,
                ProgBuf1     = 8'h21,
                ProgBuf2     = 8'h22,
                ProgBuf3     = 8'h23,
                ProgBuf4     = 8'h24,
                ProgBuf5     = 8'h25,
                ProgBuf6     = 8'h26,
                ProgBuf7     = 8'h27,
                ProgBuf8     = 8'h28,
                ProgBuf9     = 8'h29,
                ProgBuf10    = 8'h2A,
                ProgBuf11    = 8'h2B,
                ProgBuf12    = 8'h2C,
                ProgBuf13    = 8'h2D,
                ProgBuf14    = 8'h2E,
                ProgBuf15    = 8'h2F,
                AuthData     = 8'h30,
                HaltSum2     = 8'h34,
                HaltSum3     = 8'h35,
                SBAddress3   = 8'h37,
                SBCS         = 8'h38,
                SBAddress0   = 8'h39,
                SBAddress1   = 8'h3A,
                SBAddress2   = 8'h3B,
                SBData0      = 8'h3C,
                SBData1      = 8'h3D,
                SBData2      = 8'h3E,
                SBData3      = 8'h3F,
                HaltSum0     = 8'h40;
  // dtm_op_status
  localparam    DTM_SUCCESS = 2'h0,
                DTM_ERR     = 2'h2,
                DTM_BUSY    = 2'h3;
  // dtm_op_type
  localparam    DTM_NOP   = 2'h0,
                DTM_READ  = 2'h1,
                DTM_WRITE = 2'h2;
  // cmderr
  localparam    CmdErrNone         = 0,
                CmdErrBusy         = 1,
                CmdErrNotSupported = 2,
                CmdErrorException  = 3,
                CmdErrorHaltResume = 4,
                CmdErrorBus        = 5,
                CmdErrorOther = 7;
  localparam DataEnd = Data0 + {4'h0, DataCount} - 8'h1;          // Range for Data
  localparam ProgBufEnd = ProgBuf0 + {4'h0, ProgBufSize} - 8'h1;  // Range for Progbuf

  // halt sum
  reg   [31:0] haltsum0, haltsum1, haltsum2, haltsum3;
  reg   [31 : 0] halted;
  reg   [31:0] halted_reshaped0;
  reg   [31:0] halted_reshaped1;
  reg   [31:0] halted_reshaped2;
  reg   [31:0] halted_flat1;
  reg   [31:0] halted_flat2;
  reg   [31:0] halted_flat3;


  // flatten I/O signal
  wire  [31:0] progbuf_o[ProgBufSize-1:0];
  integer i;
  always @(*) begin
    for (i = 0; i < ProgBufSize; i = i + 1) begin
      progbuf_o_flatten[i*32+:32] = progbuf_o[i];
    end
  end
  wire  [31:0]    data_o[DataCount-1:0];
  always @(*) begin
    for (i = 0; i < DataCount; i = i + 1) begin
      data_o_flatten[i*32+:32] = data_o[i];
    end
  end
  reg   [31:0]    data_i[DataCount-1:0];
  always @(*) begin
    for (i = 0; i < DataCount; i = i + 1) begin
      data_i[i] = data_i_flatten[i*32+:32];
    end
  end

  reg   [31:0]        dmstatus;                        // debug module status
  reg   [31:0]        dmcontrol_d, dmcontrol_q;        // debug module control
  reg   [31:0]        abstractcs;                      // abstract command control and status
  reg   [ 2:0]        cmderr_d, cmderr_q;              // command error
  reg   [31:0]        command_d, command_q;            // abstract command cmd
  reg                 cmd_valid_d, cmd_valid_q;
  reg   [31:0]        abstractauto_d, abstractauto_q;
  // system bus access signal(not implement)
  reg   [31:0]        sbcs_d, sbcs_q;
  reg   [63:0]        sbaddr_d, sbaddr_q;
  reg   [63:0]        sbdata_d, sbdata_q;

  reg                 havereset_q;
  reg                 havereset_d;
  // program buffer
  reg   [31:0] progbuf_d[ProgBufSize-1:0];
  reg   [31:0] progbuf_q[ProgBufSize-1:0];
  reg   [31:0] data_d[DataCount-1:0];
  reg   [31:0] data_q[DataCount-1:0];

  reg   selected_hart;                                 // currently selected core

  // debug response queue
  reg   [33:0] resp_queue_inp;                         // debug response
  reg   [31:0] resp_queue_inp_data;                    // debug response data
  reg   [ 1:0] resp_queue_inp_resp;                    // debug response response(state)

  // debug request
  wire  [31:0] dmi_req_data;                           // debug request data
  wire  [ 6:0] dmi_req_addr;                           // debug request address

  wire  [15:0] abstractauto_q_autoexecprogbuf = abstractauto_q[31:16];
  wire  [11:0] abstractauto_q_autoexecdata = abstractauto_q[11:0];

  // seperate debug response
  always @(*) begin
    resp_queue_inp[33:2] = resp_queue_inp_data;
    resp_queue_inp[ 1:0] = resp_queue_inp_resp;
  end
  // seperate debug request
  assign dmi_req_data = dmi_req_i[31:0];
  assign dmi_req_addr = dmi_req_i[40:34];


  assign dmi_resp_valid_o     = ~resp_queue_empty;    // debug response is valid when response fifo queue is not empty
  assign dmi_req_ready_o      = ~resp_queue_full;     // ready to accept new debug request when respnse fifo queue is not full
  assign resp_queue_push      = dmi_req_valid_i & dmi_req_ready_o;    // accept new debug request when handshake success
  assign hartsel_o            = {dmcontrol_q[15:6], dmcontrol_q[25:16]}; // select target core(can only be 0)


  // helper registers
  wire  [ 7:0]  dm_csr_addr; // debug request's address
  reg   [31:0]  sbcs;        // system bus control and status
  reg   [31:0]  a_abstractcs;
  wire  [ 3:0]  autoexecdata_idx; // Data index selected to return

  assign dm_csr_addr = {1'b0, dmi_req_addr};
  assign autoexecdata_idx = dm_csr_addr - Data0;

  // haltsum0
  reg   [14:0] hartsel_idx0;
  always @(*) begin
    halted              = 0;
    haltsum0            = 0;
    hartsel_idx0        = hartsel_o[19:5];
    halted              = halted_i;
    halted_reshaped0    = halted;
    haltsum0            = halted_reshaped0;
  end

  // haltsum1
  reg   [9:0] hartsel_idx1;
  always @(*) begin
    halted_flat1     = 0;
    haltsum1         = 0;
    hartsel_idx1     = hartsel_o[19:10];
    halted_flat1     = |halted_reshaped0;
    halted_reshaped1 = halted_flat1[0 +: 32];
    haltsum1         = halted_reshaped1[hartsel_idx1];
  end

  // haltsum2
  reg   [4:0] hartsel_idx2;
  always @(*) begin
    halted_flat2      = 0;
    haltsum2          = 0;
    hartsel_idx2      = hartsel_o[19:15];
    halted_flat2      = |halted_reshaped1;
    halted_reshaped2  = halted_flat2[0 +: 32];
    haltsum2          = halted_reshaped2[hartsel_idx2];
  end

  // haltsum3
  always @(*) begin
    halted_flat3 = 0;
    halted_flat3 = |halted_reshaped2;
    haltsum3     = halted_flat3;
  end

  always @(*) begin
    // dmstatus
    dmstatus      = 0;
    dmstatus[3:0] = 4'h2;                                  // set version to 0.13 (4'd2 or 4'h2)
    dmstatus[7]   = 1'b1;                                  // not support authentication
    dmstatus[5]   = 1'b0;                                  // no halt on reset

    dmstatus[19]  = havereset_q;                           // allhavereset
    dmstatus[18]  = havereset_q;                           // anyhavereset

    dmstatus[17]  = resumeack_i;                           // allresumeack
    dmstatus[16]  = resumeack_i;                           // anyresumeack

    dmstatus[13]  = unavailable_i;                         // allunavail
    dmstatus[12]  = unavailable_i;                         // anyunavail

    dmstatus[15]  = (hartsel_o) > 0;                       // allnonexistent
    dmstatus[14]  = (hartsel_o) > 0;                       // anynonexistent

    dmstatus[9]   = halted_i & ~unavailable_i;             // allhalted
    dmstatus[8]   = halted_i & ~unavailable_i;             // anyhalted

    dmstatus[11]  = ~halted_i & ~unavailable_i;            // allrunning
    dmstatus[10]  = ~halted_i & ~unavailable_i;            // anyrunning

    // abstractcs
    abstractcs        = 0;
    abstractcs[3:0]   = DataCount;     // Data count support by implementation (which is 2)
    abstractcs[28:24] = ProgBufSize;   // Program buffer size
    abstractcs[12]    = cmdbusy_i;     // if cmd is busy executing
    abstractcs[10:8]  = cmderr_q;      // cmderr

    // abstractautoexec
    abstractauto_d = abstractauto_q;
    abstractauto_d[15:12] = 0; // zero

    // default assignments
    havereset_d         = havereset_q;
    dmcontrol_d         = dmcontrol_q;
    cmderr_d            = cmderr_q;
    command_d           = command_q;
    for (i = 0; i < ProgBufSize; i = i + 1)
      progbuf_d[i] = progbuf_q[i];
    for (i = 0; i < DataCount; i = i + 1)
      data_d[i] = data_q[i];
    sbcs_d              = sbcs_q;
    sbaddr_d            = {32'h0, 32'b0};
    sbdata_d            = sbdata_q;

    resp_queue_inp_data     = 32'h0;       // set default data to be 0
    resp_queue_inp_resp     = DTM_SUCCESS; // if no error then resp is success
    cmd_valid_d             = 1'b0;
    clear_resumeack_o       = 1'b0;

    // helper registers
    sbcs         = 0;
    a_abstractcs = 0;

    // reads
    if (dmi_req_valid_i && dtm_op == DTM_READ) begin
      // read returned data
      if (dm_csr_addr >= Data0 && dm_csr_addr <= DataEnd) begin
        resp_queue_inp_data = data_q[autoexecdata_idx[$clog2(DataCount)-1:0]]; // read Data[index]
        if (!cmdbusy_i) begin
          // if need to re run command -> cmd_valid_d = 1
          cmd_valid_d = abstractauto_q[autoexecdata_idx]; // select autoexecdata([11:0])
        end
        else begin
          resp_queue_inp_resp = DTM_BUSY;
          if (cmderr_q == CmdErrNone)
            cmderr_d = CmdErrBusy;
        end
      end
      else if (dm_csr_addr == DMControl)
        resp_queue_inp_data = dmcontrol_q;
      else if (dm_csr_addr == DMStatus)
        resp_queue_inp_data = dmstatus;
      else if (dm_csr_addr == AbstractCS)
        resp_queue_inp_data = abstractcs;
      else if (dm_csr_addr == AbstractAuto)
        resp_queue_inp_data = abstractauto_q;
      else if (dm_csr_addr == Command)
        resp_queue_inp_data = 0;
      // read content in program buffer
      else if (dm_csr_addr >= ProgBuf0 && dm_csr_addr <= ProgBufEnd) begin
        // use lower bit to select corresponding program buffer slot
        resp_queue_inp_data = progbuf_q[dmi_req_addr[$clog2(ProgBufSize)-1:0]];
        if (!cmdbusy_i) begin
          // check whether we need to re-execute the command (just give a cmd_valid)
          // range of autoexecprogbuf is 31:16
          cmd_valid_d = abstractauto_q_autoexecprogbuf[{1'b1, dmi_req_addr[3:0]}];
        end
        else begin
          resp_queue_inp_resp = DTM_BUSY;
          if (cmderr_q == CmdErrNone) begin
            cmderr_d = CmdErrBusy;
          end
        end
      end
      else if (dm_csr_addr == HaltSum0)
        resp_queue_inp_data = haltsum0;
      else if (dm_csr_addr == HaltSum1)
        resp_queue_inp_data = haltsum1;
      else if (dm_csr_addr == HaltSum2)
        resp_queue_inp_data = haltsum2;
      else if (dm_csr_addr == HaltSum3)
        resp_queue_inp_data = haltsum3;
      else if (dm_csr_addr == SBCS)
        resp_queue_inp_data = sbcs_q;
      else if (dm_csr_addr == SBAddress0)
        resp_queue_inp_data = sbaddr_q[31:0];
      else if (dm_csr_addr == SBAddress1)
        resp_queue_inp_data = sbaddr_q[63:32];
      else if (dm_csr_addr == SBData0)
        resp_queue_inp_data = sbdata_q[31:0];
      else if (dm_csr_addr == SBData1)
        resp_queue_inp_data = sbdata_q[63:32];
    end

    // write
    if (dmi_req_valid_i && dtm_op == DTM_WRITE) begin
      // write to Data
      if (dm_csr_addr >= Data0 && dm_csr_addr <= DataEnd) begin
        // check if Datas are implement
        if (DataCount > 0) begin
          // if busy -> don't write to Data
          if (!cmdbusy_i) begin
            // use lower bit to select Data slot to write
            data_d[dmi_req_addr[$clog2(DataCount)-1:0]] = dmi_req_data;
            // check whether we need to re-execute the command (just give a cmd_valid)
            cmd_valid_d = abstractauto_q_autoexecdata[autoexecdata_idx];
          end
          else begin
            resp_queue_inp_resp = DTM_BUSY;
            if (cmderr_q == CmdErrNone) begin
              cmderr_d = CmdErrBusy;
            end
          end
        end
      end
      else if (dm_csr_addr == DMControl) begin
        dmcontrol_d = dmi_req_data;
        // if it is acked -> clear havereset
        if (dmcontrol_d[28]) begin
          havereset_d = 1'b0;
        end
      end
      else if (dm_csr_addr == AbstractCS) begin
        // start command when bits are 0, write 1 to bits to reset to 0 -> W1C
        a_abstractcs = dmi_req_data;
        if (!cmdbusy_i) begin
          cmderr_d = ~a_abstractcs[10:8] & cmderr_q;
        end
        else begin
          resp_queue_inp_resp = DTM_BUSY;
          if (cmderr_q == CmdErrNone) begin
            cmderr_d = CmdErrBusy;
          end
        end
      end
      else if (dm_csr_addr == Command) begin
        if (!cmdbusy_i) begin
          cmd_valid_d = 1'b1;
          command_d = dmi_req_data;
        end
        else begin
          // cmd is busy
          resp_queue_inp_resp = DTM_BUSY;
          if (cmderr_q == CmdErrNone) begin
            cmderr_d = CmdErrBusy;
          end
        end
      end
      else if (dm_csr_addr == AbstractAuto) begin
        if (!cmdbusy_i) begin
          abstractauto_d                 = 32'h0;
          abstractauto_d[11:0]           = dmi_req_data[DataCount-1:0]; // autoexecdata
          abstractauto_d[31:16]          = dmi_req_data[ProgBufSize-1+16:16]; // autoexecprogbuf
        end
        else begin
          resp_queue_inp_resp = DTM_BUSY;
          if (cmderr_q == CmdErrNone) begin
            cmderr_d = CmdErrBusy;
          end
        end
      end
      else if (dm_csr_addr >= ProgBuf0 && dm_csr_addr <= ProgBufEnd) begin
        // write to program buffer
        if (!cmdbusy_i) begin
          // use lower bits to select program buffer slot
          progbuf_d[dmi_req_addr[$clog2(ProgBufSize)-1:0]] = dmi_req_data;
          cmd_valid_d = abstractauto_q_autoexecprogbuf[{1'b1, dmi_req_addr[3:0]}];
        end
        else begin
          resp_queue_inp_resp = DTM_BUSY;
          if (cmderr_q == CmdErrNone) begin
            cmderr_d = CmdErrBusy;
          end
        end
      end
      else if (dm_csr_addr == SBCS) begin
        sbcs = dmi_req_data;
        sbcs_d = sbcs_q;
      end
      else if (dm_csr_addr == SBAddress0)
        sbaddr_d[31:0] = dmi_req_data;
      else if (dm_csr_addr == SBAddress1)
        sbaddr_d[63:32] = dmi_req_data;
      else if (dm_csr_addr == SBData0)
        sbdata_d[31:0] = dmi_req_data;
      else if (dm_csr_addr == SBData1)
        sbdata_d[63:32] = dmi_req_data;
    end
    // core is error when executing command
    if (cmderror_valid_i) begin
      cmderr_d = cmderror_i;
    end

    // update Data
    if (data_valid_i) begin
      for (i = 0; i < DataCount; i = i + 1)
        data_d[i] = data_i[i];
    end

    // when reset -> set havereset flag to 1
    if (ndmreset_o) begin
      havereset_d = 1'b1;
    end

    // dmcontrol
    dmcontrol_d[26]             = 1'b0; // hasel = 0, not support
    dmcontrol_d[29]             = 1'b0; // hartreset
    dmcontrol_d[3]              = 1'b0; // set reset halt reset
    dmcontrol_d[2]              = 1'b0; // clear reset halt reset
    dmcontrol_d[27]             = 1'b0; // zero
    dmcontrol_d[5:4]            = 2'b0; // zero
    dmcontrol_d[28]             = 1'b0; // ackhavereset -> read only
    // clear resumeack when new resumereq is coming
    if (!dmcontrol_q[30] && dmcontrol_d[30]) begin
      clear_resumeack_o = 1'b1;
    end
    // if resume is ack then don't request to resume again
    if (dmcontrol_q[30] && resumeack_i) begin
      dmcontrol_d[30] = 1'b0;
    end
    sbcs_d[31:29]    = 3'd1;              // sbcersion
    sbcs_d[21]       = 1'b0;              // sbbusy
    sbcs_d[11:5]     = BusWidth;          // sbasize
    sbcs_d[4]        = BusWidth >= 32'd128;
    sbcs_d[3]        = BusWidth >= 32'd64;
    sbcs_d[2]        = BusWidth >= 32'd32;
    sbcs_d[1]        = BusWidth >= 32'd16;
    sbcs_d[0]        = BusWidth >= 32'd8;
  end

  always @(*) begin
    selected_hart = hartsel_o[0];    // support only one core
    // default assignment
    haltreq_o = 0;
    resumereq_o = 0;
    if (selected_hart == 0) begin
      haltreq_o   = dmcontrol_q[31]; // if new haltreq is coming then request to halt the selected hart
      resumereq_o = dmcontrol_q[30]; // if new resumereq is coming then request to resume the selected hart
    end
  end

  // output assinament
  assign dmactive_o  = dmcontrol_q[0];
  assign cmd_o       = command_q;
  assign cmd_valid_o = cmd_valid_q;
  genvar gi;
  generate
    for (gi = 0; gi < ProgBufSize; gi = gi + 1) begin
      assign progbuf_o[gi] = progbuf_q[gi];
    end
    for (gi = 0; gi < DataCount; gi = gi + 1) begin
      assign data_o[gi] = data_q[gi];
    end
  endgenerate

  assign resp_queue_pop = dmi_resp_ready_i & ~resp_queue_empty; // pop response queue when response is ready and response queueis not empty
  assign ndmreset_o = dmcontrol_q[1];

  // response FIFO
  fifo #(
         .n                ( 34                   ),
         .DEPTH            ( 2                    )
       ) i_fifo (
         .clk_i            ( clk_i                ),
         .rst_ni           ( rst_ni               ),
         .flush_i          ( ~dmi_rst_ni          ),
         .testmode_i       ( testmode_i           ),
         .full_o           ( resp_queue_full      ),
         .empty_o          ( resp_queue_empty     ),
         .data_i           ( resp_queue_inp       ),
         .push_i           ( resp_queue_push      ),
         .data_o           ( dmi_resp_o           ),
         .pop_i            ( resp_queue_pop       )
       );
  // sequential logic
  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      dmcontrol_q    <=  0;
      cmderr_q       <= CmdErrNone;
      command_q      <= 0;
      cmd_valid_q    <= 0;
      abstractauto_q <= 0;
      for (i = 0; i < ProgBufSize; i = i + 1)
        progbuf_q[i] = 0;
      for (i = 0; i < DataCount; i = i + 1)
        data_q[i] <= 0;
      sbcs_q[31:20]  <= 0;
      sbcs_q[19:17]  <= 3'd2; // set sbaccess to be 3'd2
      sbcs_q[16:0]   <= 0;
      sbaddr_q       <= 0;
      sbdata_q       <= 0;
      havereset_q    <= 1'b1;
    end
    else begin
      havereset_q    <= SelectableHarts & havereset_d;
      // synchronous reset for debug module (dmactive == 0)
      if (~dmcontrol_q[0]) begin
        dmcontrol_q[31]              <= 0; // haltreq
        dmcontrol_q[30]              <= 0; // resumereq
        dmcontrol_q[29]              <= 0; // hartreset
        dmcontrol_q[28]              <= 0; // ackhavereset
        dmcontrol_q[27]              <= 0; // zero1
        dmcontrol_q[26]              <= 0; // hasel
        dmcontrol_q[25:16]           <= 0; // hartsello
        dmcontrol_q[15:6]            <= 0; // hartselhi
        dmcontrol_q[5:4]             <= 0; // zero0
        dmcontrol_q[3]               <= 0; // setresethaltreq
        dmcontrol_q[2]               <= 0; // clrresethaltreq
        dmcontrol_q[1]               <= 0; // ndmreset
        dmcontrol_q[0]               <= dmcontrol_d[0]; // dmactive
        cmderr_q                     <= CmdErrNone;
        command_q                    <= 0;
        cmd_valid_q                  <= 0;
        abstractauto_q               <= 0;
        for (i = 0; i < ProgBufSize; i = i + 1)
          progbuf_q[i] = 0;
        for (i = 0; i < DataCount; i = i + 1)
          data_q[i] <= 0;
        sbcs_q[31:20]  <= 0;
        sbcs_q[19:17]  <= 3'd2;           // set sbaccess to be 3'd2
        sbcs_q[16:0]   <= 0;
        sbaddr_q                     <= 0;
        sbdata_q                     <= 0;
      end
      else begin
        dmcontrol_q                  <= dmcontrol_d;
        cmderr_q                     <= cmderr_d;
        command_q                    <= command_d;
        cmd_valid_q                  <= cmd_valid_d;
        abstractauto_q               <= abstractauto_d;
        for (i = 0; i < ProgBufSize; i = i + 1)
          progbuf_q[i] <= progbuf_d[i];
        for (i = 0; i < DataCount; i = i + 1)
          data_q[i] <= data_d[i];
        sbcs_q                       <= sbcs_d;
        sbaddr_q                     <= sbaddr_d;
        sbdata_q                     <= sbdata_d;
      end
    end
  end

endmodule
