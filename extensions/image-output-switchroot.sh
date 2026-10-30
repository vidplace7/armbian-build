#!/usr/bin/env bash
# @description Repackages the finished image as a hekate/switchroot SD card archive for the Nintendo Switch: `${version}.zip`, holding the hekate boot entry with its Armbian icon and boot logo, the two firmware blobs hekate loads, and the root filesystem split into 4092 MiB parts. Drops the `.img`, which does not boot on this board. Enabled from `config/boards/nintendo-switch.csc`.

#
# SPDX-License-Identifier: GPL-2.0
#
# This file is a part of the Armbian Build Framework
# https://github.com/armbian/build/
#
# Extension: image-output-switchroot
#
# An .img written to a card does nothing on a Switch. The card is read by
# hekate, which wants a layout of its own:
#
#   bootloader/ini/L4T-<name>.ini      the boot entry
#   switchroot/<name>/bl31.bin         ATF
#   switchroot/<name>/bl33.bin         U-Boot
#   switchroot/<name>/icon_hue.bmp     the Nyx launcher icon
#   switchroot/<name>/bootlogo.bmp     the logo hekate shows while L4T starts
#   switchroot/install/l4t.00 ...      the root filesystem, in parts
#
# Three facts from hekate's source shape this. In bootloader/l4t/l4t.c, hekate
# loads exactly bl31.bin and bl33.bin out of the entry's boot_prefixes directory,
# both mandatory, and puts bl33 at 0xAA000000 - this U-Boot's CONFIG_TEXT_BASE.
# No kernel, initramfs or device tree is read there: with SRC_EXTLINUX=yes those
# come from /boot/extlinux/extlinux.conf inside the root filesystem, so nothing
# from the switchroot bootstack is needed. In nyx/.../gui_tools_partition_manager.c,
# the installer reads switchroot/install/l4t.NN, two zero-padded decimal digits
# from 00, and refuses the image unless every part but the last is a multiple of
# 4 MiB. Hence 4092 MiB: the largest 4 MiB multiple that still fits a FAT32 file.
#
# The parts are the bare filesystem - no partition table, no padding. They are
# read straight off the root partition's loop device, so there are no offsets to
# compute here; prepare_partitions() already placed it and ROOT_PART_UUID names it.
#
# SWITCHROOT_UART_PORT sets the hekate serial log. 0 disables it. 2 is the right
# Joy-Con rail, 3 the left. U-Boot prints on the right rail either way. Both rails
# are 1.8V. A 3.3V adapter damages the Tegra pads.
#
# At 1-3 hekate also patches the BL33 device tree, at offsets taken from
# switchroot's own U-Boot. This U-Boot carries a Linux image header, so hekate
# reads the image size at offset 0x10 in place of a device tree offset. The magic
# test then fails and hekate writes nothing.
#
# Tunables: SWITCHROOT_ENTRY_NAME, SWITCHROOT_ENTRY_TITLE, SWITCHROOT_ENTRY_ID,
# SWITCHROOT_UART_PORT, SWITCHROOT_CHUNK_BYTES, SWITCHROOT_ZIP_LEVEL,
# SWITCHROOT_KEEP_IMAGE.
#

