#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/common.sh"

TIMEZONE="Asia/Shanghai"
DEFAULT_LOCALE="en_US.UTF-8"
HOSTNAME="neapu-arch"
GRUB_EFI_DIRECTORY="/efi"
GRUB_BOOTLOADER_ID="ArchLinux"
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

    if [[ ! -d "$GRUB_EFI_DIRECTORY" ]]; then
        print_error "EFI mount point not found: $GRUB_EFI_DIRECTORY"
        exit 1
    fi

    grub-install --target=x86_64-efi --efi-directory="$GRUB_EFI_DIRECTORY" --boot-directory="$GRUB_EFI_DIRECTORY" --bootloader-id="$GRUB_BOOTLOADER_ID"

    if [[ "$GRUB_EFI_DIRECTORY" == "/efi"]]; then
        ln -s /efi/grub /boot/grub
    fi

    grub-mkconfig -o /boot/grub/grub.cfg

    print_success "GRUB installed in UEFI mode"
}

# 提示用户完成密码设置并继续后续步骤。
print_final_instructions() {
    print_step "Final steps"
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