#!/bin/bash

# Check if swap is enabled and display swap information
echo "Checking for swap partitions..."

# Use swapon to check active swap devices
swap_info=$(swapon --show)

if [ -z "$swap_info" ]; then
    echo "No active swap partition or file found."
else
    echo "Swap partition or file found:"
    echo "$swap_info"
fi

# Optional: Check for swap partitions using blkid
echo "Checking for swap partitions using blkid..."

swap_partitions=$(blkid -t TYPE=swap)

if [ -z "$swap_partitions" ]; then
    echo "No swap partitions detected using blkid."
else
    echo "Swap partitions detected:"
    echo "$swap_partitions"
fi