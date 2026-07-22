#!/usr/bin/env bash
#
# Hardware auto-tuning.
#
# Reads the machine and picks settings for each component, so the user never
# configures anything. This is pillar 1 ("zero-config") expressed as a mechanism
# rather than an aspiration.
#
# Three rules govern everything below:
#
#   1. Log every decision and its reason. "Why is my governor set to this?" has
#      to be answerable, or auto-tuning is indistinguishable from the machine
#      being mysterious.
#   2. Be conservative when unsure. A safe default beats a wrong aggressive one;
#      nobody thanks an appliance for shaving 3% off a benchmark and eating
#      their battery.
#   3. Write only to drop-ins under /etc, so admin mode can override any value.
#      Auto-tuning is a default, never a lock.
#
# Re-runs when the hardware changes rather than only at first boot: a disk moved
# to another machine, or a new GPU, must be re-tuned instead of inheriting
# settings chosen for different hardware.

set -uo pipefail

STATE_DIR=/var/lib/kotinos
FINGERPRINT_FILE="${STATE_DIR}/.hardware-fingerprint"
PROFILE_LOG="${STATE_DIR}/hardware-profile.log"

SYSCTL_DIR=/etc/sysctl.d
UDEV_DIR=/etc/udev/rules.d
ZRAM_CONF=/etc/systemd/zram-generator.conf

log() { echo "kotinos-hardware-tune: $*"; }

# Decisions are written to a log the user (or the AI, later) can read back.
decide() {
    local component="$1" setting="$2" reason="$3"
    printf '%-12s %-28s %s\n' "${component}" "${setting}" "${reason}" >> "${PROFILE_LOG}"
    log "${component}: ${setting} (${reason})"
}

# ---------------------------------------------------------------- detection --

cpu_vendor="$(grep -m1 '^vendor_id' /proc/cpuinfo | awk '{print $3}')"
cpu_model="$(grep -m1 '^model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ *//')"
cpu_cores="$(nproc)"
ram_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
ram_gb=$(( ram_kb / 1024 / 1024 ))

# A battery means a laptop, which changes almost every power decision.
if [[ -d /sys/class/power_supply ]] && \
   grep -qs Battery /sys/class/power_supply/*/type 2>/dev/null; then
    on_battery_hardware=yes
else
    on_battery_hardware=no
fi

gpu_ids="$(lspci -nn 2>/dev/null | grep -iE 'vga|3d controller|display' || true)"

# Hardware fingerprint: if any of this changes we are on different hardware and
# every decision below has to be reconsidered.
fingerprint="$(printf '%s|%s|%s|%s|%s' \
    "${cpu_model}" "${cpu_cores}" "${ram_gb}" "${on_battery_hardware}" "${gpu_ids}" \
    | sha256sum | cut -d' ' -f1)"

if [[ -r "${FINGERPRINT_FILE}" ]] && [[ "$(cat "${FINGERPRINT_FILE}")" == "${fingerprint}" ]]; then
    log "hardware unchanged; nothing to re-tune"
    exit 0
fi

install -d -m 0755 "${STATE_DIR}"
{
    echo "# KotinosOS hardware profile"
    echo "# generated $(date -u +%FT%TZ)"
    echo "# every value below is overridable in admin mode"
    echo
    printf '%-12s %-28s %s\n' "COMPONENT" "SETTING" "REASON"
} > "${PROFILE_LOG}"

log "hardware changed or first run; tuning"
decide "cpu"     "${cpu_model:-unknown}" "detected, ${cpu_cores} threads"
decide "memory"  "${ram_gb} GiB"         "detected"
decide "chassis" "$([[ ${on_battery_hardware} == yes ]] && echo laptop || echo desktop)" \
                 "battery $([[ ${on_battery_hardware} == yes ]] && echo present || echo absent)"

# ------------------------------------------------------------------- memory --
#
# Low-RAM machines benefit from compressed swap in RAM and a willingness to use
# it; large-RAM machines should stay in RAM and avoid swap churn.

if (( ram_gb <= 8 )); then
    swappiness=100      # zram is fast; swapping to it is cheap
    zram_fraction="0.5"
    reason="<=8 GiB, favour compressed swap over reclaim pressure"
elif (( ram_gb <= 16 )); then
    swappiness=60
    zram_fraction="0.35"
    reason="8-16 GiB, balanced"
else
    swappiness=10
    zram_fraction="0.25"
    reason=">16 GiB, keep working set resident"
fi

install -d -m 0755 "${SYSCTL_DIR}"
cat > "${SYSCTL_DIR}/60-kotinos-memory.conf" <<EOF
# Written by kotinos-hardware-tune. Override in admin mode with a
# higher-numbered file in this directory.
vm.swappiness = ${swappiness}
EOF
decide "memory" "swappiness=${swappiness}" "${reason}"

cat > "${ZRAM_CONF}" <<EOF
# Written by kotinos-hardware-tune.
[zram0]
zram-fraction = ${zram_fraction}
compression-algorithm = zstd
EOF
decide "memory" "zram=${zram_fraction} of RAM" "compressed swap sized to installed RAM"

# ------------------------------------------------------------------ storage --
#
# The right I/O scheduler depends on whether seeking costs anything. Rotational
# disks benefit from BFQ's reordering; NVMe is fast and parallel enough that a
# scheduler mostly adds latency.

install -d -m 0755 "${UDEV_DIR}"
cat > "${UDEV_DIR}/60-kotinos-scheduler.rules" <<'EOF'
# Written by kotinos-hardware-tune.
# NVMe: no scheduler -- the device reorders better than we can.
ACTION=="add|change", KERNEL=="nvme[0-9]*n[0-9]*", ATTR{queue/scheduler}="none"
# SATA/USB SSD: light scheduler.
ACTION=="add|change", KERNEL=="sd[a-z]*", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"
# Rotational: BFQ, where seek ordering genuinely pays.
ACTION=="add|change", KERNEL=="sd[a-z]*", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
EOF

has_rotational=no
has_solid=no
for dev in /sys/block/*/queue/rotational; do
    [[ -r "${dev}" ]] || continue
    if [[ "$(cat "${dev}")" == "1" ]]; then has_rotational=yes; else has_solid=yes; fi
