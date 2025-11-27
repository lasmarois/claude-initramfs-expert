#!/bin/bash
#
# validate-initramfs.sh - Validate initramfs structure and contents
#
# Usage: ./validate-initramfs.sh /path/to/initramfs.img
#        ./validate-initramfs.sh /path/to/initramfs/directory
#
# Exit codes:
#   0 - All checks passed
#   1 - Critical error (won't boot)
#   2 - Warning (may cause issues)
#

set -e

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

ERRORS=0
WARNINGS=0

error() {
    echo -e "${RED}[ERROR]${NC} $*"
    ERRORS=$((ERRORS + 1))
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
    WARNINGS=$((WARNINGS + 1))
}

ok() {
    echo -e "${GREEN}[OK]${NC} $*"
}

info() {
    echo -e "[INFO] $*"
}

usage() {
    echo "Usage: $0 <initramfs.img|initramfs-directory>"
    echo ""
    echo "Validates an initramfs image or extracted directory for common issues."
    exit 1
}

# Check if argument provided
[ -z "$1" ] && usage

TARGET="$1"
TMPDIR=""

# Handle compressed image vs directory
if [ -f "$TARGET" ]; then
    info "Extracting initramfs image for analysis..."
    TMPDIR=$(mktemp -d)
    trap "rm -rf $TMPDIR" EXIT
    
    cd "$TMPDIR"
    
    # Detect compression and extract
    case "$(file -b "$TARGET")" in
        *gzip*)
            zcat "$TARGET" | cpio -idm 2>/dev/null
            ;;
        *XZ*)
            xzcat "$TARGET" | cpio -idm 2>/dev/null
            ;;
        *bzip2*)
            bzcat "$TARGET" | cpio -idm 2>/dev/null
            ;;
        *cpio*)
            cpio -idm < "$TARGET" 2>/dev/null
            ;;
        *)
            error "Unknown archive format"
            exit 1
            ;;
    esac
    
    INITRAMFS_ROOT="$TMPDIR"
elif [ -d "$TARGET" ]; then
    INITRAMFS_ROOT="$TARGET"
else
    error "Target not found: $TARGET"
    exit 1
fi

cd "$INITRAMFS_ROOT"

echo ""
echo "=========================================="
echo "Validating initramfs: $TARGET"
echo "=========================================="
echo ""

# === Critical Checks ===

echo "--- Critical Checks ---"

# Check for /init
if [ -f "init" ]; then
    if [ -x "init" ]; then
        ok "/init exists and is executable"
        
        # Check shebang
        SHEBANG=$(head -c 100 init | head -1)
        case "$SHEBANG" in
            "#!/bin/sh"*|"#!/bin/busybox"*|"#!/bin/bash"*)
                ok "/init has valid shebang: $SHEBANG"
                ;;
            *)
                warn "/init shebang may be non-portable: $SHEBANG"
                ;;
        esac
    else
        error "/init exists but is NOT executable"
    fi
else
    error "/init not found - initramfs will not boot"
fi

# Check for busybox
if [ -f "bin/busybox" ]; then
    ok "/bin/busybox exists"
    
    # Check if statically linked
    if command -v file >/dev/null 2>&1; then
        LINK_TYPE=$(file bin/busybox)
        if echo "$LINK_TYPE" | grep -q "statically linked"; then
            ok "busybox is statically linked"
        elif echo "$LINK_TYPE" | grep -q "dynamically linked"; then
            warn "busybox is dynamically linked - ensure required libraries are included"
        fi
    fi
else
    warn "/bin/busybox not found - ensure shell is available"
fi

# Check essential directories
echo ""
echo "--- Directory Structure ---"

for dir in bin dev etc lib mnt proc run sys; do
    if [ -d "$dir" ]; then
        ok "/$dir exists"
    else
        case "$dir" in
            proc|sys|run|mnt)
                warn "/$dir missing (will be created at runtime)"
                ;;
            *)
                error "/$dir missing"
                ;;
        esac
    fi
done

