#!/usr/bin/bash
 
# params: esp, boot, root, home and swap size
dry_run=0
esp_size="512M"
boot_size="512M"
root_size="100G"
home_size=""   # if empty, no separate home LV; root takes all remaining space
swap_size="8G"
hostname=""
SIZE_REGEX="[1-9][0-9]*[MG]"
 
# Steps: all enabled by default
do_partition=1
do_lvm=1
do_fs=1
do_mount=1
do_install=1
 
VALID_STEPS="partition lvm fs mount install"
 
# -- Helpers --
 
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]
 
Arch Linux installation script. Runs all steps by default.
 
Partition size options:
  -e <size>   EFI System Partition size        (default: ${esp_size})
  -b <size>   Boot partition (XBOOTLDR) size   (default: ${boot_size})
  -r <size>   Root LV size                     (default: ${root_size})
  -m <size>   Home LV size (optional). If omitted, no separate home LV is
              created; root takes all remaining space minus 256M.
  -w <size>   Swap LV size                     (default: ${swap_size})
 
  Sizes must be in the format <number><unit>, e.g. 512M or 100G.
 
Step selection:
  -s <steps>  Comma-separated list of steps to run (default: all).
              Valid steps: $VALID_STEPS
              Example: -s partition,lvm
 
Other:
  -n <name>   Hostname (required for the install step)
  -p          Dry run: print commands instead of executing them
  -h          Show this help message and exit
 
Examples:
  $(basename "$0")                        Run all steps
  $(basename "$0") -s partition           Only partition disks
  $(basename "$0") -s lvm,fs             Set up LVM and create filesystems
  $(basename "$0") -s mount,install      Mount and install base system
  $(basename "$0") -r 50G -w 4G -p       Dry run with custom root/swap sizes
EOF
}
 
check_size() {
    if [[ ! "$1" =~ $SIZE_REGEX ]]; then # Regex variable must be unquoted or it won't work https://stackoverflow.com/questions/218156/bash-regex-with-quotes/218217#218217
        echo "Invalid size: $1. Size must be <number><unit> (valid units: G, M)."
        exit 1
    fi
}
 
parse_steps() {
    # Disable all steps first
    do_partition=0
    do_lvm=0
    do_fs=0
    do_mount=0
    do_install=0
 
    IFS=',' read -ra steps <<< "$1"
    for step in "${steps[@]}"; do
        case "$step" in
            partition) do_partition=1 ;;
            lvm)       do_lvm=1 ;;
            fs)        do_fs=1 ;;
            mount)     do_mount=1 ;;
            install)   do_install=1 ;;
            *)
                echo "Invalid step: '$step'. Valid steps: $VALID_STEPS"
                exit 1
                ;;
        esac
    done
}
 
# -- Argument parsing --
 
while getopts "e:b:r:m:w:s:n:ph" opt; do
    case "${opt}" in
        e)
            check_size $OPTARG
            esp_size="$OPTARG"
            ;;
        b)
            check_size $OPTARG
            boot_size="$OPTARG"
            ;;
        r)
            check_size $OPTARG
            root_size="$OPTARG"
            ;;
        m)
            check_size $OPTARG
            home_size="$OPTARG"
            ;;
        w)
            check_size $OPTARG
            swap_size="$OPTARG"
            ;;
        s)
            parse_steps "$OPTARG"
            ;;
        n)
            hostname="$OPTARG"
            ;;
        p)
            dry_run=1
            ;;
        h)
            usage
            exit 0
            ;;
        ?)
            echo "Invalid option: -${OPTARG}"
            echo "Run '$(basename "$0") -h' for usage."
            exit 1
            ;;
    esac
done
 
# -- Get source files --
 
if [[ ! -f 00-helpers.sh ]]; then
    curl -o 00-helpers.sh https://raw.githubusercontent.com/shynfia/my-arch-install/refs/heads/main/00-helpers.sh
    chmod +x 00-helpers.sh
fi
if [[ dry_run -eq 0 ]]; then
    if [[ ! -f 02-arch-chroot.sh ]]; then
        curl -o 02-arch-chroot.sh https://raw.githubusercontent.com/shynfia/my-arch-install/refs/heads/main/02-arch-chroot.sh
        chmod +x 02-arch-chroot.sh
    fi
    if [[ ! -f 03-postinstall.sh ]]; then
        curl -o 03-postinstall.sh https://raw.githubusercontent.com/shynfia/my-arch-install/refs/heads/main/03-postinstall.sh
        chmod +x 03-postinstall.sh
    fi
fi
 
source ./00-helpers.sh
 
# -- Partition disks --
 
ssd_disks=()
hdd_disks=()
system_disk=""
 
find_disks() {
    while read -r name type rota rm; do
        # Ignore USBs and other removable disks
        if [[ "$type" == "disk" && "$rm" == "0" ]]; then
            if [[ "$rota" == "0" ]]; then
                ssd_disks+=("/dev/$name")
            else
                hdd_disks+=("/dev/$name")
            fi
        fi
    done < <(lsblk -ld -n --output NAME,TYPE,ROTA,RM)
}
 
