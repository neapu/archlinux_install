import subprocess
import json
import getpass
import time
import os
import re

MIRROR_SERVER = "mirrors.ustc.edu.cn"
EFI_PARTITION_SIZE_MB = 300

PACKAGE_LIST = [
    # 基本工具包
    "base",
    # Linux内核
    "linux",
    # 固件包
    "linux-firmware",
    # 文件系统工具
    "btrfs-progs",
    # 马威尔网卡固件
    "linux-firmware-marvell",
    # 网络工具
    "networkmanager",
    # 雷电4支持
    "bolt",
    # 引导加载器
    "grub", "efibootmgr",
    # 其他实用工具
    "vim",
    "sudo",
    "openssh",
    "fastfetch",
    "git",
    # 基础开发工具
    "base-devel",
    "python",
    "nodejs", "npm",
]

SELECTED_DISK = None


class Colors:
    RESET = "\033[0m"
    RED = "\033[31m"
    GREEN = "\033[32m"
    YELLOW = "\033[33m"
    BLUE = "\033[34m"


# 安装环境与基础输出
def is_connected_ping(host):
    try:
        subprocess.run(
            ["ping", "-c", "1", "-W", "2", host],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return True
    except subprocess.CalledProcessError:
        return False


def check_network(host):
    if is_connected_ping(host):
        print("Network is connected.")
        return True

    print("Network is not connected. Retrying in 5 seconds...")
    time.sleep(5)
    return is_connected_ping(host)


def check_x86_64_efi_environment():
    result = run_cmd(["uname", "-m"], "Error detecting system architecture")
    if result is None:
        return False

    architecture = result.stdout.strip()
    if architecture != "x86_64":
        print_error(f"Unsupported architecture: {architecture}. This script requires x86_64.")
        return False

    if not os.path.isdir("/sys/firmware/efi"):
        print_error("UEFI firmware interface not detected. Please boot the installer in UEFI mode.")
        return False

    if not os.path.isdir("/sys/firmware/efi/efivars"):
        print_error("EFI variables are not available. The x86_64-efi environment is incomplete.")
        return False

    return True


def print_info(message):
    print(f"{Colors.BLUE}{message}{Colors.RESET}")


def print_success(message):
    print(f"{Colors.GREEN}{message}{Colors.RESET}")


def print_error(message):
    print(f"{Colors.RED}{message}{Colors.RESET}")


def print_warning(message):
    print(f"{Colors.YELLOW}{message}{Colors.RESET}")


# 命令执行封装，统一处理普通命令与 chroot 命令
def run_cmd(cmd, error_message=None, capture_output=True, input_text=None):
    try:
        result = subprocess.run(cmd, capture_output=capture_output, text=True, input=input_text)
    except Exception as e:
        prefix = error_message or f"Error running {' '.join(cmd)}"
        print_error(f"{prefix}: {e}")
        return None

    if result.returncode != 0:
        prefix = error_message or f"Error running {' '.join(cmd)}"
        detail = result.stderr.strip() if result.stderr else result.stdout.strip()
        print_error(f"{prefix}: {detail}")
        return None

    return result


def run_chroot_cmd(cmd, error_message=None, capture_output=True, input_text=None):
    return run_cmd(["arch-chroot", "/mnt"] + cmd, error_message, capture_output, input_text)


# 交互输入：确认、主机信息、账户信息
def confirm_action(message, default_yes=True):
    prompt = " [Y/n]: " if default_yes else " [y/N]: "
    while True:
        choice = input(f"{Colors.YELLOW}{message}{Colors.RESET}{prompt}").strip().lower()
        if choice == "" and default_yes:
            return True
        if choice == "" and not default_yes:
            return False
        if choice in ["y", "yes"]:
            return True
        if choice in ["n", "no"]:
            return False
        print_error("Invalid input. Please enter 'y' or 'n'.")


def get_confirmed_password(password_prompt, confirm_prompt, empty_error_message):
    password = getpass.getpass(password_prompt).strip()
    if not password:
        print_error(empty_error_message)
        return None

    confirm_count = 3
    while confirm_count > 0:
        confirm_password = getpass.getpass(confirm_prompt).strip()
        if confirm_password == password:
            return password

        print_error("Passwords do not match. Please try again.")
        confirm_count -= 1

    print_error("Failed to confirm password after 3 attempts.")
    return None


def get_install_credentials():
    hostname = input("Enter the hostname for your new Arch Linux installation: ").strip()
    if not hostname:
        print_error("Hostname cannot be empty.")
        return None, None

    root_password = get_confirmed_password(
        "Enter the root password for your new Arch Linux installation: ",
        "Confirm the root password: ",
        "Root password cannot be empty.",
    )
    if root_password is None:
        return None, None

    return hostname, root_password


def get_user_credentials():
    username = input("Enter the username for the regular user account: ").strip()
    if not username:
        print_error("Username cannot be empty.")
        return None, None

    if re.fullmatch(r"[a-z_][a-z0-9_-]*[$]?", username) is None:
        print_error("Invalid username. Use lowercase letters, numbers, underscores, or hyphens.")
        return None, None

    user_password = get_confirmed_password(
        f"Enter the password for user {username}: ",
        f"Confirm the password for user {username}: ",
        "User password cannot be empty.",
    )
    if user_password is None:
        return None, None

    return username, user_password


# 磁盘探测、分区与挂载
def get_disk_block():
    cmd = ["lsblk", "-J", "-b", "-o", "NAME,SIZE,TYPE,MODEL"]
    result = run_cmd(cmd, "Error running lsblk")
    if result is None:
        return None

    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError as e:
        print_error(f"Error parsing lsblk output: {e}")
        return None

    disks = []
    for block in data.get("blockdevices", []):
        if block["type"] == "disk":
            disks.append({
                "name": block["name"],
                "size": block["size"],
                "model": block.get("model", "")
            })
    return disks
    
def get_partition_block(disk):
    disk_path = f"/dev/{disk['name']}"
    cmd = ["lsblk", "-J", "-l", "-o", "PATH,TYPE", disk_path]
    result = run_cmd(cmd, f"Error running lsblk for {disk_path}")
    if result is None:
        return None

    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError as e:
        print_error(f"Error parsing lsblk output for {disk_path}: {e}")
        return None

    partitions = []
    for block in data.get("blockdevices", []):
        if block["type"] == "part":
            partitions.append(block["path"])
    return partitions
    
def format_size(size_bytes):
    for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
        if size_bytes < 1024:
            return f"{size_bytes:.2f} {unit}"
        size_bytes /= 1024
    return f"{size_bytes:.2f} PB"
    
def print_disks(disks):
    rows = [
        {
            "name": disk["name"],
            "size": format_size(disk["size"]),
            "model": disk["model"],
        }
        for disk in disks
    ]

    name_width = max(len("Name"), *(len(row["name"]) for row in rows))
    size_width = max(len("Size"), *(len(row["size"]) for row in rows))
    model_width = max(len("Model"), *(len(row["model"]) for row in rows))

    print(f"{'Name':<{name_width}}  {'Size':>{size_width}}  {'Model':<{model_width}}")
    print(f"{'-' * name_width}  {'-' * size_width}  {'-' * model_width}")

    for row in rows:
        print(
            f"{row['name']:<{name_width}}  {row['size']:>{size_width}}  {row['model']:<{model_width}}"
        )

def select_disk(disks):
    while True:
        choice = input("Enter the name of the target disk (e.g., sda): ").strip()
        for disk in disks:
            if disk["name"] == choice:
                return disk
        print_error("Invalid disk name. Please try again.")

def partition_disk(disk):
    disk_path = f"/dev/{disk['name']}"
    print_info(f"Partitioning disk {disk_path}...")

    cmds = [
        # 创建GPT分区表
        ["parted", "-s", disk_path, "mklabel", "gpt"],
        # 创建EFI分区
        ["parted", "-s", disk_path, "mkpart", "ESP", "fat32", "1MiB", f"{EFI_PARTITION_SIZE_MB}MiB"],
        # 设置EFI分区标志
        ["parted", "-s", disk_path, "set", "1", "boot", "on"],
        ["parted", "-s", disk_path, "set", "1", "esp", "on"],
        # 创建根分区
        ["parted", "-s", disk_path, "mkpart", "ArchRoot", "btrfs", f"{EFI_PARTITION_SIZE_MB}MiB", "100%"]
    ]

    for cmd in cmds:
        if run_cmd(cmd) is None:
            return None

    partitions = get_partition_block(disk)
    if partitions is None or len(partitions) < 2:
        print_error("Failed to get partition information after partitioning.")
        return None
    
    return partitions

def format_partitions(efi_partition, root_partition):
    print_info(f"Formatting EFI partition {efi_partition} as FAT32...")
    cmd_efi = ["mkfs.fat", "-F32", efi_partition]
    if run_cmd(cmd_efi, "Error formatting EFI partition") is None:
        return False

    print_info(f"Formatting root partition {root_partition} as Btrfs...")
    cmd_root = ["mkfs.btrfs", "-f", root_partition]
    if run_cmd(cmd_root, "Error formatting root partition") is None:
        return False

    return True

def create_subvolumes(root_partition):
    volume_names = ["@", "@home"]

    # 临时挂载根分区
    if run_cmd(["mount", root_partition, "/mnt"], "Error mounting root partition") is None:
        return False
    
    for vol in volume_names:
        print_info(f"Creating Btrfs subvolume {vol}...")
        if run_cmd(["btrfs", "subvolume", "create", f"/mnt/{vol}"], f"Error creating subvolume {vol}") is None:
            return False
        
    # 卸载根分区
    if run_cmd(["umount", "/mnt"], "Error unmounting root partition") is None:
        return False

    return True
    
def mount_partitions(efi_partition, root_partition):
    cmds = [
        ["mount", "-t", "btrfs", "-o", "subvol=@,compress=zstd", root_partition, "/mnt"],
        ["mount", "--mkdir", "-t", "btrfs", "-o", "subvol=@home,compress=zstd", root_partition, "/mnt/home"],
        ["mount", "--mkdir", efi_partition, "/mnt/efi"],
    ]

    for cmd in cmds:
        if run_cmd(cmd) is None:
            return False
    return True


# 安装源、基础系统与系统配置
def set_mirrorlist():
    # 备份原有mirrorlist
    if run_cmd(["cp", "/etc/pacman.d/mirrorlist", "/etc/pacman.d/mirrorlist.bak"], "Error backing up mirrorlist") is None:
        return False
    
    # 写入新的mirrorlist
    mirrorlist_content = f"Server = https://{MIRROR_SERVER}/archlinux/$repo/os/$arch\n"
    try:
        with open("/etc/pacman.d/mirrorlist", "w") as f:
            f.write(mirrorlist_content)
    except Exception as e:
        print_error(f"Error writing new mirrorlist: {e}")
        return False
    
    # 重新同步软件包数据库
    if run_cmd(["pacman", "-Sy"], "Error syncing package database") is None:
        return False
    
    return True

def get_cpu_type():
    # intel/amd/other
    result = run_cmd(["lscpu"], "Error running lscpu")
    if result is None:
        return None

    if "Intel" in result.stdout or "INTEL" in result.stdout or "intel" in result.stdout:
        return "intel"
    if "AMD" in result.stdout or "amd" in result.stdout:
        return "amd"
    return "other"
    
def install_base_system():
    print_info("Installing base system with pacstrap...")
    cmd = ["pacstrap", "-K", "/mnt"] + PACKAGE_LIST

    cpu_type = get_cpu_type()

    if cpu_type == "intel":
        cmd += ["intel-ucode"]
    elif cpu_type == "amd":
        cmd += ["amd-ucode"]
    elif cpu_type == "other":
        print_warning("Unknown CPU type. Skipping microcode package installation.")
    else:
        print_warning("Failed to detect CPU type.")
        exit(1)

    if run_cmd(cmd, "Error installing base system") is None:
        return False

    return True
    
def generate_fstab():
    print_info("Generating fstab with genfstab...")
    cmd = ["genfstab", "-U", "/mnt"]
    result = run_cmd(cmd, "Error generating fstab")
    if result is None:
        return False

    try:
        with open("/mnt/etc/fstab", "w") as f:
            f.write(result.stdout)
    except Exception as e:
        print_error(f"Error writing fstab: {e}")
        return False

    return True

def set_timezone():
    print_info("Setting timezone...")
    if run_cmd(["ln", "-sf", "/usr/share/zoneinfo/Asia/Shanghai", "/mnt/etc/localtime"], "Error setting timezone") is None:
        return False
    if run_chroot_cmd(["hwclock", "--systohc"], "Error setting timezone") is None:
        return False
    return True

def set_locale():
    print_info("Setting locale...")
    try:
        with open("/mnt/etc/locale.gen", "w") as f:
            f.write("en_US.UTF-8 UTF-8\n")
            f.write("zh_CN.UTF-8 UTF-8\n")
        with open("/mnt/etc/locale.conf", "w") as f:
            f.write("LANG=en_US.UTF-8\n")
    except Exception as e:
        print_error(f"Error setting locale: {e}")
        return False

    if run_chroot_cmd(["locale-gen"], "Error setting locale") is None:
        return False
    return True

def set_hostname(hostname):
    print_info("Setting hostname...")
    try:
        with open("/mnt/etc/hostname", "w") as f:
            f.write(f"{hostname}\n")
    except Exception as e:
        print_error(f"Error setting hostname: {e}")
        return False
    return True


# 账户与服务初始化
def set_root_password(root_password):
    print_info("Setting root password...")
    if run_chroot_cmd(["chpasswd"], "Error setting root password", input_text=f"root:{root_password}\n") is None:
        return False
    return True


def create_regular_user(username, user_password):
    print_info(f"Creating regular user {username}...")
    if run_chroot_cmd(["useradd", "-m", "-G", "wheel", "-s", "/bin/bash", username], f"Error creating user {username}") is None:
        return False

    if run_chroot_cmd(["chpasswd"], f"Error setting password for user {username}", input_text=f"{username}:{user_password}\n") is None:
        return False

    return True

def enable_services():
    print_info("Enabling system services...")
    services = ["NetworkManager", "bolt"]

    for service in services:
        if run_chroot_cmd(["systemctl", "enable", service], f"Error enabling service {service}") is None:
            return False

    return True


# 引导安装与主流程编排
def setup_grub():
    print_info("Setting up GRUB bootloader...")
    cmds = [
        ["grub-install", "--target=x86_64-efi", "--efi-directory=/efi", "--boot-directory=/efi", "--bootloader-id=ArchLinux"],
        ["ln", "-s", "/efi/grub", "/boot/grub"],
        ["grub-mkconfig", "-o", "/boot/grub/grub.cfg"],
    ]
    for cmd in cmds:
        if run_chroot_cmd(cmd) is None:
            return False
    return True
    
def main():
    print_success("Welcome to the Arch Linux Fast Installer!")
    if not check_x86_64_efi_environment():
        exit(1)

    # 检查网络连接
    if not check_network(MIRROR_SERVER):
        print_error("Network is not connected. Please check your connection and try again.")
        exit(1)

    # 获取用户输入的主机名和root密码
    hostname, root_password = get_install_credentials()
    if hostname is None or root_password is None:
        exit(1)

    username, user_password = get_user_credentials()
    if username is None or user_password is None:
        exit(1)

    print_info("Step 1: Select target disk")

    disks = get_disk_block()
    if disks is None:
        print_error("Failed to get disk information.")
        exit(1)

    print_info("Available disks:")
    print_disks(disks)

    SELECTED_DISK = select_disk(disks)
    print_success(f"Selected disk: {SELECTED_DISK['name']} ({format_size(SELECTED_DISK['size'])})")

    print_info("Step 2: Partitioning disk")
    # 二次确认警告
    if not confirm_action(f"Are you sure you want to install Arch Linux on /dev/{SELECTED_DISK['name']}? This will erase all data on the disk.", default_yes=False):
        print_warning("Installation cancelled by user.")
        exit(0)

    partitions = partition_disk(SELECTED_DISK)
    if partitions is None:
        print_error("Disk partitioning failed.")
        exit(1)
    
    print_info("Step 3: Formatting partitions")
    if not format_partitions(partitions[0], partitions[1]):
        print_error("Partition formatting failed.")
        exit(1)

    print_info("Step 4: Creating Btrfs subvolumes")
    if not create_subvolumes(partitions[1]):
        print_error("Failed to create Btrfs subvolumes.")
        exit(1)

    print_info("Step 5: Mounting partitions")
    if not mount_partitions(partitions[0], partitions[1]):
        print_error("Failed to mount partitions.")
        exit(1)

    print_info("Step 6: Setting mirrorlist")
    if not set_mirrorlist():
        print_error("Failed to set mirrorlist.")
        exit(1)
    
    print_info("Step 7: Installing base system")
    if not install_base_system():
        print_error("Failed to install base system.")
        exit(1)

    print_info("Step 8: Generating fstab")
    if not generate_fstab():
        print_error("Failed to generate fstab.")
        exit(1)

    print_info("Step 9: Setting timezone")
    if not set_timezone():
        print_error("Failed to set timezone.")
        exit(1)

    print_info("Step 10: Setting locale")
    if not set_locale():
        print_error("Failed to set locale.")
        exit(1)

    print_info("Step 11: Setting hostname")
    if not set_hostname(hostname):
        print_error("Failed to set hostname.")
        exit(1)

    print_info("Step 12: Setting root password")
    if not set_root_password(root_password):
        print_error("Failed to set root password.")
        exit(1)

    print_info("Step 13: Creating regular user")
    if not create_regular_user(username, user_password):
        print_error("Failed to create regular user.")
        exit(1)

    print_info("Step 14: Enabling system services")
    if not enable_services():
        print_error("Failed to enable system services.")
        exit(1)

    print_info("Step 15: Setting up GRUB bootloader")
    if not setup_grub():
        print_error("Failed to set up GRUB bootloader.")
        exit(1)

    print_success("Arch Linux installation completed successfully!")
    print_info("You can now reboot into your new Arch Linux installation.")

if __name__ == "__main__":
    main()