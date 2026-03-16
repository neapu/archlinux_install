# Arch Linux Install Scripts

This repository contains a set of highly customized Arch Linux installation scripts created for personal use.

These scripts are not intended to be a general-purpose installer. They reflect one specific setup preference, including package choices, filesystem layout, Secure Boot workflow, mirrors, locale settings, timezone, desktop environment selection, and post-install defaults.

## Status

Use this repository as a reference or starting point, not as a drop-in solution.

The scripts assume a UEFI-based Arch installation flow and include destructive disk operations. Review everything carefully before running them on any machine.

## Scope

The repository currently includes:

- `fast_install.sh`: prepares disks, installs the base system, and copies the remaining scripts into the target system.
- `chroot_install.sh`: runs inside `arch-chroot` to configure the new system, install GRUB, and prepare Secure Boot signing.
- `after_install.sh`: applies post-install preferences such as repositories, drivers, desktop packages, and optional services.
- `common.sh`: shared helper functions for logging and root/command checks.

## Important Notes

- This is a personal workflow with opinionated defaults.
- It may not match your hardware, boot strategy, regional mirror preferences, or package selection.
- It can erase the selected disk.
- It has only been designed around the author's own installation process.
- You should read and modify the scripts before using them.

## Intended Use

This repository is published mainly for transparency, backup, and reference.

If you want a reusable public installer, you should treat these scripts as raw material and refactor them for broader compatibility, configurability, and safety checks.