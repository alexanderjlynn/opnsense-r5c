# Scripts for building opnsense (https://opnsense.org) focused on ARM64 targets

These files aim for the FriendlyELEC **NanoPi R5C** (RK3568B2, 2x RTL8125B 2.5GbE). Can be used for other ARM64 systems, and also for building images for AMD64 if desired as well. Legacy conf files for NanoPi R5S and Orange Pi 5 Plus are kept in `arm64-opnsense-build/opnsense-confs/` but are no longer wired into the scripts by default.

Based on OPNsense 26.7 "Xenial Xenops" (FreeBSD 15.1). The default build is the latest version validated from the original repository, **26.7.4**. On FreeBSD 15.1 the stock `net/realtek-re-kmod` vendor driver works with the RTL8125B NICs, so the old pinning to Realtek driver 1.98 is gone.

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

### Complete disposable UTM build on an Apple-silicon Mac

This plan installs build dependencies only inside a temporary FreeBSD VM. It does not use Homebrew, MacPorts, or install anything from the shell on macOS. The Mac needs UTM and Git already available. At the end, the repository contains the compressed R5C image and the UTM VM can be deleted.

The R5C build produces a raw disk image (`.img`), not an installer ISO. The launcher streams it through `xz` into a release-friendly `.img.xz` on the Mac.

#### 1. Download the FreeBSD installer

