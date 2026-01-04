#!/bin/bash

# --- Setup & Tools ---
sudo timedatectl set-timezone Europe/Vilnius
sudo apt-get remove -y firefox zstd
sudo apt-get install python3 aria2

URL="$1"              # Port package download URL
VENDOR_URL="$2"       # Base package download URL
GITHUB_ENV="$3"       # Output environment variable file
GITHUB_WORKSPACE="$4" # Working directory

# Environment variable check for Optional Features
INCLUDE_OFOX="${INCLUDE_OFOX:-false}" # Default to false if not set

device=pipa # Device codename

Red='\033[1;31m'
Yellow='\033[1;33m'
Blue='\033[1;34m'
Green='\033[1;32m'

# Parse versions
port_os_version=$(echo ${URL} | cut -d"/" -f4)
port_version=$(echo ${port_os_version} | sed 's/OS1/V816/g')
port_zip_name=$(echo ${URL} | cut -d"/" -f5)
vendor_os_version=$(echo ${VENDOR_URL} | cut -d"/" -f4)
vendor_version=$(echo ${vendor_os_version} | sed 's/OS1/V816/g')
vendor_zip_name=$(echo ${VENDOR_URL} | cut -d"/" -f5)
android_version=$(echo ${URL} | cut -d"_" -f5 | cut -d"." -f1)
build_time=$(date) && build_utc=$(date -d "$build_time" +%s)

# Setup Tools
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

# --- Download ---
echo -e "${Red}- Downloading ROM packages"
echo -e "${Yellow}- Downloading port package"
aria2c -x16 -j$(nproc) -U "Mozilla/5.0" -d "$GITHUB_WORKSPACE" "$URL"
echo -e "${Yellow}- Downloading base package"
aria2c -x16 -j$(nproc) -U "Mozilla/5.0" -d "$GITHUB_WORKSPACE" "$VENDOR_URL"

# --- Unpack ---
echo -e "${Red}- Extracting ROM packages"
mkdir -p "$GITHUB_WORKSPACE"/Third_Party
mkdir -p "$GITHUB_WORKSPACE"/"${device}"
mkdir -p "$GITHUB_WORKSPACE"/images/config
mkdir -p "$GITHUB_WORKSPACE"/zip

# Extract Port Zip
echo -e "${Yellow}- Extracting port zip"
$a7z x "$GITHUB_WORKSPACE"/$port_zip_name -r -o"$GITHUB_WORKSPACE"/Third_Party >/dev/null
rm -rf "$GITHUB_WORKSPACE"/$port_zip_name

# Extract Base Zip
echo -e "${Yellow}- Extracting base zip"
$a7z x "$GITHUB_WORKSPACE"/${vendor_zip_name} -o"$GITHUB_WORKSPACE"/"${device}" payload.bin >/dev/null
rm -rf "$GITHUB_WORKSPACE"/${vendor_zip_name}

# --- Extracting Base Payload ---
mkdir -p "$GITHUB_WORKSPACE"/Extra_dir
echo -e "${Red}- Extracting base payload"
# We exclude system, system_ext, product because those come from the Port ROM
$payload_extract -s -o "$GITHUB_WORKSPACE"/Extra_dir/ -i "$GITHUB_WORKSPACE"/"${device}"/payload.bin -X system,system_ext,product -e -T0
sudo rm -rf "$GITHUB_WORKSPACE"/"${device}"/payload.bin

echo -e "${Red}- Processing Base Images"

# 1. EXTRACT 'mi_ext' because we will modify it
echo -e "${Yellow}- Extracting mi_ext for modification..."
cd "$GITHUB_WORKSPACE"/"${device}"
sudo $erofs_extract -s -i "$GITHUB_WORKSPACE"/Extra_dir/mi_ext.img -x
rm -rf "$GITHUB_WORKSPACE"/Extra_dir/mi_ext.img

# 2. SEPARATE Super images from Firmware images
echo -e "${Yellow}- Preparing Super Partition files..."
sudo mv "$GITHUB_WORKSPACE"/Extra_dir/odm.img "$GITHUB_WORKSPACE"/images/
sudo mv "$GITHUB_WORKSPACE"/Extra_dir/vendor.img "$GITHUB_WORKSPACE"/images/
if [ -f "$GITHUB_WORKSPACE"/Extra_dir/dsp.img ]; then
    sudo mv "$GITHUB_WORKSPACE"/Extra_dir/dsp.img "$GITHUB_WORKSPACE"/images/
    echo -e "${Green}:: Stock dsp.img moved to images/"
