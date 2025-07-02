# PrivilegeOS

A lightweight, customizable Linux distribution built from source using the latest Linux kernel and BusyBox.

![PrivilegeOS Logo](./docs/images/logo.png)

## Overview

PrivilegeOS is a minimal Linux distribution that boots directly into a BusyBox environment. It's designed to be a starting point for custom Linux distributions, rescue systems, or educational purposes. The entire OS is built from source and packaged as a bootable UEFI disk image.

**Current Version:** 2.0 (Last Updated: 2025-07-02)

## Features

- **Minimal Footprint:** Built with only the essentials for a functional Linux system
- **UEFI Boot:** Modern boot process with EFI support
- **Hardware Support:** Includes drivers for common hardware components:
  - Intel, AMD, and NVIDIA graphics
  - Common network cards (wired and wireless)
  - USB devices
  - Laptop-specific hardware (batteries, keyboards, etc.)
- **Customizable:** Easy to modify kernel configuration and included packages
- **QEMU Testing:** Built-in virtual machine testing before deploying to physical hardware

## Requirements

### Build Environment

- **Operating System:** Linux (Debian, Ubuntu, Fedora, Arch, etc.)
- **Required Packages:**
  - Development tools: `gcc`, `make`, `bc`
  - Kernel build dependencies: `libncurses-dev`
  - Image tools: `parted`, `dosfstools`, `util-linux`
  - QEMU for testing: `qemu-system-x86_64`, `ovmf`
  - Miscellaneous: `wget`, `xz-utils`

### Hardware Requirements (for running PrivilegeOS)

- x86_64 compatible system
- UEFI firmware
- 512MB RAM minimum (1GB+ recommended)
- USB drive for deployment (minimum 512MB)

## Getting Started

### Quick Start

1. Clone this repository:
   ```
   git clone https://github.com/ktauchathuranga/privilegeos.git
   cd privilegeos
   ```

2. Run the build script:
   ```
   ./build_privilegeos.sh
   ```

3. Follow the prompts to build, test in QEMU, and optionally write to a USB drive.

### Installing Required Packages

#### Debian/Ubuntu
```bash
sudo apt-get update
sudo apt-get install build-essential libncurses-dev bc qemu-system-x86_64 ovmf parted dosfstools util-linux wget xz-utils
```

#### Fedora
```bash
sudo dnf install @development-tools ncurses-devel bc qemu-system-x86 edk2-ovmf parted dosfstools util-linux wget xz
```

#### Arch Linux
```bash
sudo pacman -S base-devel ncurses bc qemu ovmf parted dosfstools util-linux wget xz
```

## Usage

### Command Line Options

```
Usage: ./build_privilegeos.sh [options]

Options:
  -h, --help           Show this help message and exit
  -n, --name NAME      Set OS name (default: PrivilegeOS)
  -k, --kernel VER     Set kernel version (default: 6.15.3)
  -b, --busybox VER    Set BusyBox version (default: 1.36.1)
  -j, --threads N      Set number of threads for compilation (default: auto)
  -m, --memory SIZE    Set QEMU memory size (default: 2G)
  -s, --size SIZE      Set disk image size in MB (default: 512)
  -c, --clean          Clean build directory before starting
  -q, --qemu-only      Only build and test in QEMU (no USB writing)
  --skip-qemu          Skip QEMU testing
  --kernel-config FILE Use custom kernel config file
```

### Examples

Build with a custom name and kernel version:
```bash
./build_privilegeos.sh --name MyCustomOS --kernel 6.16.0
```

Clean build with more threads:
```bash
./build_privilegeos.sh --clean --threads 8
```

Build for testing in QEMU only:
```bash
./build_privilegeos.sh --qemu-only
```

## Build Process

The build process consists of the following steps:

1. **Dependency Check:** Verifies all required tools are installed
2. **Workspace Setup:** Creates build directories
3. **Source Download:** Downloads Linux kernel and BusyBox (if not present)
4. **BusyBox Build:** Compiles BusyBox with static linkage
5. **initramfs Creation:** Sets up the initial RAM filesystem structure
6. **Kernel Build:** Compiles the Linux kernel with embedded initramfs
7. **Disk Image Creation:** Creates a bootable UEFI disk image
8. **QEMU Testing:** Tests the build in a virtual machine
9. **USB Writing:** Writes the disk image to a USB drive (optional)

## Customization

### Kernel Configuration

The build script creates a default kernel configuration with common hardware support. To customize:

1. Run the build script once to generate the initial config
2. Modify `configs/kernel.config`
3. Run the build script again with the `--clean` option

### Custom initramfs Content

To add custom files or scripts to the initramfs:

1. Run the build script normally until it completes
2. Add your files to the `build/initramfs` directory
3. Run `./build_privilegeos.sh --skip-busybox` to rebuild with your changes

### Boot Parameters

To modify kernel boot parameters, edit the `build_privilegeos.sh` script and look for the line:

```bash
./scripts/config --set-str CONFIG_CMDLINE "console=tty0 console=ttyS0"
```

## Booting PrivilegeOS

### From QEMU

The build script includes QEMU testing functionality. Use the `--qemu-only` option to build and test without writing to USB.

### From USB Drive

1. Insert your USB drive
2. Run `./build_privilegeos.sh` and follow the prompts
3. Boot your target computer from the USB drive
4. Ensure UEFI boot is enabled in your BIOS settings

## Troubleshooting

### Common Issues

#### "Kernel build failed"
- Ensure you have all required development packages
- Try using `--clean` to start with a fresh build
- Check the log files in `build/logs/kernel_build.log`

#### "Failed to boot in QEMU"
- Check if virtualization is enabled in your BIOS
- Ensure you have the OVMF package installed
- Try increasing memory with `--memory 4G`

#### "USB drive not recognized after writing"
- Some BIOSes may need Secure Boot disabled
- Verify the USB drive is set as a boot device in BIOS
- Try another USB port (preferably USB 2.0)

### Logs

Build logs are stored in the `build/logs` directory and can be useful for debugging:

- `build.log`: Overall build log
- `busybox_build.log`: BusyBox compilation log
- `kernel_build.log`: Kernel compilation log

## Contributing

Contributions are welcome! Here's how you can contribute:

1. Fork the repository
2. Create a feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## License

This project is licensed under the MIT License - see the LICENSE file for details.