Download the official [FreeBSD 15.1-RELEASE ARM64 disc1 ISO](https://download.freebsd.org/releases/arm64/aarch64/ISO-IMAGES/15.1/FreeBSD-15.1-RELEASE-arm64-aarch64-disc1.iso). The [SHA-256 checksum file](https://download.freebsd.org/releases/arm64/aarch64/ISO-IMAGES/15.1/CHECKSUM.SHA256-FreeBSD-15.1-RELEASE-arm64-aarch64) is in the same directory.

#### 2. Create the UTM VM

In UTM:

1. Click **+** and choose **Virtualize**, then **Other**.
2. Select the downloaded ARM64 `disc1.iso` as the boot ISO and keep UEFI enabled.
3. Name the VM exactly `FreeBSD`. A different name works, but it must later be passed with `--vm`.
4. Assign about 8 CPU cores, 16 GB RAM, and a 100 GB virtual disk. Do not assign more cores or memory than the Mac can comfortably spare.
5. Use UTM's default **Shared Network** adapter.
6. A shared host directory is not required. [UTM's documented QEMU directory-sharing methods](https://docs.getutm.app/guest-support/sharing/directory/) target Windows and Linux guests, so this workflow deliberately uses SSH for FreeBSD.
7. Save and start the VM.

Install FreeBSD using the text installer:

1. Choose **Install**, select the normal keymap, and set any hostname.
2. Use **Auto (UFS)** over the entire virtual disk. UFS is the simplest disposable build-host layout.
3. Set a temporary root password that you can enter from the Mac.
4. Enable `sshd` when the installer asks about services. Enabling time synchronization is also recommended.
5. Finish the installation, shut down or reboot, and eject/remove the installer ISO so the VM boots from its virtual disk.

The [official OPNsense build tooling](https://github.com/opnsense/tools#setting-up-a-build-system) calls for FreeBSD 15.1, at least 16 GB RAM, and at least 50 GB of disk. The larger virtual disk above leaves room for ports, distfiles, packages, the raw image, and temporary build objects.

#### 3. Prepare the temporary FreeBSD guest

UTM clipboard integration is not required. Log in as `root` in the UTM console and type these three short commands by hand. The environment setting on the first line also accepts the one-time `pkg` bootstrap prompt.

```sh
env ASSUME_ALWAYS_YES=yes pkg install -y git
git clone https://github.com/alexanderjlynn/opnsense-r5c r
sh r/init-freebsd.sh
```

The repository's [`init-freebsd.sh`](init-freebsd.sh) performs the longer setup: it validates FreeBSD 15.1/aarch64/root, installs and starts the QEMU guest agent, enables temporary root/password SSH, validates the SSH configuration, and prints the VM's IPv4 address. It is safe to run again if setup was interrupted. Everything it installs or changes remains inside the disposable VM. This first clone is only the small bootstrap copy; the Mac launcher transfers the checkout you actually launch it from into `/root/opnsense-r5c-build` before building.

If UTM does not discover the address, run `ifconfig vtnet0` in FreeBSD and note the `inet` address. You can provide it with `--host` in step 4.

#### 4. Clone and run the complete build from macOS

From a directory where you want the repository and final image, this is the complete Mac one-liner:

```sh
git clone https://github.com/alexanderjlynn/opnsense-r5c.git && cd opnsense-r5c && ./build-r5c-utm.sh
```

If the repository is already cloned:

```sh
./build-r5c-utm.sh
```

The default release is `26.7.4`. To select another full OPNsense tag:

```sh
./build-r5c-utm.sh 26.7.4
```

The launcher will:

1. Start the UTM VM named `FreeBSD`.
2. Ask UTM's guest agent for its IPv4 address.
3. Wait for SSH and ask once for the temporary FreeBSD root password.
4. Keep SSH host keys and its multiplexed connection in a temporary directory, not in `~/.ssh/known_hosts`.
5. Copy this checkout into `/root/opnsense-r5c-build` in the VM.
6. Check FreeBSD 15.1, ARM64, root access, release tags, and free space.
7. Run every script from `1.1` through `9`, stopping at the first error.
8. Keep the Mac awake for the potentially long build without changing a persistent power setting.
9. Stream-compress the completed image back into `build-artifacts/VERSION/` in this repository.

macOS may show a one-time security request allowing the terminal to control UTM. That operating-system permission cannot be auto-accepted. The only other expected interaction is entering the temporary VM root password once.

For a differently named VM or failed automatic address discovery:

```sh
./build-r5c-utm.sh --vm "OPNsense Builder" --host 192.168.64.10 26.7.4
```

Run `./build-r5c-utm.sh --help` for the remaining overrides. The selected OPNsense release must use the FreeBSD version installed in the VM; OPNsense rejects an incompatible host ABI.

#### 5. Collect and publish the result

After a successful default build, the Mac will contain:

```text
build-artifacts/26.7.4/
├── OPNsense-26.7.4-arm-aarch64-R5C_UBOOT.img.xz
├── OPNsense-26.7.4-arm-aarch64-R5C_UBOOT.img.xz.sha256
└── OPNsense-26.7.4-arm-aarch64-R5C_UBOOT.img.sig
```

The SHA-256 file verifies the compressed release asset. The `.sig` file is the OPNsense signature for the raw image after decompression. `build-artifacts/` is ignored by Git so a multi-gigabyte image cannot accidentally be committed to normal repository history.

To publish it without installing another Mac tool:

1. Open the repository on GitHub and select **Releases** → **Draft a new release**.
2. Create or choose a tag such as `r5c-26.7.4`.
3. Drag the three files above into the release-assets box and publish the release.

[GitHub requires each release asset to be under 2 GiB](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases#storage-and-bandwidth-quotas). The launcher warns if the compressed image exceeds that. If needed, split it with the built-in macOS `split` command and attach the parts:

```sh
split -b 1900m build-artifacts/26.7.4/OPNsense-26.7.4-arm-aarch64-R5C_UBOOT.img.xz build-artifacts/26.7.4/OPNsense-26.7.4-arm-aarch64-R5C_UBOOT.img.xz.part-
```

#### 6. Delete the temporary VM

Confirm the files exist under `build-artifacts/VERSION/`, shut down FreeBSD with `shutdown -p now`, and delete the VM from UTM. You may also delete the downloaded FreeBSD installer ISO. The launcher removes its temporary control socket and SSH host-key file automatically, leaving only this repository and the build artifacts on macOS.

### Run entirely inside FreeBSD

The UTM launcher is optional. On any suitable FreeBSD 15.1 ARM64 build host, run as root:

```sh
pkg install -y git
git clone https://github.com/alexanderjlynn/opnsense-r5c.git
cd opnsense-r5c/arm64-opnsense-build
sh build-r5c.sh             # default: 26.7.4
sh build-r5c.sh 26.7.4      # explicit release
```

The raw image is written to `/usr/local/opnsense/build/26.7/aarch64/images/`. The runner validates release tags, sets the ports/pkg/Git batch flags, stops immediately on a failed stage, and records its last stage in `/root/opnsense-dev/build.VERSION.status`.

To copy a manually run build back to macOS without a shared folder, run this on the Mac and enter the FreeBSD root password:

```sh
ssh root@VM_ADDRESS "xz -T0 -c /usr/local/opnsense/build/26.7/aarch64/images/OPNsense-26.7.4-arm-aarch64-R5C_UBOOT.img" > OPNsense-26.7.4-arm-aarch64-R5C_UBOOT.img.xz
```

To write the decompressed image to an SD card, eMMC, or USB storage device, use `dd` from a suitable system. The R5C serial console runs at 1500000 baud.

## Caveats

- First boot on devices that used the 1.98 Realtek driver (R5S and OP5P on 26.1/FreeBSD 14) needed all network cables disconnected. With the stock driver on FreeBSD 15.1 this needs re-testing on the R5C — if the first boot hangs, try again with cables unplugged.

## News

- 2026-07-18: Repository reworked for the NanoPi R5C and OPNsense 26.7 (FreeBSD 15.1): U-Boot boot via a local u-boot-nanopi-r5c port (with NVMe support merged in), stock realtek-re-kmod, system can live on eMMC or on NVMe through a M.2 Key-E adapter.
- 2026-05-21: 26.1.8 release used 26.1.7 packages and aux tar files. If needed, refer to 26.1.7 tar page. Package caddy-customs won't build as a result of its Github repository update.
- 2025-12-07: Due to storage problems and the Holiday Season, I won't be able to build 25.7.9 Images. In about two weeks I will have new hardware to rebuild the ARM64 box.
