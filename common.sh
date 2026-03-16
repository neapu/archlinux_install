#!/bin/bash

# === 颜色定义 ===
BOLD='\033[1m'
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
CYAN='\033[36m'
RESET='\033[0m'

# === 公共函数 ===
print_step() {
    printf '\n%b== %s ==%b\n' "$BOLD$BLUE" "$1" "$RESET"
}

print_error() {
    printf '%bError: %s%b\n' "$BOLD$RED" "$1" "$RESET" >&2
}

print_success() {
    printf '%b%s%b\n' "$BOLD$GREEN" "$1" "$RESET"
}

print_info() {
    printf '%b%s%b\n' "$BOLD$CYAN" "$1" "$RESET"
}

print_warning() {
    printf '%bWarning: %s%b\n' "$BOLD$YELLOW" "$1" "$RESET" >&2
}

has_command() {
    command -v "$1" &> /dev/null
}

require_command() {
    if ! has_command "$1"; then
        print_error "$1 is not available."
        exit 1
    fi
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root."
        exit 1
    fi
    print_success "Running as root user."
}