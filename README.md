# Scripts for building opnsense (https://opnsense.org) focused on ARM64 targets

These files aim for the FriendlyELEC **NanoPi R5C** (RK3568B2, 2x RTL8125B 2.5GbE). Can be used for other ARM64 systems, and also for building images for AMD64 if desired as well. Legacy conf files for NanoPi R5S and Orange Pi 5 Plus are kept in `arm64-opnsense-build/opnsense-confs/` but are no longer wired into the scripts by default.

Based on OPNsense 26.7 "Xenial Xenops" (FreeBSD 15.1). On FreeBSD 15.1 the stock `net/realtek-re-kmod` vendor driver works with the RTL8125B NICs, so the old pinning to Realtek driver 1.98 is gone.

## Boot / storage notes for the R5C

- There is no `sysutils/u-boot-nanopi-r5c` port in the FreeBSD ports tree (only r5s), so `1.1-fetch_update.sh` creates a local slave port of `sysutils/u-boot-master` (see `arm64-opnsense-build/u-boot-nanopi-r5c/`) and builds it from the ports tree.
- There is no prebuilt EDK2/UEFI image for the R5C (quartz64_uefi does not ship one), so the images boot via U-Boot.
- The RK3568 boot ROM loads the SPL from **eMMC first, then sdcard**. The same image can be written to sdcard or, with FreeBSD 15.1, directly to the onboard eMMC (8/32 GB) to run the system from it — e.g. boot once from sdcard and `dd` the image onto `/dev/mmcsd1` (check which mmcsd device is the eMMC first), or use FriendlyELEC's eflasher from Linux.
- The R5C M.2 socket is Key-E (PCIe 2.1 x1 + USB 2.0), intended for WiFi/BT modules, but an NVMe drive works through a Key-E to M-key adapter (PCIe 2.1 x1 caps it at roughly 500 MB/s). The device tree enables the `pcie2x1` node and the kernel (`SMP-ARM` -> `GENERIC` -> `std.dev`) has `nvme`/`nda`, so FreeBSD sees the drive. The stock `nanopi-r5c-rk3568_defconfig` lacks NVMe though, so the local u-boot port merges `files/nvme_fragment` (`CONFIG_NVME_PCI`, `CONFIG_CMD_NVME`) to make u-boot expose the drive as an EFI block device.

### Running the system from NVMe

The boot ROM cannot load the SPL from NVMe, so eMMC (or sdcard) keeps only the u-boot blobs while the whole image lives on the NVMe:

```
# whole image onto the NVMe (from a system booted off sdcard, or via USB adapter)
dd if=image_file of=/dev/nda0 bs=1m status=progress conv=sync

# eMMC: wipe the old partition table (avoids duplicate glabel names if a
# full image was there before), then write only the boot blobs
dd if=/dev/zero of=/dev/mmcsdX bs=512 count=64
dd if=/usr/local/share/u-boot/u-boot-nanopi-r5c/idbloader.img of=/dev/mmcsdX seek=64 bs=512 conv=sync
dd if=/usr/local/share/u-boot/u-boot-nanopi-r5c/u-boot.itb of=/dev/mmcsdX seek=16384 bs=512 conv=sync
```

U-boot finds no bootflow on the eMMC, falls through to NVMe, loads the EFI loader from the image's FAT partition and the system boots from `/dev/ufs/` label on the NVMe. If it does not fall through automatically, set `boot_targets` in the u-boot environment to try `nvme` first.

## How-to use

- Run the numbered scripts in order on a FreeBSD 15.1 aarch64 build host (`1.1` ... `8`), then build the image:
  - ```
    sh 9-arm.sh R5C_UBOOT
    ```
- Writing to the sdcard, eMMC or USB storage:
  - ```
    dd if=image_file of=/dev/STORAGE_DEV bs=1m status=progress conv=sync
    ```
- Serial console runs at 1500000 baud (RK3568 standard).

## Caveats

- First boot on devices that used the 1.98 Realtek driver (R5S and OP5P on 26.1/FreeBSD 14) needed all network cables disconnected. With the stock driver on FreeBSD 15.1 this needs re-testing on the R5C — if the first boot hangs, try again with cables unplugged.

## News

- 2026-07-18: Repository reworked for the NanoPi R5C and OPNsense 26.7 (FreeBSD 15.1): U-Boot boot via a local u-boot-nanopi-r5c port (with NVMe support merged in), stock realtek-re-kmod, system can live on eMMC or on NVMe through a M.2 Key-E adapter.
- 2026-05-21: 26.1.8 release used 26.1.7 packages and aux tar files. If needed, refer to 26.1.7 tar page. Package caddy-customs won't build as a result of its Github repository update.
- 2025-12-07: Due to storage problems and the Holiday Season, I won't be able to build 25.7.9 Images. In about two weeks I will have new hardware to rebuild the ARM64 box.
