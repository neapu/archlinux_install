#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/common.sh"

# === 变量定义 ===
MIRROR_HOST='mirrors.ustc.edu.cn'
NETWORK_CHECK_TIMEOUT=10
TARGET_DISK=""
EFI_PARTITION=""
ROOT_PARTITION=""
CPU_VENDOR="unknown"
KERNEL_PACKAGE="linux"

# 基础系统与固件。
BASE_SYSTEM_PACKAGES=(
    base
    linux-firmware
    linux-firmware-marvell
    bolt
)

# 文件系统与引导相关工具。
BOOT_FILESYSTEM_PACKAGES=(
    btrfs-progs
    grub
    efibootmgr
    sbctl
)

# 网络与权限管理工具。
SYSTEM_SERVICE_PACKAGES=(
    networkmanager
    sudo
)

# 常用编辑与版本管理工具。
COMMON_TOOL_PACKAGES=(
    vim
    git
)

# 常用编译工具链。
DEVELOPMENT_PACKAGES=(
    gcc
    make
    base-devel
)

# 常见命令行与排障工具。
UTILITY_PACKAGES=(
    curl
    wget
    rsync
    unzip
    htop
)

# === 步骤函数 ===
print_wifi_help() {
    printf '\n%bWi-Fi connection guide (Arch ISO):%b\n' "$BOLD$YELLOW" "$RESET" >&2
    printf '1. Start the wireless tool: %biwctl%b\n' "$CYAN" "$RESET" >&2
    printf '2. List devices: %bdevice list%b\n' "$CYAN" "$RESET" >&2
    printf '3. Scan networks: %bstation <device> scan%b\n' "$CYAN" "$RESET" >&2
    printf '4. Show networks: %bstation <device> get-networks%b\n' "$CYAN" "$RESET" >&2
    printf '5. Connect to Wi-Fi: %bstation <device> connect <SSID>%b\n' "$CYAN" "$RESET" >&2
    printf '6. Enter the password when prompted, then exit: %bexit%b\n' "$CYAN" "$RESET" >&2
    printf '7. Re-run this script after the network is connected.\n\n' >&2
    printf 'Example:\n' >&2
    printf '  %biwctl%b\n' "$CYAN" "$RESET" >&2
    printf '  %bdevice list%b\n' "$CYAN" "$RESET" >&2
    printf '  %bstation wlan0 scan%b\n' "$CYAN" "$RESET" >&2
    printf '  %bstation wlan0 get-networks%b\n' "$CYAN" "$RESET" >&2
    printf '  %bstation wlan0 connect MyWiFi%b\n\n' "$CYAN" "$RESET" >&2
}

require_efi() {
    if [[ ! -d /sys/firmware/efi/efivars ]]; then
        print_error "This script must be run on an EFI system."
        exit 1
    fi
    print_success "EFI system detected."
}

check_network() {
    print_step "Checking network connectivity..."
    if ping -c 1 -W "$NETWORK_CHECK_TIMEOUT" "$MIRROR_HOST" &> /dev/null; then
        print_success "Network is connected."
    else
        print_error "Network is not connected."
        print_info "If you are using Wi-Fi, connect first and then rerun this script."
        if has_command iwctl; then
            print_wifi_help
        else
            printf '%bThe command %siwctl%s is not available in the current environment.%b\n' "$BOLD$YELLOW" "$CYAN" "$RESET" "$RESET" >&2
        fi
        exit 1
    fi
}

list_disks() {
    print_step "Available disks:"
    require_command fdisk

    local disk_info
    disk_info=$(fdisk -l 2>/dev/null | awk '
        function flush_disk() {
            if (device != "") {
                printf "%-14s %-12s %s\n", device, size, (model != "" ? model : "-")
            }
        }

        /^Disk \/dev\// {
            flush_disk()
            device = $2
            sub(/:$/, "", device)
            if (device !~ /^\/dev\/(sd[a-z]+|nvme[0-9]+n[0-9]+)$/) {
                device = ""
                size = ""
                model = ""
                next
            }
            size = $3 " " $4
            sub(/,$/, "", size)
            model = ""
            next
        }

        /^Disk model:/ {
            model = $0
            sub(/^Disk model:[[:space:]]*/, "", model)
            next
        }

        END {
            flush_disk()
        }
    ')

    if [[ -n "$disk_info" ]]; then
        printf '%-14s %-12s %s\n' 'DEVICE' 'SIZE' 'MODEL'
        printf '%s\n' "$disk_info"
    else
        print_error "No disks found."
        exit 1
    fi
}