partition_disks() {
    local disks=("$@")
    local disk
    for disk in "${disks[@]}"; do
        drynt wipefs -af "$disk"*
        if [[ -z "$system_disk" ]]; then
            # ESP
            drynt sgdisk -n 1:0:+"$esp_size" -t 1:ef00 $disk
            # XBOOTLDR
            drynt sgdisk -n 2:0:+"$boot_size" -t 2:ea00 $disk
            system_disk="$disk"
        fi
        # LVM
        drynt sgdisk -n 0:0:0 -t 0:8e00 $disk
    done
}
 
if [[ "$do_partition" -eq 1 ]]; then
    log "Partitioning disks...."
    find_disks
    info "SSDs found: ${ssd_disks[*]:-none}"
    info "HDDs found: ${hdd_disks[*]:-none}"
    partition_disks "${ssd_disks[@]}"
    partition_disks "${hdd_disks[@]}"
    drynt partprobe
fi
 
# -- LVM setup --
 
VG_SSD="vg_ssd"
VG_HDD="vg_hdd"
LV_ROOT="root"
LV_HOME="home"
LV_SWAP="swap"
LV_DATA="data"
 
setup_lvm_vg() {
    local vg_name="$1"
    shift
    local disks=("$@")
    
    if [[ "${#disks[@]}" -ne 0 ]]; then
        local lvm_partitions=()
 
        local disk
        for disk in "${disks[@]}"; do
            if [[ "$disk" == "$system_disk" ]]; then
                lvm_partitions+=("${disk}3")
            else
                lvm_partitions+=("${disk}1")
            fi
        done
 
        drynt vgcreate "$vg_name" "${lvm_partitions[@]}"
    fi
}
 
# Ensures ssd_disks, hdd_disks, system_disk, system_vg and data_vg_exists are
# set. If an earlier step was skipped the arrays may be empty, so we call
# find_disks to populate them and derive the rest from the disk topology.
resolve_disk_state() {
    if [[ "${#ssd_disks[@]}" -eq 0 && "${#hdd_disks[@]}" -eq 0 ]]; then
        find_disks
    fi
 
    if [[ -z "$system_disk" ]]; then
        if [[ "${#ssd_disks[@]}" -ne 0 ]]; then
            system_disk="${ssd_disks[0]}"
        else
            system_disk="${hdd_disks[0]}"
        fi
    fi
 
    system_vg=$([[ "${#ssd_disks[@]}" -ne 0 ]] && echo "$VG_SSD" || echo "$VG_HDD")
    data_vg_exists=$([[ "$system_vg" == "$VG_SSD" && "${#hdd_disks[@]}" -ne 0 ]] && echo true || echo false)
 
    # Detect whether a separate home LV exists on the live system
    # Falls back to the in-memory home_size flag when LVM hasn't run yet.
    if [[ -e "/dev/$system_vg/$LV_HOME" ]]; then
        single_root=0
    elif [[ -n "$home_size" ]]; then
        single_root=0
    else
        single_root=1
    fi
}
 
if [[ "$do_lvm" -eq 1 && "$do_partition" -eq 0 ]]; then
    resolve_disk_state
fi
 
if [[ "$do_lvm" -eq 1 ]]; then
    log "Setting up LVM..."

    setup_lvm_vg "$VG_SSD" "${ssd_disks[@]}"
    setup_lvm_vg "$VG_HDD" "${hdd_disks[@]}"
 
    system_vg=$([[ "${#ssd_disks[@]}" -ne 0 ]] && echo "$VG_SSD" || echo "$VG_HDD")
 
    single_root=$([[ -z "$home_size" ]] && echo 1 || echo 0)
 
    info "Creating LV $LV_SWAP ($swap_size) in $system_vg"
    drynt lvcreate -y -L "$swap_size" "$system_vg" -n "$LV_SWAP"
    
    if [[ "$single_root" -eq 1 ]]; then
        info "Creating LV $LV_ROOT (100%FREE - 256M) in $system_vg"
        drynt lvcreate -y -l 100%FREE "$system_vg" -n "$LV_ROOT"
        drynt lvreduce -L -256M "$system_vg/$LV_ROOT"
    else
        info "Creating LV $LV_ROOT ($root_size) in $system_vg"
        drynt lvcreate -y -L "$root_size" "$system_vg" -n "$LV_ROOT"
        info "Creating LV $LV_HOME ($home_size) in $system_vg"
        drynt lvcreate -y -L "$home_size" "$system_vg" -n "$LV_HOME"
    fi
 
    data_vg_exists=$([[ "$system_vg" == "$VG_SSD" && "${#hdd_disks[@]}" -ne 0 ]] && echo true || false)
 
    if [[ "$data_vg_exists" ]]; then
        info "Creating LV $LV_DATA (100%FREE - 256M) in $VG_HDD"
        drynt lvcreate -y -l 100%FREE "$VG_HDD" -n "$LV_DATA"
        drynt lvreduce -L -256M "$VG_HDD/$LV_DATA"
    fi
