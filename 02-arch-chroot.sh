#!/usr/bin/bash

usage() {
    echo "Usage: 02-arch-chroot.sh -h <hostname> -r </path/to/root/device> [-p]"
    echo "Root device example: /dev/vg_ssd/root"
}

dry_run=0
hostname=""
root_dev=""

source ./00-helpers.sh

while getopts "h:r:p" opt; do
    case "${opt}" in
        h)
            hostname="$OPTARG"
            ;;
        r)
            root_dev="$OPTARG"
            ;;
        p)
            dry_run=1
            ;;
        ?)
            echo "Invalid option: -${OPTARG}"
            exit 1
            ;;
    esac
done

if [[ -z "$hostname" ]]; then
    echo "Please specify a hostname."
    echo $(usage)
    exit 1
fi

if [[ -z "$root_dev" ]]; then
    echo "Please specify the path to the root device."
    echo $(usage)
    exit 1
fi

log "Configuring system..."

drynt ln -sf /usr/share/zoneinfo/Europe/Madrid /etc/localtime # Set timezone
drynt hwclock --systohc # Create /etc/adjtime
drynt systemctl enable systemd-timesyncd # Enable time sync service

drynt sed -i 's/^#\(en_US.UTF-8\)/\1/g' /etc/locale.gen
drynt sed -i 's/^#\(es_ES.UTF-8\)/\1/g' /etc/locale.gen
drynt locale-gen # Generate locales
drynt "echo \"LANG=en_US.UTF-8\" > /etc/locale.conf" # Set system locale
drynt "echo \"KEYMAP=es\" > /etc/vconsole.conf" # Set TTY keyboard layout

drynt "echo $hostname > /etc/hostname" # Set hostname
drynt "echo \"127.0.1.1        $hostname\" >> /etc/hosts" # Resolve own hostname locally
drynt systemctl enable systemd-resolved # Enable DNS resolver
drynt systemctl enable NetworkManager

drynt sed -i '55 s/block filesystems/block lvm2 filesystems/' /etc/mkinitcpio.conf
drynt mkinitcpio -P # Rebuild initramfs

log "Setting root user password..."
drynt passwd # Set root password

drynt bootctl install # Looks for ESP at /efi and XBOOTLDR at /boot
drynt "cat > /boot/loader/entries/arch.conf <<EOF
title Arch Linux
linux /vmlinuz-linux
initrd /initramfs-linux.img
options root=$root_dev rw
EOF"

log "Exiting chroot..."

dryntrm 00-helpers.sh
self_clean
