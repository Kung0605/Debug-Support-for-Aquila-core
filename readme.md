# Debug Support for Aquila core
## Abstract
Due to the increasing complexity in modern microprocessor, the Debug Module(DM) become much more important nowadays to help user to understand and change the state of processor, so users can find out where is the bug more easily. For processor designer, DM can also help them to check the functionality of processor is correct or not. 

This study implement a DM partially compatible with [RISCV-debug-release 0.13.2](https://riscv.org/wp-content/uploads/2019/03/riscv-debug-release.pdf), and also add some hardware extension in Aquila core to work with DM.
### Features
- Functionality
	- halt, resume, step, reset on a hart
	- memory access 
	- registers(GPRs/CSRs) access
	- hardware breakpoint
- HW requirement 
    - can be synthesized on Xilinx arty-a7100t
    - connected to host PC via USB with the help of [Xilinx BSCANE2 primitive](https://docs.amd.com/r/2021.1-English/ug953-vivado-7series-libraries/BSCANE2), no extra JTAG cable is required
- SW requirement
    - use [openOCD-riscv](https://github.com/riscv-collab/riscv-openocd) to connect debug module and host PC
    - build [riscv-toolchain](https://github.com/riscv-collab/riscv-gnu-toolchain/tree/master) and debug with gdb

### Compatibility to RISCV-debug specification
**Feature**                            | **Support**
-------------------------------------- | --------------------------------------------------------------------------------------
Hardware trigger        | Support up to 32 breakpoints, while watchpoint are not implemented currently.
System Bus Access (SBA)  | Not supported at this time.
Program buffer for core to run any instruction | Supported.
Multiple hart support | Not supported at this time.
Abstract Command | Support to access GPR. other type can be done by program buffer

## System overview
![block diagram of debug module](./doc/Block_diagram.png)
<br>
*From chap 2 of RISCV-debug spec*

## Component

### Debug Module Control and Status registers (dm_csrs)

There are several register in the debug module, host can write to these registers to control the debug system and read from these registers to get the information about the core or retrieve returned data of previous command.

- **Debug Module Control** (dmcontrol, 0x10): <br> Host will write to this register to control the state of current selected core<details open="true"><summary>Expand all</summary>
    
    **Field** | **Access** | **Usage**
    ----------|------------|----------
    haltreq | W | Write to this field to halt the core
    resumereq | W | Write to this field to resume a halted core
    ndmreset | W/R | Write to this field to reset the system except for the debug module
    dmactive | W/R | Write 1 to this field to indicate the debug module is activated
</details>

- **Debug Module Status** (dmstatus, 0x11):<br>This register contains the core's information, host can read it to check if the debug system work correctly<details open="true"><summary>Expand all</summary>

    **Field** | **Access** | **Usage** 
    ----------|------------|-----------
    all/anyhavereset | R | Read from this field to check if the core reset correctly
    all/anyresumeack | R | Read from this field to check if the last resume request have been acked by the debug module
    all/anyrunning | R | Read from this field to check if the core are running(not in debug mode)
    all/anyhalted | R | Read from this field to check if the core are in debug mode
</details>

- **Abstract Command Control and Status** (abstractcs, 0x16):<br>Host can read this register to get the information about Abstract Command or Program Buffer<details open="true"><summary>Expand all</summary>

    **Field** | **Access** | **Usage** 
    ----------|------------|-----------
    progbufsize | R | The size of program buffer, which is 8 in our implementation
    busy | R | This bit will be set when the abstract command is running on the core
    cmderr | R/W1C | 0 (None): no error<br>1 (busy): debug module is executing abstract command<br>2 (not support): the given abstract command is not supported<br>4 (halt/resume): the command can't be executed due to the incorrect state of the core
    datacount | R | The size of data register, which is 2 in our implementation
</details>

- **Abstract Command** (command, 0x17):<br>Write to this register will make the hardware to generate corresponding instruction for performing certain operation, which will save time from writing to program buffer<details open="true"><summary>Expand all</summary>

    **Field** | **Access** | **Usage**
    ----------|------------|-----------
    cmdtype | W | 1. Access Register: Read/Write to CSR or GPR<br>2.Quick Access: Not implemented
    control | W | Specify the operation on target register
</details>

- **Program Buffer** (progbuf0-progbuf15, 0x20-0x2f):<br>Since our implementation does not support using abstracts command to read/write memory, program buffer is needed to provide assistance for memory operation<details open="true"><summary>Expand all</summary>

    **Field** | **Access** | **Usage**
    ----------|------------|-----------
    data | W | Write instructions to these registers to make the core to run any instructions
</details>

### Debug Memory (dm_mem)

This is a 16kB memory interface of Debug Module, the functionality of this module are listed below:
- **Debug Rom** (For execution-based debug):<br>In reality, halting a core by stopping the clock is difficult to implement, so it is not a good idea to do that in our design. Instead, when a halt request is coming, the PC will be set to the predefined *halt address*, which contains a loop consists of a set of instructions. 
> The content of Debug Rom are reference from [Rocket-Chip's debug rom](https://github.com/chipsalliance/rocket-chip/blob/master/scripts/debug_rom/debug_rom_nonzero.S)
- **Debug Ram**:
    - Program Buffer:<br>User can write arbitrary instruction into Program Buffer to force the core to do anything.
    - Abstract Command:<br>In order to access registers, the debug module will generate series of instruction to get the register's value and write them into Data registers.
    - Data:<br>User can store Data in these blocks and load Data to core, and core can also return requested data by save them to these blocks.
- **Memory mapping**:<details open="true"><summary>Expand all</summary>
    **Address** | **Description** 
    ------------|-----------------
    0x000-0x0ff | unused
    0x100 | **Halted**, core will write to this address to confirm it is halted
    0x108 | **Going**, core will write to this address to confirm it is executing some command
    0x110 | **Resuming**, core will write to this address to confirm it is resuming
    0x330 | **whereto**, core will jump to this address whenever the abstract command or program buffer are set correctly, and the instruction at this address will decide where to jump to(Abstract Command or Program Buffer)
    0x338-0x35f | **Abstract Command**
    0x360-0x37f | **Program Buffer**
    0x380-0x387 | **Data**, host can read returned data from this address
    0x800-0x1000 | **Debug Rom**, as described as above
    0x800 | **Halt Address**, core will jump to here when it is requested to halt
    0x808 | **Resume Address**, core will jump to here when it is requested to resume

</details>

- State transition diagram for debug memory:<br>
![State transition for dm_mem](./doc/FSM_dm_mem_0.svg)
### Debug Module Jtag Interface (dmi_jtag)
With regard to construct communication between host PC and debug module, we choose JTAG as our communication protocol. The main purpose of this module is receiving JTAG signal from host PC to generate debug request(dmi_req), and receiving dmi_resp from debug module and translating it into JTAG signal for transmission.

- **Debug request and Debug response**:
    - Debug request:<br>
        **address** | **op** | **data** 
        ------------|--------|---------
        Target address | specify the operation is Read/Write | Read: Have no usage<br> Write: Specify the value to write to target address
    - Debug response:<br>
        **data** | **resp** 
        ---------|---------
        Write: Have no usage<br>Read: Returned data for previous request | **DTM_SUCCESS**: The request is correctly served and data is returned<br>**DTM_ERR**: There is some error during previous request<br>**DTM_BUSY**: DTM(Debug transport module) is busy, host should slow down the rate of sending request
    - Handshaking protocol:<br>
        For the correctness of the communication, two-way handshake is adopted in our design.
    <details open="true"><summary>Expand the example</summary>
    <img style="width:max(400px, 50%);" src = "./doc/dmi_protocol.png"><br>
    this figure is download from <a href = https://github.com/pulp-platform/riscv-dbg/tree/master/doc>pulp-debug-system</a>
    </details>
- **Debug Transport Module**:
    - JTAG-Protocol [(IEEE standard for JTAG)](https://ieeexplore.ieee.org/stamp/stamp.jsp?tp=&arnumber=6515989):<br>
      Since Xilinx FPGA adopt USB-JTAG as a bridge for sending bitstream and gathering waveform captured by ILA(Integrated Logic Analyzer), choosing USB-JTAG can prevent our design from adding extra cable.
      ![JTAG FSM diagram](./doc/JTAG-TAP-Controller.png)
    - JTAG-TAP(JTAG-Test Access Port):<br>
      Xilinx provide [BSCANE2](https://docs.amd.com/r/2021.1-English/ug953-vivado-7series-libraries/BSCANE2) primitive for user to access USB-JTAG directly, they will form a daisy-chain if there are more than one BSCANE2 are instantiated. We use two BSCANE2 primitive to avoid the higher complexity of using tunnel mode as discussed in [this issue](https://github.com/openhwgroup/core-v-mcu/issues/117#issuecomment-826280883)
      ![dmi_jtag_state](./doc/FSM_dmi_jtag_0.svg)
    - Debug Transport Module CSR(dtmcs):<br>
      A register contain the current state information about DTM 
- **Clock-Domain-Crossing module**:<br>
    The Aquila core and Debug Module work in the same clock domain, but the host may construct JTAG connection with clock rate which is different from the core's, so a CDC module is necessary for host and core to prevent occurrence of errors.
> The CDC module is download from the [PULP's project](https://github.com/pulp-platform/riscv-dbg/blob/master/src/dmi_cdc.sv), not designed by myself.

## Changes in Aquila Core
For the Aquila Core to be compatible with our Debug Module implementation, some minimized and essential changes should be apply to the original aquila core.
- CSR_file:<br>
[RISC-V debug spec](chrome-extension://efaidnbmnnnibpcajpcglclefindmkaj/https://riscv.org/wp-content/uploads/2019/03/riscv-debug-release.pdf) defines several CSRs for supporting debug and they are listed below.
    - Core Debug Registers:<br>
        The following registers help the debug system work correctly.
        **Address** | **Name** | **Usage** 
        ------------|----------|-----------
        0x7B0 | dcsr | Stores the configuration of debug setting and status
        0x7B1 | dpc | Save the next PC before trapped into debug mode for resuming to correct address
        0x7B2 | dscratch0 | For debug module to store arbitrary information
        0x7B3 | dscratch1 | For debug module to store arbitrary information
    - Trigger Module:<br>
        The following registers are extension that support adding **hardware-assist breakpoint**
        **Address** | **Name** | **Usage**
        ------------|----------|----------
        0x7a0 | tselect | **Trigger Select**, write trigger number to this register to select which trigger to operating on
        0x7a1 | tdata1 | **Trigger data 1**, the higher 4 bits specify the type of trigger selected by tselect, which is hardwired to 2, indicating that the trigger is match control.
        0x7a1 | mcontrol | **Match Control**, this is the lower bits of the register, specify the function of selected trigger. Ex: trap into debug mode before/after instruction execution, trigger is activated in User/Machine/Debug mode, match condition is ==/>=/<=, etc.
        0x7a12 | tdata2 | **Match Value**, this register store the breakpoint address of selected trigger, when the PC in fetch stage match the value in this register, the trigger_match signal will be set, so the core can halt when that instruction being executed.
- Decode stage:<br>
    Add some logic to support decoding of risc-v instructions and integrate dret into system jump.
    **Instruction** | **Description**
    ----------------|----------------
    ebreak | User mode: Trap into debug mode. <br> Machine mode: Do nothing. <br> Debug mode: Jump to Haltaddress.
    dret | User mode: Do nothing.<br>Machine mode: Do nothing.<br>Debug mode: Jump to dpc.
- Program Counter:<br>
    Set PC to haltaddress when following event occur
    - External debug request
    - Execution of ebreak instruction
    - Trigger match
- Debug Controller:<br>
    The main module to control the debug state of Aquila core.
    - State transition of debug system:
    <img src="./doc/FSM_debug_controller_0.svg">
    - Determine the cause of debug by priority
        1. Breakpoint match.
        2. External debug request.
        3. Stepping.
- Core Top:<br>
    - Determine the value of dpc to store from the cause of debug
    - Connect signals of debug_controller to other modules
## How debugger(openOCD) interact with debug module
- **Halt the core**:<br>
    1. dmi_req = {8'h10, 2'h2, 32'h80000001}; // write to dmcontrol and set haltreq to 1
    2. dm_csr send debug_request to core
    3. core set PC to haltaddress, execute instruction in debug rom.
- **Resume the core**:<br>
    1. dmi_req = {8'h10, 2'h2, 32'h40000001}; // write to dmcontrol and set resumereq to 1
    2. Resume flag in dm_mem will be set to 1
    3. Core will branch to resumeaddress and execute the command for resume, which will end up with dret
- **Read/write register**:<br>
    1. dmi_req = {8'h17, 2'h2, 32'h00220XXX}; // write to command and read from XXX register
    2. dm_mem generate abstract command accordingly
    ```riscv
    Abstract_command:
        csrrw x0, dscratch1, x10 // backup x10 
        auipc x10, 0             // store current cp
        srli x10, x10, 12        // these two line calculate base address for debug memory from pc[31:20]
        slli x10, x10, 12 
        csrrw x0, dscratch0, x8  // backup x8
        csrrs x8, tdata1, x0     // store tdata1 in x8
        sw x8, 896(x10)          // store x8 to Data0 in debug memory
        csrrs x8, dscratch0, x0  // restore x8
        csrrs x10, dscratch1, x0 // restore x10
        ebreak                   // jump back to halt address
    ```
    3. Read Data0 to get value of target register
- **Read/Write Memory**:<br>
    1. Write lw/sw into program buffer.
    2. Execute instruction in program buffer to get value of memory / write data into memory.
    3. Read Data0/Data1 to retrieve returned data.
- **Breakpoint**:<br>
    1. Write a trigger number to tselect.
    2. Read tdata1 for selected trigger and check if the trigger type is correct.
    3. Write breakpoint address to tdata2(tmatch_value).
    4. If decode_stage's PC is equal to any element in tmatch_value(which is a array), debug_controller will raise a debug_halt_req to halt the core.

## Demo Example
- Construct openOCD connection:<br>
openOCD will open port 3333 for gdb to connect.
    ```
    User@bash:~/RISCV-debug-module-for-Aquila-Core/demo$ openocd -f arty-a7-openocd-cfg.tcl
    ```
    Example openOCD configuration script:<br>
    ```
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
    ```
- Run gdb with Aquila's bootcode (uartboot.elf) in another terminal:<br>
    1. Run gdb with Aquila's boot code:<br>
    ```
    RISCV-debug-module-for-Aquila-Core/demo$ riscv32-unknown-elf-gdb uartboot.elf
    ```
    2. Attach to port 3333 (the core had halted by openOCD)
    ```
    (gdb) tar ext:3333 
    ```
    3. Now you can control the core via GDB command.
    ```
    (gdb) c                #continue
    (gdb) ctrl+c           #halt
    (gdb) si               #step one instruction
    (gdb) load dhry.elf    #load .elf file into memory
    (gdb) b func           #set breakpoint on func
    (gdb) b *0x124         #set breakpoint on instrction memory address 0x124
    ```
    > Note:<br>
    My implmentation currently not support "halt on reset" feature, that is, if user reset the core(Ex: External reset button on FPGA or "run" command in gdb), they have to halt the core manually.<br>
    (gdb) mon halt

## Reference
- [openhwgroup/cv32e40p](https://github.com/openhwgroup/cv32e40p)
- [rocket-chip](https://github.com/chipsalliance/rocket-chip/tree/master)
- [lowRISC/ibex-demo-system](https://github.com/lowRISC/ibex-demo-system/tree/main)
- [lowRISC/ibex-core](https://github.com/lowRISC/ibex/tree/master)
- [riscv-openOCD](https://github.com/riscv-collab/riscv-openocd)
- [pulp/riscv-dbg](https://github.com/pulp-platform/riscv-dbg/blob/master/doc/debug-system.md)
- [riscv-toolchain](https://github.com/riscv-collab/riscv-gnu-toolchain)
- [Nios-debug-module](https://www.intel.com/content/www/us/en/docs/programmable/683632/21-4-21-1-1/risc-v-based-debug-module.html)
- [openhwgroup/cva6](https://github.com/openhwgroup/cva6)