select_target_disk() {
    print_step "Select target disk for installation"
    while true; do
        read -rp "Enter the device name (e.g., /dev/sda): " TARGET_DISK
        if [[ -z "$TARGET_DISK" ]]; then
            print_error "Disk path cannot be empty. Please try again."
            continue
        fi
        if [[ ! -e "$TARGET_DISK" ]]; then
            print_error "Disk path does not exist: $TARGET_DISK"
            continue
        fi
        if [[ ! -b "$TARGET_DISK" ]]; then
            print_error "Path is not a block device: $TARGET_DISK"
            continue
        fi
        if [[ ! "$TARGET_DISK" =~ ^/dev/(sd[a-z]+|nvme[0-9]+n[0-9]+)$ ]]; then
            print_error "Unsupported disk type: $TARGET_DISK"
            print_info "Please select one of the disks shown above."
            continue
        fi
        break
    done
    print_success "Selected target disk: $TARGET_DISK"
}

confirm_disk_erasure() {
    local confirm

    print_warning "All data on $TARGET_DISK will be erased. Make sure you have backed up any important data before proceeding."
    read -rp "Type 'yes' to confirm and continue: " confirm
    if [[ "$confirm" != "yes" ]]; then
        print_info "Installation cancelled by user."
        exit 0
    fi
}

partition_disk() {
    print_step "Starting disk partitioning on $TARGET_DISK"

    require_command parted
    require_command wipefs

    local partition_prefix
    partition_prefix="$TARGET_DISK"
    if [[ "$TARGET_DISK" =~ ^/dev/nvme[0-9]+n[0-9]+$ ]]; then
        partition_prefix="${TARGET_DISK}p"
    fi

    print_info "Wiping existing signatures on $TARGET_DISK"
    wipefs -af "$TARGET_DISK" > /dev/null

    print_info "Creating GPT partition table"
    parted -s "$TARGET_DISK" mklabel gpt
    parted -s "$TARGET_DISK" mkpart ESP fat32 1MiB 301MiB
    parted -s "$TARGET_DISK" set 1 esp on
    parted -s "$TARGET_DISK" mkpart primary ext4 301MiB 100%

    if has_command partprobe; then
        partprobe "$TARGET_DISK"
    fi
    if has_command udevadm; then
        udevadm settle
    fi

    EFI_PARTITION="${partition_prefix}1"
    ROOT_PARTITION="${partition_prefix}2"

    print_success "Disk partitioning completed."
    print_info "EFI partition: $EFI_PARTITION"
    print_info "Root partition: $ROOT_PARTITION"
}

format_partitions() {
    print_step "Formatting partitions"

    require_command mkfs.fat
    require_command mkfs.btrfs

    if [[ -z "$EFI_PARTITION" || -z "$ROOT_PARTITION" ]]; then
        print_error "Partition information is missing."
        exit 1
    fi
    if [[ ! -b "$EFI_PARTITION" ]]; then
        print_error "EFI partition is not available: $EFI_PARTITION"
        exit 1
    fi
    if [[ ! -b "$ROOT_PARTITION" ]]; then
        print_error "Root partition is not available: $ROOT_PARTITION"
        exit 1
    fi

    print_info "Formatting EFI partition as FAT32: $EFI_PARTITION"
    mkfs.fat -F 32 "$EFI_PARTITION" > /dev/null

    print_info "Formatting root partition as Btrfs: $ROOT_PARTITION"
    mkfs.btrfs -f "$ROOT_PARTITION" > /dev/null

    print_success "Partition formatting completed."
}

