# Environment Setup
## Install Vivado on WSL(ubuntu)
1. Download the installer for the linux in the [vivado's website](xilinx.com/support/downloads.html).
2. Copy the installer into WSL home directory.
3. Download the dependencies for the vivado's GUI.
    ``` 
    export XINSTALLER_SCALE=2
    sudo apt update
    sudo apt install libxrender1
    sudo apt install libxtst6
    sudo apt install libxi6
    sudo apt install lintinfo5
    ```
4. Run the vivado installer.
5. Configure the language option and set the environment variable
    ```
    sudo locale-gen en_US.UTF-8
    sudo localectl set-locale LANG=en_US.UTF-8
    sudo reboot
    export DISPLAY=:0
    ```
6. Add the Vivado to Path:<br>
    1. Find "settings64.sh" in "Download path"/Xilinx/Vivado/"version"/
    2. append "Download path"/Xilinx/Vivado/"version"/settings64.sh to ~/.bashrc
    3. 
        ```
        source ./.bashrc
        ```

## Install usbipd 
1. Download USBIPD in win-os
    ```
    winget install --interactive --exact dorssel.usbipd.win
    ```
2. Check the USB port and attach to WSL
    ```
    usbipd list # list all USB devices
    # suppose FPGA is at port 1-1
    usbipd bind -b 1-1
    usbipd attach -b 1-1 -w
    ```
3. check FPGA attached correctly(run un linux)
    ```
    lsusb
    ```