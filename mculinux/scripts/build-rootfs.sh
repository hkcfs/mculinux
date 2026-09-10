#!/bin/bash
# Assemble EROFS rootfs from skeleton + busybox + static init. No Buildroot.
# Single source of /etc: mculinux/rootfs/etc/ (also feeds etc.jffs2).
# Usage: [BUSYBOX_BIN=...] [ROOTFS_STAGING=...] ./scripts/build-rootfs.sh [output.erofs]
set -e

MCULINUX_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STAGING="${ROOTFS_STAGING:-/tmp/rootfs-staging}"
OUTPUT="${1:-$MCULINUX_DIR/tools/prebuilt/binaries/rootfs.erofs}"
BUSYBOX_BIN="${BUSYBOX_BIN:-/tmp/busybox-$("$MCULINUX_DIR/scripts/latest-busybox.sh")/busybox}"
INIT_SRC="${INIT_SRC:-$MCULINUX_DIR/patches/busybox-nommu/init_final.c}"
CROSS="${XTENSA_CROSS:-$MCULINUX_DIR/build/crosstool-NG/builds/xtensa-esp32s3-linux-muslfdpic/bin/xtensa-esp32s3-linux-muslfdpic-}"

[ -x "$BUSYBOX_BIN" ] || { echo "FAIL: busybox binary not found: $BUSYBOX_BIN (run make busybox first)"; exit 1; }
command -v "${CROSS}gcc" >/dev/null 2>&1 || { echo "FAIL: cross gcc not found: ${CROSS}gcc"; exit 1; }
command -v mkfs.erofs >/dev/null 2>&1 || { echo "FAIL: mkfs.erofs missing (apt install erofs-utils)"; exit 1; }

# fakeroot gives a deterministic root-owned image; without it, devtmpfs
# still provides /dev/console+null at boot, so nodes are best-effort.
FAKEROOT=""
if command -v fakeroot >/dev/null 2>&1; then
    FAKEROOT="fakeroot"
else
    echo "WARN: fakeroot missing, skipping static /dev nodes (devtmpfs covers boot)"
fi

# Applet symlinks, mirrored from the previously working Buildroot target.
# (The cross binary cannot run on the build host, so no --list probing.)
BIN_APPLETS="arch base32 base64 cat chattr chgrp chmod chown cp cpio date dd df
    dmesg dnsdomainname dumpkmap echo egrep false fdflush fgrep getopt grep gunzip
    gzip hostname hush kill link linux32 linux64 ln login ls lsattr mkdir mknod
    mktemp more mount mountpoint mt mv netstat nice nuke pidof ping ping6 pipe_progress
    printenv ps pwd resume rm rmdir run-parts sed setarch setpriv setserial sh
    sleep stty su sync tar touch true umount uname usleep vi watch zcat"
SBIN_APPLETS="arp blkid devmem fdisk freeramdisk fsck fstrim getty halt hdparm
    hwclock ifconfig ifdown ifup insmod ip ipaddr iplink ipneigh iproute iprule
    iptunnel klogd loadkmap losetup lsmod makedevs mdev mkdosfs mke2fs mkswap
    modprobe mount nameif pivot_root poweroff reboot rmmod route run-init runlevel
    setconsole start-stop-daemon sulogin swapoff swapon switch_root sysctl syslogd
    tc udhcpc udhcpc6 uevent vconfig watchdog"

echo "=== Assembling rootfs (busybox: $BUSYBOX_BIN) ==="
rm -rf "$STAGING"
# NOTE: every mountpoint init mounts (/proc /sys /etc /data ...) MUST exist
# here: init's mkdir() calls fail silently on the read-only EROFS.
mkdir -p "$STAGING"/{bin,data,dev,etc,lib,lib32,media,mnt,opt,proc,root,run,sbin,sys,tmp,usr/bin,usr/sbin,var}
cp -r "$MCULINUX_DIR/rootfs/etc/." "$STAGING/etc/"
chmod 755 "$STAGING" "$STAGING"/bin "$STAGING"/sbin
ln -s bin/busybox "$STAGING/linuxrc"

install -m755 "$BUSYBOX_BIN" "$STAGING/bin/busybox"
for applet in $BIN_APPLETS; do
    [ "$applet" = busybox ] || ln -sf busybox "$STAGING/bin/$applet"
done
for applet in $SBIN_APPLETS; do
    ln -sf busybox "$STAGING/sbin/$applet"
done
ln -sf busybox "$STAGING/bin/sh"
ln -sf busybox "$STAGING/bin/hush"

echo "Compiling static init..."
"${CROSS}gcc" -Os -static -o "$STAGING/sbin/init" "$INIT_SRC"
chmod +x "$STAGING/sbin/init"

# Tiny static utilities (rootfs/utils/*.c -> /sbin). Fail loud on errors.
if ls "$MCULINUX_DIR/rootfs/utils/"*.c >/dev/null 2>&1; then
    echo "Compiling utils..."
    for util in "$MCULINUX_DIR/rootfs/utils/"*.c; do
        name="$(basename "$util" .c)"
        "${CROSS}gcc" -Os -static -o "$STAGING/sbin/$name" "$util" \
            || { echo "FAIL: util $name did not compile"; exit 1; }
        chmod +x "$STAGING/sbin/$name"
        echo "  $name: $(ls -lh "$STAGING/sbin/$name" | awk '{print $5}')"
    done
fi

if [ -n "$FAKEROOT" ]; then
    $FAKEROOT mknod -m 600 "$STAGING/dev/console" c 5 1
    $FAKEROOT mknod -m 666 "$STAGING/dev/null" c 1 3
fi

echo "Creating EROFS image..."
$FAKEROOT mkfs.erofs -z lzma,level=9 "$OUTPUT" "$STAGING"
echo "Rootfs: $OUTPUT ($(ls -lh "$OUTPUT" | awk '{print $5}'))"
