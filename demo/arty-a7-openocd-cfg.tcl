# Important: openOCD will connect to the same USB port as vivado, in order to run openOCD, 
# user should close vivado's Hardware Manager first.
adapter driver ftdi                                     
transport select jtag                                      

# specify the USB device name
ftdi device_desc "Digilent USB Device"
# vid and pid are 
ftdi vid_pid 0x0403 0x6010
# ftdi channel 1 is unused
ftdi channel 0
ftdi layout_init 0x0088 0x008b
reset_config none

set _CHIPNAME riscv
# target board ID is given by Xilinx arty-a7-100t
set _EXPECTED_ID 0x13631093 

# create new jtag-tap(JTAG Test-Access-Port)
jtag newtap $_CHIPNAME cpu -irlen 6 -expected-id $_EXPECTED_ID -ignore-version
set _TARGETNAME $_CHIPNAME.cpu
target create $_TARGETNAME riscv -chain-position $_TARGETNAME

# Set the IR address for different registers
# this is only required while using Xilinx BSCANE2 primitive for jtag-tap
riscv set_ir idcode 0x09
riscv set_ir dtmcs 0x22
riscv set_ir dmi 0x23

# select jtag transmission rate
adapter speed 10000

# set the priority for different access method(only progbuf is supported currently)
riscv set_mem_access progbuf sysbus abstract
riscv set_command_timeout_sec 2

# error handling
gdb_report_data_abort enable
gdb_report_register_access_error enable

# force every breakpoint to be hardware-assisted breakpoint
gdb_breakpoint_override hard

reset_config none

# initialization
init
# halt the core
halt