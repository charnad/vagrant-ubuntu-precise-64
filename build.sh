#!/bin/bash

# make sure we have dependencies
hash vagrant 2>/dev/null || { echo >&2 "ERROR: vagrant not found.  Aborting."; exit 1; }
hash VBoxManage 2>/dev/null || { echo >&2 "ERROR: VBoxManage not found.  Aborting."; exit 1; }
hash 7z 2>/dev/null || { echo >&2 "ERROR: 7z not found. Aborting."; exit 1; }

VBOX_VERSION="$(VBoxManage --version)"

if hash mkisofs 2>/dev/null; then
  MKISOFS="$(which mkisofs)"
elif hash genisoimage 2>/dev/null; then
  MKISOFS="$(which genisoimage)"
else
  echo >&2 "ERROR: mkisofs or genisoimage not found.  Aborting."
  exit 1
fi

set -o nounset
set -o errexit
#set -o xtrace

# Configurations
BOX="ubuntu-vivid-64"
ISO_URL="http://releases.ubuntu.com/vivid/ubuntu-15.04-server-amd64.iso"
ISO_MD5="487f4a81f22f8597503db3d51a1b502e"

# location, location, location
FOLDER_BASE=`pwd`
FOLDER_ISO="${FOLDER_BASE}/iso"
FOLDER_BUILD="${FOLDER_BASE}/build"
FOLDER_VBOX="${FOLDER_BUILD}/vbox"
FOLDER_ISO_CUSTOM="${FOLDER_BUILD}/iso/custom"

# Env option: Use headless mode or GUI
VM_GUI="${VM_GUI:-}"
if [ "x${VM_GUI}" == "xyes" ] || [ "x${VM_GUI}" == "x1" ]; then
  STARTVM="VBoxManage startvm ${BOX}"
else
 STARTVM="VBoxManage startvm ${BOX} --type headless"
fi

# Env option: Use custom preseed.cfg or default
DEFAULT_PRESEED="preseed.cfg"
PRESEED="${PRESEED:-"$DEFAULT_PRESEED"}"

# Env option: Use custom late_command.sh or default
DEFAULT_LATE_CMD="${FOLDER_BASE}/late_command.sh"
LATE_CMD="${LATE_CMD:-"$DEFAULT_LATE_CMD"}"

# Parameter changes from 4.2 to 4.3
if [[ "$VBOX_VERSION" < 4.3 ]]; then
  PORTCOUNT="--sataportcount 1"
else
  PORTCOUNT="--portcount 1"
fi

if [ "$OSTYPE" = "linux-gnu" ]; then
  MD5="md5sum"
elif [ "$OSTYPE" = "msys" ]; then
  MD5="md5 -l"
else
  MD5="md5 -q"
fi

# start with a clean slate
if [ -d "${FOLDER_BUILD}" ]; then
  echo "Cleaning build directory ..."
  chmod -R u+w "${FOLDER_BUILD}"
  rm -rf "${FOLDER_BUILD}"
fi
if [ -f "${FOLDER_ISO}/custom.iso" ]; then
  echo "Removing custom iso ..."
  rm "${FOLDER_ISO}/custom.iso"
fi
if [ -f "${FOLDER_BASE}/${BOX}.box" ]; then
  echo "Removing old ${BOX}.box" ...
  rm "${FOLDER_BASE}/${BOX}.box"
fi
if VBoxManage showvminfo "${BOX}" >/dev/null 2>/dev/null; then
  echo "Unregistering vm ..."
  VBoxManage unregistervm "${BOX}" --delete
fi

# Setting things back up again
mkdir -p "${FOLDER_ISO}"
mkdir -p "${FOLDER_BUILD}"
mkdir -p "${FOLDER_VBOX}"
mkdir -p "${FOLDER_ISO_CUSTOM}"

ISO_FILENAME="${FOLDER_ISO}/`basename ${ISO_URL}`"

# download the installation disk if you haven't already or it is corrupted somehow
echo "Downloading `basename ${ISO_URL}` ..."
if [ ! -e "${ISO_FILENAME}" ]; then
  curl --output "${ISO_FILENAME}" -L "${ISO_URL}"

  # make sure download is right...
  ISO_HASH=`${MD5} "${ISO_FILENAME}" | cut -b-32`
  if [ "${ISO_MD5}" != "${ISO_HASH}" ]; then
    echo "ERROR: MD5 does not match. Got ${ISO_HASH} instead of ${ISO_MD5}. Aborting."
    exit 1
  fi
fi

