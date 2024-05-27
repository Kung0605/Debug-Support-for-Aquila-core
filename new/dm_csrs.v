module dm_csrs #(
  parameter                     NrHarts          = 1,
  parameter                     BusWidth         = 32,
  parameter                     SelectableHarts  = 1,
  parameter                     ProgBufSize      = 8,
  parameter                     DataCount        = 2
) (
  input                                     clk_i,           // Clock
  input                                     rst_ni,          // Asynchronous reset active low
  input                                     testmode_i,
  input                                     dmi_rst_ni,      // sync. DTM reset,
                                                             // active-low
  input                                     dmi_req_valid_i,
  output                                    dmi_req_ready_o,
  input        [40:0]                       dmi_req_i,
  // every request needs a response one cycle later
  output                                    dmi_resp_valid_o,
  input                                     dmi_resp_ready_i,
  output       [33:0]                       dmi_resp_o,
  // global ctrl
  output                                    ndmreset_o,      // non-debug module reset active-high
  output                                    dmactive_o,      // 1 -> debug-module is active,
                                                             // 0 -> synchronous re-set
  // hart status
  input        [NrHarts-1:0]                halted_i,        // hart is halted
  input        [NrHarts-1:0]                unavailable_i,   // e.g.: powered down
  input        [NrHarts-1:0]                resumeack_i,     // hart acknowledged resume request
  // hart control
  output       [19:0]                       hartsel_o,       // hartselect to ctrl module
  output reg   [NrHarts-1:0]                haltreq_o,       // request to halt a hart
  output reg   [NrHarts-1:0]                resumereq_o,     // request hart to resume
  output reg                                clear_resumeack_o,

  output                                    cmd_valid_o,       // debugger writing to cmd field
  output       [31:0]                       cmd_o,             // abstract command
  input                                     cmderror_valid_i,  // an error occurred
  input        [2:0]                        cmderror_i,        // this error occurred
  input                                     cmdbusy_i,         // cmd is currently busy executing

  output reg   [ProgBufSize*32-1:0]         progbuf_o_flatten, // to system bus
  output reg   [DataCount*32-1:0]           data_o_flatten,

  input        [DataCount*32-1:0]           data_i_flatten,
  input                                     data_valid_i,
  // system bus access module (SBA)
  output       [BusWidth-1:0]               sbaddress_o,
  input        [BusWidth-1:0]               sbaddress_i,
  output reg                                sbaddress_write_valid_o,
  // control signals in
  output                                    sbreadonaddr_o,
  output                                    sbautoincrement_o,
  output       [2:0]                        sbaccess_o,
  // data out
  output                                    sbreadondata_o,
  output       [BusWidth-1:0]               sbdata_o,
  output reg                                sbdata_read_valid_o,
  output reg                                sbdata_write_valid_o,
  // read data in
  input        [BusWidth-1:0]               sbdata_i,
  input                                     sbdata_valid_i,
  // control signals
  input                                     sbbusy_i,
  input                                     sberror_valid_i, // bus error occurred
  input        [2:0]                        sberror_i // bus error occurred
);
  // the amount of bits we need to represent all harts
  localparam HartSelLen = (NrHarts == 1) ? 1 : $clog2(NrHarts);
  localparam NrHartsAligned = 2**HartSelLen;

  wire [1:0] dtm_op;
  assign dtm_op = dmi_req_i[33:32];

  wire         resp_queue_full;
  wire         resp_queue_empty;
  wire         resp_queue_push;
  wire         resp_queue_pop;


  // csr address 
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
  localparam DataEnd = Data0 + {4'h0, DataCount} - 8'h1;
  localparam ProgBufEnd = ProgBuf0 + {4'h0, ProgBufSize} - 8'h1;

  reg   [31:0] haltsum0, haltsum1, haltsum2, haltsum3;
  reg   [((NrHarts-1)/2**5 + 1) * 32 - 1 : 0] halted;
  reg   [31:0] halted_reshaped0[(NrHarts-1)/2**5:0];
  reg   [31:0] halted_reshaped1[(NrHarts-1)/2**10:0];
  reg   [31:0] halted_reshaped2[(NrHarts-1)/2**15:0];
  reg   [((NrHarts-1)/2**10+1)*32-1:0] halted_flat1;
  reg   [((NrHarts-1)/2**15+1)*32-1:0] halted_flat2;
  reg   [31:0] halted_flat3;


  // flatten I/O signal
  wire  [31:0]    progbuf_o[ProgBufSize-1:0];
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

  // haltsum0
  reg   [14:0] hartsel_idx0;
  always @(*) begin
    halted              = 0;
    haltsum0            = 0;
    hartsel_idx0        = hartsel_o[19:5];
    halted[NrHarts-1:0] = halted_i;
    for (i = 0; i <= (NrHarts-1)/2**5; i = i + 1)
        halted_reshaped0[i] = halted[i * 32 +: 32];
    if (hartsel_idx0 < ((NrHarts-1)/2**5+1)) begin
      haltsum0 = halted_reshaped0[hartsel_idx0];
    end
  end

  // haltsum1
  reg   [9:0] hartsel_idx1;
  always @(*) begin
    halted_flat1 = 0;
    haltsum1     = 0;
    hartsel_idx1 = hartsel_o[19:10];

    for (i = 0; i < (NrHarts-1)/2**5+1; i = i + 1) begin
      halted_flat1[i] = |halted_reshaped0[i];
    end

    for (i = 0; i <= (NrHarts-1)/2**10; i = i + 1) 
        halted_reshaped1[i] = halted_flat1[i * 32 +: 32];

    if (hartsel_idx1 < (((NrHarts-1)/2**10+1))) begin
      haltsum1 = halted_reshaped1[hartsel_idx1];
    end
  end

  // haltsum2
  reg   [4:0] hartsel_idx2;
  always @(*) begin
    halted_flat2 = 0;
    haltsum2     = 0;
    hartsel_idx2 = hartsel_o[19:15];

    for (i = 0; i < (NrHarts-1)/2**10+1; i = i + 1) begin
      halted_flat2[i] = |halted_reshaped1[i];
    end

    for (i = 0; i <= (NrHarts-1)/2**15; i = i + 1)
        halted_reshaped2[i] = halted_flat2[i * 32 +: 32];

    if (hartsel_idx2 < (((NrHarts-1)/2**15+1))) begin
      haltsum2         = halted_reshaped2[hartsel_idx2];
    end
  end

  // haltsum3
  always @(*) begin
    halted_flat3 = 0;
    for (i = 0; i < NrHarts/2**15+1; i = i + 1) begin
      halted_flat3[i] = |halted_reshaped2[i];
    end
    haltsum3 = halted_flat3;
  end


  reg   [31:0]        dmstatus;
  reg   [31:0]        dmcontrol_d, dmcontrol_q;
  reg   [31:0]        abstractcs;
  reg   [ 2:0]        cmderr_d, cmderr_q;
  reg   [31:0]        command_d, command_q;
  reg                 cmd_valid_d, cmd_valid_q;
  reg   [31:0]        abstractauto_d, abstractauto_q;
  reg   [31:0]        sbcs_d, sbcs_q;
  reg   [63:0]        sbaddr_d, sbaddr_q;
  reg   [63:0]        sbdata_d, sbdata_q;

  reg   [NrHarts-1:0] havereset_q;
  wire  [NrHarts-1:0] havereset_d;
  // program buffer
  reg   [31:0] progbuf_d[ProgBufSize-1:0]; 
  reg   [31:0] progbuf_q[ProgBufSize-1:0];
  reg   [31:0] data_d[DataCount-1:0];
  reg   [31:0] data_q[DataCount-1:0];

  reg   [HartSelLen-1:0] selected_hart;

  reg   [33:0] resp_queue_inp;
  reg   [31:0] resp_queue_inp_data;
  reg   [ 1:0] resp_queue_inp_resp;

  wire  [31:0] dmi_req_data;
  wire  [ 6:0] dmi_req_addr;

  wire  [15:0] abstractauto_q_autoexecprogbuf = abstractauto_q[31:16];
  wire  [11:0] abstractauto_q_autoexecdata = abstractauto_q[11:0];
  //
  always @(*) begin 
    resp_queue_inp[33:2] = resp_queue_inp_data;
    resp_queue_inp[ 1:0] = resp_queue_inp_resp;
  end

  assign dmi_req_data = dmi_req_i[31:0];
  assign dmi_req_addr = dmi_req_i[40:34];
  //


  assign dmi_resp_valid_o     = ~resp_queue_empty;
  assign dmi_req_ready_o      = ~resp_queue_full;
  assign resp_queue_push      = dmi_req_valid_i & dmi_req_ready_o;
  // SBA
  assign sbautoincrement_o = sbcs_q[16];
  assign sbreadonaddr_o    = sbcs_q[20];
  assign sbreadondata_o    = sbcs_q[15];
  assign sbaccess_o        = sbcs_q[19:17];
  assign sbdata_o          = sbdata_q[BusWidth-1:0];
  assign sbaddress_o       = sbaddr_q[BusWidth-1:0];

  assign hartsel_o         = {dmcontrol_q[15:6], dmcontrol_q[25:16]}; // use hartselhi and hartsello to produce hartsel_o

  // needed to avoid lint warnings
  reg   [NrHartsAligned-1:0] havereset_d_aligned;
  wire  [NrHartsAligned-1:0] havereset_q_aligned;
  wire  [NrHartsAligned-1:0] resumeack_aligned;
  wire  [NrHartsAligned-1:0] unavailable_aligned;
  wire  [NrHartsAligned-1:0] halted_aligned;
  assign resumeack_aligned   = resumeack_i;
  assign unavailable_aligned = unavailable_i;
  assign halted_aligned      = halted_i;

  assign havereset_d         = havereset_d_aligned;
  assign havereset_q_aligned = havereset_q;


  // helper variables
  wire  [ 7:0]  dm_csr_addr; // request's CSR addr
  reg   [31:0]  sbcs;
  reg   [31:0]  a_abstractcs;
  wire  [ 3:0]  autoexecdata_idx; // if this is 0 then return Data0, if this is 11 then return Data11 etc.

  // Get the data index, i.e. 0 for dm::Data0 up to 11 for dm::Data11
  assign dm_csr_addr = {1'b0, dmi_req_addr};
  // Xilinx Vivado 2020.1 does not allow subtraction of two enums; do the subtraction with logic
  // types instead.
  assign autoexecdata_idx = dm_csr_addr - Data0;

  always @(*) begin
    // dmstatus
    dmstatus      = 0;
    dmstatus[3:0] = 4'h2;                  // set version to 0.13 (4'd2 or 4'h2)
    dmstatus[7]   = 1'b1;                               // not support authentication
    dmstatus[5]   = 1'b0;                               // no halt on reset
    dmstatus[19]  = havereset_q_aligned[selected_hart]; // allhavereset
    dmstatus[18]  = havereset_q_aligned[selected_hart]; // anyhavereset

    dmstatus[17]  = resumeack_aligned[selected_hart];   // allresumeack
    dmstatus[16]  = resumeack_aligned[selected_hart];   // anyresumeack
 
    dmstatus[13]  = unavailable_aligned[selected_hart]; // allunavail
    dmstatus[12]  = unavailable_aligned[selected_hart]; // anyunavail

    dmstatus[15]  = (hartsel_o) > (NrHarts - 1);        // allnonexistent
    dmstatus[14]  = (hartsel_o) > (NrHarts - 1);        // anynonexistent

    dmstatus[9]   = halted_aligned[selected_hart] & ~unavailable_aligned[selected_hart]; // allhalted
    dmstatus[8]   = halted_aligned[selected_hart] & ~unavailable_aligned[selected_hart]; // anyhalted

    dmstatus[11]  = ~halted_aligned[selected_hart] & ~unavailable_aligned[selected_hart]; // allrunning
    dmstatus[10]  = ~halted_aligned[selected_hart] & ~unavailable_aligned[selected_hart]; // anyrunning

    // abstractcs
    abstractcs        = 0;
    abstractcs[3:0]   = DataCount; 
    abstractcs[28:24] = ProgBufSize;
    abstractcs[12]    = cmdbusy_i; // if cmd is busy executing
    abstractcs[10:8]  = cmderr_q;

    // abstractautoexec
    abstractauto_d = abstractauto_q;
    abstractauto_d[15:12] = 0; // zero

    // default assignments
    havereset_d_aligned = havereset_q;
    dmcontrol_d         = dmcontrol_q;
    cmderr_d            = cmderr_q;
    command_d           = command_q;
    for (i = 0; i < ProgBufSize; i = i + 1)
        progbuf_d[i] = progbuf_q[i];
    for (i = 0; i < DataCount; i = i + 1)
        data_d[i] = data_q[i];
    sbcs_d              = sbcs_q;
    sbaddr_d            = {32'h0, sbaddress_i};
    sbdata_d            = sbdata_q;

    resp_queue_inp_data     = 32'h0; // set default data to be 0
    resp_queue_inp_resp     = DTM_SUCCESS; // if no error then resp is success
    cmd_valid_d             = 1'b0;
    sbaddress_write_valid_o = 1'b0;
    sbdata_read_valid_o     = 1'b0;
    sbdata_write_valid_o    = 1'b0;
    clear_resumeack_o       = 1'b0;

    // helper variables
    sbcs         = 0;
    a_abstractcs = 0;

    // reads
    if (dmi_req_valid_i && dtm_op == DTM_READ) begin
        if (dm_csr_addr >= Data0 && dm_csr_addr <= DataEnd) begin
            resp_queue_inp_data = data_q[autoexecdata_idx[$clog2(DataCount)-1:0]];
            if (!cmdbusy_i) begin
            // check whether we need to re-execute the command (just give a cmd_valid)
            cmd_valid_d = abstractauto_q[autoexecdata_idx]; // select autoexecdata([11:0])
            // An abstract command was executing while one of the data registers was read
            end else begin
            resp_queue_inp_resp = DTM_BUSY;
            if (cmderr_q == CmdErrNone) begin
                cmderr_d = CmdErrBusy;
            end
            end
        end
        else if (dm_csr_addr == DMControl)    resp_queue_inp_data = dmcontrol_q;
        else if (dm_csr_addr == DMStatus)     resp_queue_inp_data = dmstatus;
        else if (dm_csr_addr == AbstractCS)   resp_queue_inp_data = abstractcs;
        else if (dm_csr_addr == AbstractAuto) resp_queue_inp_data = abstractauto_q;
        else if (dm_csr_addr == Command)      resp_queue_inp_data = 0;
        else if (dm_csr_addr >= ProgBuf0 && dm_csr_addr <= ProgBufEnd) begin
            resp_queue_inp_data = progbuf_q[dmi_req_addr[$clog2(ProgBufSize)-1:0]];
            if (!cmdbusy_i) begin
            // check whether we need to re-execute the command (just give a cmd_valid)
            // range of autoexecprogbuf is 31:16
            cmd_valid_d = abstractauto_q_autoexecprogbuf[{1'b1, dmi_req_addr[3:0]}];

            // An abstract command was executing while one of the progbuf registers was read
            end else begin
            resp_queue_inp_resp = DTM_BUSY;
            if (cmderr_q == CmdErrNone) begin
                cmderr_d = CmdErrBusy;
            end
            end
        end
        else if (dm_csr_addr == HaltSum0)     resp_queue_inp_data = haltsum0;
        else if (dm_csr_addr == HaltSum1)     resp_queue_inp_data = haltsum1;
        else if (dm_csr_addr == HaltSum2)     resp_queue_inp_data = haltsum2;
        else if (dm_csr_addr == HaltSum3)     resp_queue_inp_data = haltsum3;
        else if (dm_csr_addr == SBCS)         resp_queue_inp_data = sbcs_q;
        else if (dm_csr_addr == SBAddress0)   resp_queue_inp_data = sbaddr_q[31:0];
        else if (dm_csr_addr == SBAddress1)   resp_queue_inp_data = sbaddr_q[63:32];
        else if (dm_csr_addr == SBData0) begin
            // access while the SBA was busy
            if (sbbusy_i || sbcs_q[22]) begin
            sbcs_d[22] = 1'b1; // if access system bus when it is busy then generate a busy error
            resp_queue_inp_resp = DTM_BUSY;
            end else begin
            sbdata_read_valid_o = (sbcs_q[14:12] == 0);
            resp_queue_inp_data = sbdata_q[31:0];
            end
        end
        else if (dm_csr_addr == SBData1) begin
            // access while the SBA was busy
            if (sbbusy_i || sbcs_q[22]) begin
            sbcs_d[22] = 1'b1; // if access system bus when it is busy then generate a busy error
            resp_queue_inp_resp = DTM_BUSY;
            end else begin
            resp_queue_inp_data = sbdata_q[63:32];
            end
        end
    end

    // write
    if (dmi_req_valid_i && dtm_op == DTM_WRITE) begin
        if (dm_csr_addr >= Data0 && dm_csr_addr <= DataEnd) begin
          if (DataCount > 0) begin
            // attempts to write them while busy is set does not change their value
            if (!cmdbusy_i) begin
              data_d[dmi_req_addr[$clog2(DataCount)-1:0]] = dmi_req_data;
              // check whether we need to re-execute the command (just give a cmd_valid)
              cmd_valid_d = abstractauto_q_autoexecdata[autoexecdata_idx];
            //An abstract command was executing while one of the data registers was written
            end else begin
              resp_queue_inp_resp = DTM_BUSY;
              if (cmderr_q == CmdErrNone) begin
                cmderr_d = CmdErrBusy;
              end
            end
          end
        end
        else if (dm_csr_addr == DMControl) begin
          dmcontrol_d = dmi_req_data;
          // clear havereset if it is acked
          if (dmcontrol_d[28]) begin
            havereset_d_aligned[selected_hart] = 1'b0;
          end
        end
        else if (dm_csr_addr == AbstractCS) begin // W1C
          // Gets set if an abstract command fails. The bits in this
          // field remain set until they are cleared by writing 1 to
          // them. No abstract command is started until the value is
          // reset to 0.
          a_abstractcs = dmi_req_data;
          // reads during abstract command execution are not allowed
          if (!cmdbusy_i) begin
            cmderr_d = ~a_abstractcs[10:8] & cmderr_q; // ????
          end else begin
            resp_queue_inp_resp = DTM_BUSY;
            if (cmderr_q == CmdErrNone) begin
              cmderr_d = CmdErrBusy;
            end
          end
        end
        else if (dm_csr_addr == Command) begin
          // writes are ignored if a command is already busy
          if (!cmdbusy_i) begin
            cmd_valid_d = 1'b1;
            command_d = dmi_req_data;
          // if there was an attempted to write during a busy execution
          // and the cmderror field is zero set the busy error
          end else begin
            resp_queue_inp_resp = DTM_BUSY;
            if (cmderr_q == CmdErrNone) begin
              cmderr_d = CmdErrBusy;
            end
          end
        end
        else if (dm_csr_addr == AbstractAuto) begin
          // this field can only be written legally when there is no command executing
          if (!cmdbusy_i) begin
            abstractauto_d                 = 32'h0;
            abstractauto_d[11:0]           = dmi_req_data[DataCount-1:0]; // autoexecdata
            abstractauto_d[31:16]          = dmi_req_data[ProgBufSize-1+16:16]; // autoexecprogbuf
          end else begin
            resp_queue_inp_resp = DTM_BUSY;
            if (cmderr_q == CmdErrNone) begin
              cmderr_d = CmdErrBusy;
            end
          end
        end
        else if (dm_csr_addr >= ProgBuf0 && dm_csr_addr <= ProgBufEnd) begin
          // attempts to write them while busy is set does not change their value
          if (!cmdbusy_i) begin
            progbuf_d[dmi_req_addr[$clog2(ProgBufSize)-1:0]] = dmi_req_data;
            // check whether we need to re-execute the command (just give a cmd_valid)
            // this should probably throw an error if executed during another command
            // was busy
            // range of autoexecprogbuf is 31:16
            cmd_valid_d = abstractauto_q_autoexecprogbuf[{1'b1, dmi_req_addr[3:0]}];
          //An abstract command was executing while one of the progbuf registers was written
          end else begin
            resp_queue_inp_resp = DTM_BUSY;
            if (cmderr_q == CmdErrNone) begin
              cmderr_d = CmdErrBusy;
            end
          end
        end
        else if (dm_csr_addr == SBCS) begin
          // access while the SBA was busy
          if (sbbusy_i) begin
            sbcs_d[22] = 1'b1;
            resp_queue_inp_resp = DTM_BUSY;
          end else begin
            sbcs = dmi_req_data;
            sbcs_d = sbcs; // default assignment
            // R/W1C
            sbcs_d[22] = sbcs_q[22] & (~sbcs[22]); // system bus is in busy
            sbcs_d[14:12]     = (|sbcs[14:12]) ? 3'b0 : sbcs_q[14:12]; // set current error type
          end
        end
        else if (dm_csr_addr == SBAddress0) begin
          // access while the SBA was busy
          if (sbbusy_i || sbcs_q[22]) begin
            sbcs_d[22] = 1'b1; 
            resp_queue_inp_resp = DTM_BUSY;
          end else begin
            sbaddr_d[31:0] = dmi_req_data;
            sbaddress_write_valid_o = (sbcs_q[14:12] == 3'b0);
          end
        end
        else if (dm_csr_addr == SBAddress1) begin
          // access while the SBA was busy
          if (sbbusy_i || sbcs_q[22]) begin
            sbcs_d[22] = 1'b1;
            resp_queue_inp_resp = DTM_BUSY;
          end else begin
            sbaddr_d[63:32] = dmi_req_data;
          end
        end
        else if (dm_csr_addr == SBData0) begin
          // access while the SBA was busy
          if (sbbusy_i || sbcs_q[22]) begin
           sbcs_d[22] = 1'b1;
           resp_queue_inp_resp = DTM_BUSY;
          end else begin
            sbdata_d[31:0] = dmi_req_data;
            sbdata_write_valid_o = (sbcs_q[14:12] == 3'b0);
          end
        end
        else if (dm_csr_addr == SBData1) begin
          // access while the SBA was busy
          if (sbbusy_i || sbcs_q[22]) begin
           sbcs_d[22] = 1'b1;
           resp_queue_inp_resp = DTM_BUSY;
          end else begin
            sbdata_d[63:32] = dmi_req_data;
          end
        end
    end
    // hart threw a command error and has precedence over bus writes
    if (cmderror_valid_i) begin
      cmderr_d = cmderror_i;
    end

    // update data registers
    if (data_valid_i) begin
        for (i = 0; i < DataCount; i = i + 1)
            data_d[i] = data_i[i];
    end

    // set the havereset flag when we did a ndmreset
    if (ndmreset_o) begin
      havereset_d_aligned[NrHarts-1:0] = {NrHarts{1'b1}};
    end
    // -------------
    // System Bus
    // -------------
    // set bus error
    if (sberror_valid_i) begin
      sbcs_d[14:12] = sberror_i; // set system bus error type
    end
    // update read data
    if (sbdata_valid_i) begin
      sbdata_d = {32'b0, sbdata_i};
    end

    // dmcontrol
    // not support action on single hart
    dmcontrol_d[26]             = 1'b0; // hasel = 0, not support
    dmcontrol_d[29]             = 1'b0;
    dmcontrol_d[3]              = 1'b0;
    dmcontrol_d[2]              = 1'b0;
    dmcontrol_d[27]             = 1'b0; 
    dmcontrol_d[5:4]            = 2'b0;
    // Non-writeable, clear only
    dmcontrol_d[28]             = 1'b0; // you can not write to ackhavereset
    // if new resume request is coming then clear the old resumeack
    if (!dmcontrol_q[30] && dmcontrol_d[30]) begin
      clear_resumeack_o = 1'b1;
    end
    if (dmcontrol_q[30] && resumeack_i) begin
      dmcontrol_d[30] = 1'b0;
    end
    // static values for dcsr
    sbcs_d[31:29]    = 3'd1;                    // sbcersion
    sbcs_d[21]       = sbbusy_i;                // sbbusy 
    sbcs_d[11:5]     = BusWidth; // sbasize
    // check the SBA width support
    sbcs_d[4]        = BusWidth >= 32'd128;
    sbcs_d[3]        = BusWidth >= 32'd64;
    sbcs_d[2]        = BusWidth >= 32'd32;
    sbcs_d[1]        = BusWidth >= 32'd16;
    sbcs_d[0]        = BusWidth >= 32'd8;
  end

  // output multiplexer
  always @(*) begin 
    selected_hart = hartsel_o[HartSelLen-1:0];
    // default assignment
    haltreq_o = 0;
    resumereq_o = 0;
    if (selected_hart <= (NrHarts-1)) begin
      haltreq_o[selected_hart]   = dmcontrol_q[31]; // if new haltreq is coming then request to halt the selected hart
      resumereq_o[selected_hart] = dmcontrol_q[30]; // if new resumereq is coming then request to resume the selected hart
    end
  end

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

  assign resp_queue_pop = dmi_resp_ready_i & ~resp_queue_empty;

  assign ndmreset_o = dmcontrol_q[1];

  // response FIFO
  fifo #(
    .n                ( 34                            ),
    .DEPTH            ( 2                             )
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

  always @(posedge clk_i or negedge rst_ni) begin
    // PoR
    if (!rst_ni) begin
      dmcontrol_q    <=  0;
      // this is the only write-able bit during reset
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
      havereset_q    <= {NrHarts{1'b1}};
    end else begin
      havereset_q    <= SelectableHarts & havereset_d;
      // synchronous re-set of debug module, active-low, except for dmactive
      // if debug module is not active then no action will be taken
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
        sbcs_q[19:17]  <= 3'd2; // set sbaccess to be 3'd2
        sbcs_q[16:0]   <= 0;
        sbaddr_q                     <= 0;
        sbdata_q                     <= 0;
      end else begin
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