fi
 
# -- Filesystems --
 
if [[ "$do_fs" -eq 1 && "$do_lvm" -eq 0 ]]; then
    resolve_disk_state
fi
 
if [[ "$do_fs" -eq 1 ]]; then
    DEV_ESP="${system_disk}1"
    DEV_BOOT="${system_disk}2"
    DEV_ROOT="/dev/$system_vg/$LV_ROOT"
    DEV_HOME="/dev/$system_vg/$LV_HOME"
    DEV_SWAP="/dev/$system_vg/$LV_SWAP"
    DEV_DATA="/dev/$VG_HDD/$LV_DATA"
 
    log "Creating file systems...."
 
    info "$DEV_ESP -> FAT32"
    drynt mkfs.fat -F 32 "$DEV_ESP"
    info "$DEV_BOOT -> ext4"
    drynt mkfs.ext4 "$DEV_BOOT"
    info "$DEV_ROOT -> ext4"
    drynt mkfs.ext4 "$DEV_ROOT"
    if [[ "$single_root" -eq 0 ]]; then
        info "$DEV_HOME -> ext4"
        drynt mkfs.ext4 "$DEV_HOME"
    fi
    if [[ "$data_vg_exists" ]]; then
        info "$DEV_DATA -> ext4"
        drynt mkfs.ext4 "$DEV_DATA"
    fi
    info "$DEV_SWAP -> swap"
    drynt mkswap "$DEV_SWAP"
fi
 
# -- Mount --
 
if [[ "$do_mount" -eq 1 && "$do_fs" -eq 0 ]]; then
    resolve_disk_state
fi
 
if [[ "$do_mount" -eq 1 ]]; then
    DEV_ESP="${system_disk}1"
    DEV_BOOT="${system_disk}2"
    DEV_ROOT="/dev/$system_vg/$LV_ROOT"
    DEV_HOME="/dev/$system_vg/$LV_HOME"
    DEV_SWAP="/dev/$system_vg/$LV_SWAP"
    DEV_DATA="/dev/$VG_HDD/$LV_DATA"
 
    log "Mounting file systems..."
 
    info "$DEV_ROOT -> /mnt"
    drynt mount "$DEV_ROOT" /mnt
    info "$DEV_ESP -> /mnt/efi"
    drynt mount --mkdir "$DEV_ESP" /mnt/efi
    info "$DEV_BOOT -> /mnt/boot"
    drynt mount --mkdir "$DEV_BOOT" /mnt/boot
    if [[ "$single_root" -eq 0 ]]; then
        info "$DEV_HOME -> /mnt/home"
        drynt mount --mkdir "$DEV_HOME" /mnt/home
    fi
    if [[ "$data_vg_exists" ]]; then
        info "$DEV_DATA -> /mnt/data"
        drynt mount --mkdir "$DEV_DATA" /mnt/data
    fi
    info "$DEV_SWAP -> swap"
    drynt swapon "$DEV_SWAP"
fi
 
# -- Install base system --
 
if [[ "$do_install" -eq 1 ]]; then
    if [[ -z "$hostname" ]]; then
        echo "Hostname is required for the install step. Use -n <hostname>."
        echo "Run '$(basename "$0") -h' for usage."
        exit 1
    fi
 
    if [[ -z "$system_vg" ]]; then
        resolve_disk_state
    fi
    DEV_ROOT="/dev/$system_vg/$LV_ROOT"
 
    log "Installing base system..."
    
    info "Setting up pacman mirrors..."
    drynt reflector --latest 10 --protocol https --sort rate --save /etc/pacman.d/mirrorlist
    
    info "Installing..."
    drynt pacstrap -K /mnt base base-devel linux linux-firmware intel-ucode lvm2 networkmanager sudo git man-db man-pages texinfo
 
    drynt "genfstab -U /mnt >> /mnt/etc/fstab"
 
    # systemd-resolved config
    drynt ln -sf ../run/systemd/resolve/stub-resolv.conf /mnt/etc/resolv.conf
 
    # Copy rEFInd's ext4 driver, needed for systemd-boot
    drynt mkdir -p /mnt/efi/EFI/systemd/drivers/
    drynt cp /usr/share/refind/drivers_x64/ext4_x64.efi /mnt/efi/EFI/systemd/drivers/
 
    # Copy helpers file, next scripts will need it
    drynt cp 00-helpers.sh /mnt/
    drynt cp 00-helpers.sh /mnt/root/
    # Copy next scripts
    drynt mv 02-arch-chroot.sh /mnt/
    drynt mv 03-postinstall.sh /mnt/root/
 
    log "Entering chroot..."
 
    chroot_args="-r $DEV_ROOT -h $hostname"
    [[ "$dry_run" -eq 1 ]] && chroot_args="$chroot_args -p"
    drynt arch-chroot -S /mnt ./02-arch-chroot.sh $chroot_args
 
    # -- Cleanup --
    log "All done. After reboot, log in as root and run ./03-postinstall.sh" 
    drynt rm 00-helpers.sh
    self_clean
fi