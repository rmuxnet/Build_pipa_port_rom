#!/bin/bash

sudo timedatectl set-timezone Europe/Vilnius
sudo apt-get remove -y firefox zstd
sudo apt-get install python3 aria2

URL="$1"              # Port package download URL
VENDOR_URL="$2"       # Base package download URL
GITHUB_ENV="$3"       # Output environment variable file
GITHUB_WORKSPACE="$4" # Working directory

device=pipa # Device codename

Red='\033[1;31m'
Yellow='\033[1;33m'
Blue='\033[1;34m'
Green='\033[1;32m'

# Parse version and zip names from URLs
port_os_version=$(echo ${URL} | cut -d"/" -f4)
port_version=$(echo ${port_os_version} | sed 's/OS1/V816/g')
port_zip_name=$(echo ${URL} | cut -d"/" -f5)
vendor_os_version=$(echo ${VENDOR_URL} | cut -d"/" -f4)
vendor_version=$(echo ${vendor_os_version} | sed 's/OS1/V816/g')
vendor_zip_name=$(echo ${VENDOR_URL} | cut -d"/" -f5)

android_version=$(echo ${URL} | cut -d"_" -f5 | cut -d"." -f1)
build_time=$(date) && build_utc=$(date -d "$build_time" +%s)

sudo chmod -R 777 "$GITHUB_WORKSPACE"/tools
magiskboot="$GITHUB_WORKSPACE"/tools/magiskboot
ksud="$GITHUB_WORKSPACE"/tools/ksud
a7z="$GITHUB_WORKSPACE"/tools/7zzs
zstd="$GITHUB_WORKSPACE"/tools/zstd
payload_extract="$GITHUB_WORKSPACE"/tools/payload_extract
erofs_extract="$GITHUB_WORKSPACE"/tools/extract.erofs
erofs_mkfs="$GITHUB_WORKSPACE"/tools/mkfs.erofs
lpmake="$GITHUB_WORKSPACE"/tools/lpmake
apktool_jar="java -jar "$GITHUB_WORKSPACE"/tools/apktool.jar"

Start_Time() {
  Start_s=$(date +%s)
  Start_ns=$(date +%N)
}

