# Scripts for building opnsense (https://opnsense.org) focused on ARM64 targets

These files aim for the FriendlyELEC **NanoPi R5C** (RK3568B2, 2x RTL8125B 2.5GbE). Can be used for other ARM64 systems, and also for building images for AMD64 if desired as well. Legacy conf files for NanoPi R5S and Orange Pi 5 Plus are kept in `arm64-opnsense-build/opnsense-confs/` but are no longer wired into the scripts by default.

Based on OPNsense 26.7 "Xenial Xenops" (FreeBSD 15.1). The default build is the latest version validated from the original repository, **26.7.4**. On FreeBSD 15.1 the stock `net/realtek-re-kmod` vendor driver works with the RTL8125B NICs, so the old pinning to Realtek driver 1.98 is gone.

## Boot / storage notes for the R5C

- There is no `sysutils/u-boot-nanopi-r5c` port in the FreeBSD ports tree (only r5s), so `1.1-fetch_update.sh` creates a local slave port of `sysutils/u-boot-master` (see `arm64-opnsense-build/u-boot-nanopi-r5c/`) and builds it from the ports tree.
- There is no prebuilt EDK2/UEFI image for the R5C (quartz64_uefi does not ship one), so the images boot via U-Boot.
- The output is a whole-disk image containing the R5C U-Boot boot blobs and can be written to either microSD or the onboard 32 GB eMMC. FriendlyELEC documents both SD boot and several eMMC installation methods. Never assume a device name such as `/dev/mmcsd1`; identify the source and target on the actual board before writing.
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

The repository's [`init-freebsd.sh`](init-freebsd.sh) performs the longer setup: it validates FreeBSD 15.1/aarch64/root, enables temporary root/password SSH, validates the SSH configuration, attempts to install and start the optional QEMU guest agent, and prints the VM's IPv4 address. Guest-agent failure is only a warning because the printed address can be supplied directly to the Mac launcher. It is safe to run again if setup was interrupted. Everything it installs or changes remains inside the disposable VM. This first clone is only the small bootstrap copy; the Mac launcher transfers the checkout you actually launch it from into `/root/opnsense-r5c-build` before building.

If the initializer does not print an address, run `ifconfig vtnet0` in FreeBSD and note the `inet` address. Supply that address as the second argument in step 4; this does not require a working guest agent.

#### 4. Clone and run the complete build from macOS

From a directory where you want the repository and final image, this is the complete Mac one-liner:

```sh
git clone https://github.com/alexanderjlynn/opnsense-r5c.git && cd opnsense-r5c && ./build-r5c-utm.sh 26.7.4 192.168.65.3
```

If the repository is already cloned:

```sh
./build-r5c-utm.sh 26.7.4 192.168.65.3
```

The first argument is the complete OPNsense release and the second is the address printed inside the VM. Substitute your actual address. Supplying it bypasses guest-agent discovery entirely. The default release remains `26.7.4`, so `./build-r5c-utm.sh` can still attempt automatic discovery.

To select another full OPNsense tag and provide its guest address:

```sh
./build-r5c-utm.sh 26.7.5 192.168.65.3
```

Add `--keep-raw` when you also want the uncompressed `.img` needed by an SD writer or FriendlyWrt's eMMC web tool:

```sh
./build-r5c-utm.sh --keep-raw 26.7.4 192.168.65.3
```

The launcher will:

1. Start the UTM VM named `FreeBSD`.
2. Use the supplied IPv4 address, or ask UTM's guest agent only when no address was supplied.
3. Wait for SSH and ask once for the temporary FreeBSD root password.
4. Keep SSH host keys and its multiplexed connection in a temporary directory, not in `~/.ssh/known_hosts`.
5. Copy this checkout into `/root/opnsense-r5c-build` in the VM.
6. Check FreeBSD 15.1, ARM64, root access, release tags, and free space.
7. Pin `tools`, `src`, `core`, `plugins`, and `ports` to the exact selected
   point-release tag and verify every commit before compiling.
8. Record those source commits with the generated sets. If a later run finds
   cached output with changed or unknown source provenance, discard only that
   generated output so it cannot be mislabeled as the selected release.
9. Run every script from `1.1` through `9`, stopping at the first error.
10. Keep the Mac awake for the potentially long build without changing a persistent power setting.
11. Save the complete console output in `build-artifacts/VERSION/build-VERSION.log`, including failed runs.
12. Stream-compress the completed image back into `build-artifacts/VERSION/` in this repository and, with `--keep-raw`, also copy the raw image.

