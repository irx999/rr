#!/usr/bin/env bash

set -e

if [ ! -d .buildroot ]; then
  echo "Downloading buildroot"
  git clone --single-branch -b 2022.02 https://github.com/buildroot/buildroot.git .buildroot
fi

echo "Convert po2mo"
if [ -d files/board/arpl/overlayfs/opt/arpl/lang ]; then
  for P in "`ls files/board/arpl/overlayfs/opt/arpl/lang/*.po`"
  do
    # Use msgfmt command to compile the .po file into a binary .mo file
    msgfmt ${P} -o ${P/.po/.mo}
  done
fi

# Get extractor
echo "Getting syno extractor"
TOOL_PATH="files/board/arpl/p3/extractor"
CACHE_DIR="/tmp/pat"
rm -rf "${TOOL_PATH}"
mkdir -p "${TOOL_PATH}"
rm -rf "${CACHE_DIR}"
mkdir -p "${CACHE_DIR}"
OLDPAT_URL="https://global.download.synology.com/download/DSM/release/7.0.1/42218/DSM_DS3622xs%2B_42218.pat"
OLDPAT_FILE="DSM_DS3622xs+_42218.pat"
STATUS=`curl -# -w "%{http_code}" -L "${OLDPAT_URL}" -o "${CACHE_DIR}/${OLDPAT_FILE}"`
if [ $? -ne 0 -o ${STATUS} -ne 200 ]; then
  echo "[E] DSM_DS3622xs%2B_42218.pat download error!"
  rm -rf ${CACHE_DIR}
  exit 1
fi

mkdir -p "${CACHE_DIR}/ramdisk"
tar -C "${CACHE_DIR}/ramdisk/" -xf "${CACHE_DIR}/${OLDPAT_FILE}" rd.gz 2>&1
if [ $? -ne 0 ]; then
  echo "[E] extractor rd.gz error!"
  rm -rf ${CACHE_DIR}
  exit 1
fi
(cd "${CACHE_DIR}/ramdisk"; xz -dc < rd.gz | cpio -idm) >/dev/null 2>&1 || true

# Copy only necessary files
for f in libcurl.so.4 libmbedcrypto.so.5 libmbedtls.so.13 libmbedx509.so.1 libmsgpackc.so.2 libsodium.so libsynocodesign-ng-virtual-junior-wins.so.7; do
  cp "${CACHE_DIR}/ramdisk/usr/lib/${f}" "${TOOL_PATH}"
done
cp "${CACHE_DIR}/ramdisk/usr/syno/bin/scemd" "${TOOL_PATH}/syno_extract_system_patch"
rm -rf ${CACHE_DIR}

# Get latest LKMs
echo "Getting latest LKMs"
echo "  Downloading LKMs from github"
TAG=`curl -s https://api.github.com/repos/wjz304/redpill-lkm/releases/latest | grep "tag_name" | awk '{print substr($2, 2, length($2)-3)}'`
curl -L "https://github.com/wjz304/redpill-lkm/releases/download/${TAG}/rp-lkms.zip" -o /tmp/rp-lkms.zip
rm -rf files/board/arpl/p3/lkms/*
unzip /tmp/rp-lkms.zip -d files/board/arpl/p3/lkms


# Get latest addons and install its
echo "Getting latest Addons"
rm -Rf /tmp/addons
mkdir -p /tmp/addons
echo "  Downloading Addons from github"
TAG=`curl -s https://api.github.com/repos/wjz304/arpl-addons/releases/latest | grep "tag_name" | awk '{print substr($2, 2, length($2)-3)}'`
curl -L "https://github.com/wjz304/arpl-addons/releases/download/${TAG}/addons.zip" -o /tmp/addons.zip
rm -rf /tmp/addons
unzip /tmp/addons.zip -d /tmp/addons
DEST_PATH="files/board/arpl/p3/addons"
echo "Installing addons to ${DEST_PATH}"
for PKG in `ls /tmp/addons/*.addon`; do
  ADDON=`basename ${PKG} | sed 's|.addon||'`
  mkdir -p "${DEST_PATH}/${ADDON}"
  echo "Extracting ${PKG} to ${DEST_PATH}/${ADDON}"
  tar xaf "${PKG}" -C "${DEST_PATH}/${ADDON}"
done

# Get latest modules
echo "Getting latest modules"
echo "  Downloading Modules from github"
MODULES_DIR="${PWD}/files/board/arpl/p3/modules"

TAG=`curl -s https://api.github.com/repos/wjz304/arpl-modules/releases/latest | grep "tag_name" | awk '{print substr($2, 2, length($2)-3)}'`
curl -L "https://github.com/wjz304/arpl-modules/releases/download/${TAG}/modules.zip" -o "/tmp/modules.zip"
rm -rf "${MODULES_DIR}/"*
unzip /tmp/modules.zip -d "${MODULES_DIR}"


# Remove old files
rm -rf ".buildroot/output/target/opt/arpl"
rm -rf ".buildroot/board/arpl/overlayfs"
rm -rf ".buildroot/board/arpl/p1"
rm -rf ".buildroot/board/arpl/p3"

# Copy files
echo "Copying files"
VERSION=`cat VERSION`
sed 's/^ARPL_VERSION=.*/ARPL_VERSION="'${VERSION}'"/' -i files/board/arpl/overlayfs/opt/arpl/include/consts.sh
echo "${VERSION}" > files/board/arpl/p1/ARPL-VERSION
cp -Ru files/* .buildroot/

cd .buildroot
echo "Generating default config"
make BR2_EXTERNAL=../external -j`nproc` arpl_defconfig
echo "Version: ${VERSION}"
echo "Building... Drink a coffee and wait!"
make BR2_EXTERNAL=../external -j`nproc`
cd -
qemu-img convert -O vmdk arpl.img arpl-dyn.vmdk
qemu-img convert -O vmdk -o adapter_type=lsilogic arpl.img -o subformat=monolithicFlat arpl.vmdk
[ -x test.sh ] && ./test.sh
rm -f *.zip
zip -9 "arpl-i18n-${VERSION}.img.zip" arpl.img
zip -9 "arpl-i18n-${VERSION}.vmdk-dyn.zip" arpl-dyn.vmdk
zip -9 "arpl-i18n-${VERSION}.vmdk-flat.zip" arpl.vmdk arpl-flat.vmdk
sha256sum update-list.yml > sha256sum
zip -9j update.zip update-list.yml
while read F; do
  if [ -d "${F}" ]; then
    FTGZ="`basename "${F}"`.tgz"
    tar czf "${FTGZ}" -C "${F}" .
    sha256sum "${FTGZ}" >> sha256sum
    zip -9j update.zip "${FTGZ}"
    rm "${FTGZ}"
  else
    (cd `dirname ${F}` && sha256sum `basename ${F}`) >> sha256sum
    zip -9j update.zip "${F}"
  fi
done < <(yq '.replace | explode(.) | to_entries | map([.key])[] | .[]' update-list.yml)
zip -9j update.zip sha256sum 
rm -f sha256sum
