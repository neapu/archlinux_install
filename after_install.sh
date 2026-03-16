#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/common.sh"

NETWORK_CHECK_HOST="archlinux.org"
NETWORK_CHECK_TIMEOUT=10
ARCHLINUXCN_MIRROR="https://mirrors.ustc.edu.cn/archlinuxcn/\$arch"
GPU_VENDOR_INTEL=0
GPU_VENDOR_AMD=0
GPU_VENDOR_NVIDIA=0

KDE_PACKAGES=(
	# KDE Plasma 桌面环境元包。
	plasma
    # KDE 图形登录管理器。
    sddm
	# Baloo 搜索结果小部件。
	baloo-widgets
	# Dolphin 文件管理器扩展插件。
	dolphin-plugins
	# 为视频文件生成缩略图。
	ffmpegthumbs
	# KDE 使用情况调查组件。
	kde-inotify-survey
	# 图像与文档缩略图支持。
	kdegraphics-thumbnailers
	# Samba 共享等网络文件共享集成。
	kdenetwork-filesharing
	# KDE 帮助中心。
	khelpcenter
	# 补充更多图像格式支持。
	kimageformats
	# 允许文件管理器执行管理员操作。
	kio-admin
	# 提供额外的 KIO 协议支持。
	kio-extras
	# 通过 FUSE 挂载远程 KIO 路径。
	kio-fuse
	# KDE 钱包管理工具。
	kwalletmanager
	# 指纹识别服务。
	fprintd
	# 双显卡切换控制服务。
	switcheroo-control
	# KDE 终端模拟器。
	konsole
	# 中日韩字体集合。
	noto-fonts-cjk
	# 提供 KDE 图形对话框命令接口。
	kdialog
	# Cascadia Code 编程字体。
	ttf-cascadia-code
	# 思源黑体简体中文字库。
	adobe-source-han-sans-cn-fonts
	# KDE 图形化压缩包管理器。
	ark
	# 7z 压缩格式支持工具。
	7zip
	# 支持更多归档格式解压。
	unarchiver
	# ZIP 解压工具。
	unzip
    # 输入法
    fcitx5
    fcitx5-chinese-addons
    fcitx5-configtool
    fcitx5-gtk
    fcitx5-qt
)

# 禁用 snd_hda_intel 声卡节能。
disable_audio_power_save() {
	print_step "Disabling audio power saving"

	mkdir -p /etc/modprobe.d
	printf 'options snd_hda_intel power_save=0\n' > /etc/modprobe.d/disable-snd-hda-intel-powersave.conf

	print_success "Audio power saving disabled"
}

# 输出使用 NetworkManager 连接 Wi-Fi 的方法。
print_wifi_help() {
	printf '\n%bWi-Fi connection guide (NetworkManager):%b\n' "$BOLD$YELLOW" "$RESET" >&2
	printf '1. List devices: %bnmcli device status%b\n' "$CYAN" "$RESET" >&2
	printf '2. Enable Wi-Fi radio: %bnmcli radio wifi on%b\n' "$CYAN" "$RESET" >&2
	printf '3. Scan networks: %bnmcli device wifi list%b\n' "$CYAN" "$RESET" >&2
	printf '4. Connect to Wi-Fi: %bnmcli device wifi connect <SSID> password <PASSWORD>%b\n' "$CYAN" "$RESET" >&2
	printf '5. Verify connection: %bping -c 1 %s%b\n\n' "$CYAN" "$NETWORK_CHECK_HOST" "$RESET" >&2
	printf 'Example:\n' >&2
	printf '  %bnmcli device status%b\n' "$CYAN" "$RESET" >&2
	printf '  %bnmcli radio wifi on%b\n' "$CYAN" "$RESET" >&2
	printf '  %bnmcli device wifi list%b\n' "$CYAN" "$RESET" >&2
	printf '  %bnmcli device wifi connect MyWiFi password MyPassword%b\n\n' "$CYAN" "$RESET" >&2
}

# 启用并启动 NetworkManager。
start_networkmanager() {
	print_step "Starting NetworkManager"

	require_command systemctl

	systemctl enable NetworkManager > /dev/null
	systemctl start NetworkManager

	print_success "NetworkManager service is enabled and started"
}

# 检测联网情况，失败时提示 Wi-Fi 连接方法。
check_network() {
	print_step "Checking network connectivity"

	require_command ping

	if ping -c 1 -W "$NETWORK_CHECK_TIMEOUT" "$NETWORK_CHECK_HOST" &> /dev/null; then
		print_success "Network is connected"
		return
	fi

	print_error "Network is not connected"
	print_info "Connect to Wi-Fi with NetworkManager and rerun this script."
	if has_command nmcli; then
		print_wifi_help
	else
		print_warning "nmcli is not available in the current environment."
	fi
	exit 1
}

