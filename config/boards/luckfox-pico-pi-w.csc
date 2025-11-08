# Rockchip RV1106 single core 128-256MB SoC 1x100MBe EMMC 4xUSB2 1xmPCIe
BOARD_NAME="Luckfox Pico Pi W"
BOARDFAMILY="rockchip-rv1106"
BOOTCONFIG="luckfox_rv1106_uboot_defconfig"
BOARD_MAINTAINER="vidplace7"
KERNEL_TARGET="vendor"
BOOT_FDT_FILE="rv1106g-luckfox-pico-pi-w.dtb"
IMAGE_PARTITION_TABLE="gpt"
BOOT_SOC="rv1106"
enable_extension "radxa-aic8800"
AIC8800_TYPE="sdio"

# Board only has 128-256MB RAM; use 'lowmem' extension to optimize for this.
enable_extension "lowmem"
