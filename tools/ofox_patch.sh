#!/bin/bash

: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is not set}"
: "${device:?device is not set}"
magiskboot="$GITHUB_WORKSPACE/tools/magiskboot"

OFOX_JSON_URL="https://raw.githubusercontent.com/PipaDB/Releases/refs/heads/main/ofox.json"
OFOX_ZIP="$GITHUB_WORKSPACE/tools/ofox.zip"
OFOX_OUTPUT_DIR="$GITHUB_WORKSPACE/output_patched"
OFOX_INPUT_BOOT="$GITHUB_WORKSPACE/${device}/firmware-update/boot.img"
OFOX_OUTPUT_BOOT="$OFOX_OUTPUT_DIR/ofox-boot-pipa.img"

Red='\033[1;31m'
Green='\033[1;32m'
Blue='\033[1;34m'
Yellow='\033[1;33m'
NC='\033[0m'

echo -e "${Red}- Patching OrangeFox Recovery (External Script)${NC}"

mkdir -p "$OFOX_OUTPUT_DIR" "$GITHUB_WORKSPACE/tools"

if [[ ! -f "$OFOX_ZIP" ]]; then
    echo -e "${Blue}:: Fetching OrangeFox metadata...${NC}"
    JSON_DATA=$(curl -sL "$OFOX_JSON_URL")
    OFOX_URL=$(echo "$JSON_DATA" | grep -oP '(?<="url": ")[^"]*')
    
    if [[ -z "$OFOX_URL" ]]; then
        echo -e "${Red}!! ERROR: Could not find download URL in metadata.${NC}"
        return 1
    fi
    
    echo -e "${Blue}:: Downloading OrangeFox...${NC}"
    wget -q --show-progress -O "$OFOX_ZIP" "$OFOX_URL"
else
    echo -e "${Green}:: OrangeFox zip found locally.${NC}"
fi

if [ -f "$OFOX_INPUT_BOOT" ]; then
    rm -rf "$GITHUB_WORKSPACE/work_rec" && mkdir -p "$GITHUB_WORKSPACE/work_rec"
    cp "$OFOX_INPUT_BOOT" "$GITHUB_WORKSPACE/work_rec/boot.img"
    cd "$GITHUB_WORKSPACE/work_rec" || return 1
    
    $magiskboot unpack -h boot.img >/dev/null 2>&1
    unzip -pq "$OFOX_ZIP" recovery.img > recovery.img
    $magiskboot unpack -h recovery.img >/dev/null 2>&1
    mv ramdisk.cpio ramdisk-ofox.cpio
    rm -f kernel dtb recovery.img header
    mv ramdisk-ofox.cpio ramdisk.cpio
    
    if [ -f "header" ]; then
        CMDLINE=$(grep '^cmdline=' header | cut -d= -f2-)
        CLEAN_CMDLINE=$(echo "$CMDLINE" | sed -e 's/skip_override//' -e 's/  */ /g' -e 's/[ \t]*$//')
        sed -i "s|cmdline=$CMDLINE|cmdline=$CLEAN_CMDLINE|" header
    fi
    
    $magiskboot repack boot.img >/dev/null 2>&1
    mv new-boot.img "$OFOX_OUTPUT_BOOT"
    
    cd "$GITHUB_WORKSPACE"
    rm -rf "$GITHUB_WORKSPACE/work_rec"
    
    echo -e "${Green}==> OrangeFox patched boot saved.${NC}"
    
    sudo cp "$OFOX_OUTPUT_BOOT" "$GITHUB_WORKSPACE/${device}/firmware-update/boot.img"
    sudo cp "$OFOX_OUTPUT_BOOT" "$GITHUB_WORKSPACE/images/boot.img"
else
    echo -e "${Red}!! Stock boot.img not found, skipping OrangeFox patch.${NC}"
fi
