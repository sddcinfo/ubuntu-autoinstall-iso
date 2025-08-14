#!/bin/bash
set -eo pipefail

# --- Configuration ---
ISO_URL="${ISO_URL:-https://ftp.riken.jp/Linux/ubuntu-releases/noble/ubuntu-24.04.3-live-server-amd64.iso}"
ORIGINAL_ISO="ubuntu-24.04.3-live-server-amd64.iso"
CUSTOM_ISO="ubuntu-24.04.3-custom-autoinstall.iso"
TARGET_DEVICE="${1:-/dev/mmcblk0}"
WORK_DIR="/tmp/iso_work"
MOUNT_DIR="/tmp/iso_mount"

# Track progress
STEP_EXTRACT=false
STEP_MODIFY=false
STEP_BUILD=false
STEP_VALIDATE=false
STEP_WRITE=false

# --- Functions ---
cleanup() {
  umount "${MOUNT_DIR}" 2>/dev/null || true
  umount /tmp/iso_verify 2>/dev/null || true
  rm -rf "${WORK_DIR}" "${MOUNT_DIR}" /tmp/iso_verify 2>/dev/null || true
}
trap cleanup EXIT

fail_with_status() {
  echo
  echo "FAILED: $1"
  echo
  echo "Progress completed:"
  [[ "$STEP_EXTRACT" == "true" ]] && echo "  [OK] ISO extraction" || echo "  [FAIL] ISO extraction"
  [[ "$STEP_MODIFY" == "true" ]] && echo "  [OK] Configuration modification" || echo "  [FAIL] Configuration modification"
  [[ "$STEP_BUILD" == "true" ]] && echo "  [OK] ISO rebuild" || echo "  [FAIL] ISO rebuild"
  [[ "$STEP_VALIDATE" == "true" ]] && echo "  [OK] ISO validation" || echo "  [FAIL] ISO validation"
  [[ "$STEP_WRITE" == "true" ]] && echo "  [OK] Device write" || echo "  [FAIL] Device write"
  exit 1
}

# --- Dependency Checks ---
echo -n "Checking dependencies... "
MISSING_PACKAGES=()

if ! command -v 7z >/dev/null 2>&1; then
  MISSING_PACKAGES+=("p7zip-full")
fi
if ! command -v xorriso >/dev/null 2>&1; then
  MISSING_PACKAGES+=("xorriso")
fi
if ! command -v isoinfo >/dev/null 2>&1; then
  MISSING_PACKAGES+=("genisoimage")
fi
if ! command -v wget >/dev/null 2>&1; then
  MISSING_PACKAGES+=("wget")
fi
if ! command -v efibootmgr >/dev/null 2>&1; then
  MISSING_PACKAGES+=("efibootmgr")
fi

