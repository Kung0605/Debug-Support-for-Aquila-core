module dmi_jtag_tap (
  // control logic of JTAG-protocol
  output         tck_o,
  output         dmi_clear_o,
  output         update_o,
  output         capture_o,
  output         shift_o,
  output         tdi_o,
  // Access debug transport module's CSRs
  output         dtmcs_select_o,
  input          dtmcs_tdo_i,
  // Access debug module's CSRs
  output         dmi_select_o,
  input          dmi_tdo_i
);

  BSCANE2 #(
    .JTAG_CHAIN (3)
  ) i_tap_dtmcs (
    .CAPTURE (capture_o),
    .DRCK (),
    .RESET (dmi_clear_o),
    .RUNTEST (),
    .SEL (dtmcs_select_o),
    .SHIFT (shift_o),
    .TCK (tck_o),
    .TDI (tdi_o),
    .TMS (),
    .TDO (dtmcs_tdo_i),
    .UPDATE (update_o)
  );

  BSCANE2 #(
    .JTAG_CHAIN (4)
  ) i_tap_dmi (
    .CAPTURE (),
    .DRCK (),
    .RESET (),
    .RUNTEST (),
    .SEL (dmi_select_o),
    .SHIFT (),
    .TCK (),
    .TDI (),
    .TMS (),
    .TDO (dmi_tdo_i),
    .UPDATE ()
  );

endmodule