#!/bin/bash

# SRCheck Packager
# Builds dist/SRCheck-<version>.zip: an "SRCheck" folder ready to unzip into
# World of Warcraft/_classic_era_/Interface/AddOns/

set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
VERSION="$(sed -n 's/^## Version: *//p' "$ROOT/SRCheck/SRCheck.toc" | tr -d '\r')"
ZIP="$ROOT/dist/SRCheck-$VERSION.zip"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo "Packaging SRCheck $VERSION..."

cp -r "$ROOT/SRCheck" "$STAGE/SRCheck"
cp "$ROOT/README.md" "$STAGE/SRCheck/README.md"

mkdir -p "$ROOT/dist"
rm -f "$ZIP"
(cd "$STAGE" && zip -rq -X "$ZIP" SRCheck)

echo "Created: $ZIP"
unzip -l "$ZIP"