# 安装快照相关软件并配置 root/home 快照。
setup_snapper() {
	print_step "Configuring Snapper and GRUB snapshot integration"

	require_command pacman
	require_command systemctl

	if [[ ! -d /home ]]; then
		print_error "/home does not exist"
		exit 1
	fi

	print_info "Installing snapshot packages"
	pacman -S --needed --noconfirm snapper btrfs-assistant grub-btrfs inotify-tools
	require_command snapper

	if [[ ! -f /etc/snapper/configs/root ]]; then
		print_info "Creating Snapper config: root"
		snapper -c root create-config /
	else
		print_info "Snapper config already exists: root"
	fi

	if [[ ! -f /etc/snapper/configs/home ]]; then
		print_info "Creating Snapper config: home"
		snapper -c home create-config /home
	else
		print_info "Snapper config already exists: home"
	fi

	print_info "Enabling grub-btrfsd service"
	systemctl enable --now grub-btrfsd

	print_success "Snapper and GRUB snapshot integration configured"
}

# 允许用户跳过快照相关配置。
maybe_setup_snapper() {
	local choice

	print_step "Optional snapshot setup"
	while true; do
		read -rp "Install Snapper, btrfs-assistant, grub-btrfs and configure snapshots? [Y/n]: " choice
		case "$choice" in
			""|y|Y|yes|YES)
				setup_snapper
				break
				;;
			n|N|no|NO|skip|SKIP)
				print_info "Skipping snapshot setup"
				break
				;;
			*)
				print_error "Invalid choice: $choice"
				print_info "Please enter Y or n."
				;;
		esac
	done
}

# 启用 multilib 和 archlinuxcn 软件源，并安装 keyring。
setup_extra_repositories() {
	print_step "Configuring additional repositories"

	require_command pacman
	require_command sed
	require_command grep

	local pacman_conf
	pacman_conf="/etc/pacman.conf"

	if [[ ! -f "$pacman_conf" ]]; then
		print_error "Pacman configuration file not found: $pacman_conf"
		exit 1
	fi

	if grep -q '^\[multilib\]' "$pacman_conf"; then
		print_info "Enabling multilib repository"
		sed -i '/^#\[multilib\]$/,/^#Include = \/etc\/pacman.d\/mirrorlist$/ s/^#//' "$pacman_conf"
	else
		print_warning "multilib section not found in pacman.conf"
	fi

	if ! grep -q '^\[archlinuxcn\]' "$pacman_conf"; then
		print_info "Adding archlinuxcn repository"
		cat >> "$pacman_conf" <<EOF

[archlinuxcn]
Server = $ARCHLINUXCN_MIRROR
EOF
	else
		print_info "archlinuxcn repository already exists"
	fi

	print_info "Synchronizing package databases"
	pacman -Syy > /dev/null

	print_info "Installing archlinuxcn keyring"
	pacman -S --needed --noconfirm archlinuxcn-keyring

	print_success "Additional repositories configured"
}

# 允许用户跳过额外软件源配置。
maybe_setup_extra_repositories() {
	local choice

	print_step "Optional repository setup"
	while true; do
		read -rp "Enable multilib and archlinuxcn repositories? [Y/n]: " choice
		case "$choice" in
			""|y|Y|yes|YES)
				setup_extra_repositories
				break
				;;
			n|N|no|NO|skip|SKIP)
				print_info "Skipping additional repository setup"
				break
				;;
			*)
				print_error "Invalid choice: $choice"
				print_info "Please enter Y or n."
				;;
		esac
	done
}

# 检测是否已启用 multilib 软件源。
is_multilib_enabled() {
	grep -Eq '^\[multilib\]$' /etc/pacman.conf
}

# 检测是否已启用 archlinuxcn 软件源。
is_archlinuxcn_enabled() {
	grep -Eq '^\[archlinuxcn\]$' /etc/pacman.conf
}

# 根据已安装内核推断 NVIDIA 驱动包名。
detect_nvidia_kernel_package() {
	if pacman -Qq linux &> /dev/null; then
		printf '%s\n' 'nvidia-open'
		return
	fi
	if pacman -Qq linux-lts &> /dev/null; then
		printf '%s\n' 'nvidia-open-lts'
		return
	fi
	printf '%s\n' 'nvidia-open-dkms'
}

