`timescale 1ns / 1ps 
`define DbgVersion013 4'h2
  // size of program buffer in junks of 32-bit words
`define ProgBufSize   5'h8

  // amount of data count registers implemented
`define DataCount     4'h2

  // address to which a hart should jump when it was requested to halt
`define HaltAddress = 64'h800;
`define ResumeAddress = HaltAddress + 8;
`define ExceptionAddress = HaltAddress + 16;

  // address where data0-15 is shadowed or if shadowed in a CSR
  // address of the first CSR used for shadowing the data
`define DataAddr = 12'h380; // we are aligned with Rocket here