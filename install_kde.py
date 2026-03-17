import time
import os

from common import (
    attach_log_file,
    check_network,
    get_system_runner,
    owns_log_file,
    print_error,
    print_info,
    print_success,
    print_warning,
    run_cmd,
    setup_logging,
)


# ==============================
# 全局配置
# ==============================
LOG_FILE_PATH = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    f"install_kde_{time.strftime('%Y%m%d_%H%M%S')}.log",
)

NVIDIA_PACKAGES = [
    "nvidia",
    "nvidia-utils",
    "nvidia-settings",
    "lib32-nvidia-utils",
]

AMD_PACKAGES = [
    "mesa",
    "lib32-mesa",
    "xf86-video-amdgpu",
    "vulkan-radeon",
    "lib32-vulkan-radeon",
]

INTEL_PACKAGES = [
    "mesa",
    "lib32-mesa",
    "xf86-video-intel",
    "vulkan-intel",
    "lib32-vulkan-intel",
]

GPU_PACKAGES = {
    "nvidia": NVIDIA_PACKAGES,
    "amd": AMD_PACKAGES,
    "intel": INTEL_PACKAGES,
}

KDE_PACKAGES = [
    # 基于ffmpeg的多媒体支持
    "qt6-multimedia-ffmpeg",
    # 字体支持
    "noto-fonts-emoji",
    "noto-fonts",
    "ttf-cascadia-code",
    "adobe-source-han-sans-cn-fonts",
    "noto-fonts-cjk",
    # 整合包，包含一些基础组件和工具
    "plasma",
    # 文件搜索和索引
    "baloo-widgets",
    # 为 Dolphin 提供多种实用插件，包括 ISO 挂载功能
    "dolphin-plugins",
    # KDE 的多媒体缩略图生成器，支持多种视频格式
    "ffmpegthumbs",
    # 当应用程序占用所有 inotify 监视器时会发出警告并提示用户增加限额；这有助于用户理解为何 Baloo 等特定功能无法正常工作，并提供修复方案
    "kde-inotify-survey",
    # 提供pdf、epub、fb2等文档格式的缩略图支持
    "kdegraphics-thumbnailers",
    # SMB/CIFS 文件共享支持，允许用户通过 Dolphin 访问 Windows 网络共享
    "kdenetwork-filesharing",
    # 帮助中心
    "khelpcenter",
    # KDE 的图像格式插件，提供对各种图像格式的支持，包括一些特殊格式的缩略图生成
    "kimageformats",
    # 提供以root权限访问文件的功能
    "kio-admin",
    # 提供缩略图引擎及众多缩略图插件等功能
    "kio-extras",
    # 为非 KDE 应用程序提供对远程位置文件的透明访问
    "kio-fuse",
    # 密码管理工具
    "kwalletmanager",
    # 指纹识别驱动和服务
    "fprintd",
    # 提供正确的混合/多 GPU 检测功能
    "switcheroo-control",
    # KDE 的终端模拟器，提供与 KDE 桌面环境的良好集成
    "konsole",
    # 应用程序浏览文件支持
    "kdialog",
    # Dolphin解压框架
    "ark",
    # 压缩格式支持
    "7zip",
    "unarchiver",
    "unzip",
    # KDE Connect
    "kdeconnect",
    # 输入法
    "fcitx5",
    "fcitx5-chinese-addons",
    "fcitx5-configtool",
    "fcitx5-gtk",
    "fcitx5-qt",
]


def get_gpu_vendor():
    result = run_cmd(["lspci", "-nnk"], capture_output=True)
    if result is None:
        return []

    output = result.stdout
    keywork = ["VGA compatible controller", "3D controller", "Display controller"]
    vendors = []
    for line in output.splitlines():
        if any(keyword in line for keyword in keywork):
            if "NVIDIA" in line:
                vendors.append("nvidia")
            elif "AMD" in line or "ATI" in line:
                vendors.append("amd")
            elif "Intel" in line:
                vendors.append("intel")

    return list(dict.fromkeys(vendors))


def install_gpu_drivers(use_chroot=False):
    system_runner = get_system_runner(use_chroot)
    vendors = get_gpu_vendor()
    if not vendors:
        print_warning("No supported GPU detected. Skipping GPU driver installation.")
        return True

    package_list = []
    for vendor in vendors:
        package_list.extend(GPU_PACKAGES[vendor])

    package_list = list(dict.fromkeys(package_list))
    print_info(f"Detected GPU vendors: {', '.join(vendors)}. Installing GPU drivers...")
    return system_runner(
        ["pacman", "-S", "--noconfirm"] + package_list,
        "Failed to install GPU drivers",
    ) is not None


def install_kde(use_chroot=False):
    system_runner = get_system_runner(use_chroot)
    print_info("Installing KDE Plasma desktop environment and related packages...")
    if system_runner(
        ["pacman", "-S", "--noconfirm"] + KDE_PACKAGES,
        "Failed to install KDE Plasma and related packages",
    ) is None:
        return False

    if system_runner(["systemctl", "enable", "sddm"], "Failed to enable SDDM") is None:
        return False

    return True


def main(use_chroot=False):
    if owns_log_file():
        print_info(f"Installer log: {LOG_FILE_PATH}")

    if not check_network("mirrors.ustc.edu.cn"):
        print_error("Network is not connected. Please check your connection and try again.")
        return False

    if not install_gpu_drivers(use_chroot=use_chroot):
        return False

    print_success("GPU driver installation completed.")

    if not install_kde(use_chroot=use_chroot):
        return False

    print_success("KDE Plasma installation completed.")
    return True

if __name__ == "__main__":
    setup_logging(LOG_FILE_PATH)
    main()
