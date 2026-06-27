# DO NOT RUN THIS SCRIPT
# It is meant as an example so you know which commands to type

loadkeys es # Set up keyboard layout

# Connect to the Internet via Wi-Fi
# iwctl
# iwctl> device list: List available wifi devices on our computer
# iwctl> station <device> scan: Scans for available networks, does not print anything 
# iwctl> station <device> get-networks: Shows available networks
# iwctl> station <device> connect <network>

ping ping.archlinux.org # Check Internet connection
timedatectl # Check system clock is correct

# Partitions
lsblk # List current devices and partitions
gdisk /dev/<devicename> # Partition device
# gdisk commands
# d: Delete partition
# n: Create new partition
# p: Show existing partitions
# c: Change partition name
# w: Write changes to disk and quit

# /dev/sda - SSD

# EFI system partition (ESP)
# Last sector: +512M // 512MiB
# Hex code: ef00

# boot partition
# Last sector: +512M
# Hex code: ea00

# LVM partition
# Last sector: Last disk sector
# Hex code: 8e00

# /dev/sdb - HDD
# Single partition spanning the whole disk

# LVM
pvcreate /dev/sda3
pvcreate /dev/sdb1

vgcreate vg_ssd /dev/sda3
vgcreate vg_hdd /dev/sdb1

lvcreate -L 100G vg_ssd -n root
lvcreate -L 100G vg_ssd -n home
lvcreate -L 8G vg_ssd -n swap

lvcreate -l 100%FREE vg_hdd -n data
lvreduce -L -256M vg_hdd/data # Free space required by ext4 filesystems in order to run e2scrub

# Create filesystems
mkfs.fat -F 32 /dev/sda1 # ESP
mkfs.ext4 /dev/sda2 # boot

mkfs.ext4 /dev/vg_ssd/root
mkfs.ext4 /dev/vg_ssd/home
mkfs.ext4 /dev/vg_hdd/data

mkswap /dev/vg_ssd/swap

# Mount filesystems
mount /dev/vg_ssd/root /mnt
mount --mkdir /dev/sda1 /mnt/efi
mount --mkdir /dev/sda2 /mnt/boot
mount --mkdir /dev/vg_ssd/home /mnt/home
mount --mkdir /dev/vg_hdd/data /mnt/data/shynfia
swapon /dev/vg_ssd/swap

# Install essential packages
# Sort Arch mirrors by download speed and save them to pacman's mirrorlist
reflector --latest 10 --protocol https --sort rate --save /etc/pacman.d/mirrorlist
pacstrap -K /mnt base base-devel linux linux-firmware linux-headers intel-ucode lvm2 dosfstools e2fsprogs networkmanager wireless-regdb nano nano-syntax-highlighting man-db man-pages texinfo

# fstab
genfstab -U /mnt >> /mnt/etc/fstab

# systemd-resolved config
ln -sf ../run/systemd/resolve/stub-resolv.conf /mnt/etc/resolv.conf

cp /usr/share/refind/drivers_x64/ext4_x64.efi /mnt/efi/EFI/systemd/drivers/ # Copy rEFInd's ext4 driver, needed for systemd-boot

arch-chroot -S /mnt # -S required to install systemd-boot

ln -sf /usr/share/zoneinfo/Europe/Madrid /etc/localtime # Set timezone
hwclock --systohc # Create /etc/adjtime
systemctl enable systemd-timesyncd # Enable time sync service

nano /etc/locale.gen # Uncomment desired locales eg en_US.UTF-8, es_ES.UTF-8
locale-gen # Generate locales
echo "LANG=en_US.UTF-8" > /etc/locale.conf # Set system locale
echo "KEYMAP=es" > /etc/vconsole.conf # Set TTY keyboard layout
localectl --no-convert set-x11-keymap es # Set X11 keyboard layout, needed for some programs like plasmalogin

echo "rocaterra" > /etc/hostname # Set hostname
echo "127.0.1.1        rocaterra" >> /etc/hosts # Resolve own hostname locally
systemctl enable systemd-resolved # Enable DNS resolver
systemctl enable NetworkManager

nano /etc/mkinitcpio.conf # Insert lvm2 hook between "block" and "filesystems" in HOOKS array
mkinitcpio -P # Rebuild initramfs

passwd # Set root password

bootctl install # Looks for ESP at /efi and XBOOTLDR at /boot
nano /efi/loader/loader.conf # Set up systemd-boot
# timeout 0
# console-mode auto
# editor false
# auto-firmware true
# auto-reboot true
# auto-poweroff true
nano /boot/loader/entries/arch.conf # Set up Arch entry
# title Arch Linux
# linux /vmlinuz-linux
# initrd /initramfs-linux.img
# options root=/dev/vg_ssd/root rw // As root filesystem is in a LV, root= must point to the mapped device

# After rebooting
nmcli device wifi connect <network> password <password> # Connect to wifi using NetworkManager

nano /etc/pacman.conf # Uncomment multilib repository

# Audio setup
pacman -S lib32-pipewire lib32-pipewire-jack pipewire pipewire-alsa pipewire-audio pipewire-jack pipewire-pulse wireplumber xdg-desktop-portal

pacman -S sudo vi # Required for editing sudoers
visudo # Give sudo permissions to group wheel
useradd -m -G wheel shynfia # Create unprivileged user
passwd shynfia # Set password for the new user

# After exiting and reloggin with the new user
sudo pacman -S git # Required for installing paru
git clone https://aur.archlinux.org/paru.git
cd paru
makepkg -si
cd ..
rm -rf paru
paru --gendb

# Graphics setup
paru -S lib32-nvidia-580xx-utils nvidia-580xx-dkms
sudo pacman -S lib32-mesa lib32-vulkan-intel linux-headers nvtop switcheroo-control vulkan-intel
sudo systemctl enable switcheroo-control

sudo pacman -S plasma-meta noto-fonts-cjk # Instal Plasma desktop. Choose noto-fonts and qt6-multimedia-ffmpeg
sudo systemctl enable plasmalogin # Start plasma on boot