macOS may show a one-time security request allowing the terminal to control UTM. That operating-system permission cannot be auto-accepted. The only other expected interaction is entering the temporary VM root password once.

For a differently named VM, put the option before the release and address:

```sh
./build-r5c-utm.sh --vm "OPNsense Builder" 26.7.4 192.168.65.3
```

Run `./build-r5c-utm.sh --help` for the remaining overrides. The selected OPNsense release must use the FreeBSD version installed in the VM; OPNsense rejects an incompatible host ABI.

#### 5. Collect and publish the result

After a successful default build, the Mac will contain:

```text
build-artifacts/26.7.4/
├── build-26.7.4.log
├── OPNsense-26.7.4-arm-aarch64-R5C_UBOOT.img.xz
├── OPNsense-26.7.4-arm-aarch64-R5C_UBOOT.img.xz.sha256
└── OPNsense-26.7.4-arm-aarch64-R5C_UBOOT.img.sig
```

The SHA-256 file verifies the compressed release asset. The `.sig` file is the OPNsense signature for the raw image after decompression. The log is for diagnosis and normally does not need to be uploaded. With `--keep-raw`, the directory also contains the much larger `.img`. `build-artifacts/` is ignored by Git so these files cannot accidentally be committed to normal repository history.

Verify the transferred asset before deleting the VM:

```sh
(cd build-artifacts/26.7.4 && shasum -a 256 -c OPNsense-26.7.4-arm-aarch64-R5C_UBOOT.img.xz.sha256)
```

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

### Validated build

The complete disposable-UTM workflow was run successfully on 2026-09-26 for OPNsense **26.7.4** using FreeBSD 15.1/aarch64, 8 virtual CPUs, and 16 GB RAM. It completed the R5C image and OPNsense signature, transferred a 1.3 GB compressed image to macOS, and passed `shasum -a 256 -c` against the generated checksum file.

### Common build issues

The wrapper exits on the first real error. Re-run the same Mac command after correcting a failure; the OPNsense build directories and downloaded distfiles remain in the VM, so completed work is normally reused. The exact source-commit manifest prevents a retry from silently mixing release tags.

- **UTM starts but no IPv4 address is discovered:** the guest agent is optional and is not reliable on every UTM/FreeBSD combination. In the VM run `ifconfig vtnet0`, then pass the address explicitly: `./build-r5c-utm.sh 26.7.4 192.168.65.3`.
- **No clipboard in the VM:** this workflow does not depend on clipboard sharing. Type the three short bootstrap commands from step 3, then perform the build from the Mac.
- **AppleDouble or extended-attribute errors while copying:** the launcher disables macOS metadata and ACLs when creating the transfer archive. Use the launcher rather than manually archiving the checkout.
- **`opnsense-update` checksum/size failure:** this happened when `ports` was at the `26.7` tag while the output was labeled `26.7.4`. Stage 1.1 now passes the full version to `make update`, verifies all five repositories at the exact tag, and removes generated sets when their recorded source commits do not match. Do not edit `distinfo` or bypass the checksum.
- **Missing versioned Perl:** stage 1.1 determines the exact interpreter required by the selected ports tag and installs that tagged Perl port when necessary.
- **`py312-* conflicts with py311-*`:** a reused VM can retain automatic Python build dependencies from an older ports snapshot. Stage 1.1 now removes only obsolete, automatically installed Python flavors in the R5C U-Boot dependency closure. It deliberately will not remove a package explicitly installed by the administrator.
- **`pkg-static: database version ... is newer ... but still compatible`:** this is a compatibility warning, not the failure. Continue reading for the first `*** Error code` or the final `Build stopped:` line.
- **`ctfconvert: ... doesn't have type data to convert`:** these messages are non-fatal when the kernel subsequently links and reports `Kernel build ... completed`.
- **A compile line appears stuck:** LLVM, Rust, OpenSSL, Perl, and link steps can be quiet for ten minutes or longer. In another SSH session run `top -aSH` or `ps auxww` and wait while compiler/linker processes are using CPU. Treat it as hung only after activity and disk usage have stopped for a sustained period.
- **`pkg` port fails during parallel targets:** stage 1.1 intentionally runs the ports framework's clean/build/reinstall targets serially; the port's own build may still use multiple CPUs.
- **Disk-space warning:** 50 GiB free is the minimum preflight threshold, not a comfortable allocation. A 100 GB UTM disk is recommended. Increase the virtual disk before retrying if `/usr` is nearly full.
- **Build failed and the important line scrolled away:** inspect `build-artifacts/VERSION/build-VERSION.log` on the Mac and `/root/opnsense-dev/build.VERSION.status` in the VM. The latter names the failed numbered stage.
- **Build succeeded but transfer failed:** leave the VM running and re-run the launcher, or copy the raw image with the SSH command in the installation section below. Do not delete the VM until the Mac checksum passes.

