#!/bin/bash

# SRCheck Addon Installer
# Installs SRCheck to the WoW Classic Era AddOns directory

SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)/SRCheck"
TARGET_DIR="$HOME/wow/World of Warcraft/_classic_era_/Interface/AddOns/SRCheck"

echo "Installing SRCheck addon..."

mkdir -p "$TARGET_DIR"
cp -rv "$SOURCE_DIR/." "$TARGET_DIR/"

echo "SRCheck installed successfully to:"
echo "$TARGET_DIR"