function extension_prepare_config__switchroot_output() {
	[[ "${BOARD}" == "nintendo-switch" ]] ||
		exit_with_error "${EXTENSION} only supports the Nintendo Switch" "${BOARD}"
	# The archive ships a filesystem, so there has to be one.
	[[ "${ROOTFS_TYPE}" != "nfs" ]] ||
		exit_with_error "${EXTENSION} does not support an NFS root" "ROOTFS_TYPE=nfs"
	# hekate's installer writes one partition, so p1 must be the root. These are
	# what prepare_partitions() would put in front of it.
	[[ -z "${BOOTFS_TYPE}" ]] ||
		exit_with_error "${EXTENSION} needs the root on a single partition" "BOOTFS_TYPE=${BOOTFS_TYPE}"
	[[ "${UEFISIZE:-0}" == "0" && "${BIOSSIZE:-0}" == "0" ]] ||
		exit_with_error "${EXTENSION} needs the root on a single partition" "UEFISIZE=${UEFISIZE:-0} BIOSSIZE=${BIOSSIZE:-0}"
	[[ "${CRYPTROOT_ENABLE:-no}" != "yes" ]] ||
		exit_with_error "${EXTENSION} does not support an encrypted root" "CRYPTROOT_ENABLE=yes"
	# U-Boot reads extlinux.conf out of the root filesystem; there is no boot.scr path.
	[[ "${SRC_EXTLINUX}" == "yes" ]] ||
		exit_with_error "${EXTENSION} needs extlinux" "SRC_EXTLINUX=${SRC_EXTLINUX:-no}"

	declare -g SWITCHROOT_ENTRY_NAME="${SWITCHROOT_ENTRY_NAME:-"armbian-${RELEASE}"}"
	declare -g SWITCHROOT_ENTRY_TITLE="${SWITCHROOT_ENTRY_TITLE:-"Armbian ${RELEASE^}"}"
	declare -g SWITCHROOT_ENTRY_ID="${SWITCHROOT_ENTRY_ID:-"SWR-ARM"}"
	declare -g SWITCHROOT_UART_PORT="${SWITCHROOT_UART_PORT:-0}"
	declare -g SWITCHROOT_CHUNK_BYTES="${SWITCHROOT_CHUNK_BYTES:-4290772992}" # 4092 MiB
	declare -g SWITCHROOT_ZIP_LEVEL="${SWITCHROOT_ZIP_LEVEL:-6}"
	declare -g SWITCHROOT_KEEP_IMAGE="${SWITCHROOT_KEEP_IMAGE:-no}"

	# hekate muxes UART-D at 4. That port is the Bluetooth link on this board.
	((SWITCHROOT_UART_PORT >= 0 && SWITCHROOT_UART_PORT <= 3)) ||
		exit_with_error "${EXTENSION}: uart_port must be 0-3" "${SWITCHROOT_UART_PORT}"

	declare -i align=$((4 * 1024 * 1024))
	((SWITCHROOT_CHUNK_BYTES > 0 && SWITCHROOT_CHUNK_BYTES % align == 0)) ||
		exit_with_error "${EXTENSION}: part size must be a multiple of 4 MiB" "${SWITCHROOT_CHUNK_BYTES}"

	# The archive is already compressed. Leave it alone, but still checksum it.
	declare -g SKIP_COMPRESSING="${SKIP_COMPRESSING:+"${SKIP_COMPRESSING},"}zip"

	display_alert "${EXTENSION}" "hekate archive for ${BOARD}: switchroot/${SWITCHROOT_ENTRY_NAME}" "info"
}

