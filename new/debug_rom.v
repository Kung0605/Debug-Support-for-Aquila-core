module debug_rom (
  input           clk_i,
  input           rst_ni,
  input           req_i,
  input   [63:0]  addr_i,
  output  [63:0]  rdata_o
);

  localparam RomSize = 20;

  wire [63:0] mem[RomSize-1:0];
  assign mem[0]  = 64'h00000013_0180006f;
  assign mem[1]  = 64'h00000013_0840006f;
  assign mem[2]  = 64'h00000013_0500006f;
  assign mem[3]  = 64'h7b241073_0ff0000f;
  assign mem[4]  = 64'h00000517_7b351073;
  assign mem[5]  = 64'h00c51513_00c55513;
  assign mem[6]  = 64'h10852023_f1402473;
  assign mem[7]  = 64'h40044403_00a40433;
  assign mem[8]  = 64'h02041c63_00147413;
  assign mem[9]  = 64'h00a40433_f1402473;
  assign mem[10] = 64'h00247413_40044403;
  assign mem[11] = 64'hfd5ff06f_fa0418e3;
  assign mem[12] = 64'h00c55513_00000517;
  assign mem[13] = 64'h10052c23_00c51513;
  assign mem[14] = 64'h7b202473_7b302573;
  assign mem[15] = 64'h10052423_00100073;
  assign mem[16] = 64'h7b202473_7b302573;
  assign mem[17] = 64'hf1402473_a79ff06f;
  assign mem[18] = 64'h7b302573_10852823;
  assign mem[19] = 64'h7b200073_7b202473;

  wire [$clog2(RomSize)-1:0] addr_d;
  reg  [$clog2(RomSize)-1:0] addr_q;

  assign addr_d = req_i ? addr_i[$clog2(RomSize)-1+3:3] : addr_q;

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      addr_q <= 0;
    end else begin
      addr_q <= addr_d;
    end
  end
  assign rdata_o = (addr_q < RomSize) ? mem[addr_q] : 0;

endmodule