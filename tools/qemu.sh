#!/usr/bin/env bash
# Boot a croi EFI system partition under QEMU with edk2 firmware.
#
#   qemu.sh [--test <text>] [--exits] [--then <command>] [--forward <host>:<guest>] [--disk <file>] [--timeout <seconds>] [--screendump <file.ppm> [--screendump-device <id>]] [--registers-on <text>] [--iommu intel|amd] <amd64|arm64|rv64> <esp-dir> <work-dir> <edk2-dir> [qemu args...]
#
# The ESP directory is served as a virtual FAT drive. Writable firmware
# variable stores are copied into <work-dir> on first use. With --test the
# run is headless and console output is copied to stdout and to
# <work-dir>/console.log (vx trace collect reads the traces in it); it
# succeeds as soon as a line containing <text> appears and fails after a
# timeout. With
# --exits (test mode only) the run goes on after that line until QEMU exits
# by itself (a guest power-off, or a reset: test runs pass -no-reboot), and
# fails if it doesn't within the timeout. With
# --screendump (test mode only) the display is saved as a PPM at that point;
# --screendump-device names the display device's id (`-device ...,id=`), so
# a test with a virtio GPU dumps its output rather than the firmware's.
# With --registers-on (test mode only), the first line containing that text
# prints every CPU's PC and frame-pointer backtrace (vx qemu-monitor): where
# each CPU is when a lockup is reported. Alternatives are separated by '|'.
# --iommu picks amd64's IOMMU (default intel; QEMU takes one at a time),
# or on rv64 `base` for an IOMMU without MSI_FLAT. --aia (rv64): the APLIC and
# IMSICs instead of the PLIC (K12i).
# In test mode the guest may type: a console line holding `qemu: sendkey
# KEYS` sends each of KEYS (QEMU's key names, separated by spaces) through
# the monitor's sendkey, to the keyboard the guest's driver last activated
# (V2 7d: launch-test's key through virtio-input); one holding `qemu:
# mouse_move DX DY` or `qemu: mouse_button N` runs that command, for the
# pointer (D83).
# With --then (test mode only), once the line is seen the command runs on
# the host, the line in $QEMU_LINE, while the console goes on being copied;
# the run succeeds if the command does (boot-cpu: vx cpu into the guest).
# Every boot has a virtio-blk disk (D105, D106) at slot 0x13, through the
# IOMMU: <work-dir>/disk.img, or --disk's <file>, made first with
# `vx disk FILE 256M taisce:* --man REPO` (a Taisce volume, sparse, with
# this tree's manual at lib/man) if it isn't there; with
# --test and no --disk, made anew each run.
# --forward connects TCP port <host> on 127.0.0.1 to the guest's port
# <guest> (vx boot --cpu, boot-cpu).
# --timeout ends QEMU after <seconds> in test mode (90 by default; boot-cpu,
# which copies a bootfs over the link to warm-boot, needs more).

set -euo pipefail

# vx runs the monitor commands; CMake builds it (.build/debug/vx).
vx="${VX:-$(cd "$(dirname "$0")/.." && pwd)/.build/debug/vx}"

expect=
limit=90
exits=
screendump=
screendump_device=
registers_on=
iommu=intel
aia=
then=
forward=
datadisk=
while [[ ${1:-} == --* ]]; do
  case $1 in
    --test) expect=${2:?--test needs the text to wait for}; shift 2 ;;
    --exits) exits=1; shift ;;
    --screendump) screendump=${2:?--screendump needs a file}; shift 2 ;;
    --screendump-device) screendump_device=${2:?--screendump-device needs an id}; shift 2 ;;
    --registers-on) registers_on=${2:?--registers-on needs the text to wait for}; shift 2 ;;
    --iommu) iommu=${2:?--iommu needs intel or amd}; shift 2 ;;
    --aia) aia=1; shift ;;
    --then) then=${2:?--then needs a command}; shift 2 ;;
    --forward) forward=${2:?--forward needs host:guest}; shift 2 ;;
    --disk) datadisk=${2:?--disk needs a file}; shift 2 ;;
    --timeout) limit=${2:?--timeout needs seconds}; shift 2 ;;
    *) echo "qemu.sh: unknown option $1" >&2; exit 2 ;;
  esac
