#!/bin/bash

set -xe

# Whether the system is still recoverable. We set this to zero at the "point of
# no return".
RECOVERABLE=1

try_to_recover() {
    if [ $RECOVERABLE = 1 ]; then
        umount $MOUNTED_DEVICE || true
        sync
        echo "Rebooting in 10 seconds..."
        sleep 10
        echo b > /proc/sysrq-trigger
    else
        echo "Beyond the point of no return. This device is probably bricked..."
        exit 1
    fi
}
trap try_to_recover EXIT

gather_old_partition_info() {
    MOUNTED_DEVICE=$(mount | grep ' /old_root ' | awk '{print $1}')

    if echo "$MOUNTED_DEVICE" | egrep -q 'p[0-9]+$'; then
        STORAGE_DEVICE_HAS_P=p
    else
        STORAGE_DEVICE_HAS_P=
    fi

    STORAGE_DEVICE=$(echo $MOUNTED_DEVICE | sed -Ee 's/p?[0-9]+$//')

    TOTAL_SIZE=$(blockdev --getsize64 $STORAGE_DEVICE)
    # Subtract one MiB as "partition overhead".
    TOTAL_SIZE=$(($TOTAL_SIZE - 1048576))

    NEW_ROOTFS_SIZE=$(($TOTAL_SIZE / 4))
    NEW_ROOTFS_SIZE_MB=$(($NEW_ROOTFS_SIZE / 1048576))

    OLD_FIRST_PART_START=$(fdisk -u=sectors -odevice,start,end -l $STORAGE_DEVICE | grep -A1 "^Device" | tail -n 1 | awk '{print $2}')
    OLD_PART_START=$(fdisk -u=sectors -odevice,start,end -l $STORAGE_DEVICE | grep "^$MOUNTED_DEVICE" | awk '{print $2}')
    OLD_PART_END=$(fdisk -u=sectors -odevice,start,end -l $STORAGE_DEVICE | grep "^$MOUNTED_DEVICE" | awk '{print $3}')
    # The 511 is so that any excess sectors will be rounded up. 2048 is the
    # number of sectors in one MiB.
    OLD_ROOTFS_SIZE_MB=$((($OLD_PART_END - $OLD_PART_START + 1 + 511) / 2048))
}

kill_everything() {
    cd /proc

    # When you kill a login shell, Linux seems to kill every process that's
    # connected to the same tty. So we need to disconnect from it while we kill
    # stuff, and then reconnect afterwards.
    OLD_STDIN=$(/busybox readlink /proc/$$/fd/0)
    OLD_STDOUT=$(/busybox readlink /proc/$$/fd/1)
    OLD_STDERR=$(/busybox readlink /proc/$$/fd/2)
    exec </dev/null >/dev/null 2>/dev/null

    for pid in `ls -d [0-9]*`; do
        if [ $pid -eq 1 -o $pid -eq $$ ]; then
            continue
        fi

        # Ignore errors, some processes may vanish before we can kill them
        kill -9 $pid || true
    done

    sleep 1
    exec <$OLD_STDIN >$OLD_STDOUT 2>$OLD_STDERR

    cd /
}

unmount_everything() {
    cat /proc/mounts | cut -d' ' -f 2 | grep ^/old_root | sort -r | xargs -n1 umount
}

resize_old_rootfs_partition() {
    local ret=0
    e2fsck -af $MOUNTED_DEVICE || ret=$?
    if [ $ret -ne 0 -a $ret -ne 1 -a $ret -ne 2 ]; then
        return $ret
    fi
    resize2fs $MOUNTED_DEVICE ${NEW_ROOTFS_SIZE_MB}M
}

recreate_rootfs_partitions() {
    (
        echo p                          # Print original partition table for debugging.

        echo g                          # Create new GPT

        echo n                          # New partition: EFI
        echo 1                          # Partition number
        echo $OLD_FIRST_PART_START      # Use first used sector from old partition table to avoid
                                        # overwriting bootloaders and such.
        echo +16M                       # 16MiB partition
        echo t                          # Change type
        echo 1                          # Type: EFI

        echo n                          # New partition: RootfsA
        echo 2                          # Partition number
        echo                            # Accept first sector default
        echo +${NEW_ROOTFS_SIZE_MB}M    # Partition size
        echo t                          # Change type
        echo 2                          # Partition number
        echo 20                         # Type: Linux filesystem

        echo n                          # New partition: RootfsB
        echo 3                          # Partition number
        echo                            # Accept first sector default
        echo +${NEW_ROOTFS_SIZE_MB}M    # Partition size
        echo t                          # Change type
        echo 3                          # Partition number
        echo 20                         # Type: Linux filesystem

        echo n                          # New partition: Data
        echo 4                          # Partition number
        echo                            # Accept first sector default
        echo                            # Partition size: Use remaining
        echo t                          # Change type
        echo 4                          # Partition number
        echo 20                         # Type: Linux filesystem

        echo p
        echo w
    ) | fdisk $STORAGE_DEVICE

    MOUNTED_DEVICE=${STORAGE_DEVICE}${STORAGE_DEVICE_HAS_P}2
    NEW_PART_START=$(fdisk -u=sectors -odevice,start,end -l $STORAGE_DEVICE | grep "^$MOUNTED_DEVICE" | awk '{print $2}')
    NEW_PART_END=$(fdisk -u=sectors -odevice,start,end -l $STORAGE_DEVICE | grep "^$MOUNTED_DEVICE" | awk '{print $3}')
}

