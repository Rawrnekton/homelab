#!/usr/bin/env bash
# Writes the Ubuntu cloud image and the cloud-init seed of a host to a disk.
# The disk must be in a USB case. After this script, put the disk into the host
# and start it. See docs/thinkcentre-ubuntu.md.
#
# Layout after the script:
#   p13 /boot, p14 BIOS boot, p15 ESP  (from the image)
#   p1  /, ROOT_SIZE_GIB               (from the image, made larger)
#   p2  GPT name "data", rest of disk  (empty, for the lvm role)
#
# Usage: scripts/prepare-disk.sh <device> <host>
#   ROOT_SIZE_GIB  size of the root partition in GiB (default 50)
#   IMAGE_BASE     download directory of the image

set -euo pipefail

DEVICE=${1:?Usage: prepare-disk.sh <device> <host>}
HOST=${2:?Usage: prepare-disk.sh <device> <host>}
ROOT_SIZE_GIB=${ROOT_SIZE_GIB:-50}
IMAGE_BASE=${IMAGE_BASE:-https://cloud-images.ubuntu.com/releases/26.04/release}
IMAGE=ubuntu-26.04-server-cloudimg-amd64.img

REPO=$(realpath "$(dirname "$0")/..")
SEED_SHARED=$REPO/cloud-init/thinkcentre
SEED_HOST=$REPO/cloud-init/$HOST
CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/homelab/cloud-images
MNT=

die() {
  echo "ERROR: $*" >&2
  exit 1
}

cleanup() {
  if [[ -n $MNT ]]; then
    mountpoint -q "$MNT" && sudo umount "$MNT"
    rmdir "$MNT"
  fi
}
trap cleanup EXIT

# The kernel calls a partition of nvme0n1 "nvme0n1p1", but of sda "sda1".
partition() {
  if [[ $DEVICE =~ [0-9]$ ]]; then
    echo "${DEVICE}p$1"
  else
    echo "${DEVICE}$1"
  fi
}

reread_partitions() {
  sudo partprobe "$DEVICE"
  sudo udevadm settle
}

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

for cmd in curl sha256sum qemu-img sgdisk partprobe wipefs e2fsck resize2fs; do
  command -v "$cmd" >/dev/null || die "$cmd is missing. qemu-img is in the package qemu-utils."
done

[[ -f $SEED_HOST/meta-data ]] || die "$SEED_HOST/meta-data does not exist."
[[ -b $DEVICE ]] || die "$DEVICE is not a block device."
[[ $(lsblk -dno TYPE "$DEVICE") == disk ]] || die "$DEVICE is not a full disk. Give the disk, not a partition."
# Only a disk in a USB case is permitted. This prevents a write to the disk of
# the workstation.
[[ $(lsblk -dno TRAN "$DEVICE") == usb ]] || die "$DEVICE is not a USB disk."
[[ -z $(lsblk -nro MOUNTPOINTS "$DEVICE" | tr -d '[:space:]') ]] ||
  die "$DEVICE has mounted partitions. Unmount them, for example with: udisksctl unmount -b $(partition 1)"
# The workstation can activate an old volume group of the disk, for example
# ubuntu-vg of an old install. Then the kernel keeps the old device mapper
# devices. The workstation also has a ubuntu-vg, thus the hint uses the UUID.
if lsblk -nro TYPE "$DEVICE" | grep -qx lvm; then
  die "$DEVICE has active logical volumes. Find the VG UUID with 'sudo pvs -o pv_name,vg_name,vg_uuid', then: sudo vgchange -an --select vg_uuid=<uuid>"
fi
# The GPT of the image is for 512-byte sectors. Some USB cases show 4096-byte
# sectors, and then the partition table is not correct.
[[ $(lsblk -dno LOG-SEC "$DEVICE") -eq 512 ]] ||
  die "$DEVICE has a logical sector size of $(lsblk -dno LOG-SEC "$DEVICE"), not 512. Use a different USB case."

lsblk -o NAME,SIZE,MODEL,SERIAL,TRAN,FSTYPE,LABEL "$DEVICE"
echo
echo "This deletes ALL data on $DEVICE and prepares it for $HOST."
read -r -p "Type the device name ($DEVICE) to continue: " answer
[[ $answer == "$DEVICE" ]] || die "Stopped. Nothing was changed."

# ---------------------------------------------------------------------------
# Image
# ---------------------------------------------------------------------------

# "release" always points to the newest build. Thus the script downloads the
# checksums each time. A cached image with a wrong checksum is an old build.
image_ok() {
  grep " \*$IMAGE\$" SHA256SUMS | sha256sum -c --status - 2>/dev/null
}
mkdir -p "$CACHE"
cd "$CACHE"
curl -fsSL -o SHA256SUMS "$IMAGE_BASE/SHA256SUMS"
if ! image_ok; then
  curl -fL -o "$IMAGE" "$IMAGE_BASE/$IMAGE"
  image_ok || die "The checksum of $IMAGE is not correct."
fi

# ---------------------------------------------------------------------------
# Disk
# ---------------------------------------------------------------------------

# wipefs removes both GPT headers. The backup header of an old partition table
# is at the end of the disk, where the image does not write.
sudo wipefs -a "$DEVICE"
sudo qemu-img convert -p -f qcow2 -O raw "$IMAGE" "$DEVICE"
# The image has its backup GPT header at 3.5 GiB. -e moves it to the end of the
# disk.
sudo sgdisk -e "$DEVICE"
reread_partitions

# p1 is the last partition of the image. The script makes it new with the same
# start, type, name and GUID, but with a different end. The data stays.
root_start=$(sudo sgdisk -i 1 "$DEVICE" | awk '/^First sector:/ {print $3}')
root_guid=$(sudo sgdisk -i 1 "$DEVICE" | awk '/^Partition unique GUID:/ {print $4}')
root_end=$((root_start + ROOT_SIZE_GIB * 1024 * 1024 * 2 - 1))
sudo sgdisk \
  -d 1 \
  -n "1:$root_start:$root_end" -t 1:8304 -c 1:cloudimg-rootfs -u "1:$root_guid" \
  -n 2:0:0 -t 2:8e00 -c 2:data \
  "$DEVICE"
reread_partitions

# The new p2 can contain an old signature, for example of an old physical
# volume. pvcreate in the lvm role stops on a signature.
sudo wipefs -a "$(partition 2)"

# e2fsck exits with 1 when it corrected an error. Only a value of 2 or more is
# a failure.
sudo e2fsck -f -p "$(partition 1)" || [[ $? -le 1 ]] || die "e2fsck failed."
sudo resize2fs "$(partition 1)"

# ---------------------------------------------------------------------------
# cloud-init seed
# ---------------------------------------------------------------------------

MNT=$(mktemp -d)
sudo mount "$(partition 1)" "$MNT"
sudo install -D -m 0600 -t "$MNT/var/lib/cloud/seed/nocloud" \
  "$SEED_SHARED/user-data" \
  "$SEED_SHARED/network-config" \
  "$SEED_HOST/meta-data"
sudo ls -l "$MNT/var/lib/cloud/seed/nocloud"
sudo umount "$MNT"
sync

echo
sudo sgdisk -p "$DEVICE"
echo
echo "$DEVICE is ready for $HOST. Disconnect it with: udisksctl power-off -b $DEVICE"