create_btrfs_subvolumes() {
    print_step "Creating Btrfs subvolumes"

    require_command mount
    require_command umount
    require_command btrfs
    require_command mountpoint

    if [[ ! -b "$ROOT_PARTITION" ]]; then
        print_error "Root partition is not available: $ROOT_PARTITION"
        exit 1
    fi
    if mountpoint -q /mnt; then
        print_error "/mnt is already mounted. Please unmount it first."
        exit 1
    fi

    mkdir -p /mnt

    print_info "Temporarily mounting root partition: $ROOT_PARTITION"
    if ! mount "$ROOT_PARTITION" /mnt; then
        print_error "Failed to mount root partition: $ROOT_PARTITION"
        exit 1
    fi

    if ! btrfs subvolume create /mnt/@ > /dev/null; then
        umount /mnt || true
        print_error "Failed to create Btrfs subvolume: @"
        exit 1
    fi
    if ! btrfs subvolume create /mnt/@home > /dev/null; then
        umount /mnt || true
        print_error "Failed to create Btrfs subvolume: @home"
        exit 1
    fi

    print_info "Unmounting temporary mount point"
    umount /mnt

    print_success "Btrfs subvolumes created: @, @home"
}

mount_subvolumes() {
    print_step "Mounting filesystems"

    require_command mount
    require_command mountpoint

    if [[ ! -b "$ROOT_PARTITION" ]]; then
        print_error "Root partition is not available: $ROOT_PARTITION"
        exit 1
    fi
    if [[ ! -b "$EFI_PARTITION" ]]; then
        print_error "EFI partition is not available: $EFI_PARTITION"
        exit 1
    fi
    if mountpoint -q /mnt; then
        print_error "/mnt is already mounted. Please unmount it first."
        exit 1
    fi

    mkdir -p /mnt

    print_info "Mounting root subvolume @ with transparent compression"
    mount -o subvol=@,compress=zstd "$ROOT_PARTITION" /mnt

    mkdir -p /mnt/home /mnt/efi

    print_info "Mounting home subvolume @home with transparent compression"
    mount -o subvol=@home,compress=zstd "$ROOT_PARTITION" /mnt/home

    print_info "Mounting EFI partition"
    mount "$EFI_PARTITION" /mnt/efi

    print_success "Filesystems mounted under /mnt"
}

configure_mirrorlist() {
    print_step "Configuring pacman mirror"

    require_command pacman

    local mirrorlist_path backup_path
    mirrorlist_path="/etc/pacman.d/mirrorlist"
    backup_path="/etc/pacman.d/mirrorlist.bak"

    if [[ ! -f "$mirrorlist_path" ]]; then
        print_error "Mirrorlist file not found: $mirrorlist_path"
        exit 1
    fi

    if [[ ! -f "$backup_path" ]]; then
        cp "$mirrorlist_path" "$backup_path"
    fi

    print_info "Setting mirror to $MIRROR_HOST"
    printf 'Server = https://%s/archlinux/$repo/os/$arch\n' "$MIRROR_HOST" > "$mirrorlist_path"

    print_info "Synchronizing package databases"
    pacman -Syy > /dev/null

    print_success "Pacman mirror updated and synchronized."
}

detect_cpu_vendor() {
    print_step "Detecting CPU vendor"

    local vendor_id
    vendor_id=$(awk -F ': ' '/^vendor_id[[:space:]]*:/ {print $2; exit}' /proc/cpuinfo 2>/dev/null || true)

    case "$vendor_id" in
        GenuineIntel)
            CPU_VENDOR="intel"
            ;;
        AuthenticAMD)
            CPU_VENDOR="amd"
            ;;
        *)
            CPU_VENDOR="unknown"
            ;;
    esac

    print_info "Detected CPU vendor: $CPU_VENDOR"
}

select_kernel_package() {
    print_step "Select kernel package"
    print_info "1) linux"
    print_info "2) linux-lts"
    print_info "3) linux-zen"
    print_info "4) linux-hardened"

    local choice
    while true; do
        read -rp "Choose kernel [1-4] (default: 1): " choice
        case "$choice" in
            ""|1)
                KERNEL_PACKAGE="linux"
                break
                ;;
            2)
                KERNEL_PACKAGE="linux-lts"
                break
                ;;
            3)
                KERNEL_PACKAGE="linux-zen"
                break
                ;;
            4)
                KERNEL_PACKAGE="linux-hardened"
                break
                ;;
            *)
                print_error "Invalid choice: $choice"
                print_info "Please enter 1, 2, 3, or 4."
                ;;
        esac
    done

    print_success "Selected kernel package: $KERNEL_PACKAGE"
}

