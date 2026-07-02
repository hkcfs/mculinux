#!/bin/bash
# Test MCUlinux packages

set -e

OUTPUT_DIR="${OUTPUT_DIR:-/output}"
TEST_DIR="${TEST_DIR:-/tests}"

echo "Testing MCUlinux packages"

# Create test environment
mkdir -p "$TEST_DIR"

# Test each package
PACKAGES=("busybox" "htop" "btop" "nano" "coreutils" "bash")

for package in "${PACKAGES[@]}"; do
    echo "Testing package: $package"
    
    # Create test script
    cat > "$TEST_DIR/test-$package.sh" << EOF
#!/bin/bash
# Test $package installation

echo "Installing $package..."
apk add $package

echo "Testing $package..."
case "$package" in
    busybox)
        busybox --help
        ;;
    htop)
        htop --version
        ;;
    btop)
        btop --version
        ;;
    nano)
        nano --version
        ;;
    coreutils)
        ls --version
        ;;
    bash)
        bash --version
        ;;
esac

echo "Package $package test completed"
EOF
    
    chmod +x "$TEST_DIR/test-$package.sh"
    
    # Run test in container
    docker run --rm \
        -v "$OUTPUT_DIR":/output \
        -v "$TEST_DIR":/tests \
        alpine:3.19 \
        /tests/test-$package.sh
    
    echo "Package $package: PASSED"
done

echo "All package tests completed"

# Create test report
cat > "$TEST_DIR/test-report.json" << EOF
{
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "packages": [
        "busybox",
        "htop",
        "btop",
        "nano",
        "coreutils",
        "bash"
    ],
    "status": "passed"
}
EOF

echo "Test report saved to $TEST_DIR/test-report.json"