### Run entirely inside FreeBSD

The UTM launcher is optional. On any suitable FreeBSD 15.1 ARM64 build host, run as root:

```sh
pkg install -y git
git clone https://github.com/alexanderjlynn/opnsense-r5c.git
cd opnsense-r5c/arm64-opnsense-build
sh build-r5c.sh             # default: 26.7.4
sh build-r5c.sh 26.7.4      # explicit release
```

The raw image is written to `/usr/local/opnsense/build/26.7/aarch64/images/`. The runner validates and checks out the exact release tags, records source provenance, sets the ports/pkg/Git batch flags, stops immediately on a failed stage, and records its last stage in `/root/opnsense-dev/build.VERSION.status`.

To copy a manually run build back to macOS without a shared folder, run this on the Mac and enter the FreeBSD root password:

```sh
ssh root@VM_ADDRESS "xz -T0 -c /usr/local/opnsense/build/26.7/aarch64/images/OPNsense-26.7.4-arm-aarch64-R5C_UBOOT.img" > OPNsense-26.7.4-arm-aarch64-R5C_UBOOT.img.xz
```

## Install the image on a NanoPi R5C

### Which storage should be used?

Use a microSD card for the first boot and hardware test, then use eMMC for a permanent firewall. SD is removable and gives the easiest recovery path; eMMC is internal, avoids dependence on a removable card, and is the simplest permanent layout. NVMe is useful only when its extra capacity or endurance matters because the R5C still needs U-Boot on eMMC or SD and requires a Key-E adapter. This recommendation is an operational judgment rather than a FreeBSD requirement—the same whole-disk R5C image is used for SD and eMMC.

The build image starts at 4 GB. Its first-boot marker invokes the included partition/growfs logic, so the UFS root filesystem expands to use the remaining SD/eMMC space. Allow the first boot extra time and do not interrupt it while the filesystem is being grown.

The R5C has 32 GB eMMC and UHS-I microSD, and its debug UART is 3.3 V at **1500000 baud, 8N1**. FriendlyELEC's board-specific installation and recovery procedures are in the [official NanoPi R5C wiki](https://wiki.friendlyelec.com/wiki/index.php/NanoPi_R5C).

### Obtain the uncompressed image

FriendlyWrt's web flasher and macOS `dd` need the raw `.img`; the GitHub release asset is `.img.xz`. For future builds, add `--keep-raw` to the Mac launcher. If this build VM is still available, retrieve the already-built raw image without installing anything on macOS:

```sh
ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@192.168.65.3 \
  "cat /usr/local/opnsense/build/26.7/aarch64/images/OPNsense-26.7.4-arm-aarch64-R5C_UBOOT.img" \
  > build-artifacts/26.7.4/OPNsense-26.7.4-arm-aarch64-R5C_UBOOT.img
```

Substitute the VM address and version. This prompts for the temporary root password and leaves no SSH host key behind. Confirm that the resulting file is several gigabytes and not empty before deleting the VM.

### Recommended first test: write a microSD card on macOS

These commands use only macOS tools. **`dd` destroys the selected disk, so verify `diskN` by size and name before pressing Return. Never copy the example device name blindly.**

```sh
diskutil list
diskutil unmountDisk /dev/diskN
sudo dd if="$PWD/build-artifacts/26.7.4/OPNsense-26.7.4-arm-aarch64-R5C_UBOOT.img" of=/dev/rdiskN bs=4m
sync
diskutil eject /dev/diskN
```

Press `Control-T` while macOS `dd` is running to display progress. Insert the card and power on the R5C. For the most useful first-boot diagnostics, connect a 3.3 V USB-to-TTL serial adapter at 1500000 baud; do not connect the adapter's VCC pin. Keep the original eMMC unchanged until networking, both RTL8125B interfaces, and rebooting have been tested.

If a valid SD image is ignored, consult FriendlyELEC's Maskrom/unbrick procedure. An incompatible bootloader on eMMC may need to be erased before normal SD boot is restored.

### Recommended permanent install: FriendlyWrt eMMC Tools

For R5Cs that already have FriendlyELEC software, this is the easiest route and avoids Rockchip USB tooling:

