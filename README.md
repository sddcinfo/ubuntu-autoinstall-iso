# Ubuntu Autoinstall ISO Creator

A comprehensive script that creates custom Ubuntu 24.04 autoinstall ISOs with embedded cloud-init configuration, automatically installs them to target devices, and configures EFI boot order for hands-free deployment.

## Overview

This project solves the problem of creating bootable Ubuntu autoinstall media that can perform completely unattended installations. The script handles the entire pipeline from ISO creation to boot configuration.

## Key Features

- 🔄 **Automatic dependency installation** - Installs required packages automatically
- 📥 **Automatic ISO download** - Downloads Ubuntu ISO from configurable mirror
- ⚙️ **Custom autoinstall configuration** - Embeds your `user-data` for unattended installation
- 🔧 **Device preparation** - Completely cleans target devices before writing
- 💿 **Hybrid ISO creation** - Creates bootable ISOs with preserved boot signatures
- 🖥️ **EFI boot management** - Automatically configures next boot to use the new installation media
- ✅ **Comprehensive validation** - Validates each step with clear success/failure reporting

## How It Works

### Architecture Overview

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│   Original      │    │   Work           │    │   Custom        │
│   Ubuntu ISO    │───▶│   Directory      │───▶│   Autoinstall   │
│                 │    │   + user-data    │    │   ISO           │
└─────────────────┘    │   + meta-data    │    └─────────────────┘
                       │   + GRUB mods    │              │
                       └──────────────────┘              │
                                                         ▼
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│   EFI Boot      │    │   Device         │    │   Target        │
│   Configuration │◀───│   Validation     │◀───│   Device        │
│                 │    │                  │    │   (eMMC/USB)    │
└─────────────────┘    └──────────────────┘    └─────────────────┘
```

### Process Flow

1. **Dependency Check & Installation**
   - Checks for required tools: `7z`, `xorriso`, `isoinfo`, `wget`, `efibootmgr`
   - Automatically installs missing packages via `apt`

2. **ISO Acquisition**
   - Downloads Ubuntu 24.04 ISO if not present locally
   - Uses configurable mirror (default: RIKEN Japan mirror)
   - Validates download integrity

3. **ISO Modification**
   - Extracts original Ubuntu ISO using `7z`
   - Embeds `user-data` and `meta-data` files for cloud-init
   - Modifies GRUB configuration to enable autoinstall mode
   - Adds kernel parameters: `autoinstall ds=nocloud;s=/cdrom/`

4. **ISO Reconstruction**
   - Rebuilds ISO with `xorriso` preserving boot structures
   - Maintains hybrid boot capability (UEFI + Legacy BIOS)
   - Preserves GPT partition table for proper device recognition

5. **Device Preparation**
   - Unmounts all existing partitions
   - Zeroes partition tables and boot sectors
   - Clears eMMC boot partitions (`/dev/mmcblk0boot0`, `/dev/mmcblk0boot1`)
   - Wipes filesystem signatures

6. **ISO Writing**
   - Writes custom ISO to target device using `dd`
   - Validates boot signature presence
   - Verifies partition table integrity

7. **EFI Boot Configuration**
   - Detects EFI vs Legacy BIOS systems
   - Queries `efibootmgr` for available boot entries
   - Identifies boot entry for target device
   - Sets device as next boot target (`efibootmgr -n`)

## Prerequisites

- **Ubuntu/Debian-based system** (for package management)
- **Root privileges** (script must run as sudo)
- **EFI firmware** (recommended for boot order management)
- **Internet connection** (for downloading ISO and packages)

## Installation

1. Clone the repository:
   ```bash
   git clone https://github.com/sddcinfo/ubuntu-autoinstall-iso.git
   cd ubuntu-autoinstall-iso
   ```

2. Create your `user-data` configuration file (see Configuration section)

3. Run the script:
   ```bash
   sudo ./create_custom_iso_quiet.sh /dev/your-target-device
   ```

## Configuration

### user-data File

Create a `user-data` file in the same directory as the script. This file contains your autoinstall configuration.

**Example user-data:**
```yaml
#cloud-config

