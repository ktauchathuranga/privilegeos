# PrivilegeOS

**A specialized Linux distribution designed for penetration testing and Windows admin access bypass**

![PrivilegeOS Banner](docs/banner.png)

## 📋 Table of Contents

* [Overview](#-overview)
* [Features](#-features)
* [System Requirements](#-system-requirements)
* [Installation](#-installation)
* [Usage](#-usage)
* [Built-in Tools](#️-built-in-tools)
* [Windows Admin Bypass](#-windows-admin-bypass)
* [Building from Source](#-building-from-source)
* [Configuration](#️-configuration)
* [Troubleshooting](#-troubleshooting)
* [Security Notice](#-security-notice)
* [Contributing](#-contributing)
* [License](#-license)
* [Changelog](#-changelog)
* [Acknowledgments](#-acknowledgments)

## 🔍 Overview

PrivilegeOS is a minimal, bootable Linux distribution built specifically for penetration testing scenarios involving Windows systems. It features native NTFS3 kernel support, custom penetration testing tools, and specialized utilities for Windows admin access bypass techniques.

**Key Characteristics:**
- **Lightweight**: ~512MB bootable image
- **Fast Boot**: Boots in under 30 seconds
- **No Installation Required**: Runs entirely from USB/CD
- **Root Access**: Automatic root login
- **NTFS3 Support**: Native kernel NTFS driver for reliable Windows filesystem access
- **UEFI Compatible**: Modern firmware support

## ✨ Features

### Core System
- **Linux Kernel**: 6.15.3 with custom configuration
- **Init System**: BusyBox with custom scripts
- **Filesystem Support**: NTFS3 (native), FAT32, EXT4, XFS, BTRFS
- **Network Support**: Ethernet and Wi-Fi drivers
- **Storage Support**: SATA, NVMe, USB storage devices
- **Graphics Support**: Intel, AMD, NVIDIA drivers

### Security Tools
- **Windows Admin Bypass**: Sticky keys replacement technique
- **NTFS Mount Tools**: Advanced NTFS mounting with various options
- **Drive Analysis**: Comprehensive partition and filesystem detection
- **Network Tools**: Basic network diagnostics and configuration

### User Experience
- **Automatic Boot**: No user interaction required
- **Color-coded Interface**: Easy-to-read terminal output
- **Command Aliases**: Simplified commands for common operations
- **Help System**: Built-in documentation and examples

## 💻 System Requirements

### Minimum Requirements
- **CPU**: x86-64 compatible processor
- **RAM**: 1GB (2GB recommended)
- **Storage**: 1GB available space for USB creation
- **Firmware**: UEFI or Legacy BIOS support

### Recommended Requirements
- **CPU**: Intel Core i3 or AMD equivalent
- **RAM**: 4GB or more
- **Storage**: USB 3.0+ drive for faster boot times
- **Network**: Ethernet or Wi-Fi adapter

### Supported Hardware
- **Storage Controllers**: AHCI, NVMe, USB
- **Network Adapters**: Intel, Realtek, Atheros, Broadcom
- **Graphics Cards**: Intel integrated, AMD, NVIDIA
- **Input Devices**: USB keyboards, mice, touchpads

## 🚀 Installation

### Quick Start

1. **Download** the latest PrivilegeOS image:
   ```bash
   wget https://github.com/ktauchathuranga/privilegeos/releases/latest/PrivilegeOS.img
   ```

2. **Write to USB** drive (replace `/dev/sdX` with your USB device):
   ```bash
   sudo dd if=PrivilegeOS.img of=/dev/sdX bs=8M status=progress conv=fsync
   ```

3. **Boot** from USB drive:
   - Enable UEFI boot in BIOS/firmware settings
   - Select USB drive as boot device
   - PrivilegeOS will boot automatically

### Alternative Methods

#### Using Balena Etcher (GUI)
1. Download [Balena Etcher](https://www.balena.io/etcher/)
2. Select PrivilegeOS.img file
3. Select your USB drive
4. Click "Flash"

#### Using Rufus (Windows)
1. Download [Rufus](https://rufus.ie/)
2. Select your USB drive
3. Select PrivilegeOS.img as boot selection
4. Set partition scheme to GPT
5. Click "START"

## 📖 Usage

### First Boot

When PrivilegeOS boots, you'll see:

```
  ____       _       _ _                  ___  ____  
 |  _ \ _ __(_)_   _(_) | ___  __ _  ___ / _ \/ ___| 
 | |_) | '__| \ \ / / | |/ _ \/ _` |/ _ \ | | \___ \ 
 |  __/| |  | |\ V /| | |  __/ (_| |  __/ |_| |___) |
 |_|   |_|  |_| \_/ |_|_|\___|\__, |\___|\___/|____/ 
                              |___/                 

Welcome to PrivilegeOS!
Build date: 2025-07-06 11:51:07
You are running as: ROOT

Hardware Information:
====================
Intel(R) Core(TM) i7-8750H CPU @ 2.20GHz
Memory: 1024/8192 MB
NTFS3 support: AVAILABLE (native kernel driver)

Custom commands available:
  - getadmin
  - putadmin
  - getdrives

Type 'poweroff' or 'reboot' to exit.
To mount NTFS drives: mount -t ntfs3 /dev/sdXN /mnt

/ # 
```

### Basic Commands

```bash
# List all storage devices
getdrives

# Mount NTFS partition
mount -t ntfs3 /dev/sda2 /mnt

# Navigate mounted drive
cd /mnt
ls -la

# Windows admin bypass
getadmin --help
getadmin -f -d

# Restore Windows to normal
putadmin --help
putadmin -f

# Network configuration
ip addr show
ip link set eth0 up
```

### Command Reference

| Command | Description | Example |
|---------|-------------|---------|
| `getdrives` | List all drives and partitions | `getdrives` |
| `getadmin` | Windows admin bypass tool | `getadmin -f -d` |
| `putadmin` | Restore Windows to normal | `putadmin -f` |
| `mount-ntfs` | Mount NTFS partition (alias) | `mount-ntfs /dev/sda2 /mnt` |
| `poweroff` | Shutdown system | `poweroff` |
| `reboot` | Restart system | `reboot` |

## 🛠️ Built-in Tools

### Drive Management Tools

#### `getdrives`
Comprehensive drive and partition analysis tool.

**Features:**
- Partition table display
- Filesystem detection
- Mount status
- Disk usage information
- NTFS3 compatibility check

**Usage:**
```bash
getdrives
```

**Output Example:**
```
===============================================
            STORAGE DEVICES LIST
===============================================

Partition Table:
MAJOR MINOR  #BLOCKS  NAME
8        0  488386584 sda
8        1     204800 sda1
8        2  488179712 sda2

Filesystem Detection:
/dev/sda1: vfat
/dev/sda2: ntfs

NTFS3 Commands (Native Kernel Driver):
Mount NTFS partition: mount -t ntfs3 /dev/sdXN /mnt
Mount NTFS read-only: mount -t ntfs3 -o ro /dev/sdXN /mnt
```

### Windows Admin Bypass Tools

#### `getadmin`
Advanced Windows admin access bypass tool using sticky keys replacement.

**Features:**
- Automatic Windows partition detection
- Hibernation file handling
- File integrity verification
- Multiple mount options
- Comprehensive logging

**Usage:**
```bash
# Basic usage
getadmin

# Force mount with hibernation file deletion
getadmin --force --delete-hiberfil

# Show help
getadmin --help
```

**Options:**
- `-f, --force`: Use force option when mounting NTFS partitions
- `-d, --delete-hiberfil`: Delete hiberfil.sys if found
- `-h, --help`: Show help message

#### `putadmin`
Windows system restoration tool to reverse getadmin modifications.

**Features:**
- Automatic backup detection
- File restoration verification
- Cleanup of temporary files
- Safety checks and confirmations

**Usage:**
```bash
# Basic restoration
putadmin

# Force restoration
putadmin --force

# Show help
putadmin --help
```

## 🔧 Windows Admin Bypass

### Overview

PrivilegeOS includes a sophisticated Windows admin bypass system that uses the "sticky keys" replacement technique. This method is commonly used in penetration testing to gain administrative access to Windows systems.

### How It Works

1. **Detection**: Script scans for Windows NTFS partitions
2. **Mounting**: Mounts Windows filesystem with write access
3. **Backup**: Creates backup of original system files
4. **Replacement**: Replaces `sethc.exe` with `cmd.exe`
5. **Verification**: Confirms operation success

### Usage Process

#### Step 1: Boot PrivilegeOS
Boot from USB and wait for the command prompt.

#### Step 2: Run getadmin
```bash
/ # getadmin --force --delete-hiberfil
```

#### Step 3: Confirm Operation
When prompted, type `YES` to confirm the modification.

#### Step 4: Boot Windows
Restart and boot into Windows normally.

#### Step 5: Access Admin Shell
At the Windows login screen, press `Shift` five times. Instead of sticky keys, a command prompt with SYSTEM privileges will open.

#### Step 6: Create Admin User
```cmd
net user administrator /active:yes
net user newadmin password123 /add
net localgroup administrators newadmin /add
```

#### Step 7: Restore System (Optional)
Boot back into PrivilegeOS and run:
```bash
/ # putadmin --force
```

### Security Considerations

⚠️ **WARNING**: This technique should only be used on systems you own or have explicit permission to test.

- **Legal**: Ensure you have proper authorization
- **Detection**: May be detected by security software
- **Forensics**: Leaves traces in system logs
- **Backup**: Always create backups before modification

## 🔨 Building from Source

### Prerequisites

#### Required Packages (Ubuntu/Debian)
```bash
sudo apt-get update
sudo apt-get install -y \
    build-essential \
    gcc \
    make \
    bc \
    libncurses-dev \
    flex \
    bison \
    libelf-dev \
    libssl-dev \
    qemu-system-x86_64 \
    ovmf \
    parted \
    dosfstools \
    wget \
    xz-utils
```

#### Required Packages (Fedora/CentOS)
```bash
sudo dnf install -y \
    gcc \
    make \
    bc \
    ncurses-devel \
    flex \
    bison \
    elfutils-libelf-devel \
    openssl-devel \
    qemu-system-x86 \
    edk2-ovmf \
    parted \
    dosfstools \
    wget \
    xz
```

### Build Process

#### 1. Clone Repository
```bash
git clone https://github.com/ktauchathuranga/privilegeos.git
cd privilegeos
```

#### 2. Basic Build
```bash
./build.sh
```

#### 3. Custom Build Options
```bash
# Clean build with custom size
./build.sh --clean --size 1024 --threads 8

# QEMU-only testing
./build.sh --qemu-only

# Custom kernel and BusyBox versions
./build.sh --kernel 6.15.3 --busybox 1.36.1

# Use custom configurations
./build.sh --kernel-config my_kernel.config --busybox-config my_busybox.config
```

#### 4. Build Options Reference

| Option | Description | Example |
|--------|-------------|---------|
| `--clean` | Clean build directory | `--clean` |
| `--size SIZE` | Disk image size in MB | `--size 1024` |
| `--threads N` | Compilation threads | `--threads 8` |
| `--memory SIZE` | QEMU memory size | `--memory 4G` |
| `--qemu-only` | Test in QEMU only | `--qemu-only` |
| `--skip-qemu` | Skip QEMU testing | `--skip-qemu` |
| `--kernel-config FILE` | Custom kernel config | `--kernel-config my.config` |
| `--busybox-config FILE` | Custom BusyBox config | `--busybox-config my.config` |

### Adding Custom Scripts

#### 1. Create Script Directory
```bash
mkdir -p scripts
```

#### 2. Add Your Scripts
```bash
# Example custom script
cat > scripts/myscript.sh << 'EOF'
#!/bin/sh
echo "Hello from custom script!"
EOF
chmod +x scripts/myscript.sh
```

#### 3. Rebuild
```bash
./build.sh
```

#### 4. Use in PrivilegeOS
After rebuilding, your script will be available as:
```bash
/ # myscript
Hello from custom script!
```

### Build Directory Structure

```
privilegeos/
├── build.sh      # Main build script
├── scripts/                   # Custom scripts directory
│   ├── getadmin.sh           # Windows admin bypass tool
│   ├── putadmin.sh           # Windows restoration tool
│   └── getdrives.sh          # Drive analysis tool
├── configs/                   # Configuration files
│   ├── kernel.config         # Kernel configuration
│   └── busybox.config        # BusyBox configuration
├── build/                     # Build output directory
│   ├── PrivilegeOS.img       # Final disk image
│   ├── initramfs/            # Root filesystem
│   └── logs/                 # Build logs
├── linux-6.15.3/            # Kernel source (downloaded)
├── busybox-1.36.1/           # BusyBox source (downloaded)
└── README.md                 # This file
```

## ⚙️ Configuration

### Kernel Configuration

The kernel is configured with these key features:

#### Filesystem Support
- **NTFS3**: Native kernel NTFS driver
- **FAT32/VFAT**: Windows filesystem support
- **EXT4**: Linux filesystem support
- **XFS/BTRFS**: Advanced filesystems

#### Hardware Support
- **Storage**: AHCI, NVMe, USB storage
- **Network**: Ethernet and Wi-Fi drivers
- **Graphics**: Intel, AMD, NVIDIA drivers
- **Input**: USB keyboards and mice

#### Security Features
- **EFI**: UEFI boot support
- **Framebuffer**: Console graphics support
- **Serial**: Debug console support

### BusyBox Configuration

BusyBox is configured with these utilities:

#### Core Utilities
- `ls`, `cp`, `mv`, `rm`, `mkdir`, `rmdir`
- `cat`, `more`, `less`, `grep`, `sed`, `awk`
- `tar`, `gzip`, `gunzip`, `find`, `which`

#### System Utilities
- `mount`, `umount`, `df`, `du`, `free`
- `ps`, `top`, `kill`, `killall`
- `chmod`, `chown`, `chgrp`

#### Network Utilities
- `ping`, `wget`, `ip`, `ifconfig`
- `netstat`, `route`, `arp`

#### File Utilities
- `blkid`, `fdisk`, `lsblk`
- `mkfs.vfat`, `fsck`

### Custom Configurations

#### Network Configuration
```bash
# Static IP configuration
ip addr add 192.168.1.100/24 dev eth0
ip route add default via 192.168.1.1

# DHCP configuration
ip link set eth0 up
# DHCP client would need to be added manually
```

#### Mount Options
```bash
# NTFS read-write with full permissions
mount -t ntfs3 -o rw,uid=0,gid=0,fmask=133,dmask=022 /dev/sda2 /mnt

# NTFS read-only
mount -t ntfs3 -o ro /dev/sda2 /mnt

# NTFS with force (hibernated systems)
mount -t ntfs3 -o rw,force /dev/sda2 /mnt
```

## 🔧 Troubleshooting

### Common Issues

#### Boot Issues

**Problem**: System doesn't boot from USB
**Solutions:**
1. Verify UEFI boot is enabled in BIOS
2. Disable Secure Boot if enabled
3. Try different USB ports (USB 2.0 vs 3.0)
4. Re-write image to USB with different tool

**Problem**: Kernel panic on boot
**Solutions:**
1. Check hardware compatibility
2. Try booting with `acpi=off` parameter
3. Verify image integrity with checksum

#### NTFS Mounting Issues

**Problem**: Cannot mount NTFS partition
**Solutions:**
1. Check if NTFS3 is available: `grep ntfs3 /proc/filesystems`
2. Try force mounting: `mount -t ntfs3 -o rw,force /dev/sdX /mnt`
3. Check for hibernation: look for `hiberfil.sys`
4. Verify partition exists: `fdisk -l`

**Problem**: "Read-only file system" error
**Solutions:**
1. Remount with write permissions: `mount -o remount,rw /mnt`
2. Check filesystem errors: `fsck.ntfs /dev/sdX`
3. Remove hibernation file: `rm /mnt/hiberfil.sys`

#### getadmin Issues

**Problem**: No Windows partition found
**Solutions:**
1. Use force option: `getadmin --force`
2. Check partitions manually: `getdrives`
3. Try different mount options
4. Verify Windows is not BitLocker encrypted

**Problem**: Permission denied errors
**Solutions:**
1. Check file permissions: `ls -la /mnt/Windows/System32/`
2. Try changing permissions: `chmod 755 /mnt/Windows/System32/sethc.exe`
3. Use force mount option
4. Check for file attributes: `lsattr /mnt/Windows/System32/sethc.exe`

**Problem**: Bypass doesn't work in Windows
**Solutions:**
1. Verify file sizes changed: `ls -la /mnt/Windows/System32/sethc.exe`
2. Check backup was created: `ls -la /mnt/Windows/System32/sethc.exe.backup`
3. Try restoration and re-application: `putadmin` then `getadmin`
4. Check Windows version compatibility

### Debug Information

#### System Information
```bash
# Check kernel version and modules
uname -a
lsmod | grep ntfs

# Check loaded filesystems
cat /proc/filesystems

# Check memory usage
free -m

# Check storage devices
cat /proc/partitions
```

#### Network Debugging
```bash
# Check network interfaces
ip addr show

# Check network connectivity
ping 8.8.8.8

# Check DNS resolution
nslookup google.com
```

#### Storage Debugging
```bash
# Check block devices
lsblk

# Check filesystem types
blkid

# Check mount points
mount | grep /dev/

# Check disk usage
df -h
```

### Log Files

#### Build Logs
- `build/logs/build.log` - Main build log
- `build/logs/kernel_build.log` - Kernel compilation log
- `build/logs/busybox_build.log` - BusyBox compilation log

#### Runtime Logs
- `/var/log/dmesg.log` - Kernel messages
- `/tmp/rcS_started` - Init script status
- `/tmp/rcS_completed` - Init completion status

### Getting Help

#### Community Support
- **GitHub Issues**: [Report bugs and request features](https://github.com/ktauchathuranga/privilegeos/issues)
- **Discussions**: [Ask questions and share tips](https://github.com/ktauchathuranga/privilegeos/discussions)

## 🔒 Security Notice

### Legal Disclaimer

**PrivilegeOS is designed for educational and authorized penetration testing purposes only.**

By using this software, you acknowledge that:

1. **Authorization Required**: You will only use this tool on systems you own or have explicit written permission to test
2. **Legal Compliance**: You will comply with all applicable local, state, and federal laws
3. **No Malicious Use**: You will not use this tool for unauthorized access, data theft, or malicious purposes
4. **Educational Purpose**: This tool is intended for learning about security vulnerabilities and defensive measures

### Ethical Guidelines

#### Responsible Disclosure
If you discover vulnerabilities using PrivilegeOS:
1. Report to the affected vendor first
2. Allow reasonable time for patching
3. Follow coordinated disclosure practices
4. Do not exploit for personal gain

#### Professional Use
For security professionals:
1. Obtain proper authorization before testing
2. Document all activities for client records
3. Follow industry best practices
4. Provide constructive remediation advice

### Technical Security

#### Detection Avoidance
This tool may be detected by:
- Antivirus software
- Host-based intrusion detection systems
- File integrity monitoring
- Behavioral analysis tools

#### Forensic Considerations
This tool may leave traces including:
- Modified system files
- Backup files in System32
- Registry changes (if additional tools used)
- Event log entries

### Updates and Patches

#### Security Updates
- Monitor for kernel security updates
- Update BusyBox for security fixes
- Review tool effectiveness regularly
- Test against latest Windows versions

#### Vulnerability Reporting
To report security issues in PrivilegeOS:
1. Email: security@example.com
2. Include detailed reproduction steps
3. Allow 90 days for response and fixing
4. Follow responsible disclosure guidelines

## 🤝 Contributing

We welcome contributions from the security community!

### Development Process

#### 1. Fork the Repository
```bash
git clone https://github.com/ktauchathuranga/privilegeos.git
cd privilegeos
git checkout -b feature/my-new-feature
```

#### 2. Make Changes
- Follow existing code style
- Add comprehensive comments
- Test thoroughly
- Update documentation

#### 3. Submit Pull Request
- Describe changes clearly
- Include test results
- Reference any related issues
- Sign commits with GPG key

### Contribution Guidelines

#### Code Standards
- **Shell Scripts**: Follow POSIX shell standards
- **Documentation**: Use clear, concise language
- **Comments**: Explain complex logic
- **Error Handling**: Include comprehensive error checking

#### Testing Requirements
- Test on multiple hardware configurations
- Verify UEFI and Legacy BIOS compatibility
- Test with various Windows versions
- Document any limitations or known issues

#### Documentation Updates
- Update README for new features
- Add help text for new commands
- Include usage examples
- Update troubleshooting section

### Development Environment

#### Setting Up Development Environment
```bash
# Install development dependencies
sudo apt-get install -y build-essential git

# Clone repository
git clone https://github.com/ktauchathuranga/privilegeos.git
cd privilegeos

# Create development branch
git checkout -b develop
```

#### Testing Changes
```bash
# Test build process
./build.sh --qemu-only

# Test specific components
./build.sh --clean --skip-qemu

# Test in virtual machine
qemu-system-x86_64 -bios /usr/share/ovmf/x64/OVMF.fd -drive file=build/PrivilegeOS.img,format=raw
```

## 📄 License

### Third-Party Licenses

#### Linux Kernel
Licensed under GNU General Public License v2.0
- **Source**: https://kernel.org/
- **License**: https://www.gnu.org/licenses/gpl-2.0.html

#### BusyBox
Licensed under GNU General Public License v2.0
- **Source**: https://busybox.net/
- **License**: https://www.gnu.org/licenses/gpl-2.0.html

#### Additional Components
All other components maintain their respective licenses. See individual source files for details.

## 📝 Changelog

### Version 2.0.0 (2025-07-06)

#### 🎉 Major Features
- **Native NTFS3 Support**: Replaced NTFS-3G with kernel NTFS3 driver
- **Enhanced Windows Bypass**: Improved getadmin tool with hibernation handling
- **Restoration Tool**: New putadmin tool for system restoration
- **UEFI Boot**: Full UEFI firmware support

#### 🔧 Improvements
- **Build System**: Completely rewritten build script with better error handling
- **Hardware Support**: Enhanced drivers for modern hardware
- **User Interface**: Color-coded output and improved messaging
- **Documentation**: Comprehensive README and help systems

#### 🐛 Bug Fixes
- Fixed mounting issues with hibernated Windows systems
- Resolved file permission problems on NTFS partitions
- Corrected unmounting failures
- Fixed kernel module loading issues

#### 🔒 Security Updates
- Updated kernel to 6.15.3 with latest security patches
- Improved file verification and backup systems
- Enhanced error handling to prevent system corruption
- Added comprehensive logging for audit trails

### Version 1.0.0 (2025-01-15)

#### 🎉 Initial Release
- **Core System**: Linux kernel 6.15.3 with BusyBox 1.36.1
- **NTFS Support**: NTFS-3G integration for Windows filesystem access
- **Basic Tools**: getdrives script for drive analysis
- **UEFI Support**: Basic UEFI boot capability
- **USB Boot**: Bootable USB image creation

#### 🔧 Features
- **Automatic Root**: No login required, automatic root access
- **Drive Detection**: Automatic storage device detection
- **Network Support**: Basic ethernet and Wi-Fi support
- **Build System**: Automated build process with QEMU testing

### Roadmap

#### Version 2.1.0 (Planned: Q3 2025)
- [ ] **GUI Interface**: Optional graphical interface with web browser
- [ ] **Network Tools**: SSH, VNC, and remote access tools
- [ ] **Memory Analysis**: RAM dump and analysis capabilities
- [ ] **Reporting**: Automated report generation
- [ ] **Plugin System**: Extensible architecture for custom tools

#### Version 3.0.0 (Planned: Q4 2025)
- [ ] **Container Support**: Docker/Podman integration
- [ ] **Cloud Integration**: Cloud storage and remote management
- [ ] **Mobile Support**: Android and iOS companion apps
- [ ] **AI Integration**: Machine learning for threat detection
- [ ] **Blockchain**: Secure audit trails with blockchain technology

---

**Project Repository**: https://github.com/ktauchathuranga/privilegeos  
**Issue Tracker**: https://github.com/ktauchathuranga/privilegeos/issues  

---

## 🙏 Acknowledgments

Special thanks to:

- **Linux Kernel Team** for the robust kernel foundation
- **BusyBox Team** for the essential utilities
- **NTFS3 Developers** for native Windows filesystem support
- **Arch Community** dor helping to make it robust

