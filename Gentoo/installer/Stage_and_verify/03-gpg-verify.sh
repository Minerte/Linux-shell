#!/bin/bash

gpg_verify() {
  local ASC_FILENAME="$1"
  local STAGE3_FILENAME="$2"

  echo "Importing Gentoo release key..."
  gpg --import /usr/share/openpgp-keys/gentoo-release.asc || { echo "Failed to import Gentoo release key"; return 1; }
  echo "Key successfully imported"

  echo "Verifying stage3 file..."
  gpg --verify "$ASC_FILENAME" "$STAGE3_FILENAME" || { echo "Failed to verify $STAGE3_FILENAME with $ASC_FILENAME"; return 1; }
  echo "Verification successful!"
  return 0
}
