#!/bin/bash

set -euo pipefail

REPO_URL="https://github.com/sddcinfo/ubuntu-autoinstall-iso.git"
REPO_DIR="ubuntu-autoinstall-iso"

echo "Cloning ubuntu-autoinstall-iso repository..."

if [[ -d "${REPO_DIR}" ]]; then
    echo "Directory ${REPO_DIR} already exists. Removing..."
    rm -rf "${REPO_DIR}"
fi

git clone "${REPO_URL}" "${REPO_DIR}"

echo "Repository cloned successfully to ${REPO_DIR}/"
echo "To get started, run: cd ${REPO_DIR} && ./create_iso.sh"