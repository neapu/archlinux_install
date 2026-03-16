#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/common.sh"

TIMEZONE="Asia/Shanghai"
DEFAULT_LOCALE="en_US.UTF-8"
HOSTNAME="neapu-arch"
GRUB_EFI_DIRECTORY="/efi"
GRUB_BOOTLOADER_ID="ArchLinux"
SECURE_BOOT_KEY_DIRECTORY="/var/lib/sbctl/keys"
LOCALE_LIST=(
    en_US.UTF-8
    zh_CN.UTF-8
)

# 设置系统时区并同步硬件时钟。
set_timezone() {
    print_step "Setting timezone"

    require_command ln
    require_command hwclock

    if [[ ! -e "/usr/share/zoneinfo/$TIMEZONE" ]]; then
        print_error "Timezone file not found: /usr/share/zoneinfo/$TIMEZONE"
        exit 1
    fi

    ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
    hwclock --systohc

    print_success "Timezone set to $TIMEZONE"
}

# 启用所需语言并设置默认语言。
configure_locale() {
    print_step "Configuring locale"

    require_command locale-gen

    local locale_gen_file locale_name
    locale_gen_file="/etc/locale.gen"

    if [[ ! -f "$locale_gen_file" ]]; then
        print_error "Locale configuration file not found: $locale_gen_file"
        exit 1
    fi

    for locale_name in "${LOCALE_LIST[@]}"; do
        sed -i "s/^#\(${locale_name} UTF-8\)/\1/" "$locale_gen_file"
    done

    locale-gen
    printf 'LANG=%s\n' "$DEFAULT_LOCALE" > /etc/locale.conf

    print_success "Locale configured. Default locale: $DEFAULT_LOCALE"
}

# 配置主机名和本地域名解析。
configure_hostname() {
    print_step "Configuring hostname"

    printf '%s\n' "$HOSTNAME" > /etc/hostname
    cat > /etc/hosts <<EOF
127.0.0.1 localhost
::1 localhost
127.0.1.1 ${HOSTNAME}.localdomain ${HOSTNAME}
EOF

    print_success "Hostname set to $HOSTNAME"
}

# 以 UEFI 模式安装并生成 GRUB 配置。
install_grub_efi() {
    print_step "Installing GRUB for UEFI"

    require_command grub-install
    require_command grub-mkconfig
    require_command sbctl
    require_command mkdir
    require_command rm
    require_command ln

    if [[ ! -d "$GRUB_EFI_DIRECTORY" ]]; then
        print_error "EFI mount point not found: $GRUB_EFI_DIRECTORY"
        exit 1
    fi

    grub-install --target=x86_64-efi --efi-directory="$GRUB_EFI_DIRECTORY" --boot-directory="$GRUB_EFI_DIRECTORY" --bootloader-id="$GRUB_BOOTLOADER_ID" --disable-shim-lock

    mkdir -p /boot "$GRUB_EFI_DIRECTORY/grub"
    if [[ -e /boot/grub && ! -L /boot/grub ]]; then
        rm -rf /boot/grub
    fi
    ln -sfn "$GRUB_EFI_DIRECTORY/grub" /boot/grub

    grub-mkconfig -o /boot/grub/grub.cfg

    prepare_secure_boot_keys
    sign_secure_boot_artifacts

    print_success "GRUB installed in UEFI mode with Secure Boot support"
}

# 初始化 Secure Boot 密钥，并在固件处于 setup mode 时自动注册。
prepare_secure_boot_keys() {
    print_step "Preparing Secure Boot keys"

    require_command sbctl
    require_command grep

    local status_output

    if [[ ! -d "$SECURE_BOOT_KEY_DIRECTORY" ]]; then
        sbctl create-keys
        print_success "Secure Boot keys created"
    else
        print_info "Secure Boot keys already exist"
    fi

    status_output="$(sbctl status 2>/dev/null || true)"
    if printf '%s\n' "$status_output" | grep -Eq 'Setup Mode:.*Enabled'; then
        print_info "Firmware is in setup mode. Enrolling Secure Boot keys"
        sbctl enroll-keys -m
        print_success "Secure Boot keys enrolled"
        return
    fi

    print_warning "Firmware is not in setup mode. Secure Boot keys were created but could not be enrolled automatically."
    print_info "If you want to enable Secure Boot, switch firmware to setup mode and run: sbctl enroll-keys -m"
}

# 对 GRUB EFI 文件和内核镜像进行签名，并生成 fallback 启动文件。
sign_secure_boot_artifacts() {
    print_step "Signing Secure Boot artifacts"

    require_command sbctl
    require_command cp

    local bootloader_path fallback_path kernel_path signed_kernel_count
    bootloader_path="$GRUB_EFI_DIRECTORY/EFI/$GRUB_BOOTLOADER_ID/grubx64.efi"
    fallback_path="$GRUB_EFI_DIRECTORY/EFI/BOOT/BOOTX64.EFI"
    signed_kernel_count=0

    if [[ ! -f "$bootloader_path" ]]; then
        print_error "GRUB EFI binary not found: $bootloader_path"
        exit 1
    fi

    mkdir -p "$(dirname "$fallback_path")"
    cp -f "$bootloader_path" "$fallback_path"

    sbctl sign -s "$bootloader_path"
    sbctl sign -s "$fallback_path"

    shopt -s nullglob
    for kernel_path in /boot/vmlinuz-*; do
        sbctl sign -s "$kernel_path"
        signed_kernel_count=$((signed_kernel_count + 1))
    done
    shopt -u nullglob

    if [[ $signed_kernel_count -eq 0 ]]; then
        print_warning "No kernel image was found under /boot for signing."
    fi

    print_success "Signed GRUB EFI binaries and $signed_kernel_count kernel image(s)"
}

# 提示用户完成密码设置并继续后续步骤。
print_final_instructions() {
    print_step "Final steps"
    print_info "Check Secure Boot state with: sbctl status"
    print_info "If keys were not enrolled automatically, use firmware setup mode and run: sbctl enroll-keys -m"
    print_warning "Set the root password now by running: passwd"
    print_info "After that, exit chroot by running: exit"
    print_info "Then reboot the system."
    print_info "After logging into the new system, run: /root/after_install.sh"
}

main() {
    require_root
    print_step "Starting chroot installation process"

    # 配置时区。
    set_timezone
    # 配置系统语言。
    configure_locale
    # 配置主机名。
    configure_hostname
    # 安装 UEFI 模式的 GRUB。
    install_grub_efi
    # 提示用户完成后续手动步骤。
    print_final_instructions

}

main "$@"