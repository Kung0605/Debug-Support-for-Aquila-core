module dm_abstractcmd_generator(
    input  [31:0]     cmd_i,
    output [7:0]      cmd_cmdtype_o,
    output reg [63:0] abstract_cmd0_o,
    output reg [63:0] abstract_cmd1_o,
    output reg [63:0] abstract_cmd2_o,
    output reg [63:0] abstract_cmd3_o,
    output reg [63:0] abstract_cmd4_o,
    output reg [63:0] abstract_cmd5_o,
    output reg [63:0] abstract_cmd6_o,
    output reg [63:0] abstract_cmd7_o,
    output reg        unsupported_command_o,
    output            transfer_o,
    output            postexec_o
);

    function [31:0] jalr (input [4:0]  rd, input [4:0]  rs1, input [11:0] offset);
        jalr =  {offset[11:0], rs1, 3'b0, rd, 7'h67};
    endfunction
    function [31:0] andi (input [4:0]  rd, input [4:0]  rs1, input [11:0] imm);
        andi = {imm[11:0], rs1, 3'h7, rd, 7'h13};
    endfunction
    function [31:0] slli (input [4:0] rd, input [4:0] rs1, input [5:0] shamt);
        slli = {6'b0, shamt[5:0], rs1, 3'h1, rd, 7'h13};
    endfunction
    function [31:0] srli (input [4:0] rd, input [4:0] rs1, input [5:0] shamt);
        srli = {6'b0, shamt[5:0], rs1, 3'h5, rd, 7'h13};
    endfunction
    function [31:0] load (input [2:0]  size, input [4:0]  dest, input [4:0]  base, input [11:0] offset);
        load = {offset[11:0], base, size, dest, 7'h03};
    endfunction
    function [31:0] auipc (input [4:0]  rd, input [20:0] imm);
        auipc = {imm[20], imm[10:1], imm[11], imm[19:12], rd, 7'h17};
    endfunction
    function [31:0] store (input [2:0]  size, input [4:0]  src, input [4:0]  base, input [11:0] offset);
        store = {offset[11:5], src, base, size, offset[4:0], 7'h23};
    endfunction
    function [31:0] float_load (input [2:0]  size, input [4:0]  dest, input [4:0]  base, input [11:0] offset);
        float_load = {offset[11:0], base, size, dest, 7'b00_001_11};
    endfunction
    function [31:0] float_store (input [2:0]  size, input [4:0]  src, input [4:0]  base, input [11:0] offset);
        float_store = {offset[11:5], src, base, size, offset[4:0], 7'b01_001_11};
    endfunction
    function [31:0] csrw (input [11:0] csr, input [4:0] rs1);
        csrw = {csr, rs1, 3'h1, 5'h0, 7'h73};
    endfunction
    function [31:0] csrr (input [11:0] csr, input [4:0] dest);
        csrr = {csr, 5'h0, 3'h2, dest, 7'h73};
    endfunction
    function [31:0] branch(input [4:0]  src2, input [4:0]  src1, input [2:0]  funct3, input [11:0] offset);
        branch = {offset[11], offset[9:4], src2, src1, funct3, offset[3:0], offset[10], 7'b11_000_11};
    endfunction
    localparam  MaxAar         = 3;
    localparam  AccessRegister = 8'h0,
                QuickAccess    = 8'h1,
                AccessMemory   = 8'h2;

    localparam  CSR_DSCRATCH0      = 12'h7b2,
                CSR_DSCRATCH1      = 12'h7b3;   

    localparam  ebreak =  32'h00100073,
                wfi = 32'h10500073,
                nop = 32'h00000013,
                illegal = 32'h00000000;

    localparam  LoadBaseAddr   = 5'd10;
    localparam  DataAddr       = 32'h380;
    reg  [63:0] abstract_cmd [0:7];
    // Abstract Command Access Register
    wire  [31:0] ac_ar;
    wire  [23:0] cmd_control;
    wire  [ 7:0] cmd_cmdtype;
    wire  transfer;
    wire  postexec;
    wire  write;
    wire  aarpostincrement;
    wire  [2:0] aarsize;
    wire  [15:0] regno;
    reg   unsupported_command;
    
    assign cmd_control = cmd_i[23: 0];
    assign cmd_cmdtype = cmd_i[31:24];
    assign ac_ar       = cmd_control;
    assign aarsize     = ac_ar[22:20];
    assign regno       = ac_ar[15:0];
    assign aarpostincrement = ac_ar[19];
    assign transfer    = ac_ar[17];
    assign postexec    = ac_ar[18];
    assign write       = ac_ar[16];
    
    always @(*) begin

        // default command
        unsupported_command = 1'b0;
        abstract_cmd[0][31:0]  = illegal;
        // load debug module base address into a0
        abstract_cmd[0][63:32] = auipc(5'd10, 0);
        // calculate dm_mem offset
        abstract_cmd[1][31:0]  = srli(5'd10, 5'd10, 6'd12);
        abstract_cmd[1][63:32] = slli(5'd10, 5'd10, 6'd12);
        abstract_cmd[2][31:0]  = nop;
        abstract_cmd[2][63:32] = nop;
        abstract_cmd[3][31:0]  = nop;
        abstract_cmd[3][63:32] = nop;
        abstract_cmd[4][31:0]  = csrr(CSR_DSCRATCH1, 5'd10);
        abstract_cmd[4][63:32] = ebreak;
        abstract_cmd[5]      = 0;
        abstract_cmd[6]      = 0;
        abstract_cmd[7]      = 0;

        // currently only support AccessRegister
        case (cmd_cmdtype)
            AccessRegister: begin
                if (aarsize < MaxAar && transfer && write) begin
                    abstract_cmd[0][31:0] = csrw(CSR_DSCRATCH1, 5'd10);
                    // this range is reserved
                    if (regno[15:14] != 0) begin
                        abstract_cmd[0][31:0] = ebreak; // leave abstract command to avoid error
                        unsupported_command = 1'b1;
                    // since a0 register are now store in dscratch, so we should write to CSR instead
                    end else if (regno[12] && (regno[5]) && (regno[4:0] == 5'd10)) begin
                        abstract_cmd[2][31:0]  = csrw(CSR_DSCRATCH0, 5'd8);
                        abstract_cmd[2][63:32] = load(aarsize, 5'd8, LoadBaseAddr, DataAddr);
                        abstract_cmd[3][31:0]  = csrw(CSR_DSCRATCH1, 5'd8);
                        abstract_cmd[3][63:32] = csrr(CSR_DSCRATCH0, 5'd8);
                    // GPR/FPR access
                    end else if (regno[12]) begin
                        // determine access FPR/GPR
                        if (regno[5]) begin
                            abstract_cmd[2][31:0] = float_load(aarsize, regno[4:0], LoadBaseAddr, DataAddr);
                        end else begin
                            abstract_cmd[2][31:0] = load(aarsize, regno[4:0], LoadBaseAddr, DataAddr);
                        end
                    // CSR access
                    end else begin
                        abstract_cmd[2][31:0]  = csrw(CSR_DSCRATCH0, 5'd8);
                        abstract_cmd[2][63:32] = load(aarsize, 5'd8, LoadBaseAddr, DataAddr);
                        abstract_cmd[3][31:0]  = csrw(regno[11:0], 5'd8);
                        abstract_cmd[3][63:32] = csrr(CSR_DSCRATCH0, 5'd8);
                    end
                end else if (aarsize < MaxAar && transfer && !write) begin
                    // read operation
                    abstract_cmd[0][31:0]  = csrw(CSR_DSCRATCH1, LoadBaseAddr);
                    // this range is reserved
                    if (regno[15:14] != 0) begin
                        abstract_cmd[0][31:0] = ebreak; // leave abstract command to avoid error
                        unsupported_command = 1'b1;
                    // since a0 is stored in dscratch, so a0 must be handled separately
                    end else if (regno[12] && (!regno[5]) && (regno[4:0] == 5'd10)) begin
                        abstract_cmd[2][31:0]  = csrw(CSR_DSCRATCH0, 5'd8);
                        abstract_cmd[2][63:32] = csrr(CSR_DSCRATCH1, 5'd8);
                        abstract_cmd[3][31:0]  = store(aarsize, 5'd8, LoadBaseAddr, DataAddr);
                        abstract_cmd[3][63:32] = csrr(CSR_DSCRATCH0, 5'd8);
                    // GPR/FPR access
                    end else if (regno[12]) begin
                        // determine to access FPR or GPR
                        if (regno[5]) begin
                            abstract_cmd[2][31:0] = float_store(aarsize, regno[4:0], LoadBaseAddr, DataAddr);
                        end else begin
                            abstract_cmd[2][31:0] = store(aarsize, regno[4:0], LoadBaseAddr, DataAddr);
                        end
                    // CSR access
                    end else begin
                        abstract_cmd[2][31:0]  = csrw(CSR_DSCRATCH0, 5'd8);
                        abstract_cmd[2][63:32] = csrr(regno[11:0], 5'd8);
                        abstract_cmd[3][31:0]  = store(aarsize, 5'd8, LoadBaseAddr, DataAddr);
                        abstract_cmd[3][63:32] = csrr(CSR_DSCRATCH0, 5'd8);
                    end
                end else if ((aarsize >= MaxAar) || aarpostincrement) begin
                    abstract_cmd[0][31:0] = ebreak; // leave abstractcmd to avoid error
                    unsupported_command = 1'b1;
                end

                if (postexec && !unsupported_command) begin
                    // jump to program buffer directly
                    abstract_cmd[4][63:32] = nop;
                end
            end
            default: begin
                abstract_cmd[0][31:0] = ebreak;
                unsupported_command = 1'b1;
            end
        endcase
    end

    // output connection
    always @(*) begin
        abstract_cmd0_o = abstract_cmd[0];
        abstract_cmd1_o = abstract_cmd[1];
        abstract_cmd2_o = abstract_cmd[2];
        abstract_cmd3_o = abstract_cmd[3];
        abstract_cmd4_o = abstract_cmd[4];
        abstract_cmd5_o = abstract_cmd[5];
        abstract_cmd6_o = abstract_cmd[6];
        abstract_cmd7_o = abstract_cmd[7];
        unsupported_command_o = unsupported_command;
    end

    assign transfer_o = transfer;
    assign postexec_o = postexec;
    assign cmd_cmdtype_o = cmd_cmdtype;
endmodule