done
if (( $# < 4 )); then
  sed -n '4p' "$0" >&2
  exit 2
fi
arch=$1 esp=$2 work=$3 edk2=$4
shift 4

mkdir -p "$work"

# Copy a firmware vars template into the work dir once, padded if needed.
vars() {
  local src=$1 dst=$work/$2 size=${3:-}
  if [[ ! -f $dst ]]; then
    cp "$src" "$dst"
    [[ -n $size ]] && truncate -s "$size" "$dst"
  fi
  echo "$dst"
}

disk=(-drive "if=none,format=raw,file=fat:rw:$esp,id=esp" -device virtio-blk-pci,drive=esp)

second_serial=()
case $arch in
  amd64)
    # edu (00:10.0): a PCI device with MSI (K9d) and DMA for the boot
    # tests, behind QEMU's VT-d (K12a) or AMD-Vi (K12b), which must come
    # before the other devices.
    # VT-d with interrupt remapping (K12f) under TCG; KVM refuses it unless
    # the irqchip is split (the IOAPIC in QEMU), which would change every
    # interrupt timing the bench records, so KVM boots keep it off.
    intremap=on
    [[ " $* " == *" kvm "* ]] && intremap=off
    case $iommu in
      intel) iommu_device=intel-iommu,intremap=$intremap; [[ $intremap == on ]] && iommu_device+=,eim=on ;;
      amd) iommu_device=amd-iommu,intremap=$intremap,dma-remap=on ;;
      amd-xt) iommu_device=amd-iommu,intremap=on,xtsup=on,dma-remap=on ;;
      *) echo "qemu.sh: --iommu takes intel, amd or amd-xt" >&2; exit 2 ;;
    esac
    qemu=(qemu-system-x86_64 -machine q35 -cpu max -device "$iommu_device" -device edu,addr=0x10
          -drive "if=pflash,format=raw,readonly=on,file=$edk2/ovmf/OVMF_CODE.fd"
          -drive "if=pflash,format=raw,file=$(vars "$edk2/ovmf/OVMF_VARS.fd" amd64-vars.fd)")
    ;;
  arm64)
    # ramfb gives the firmware a linear GOP framebuffer.
    # edu: DMA through the SMMUv3 for the IOMMU boot test (K12c).
    qemu=(qemu-system-aarch64 -machine virt,acpi=on,iommu=smmuv3,gic-version=3 -cpu max -device ramfb
          -device edu,addr=0x10
          -drive "if=pflash,format=raw,readonly=on,file=$edk2/aarch64/QEMU_EFI-pflash.raw"
          -drive "if=pflash,format=raw,file=$(vars "$edk2/aarch64/vars-template-pflash.raw" arm64-vars.raw)")
    # A test boot's second serial port is virt's second PL011, a spare for
    # bin/irq-test (boot-irq); it follows the console's -serial.
    second_serial=(-serial null)
    ;;
  rv64)
    # The virt machine wants both flash images padded to 32 MiB.
    if [[ ! -f $work/rv64-code.fd ]]; then
      cp "$edk2/riscv/RISCV_VIRT_CODE.fd" "$work/rv64-code.fd"
      truncate -s 32M "$work/rv64-code.fd"
    fi
    # -cpu max has Svpbmt (memory types in page tables); the default CPU doesn't.
    # A RISC-V IOMMU and edu behind it (K12e). The PCI one: QEMU 10.2 puts
    # only it in the RIMT (iommu-sys=on makes the device, no RIMT). At slot
    # 8, so the others keep their slots, and below edu: the RIMT routes the
    # requester ids above the IOMMU's own.
    # --iommu base: without interrupt remapping (no MSI_FLAT), so 32-byte
    # device contexts in a 2-level directory instead of 64-byte in 3.
    iommu_options=
    case $iommu in
      intel) ;;
      base) iommu_options=,intremap=off ;;
      *) echo "qemu.sh: --iommu on rv64 takes base" >&2; exit 2 ;;
    esac
    machine=virt,acpi=on
    [[ -n $aia ]] && machine+=,aia=aplic-imsic
    qemu=(qemu-system-riscv64 -machine "$machine" -cpu max -device ramfb
          -device "riscv-iommu-pci,addr=0x8$iommu_options" -device edu,addr=0x10
          -drive "if=pflash,format=raw,unit=0,readonly=on,file=$work/rv64-code.fd"
          -drive "if=pflash,format=raw,unit=1,file=$(vars "$edk2/riscv/RISCV_VIRT_VARS.fd" rv64-vars.fd 32M)")
    ;;
  *)
    echo "qemu.sh: unknown arch '$arch'" >&2
    exit 2
    ;;