# Check for root mount point
if [ -d "mnt/root" ] || [ -d "sysroot" ] || [ -d "newroot" ]; then
    ok "Root mount point exists"
else
    warn "No root mount point (mnt/root, sysroot, or newroot)"
fi

# Check device nodes
echo ""
echo "--- Device Nodes ---"

if [ -c "dev/console" ] 2>/dev/null; then
    ok "/dev/console exists"
else
    error "/dev/console missing - kernel console output will fail"
fi

if [ -c "dev/null" ] 2>/dev/null; then
    ok "/dev/null exists"
else
    warn "/dev/null missing - some commands may fail"
fi

# Check /init content for common issues
echo ""
echo "--- Init Script Analysis ---"

if [ -f "init" ]; then
    INIT_CONTENT=$(cat init)
    
    # Check for switch_root
    if echo "$INIT_CONTENT" | grep -q "switch_root"; then
        ok "switch_root found in /init"
        
        # Check if exec is used with switch_root
        if echo "$INIT_CONTENT" | grep -q "exec.*switch_root\|exec switch_root"; then
            ok "switch_root called with exec (correct)"
        else
            warn "switch_root may not be called with exec - PID 1 must be maintained"
        fi
    else
        warn "switch_root not found - custom pivot mechanism?"
    fi
    
    # Check mount commands
    if echo "$INIT_CONTENT" | grep -q "mount.*devtmpfs\|mount -t devtmpfs"; then
        ok "devtmpfs mount found"
    else
        warn "devtmpfs mount not found - device nodes may not be available"
    fi
    
    if echo "$INIT_CONTENT" | grep -q "mount.*proc"; then
        ok "/proc mount found"
    else
        error "/proc mount not found - kernel command line parsing will fail"
    fi
    
    if echo "$INIT_CONTENT" | grep -q "mount.*/run\|mount.*tmpfs.*/run"; then
        ok "/run mount found"
    else
        warn "/run mount not found - systemd handoff may fail"
    fi
    
    # Check for emergency shell
    if echo "$INIT_CONTENT" | grep -q "rescue_shell\|emergency\|/bin/sh"; then
        ok "Emergency shell fallback found"
    else
        warn "No emergency shell fallback - debugging boot failures will be difficult"
    fi
fi

# Check for common binaries
echo ""
echo "--- Binary Availability ---"

for bin in sh mount umount switch_root; do
    if [ -x "bin/$bin" ] || [ -x "sbin/$bin" ] || [ -L "bin/$bin" ] || [ -L "sbin/$bin" ]; then
        ok "$bin available"
    else
        # Check if it's a busybox applet
        if [ -x "bin/busybox" ] && bin/busybox --list 2>/dev/null | grep -q "^${bin}$"; then
            ok "$bin available (busybox applet)"
        else
            error "$bin not found"
        fi
    fi
done

# Optional but useful binaries
for bin in findfs blkid modprobe sleep cat grep; do
    if [ -x "bin/$bin" ] || [ -x "sbin/$bin" ] || [ -L "bin/$bin" ] || [ -L "sbin/$bin" ]; then
        ok "$bin available"
    elif [ -x "bin/busybox" ] && bin/busybox --list 2>/dev/null | grep -q "^${bin}$"; then
        ok "$bin available (busybox applet)"
    else
        info "$bin not found (optional)"
    fi
done

# Summary
echo ""
echo "=========================================="
echo "Validation Summary"
echo "=========================================="
echo ""

if [ $ERRORS -gt 0 ]; then
    echo -e "${RED}ERRORS: $ERRORS${NC} - initramfs may not boot"
fi

if [ $WARNINGS -gt 0 ]; then
    echo -e "${YELLOW}WARNINGS: $WARNINGS${NC} - review recommended"
fi

if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
    echo -e "${GREEN}All checks passed!${NC}"
fi

echo ""

# Exit with appropriate code
if [ $ERRORS -gt 0 ]; then
    exit 1
elif [ $WARNINGS -gt 0 ]; then
    exit 2
else
    exit 0
fi