# customize it
echo "Creating Custom ISO"
if [ ! -e "${FOLDER_ISO}/custom.iso" ]; then

  echo "Using 7zip"
  7z x "${ISO_FILENAME}" -o"${FOLDER_ISO_CUSTOM}"

  # If that didn't work, you have to update p7zip
  if [ ! -e $FOLDER_ISO_CUSTOM ]; then
    echo "Error with extracting the ISO file with your version of p7zip. Try updating to the latest version."
    exit 1
  fi

  cd "${FOLDER_BASE}"
  if [ "${PRESEED}" != "${DEFAULT_PRESEED}" ] ; then
    echo "Using custom preseed file ${PRESEED}"
  fi
  cp "${PRESEED}" "${FOLDER_ISO_CUSTOM}/preseed/vagrant.seed"

  # replace isolinux configuration
  echo "Replacing isolinux config ..."
  cd "${FOLDER_BASE}"
  chmod u+w "${FOLDER_ISO_CUSTOM}/isolinux" "${FOLDER_ISO_CUSTOM}/isolinux/isolinux.cfg"
  rm "${FOLDER_ISO_CUSTOM}/isolinux/isolinux.cfg"
  cp isolinux.cfg "${FOLDER_ISO_CUSTOM}/isolinux/isolinux.cfg"  
  chmod u+w "${FOLDER_ISO_CUSTOM}/isolinux/isolinux.bin"

  # add late_command script
  echo "Add late_command script ..."
  chmod u+w "${FOLDER_ISO_CUSTOM}"
  cp "${LATE_CMD}" "${FOLDER_ISO_CUSTOM}/late_command.sh"
  
  echo "Running mkisofs ..."
  "$MKISOFS" -r -V "Custom Ubuntu Install CD" \
    -cache-inodes -quiet \
    -J -l -b isolinux/isolinux.bin \
    -c isolinux/boot.cat -no-emul-boot \
    -boot-load-size 4 -boot-info-table \
    -o "${FOLDER_ISO}/custom.iso" "${FOLDER_ISO_CUSTOM}"
fi

echo "Creating VM Box..."
# create virtual machine
if ! VBoxManage showvminfo "${BOX}" >/dev/null 2>/dev/null; then
  VBoxManage createvm \
    --name "${BOX}" \
    --ostype Ubuntu_64 \
    --register \
    --basefolder "${FOLDER_VBOX}"

  VBoxManage modifyvm "${BOX}" \
    --memory 360 \
    --boot1 dvd \
    --boot2 disk \
    --boot3 none \
    --boot4 none \
    --vram 12 \
    --pae off \
    --rtcuseutc on

  VBoxManage storagectl "${BOX}" \
    --name "IDE Controller" \
    --add ide \
    --controller PIIX4 \
    --hostiocache on

  VBoxManage storageattach "${BOX}" \
    --storagectl "IDE Controller" \
    --port 1 \
    --device 0 \
    --type dvddrive \
    --medium "${FOLDER_ISO}/custom.iso"

  VBoxManage storagectl "${BOX}" \
    --name "SATA Controller" \
    --add sata \
    --controller IntelAhci \
    $PORTCOUNT \
    --hostiocache off

  VBoxManage createhd \
    --filename "${FOLDER_VBOX}/${BOX}/${BOX}.vdi" \
    --size 40960

  VBoxManage storageattach "${BOX}" \
    --storagectl "SATA Controller" \
    --port 0 \
    --device 0 \
    --type hdd \
    --medium "${FOLDER_VBOX}/${BOX}/${BOX}.vdi"

  ${STARTVM}

  echo -n "Waiting for installer to finish "
  while VBoxManage list runningvms | grep "${BOX}" >/dev/null; do
    sleep 20
    echo -n "."
  done
  echo ""

  VBoxManage storageattach "${BOX}" \
    --storagectl "IDE Controller" \
    --port 1 \
    --device 0 \
    --type dvddrive \
    --medium emptydrive
fi

echo "Building Vagrant Box ..."
vagrant package --base "${BOX}" --output "${BOX}.box"

if VBoxManage showvminfo "${BOX}" >/dev/null 2>/dev/null; then
  echo "Unregistering vm ..."
  VBoxManage unregistervm "${BOX}" --delete
fi

# references:
# http://blog.ericwhite.ca/articles/2009/11/unattended-debian-lenny-install/
# http://cdimage.ubuntu.com/releases/precise/beta-2/
# http://www.imdb.com/name/nm1483369/
# http://vagrantup.com/docs/base_boxes.html