# The u-boot deb is installed in the image, so both blobs are already here: no
# second mount, and no guessing which artifact hash in output/debs is current.
# Not named after ${version}, which the finalization globs would pick up.
function pre_umount_final_image__800_switchroot_boot_entry() {
	declare -g SWITCHROOT_STAGING
	SWITCHROOT_STAGING="$(mktemp -d -p "${DESTIMG}" "image-output-switchroot.XXXXXX")"

	declare -a uboot_dirs=("${MOUNT}"/usr/lib/linux-u-boot-*)
	[[ -d "${uboot_dirs[0]}" ]] ||
		exit_with_error "${EXTENSION}: no u-boot package in the image" "${MOUNT}/usr/lib/linux-u-boot-*"

	# bl33 is hekate's name for the second-stage bootloader. The artifact may
	# already carry that name, depending on UBOOT_TARGET_MAP.
	declare bl33_src="${uboot_dirs[0]}/bl33.bin"
	[[ -f "${bl33_src}" ]] || bl33_src="${uboot_dirs[0]}/u-boot.bin"
	[[ -f "${bl33_src}" ]] ||
		exit_with_error "${EXTENSION}: no u-boot binary in the image" "${uboot_dirs[0]}"
	[[ -f "${uboot_dirs[0]}/bl31.bin" ]] ||
		exit_with_error "${EXTENSION}: no bl31.bin in the image; is ATF in UBOOT_TARGET_MAP?" "${uboot_dirs[0]}"

	declare boot_dir="${SWITCHROOT_STAGING}/switchroot/${SWITCHROOT_ENTRY_NAME}"
	declare -a cmd
	cmd=(mkdir -p "${boot_dir}" "${SWITCHROOT_STAGING}/bootloader/ini") && run_host_command_logged "${cmd[*]@Q}"
	cmd=(cp -v "${bl33_src}" "${boot_dir}/bl33.bin") && run_host_command_logged "${cmd[*]@Q}"
	cmd=(cp -v "${uboot_dirs[0]}/bl31.bin" "${boot_dir}/bl31.bin") && run_host_command_logged "${cmd[*]@Q}"

	# Both are 32-bit BMPs; hekate rejects 24-bit. Nyx tints an icon named *_hue.bmp
	# in the theme color. The panel is portrait, so the logo is turned 90° CCW.
	# hekate centers a logo smaller than 720x1280 on the color of its first pixel.
	cmd=(cp -v "${SRC}/packages/blobs/splash/armbian-hekate-icon_hue.bmp" "${boot_dir}/icon_hue.bmp") && run_host_command_logged "${cmd[*]@Q}"
	cmd=(cp -v "${SRC}/packages/blobs/splash/armbian-hekate-bootlogo.bmp" "${boot_dir}/bootlogo.bmp") && run_host_command_logged "${cmd[*]@Q}"

	# Never use # to comment a key in here; hekate reads it as part of the value.
	declare ini_file="${SWITCHROOT_STAGING}/bootloader/ini/L4T-${SWITCHROOT_ENTRY_NAME}.ini"
	cat <<- SWITCHROOT_INI > "${ini_file}"
		[${SWITCHROOT_ENTRY_TITLE}]
		l4t=1
		boot_prefixes=/switchroot/${SWITCHROOT_ENTRY_NAME}/
		id=${SWITCHROOT_ENTRY_ID}
		r2p_action=self
		icon=switchroot/${SWITCHROOT_ENTRY_NAME}/icon_hue.bmp
		logopath=switchroot/${SWITCHROOT_ENTRY_NAME}/bootlogo.bmp
	SWITCHROOT_INI
	if ((${SWITCHROOT_UART_PORT:-0})); then
		echo "uart_port=${SWITCHROOT_UART_PORT}" >> "${ini_file}"
	fi
	display_alert "${EXTENSION}" "hekate boot entry:" "info"
	run_host_command_logged cat "${ini_file}"
}

