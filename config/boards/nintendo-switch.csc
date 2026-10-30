# Nintendo Switch Nvidia Tegra X1 (t210)
BOARD_VENDOR="nintendo"
BOARD_NAME="nintendo-switch"
BOARD_MAINTAINER="vidplace7"
BOARDFAMILY="nvidia-t210"
INTRODUCED="2017"
BOOTCONFIG="nintendo-switch_defconfig"
KERNEL_TARGET="edge"
KERNEL_TEST_TARGET="edge"
FULL_DESKTOP="yes"
PACKAGE_LIST_BOARD="rfkill bluetooth bluez bluez-tools alsa-utils alsa-ucm-conf"

declare -g DESKTOP_AUTOLOGIN="yes"

# The .img does not boot here. hekate reads an SD card layout of its own.
enable_extension "image-output-switchroot"

BOOT_FDT_FILE="nvidia/tegra210-nintendo-switch.dtb"
# The portrait panel is mounted left side up. The panel driver does not report
# this, so video= tells plymouth and KWin. simpledrm starts first and needs fbcon=.
# tty1 is last, so /dev/console is the panel. UART-A needs a modded cable.
SRC_CMDLINE="rootwait video=DSI-1:panel_orientation=left_side_up fbcon=rotate:3 console=ttyS0,115200n8 console=tty1"

# The family is sourced after this file, so override from the hook, not here.
function post_family_config__nintendo_switch_hekate_payloads() {
	# hekate reads bl31.bin and bl33.bin from the L4T boot directory. Nothing else.
	declare -g UBOOT_TARGET_MAP=";;u-boot.bin:bl33.bin bl31.bin"

	function write_uboot_platform() {
		# U-Boot is not on the boot device. hekate loads bl33.bin from the
		# FAT partition of the SD card. Copy it there by hand.
		echo "Copy bl31.bin and bl33.bin to the L4T boot directory on the SD card."
	}
}

# No firmware repo has these files. linux-firmware's brcmfmac4356-pcie.bin is
# built for the A2 ROM, but the Switch has an A3 chip. The NVRAM holds the
# board calibration. Without the BT patch, large BT packets get lost.
# brcmfmac and btbcm look for the board-specific names first.
# Source: https://gist.github.com/kiding/34916dd163d700098980ec0b8901a033
function post_family_tweaks_bsp__nintendo_switch_wifi_bt_firmware() {
	display_alert "$BOARD" "Installing WiFi firmware, NVRAM and BT patch" "info"
	run_host_command_logged mkdir -p "${destination}/lib/firmware/brcm"
	run_host_command_logged cp -v "${SRC}"/packages/bsp/nintendo-switch/brcm/* "${destination}/lib/firmware/brcm/"
}

function post_family_tweaks_bsp__nintendo_switch_brcmfmac_no_p2p() {
	display_alert "$BOARD" "Disabling brcmfmac P2P" "info"
	# The firmware reports P2P, but never creates the P2P device: boot logs a timeout.
	mkdir -p "${destination}"/etc/modprobe.d
	echo "options brcmfmac feature_disable=0x10" > "${destination}"/etc/modprobe.d/brcmfmac-nintendo-switch.conf
}

# alsa-ucm-conf has no profile for this card. Without one, the AHUB crossbar
# stays at "None" and no audio gets to the codec. The profile routes ADMAIF1 to I2S1.
# Source: https://github.com/mojyack/gentoo-note/tree/main/misc/nx/static/usr/share/alsa/ucm2
function post_family_tweaks_bsp__nintendo_switch_alsa_ucm() {
	display_alert "$BOARD" "Installing ALSA UCM profile" "info"
	declare ucm2="${destination}/usr/share/alsa/ucm2"
	declare card_conf="${ucm2}/conf.d/tegra-ape/Nintendo Switch APE.conf"
	run_host_command_logged mkdir -p "${ucm2}/Tegra/rt5640" "${ucm2}/conf.d/tegra-ape"
	run_host_command_logged cp -v "${SRC}"/packages/bsp/nintendo-switch/ucm2/Tegra/rt5640/*.conf "${ucm2}/Tegra/rt5640/"
	# alsa-lib reads conf.d/<card driver>/<card long name>.conf. The DT sets the long name.
	run_host_command_logged ln -sfv ../../Tegra/rt5640/Nintendo-Switch.conf "${card_conf@Q}"
}
