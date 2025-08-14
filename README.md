# Ubuntu Autoinstall ISO Creator

A script that creates custom Ubuntu 24.04 autoinstall ISOs with embedded cloud-init configuration, automatically installs them to target devices, and configures EFI boot order for hands-free deployment.

## Features

- 🔄 **Automatic dependency installation** - Installs required packages automatically
- 📥 **Automatic ISO download** - Downloads Ubuntu ISO from configurable mirror
- ⚙️ **Custom autoinstall configuration** - Embeds your `user-data` for unattended installation
- 🔧 **Device preparation** - Completely cleans target devices before writing
- 💿 **Hybrid ISO creation** - Creates bootable ISOs with preserved boot signatures
- 🖥️ **EFI boot management** - Automatically configures next boot to use the new installation media

## How It Works

The script performs these steps automatically:

1. **Downloads Ubuntu ISO** (if not present) from configurable mirror
2. **Extracts and modifies ISO** - Embeds `user-data` and modifies GRUB for autoinstall
3. **Rebuilds bootable ISO** - Preserves all boot signatures and compatibility
4. **Prepares target device** - Wipes partitions, boot sectors, and eMMC boot partitions
5. **Writes custom ISO** to target device
6. **Configures EFI boot order** to automatically boot from the device

## Quick Start

1. **Create your `user-data` configuration** (see Configuration section below)

2. **Run the script:**
   ```bash
   sudo ./create_iso.sh /dev/your-target-device
   ```

3. **Reboot** - System will automatically boot from the new device and install Ubuntu

## Configuration

### user-data File

Create a `user-data` file with your autoinstall configuration. The included example uses:
- **Username:** `admin` 
- **Password:** `password` (change this!)
- **Storage:** LVM layout on `/dev/nvme0n1`

**To change the password**, generate a new hash:
```bash
# Generate password hash
python3 -c "import crypt; print(crypt.crypt('your-new-password', crypt.mksalt(crypt.METHOD_SHA512)))"

# Replace the password line in user-data:
password: "$6$your-generated-hash-here"
```

### Storage Configuration

**Automatic LVM layout (recommended):**
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

### Custom ISO Source

Use a different Ubuntu mirror:
```bash
sudo ISO_URL="https://releases.ubuntu.com/24.04/ubuntu-24.04.3-live-server-amd64.iso" \
  ./create_iso.sh /dev/mmcblk0
```

## Usage Examples

```bash
# Create autoinstall ISO and write to eMMC
sudo ./create_iso.sh /dev/mmcblk0

# Write to SD card
sudo ./create_iso.sh /dev/sda

# Write to USB device  
sudo ./create_iso.sh /dev/sdb
```

## Hardware Compatibility

**Supported storage devices:**
- ✅ **eMMC storage** (`/dev/mmcblk0`)
- ✅ **NVMe SSDs** (`/dev/nvme0n1`) 
- ✅ **SD cards** (`/dev/sda`)
- ✅ **USB storage** (`/dev/sdb`, `/dev/sdc`, etc.)

**System requirements:**
- Ubuntu/Debian-based system (for package management)
- Root privileges (script must run as sudo)
- Internet connection (for downloading ISO and packages)

## Device Wipe Utility

For thorough device cleaning before use:
```bash
sudo ./complete_device_wipe.sh
```

This script completely wipes both SD card and eMMC devices, including eMMC boot partitions.

## Files Included

- **`create_iso.sh`** - Main script for creating and deploying autoinstall ISOs
- **`user-data`** - Example autoinstall configuration 
- **`complete_device_wipe.sh`** - Utility for complete device cleaning

## Security Notes

- **Change the default password** in `user-data` before use
- **Use SSH keys** instead of passwords when possible
- **Run installations on trusted networks only**
- The script requires root privileges for device access

## License

MIT License - see LICENSE file for details.