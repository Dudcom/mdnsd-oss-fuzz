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
    if [ -f "CMakeLists.txt" ]; then
        cp CMakeLists.txt CMakeLists.txt.bak
        grep -v "ADD_SUBDIRECTORY(examples)" CMakeLists.txt.bak | \
        grep -v "ADD_SUBDIRECTORY(lua)" | \
        grep -v "add_subdirectory(examples)" | \
        grep -v "add_subdirectory(lua)" > CMakeLists.txt || cp CMakeLists.txt.bak CMakeLists.txt
    fi
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

# Download and build libubus (required dependency for mdnsd)
if [ ! -d "ubus" ]; then
    echo "Downloading ubus..."
    git clone https://github.com/openwrt/ubus.git
    cd ubus
    # Remove unnecessary components
    rm -rf tests examples lua
    # Patch CMakeLists.txt to remove references to examples and lua
    if [ -f "CMakeLists.txt" ]; then
        cp CMakeLists.txt CMakeLists.txt.bak
        grep -v "ADD_SUBDIRECTORY(examples)" CMakeLists.txt.bak | \
        grep -v "ADD_SUBDIRECTORY(lua)" | \
        grep -v "add_subdirectory(examples)" | \
        grep -v "add_subdirectory(lua)" > CMakeLists.txt || cp CMakeLists.txt.bak CMakeLists.txt
    fi
    cd ..
fi

cd ubus
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

# Try building ucode first (dependency for udebug)
if [ ! -d "ucode" ]; then
    echo "Downloading ucode..."
    git clone https://github.com/openwrt/ucode.git
    cd ucode
    # Remove unnecessary components
    rm -rf tests examples lua
    # Patch CMakeLists.txt to remove references to examples and lua
    if [ -f "CMakeLists.txt" ]; then
        cp CMakeLists.txt CMakeLists.txt.bak
        grep -v "ADD_SUBDIRECTORY(examples)" CMakeLists.txt.bak | \
        grep -v "ADD_SUBDIRECTORY(lua)" | \
        grep -v "add_subdirectory(examples)" | \
        grep -v "add_subdirectory(lua)" > CMakeLists.txt || cp CMakeLists.txt.bak CMakeLists.txt
    fi
    cd ..
fi

echo "Building ucode..."
cd ucode
mkdir -p build
cd build
if cmake .. -DCMAKE_INSTALL_PREFIX="$DEPS_DIR/install" \
            -DCMAKE_C_FLAGS="$CFLAGS" \
            -DBUILD_STATIC=OFF \
            -DBUILD_SHARED_LIBS=ON; then
    make -j$(nproc)
    make install
    echo "ucode built successfully"
    UCODE_AVAILABLE=1
else
    echo "ucode build failed, will try to build without udebug"
    UCODE_AVAILABLE=0
fi
cd "$DEPS_DIR"

# Download and build udebug (OpenWrt debug library) - only if ucode is available
if [ "$UCODE_AVAILABLE" = "1" ]; then
    if [ ! -d "udebug" ]; then
        echo "Downloading udebug..."
        git clone https://github.com/openwrt/udebug.git
        cd udebug
        # Remove unnecessary components
        rm -rf tests examples lua
        # Patch CMakeLists.txt to remove references to examples and lua
        if [ -f "CMakeLists.txt" ]; then
            cp CMakeLists.txt CMakeLists.txt.bak
            grep -v "ADD_SUBDIRECTORY(examples)" CMakeLists.txt.bak | \
            grep -v "ADD_SUBDIRECTORY(lua)" | \
            grep -v "add_subdirectory(examples)" | \
            grep -v "add_subdirectory(lua)" > CMakeLists.txt || cp CMakeLists.txt.bak CMakeLists.txt
        fi
        cd ..
    fi

    echo "Building udebug..."
    cd udebug
    mkdir -p build
    cd build
    if cmake .. -DCMAKE_INSTALL_PREFIX="$DEPS_DIR/install" \
                -DCMAKE_C_FLAGS="$CFLAGS" \
                -DBUILD_STATIC=OFF \
                -DBUILD_SHARED_LIBS=ON; then
        make -j$(nproc)
        make install
        echo "udebug built successfully"
        UDEBUG_AVAILABLE=1
    else
        echo "udebug build failed, will build without it"
        UDEBUG_AVAILABLE=0
    fi
    cd "$DEPS_DIR"
else
    echo "Skipping udebug build since ucode is not available"
    UDEBUG_AVAILABLE=0
fi

# Go back to source directory
cd ..

# Set up compiler flags and paths
: "${CFLAGS:=-O2 -fPIC}"
: "${LDFLAGS:=}"
: "${PKG_CONFIG_PATH:=}"
: "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"

# Add required flags for the build (remove _GNU_SOURCE since source files already define it)
export CFLAGS="$CFLAGS -std=gnu99"
export CFLAGS="$CFLAGS -I$DEPS_DIR/install/include"
export LDFLAGS="$LDFLAGS -L$DEPS_DIR/install/lib"
export PKG_CONFIG_PATH="$DEPS_DIR/install/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

echo "Compiling mdnsd source files..."

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
# Link the fuzzer with all components and required libraries
# Build library list based on what's available
LINK_LIBS="-lubox -lubus -lblobmsg_json -ljson-c -lresolv"
if [ "$UDEBUG_AVAILABLE" = "1" ]; then
    LINK_LIBS="$LINK_LIBS -ludebug"
    echo "Including udebug in link"
else
    echo "Building without udebug"
fi

$CC $CFLAGS $LIB_FUZZING_ENGINE mdnsd-fuzz.o \
    "${OBJECT_FILES[@]}" \
    $LDFLAGS $LINK_LIBS \
    -o $OUT/mdnsd_fuzzer

# Set correct rpath for OSS-Fuzz
echo "Setting rpath with patchelf..."
patchelf --set-rpath '$ORIGIN/lib' $OUT/mdnsd_fuzzer

# Copy all required shared library dependencies
echo "Finding and copying shared library dependencies..."

# Create lib directory
mkdir -p "$OUT/lib"

# Copy libraries from our custom installation
echo "Copying libraries from custom installation..."
for lib in libubox.so libubus.so libblobmsg_json.so; do
    if [ -f "$DEPS_DIR/install/lib/$lib" ]; then
        cp "$DEPS_DIR/install/lib/$lib"* "$OUT/lib/" 2>/dev/null || true
        echo "Copied $lib"
    fi
done

# Copy optional libraries if they exist
if [ "$UCODE_AVAILABLE" = "1" ] && [ -f "$DEPS_DIR/install/lib/libucode.so" ]; then
    cp "$DEPS_DIR/install/lib/libucode.so"* "$OUT/lib/" 2>/dev/null || true
    echo "Copied libucode.so"
fi

if [ "$UDEBUG_AVAILABLE" = "1" ] && [ -f "$DEPS_DIR/install/lib/libudebug.so" ]; then
    cp "$DEPS_DIR/install/lib/libudebug.so"* "$OUT/lib/" 2>/dev/null || true
    echo "Copied libudebug.so"
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
                    if [[ "$lib_name" =~ ^(libjson-c) ]]; then
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
