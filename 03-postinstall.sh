#!/usr/bin/bash

dry_run=0
username=""

source ./00-helpers.sh

while getopts "u:p" opt; do
    case "${opt}" in
        u)
            username="$OPTARG"
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

if [[ -z "$username" ]]; then
    echo "Please specify a username"
    echo "Usage: 03-postinstall.sh -u <username> [-p]"
    exit 1
fi

log "Setting up user $username with sudo permissions..."
drynt "sed -i 's/^# \(%wheel ALL=(ALL:ALL) ALL\)/\1/g' /etc/sudoers"
drynt useradd -m -G wheel "$username" # Create unprivileged user
until drynt passwd "$username"; do
    info "Password change failed, please try again..."
done


# Install paru
log "Installing paru..."

drynt sudo -u "$username" git clone https://aur.archlinux.org/paru.git /home/"$username"/paru
drynt cd /home/"$username"/paru
drynt sudo -u "$username" makepkg -si
drynt cd ..
drynt rm -rf paru
drynt rm -rf .cargo
drynt sudo -u "$username" paru --gendb

# Cleanup
log "Cleaning up and exiting. You can now log in as user $username"

drynt cd
drynt rm 00-helpers.sh
self_clean