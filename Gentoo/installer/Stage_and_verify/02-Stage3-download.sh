#!/bin/bash

URL1="https://distfiles.gentoo.org/releases/amd64/autobuilds/current-stage3-amd64-hardened-openrc/"
URL1_FALLBACK="https://gentoo.osuosl.org/releases/amd64/autobuilds/current-stage3-amd64-hardened-openrc/"
URL2="https://distfiles.gentoo.org/releases/amd64/autobuilds/current-stage3-amd64-hardened-selinux-openrc/"
URL2_FALLBACK="https://gentoo.osuosl.org/releases/amd64/autobuilds/current-stage3-amd64-hardened-selinux-openrc/"

download_stage3() {
  local type_choice="$1"
  local BOUNCER_URL
  local FALLBACK_URL
  local FILE_PATTERN

  case "$type_choice" in
    1)
      BOUNCER_URL="$URL1"
      FALLBACK_URL="$URL1_FALLBACK"
      FILE_PATTERN='stage3-amd64-hardened-openrc-\d{8}T\d{6}Z\.tar\.xz'
      ;;
    2)
      BOUNCER_URL="$URL2"
      FALLBACK_URL="$URL2_FALLBACK"
      FILE_PATTERN='stage3-amd64-hardened-selinux-openrc-\d{8}T\d{6}Z\.tar\.xz'
      ;;
    *)
      echo "Invalid choice. Exiting..."
      return 1
      ;;
  esac

  echo "Fetching the latest stage3 file from $BOUNCER_URL..."
  FILE_LIST=$(curl -s "$BOUNCER_URL")
  if [[ -z "$FILE_LIST" ]]; then
    echo "Primary URL failed. Trying fallback URL $FALLBACK_URL..."
    FILE_LIST=$(curl -s "$FALLBACK_URL")
    if [[ -z "$FILE_LIST" ]]; then
      echo "Failed to retrieve the list of files from both primary and fallback URLs."
      return 1
    fi
    BOUNCER_URL="$FALLBACK_URL"
  fi

  STAGE3_FILENAME=$(echo "$FILE_LIST" | grep -oP "$FILE_PATTERN" | tail -n 1)
  ASC_FILENAME="${STAGE3_FILENAME}.asc"

  if [[ -z "$STAGE3_FILENAME" || -z "$ASC_FILENAME" ]]; then
    echo "Failed to find the latest stage3 file or its .asc file."
    return 1
  fi

  STAGE3_URL="$BOUNCER_URL/$STAGE3_FILENAME"
  ASC_URL="$BOUNCER_URL/$ASC_FILENAME"

  echo "Downloading stage3 file: $STAGE3_FILENAME"
  curl -O "$STAGE3_URL" || { echo "Failed to download stage3 file"; return 1; }

  echo "Downloading verification file: $ASC_FILENAME"
  curl -O "$ASC_URL" || { echo "Failed to download .asc file"; return 1; }

  if [[ ! -s "$STAGE3_FILENAME" || ! -s "$ASC_FILENAME" ]]; then
    echo "Downloaded files are empty."
    return 1
  fi

  echo "Download complete: $STAGE3_FILENAME and $ASC_FILENAME"
  return 0
}