esac

# virtio-rng: edk2 offers EFI_RNG_PROTOCOL over it, the CPRNG's seed (K11b).
# virtio-keyboard (V2 7d): devmgr's virtio-input, at slot 0x11 on every
# machine, after edu, through the IOMMU (iommu_platform: QEMU's virtio
# bypasses it otherwise, taking the driver's I/O addresses as physical).
# virtio-tablet (D83): the pointer, devmgr's virtio-input again, at slot
# 0x14, the same way; absolute, as a desktop VM's pointer is, so it
# follows the host's without a grab. In test mode, a virtio-mouse too, at
# 0x15: the monitor's mouse_move is relative, which a tablet doesn't take.
# virtio-net (D82): devmgr's virtio-net at slot 0x12, the same way (and
# modern only: QEMU won't put a transitional device behind the IOMMU), on
# QEMU's user network, which reaches nothing outside (restrict=on) but an
# echo, cat, at 10.0.2.100!7 for boot-launch to dial; no option ROM
# (romfile=), so the firmware doesn't try to boot from it.
netdev=user,id=net0,restrict=on,guestfwd=tcp:10.0.2.100:7-cmd:cat
[[ -n $forward ]] && netdev+=,hostfwd=tcp:127.0.0.1:${forward%%:*}-:${forward#*:}
qemu+=(-m 512M -smp 4 -net none "${disk[@]}" -device virtio-rng-pci -device virtio-keyboard-pci,addr=0x11,iommu_platform=on
       -device virtio-tablet-pci,addr=0x14,iommu_platform=on
       -netdev "$netdev" -device virtio-net-pci,netdev=net0,addr=0x12,disable-legacy=on,iommu_platform=on,romfile=)
[[ -n $expect ]] && qemu+=(-device virtio-mouse-pci,addr=0x15,iommu_platform=on)
# A test starts from a new disk, unless it names its own (boot-persist's,
# kept across its boots); an interactive boot keeps its disk.
if [[ -z $datadisk ]]; then
  datadisk=$work/disk.img
  [[ -n $expect ]] && rm -f "$datadisk"
fi
[[ -f $datadisk ]] || "$vx" disk "$datadisk" 256M 'taisce:*' --man "$(cd "$(dirname "$0")/.." && pwd)"
qemu+=(-drive "if=none,format=raw,file=$datadisk,id=data"
       -device virtio-blk-pci,drive=data,addr=0x13,disable-legacy=on,iommu_platform=on)

if [[ -n $expect ]]; then
  console=$work/console.log
  : > "$console"
  # The monitor: screendumps, backtraces and the guest's keys.
  socket=$work/monitor.sock
  # A Unix socket's path is under 108 bytes; a deep work dir's may not be.
  (( ${#socket} < 100 )) || socket=$(mktemp -u "${TMPDIR:-/tmp}/qemu-monitor.XXXXXX")
  rm -f "$socket"
  monitor=(-monitor "unix:$socket,server=on,wait=off")
  # A guest power-off pauses QEMU instead of ending it, so the screen can
  # still be read once the line is seen.
  [[ -n $screendump ]] && monitor+=(-action shutdown=pause)
  coproc vm { exec timeout "$limit" "${qemu[@]}" -display none -serial stdio "${second_serial[@]}" "${monitor[@]}" -no-reboot "$@" 2>&1; }
  pid=$vm_PID  # bash unsets vm_PID when the coproc ends
  # Its output, kept: bash unsets vm as well when it sees the coproc change
  # state, which a monitor command run meanwhile made it see on rv64.
  exec {out}<&"${vm[0]}"
  kaslr_image=()
  status=1
  while IFS= read -r line <&"$out"; do
    printf '%s\n' "$line"; printf '%s\n' "$line" >> "$console"
    # KASLR: where the kernel runs, so backtraces can name link addresses.
    if [[ $line =~ kaslr:\ image\ (0x[0-9a-f]+)-(0x[0-9a-f]+),\ link\ (0x[0-9a-f]+) ]]; then
      kaslr_image=("${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}")
    fi
    if [[ -n $registers_on ]]; then
      IFS='|' read -ra triggers <<< "$registers_on"
      for trigger in "${triggers[@]}"; do
        if [[ $line == *"$trigger"* ]]; then
          "$vx" qemu-monitor "$socket" backtrace "${kaslr_image[@]}" || true
          registers_on=
          break
        fi
      done
    fi
    # The guest moves the mouse: mouse_move DX DY and mouse_button N.
    if [[ $line =~ qemu:\ (mouse_move|mouse_button)((\ -?[0-9]+)+) ]]; then
      "$vx" qemu-monitor "$socket" "${BASH_REMATCH[1]}" ${BASH_REMATCH[2]} > /dev/null || true
    fi
    # The guest asks for keys: each through the monitor's sendkey.
    if [[ $line =~ qemu:\ sendkey\ (.+)$ ]]; then
      keys=${BASH_REMATCH[1]%$'\r'}
      for key in $keys; do "$vx" qemu-monitor "$socket" sendkey "$key" > /dev/null || true; done
    fi
    # The guest turned itself off without the line: no point waiting.
    if [[ $line == "croi kernel: powering off"* || $line == "croi kernel: rebooting"* ]] &&
       [[ $line != *"$expect"* ]]; then
      break
    fi
    if [[ $line == *"$expect"* ]]; then
      status=0
      if [[ -n $screendump ]]; then
        rm -f "$screendump"
        "$vx" qemu-monitor "$socket" screendump "$screendump" ${screendump_device:+"$screendump_device"} || status=1
      fi
      if [[ -n $then ]]; then
        # The console goes on being copied meanwhile, so the guest never
        # waits for it to be read.
        ( while IFS= read -r l <&"$out"; do printf '%s\n' "$l"; printf '%s\n' "$l" >> "$console"; done ) &
        drain=$!
        QEMU_LINE=$line bash -c "$then" || status=2
        kill "$drain" 2>/dev/null || true
      fi
      break
    fi
  done
  if (( status == 2 )); then
    echo "qemu.sh: '$then' failed" >&2
    status=1
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    exit $status
  fi
  if (( status != 0 )); then
    echo "qemu.sh: '$expect' not seen" >&2
  elif [[ -n $exits ]]; then
    # The rest of the console, until QEMU exits (EOF) or the timeout kills it.
    while IFS= read -r line <&"$out"; do printf '%s\n' "$line"; printf '%s\n' "$line" >> "$console"; done
    wait "$pid" 2>/dev/null && exited=0 || exited=$?
    if (( exited != 0 )); then
      echo "qemu.sh: QEMU didn't exit by itself (status $exited)" >&2
      status=1
    fi
    exit $status
  fi
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  exit $status
else
  exec "${qemu[@]}" -nographic "$@"
fi