if [[ ${#MISSING_PACKAGES[@]} -gt 0 ]]; then
  echo "installing missing packages"
  echo "Installing required packages: ${MISSING_PACKAGES[*]}"
  if ! apt update >/dev/null 2>&1; then
    fail_with_status "Failed to update package lists"
  fi
  if ! apt install -y "${MISSING_PACKAGES[@]}" >/dev/null 2>&1; then
    fail_with_status "Failed to install required packages: ${MISSING_PACKAGES[*]}"
  fi
  echo "Packages installed successfully"
else
  echo "done"
fi

# --- Safety Checks ---
if [[ "$(id -u)" -ne 0 ]]; then
  fail_with_status "This script must be run as root. Please use sudo."
fi

# Download ISO if not present
if [[ ! -f "${ORIGINAL_ISO}" ]]; then
  echo -n "Downloading Ubuntu ISO... "
  if ! wget -q -O "${ORIGINAL_ISO}" "${ISO_URL}"; then
    fail_with_status "Failed to download ISO from ${ISO_URL}"
  fi
  echo "done"
else
  echo "Using existing ISO: ${ORIGINAL_ISO}"
fi

if [[ ! -f "user-data" ]]; then
  fail_with_status "user-data file not found."
fi

if [[ ! -b "${TARGET_DEVICE}" ]]; then
  fail_with_status "Target device ${TARGET_DEVICE} not found."
fi

echo "Creating custom Ubuntu ISO with autoinstall..."
echo "Target device: ${TARGET_DEVICE}"

# --- Step 1: Extract the original ISO ---
echo -n "Extracting original ISO... "
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}" "${MOUNT_DIR}"

if ! 7z x -o"${WORK_DIR}" "${ORIGINAL_ISO}" >/dev/null 2>&1; then
  fail_with_status "Failed to extract original ISO"
fi
STEP_EXTRACT=true
echo "done"

# --- Step 2: Add autoinstall configuration ---
echo -n "Adding autoinstall configuration... "
cp user-data "${WORK_DIR}/user-data" || fail_with_status "Failed to copy user-data"

cat > "${WORK_DIR}/meta-data" << 'EOF' || fail_with_status "Failed to create meta-data"
instance-id: ubuntu-autoinstall
local-hostname: ubuntu-autoinstall
EOF

# --- Step 3: Modify GRUB configuration for autoinstall ---
GRUB_CFG="${WORK_DIR}/boot/grub/grub.cfg"
if [[ -f "${GRUB_CFG}" ]]; then
  cp "${GRUB_CFG}" "${GRUB_CFG}.backup"
  if ! sed -i 's|linux.*/casper/vmlinuz|& autoinstall ds=nocloud\\;s=/cdrom/|g' "${GRUB_CFG}"; then
    fail_with_status "Failed to modify GRUB configuration"
  fi
fi

EFI_GRUB_CFG="${WORK_DIR}/EFI/ubuntu/grub.cfg"
if [[ -f "${EFI_GRUB_CFG}" ]]; then
  cp "${EFI_GRUB_CFG}" "${EFI_GRUB_CFG}.backup"
  sed -i 's|linux.*/casper/vmlinuz|& autoinstall ds=nocloud\\;s=/cdrom/|g' "${EFI_GRUB_CFG}" 2>/dev/null || true
fi
STEP_MODIFY=true
echo "done"

# --- Step 4: Rebuild the ISO ---
echo -n "Rebuilding ISO... "
VOLUME_ID=$(isoinfo -d -i "${ORIGINAL_ISO}" 2>/dev/null | grep "Volume id:" | cut -d: -f2 | xargs || echo "Ubuntu Custom")

# Create ISO using advanced method
if ! xorriso -as mkisofs \
  -r -V "${VOLUME_ID}" \
  -J -joliet-long -l \
  -iso-level 3 \
  -partition_offset 16 \
  -append_partition 2 28732ac11ff8d211ba4b00a0c93ec93b "${WORK_DIR}/[BOOT]/2-Boot-NoEmul.img" \
  -appended_part_as_gpt \
  -c /boot.catalog \
  -b /boot/grub/i386-pc/eltorito.img \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  -eltorito-alt-boot \
  -e '--interval:appended_partition_2:all::' \
  -no-emul-boot \
  -o "${CUSTOM_ISO}" \
  "${WORK_DIR}/" >/dev/null 2>&1; then
  
  # Fallback to simpler method
  if ! xorriso -as mkisofs \
    -r -V "${VOLUME_ID}" \
    -J -l \
    -c boot.catalog \
    -b boot/grub/i386-pc/eltorito.img \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    -o "${CUSTOM_ISO}" \
    "${WORK_DIR}/" >/dev/null 2>&1; then
    fail_with_status "Failed to create custom ISO with both methods"
  fi
fi
STEP_BUILD=true
echo "done"

# --- Step 5: Quick validation ---
echo -n "Validating ISO... "
if [[ ! -f "${CUSTOM_ISO}" ]] || [[ ! -s "${CUSTOM_ISO}" ]]; then
  fail_with_status "Custom ISO file missing or empty"
fi

# Check if ISO is readable
if ! isoinfo -l -i "${CUSTOM_ISO}" >/dev/null 2>&1; then
  fail_with_status "Custom ISO filesystem appears corrupted"
fi

# Check for basic boot structures
if ! isoinfo -f -i "${CUSTOM_ISO}" | grep -q "boot.catalog\|BOOT.CATALOG" 2>/dev/null; then
  echo "warning: boot catalog not found"
fi
STEP_VALIDATE=true
echo "done"

# --- Step 6: Prepare and write to target device ---
echo -n "Preparing target device... "
# Unmount any existing partitions
umount "${TARGET_DEVICE}"* 2>/dev/null || true

# Clean the device
dd if=/dev/zero of="${TARGET_DEVICE}" bs=1M count=100 >/dev/null 2>&1 || true
sgdisk --zap-all "${TARGET_DEVICE}" >/dev/null 2>&1 || true
wipefs -a "${TARGET_DEVICE}" >/dev/null 2>&1 || true
sync

partprobe "${TARGET_DEVICE}" 2>/dev/null || true
sleep 1
echo "done"

# Write the ISO
echo -n "Writing ISO to ${TARGET_DEVICE}... "
if ! dd if="${CUSTOM_ISO}" of="${TARGET_DEVICE}" bs=4M oflag=sync >/dev/null 2>&1; then
  fail_with_status "Failed to write ISO to device"
fi
sync

# Quick device validation
if ! xxd -l 512 "${TARGET_DEVICE}" | grep -q "55aa" 2>/dev/null; then
  fail_with_status "No boot signature found on device after write"
fi
STEP_WRITE=true
echo "done"

# --- Step 7: Set EFI boot order ---
echo -n "Configuring EFI boot order... "

# Check if we're on an EFI system
if [[ ! -d /sys/firmware/efi ]]; then
  echo "skipped (not an EFI system)"
else
  # Force firmware to rescan for new boot devices
  echo -n "refreshing EFI boot entries... "
  partprobe "${TARGET_DEVICE}" >/dev/null 2>&1 || true
  sleep 1
  
  # Force udev to process the new partition table with timeout
  timeout 10 udevadm settle >/dev/null 2>&1 || true
  timeout 5 udevadm trigger --subsystem-match=block >/dev/null 2>&1 || true
  timeout 10 udevadm settle >/dev/null 2>&1 || true
  sleep 1
  
  # Get current boot entries after refresh
  BOOT_ENTRIES=$(efibootmgr 2>/dev/null)
  
  if [[ $? -ne 0 ]]; then
    echo "warning (efibootmgr failed)"
  else
    # Look for the device we just wrote to
    DEVICE_NAME=$(basename "${TARGET_DEVICE}")
    
    # Find boot entry that matches our device
    BOOT_ENTRY=""
    
    # Common patterns for eMMC/MMC devices in EFI
    if [[ "${TARGET_DEVICE}" =~ mmcblk ]]; then
      # Look for MMC or eMMC entries (case insensitive)
      BOOT_ENTRY=$(echo "${BOOT_ENTRIES}" | grep -i -E "(mmc|emmc)" | head -1 | grep -o "Boot[0-9A-F]\{4\}")
      
      # If not found, try searching by device path
      if [[ -z "${BOOT_ENTRY}" ]]; then
        BOOT_ENTRY=$(echo "${BOOT_ENTRIES}" | grep -i "${DEVICE_NAME}" | head -1 | grep -o "Boot[0-9A-F]\{4\}")
      fi
    else
      # For other devices, try to match by device name first
      BOOT_ENTRY=$(echo "${BOOT_ENTRIES}" | grep -i "${DEVICE_NAME}" | head -1 | grep -o "Boot[0-9A-F]\{4\}")
      
      # Then try removable media patterns
      if [[ -z "${BOOT_ENTRY}" ]]; then
        BOOT_ENTRY=$(echo "${BOOT_ENTRIES}" | grep -i -E "(removable|usb)" | head -1 | grep -o "Boot[0-9A-F]\{4\}")
      fi
    fi
    
    # If no existing boot entry found, create one for the newly written ISO
    if [[ -z "${BOOT_ENTRY}" ]]; then
      echo -n "creating new boot entry for ${TARGET_DEVICE}... "
      
      # Create a new boot entry for the ISO we just wrote
      # Find the EFI partition (usually partition 2 on Ubuntu ISOs)
      EFI_PARTITION="${TARGET_DEVICE}p2"
      if [[ ! -b "${EFI_PARTITION}" ]]; then
        EFI_PARTITION="${TARGET_DEVICE}2"
      fi
      
      if [[ -b "${EFI_PARTITION}" ]]; then
        # Create boot entry pointing to the Ubuntu EFI bootloader
        NEW_BOOT_OUTPUT=$(efibootmgr -c -d "${TARGET_DEVICE}" -p 2 -L "Ubuntu Live USB" -l "\\EFI\\BOOT\\BOOTX64.EFI" 2>/dev/null)
        
        if [[ $? -eq 0 ]]; then
          # Extract the boot number from the output (e.g., "Boot0005* Ubuntu Live USB")
          BOOT_ENTRY=$(echo "${NEW_BOOT_OUTPUT}" | grep -o "Boot[0-9A-F]\{4\}")
          if [[ -n "${BOOT_ENTRY}" ]]; then
            echo "created ${BOOT_ENTRY}"
          else
            echo "created but could not extract boot number"
          fi
        else
          echo "failed to create boot entry"
        fi
      else
        echo "failed (EFI partition not found)"
      fi
    fi
    
    if [[ -n "${BOOT_ENTRY}" ]]; then
      # Extract just the boot number (e.g., "0001" from "Boot0001")
      BOOT_NUM=$(echo "${BOOT_ENTRY}" | sed 's/Boot//')
      
      # Set this as the next boot device
      if efibootmgr -n "${BOOT_NUM}" >/dev/null 2>&1; then
        # Validate that the next boot is actually set correctly - try multiple times
        VALIDATION_SUCCESS=false
        for attempt in 1 2 3; do
          sleep 2
          VERIFY_OUTPUT=$(efibootmgr 2>/dev/null)
          
          if [[ $? -eq 0 ]]; then
            # Try multiple patterns for BootNext to handle different formats
            NEXT_BOOT=""
            
            # Pattern 1: BootNext: 0001
            if [[ -z "${NEXT_BOOT}" ]]; then
              NEXT_BOOT=$(echo "${VERIFY_OUTPUT}" | grep -i "BootNext" | sed -n 's/.*BootNext:\s*\([0-9A-Fa-f]\{4\}\).*/\1/p' | tr '[:lower:]' '[:upper:]')
            fi
            
            # Pattern 2: BootNext 0001
            if [[ -z "${NEXT_BOOT}" ]]; then
              NEXT_BOOT=$(echo "${VERIFY_OUTPUT}" | grep -i "BootNext" | sed -n 's/.*BootNext\s\+\([0-9A-Fa-f]\{4\}\).*/\1/p' | tr '[:lower:]' '[:upper:]')
            fi
            
            # Pattern 3: Extract any 4-digit hex after BootNext
            if [[ -z "${NEXT_BOOT}" ]]; then
              NEXT_BOOT=$(echo "${VERIFY_OUTPUT}" | grep -i "BootNext" | grep -o '[0-9A-Fa-f]\{4\}' | head -1 | tr '[:lower:]' '[:upper:]')
            fi
            
            # Normalize boot number for comparison (pad with zeros if needed)
            BOOT_NUM_PADDED=$(printf "%04s" "${BOOT_NUM}" | tr ' ' '0' | tr '[:lower:]' '[:upper:]')
            
            if [[ -n "${NEXT_BOOT}" && "${NEXT_BOOT}" == "${BOOT_NUM_PADDED}" ]]; then
              echo "done (set ${BOOT_ENTRY} for next boot)"
              echo "  Boot entry: $(echo "${BOOT_ENTRIES}" | grep "${BOOT_ENTRY}" | head -1)"
              echo "  [OK] Verified: Next boot is set to ${BOOT_ENTRY} (${NEXT_BOOT})"
              VALIDATION_SUCCESS=true
              break
            elif [[ -n "${NEXT_BOOT}" ]]; then
              echo "  Attempt ${attempt}: Expected ${BOOT_NUM_PADDED}, got ${NEXT_BOOT}"
            else
              echo "  Attempt ${attempt}: No BootNext found in output"
            fi
          else
            echo "  Attempt ${attempt}: efibootmgr failed"
          fi
        done
        
        if [[ "${VALIDATION_SUCCESS}" != "true" ]]; then
          echo "warning (boot order may be set but verification failed after 3 attempts)"
          echo "  Boot entry: $(echo "${BOOT_ENTRIES}" | grep "${BOOT_ENTRY}" | head -1)"
          echo "  Debug: efibootmgr output:"
          echo "${VERIFY_OUTPUT}" | grep -i "boot" | head -3 | sed 's/^/    /'
        fi
      else
        echo "warning (failed to set boot order for ${BOOT_ENTRY})"
      fi
    else
      # If we still can't find a specific entry, try any removable/external device
      BOOT_ENTRY=$(echo "${BOOT_ENTRIES}" | grep -i -E "(removable|external|usb|mmc)" | head -1 | grep -o "Boot[0-9A-F]\{4\}")
      
      if [[ -n "${BOOT_ENTRY}" ]]; then
        BOOT_NUM=$(echo "${BOOT_ENTRY}" | sed 's/Boot//')
        if efibootmgr -n "${BOOT_NUM}" >/dev/null 2>&1; then
          # Validate that the next boot is actually set correctly - try multiple times
          VALIDATION_SUCCESS=false
          for attempt in 1 2 3; do
            sleep 2
            VERIFY_OUTPUT=$(efibootmgr 2>/dev/null)
            
            if [[ $? -eq 0 ]]; then
              # Try multiple patterns for BootNext to handle different formats
              NEXT_BOOT=""
              
              # Pattern 1: BootNext: 0001
              if [[ -z "${NEXT_BOOT}" ]]; then
                NEXT_BOOT=$(echo "${VERIFY_OUTPUT}" | grep -i "BootNext" | sed -n 's/.*BootNext:\s*\([0-9A-Fa-f]\{4\}\).*/\1/p' | tr '[:lower:]' '[:upper:]')
              fi
              
              # Pattern 2: BootNext 0001
              if [[ -z "${NEXT_BOOT}" ]]; then
                NEXT_BOOT=$(echo "${VERIFY_OUTPUT}" | grep -i "BootNext" | sed -n 's/.*BootNext\s\+\([0-9A-Fa-f]\{4\}\).*/\1/p' | tr '[:lower:]' '[:upper:]')
              fi
              
              # Pattern 3: Extract any 4-digit hex after BootNext
              if [[ -z "${NEXT_BOOT}" ]]; then
                NEXT_BOOT=$(echo "${VERIFY_OUTPUT}" | grep -i "BootNext" | grep -o '[0-9A-Fa-f]\{4\}' | head -1 | tr '[:lower:]' '[:upper:]')
              fi
              
              # Normalize boot number for comparison (pad with zeros if needed)
              BOOT_NUM_PADDED=$(printf "%04s" "${BOOT_NUM}" | tr ' ' '0' | tr '[:lower:]' '[:upper:]')
              
              if [[ -n "${NEXT_BOOT}" && "${NEXT_BOOT}" == "${BOOT_NUM_PADDED}" ]]; then
                echo "done (set ${BOOT_ENTRY} for next boot)"
                echo "  Boot entry: $(echo "${BOOT_ENTRIES}" | grep "${BOOT_ENTRY}" | head -1)"
                echo "  [OK] Verified: Next boot is set to ${BOOT_ENTRY} (${NEXT_BOOT})"
                VALIDATION_SUCCESS=true
                break
              elif [[ -n "${NEXT_BOOT}" ]]; then
                echo "  Attempt ${attempt}: Expected ${BOOT_NUM_PADDED}, got ${NEXT_BOOT}"
              else
                echo "  Attempt ${attempt}: No BootNext found in output"
              fi
            else
              echo "  Attempt ${attempt}: efibootmgr failed"
            fi
          done
          
          if [[ "${VALIDATION_SUCCESS}" != "true" ]]; then
            echo "warning (boot order may be set but verification failed after 3 attempts)"
            echo "  Boot entry: $(echo "${BOOT_ENTRIES}" | grep "${BOOT_ENTRY}" | head -1)"
            echo "  Debug: efibootmgr output:"
            echo "${VERIFY_OUTPUT}" | grep -i "boot" | head -3 | sed 's/^/    /'
          fi
        else
          echo "warning (failed to set boot order for ${BOOT_ENTRY})"
        fi
      else
        echo "warning (could not identify boot entry for device ${TARGET_DEVICE})"
        echo "  Available boot entries:"
        echo "${BOOT_ENTRIES}" | grep "Boot[0-9]" | head -5 | sed 's/^/    /'
      fi
    fi
  fi
fi

# --- Success ---
echo
echo "==============================================="
echo "SUCCESS: Custom Ubuntu ISO written to ${TARGET_DEVICE}"
echo "==============================================="
echo "All steps completed successfully:"
echo "  [OK] ISO extraction"
echo "  [OK] Configuration modification"  
echo "  [OK] ISO rebuild"
echo "  [OK] ISO validation"
echo "  [OK] Device write"
echo
echo "The device should now boot Ubuntu with autoinstall."
echo "Custom ISO also saved as: ${CUSTOM_ISO}"
echo "==============================================="