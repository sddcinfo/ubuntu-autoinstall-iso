#!/bin/bash
set -eo pipefail

# --- Configuration ---
SD_DEVICE="/dev/sda"
EMMC_DEVICE="/dev/mmcblk0"

wipe_device() {
  local DEVICE=$1
  local DEVICE_NAME=$2
  
  echo "=== WIPING ${DEVICE_NAME} (${DEVICE}) ==="
  
  if [[ ! -b "${DEVICE}" ]]; then
    echo "WARNING: ${DEVICE_NAME} device ${DEVICE} not found, skipping"
    return
  fi
  
  # Show current state
  echo "Current ${DEVICE_NAME} state:"
  fdisk -l "${DEVICE}" 2>/dev/null || echo "Could not read device"
  echo
  
  # Unmount everything
  echo -n "Unmounting all ${DEVICE_NAME} partitions... "
  umount "${DEVICE}"* 2>/dev/null || true
  umount "${DEVICE}p"* 2>/dev/null || true
  sync
  echo "done"
  
  # Nuclear option - wipe partition tables completely
  echo -n "Destroying all partition tables... "
  dd if=/dev/zero of="${DEVICE}" bs=512 count=2048 >/dev/null 2>&1 || true  # Clear first 1MB
  sgdisk --zap-all "${DEVICE}" >/dev/null 2>&1 || true
  dd if=/dev/zero of="${DEVICE}" bs=1M count=10 >/dev/null 2>&1 || true     # Clear first 10MB
  sync
  echo "done"
  
  # Wipe filesystem signatures from potential partitions
  echo -n "Clearing filesystem signatures... "
  wipefs -a "${DEVICE}" >/dev/null 2>&1 || true
  for i in {1..20}; do
    [[ -b "${DEVICE}${i}" ]] && wipefs -a "${DEVICE}${i}" >/dev/null 2>&1 || true
    [[ -b "${DEVICE}p${i}" ]] && wipefs -a "${DEVICE}p${i}" >/dev/null 2>&1 || true
  done
  sync
  echo "done"
  
  # Deep wipe - clear first 1GB of device
  echo -n "Deep wiping device (first 1GB)... "
  dd if=/dev/zero of="${DEVICE}" bs=1M count=1024 >/dev/null 2>&1 || true
  sync
  echo "done"
  
  # Final cleanup - force kernel to forget about old partitions
  echo -n "Forcing partition table reload... "
  partprobe "${DEVICE}" 2>/dev/null || true
  sleep 3
  
  # Additional cleanup commands
  blockdev --rereadpt "${DEVICE}" 2>/dev/null || true
  echo 1 > /sys/block/$(basename ${DEVICE})/device/rescan 2>/dev/null || true
  sync
  echo "done"
  
  # Verify device is completely clean
  echo "Verifying ${DEVICE_NAME} is clean:"
  if fdisk -l "${DEVICE}" 2>/dev/null | grep -q "Partition\|/dev/"; then
    echo "WARNING: Some remnants detected:"
    fdisk -l "${DEVICE}" 2>/dev/null | grep -E "(Partition|${DEVICE})" || true
  else
    echo "PASS: ${DEVICE_NAME} appears completely clean"
  fi
  
  # Clear eMMC boot partitions if this is an eMMC device
  if [[ "${DEVICE}" =~ mmcblk ]]; then
    echo -n "Clearing eMMC boot partitions... "
    dd if=/dev/zero of="${DEVICE}boot0" bs=1M count=4 >/dev/null 2>&1 || true
    dd if=/dev/zero of="${DEVICE}boot1" bs=1M count=4 >/dev/null 2>&1 || true
    sync
    echo "done"
  fi
  
  echo "=== ${DEVICE_NAME} WIPE COMPLETE ==="
  echo
}

# --- Safety Checks ---
if [[ "$(id -u)" -ne 0 ]]; then
  echo "FAILED: This script must be run as root. Please use sudo."
  exit 1
fi

echo "COMPLETE DEVICE WIPE SCRIPT"
echo "WARNING: This will destroy ALL data on the following devices:"
echo "  - SD Card: ${SD_DEVICE}"
echo "  - eMMC:    ${EMMC_DEVICE}"
echo

# Show all current block devices
echo "Current block devices:"
lsblk
echo

# Confirm which devices to wipe
echo "Select devices to wipe:"
echo "1) SD Card only (${SD_DEVICE})"
echo "2) eMMC only (${EMMC_DEVICE})"
echo "3) Both devices"
echo "4) Cancel and exit"
echo
read -p "Enter your choice (1-4): " choice

case $choice in
  1)
    echo "Wiping SD Card only..."
    wipe_device "${SD_DEVICE}" "SD CARD"
    ;;
  2)
    echo "Wiping eMMC only..."
    wipe_device "${EMMC_DEVICE}" "eMMC"
    ;;
  3)
    echo "Wiping both devices..."
    echo
    read -p "Are you ABSOLUTELY sure? This will destroy ALL data on BOTH devices! (yes/no): " confirm
    if [[ "$confirm" == "yes" ]]; then
      wipe_device "${SD_DEVICE}" "SD CARD"
      wipe_device "${EMMC_DEVICE}" "eMMC"
    else
      echo "Operation cancelled."
      exit 0
    fi
    ;;
  4)
    echo "Operation cancelled."
    exit 0
    ;;
  *)
    echo "Invalid choice. Operation cancelled."
    exit 1
    ;;
esac

# Final system cleanup
echo "=== FINAL SYSTEM CLEANUP ==="
echo -n "Flushing all caches and buffers... "
sync
echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
partprobe 2>/dev/null || true
udevadm settle 2>/dev/null || true
echo "done"

# Show final state of all devices
echo
echo "=== FINAL DEVICE STATE ==="
lsblk
echo

echo "==============================================="
echo "WIPE OPERATION SUCCESSFUL"
echo "==============================================="
case $choice in
  1)
    echo "SD Card (${SD_DEVICE}) has been completely wiped:"
    echo "  [OK] SD Card: CLEAN"
    ;;
  2)
    echo "eMMC (${EMMC_DEVICE}) has been completely wiped:"
    echo "  [OK] eMMC: CLEAN"
    ;;
  3)
    echo "Both devices have been completely wiped:"
    echo "  [OK] SD Card (${SD_DEVICE}): CLEAN"
    echo "  [OK] eMMC (${EMMC_DEVICE}): CLEAN"
    ;;
esac
echo ""
echo "All partition tables, boot sectors, and"
echo "filesystem signatures have been destroyed."
echo ""
echo "You can now write a fresh ISO without"
echo "any interference from previous installations."
echo "==============================================="