End_Time() {
  local End_s End_ns time_s time_ns
  End_s=$(date +%s)
  End_ns=$(date +%N)
  time_s=$((10#$End_s - 10#$Start_s))
  time_ns=$((10#$End_ns - 10#$Start_ns))
  if ((time_ns < 0)); then
    ((time_s--))
    ((time_ns += 1000000000))
  fi

  local ns ms sec min hour
  ns=$((time_ns % 1000000))
  ms=$((time_ns / 1000000))
  sec=$((time_s % 60))
  min=$((time_s / 60 % 60))
  hour=$((time_s / 3600))

  if ((hour > 0)); then
    echo -e "${Green}- $1 took: ${Blue}$hour h $min m $sec s $ms ms"
  elif ((min > 0)); then
    echo -e "${Green}- $1 took: ${Blue}$min m $sec s $ms ms"
  elif ((sec > 0)); then
    echo -e "${Green}- $1 took: ${Blue}$sec s $ms ms"
  elif ((ms > 0)); then
    echo -e "${Green}- $1 took: ${Blue}$ms ms"
  else
    echo -e "${Green}- $1 took: ${Blue}$ns ns"
  fi
}

# Download ROM packages
echo -e "${Red}- Downloading ROM packages"
echo -e "${Yellow}- Downloading port package"
Start_Time
aria2c -x16 -j$(nproc) -U "Mozilla/5.0" -d "$GITHUB_WORKSPACE" "$URL"
End_Time "Port package download"
Start_Time
echo -e "${Yellow}- Downloading base package"
aria2c -x16 -j$(nproc) -U "Mozilla/5.0" -d "$GITHUB_WORKSPACE" "$VENDOR_URL"
End_Time "Base package download"

# Unpack ROMs
echo -e "${Red}- Extracting ROM packages"
mkdir -p "$GITHUB_WORKSPACE"/Third_Party
mkdir -p "$GITHUB_WORKSPACE"/"${device}"
mkdir -p "$GITHUB_WORKSPACE"/images/config
mkdir -p "$GITHUB_WORKSPACE"/zip

echo -e "${Yellow}- Extracting port package"
Start_Time
$a7z x "$GITHUB_WORKSPACE"/$port_zip_name -r -o"$GITHUB_WORKSPACE"/Third_Party >/dev/null
rm -rf "$GITHUB_WORKSPACE"/$port_zip_name
End_Time "Extract port package"
echo -e "${Yellow}- Extracting base package"
Start_Time
$a7z x "$GITHUB_WORKSPACE"/${vendor_zip_name} -o"$GITHUB_WORKSPACE"/"${device}" payload.bin >/dev/null
rm -rf "$GITHUB_WORKSPACE"/${vendor_zip_name}
End_Time "Extract base package"
mkdir -p "$GITHUB_WORKSPACE"/Extra_dir
echo -e "${Red}- Extracting base payload"
$payload_extract -s -o "$GITHUB_WORKSPACE"/Extra_dir/ -i "$GITHUB_WORKSPACE"/"${device}"/payload.bin -X system,system_ext,product -e -T0
sudo rm -rf "$GITHUB_WORKSPACE"/"${device}"/payload.bin
echo -e "${Red}- Extracting base images"
for i in mi_ext odm system_dlkm vendor vendor_dlkm; do
  echo -e "${Yellow}- Extracting base: $i.img"
  cd "$GITHUB_WORKSPACE"/"${device}"
  sudo $erofs_extract -s -i "$GITHUB_WORKSPACE"/Extra_dir/$i.img -x
  rm -rf "$GITHUB_WORKSPACE"/Extra_dir/$i.img
done
sudo mkdir -p "$GITHUB_WORKSPACE"/"${device}"/firmware-update/
sudo cp -rf "$GITHUB_WORKSPACE"/Extra_dir/* "$GITHUB_WORKSPACE"/"${device}"/firmware-update/
cd "$GITHUB_WORKSPACE"/images
echo -e "${Red}- Extracting port payload"
$payload_extract -s -o "$GITHUB_WORKSPACE"/images/ -i "$GITHUB_WORKSPACE"/Third_Party/payload.bin -X product,system,system_ext -T0
echo -e "${Red}- Extracting port images"
for i in product system system_ext; do
  echo -e "${Yellow}- Extracting port: $i"
  sudo $erofs_extract -s -i "$GITHUB_WORKSPACE"/images/$i.img -x
  rm -rf "$GITHUB_WORKSPACE"/images/$i.img
done
sudo rm -rf "$GITHUB_WORKSPACE"/Third_Party

# Write build variables
echo -e "${Red}- Writing build variables"
echo "build_time=$build_time" >>$GITHUB_ENV
echo -e "${Blue}- Build time: $build_time"
echo "port_os_version=$port_os_version" >>$GITHUB_ENV
echo -e "${Blue}- Port version: $port_os_version"
echo "vendor_os_version=$vendor_os_version" >>$GITHUB_ENV
echo -e "${Blue}- Base version: $vendor_os_version"
system_build_prop=$(find "$GITHUB_WORKSPACE"/images/system/system/ -maxdepth 1 -type f -name "build.prop" | head -n 1)
port_security_patch=$(grep "ro.build.version.security_patch=" "$system_build_prop" | awk -F "=" '{print $2}')
echo -e "${Blue}- Port security patch: $port_security_patch"
echo "port_security_patch=$port_security_patch" >>$GITHUB_ENV
vendor_build_prop=$GITHUB_WORKSPACE/${device}/vendor/build.prop
vendor_security_patch=$(grep "ro.vendor.build.security_patch=" "$vendor_build_prop" | awk -F "=" '{print $2}')
echo -e "${Blue}- Base security patch: $vendor_security_patch"
echo "vendor_security_patch=$vendor_security_patch" >>$GITHUB_ENV
port_base_line=$(grep "ro.system.build.id=" "$system_build_prop" | awk -F "=" '{print $2}')
echo -e "${Blue}- Port baseline: $port_base_line"
echo "port_base_line=$port_base_line" >>$GITHUB_ENV
vendor_base_line=$(grep "ro.vendor.build.id=" "$vendor_build_prop" | awk -F "=" '{print $2}')
echo -e "${Blue}- Base baseline: $vendor_base_line"
echo "vendor_base_line=$vendor_base_line" >>$GITHUB_ENV

# Main patching and customization section
echo -e "${Red}- Starting patching and customization"
Start_Time
# Replace product overlays
echo -e "${Red}- Replace product overlays"
sudo rm -rf "$GITHUB_WORKSPACE"/images/product/overlay/*
sudo unzip -o -q "$GITHUB_WORKSPACE"/"${device}"_files/overlay.zip -d "$GITHUB_WORKSPACE"/images/product/overlay

# Replace device_features
echo -e "${Red}- Replace device_features"
sudo rm -rf "$GITHUB_WORKSPACE"/images/product/etc/device_features/*
sudo unzip -o -q "$GITHUB_WORKSPACE"/"${device}"_files/device_features.zip -d "$GITHUB_WORKSPACE"/images/product/etc/device_features/

# Replace displayconfig
echo -e "${Red}- Replace displayconfig"
sudo rm -rf "$GITHUB_WORKSPACE"/images/product/etc/displayconfig/*
sudo unzip -o -q "$GITHUB_WORKSPACE"/"${device}"_files/displayconfig.zip -d "$GITHUB_WORKSPACE"/images/product/etc/displayconfig/

# Unify build.prop
echo -e "${Red}- Unify build.prop"
sudo sed -i 's/ro.build.user=[^*]*/ro.build.user=YuKongA/' "$GITHUB_WORKSPACE"/images/system/system/build.prop
for port_build_prop in $(sudo find "$GITHUB_WORKSPACE"/images/ -type f -name "build.prop"); do
  sudo sed -i 's/build.date=[^*]*/build.date='"${build_time}"'/' "${port_build_prop}"
  sudo sed -i 's/build.date.utc=[^*]*/build.date.utc='"${build_utc}"'/' "${port_build_prop}"
  sudo sed -i 's/'"${port_os_version}"'/'"${vendor_os_version}"'/g' "${port_build_prop}"
  sudo sed -i 's/'"${port_version}"'/'"${vendor_version}"'/g' "${port_build_prop}"
  sudo sed -i 's/'"${port_base_line}"'/'"${vendor_base_line}"'/g' "${port_build_prop}"
  sudo sed -i 's/ro.product.product.name=[^*]*/ro.product.product.name='"${device}"'/' "${port_build_prop}"
done
for vendor_build_prop in $(sudo find "$GITHUB_WORKSPACE"/"${device}"/ -type f -name "*build.prop"); do
  sudo sed -i 's/build.date=[^*]*/build.date='"${build_time}"'/' "${vendor_build_prop}"
  sudo sed -i 's/build.date.utc=[^*]*/build.date.utc='"${build_utc}"'/' "${vendor_build_prop}"
  sudo sed -i 's/ro.mi.os.version.incremental=[^*]*/ro.mi.os.version.incremental='"${port_os_version}"'/' "${vendor_build_prop}"
done

# Remove unwanted apps
echo -e "${Red}- Remove unwanted apps"
apps=("MIGalleryLockscreen" "MIUIDriveMode" "MIUIDuokanReader" "MIUIGameCenter" "MIUINewHome" "MIUIYoupin" "MIUIHuanJi" "MIUIMiDrive" "MIUIVirtualSim" "ThirdAppAssistant" "XMRemoteController" "MIUIVipAccount" "MiuiScanner" "Xinre" "SmartHome" "MiShop" "MiRadio" "MIUICompass" "MediaEditor" "BaiduIME" "iflytek.inputmethod" "MIService" "MIUIEmail" "MIUIVideo" "MIUIMusicT")
for app in "${apps[@]}"; do
  appsui=$(sudo find "$GITHUB_WORKSPACE"/images/product/data-app/ -type d -iname "*${app}*")
  if [[ -n $appsui ]]; then
    echo -e "${Yellow}- Found and removing: $appsui"
    sudo rm -rf "$appsui"
  fi
done

# Change resolution
echo -e "${Red}- Change resolution"
sudo sed -i 's/persist.miui.density_v2=[^*]*/persist.miui.density_v2=440/' "$GITHUB_WORKSPACE"/images/product/etc/build.prop

# Replace camera
echo -e "${Red}- Replace camera"
sudo rm -rf "$GITHUB_WORKSPACE"/images/product/priv-app/MiuiCamera/*
sudo unzip -o -q "$GITHUB_WORKSPACE"/"${device}"_files/MiuiCamera.zip -d "$GITHUB_WORKSPACE"/images/product/priv-app/MiuiCamera/

# --- OrangeFox Recovery patching ---
echo -e "${Red}- Patching OrangeFox Recovery"
OFOX_JSON_URL="https://raw.githubusercontent.com/PipaDB/Releases/refs/heads/main/ofox.json"
OFOX_ZIP="$GITHUB_WORKSPACE/tools/ofox.zip"
OFOX_OUTPUT_DIR="$GITHUB_WORKSPACE/output_patched"
OFOX_INPUT_BOOT="$GITHUB_WORKSPACE/${device}/firmware-update/boot.img"
OFOX_OUTPUT_BOOT="$OFOX_OUTPUT_DIR/ofox-boot-pipa.img"

mkdir -p "$OFOX_OUTPUT_DIR" "$GITHUB_WORKSPACE/tools"

if [[ -f "$OFOX_ZIP" ]]; then
    echo -e "${Blue}::${NC} OrangeFox zip found locally."
else
    echo -e "${Blue}::${NC} Fetching OrangeFox metadata..."
    JSON_DATA=$(curl -sL "$OFOX_JSON_URL")
    OFOX_URL=$(echo "$JSON_DATA" | grep -oP '(?<="url": ")[^"]*')
    if [[ -z "$OFOX_URL" ]]; then
        echo -e "\033[0;31m[ERROR]\033[0m Could not find download URL in metadata."
        exit 1
    fi
    echo -e "${Blue}::${NC} Downloading OrangeFox..."
    wget -q --show-progress -O "$OFOX_ZIP" "$OFOX_URL" || { echo -e "\033[0;31m[ERROR]\033[0m Download failed."; exit 1; }
fi

if [ ! -f "$OFOX_INPUT_BOOT" ]; then
    echo -e "\033[0;31m[ERROR]\033[0m Stock boot.img not found in firmware-update/"
    exit 1
fi

rm -rf "$GITHUB_WORKSPACE/work_rec" && mkdir -p "$GITHUB_WORKSPACE/work_rec"
cp "$OFOX_INPUT_BOOT" "$GITHUB_WORKSPACE/work_rec/boot.img"
cd "$GITHUB_WORKSPACE/work_rec" || exit 1
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

echo -e "${Green}==>${NC} ${BOLD}OrangeFox patched boot saved to: $OFOX_OUTPUT_BOOT${NC}"

# Copy changed files and cleanup
echo -e "${Red}- Copy changed files and cleanup"
sudo cp -r "$GITHUB_WORKSPACE"/"${device}"/* "$GITHUB_WORKSPACE"/images
sudo rm -rf "$GITHUB_WORKSPACE"/"${device}"
sudo rm -rf "$GITHUB_WORKSPACE"/"${device}"_files
End_Time "Patching and customization"

# Build super.img
echo -e "${Red}- Building super.img"
Start_Time
partitions=("mi_ext" "odm" "product" "system" "system_ext" "vendor")
for partition in "${partitions[@]}"; do
  echo -e "${Red}- Building: $partition"
  sudo python3 "$GITHUB_WORKSPACE"/tools/fspatch.py "$GITHUB_WORKSPACE"/images/$partition "$GITHUB_WORKSPACE"/images/config/"$partition"_fs_config
  sudo python3 "$GITHUB_WORKSPACE"/tools/contextpatch.py "$GITHUB_WORKSPACE"/images/$partition "$GITHUB_WORKSPACE"/images/config/"$partition"_file_contexts
  sudo $erofs_mkfs --quiet -zlz4hc,9 -T 1230768000 --mount-point /$partition --fs-config-file "$GITHUB_WORKSPACE"/images/config/"$partition"_fs_config --file-contexts "$GITHUB_WORKSPACE"/images/config/"$partition"_file_contexts "$GITHUB_WORKSPACE"/images/$partition.img "$GITHUB_WORKSPACE"/images/$partition
  eval "${partition}_size=$(du -sb "$GITHUB_WORKSPACE"/images/$partition.img | awk '{print $1}')"
  sudo rm -rf "$GITHUB_WORKSPACE"/images/$partition
done
sudo rm -rf "$GITHUB_WORKSPACE"/images/config
$lpmake --metadata-size 65536 --super-name super --block-size 4096 \
  --partition mi_ext_a:readonly:"$mi_ext_size":qti_dynamic_partitions_a --image mi_ext_a="$GITHUB_WORKSPACE"/images/mi_ext.img \
  --partition mi_ext_b:readonly:0:qti_dynamic_partitions_b \
  --partition odm_a:readonly:"$odm_size":qti_dynamic_partitions_a --image odm_a="$GITHUB_WORKSPACE"/images/odm.img \
  --partition odm_b:readonly:0:qti_dynamic_partitions_b \
  --partition product_a:readonly:"$product_size":qti_dynamic_partitions_a --image product_a="$GITHUB_WORKSPACE"/images/product.img \
  --partition product_b:readonly:0:qti_dynamic_partitions_b \
  --partition system_a:readonly:"$system_size":qti_dynamic_partitions_a --image system_a="$GITHUB_WORKSPACE"/images/system.img \
  --partition system_b:readonly:0:qti_dynamic_partitions_b \
  --partition system_ext_a:readonly:"$system_ext_size":qti_dynamic_partitions_a --image system_ext_a="$GITHUB_WORKSPACE"/images/system_ext.img \
  --partition system_ext_b:readonly:0:qti_dynamic_partitions_b \
  --partition vendor_a:readonly:"$vendor_size":qti_dynamic_partitions_a --image vendor_a="$GITHUB_WORKSPACE"/images/vendor.img \
  --partition vendor_b:readonly:0:qti_dynamic_partitions_b \
  --device super:9126805504 --metadata-slots 3 \
  --group qti_dynamic_partitions_a:9126805504 --group qti_dynamic_partitions_b:9126805504 --virtual-ab -F \
  --output "$GITHUB_WORKSPACE"/images/super.img
End_Time "Build super"
for i in mi_ext odm product system system_ext vendor; do
  rm -rf "$GITHUB_WORKSPACE"/images/$i.img
done

# Output flashable zip
echo -e "${Red}- Creating flashable zip"
echo -e "${Red}- Compressing super.zst"
Start_Time
sudo find "$GITHUB_WORKSPACE"/images/ -exec touch -t 200901010000.00 {} \;
zstd -12 -f "$GITHUB_WORKSPACE"/images/super.img -o "$GITHUB_WORKSPACE"/images/super.zst --rm
End_Time "Compress super.zst"
echo -e "${Red}- Creating flashable zip"
Start_Time
sudo $a7z a "$GITHUB_WORKSPACE"/zip/hyperos_${device}_${port_os_version}.zip "$GITHUB_WORKSPACE"/images/* >/dev/null
sudo rm -rf "$GITHUB_WORKSPACE"/images
End_Time "Compress flashable zip"
echo -e "${Red}- Customizing ROM filename"
md5=$(md5sum "$GITHUB_WORKSPACE"/zip/hyperos_${device}_${port_os_version}.zip)
echo "MD5=${md5:0:32}" >>$GITHUB_ENV
zip_md5=${md5:0:10}
rom_name="hyperos2.2_PIPA_${port_os_version}_${zip_md5}_${android_version}_rmux.zip"
sudo mv "$GITHUB_WORKSPACE"/zip/hyperos_${device}_${port_os_version}.zip "$GITHUB_WORKSPACE"/zip/"${rom_name}"
echo "rom_name=$rom_name" >>$GITHUB_ENV