done
decide "storage" "scheduler rules installed" \
       "rotational=${has_rotational} solid-state=${has_solid}"

# TRIM matters only where there is something to trim.
if [[ "${has_solid}" == "yes" ]]; then
    systemctl enable fstrim.timer >/dev/null 2>&1 \
        && decide "storage" "fstrim.timer enabled" "solid-state device present"
fi

# ---------------------------------------------------------------- cpu power --
#
# On intel_pstate and amd_pstate the "powersave" governor is the correct choice
# even on desktops: it is not a low-performance mode, it hands frequency
# selection to the hardware, which does it better. Performance intent is then
# expressed through the energy/performance preference instead.

driver=""
[[ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver ]] && \
    driver="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver)"

if [[ -z "${driver}" ]]; then
    decide "cpu" "left alone" "no cpufreq driver exposed (likely virtualised)"
else
    case "${driver}" in
        intel_pstate|intel_cpufreq|amd-pstate*|amd_pstate*)
            governor="powersave"
            if [[ "${on_battery_hardware}" == "yes" ]]; then
                epp="balance_power"; why="laptop: favour battery life"
            else
                epp="balance_performance"; why="desktop: favour responsiveness"
            fi
            ;;
        *)
            # acpi-cpufreq and friends: schedutil is the sane modern default.
            governor="schedutil"; epp=""; why="generic driver, schedutil is the safe default"
            ;;
    esac

    cat > "${UDEV_DIR}/60-kotinos-cpu.rules" <<EOF
# Written by kotinos-hardware-tune.
ACTION=="add", SUBSYSTEM=="cpu", ATTR{cpufreq/scaling_governor}="${governor}"
EOF
    decide "cpu" "governor=${governor}" "${driver}, ${why}"

    if [[ -n "${epp}" ]]; then
        cat >> "${UDEV_DIR}/60-kotinos-cpu.rules" <<EOF
ACTION=="add", SUBSYSTEM=="cpu", ATTR{cpufreq/energy_performance_preference}="${epp}"
EOF
        decide "cpu" "epp=${epp}" "${why}"
    fi
fi

# ---------------------------------------------------------------- graphics ---
if [[ -n "${gpu_ids}" ]]; then
    if grep -qi nvidia <<<"${gpu_ids}"; then
        # Deliberately does not install a driver. The proprietary NVIDIA module
        # is out-of-tree and will not load under the Secure Boot lockdown the
        # image runs with; that needs MOK enrolment, which is a user decision.
        decide "gpu" "nouveau (no proprietary driver)" \
               "NVIDIA detected; out-of-tree modules need MOK enrolment under Secure Boot"
    elif grep -qiE 'amd|radeon' <<<"${gpu_ids}"; then
        decide "gpu" "amdgpu in-tree" "AMD detected, kernel driver is correct"
    elif grep -qi intel <<<"${gpu_ids}"; then
        decide "gpu" "i915/xe in-tree" "Intel detected, kernel driver is correct"
    else
        decide "gpu" "in-tree driver" "unrecognised GPU, leaving to the kernel"
    fi
fi

# ------------------------------------------------------------------- finish --
printf '%s' "${fingerprint}" > "${FINGERPRINT_FILE}"
log "tuning complete; decisions recorded in ${PROFILE_LOG}"