1. Boot FriendlyWrt from a microSD card so the eMMC is the target, not the running root disk.
2. Connect to the LAN side and open `http://192.168.2.1/` (or the address configured on that device).
3. Open **System → eMMC Tools**, select the uncompressed OPNsense `.img`, then choose **Upload and Write**.
4. Wait for completion, shut down if the interface asks, remove the SD card, and power-cycle the board.

FriendlyELEC documents `.img`, `.gz`, `.tgz`, and `.zip` inputs for this page; `.xz` is not listed, which is why the raw image is required. A full image overwrites the eMMC, including FriendlyWrt and its configuration.

### Alternative permanent install: FriendlyELEC eFlasher card

This is useful for repeated or headless deployment:

1. Download FriendlyELEC's R5C `eflasher` or `eflasher-multiple-os` image and write it to a sufficiently large SD card.
2. Mount the SD card's `FriendlyARM` partition on the Mac.
3. Copy the OPNsense raw `.img` there and rename its suffix from `.img` to `.raw`.
4. For unattended flashing, set `autoStart=` in `eflasher.conf` to that `.raw` filename. The multiple-OS image can instead be selected interactively.
5. Boot the R5C from this card, wait for eFlasher to finish, remove the card, and reboot from eMMC.

FriendlyELEC explicitly documents third-party `.raw` images for eFlasher. Back up anything needed from eMMC first; automatic mode begins writing after boot.

### Advanced: stream from an SD-booted OPNsense system to eMMC

This avoids storing another copy on the SD card. First use the serial console or an SSH shell on the R5C to identify the disks:

```sh
sysctl kern.disks
mount
gpart show
```

The disk containing the mounted root filesystem is the SD source. Only after confirming the other `mmcsd` disk is the eMMC, stream the compressed image from the Mac, replacing `mmcsdX` with the verified target:

```sh
# Confirm /usr/bin/xz is present on the SD-booted R5C first.
ssh root@R5C_ADDRESS 'command -v xz'
cat build-artifacts/26.7.4/OPNsense-26.7.4-arm-aarch64-R5C_UBOOT.img.xz | \
  ssh root@R5C_ADDRESS 'xz -dc | dd of=/dev/mmcsdX bs=1m conv=sync'
```

If `xz` is unavailable, use the raw `.img` from `--keep-raw` and pipe it directly to the same `dd` command. SSH must first be enabled on the temporary SD installation. Run `sync`, shut the board down, remove the SD card, and power it on again. This command overwrites the target immediately and has no confirmation prompt.

### USB-to-eMMC / Maskrom

The R5C supports Rockchip Maskrom flashing over the USB Type-A port nearest the TF slot. FriendlyELEC's procedure is to hold **MASK**, apply power, wait at least three seconds, release it, and connect that port to the flashing computer with a USB A-to-A data cable. Its Windows RKDevTool flow can erase eMMC and flash a single third-party image.

This is a recovery/production option, but it is not the recommended direct-Mac route: FriendlyELEC reports that `upgrade_tool_v2.25` does not work correctly on macOS and recommends Windows or Linux. A disposable Linux VM with USB passthrough or a Windows machine can be used, together with the R5C `MiniLoaderAll.bin` and tools from FriendlyELEC's USB package. If RKDevTool rejects the raw OPNsense image as a firmware container, stop and use eFlasher or the SD-to-eMMC streaming method; do not guess partition offsets. The upstream [Rockchip `rkdeveloptool`](https://github.com/rockchip-linux/rkdeveloptool) can write sectors from Linux, but it also requires the correct RK3568 loader and careful target handling.

## Caveats

- First boot on devices that used the 1.98 Realtek driver (R5S and OP5P on 26.1/FreeBSD 14) needed all network cables disconnected. With the stock driver on FreeBSD 15.1 this needs re-testing on the R5C — if the first boot hangs, try again with cables unplugged.

## News

- 2026-07-18: Repository reworked for the NanoPi R5C and OPNsense 26.7 (FreeBSD 15.1): U-Boot boot via a local u-boot-nanopi-r5c port (with NVMe support merged in), stock realtek-re-kmod, system can live on eMMC or on NVMe through a M.2 Key-E adapter.
- 2026-05-21: 26.1.8 release used 26.1.7 packages and aux tar files. If needed, refer to 26.1.7 tar page. Package caddy-customs won't build as a result of its Github repository update.
- 2025-12-07: Due to storage problems and the Holiday Season, I won't be able to build 25.7.9 Images. In about two weeks I will have new hardware to rebuild the ARM64 box.