install_base_system() {
    print_step "Installing base system"

    require_command pacstrap

    if ! mountpoint -q /mnt; then
        print_error "/mnt is not mounted."
        exit 1
    fi

    local microcode_package=""
    case "$CPU_VENDOR" in
        intel)
            microcode_package="intel-ucode"
            ;;
        amd)
            microcode_package="amd-ucode"
            ;;
    esac

    if [[ -n "$microcode_package" ]]; then
        print_info "Installing microcode package: $microcode_package"
    else
        print_warning "CPU vendor is unknown. Microcode package will be skipped."
    fi

    local packages=(
        "${BASE_SYSTEM_PACKAGES[@]}"
        "$KERNEL_PACKAGE"
        "${BOOT_FILESYSTEM_PACKAGES[@]}"
        "${SYSTEM_SERVICE_PACKAGES[@]}"
        "${COMMON_TOOL_PACKAGES[@]}"
        "${DEVELOPMENT_PACKAGES[@]}"
        "${UTILITY_PACKAGES[@]}"
    )

    if [[ -n "$microcode_package" ]]; then
        packages+=("$microcode_package")
    fi

    print_info "Installing packages with pacstrap"
    pacstrap -K /mnt "${packages[@]}"

    print_success "Base system installation completed."
}

generate_fstab() {
    print_step "Generating fstab"

    require_command genfstab

    if ! mountpoint -q /mnt; then
        print_error "/mnt is not mounted."
        exit 1
    fi
    if [[ ! -d /mnt/etc ]]; then
        print_error "Target system directory is missing: /mnt/etc"
        exit 1
    fi

    print_info "Generating mount configuration for /mnt/etc/fstab"
    genfstab -U /mnt > /mnt/etc/fstab

    print_success "fstab generated successfully."
}

inject_project_scripts() {
    print_step "Copying project scripts into new system"

    if ! mountpoint -q /mnt; then
        print_error "/mnt is not mounted."
        exit 1
    fi

    local scripts=()
    local script_path
    shopt -s nullglob
    scripts=("$SCRIPT_DIR"/*.sh)
    shopt -u nullglob

    if [[ ${#scripts[@]} -eq 0 ]]; then
        print_error "No shell scripts found in project directory: $SCRIPT_DIR"
        exit 1
    fi

    mkdir -p /mnt/root

    for script_path in "${scripts[@]}"; do
        cp "$script_path" /mnt/root/
        chmod +x "/mnt/root/$(basename "$script_path")"
    done

    print_success "Project scripts copied to /mnt/root"
}

print_chroot_hint() {
    print_step "Next step"
    print_warning "The chroot-stage scripts may still be incomplete. Review them before running if needed."
    print_info "Run: arch-chroot /mnt"
    print_info "Then run: cd /root && ./chroot_install.sh"
}

# === 主函数 ===
main() {
    # 检测是否以 root 用户运行
    require_root
    # 检测是否在 EFI 系统下运行
    require_efi
    print_step 'Arch Linux fast installer'

    # 检测网络
    check_network
    # 检测可用的磁盘
    list_disks
    # 提示用户选择目标磁盘
    select_target_disk
    # 二次确认清盘
    confirm_disk_erasure
    # 开始分区
    partition_disk
    # 格式化分区
    format_partitions
    # 创建 Btrfs 子卷
    create_btrfs_subvolumes
    # 挂载子卷和 EFI 分区
    mount_subvolumes
    # 切换镜像源并同步数据库
    configure_mirrorlist
    # 检测 CPU 类型
    detect_cpu_vendor
    # 选择内核类型
    select_kernel_package
    # 安装基础系统
    install_base_system
    # 生成挂载点配置
    generate_fstab
    # 将项目脚本复制到新系统
    inject_project_scripts
    # 提示用户进入 chroot 继续安装
    print_chroot_hint
}

main "$@"