else
    echo -e "${Red}!! WARNING: Stock dsp.img not found."
fi

# 3. Everything else is FIRMWARE
echo -e "${Yellow}- Preparing Firmware-Update folder..."
sudo mkdir -p "$GITHUB_WORKSPACE"/"${device}"/firmware-update/
sudo cp -rf "$GITHUB_WORKSPACE"/Extra_dir/* "$GITHUB_WORKSPACE"/"${device}"/firmware-update/
rm -rf "$GITHUB_WORKSPACE"/Extra_dir

# --- Extracting Port Payload ---
cd "$GITHUB_WORKSPACE"/images
echo -e "${Red}- Extracting port payload"
$payload_extract -s -o "$GITHUB_WORKSPACE"/images/ -i "$GITHUB_WORKSPACE"/Third_Party/payload.bin -X product,system,system_ext -T0
echo -e "${Red}- Extracting port images (system, product, system_ext)"
for i in product system system_ext; do
  echo -e "${Yellow}- Extracting port: $i"
  sudo $erofs_extract -s -i "$GITHUB_WORKSPACE"/images/$i.img -x
  rm -rf "$GITHUB_WORKSPACE"/images/$i.img
done
sudo rm -rf "$GITHUB_WORKSPACE"/Third_Party

# --- Build Variables ---
echo -e "${Red}- Writing build variables"
echo "build_time=$build_time" >>$GITHUB_ENV
echo "port_os_version=$port_os_version" >>$GITHUB_ENV
echo "vendor_os_version=$vendor_os_version" >>$GITHUB_ENV

system_build_prop=$(find "$GITHUB_WORKSPACE"/images/system/system/ -maxdepth 1 -type f -name "build.prop" | head -n 1)
port_security_patch=$(grep "ro.build.version.security_patch=" "$system_build_prop" | awk -F "=" '{print $2}')
echo "port_security_patch=$port_security_patch" >>$GITHUB_ENV
port_base_line=$(grep "ro.system.build.id=" "$system_build_prop" | awk -F "=" '{print $2}')
echo "port_base_line=$port_base_line" >>$GITHUB_ENV

update_mi_ext_incremental() {
  local build_prop="$GITHUB_WORKSPACE/images/mi_ext/etc/build.prop"
  if [ -f "$build_prop" ]; then
    local version=$(grep '^ro.mi.os.version.incremental=' "$build_prop" | cut -d= -f2-)
    if [ -n "$version" ]; then
      sudo sed -i "s|^ro.mi.os.version.incremental=.*$|ro.mi.os.version.incremental=${version} | rmux|" "$build_prop"
    fi
  fi
}

# --- Patching & Customization ---
echo -e "${Red}- Starting patching and customization"

update_mi_ext_incremental

echo -e "${Red}- Replace product overlays"
sudo rm -rf "$GITHUB_WORKSPACE"/images/product/overlay/*
sudo unzip -o -q "$GITHUB_WORKSPACE"/"${device}"_files/overlay.zip -d "$GITHUB_WORKSPACE"/images/product/overlay

echo -e "${Red}- Replace device_features"
sudo rm -rf "$GITHUB_WORKSPACE"/images/product/etc/device_features/*
sudo unzip -o -q "$GITHUB_WORKSPACE"/"${device}"_files/device_features.zip -d "$GITHUB_WORKSPACE"/images/product/etc/device_features/

echo -e "${Red}- Replace displayconfig"
sudo rm -rf "$GITHUB_WORKSPACE"/images/product/etc/displayconfig/*
sudo unzip -o -q "$GITHUB_WORKSPACE"/"${device}"_files/displayconfig.zip -d "$GITHUB_WORKSPACE"/images/product/etc/displayconfig/

echo -e "${Red}- Unify build.prop"
sudo sed -i 's/ro.build.user=[^*]*/ro.build.user=rmux/' "$GITHUB_WORKSPACE"/images/system/system/build.prop
for port_build_prop in $(sudo find "$GITHUB_WORKSPACE"/images/ -type f -name "build.prop"); do
  sudo sed -i 's/build.date=[^*]*/build.date='"${build_time}"'/' "${port_build_prop}"
  sudo sed -i 's/build.date.utc=[^*]*/build.date.utc='"${build_utc}"'/' "${port_build_prop}"
  sudo sed -i 's/'"${port_os_version}"'/'"${vendor_os_version}"'/g' "${port_build_prop}"
  sudo sed -i 's/'"${port_version}"'/'"${vendor_version}"'/g' "${port_build_prop}"
  sudo sed -i 's/'"${port_base_line}"'/'"${vendor_base_line}"'/g' "${port_build_prop}"
  sudo sed -i 's/ro.product.product.name=[^*]*/ro.product.product.name='"${device}"'/' "${port_build_prop}"
