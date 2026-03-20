#!/bin/bash
# run-uml-parallel.sh
#
# Parallel BTRFS fstests runner for User-Mode Linux (UML).
# Shards the test list across N UML instances, each backed by
# tmpfs (RAM disk) block devices for maximum I/O performance.
#
# Usage:
#   ./run-uml-parallel.sh [OPTIONS]
#
# Options:
#   --shards N          Number of parallel UML instances (default: auto = nproc/2)
#   --uml-binary PATH   Path to UML kernel binary (default: ./linux-6.14.2/linux)
#   --rootfs PATH       Path to rootfs image (default: ./rootfs.img)
#   --test-list PATH    Path to test list file (default: ./uml_all_auto_tests.txt)
#   --results-dir PATH  Directory to collect results (default: ./results-<timestamp>)
#   --uml-mem SIZE      Memory per UML instance, e.g. 512M (default: 512M)
#   --test-img-size S   Size of TEST_DEV image per shard (default: 5G)
#   --scratch-img-size S Size of SCRATCH_DEV image per shard (default: 5G)
#   --tmpfs-dir PATH    Host directory to use for tmpfs images (default: /dev/shm)
#   --no-tmpfs          Use regular disk-backed images instead of tmpfs
#   --timeout SECS      Per-shard timeout in seconds (default: 7200)
#   --help              Show this help message

set -euo pipefail

# ─── Defaults ────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARDS=""
UML_BINARY="${SCRIPT_DIR}/linux-6.14.2/linux"
ROOTFS_IMG="${SCRIPT_DIR}/rootfs.img"
TEST_LIST="${SCRIPT_DIR}/uml_all_auto_tests.txt"
RESULTS_DIR="${SCRIPT_DIR}/results-$(date +%Y%m%d-%H%M%S)"
UML_MEM="512M"
TEST_IMG_SIZE="5G"
SCRATCH_IMG_SIZE="5G"
# /dev/shm is a pre-existing tmpfs on all Linux systems, always accessible
# to all processes (including UML's forked I/O helper threads).
TMPFS_DIR="/dev/shm"
USE_TMPFS=true
SHARD_TIMEOUT=7200

# ─── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --shards)           SHARDS="$2";           shift 2 ;;
        --uml-binary)       UML_BINARY="$2";       shift 2 ;;
        --rootfs)           ROOTFS_IMG="$2";       shift 2 ;;
        --test-list)        TEST_LIST="$2";        shift 2 ;;
        --results-dir)      RESULTS_DIR="$2";      shift 2 ;;
        --uml-mem)          UML_MEM="$2";          shift 2 ;;
        --test-img-size)    TEST_IMG_SIZE="$2";    shift 2 ;;
        --scratch-img-size) SCRATCH_IMG_SIZE="$2"; shift 2 ;;
        --tmpfs-dir)        TMPFS_DIR="$2";        shift 2 ;;
        --no-tmpfs)         USE_TMPFS=false;       shift ;;
        --timeout)          SHARD_TIMEOUT="$2";    shift 2 ;;
        --help)
            sed -n '3,24p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ─── Auto-detect shard count ─────────────────────────────────────────────────
if [[ -z "$SHARDS" ]]; then
    HOST_CPUS=$(nproc)
    # Use at most half the CPUs to leave room for the host OS.
    SHARDS=$(( HOST_CPUS / 2 ))
    [[ "$SHARDS" -lt 1 ]] && SHARDS=1
fi

# ─── Sanity checks ───────────────────────────────────────────────────────────
[[ -x "$UML_BINARY" ]]   || { echo "ERROR: UML binary not found: $UML_BINARY"; exit 1; }
[[ -f "$ROOTFS_IMG" ]]   || { echo "ERROR: rootfs image not found: $ROOTFS_IMG"; exit 1; }
[[ -f "$TEST_LIST" ]]    || { echo "ERROR: test list not found: $TEST_LIST"; exit 1; }

TOTAL_TESTS=$(wc -l < "$TEST_LIST")
[[ "$TOTAL_TESTS" -eq 0 ]] && { echo "ERROR: test list is empty"; exit 1; }