autoinstall:
  version: 1
  locale: en_US.UTF-8
  keyboard:
    layout: us
    variant: ""
  
  identity:
    hostname: myserver
    realname: "Administrator"
    username: admin
    password: "$6$rounds=4096$saltgoeshere$hashedpassword"
  
  ssh:
    install-server: true
  
  storage:
    layout:
      name: lvm
      match:
        path: /dev/nvme0n1
  
  packages:
    - openssh-server
    - curl
    - git
  
  shutdown: reboot

user-data:
  users:
    - name: admin
      sudo: ALL=(ALL) NOPASSWD:ALL
```

### Environment Variables

- **ISO_URL**: Custom Ubuntu ISO download URL
  ```bash
  sudo ISO_URL="https://mirror.example.com/ubuntu.iso" ./create_custom_iso_quiet.sh /dev/sdb
  ```

### Storage Configuration Options

The script supports multiple storage layout options:

**Simple automatic layout:**
```yaml
storage:
  layout:
    name: lvm
    match:
      path: /dev/nvme0n1
```

**Direct layout (no LVM):**
```yaml
storage:
  layout:
    name: direct
    match:
      path: /dev/nvme0n1
```

## Usage Examples

### Basic Usage
```bash
# Create autoinstall ISO and write to eMMC
sudo ./create_custom_iso_quiet.sh /dev/mmcblk0
```

### Custom ISO Source
```bash
# Use different Ubuntu mirror
sudo ISO_URL="https://releases.ubuntu.com/24.04/ubuntu-24.04.3-live-server-amd64.iso" \
  ./create_custom_iso_quiet.sh /dev/sdb
```

### USB Device Target
```bash
# Write to USB device
sudo ./create_custom_iso_quiet.sh /dev/sdb
```

## Troubleshooting

### Common Issues

**1. Boot signature not found**
```
FAILED: No boot signature found on device
```
- Solution: Ensure target device is not mounted during write operation
- Run device wipe script first: `sudo ./complete_device_wipe.sh`

**2. EFI boot configuration failed**
```
warning (could not identify boot entry for device)
```
- Check available boot entries: `efibootmgr -v`
- Manually set boot order if needed: `efibootmgr -n 0003`

**3. Cloud-init not working**
```
dsmode: local (instead of nocloud)
```
- Verify GRUB modification: `cat /proc/cmdline | grep ds=nocloud`
- Check cloud-init logs: `tail -f /var/log/cloud-init.log`

**4. Storage configuration errors**
```
missing 1 required keyword-only argument: 'volume'
```
- Use simplified storage layout (see Configuration section)
- Validate YAML syntax: `python3 -c "import yaml; yaml.safe_load(open('user-data'))"`

### Debug Commands

**Check cloud-init status:**
```bash
cloud-init status --long
systemctl status cloud-init
```

**Verify autoinstall configuration:**
```bash
cloud-init schema --config-file /cdrom/user-data
```

**Check device boot entries:**
```bash
efibootmgr -v
```

## Hardware Compatibility

### Tested Platforms
- ✅ **eMMC storage devices** (`/dev/mmcblk0`)
- ✅ **NVMe SSDs** (`/dev/nvme0n1`) 
- ✅ **SATA SSDs/HDDs** (`/dev/sda`)
- ✅ **USB storage devices**

### Known Issues
- **eMMC boot partition interference**: Script automatically clears `/dev/mmcblk0boot0` and `/dev/mmcblk0boot1`
- **Legacy BIOS systems**: EFI boot management will be skipped (manual boot order required)

## Security Considerations

- **Password hashes**: Use strong password hashes in user-data
- **SSH keys**: Prefer SSH key authentication over passwords
- **Network security**: Ensure autoinstall happens on trusted networks
- **Root access**: Script requires root privileges for device access

## Contributing

1. Fork the repository
2. Create a feature branch: `git checkout -b feature-name`
3. Make changes and test thoroughly
4. Submit a pull request with detailed description

## License

This project is licensed under the MIT License. See LICENSE file for details.

## Changelog

### v1.0.0 (Current)
- Initial release with full autoinstall ISO creation
- EFI boot order management
- Automatic dependency installation
- Comprehensive device cleaning
- Progress tracking and validation

## Support

For issues, questions, or contributions:
- Create an issue on GitHub
- Check troubleshooting section above
- Review Ubuntu autoinstall documentation: https://ubuntu.com/server/docs/install/autoinstall