done

echo -e "${Red}- Change resolution"
sudo sed -i 's/persist.miui.density_v2=[^*]*/persist.miui.density_v2=440/' "$GITHUB_WORKSPACE"/images/product/etc/build.prop
if [ -f "$GITHUB_WORKSPACE/images/product/etc/build.prop" ]; then
  sudo sed -i 's/sheng/pipa/g' "$GITHUB_WORKSPACE/images/product/etc/build.prop"
fi

echo -e "${Red}- Replace camera"
sudo rm -rf "$GITHUB_WORKSPACE"/images/product/priv-app/MiuiCamera/*
sudo unzip -o -q "$GITHUB_WORKSPACE"/"${device}"_files/MiuiCamera.zip -d "$GITHUB_WORKSPACE/images/product/priv-app/MiuiCamera/"

echo -e "${Red}- Overwriting apex in system_ext"
if [ -f "$GITHUB_WORKSPACE/${device}_files/apex.zip" ]; then
    sudo unzip -o -q "$GITHUB_WORKSPACE"/"${device}"_files/apex.zip -d "$GITHUB_WORKSPACE/images/system_ext/apex/"
    echo -e "${Green}:: Apex files overwritten."
else
    echo -e "${Yellow}:: No apex.zip found."
fi

echo -e "${Red}- Adding Via Browser"
if [ -f "$GITHUB_WORKSPACE/${device}_files/Via.zip" ]; then
  sudo mkdir -p "$GITHUB_WORKSPACE/images/product/app/Via"
  sudo unzip -o -q "$GITHUB_WORKSPACE"/"${device}"_files/Via.zip -d "$GITHUB_WORKSPACE/images/product/app/Via/"
else
  echo -e "${Red}!! ERROR: Via.zip not found"
fi

echo -e "${Red}- Adding Gboard"
if [ -f "$GITHUB_WORKSPACE/${device}_files/LatinImeGoogle.zip" ]; then
  sudo mkdir -p "$GITHUB_WORKSPACE/images/product/data-app/LatinImeGoogle"
  sudo unzip -o -q "$GITHUB_WORKSPACE"/"${device}"_files/LatinImeGoogle.zip -d "$GITHUB_WORKSPACE/images/product/data-app/LatinImeGoogle/"
else
  echo -e "${Red}!! ERROR: LatinImeGoogle.zip not found"
fi

if [ -d "$GITHUB_WORKSPACE/${device}_files/pangu" ]; then
  echo -e "${Red}- Adding pangu"
  sudo cp -r "$GITHUB_WORKSPACE/${device}_files/pangu" "$GITHUB_WORKSPACE/images/product/pangu"
fi

# --- OrangeFox Patching (Optional) ---
# Checked via environment variable INCLUDE_OFOX
if [ "$INCLUDE_OFOX" == "true" ]; then
    echo -e "${Red}- Running OrangeFox Patching Script..."
    if [ -f "$GITHUB_WORKSPACE/tools/ofox_patch.sh" ]; then
        chmod +x "$GITHUB_WORKSPACE/tools/ofox_patch.sh"
        # Source to share variables like $device and $GITHUB_WORKSPACE
        source "$GITHUB_WORKSPACE/tools/ofox_patch.sh"
    else
        echo -e "${Red}!! ERROR: tools/ofox_patch.sh not found!"
    fi
else
    echo -e "${Yellow}- OrangeFox Patching skipped (INCLUDE_OFOX is false)."
fi

# Cleanup customized files
echo -e "${Red}- Cleanup"
sudo cp -r "$GITHUB_WORKSPACE"/"${device}"/* "$GITHUB_WORKSPACE"/images
sudo rm -rf "$GITHUB_WORKSPACE"/"${device}"
sudo rm -rf "$GITHUB_WORKSPACE"/"${device}"_files

# --- Building Super ---
echo -e "${Red}- Building super.img"

# 1. Rebuild ONLY the modified partitions
partitions=("mi_ext" "product" "system" "system_ext")
for partition in "${partitions[@]}"; do
  echo -e "${Red}- Rebuilding modified partition: $partition"
  sudo python3 "$GITHUB_WORKSPACE"/tools/fspatch.py "$GITHUB_WORKSPACE"/images/$partition "$GITHUB_WORKSPACE"/images/config/"$partition"_fs_config
  sudo python3 "$GITHUB_WORKSPACE"/tools/contextpatch.py "$GITHUB_WORKSPACE"/images/$partition "$GITHUB_WORKSPACE"/images/config/"$partition"_file_contexts
  sudo $erofs_mkfs --quiet -zlz4hc,9 -T 1230768000 --mount-point /$partition --fs-config-file "$GITHUB_WORKSPACE"/images/config/"$partition"_fs_config --file-contexts "$GITHUB_WORKSPACE"/images/config/"$partition"_file_contexts "$GITHUB_WORKSPACE"/images/$partition.img "$GITHUB_WORKSPACE"/images/$partition
  sudo rm -rf "$GITHUB_WORKSPACE"/images/$partition
done
sudo rm -rf "$GITHUB_WORKSPACE"/images/config

# 2. Get sizes for ALL partitions (Rebuilt + Stock)
eval "mi_ext_size=$(du -sb "$GITHUB_WORKSPACE"/images/mi_ext.img | awk '{print $1}')"
eval "odm_size=$(du -sb "$GITHUB_WORKSPACE"/images/odm.img | awk '{print $1}')"
eval "product_size=$(du -sb "$GITHUB_WORKSPACE"/images/product.img | awk '{print $1}')"
eval "system_size=$(du -sb "$GITHUB_WORKSPACE"/images/system.img | awk '{print $1}')"
eval "system_ext_size=$(du -sb "$GITHUB_WORKSPACE"/images/system_ext.img | awk '{print $1}')"
eval "vendor_size=$(du -sb "$GITHUB_WORKSPACE"/images/vendor.img | awk '{print $1}')"
if [ -f "$GITHUB_WORKSPACE/images/dsp.img" ]; then
    eval "dsp_size=$(du -sb "$GITHUB_WORKSPACE"/images/dsp.img | awk '{print $1}')"
else
    dsp_size=0
fi

# 3. Pack Super
$lpmake --metadata-size 65536 --super-name super --block-size 4096 \
  --partition dsp_a:readonly:"$dsp_size":qti_dynamic_partitions_a --image dsp_a="$GITHUB_WORKSPACE"/images/dsp.img \
  --partition dsp_b:readonly:0:qti_dynamic_partitions_b \
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

# Cleanup Images
for i in dsp mi_ext odm product system system_ext vendor; do
  rm -rf "$GITHUB_WORKSPACE"/images/$i.img
done

# --- Add Flash Tools ---
echo -e "${Red}- Adding Flash Tools"
if [ -f "$GITHUB_WORKSPACE/tools/flashtools.zip" ]; then
    sudo unzip -o -q "$GITHUB_WORKSPACE"/tools/flashtools.zip -d "$GITHUB_WORKSPACE"/images
    echo -e "${Green}:: Flash tools added."
else
    echo -e "${Red}!! WARNING: flashtools.zip not found in tools/ folder."
fi

# --- Compress & Output ---
echo -e "${Red}- Creating flashable zip"
sudo find "$GITHUB_WORKSPACE"/images/ -exec touch -t 200901010000.00 {} \;
zstd -12 -f "$GITHUB_WORKSPACE"/images/super.img -o "$GITHUB_WORKSPACE"/images/super.zst --rm

echo -e "${Red}- Packaging zip"
sudo $a7z a "$GITHUB_WORKSPACE"/zip/hyperos_${device}_${port_os_version}.zip "$GITHUB_WORKSPACE"/images/* >/dev/null
sudo rm -rf "$GITHUB_WORKSPACE"/images

md5=$(md5sum "$GITHUB_WORKSPACE"/zip/hyperos_${device}_${port_os_version}.zip)
echo "MD5=${md5:0:32}" >>$GITHUB_ENV
zip_md5=${md5:0:10}
rom_name="hyperos2.2_PIPA_${port_os_version}_${zip_md5}_${android_version}_rmux.zip"
sudo mv "$GITHUB_WORKSPACE"/zip/hyperos_${device}_${port_os_version}.zip "$GITHUB_WORKSPACE"/zip/"${rom_name}"
echo "rom_name=$rom_name" >>$GITHUB_ENV
