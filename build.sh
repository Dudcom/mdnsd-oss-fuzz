#!/bin/bash -eu

# mdnsd OSS-Fuzz Build Script
echo "Building mdnsd fuzzer..."

# Update package list and install basic dependencies
apt-get update
apt-get install -y build-essential cmake pkg-config git libjson-c-dev patchelf

# Set up dependencies directory
DEPS_DIR="$PWD/deps"
mkdir -p "$DEPS_DIR"
cd "$DEPS_DIR"

# Download and build libubox (required dependency for mdnsd)
if [ ! -d "libubox" ]; then
    echo "Downloading libubox..."
    git clone https://github.com/openwrt/libubox.git
    cd libubox
    # Remove unnecessary components to avoid CMake errors
    rm -rf tests examples lua
    # Patch CMakeLists.txt to remove references to examples and lua
    sed -i '/ADD_SUBDIRECTORY(examples)/d' CMakeLists.txt 2>/dev/null || true
    sed -i '/ADD_SUBDIRECTORY(lua)/d' CMakeLists.txt 2>/dev/null || true
    cd ..
fi

cd libubox
mkdir -p build
cd build
cmake .. -DCMAKE_INSTALL_PREFIX="$DEPS_DIR/install" \
         -DCMAKE_C_FLAGS="$CFLAGS" \
         -DBUILD_LUA=OFF \
         -DBUILD_EXAMPLES=OFF \
         -DBUILD_TESTS=OFF \
         -DBUILD_STATIC=OFF \
         -DBUILD_SHARED_LIBS=ON
make -j$(nproc)
make install
cd "$DEPS_DIR"

# Go back to source directory
cd ..

# Set up compiler flags and paths
: "${CFLAGS:=-O2 -fPIC}"
: "${LDFLAGS:=}"
: "${PKG_CONFIG_PATH:=}"
: "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"

# Add required flags for the build
export CFLAGS="$CFLAGS -D_GNU_SOURCE -std=gnu99"
export CFLAGS="$CFLAGS -I$DEPS_DIR/install/include"
export LDFLAGS="$LDFLAGS -L$DEPS_DIR/install/lib"
export PKG_CONFIG_PATH="$DEPS_DIR/install/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

echo "Compiling mdnsd source files..."

# List of source files to compile (excluding main.c as we have our own fuzzer entry point)
SOURCE_FILES=(
    "cache.c"
    "dns.c" 
    "interface.c"
    "service.c"
    "util.c"
    "ubus.c"
    "announce.c"
)

# Compile individual source files
OBJECT_FILES=()
for src_file in "${SOURCE_FILES[@]}"; do
    if [ -f "$src_file" ]; then
        echo "Compiling $src_file..."
        obj_file="${src_file%.c}.o"
        $CC $CFLAGS -c "$src_file" -o "$obj_file"
        OBJECT_FILES+=("$obj_file")
    else
        echo "Warning: $src_file not found, skipping..."
    fi
done

echo "Compiling fuzzer..."
$CC $CFLAGS -c mdnsd-fuzz.c -o mdnsd-fuzz.o

echo "Linking fuzzer..."
# Link the fuzzer with all components
$CC $CFLAGS $LIB_FUZZING_ENGINE mdnsd-fuzz.o \
    "${OBJECT_FILES[@]}" \
    $LDFLAGS -lubox -ljson-c \
    -o $OUT/mdnsd_fuzzer

# Set correct rpath for OSS-Fuzz
echo "Setting rpath with patchelf..."
patchelf --set-rpath '$ORIGIN/lib' $OUT/mdnsd_fuzzer

# Copy all required shared library dependencies
echo "Finding and copying shared library dependencies..."

# Create lib directory
mkdir -p "$OUT/lib"

# First, copy libubox from our custom installation
echo "Copying libubox from custom installation..."
if [ -f "$DEPS_DIR/install/lib/libubox.so" ]; then
    cp "$DEPS_DIR/install/lib/libubox.so"* "$OUT/lib/" 2>/dev/null || true
    echo "Copied libubox.so"
fi

# Copy other dependencies
copy_library_deps() {
    local binary="$1"
    local out_lib="$2"
    
    echo "Copying dependencies for $binary"
    
    # Get all dependencies using ldd
    ldd "$binary" 2>/dev/null | while read line; do
        # Extract library path from ldd output
        if [[ $line =~ '=>' ]]; then
            lib_path=$(echo "$line" | awk '{print $3}')
            if [[ -f "$lib_path" ]]; then
                lib_name=$(basename "$lib_path")
                # Skip system libraries that are always available
                if [[ ! "$lib_name" =~ ^(ld-linux|libc\.so|libm\.so|libpthread\.so|libdl\.so|librt\.so|libresolv\.so) ]]; then
                    if [[ "$lib_name" =~ ^(libjson-c|libubox) ]]; then
                        echo "Copying $lib_name from $lib_path"
                        cp "$lib_path" "$out_lib/" 2>/dev/null || true
                    fi
                fi
            fi
        fi
    done
}

copy_library_deps "$OUT/mdnsd_fuzzer" "$OUT/lib"



echo "Verifying fuzzer binary..."
if [ -f "$OUT/mdnsd_fuzzer" ]; then
    echo "Fuzzer binary created successfully"
    echo "Binary size: $(stat -c%s "$OUT/mdnsd_fuzzer") bytes"
    
    # Test that it can run briefly
    echo "Testing fuzzer (dry run)..."
    timeout 5 $OUT/mdnsd_fuzzer -help 2>/dev/null || echo "Fuzzer help completed"
    
    # Check dependencies
    echo "Binary dependencies:"
    ldd $OUT/mdnsd_fuzzer || echo "Some dependencies may be in lib/ directory"
    
    echo "Libraries in $OUT/lib:"
    ls -la $OUT/lib/ 2>/dev/null || echo "No additional libraries"
    
    echo "Seed corpus files:"
    ls -la $OUT/mdnsd_fuzzer_seed_corpus/ 2>/dev/null || echo "No seed corpus"
    
else
    echo  "Failed to create fuzzer binary!"
    exit 1
fi

# Clean up build artifacts
echo "Cleaning up..."
rm -f *.o

echo "mdnsd fuzzer build completed successfully!"
echo "Fuzzer: $OUT/mdnsd_fuzzer"
echo "Seed corpus: $OUT/mdnsd_fuzzer_seed_corpus"