# The loop device is still attached here and the filesystem is unmounted, so the
# root partition can be read as a device. That is the whole reason this is not in
# post_build_image: no partition table to re-parse, no offset arithmetic.
function post_umount_final_image__810_switchroot_split_rootfs() {
	[[ -d "${SWITCHROOT_STAGING}" ]] ||
		exit_with_error "${EXTENSION}: boot entry was not staged" "${SWITCHROOT_STAGING:-unset}"

	declare root_device="${LOOP}p1"
	check_loop_device "${root_device}" # handles CONTAINER_COMPAT device nodes

	# Identity, not just existence: prove p1 is the filesystem prepare_partitions()
	# made, before shipping eight gigabytes of it.
	declare root_device_uuid
	root_device_uuid="$(blkid -s UUID -o value "${root_device}" || true)"
	[[ "${root_device_uuid}" == "${ROOT_PART_UUID}" ]] ||
		exit_with_error "${EXTENSION}: ${root_device} is not the root filesystem" \
			"${root_device_uuid:-none} != ${ROOT_PART_UUID}"

	declare -i root_bytes chunk="${SWITCHROOT_CHUNK_BYTES}"
	root_bytes="$(blockdev --getsize64 "${root_device}")"

	declare install_dir="${SWITCHROOT_STAGING}/switchroot/install"
	declare -a cmd
	cmd=(mkdir -p "${install_dir}") && run_host_command_logged "${cmd[*]@Q}"

	display_alert "${EXTENSION}" \
		"splitting $((root_bytes / 1024 / 1024))MB root filesystem into $(((root_bytes + chunk - 1) / chunk)) part(s)" "info"
	cmd=(dd "if=${root_device}" bs=4M status=none) && run_host_command_logged "${cmd[*]@Q}" "|" \
		"split --bytes=${chunk} --numeric-suffixes=0 --suffix-length=2 - ${install_dir@Q}/l4t."

	# dd runs under pipefail, so a short read already fails the build. This is for
	# the rest: a truncated write, a full disk.
	declare -i written=0
	declare part_file
	for part_file in "${install_dir}"/l4t.*; do
		written=$((written + $(stat -c %s "${part_file}")))
	done
	((written == root_bytes)) ||
		exit_with_error "${EXTENSION}: split wrote ${written} bytes, expected ${root_bytes}" "${install_dir}"
}

function post_build_image__900_switchroot_archive() {
	[[ -z "${version}" ]] && exit_with_error "version is not set"
	[[ -d "${SWITCHROOT_STAGING}" ]] ||
		exit_with_error "${EXTENSION}: nothing staged to archive" "${SWITCHROOT_STAGING:-unset}"

	# Safe to drop the .img first: its only content of interest is the root
	# filesystem, which is already in the staged parts and was verified there.
	# Keeps the peak at two image-sized copies rather than three.
	declare image_file="${DESTIMG}/${version}.img"
	if [[ "${SWITCHROOT_KEEP_IMAGE}" == "yes" ]]; then
		display_alert "${EXTENSION}" "keeping ${version}.img as well" "info"
	elif [[ -n "${CARD_DEVICE:-}" ]]; then
		# The write to the card happens right after this hook and is guarded by
		# the .img existing. It will not boot, but that is the user's call.
		display_alert "${EXTENSION}" "keeping .img, CARD_DEVICE=${CARD_DEVICE} is set" "info"
	elif [[ -f "${image_file}" ]]; then
		display_alert "${EXTENSION}" "root filesystem is in the archive; dropping the .img" "info"
		run_host_command_logged rm -vf "${image_file}"
	fi

	# bootloader/ and switchroot/ sit at the archive root, so this unpacks straight
	# onto the card beside whatever hekate already has there.
	declare archive="${DESTIMG}/${version}.zip"
	display_alert "${EXTENSION}" "building $(basename "${archive}")" "info"
	cd "${SWITCHROOT_STAGING}" || exit_with_error "Could not cd to ${SWITCHROOT_STAGING}"
	declare -a cmd=(zip -r "-${SWITCHROOT_ZIP_LEVEL}" "${archive}" bootloader switchroot)
	run_host_command_logged "${cmd[*]@Q}"
	cd "${SRC}" || exit_with_error "Could not cd to ${SRC}"

	[[ -f "${archive}" ]] || exit_with_error "${EXTENSION}: archive was not produced" "${archive}"
	run_host_command_logged rm -rf "${SWITCHROOT_STAGING}"

	# The build only fingerprints when an .img survives, and usually one does not.
	[[ -f "${DESTIMG}/${version}.txt" ]] || fingerprint_image "${DESTIMG}/${version}.txt" "${version}"

	display_alert "${EXTENSION}" \
		"$(basename "${archive}") is $(($(stat -c %s "${archive}") / 1024 / 1024))MB" "info"
	display_alert "${EXTENSION}" \
		"unpack onto the SD card, then install it from hekate: Tools, Linux Installer" "info"

	return 0
}