move_old_rootfs_partition() {
    local sector_count=$(($NEW_PART_END - $NEW_PART_START + 1))

    if [ $NEW_PART_START -eq $OLD_PART_START ]; then
        return
    elif [ $NEW_PART_START -lt $OLD_PART_START ]; then
        # Simple case: Backwards move

        # Progress output
        while sleep 10; do pkill -USR1 '^dd$'; done &
        local progress_pid=$!

        dd if=$STORAGE_DEVICE of=$STORAGE_DEVICE skip=$OLD_PART_START seek=$NEW_PART_START count=$sector_count

        kill $progress_pid
    else
        # Complex case: Forwards move. Here we need to write in chunks from the
        # back to the front, to avoid writes interfering with later reads.
        local sector_diff=$(($NEW_PART_START - $OLD_PART_START))
        local old_sector=$(($OLD_PART_START + $sector_count - $sector_diff))
        local new_sector=$(($NEW_PART_END + 1 - $sector_diff))
        while [ $new_sector -ge $NEW_PART_START ]; do
            echo "Working back-to-front on sector $new_sector (final sector: $NEW_PART_START)"
            dd if=$STORAGE_DEVICE of=$STORAGE_DEVICE skip=$old_sector seek=$new_sector count=$sector_diff
            local old_new_sector=$new_sector
            new_sector=$(($new_sector - $sector_diff))
            if [ $new_sector -lt $NEW_PART_START ]; then
                new_sector=$NEW_PART_START
                if [ $new_sector -eq $old_new_sector ]; then
                    break
                fi
                sector_diff=$(($old_new_sector - $new_sector))
            fi
            old_sector=$(($old_sector - $sector_diff))
        done
    fi
}

setup_efi_partition() {
    local efi_part=${STORAGE_DEVICE}${STORAGE_DEVICE_HAS_P}1

    gunzip -c /boot-part.vfat.gz | dd of=$efi_part
}

mount_rootfs_and_data_partition() {
    local data_part=${STORAGE_DEVICE}${STORAGE_DEVICE_HAS_P}4
    mkfs.ext4 -F $data_part

    mkdir -p /new_data
    mount $data_part /new_data -t ext4

    mkdir -p /new_root
    mount $MOUNTED_DEVICE /new_root -t ext4
}

setup_rootfs_and_data_partition() {
    mkdir -p /new_root/data

    if [ -d /new_root/var/lib/mender ]; then
        mv /new_root/var/lib/mender /new_data
    fi
    ln -sf /data/mender /new_root/var/lib/mender
}

setup_kernel() {
    cd /new_root/boot

    # This logic is not very robust, but works for many common/simple cases:
    # Pick the vmlinuz kernel with the highest kernel number.
    local kernel="$(ls vmlinuz* | sort -V | tail -n1)"
    ln -s "$kernel" zImage

    cd /
}

adjust_fstab() {
    local data_part=${STORAGE_DEVICE}${STORAGE_DEVICE_HAS_P}4
    echo "$data_part /data ext4 errors=remount-ro 0 2" >> /new_root/etc/fstab
}

unmount_rootfs_and_data_partition() {
    umount /new_root
    umount /new_data
}

gather_old_partition_info
# Do this twice, since some processes can sometimes escape due to race
# conditions.
kill_everything
kill_everything
touch /old_root/var/lib/mender/dual-rootfs-repartition-too-late-to-roll-back
unmount_everything

# After this there is no going back.
RECOVERABLE=0

if [ $OLD_ROOTFS_SIZE_MB -ge $NEW_ROOTFS_SIZE_MB ]; then
    # If the old rootfs partition is bigger than the new one, then we need to
    # resize before creating new partitions.
    resize_old_rootfs_partition
fi

recreate_rootfs_partitions
move_old_rootfs_partition

if [ $OLD_ROOTFS_SIZE_MB -lt $NEW_ROOTFS_SIZE_MB ]; then
    # If the old rootfs partition is smaller than the new one, then we need to
    # resize after creating new partitions.
    resize_old_rootfs_partition
fi

setup_efi_partition

# The dangerous part is over!
RECOVERABLE=1

mount_rootfs_and_data_partition
setup_rootfs_and_data_partition
setup_kernel
adjust_fstab
touch /new_data/mender/dual-rootfs-repartition-finished
unmount_rootfs_and_data_partition

# Finished! The trap will reboot for us.