# 检测系统中的显卡厂商。
detect_gpu_vendors() {
	print_step "Detecting GPU vendors"

	require_command pacman

	if ! has_command lspci; then
		print_info "Installing pciutils for GPU detection"
		pacman -S --needed --noconfirm pciutils > /dev/null
	fi
	require_command lspci

	local gpu_info
	gpu_info=$(lspci | grep -Ei 'VGA compatible controller|3D controller|Display controller' || true)

	if [[ -z "$gpu_info" ]]; then
		print_warning "No supported GPU controller was detected"
		return
	fi

	if grep -qi 'intel' <<< "$gpu_info"; then
		GPU_VENDOR_INTEL=1
		print_info "Detected Intel GPU"
	fi
	if grep -Eqi 'amd|advanced micro devices|ati' <<< "$gpu_info"; then
		GPU_VENDOR_AMD=1
		print_info "Detected AMD GPU"
	fi
	if grep -qi 'nvidia' <<< "$gpu_info"; then
		GPU_VENDOR_NVIDIA=1
		print_info "Detected NVIDIA GPU"
	fi
}

# 安装对应显卡驱动。
install_gpu_drivers() {
	print_step "Installing GPU drivers"

	require_command pacman

	local packages=()
	local nvidia_package

	if (( GPU_VENDOR_INTEL )); then
		packages+=(mesa vulkan-intel intel-media-driver)
		if is_multilib_enabled; then
			packages+=(lib32-mesa lib32-vulkan-intel)
		fi
	fi

	if (( GPU_VENDOR_AMD )); then
		packages+=(mesa vulkan-radeon libva-mesa-driver xf86-video-amdgpu)
		if is_multilib_enabled; then
			packages+=(lib32-mesa lib32-vulkan-radeon)
		fi
	fi

	if (( GPU_VENDOR_NVIDIA )); then
		nvidia_package=$(detect_nvidia_kernel_package)
		packages+=("$nvidia_package" nvidia-utils nvidia-settings)
		if [[ "$nvidia_package" == "nvidia-open-dkms" ]]; then
			packages+=(dkms)
			if pacman -Qq linux-zen &> /dev/null; then
				packages+=(linux-zen-headers)
			fi
			if pacman -Qq linux-hardened &> /dev/null; then
				packages+=(linux-hardened-headers)
			fi
			if pacman -Qq linux &> /dev/null; then
				packages+=(linux-headers)
			fi
			if pacman -Qq linux-lts &> /dev/null; then
				packages+=(linux-lts-headers)
			fi
		fi
		if is_multilib_enabled; then
			packages+=(lib32-nvidia-utils)
		fi
	fi

	if [[ ${#packages[@]} -eq 0 ]]; then
		print_warning "No GPU driver packages need to be installed"
		return
	fi

	print_info "Installing GPU driver packages"
	pacman -S --needed --noconfirm "${packages[@]}"

	print_success "GPU drivers installed"
}

# 允许用户跳过显卡驱动安装。
maybe_install_gpu_drivers() {
	local choice

	print_step "Optional GPU driver setup"
	while true; do
		read -rp "Detect GPU and install matching drivers? [Y/n]: " choice
		case "$choice" in
			""|y|Y|yes|YES)
				detect_gpu_vendors
				install_gpu_drivers
				break
				;;
			n|N|no|NO|skip|SKIP)
				print_info "Skipping GPU driver installation"
				break
				;;
			*)
				print_error "Invalid choice: $choice"
				print_info "Please enter Y or n."
				;;
		esac
	done
}

# 安装电源管理与性能模式切换工具。
setup_power_management() {
	print_step "Installing power management tools"

	require_command pacman
	require_command systemctl

	print_info "Installing power-profiles-daemon"
	pacman -S --needed --noconfirm power-profiles-daemon

	print_info "Enabling power-profiles-daemon service"
	systemctl enable --now power-profiles-daemon

	print_success "Power management tools installed"
}

# 允许用户跳过电源管理工具安装。
maybe_setup_power_management() {
	local choice

	print_step "Optional power management setup"
	while true; do
		read -rp "Install power management and performance profile tools? [Y/n]: " choice
		case "$choice" in
			""|y|Y|yes|YES)
				setup_power_management
				break
				;;
			n|N|no|NO|skip|SKIP)
				print_info "Skipping power management setup"
				break
				;;
			*)
				print_error "Invalid choice: $choice"
				print_info "Please enter Y or n."
				;;
		esac
		done
}

# 安装蓝牙支持并启用服务。
setup_bluetooth() {
	print_step "Installing Bluetooth support"

	require_command pacman
	require_command systemctl

	print_info "Installing Bluetooth packages"
	pacman -S --needed --noconfirm bluez bluez-utils

	print_info "Enabling bluetooth service"
	systemctl enable --now bluetooth

	print_success "Bluetooth support installed"
}