# ─── Setup ───────────────────────────────────────────────────────────────────
mkdir -p "$RESULTS_DIR"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║          UML Parallel fstests Runner                        ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  UML binary    : $UML_BINARY"
echo "  Rootfs image  : $ROOTFS_IMG"
echo "  Test list     : $TEST_LIST ($TOTAL_TESTS tests)"
echo "  Shards        : $SHARDS"
echo "  UML memory    : $UML_MEM per shard"
echo "  Test img size : $TEST_IMG_SIZE"
echo "  Scratch size  : $SCRATCH_IMG_SIZE"
echo "  Use tmpfs     : $USE_TMPFS"
echo "  tmpfs dir     : $TMPFS_DIR"
echo "  Results dir   : $RESULTS_DIR"
echo "  Timeout       : ${SHARD_TIMEOUT}s per shard"
echo ""

# ─── Determine image base directory ──────────────────────────────────────────
if [[ "$USE_TMPFS" == "true" ]]; then
    IMG_BASE_DIR="$TMPFS_DIR"
    # If using /dev/shm, ensure it has enough space.
    # Each shard needs ~1GB rootfs copy + sparse test/scratch images.
    # Estimate required space: shards * 1.2GB (rootfs) + headroom
    ROOTFS_SIZE_BYTES=$(stat -c%s "$ROOTFS_IMG")
    ROOTFS_SIZE_GB=$(( (ROOTFS_SIZE_BYTES / 1073741824) + 1 ))
    NEEDED_GB=$(( SHARDS * (ROOTFS_SIZE_GB + 1) + 2 ))
    AVAIL_KB=$(df -k "$TMPFS_DIR" | awk 'NR==2{print $4}')
    AVAIL_GB=$(( AVAIL_KB / 1048576 ))
    if [[ "$AVAIL_GB" -lt "$NEEDED_GB" ]]; then
        echo "→ Expanding $TMPFS_DIR to ${NEEDED_GB}G (currently ${AVAIL_GB}G available) ..."
        sudo mount -o remount,size="${NEEDED_GB}G" "$TMPFS_DIR" 2>/dev/null || \
            echo "  WARNING: Could not expand $TMPFS_DIR. Proceeding anyway."
    fi
    echo "→ Using $TMPFS_DIR for shard images (tmpfs, RAM-backed I/O)"
else
    IMG_BASE_DIR="$SCRIPT_DIR"
    echo "→ Using $IMG_BASE_DIR for shard images (disk-backed)"
fi

# ─── Shard the test list ─────────────────────────────────────────────────────
echo ""
echo "→ Sharding $TOTAL_TESTS tests across $SHARDS instances ..."

# Create shard list files
for (( i=0; i<SHARDS; i++ )); do
    rm -f "${IMG_BASE_DIR}/shard-${i}-tests.txt"
done

# Round-robin distribution: interleave tests so each shard gets a mix of
# fast and slow tests (avoids one shard getting all the heavy fsstress tests)
mapfile -t ALL_TESTS < "$TEST_LIST"
for (( idx=0; idx<${#ALL_TESTS[@]}; idx++ )); do
    shard_idx=$(( idx % SHARDS ))
    echo "${ALL_TESTS[$idx]}" >> "${IMG_BASE_DIR}/shard-${shard_idx}-tests.txt"
done

for (( i=0; i<SHARDS; i++ )); do
    count=$(wc -l < "${IMG_BASE_DIR}/shard-${i}-tests.txt")
    echo "  Shard $i: $count tests"
done

# ─── Create per-shard disk images ────────────────────────────────────────────
echo ""
echo "→ Creating per-shard disk images ..."

ROOTFS_COPIES=()
TEST_IMGS=()
SCRATCH_IMGS=()
SHARD_LOGS=()

for (( i=0; i<SHARDS; i++ )); do
    SHARD_DIR="${IMG_BASE_DIR}/uml-shard-${i}"
    mkdir -p "$SHARD_DIR"

    # Rootfs: copy the base image into the shard directory.
    # NOTE: The tmpfs directory MUST remain mounted for the entire duration
    # of the UML run, as UML's I/O helper thread accesses the files directly.
    ROOTFS_COPY="${SHARD_DIR}/rootfs.img"
    echo "  Shard $i: copying rootfs to $ROOTFS_COPY ..."
    cp "$ROOTFS_IMG" "$ROOTFS_COPY"
    ROOTFS_COPIES+=("$ROOTFS_COPY")

    # Test and scratch devices: sparse files (pages allocated on first write)
    TEST_IMG="${SHARD_DIR}/test.img"
    SCRATCH_IMG="${SHARD_DIR}/scratch.img"
    truncate -s "$TEST_IMG_SIZE"    "$TEST_IMG"
    truncate -s "$SCRATCH_IMG_SIZE" "$SCRATCH_IMG"
    TEST_IMGS+=("$TEST_IMG")
    SCRATCH_IMGS+=("$SCRATCH_IMG")

    SHARD_LOG="${RESULTS_DIR}/shard-${i}.log"
    SHARD_LOGS+=("$SHARD_LOG")

    echo "  Shard $i: images ready in $SHARD_DIR"
done

# ─── Install per-shard test lists into rootfs copies ─────────────────────────
echo ""
echo "→ Installing per-shard test lists and configs into rootfs copies ..."

for (( i=0; i<SHARDS; i++ )); do
    SHARD_DIR="${IMG_BASE_DIR}/uml-shard-${i}"
    MOUNT_POINT="${SHARD_DIR}/mnt"
    mkdir -p "$MOUNT_POINT"

    sudo mount -o loop "${ROOTFS_COPIES[$i]}" "$MOUNT_POINT"

    # Install the shard-specific test list
    sudo cp "${IMG_BASE_DIR}/shard-${i}-tests.txt" \
            "$MOUNT_POINT/opt/xfstests/shard_tests.txt"

    # Write a per-shard local.config
    sudo tee "$MOUNT_POINT/opt/xfstests/local.config" > /dev/null << LOCALCFG
FSTYP=btrfs
TEST_DEV=/dev/ubdb
TEST_DIR=/mnt/test
SCRATCH_DEV=/dev/ubdc
SCRATCH_MNT=/mnt/scratch
RESULT_BASE=/results
RECREATE_TEST_DEV=true
LOCALCFG

    # Update the run-fstests.sh to use shard_tests.txt
    sudo tee "$MOUNT_POINT/sbin/run-fstests.sh" > /dev/null << 'INITSCRIPT'
#!/bin/bash
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t devtmpfs devtmpfs /dev 2>/dev/null
mount -t devpts devpts /dev/pts 2>/dev/null
mount -t tmpfs tmpfs /tmp 2>/dev/null

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
hostname uml-fstests

mkdir -p /mnt/test /mnt/scratch /results

echo "=== UML FSTESTS START at $(date) ==="
echo "=== Kernel: $(uname -r) ==="

# Format the test device with btrfs before fstests runs
# (fstests' check script will also reformat via RECREATE_TEST_DEV=true,
# but an explicit mkfs here ensures the device is ready on first mount)
mkfs.btrfs -f /dev/ubdb 2>&1 | tail -3

cd /opt/xfstests

# Run the tests listed in shard_tests.txt
./check -T $(cat /opt/xfstests/shard_tests.txt | tr '\n' ' ') \
    2>&1 | tee /results/check.log

echo "=== UML FSTESTS DONE at $(date) ==="
sync
echo 1 > /proc/sys/kernel/sysrq
echo o > /proc/sysrq-trigger
sleep 5
INITSCRIPT
    sudo chmod +x "$MOUNT_POINT/sbin/run-fstests.sh"

    sudo umount "$MOUNT_POINT"
    echo "  Shard $i: installed $(wc -l < "${IMG_BASE_DIR}/shard-${i}-tests.txt") tests"
done

# ─── Launch UML shards in parallel ───────────────────────────────────────────
echo ""
echo "→ Launching $SHARDS UML instances in parallel ..."
echo ""

SHARD_PIDS=()

cleanup() {
    echo ""
    echo "→ Caught signal, killing all UML shards ..."
    for pid in "${SHARD_PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    # Clean up shard directories from tmpfs
    if [[ "$USE_TMPFS" == "true" ]]; then
        for (( i=0; i<SHARDS; i++ )); do
            rm -rf "${IMG_BASE_DIR}/uml-shard-${i}" \
                   "${IMG_BASE_DIR}/shard-${i}-tests.txt" 2>/dev/null || true
        done
    fi
    exit 1
}
trap cleanup INT TERM

for (( i=0; i<SHARDS; i++ )); do
    timeout "$SHARD_TIMEOUT" "$UML_BINARY" \
        "ubda=${ROOTFS_COPIES[$i]}" \
        "ubdb=${TEST_IMGS[$i]}" \
        "ubdc=${SCRATCH_IMGS[$i]}" \
        "mem=${UML_MEM}" \
        root=/dev/ubda \
        rootfstype=ext4 \
        rw \
        con=null \
        con0=fd:0,fd:1 \
        init=/sbin/run-fstests.sh \
        > "${SHARD_LOGS[$i]}" 2>&1 &

    SHARD_PIDS+=($!)
    echo "  Shard $i launched (PID ${SHARD_PIDS[$i]}), log: ${SHARD_LOGS[$i]}"
done

# ─── Monitor progress ────────────────────────────────────────────────────────
echo ""
echo "→ All shards running. Monitoring progress every 30s (Ctrl+C to abort) ..."
echo ""

START_TIME=$(date +%s)
while true; do
    RUNNING=0
    for (( i=0; i<SHARDS; i++ )); do
        if kill -0 "${SHARD_PIDS[$i]}" 2>/dev/null; then
            RUNNING=$(( RUNNING + 1 ))
        fi
    done

    ELAPSED=$(( $(date +%s) - START_TIME ))
    ELAPSED_MIN=$(( ELAPSED / 60 ))
    ELAPSED_SEC=$(( ELAPSED % 60 ))

    # Count tests started and done across all shard logs
    TOTAL_STARTED=0
    TOTAL_DONE=0
    for (( i=0; i<SHARDS; i++ )); do
        if [[ -f "${SHARD_LOGS[$i]}" ]]; then
            s=$(grep -c "run fstests" "${SHARD_LOGS[$i]}" 2>/dev/null || true)
            d=$(grep -cE "^\s+\[.*\] [0-9]+s" "${SHARD_LOGS[$i]}" 2>/dev/null || true)
            # grep -c returns 0 on no match (not an error), but can fail on binary
            [[ -z "$s" ]] && s=0
            [[ -z "$d" ]] && d=0
            TOTAL_STARTED=$(( TOTAL_STARTED + s ))
            TOTAL_DONE=$(( TOTAL_DONE + d ))
        fi
    done

    printf "\r  [%02d:%02d] %d/%d shards running | %d tests started | %d completed    " \
        "$ELAPSED_MIN" "$ELAPSED_SEC" "$RUNNING" "$SHARDS" "$TOTAL_STARTED" "$TOTAL_DONE"

    [[ "$RUNNING" -eq 0 ]] && break
    sleep 30
done

echo ""
echo ""

# ─── Collect and aggregate results ───────────────────────────────────────────
echo "→ All shards finished. Aggregating results ..."
echo ""

TOTAL_PASSED=0
TOTAL_FAILED=0
TOTAL_NOTRUN=0
ALL_FAILED_TESTS=()

for (( i=0; i<SHARDS; i++ )); do
    LOG="${SHARD_LOGS[$i]}"
    echo "  ── Shard $i ──────────────────────────────────────────────────"

    if [[ ! -f "$LOG" ]]; then
        echo "  WARNING: log file not found: $LOG"
        continue
    fi

    # Extract summary lines from fstests check output
    if grep -q "^Passed all" "$LOG" 2>/dev/null; then
        passed=$(grep "^Passed all" "$LOG" | grep -oP '\d+' | head -1)
        passed=${passed:-0}
        echo "  Passed: $passed tests"
        TOTAL_PASSED=$(( TOTAL_PASSED + passed ))
    fi

    if grep -q "^Failed [0-9]" "$LOG" 2>/dev/null; then
        n=$(grep "^Failed [0-9]" "$LOG" | grep -oP '^\S+ \K\d+' | head -1)
        n=${n:-0}
        TOTAL_FAILED=$(( TOTAL_FAILED + n ))
        echo "  Failed: $n tests"
    fi

    if grep -q "^Failures:" "$LOG" 2>/dev/null; then
        failed_line=$(grep "^Failures:" "$LOG" | head -1)
        echo "  $failed_line"
        # Extract individual test names from the Failures: line
        while IFS= read -r t; do
            [[ -n "$t" ]] && ALL_FAILED_TESTS+=("$t")
        done < <(echo "$failed_line" | sed 's/^Failures: //' | tr ' ' '\n')
    fi

    if grep -q "^Not run:" "$LOG" 2>/dev/null; then
        notrun_line=$(grep "^Not run:" "$LOG" | head -1)
        notrun_count=$(echo "$notrun_line" | sed 's/^Not run: //' | wc -w)
        TOTAL_NOTRUN=$(( TOTAL_NOTRUN + notrun_count ))
        echo "  Not run: $notrun_count tests"
    fi
done

# ─── Extract per-test results from rootfs images ─────────────────────────────
echo ""
echo "→ Extracting per-test result files from shard rootfs images ..."
for (( i=0; i<SHARDS; i++ )); do
    SHARD_DIR="${IMG_BASE_DIR}/uml-shard-${i}"
    MOUNT_POINT="${SHARD_DIR}/mnt"
    SHARD_RESULTS="${RESULTS_DIR}/shard-${i}-results"
    mkdir -p "$SHARD_RESULTS" "$MOUNT_POINT"
    sudo mount -o loop,ro "${ROOTFS_COPIES[$i]}" "$MOUNT_POINT" 2>/dev/null && \
        sudo cp -r "$MOUNT_POINT/results/." "$SHARD_RESULTS/" 2>/dev/null && \
        sudo umount "$MOUNT_POINT" 2>/dev/null || true
    echo "  Shard $i: results in $SHARD_RESULTS"
done

# ─── Final summary ───────────────────────────────────────────────────────────
ELAPSED=$(( $(date +%s) - START_TIME ))
ELAPSED_MIN=$(( ELAPSED / 60 ))
ELAPSED_SEC=$(( ELAPSED % 60 ))

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                    FINAL RESULTS                            ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
printf "  Total time      : %02d min %02d sec\n" "$ELAPSED_MIN" "$ELAPSED_SEC"
echo "  Total tests     : $TOTAL_TESTS"
echo "  Passed          : $TOTAL_PASSED"
echo "  Failed          : $TOTAL_FAILED"
echo "  Not run         : $TOTAL_NOTRUN"
echo ""

if [[ "${#ALL_FAILED_TESTS[@]}" -gt 0 ]]; then
    echo "  Failed tests:"
    for t in "${ALL_FAILED_TESTS[@]}"; do
        echo "    - $t"
    done
    echo ""
fi

echo "  Shard logs      : $RESULTS_DIR/shard-*.log"
echo "  Per-test results: $RESULTS_DIR/shard-*-results/"
echo ""

# ─── Cleanup tmpfs shard directories ─────────────────────────────────────────
if [[ "$USE_TMPFS" == "true" ]]; then
    echo "→ Cleaning up shard directories from $TMPFS_DIR ..."
    for (( i=0; i<SHARDS; i++ )); do
        rm -rf "${IMG_BASE_DIR}/uml-shard-${i}" \
               "${IMG_BASE_DIR}/shard-${i}-tests.txt" 2>/dev/null || true
    done
    echo "  ✓ Cleanup complete"
fi

echo ""
echo "Done. Full logs available in: $RESULTS_DIR"