# 允许用户跳过蓝牙安装。
maybe_setup_bluetooth() {
	local choice

	print_step "Optional Bluetooth setup"
	while true; do
		read -rp "Install Bluetooth support? [Y/n]: " choice
		case "$choice" in
			""|y|Y|yes|YES)
				setup_bluetooth
				break
				;;
			n|N|no|NO|skip|SKIP)
				print_info "Skipping Bluetooth setup"
				break
				;;
			*)
				print_error "Invalid choice: $choice"
				print_info "Please enter Y or n."
				;;
			esac
		done
}

# 安装 KDE Plasma 桌面及常用组件。
setup_kde() {
	print_step "Installing KDE Plasma"

	require_command pacman

	print_info "Installing KDE packages"
	pacman -S --needed --noconfirm "${KDE_PACKAGES[@]}"

	print_success "KDE Plasma packages installed"
}

# 允许用户跳过 KDE 安装。
maybe_setup_kde() {
	local choice

	print_step "Optional KDE setup"
	while true; do
		read -rp "Install KDE Plasma and related packages? [Y/n]: " choice
		case "$choice" in
			""|y|Y|yes|YES)
				setup_kde
				break
				;;
			n|N|no|NO|skip|SKIP)
				print_info "Skipping KDE setup"
				break
				;;
			*)
				print_error "Invalid choice: $choice"
				print_info "Please enter Y or n."
				;;
			esac
		done
}

# 安装并配置 zram。
setup_zram() {
	print_step "Configuring zram"

	require_command pacman
	require_command systemctl

	print_info "Installing zram-generator"
	pacman -S --needed --noconfirm zram-generator

	mkdir -p /etc/systemd
	cat > /etc/systemd/zram-generator.conf <<EOF
[zram0]
zram-size = ram
compression-algorithm = zstd
EOF

	print_info "Reloading systemd configuration"
	systemctl daemon-reload
	if systemctl list-unit-files systemd-zram-setup@.service &> /dev/null; then
		print_info "Starting zram device"
		systemctl start systemd-zram-setup@zram0
	fi

	print_success "zram configured"
}

# 允许用户跳过 zram 配置。
maybe_setup_zram() {
	local choice

	print_step "Optional zram setup"
	while true; do
		read -rp "Install and configure zram? [Y/n]: " choice
		case "$choice" in
			""|y|Y|yes|YES)
				setup_zram
				break
				;;
			n|N|no|NO|skip|SKIP)
				print_info "Skipping zram setup"
				break
				;;
			*)
				print_error "Invalid choice: $choice"
				print_info "Please enter Y or n."
				;;
			esac
		done
}

# 安装 yay AUR 助手。
setup_yay() {
	print_step "Installing yay"

	require_command pacman

	if ! is_archlinuxcn_enabled; then
		print_error "archlinuxcn repository is not enabled"
		print_info "Enable archlinuxcn first, then rerun this step."
		exit 1
	fi

	print_info "Installing yay from archlinuxcn"
	pacman -S --needed --noconfirm yay

	print_success "yay installed"
}

# 允许用户跳过 yay 安装。
maybe_setup_yay() {
	local choice

	print_step "Optional yay setup"
	while true; do
		read -rp "Install yay? This requires archlinuxcn to be enabled first. [Y/n]: " choice
		case "$choice" in
			""|y|Y|yes|YES)
				setup_yay
				break
				;;
			n|N|no|NO|skip|SKIP)
				print_info "Skipping yay installation"
				break
				;;
			*)
				print_error "Invalid choice: $choice"
				print_info "Please enter Y or n."
				;;
			esac
		done
}

# 提示用户完成图形登录前的手动步骤。
print_final_instructions() {
	print_step "Final steps"
	print_warning "Create a regular user before enabling the graphical login manager."
	print_info "Suggested commands:"
	print_info "  useradd -m -G wheel -s /bin/bash <username>"
	print_info "  passwd <username>"
	print_info "After creating the user, enable SDDM manually:"
	print_info "  systemctl enable --now sddm"
	print_info "This script will not start SDDM automatically because logging in as root is not recommended."
	print_info "You can exit this script now."
}

main() {
	require_root
	print_step "Starting post-installation process"

	# 禁用声卡节能。
	disable_audio_power_save
	# 启动 NetworkManager 并检测网络。
	start_networkmanager
	check_network
	# 可选配置额外软件源。
	maybe_setup_extra_repositories
	# 可选安装显卡驱动。
	maybe_install_gpu_drivers
	# 可选安装电源管理工具。
	maybe_setup_power_management
	# 可选安装蓝牙支持。
	maybe_setup_bluetooth
	# 可选安装 KDE 桌面环境。
	maybe_setup_kde
	# 可选安装 yay。
	maybe_setup_yay
	# 可选配置 zram。
	maybe_setup_zram
	# 可选配置快照功能。
	maybe_setup_snapper
	# 提示用户执行最后的手动步骤。
	print_final_instructions
}

main "$@"
