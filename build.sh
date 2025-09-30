#!/usr/bin/env bash
#
# Script Pembangunan Kernel
# Diadaptasi dari build.sh yang disediakan.
#
# Menggunakan Image.gz sebagai output akhir dan linker ld.lld (default).
#

# Keluar segera jika ada perintah yang gagal
set -eo pipefail

## Deklarasi Fungsi Utama
#---------------------------------------------------------------------------------

# Fungsi untuk mengirim pesan ke Telegram
tg_post_msg() {
    local message="$1"
    curl -s -X POST "$BOT_MSG_URL" \
        -d chat_id="$TG_CHAT_ID" \
        -d "disable_web_page_preview=true" \
        -d "parse_mode=html" \
        -d text="$message"
}

# Fungsi untuk menangani kegagalan (find error)
function finerr() {
    local LOG_FILE="build.log"
    local LOG_URL="https://api.cirrus-ci.com/v1/task/$CIRRUS_TASK_ID/logs/Build_kernel.log"
    
    echo "Pembangunan GAGAL. Mencoba mengambil log dari $LOG_URL..." >&2
    
    # Ambil log
    if wget "$LOG_URL" -O "$LOG_FILE"; then
        # KASUS BERHASIL: Log berhasil diambil dan akan dikirim
        echo "Log berhasil diambil. Mengirim log kegagalan ke Telegram..." >&2
        
        # Kirim dokumen log
        curl -F document=@"$LOG_FILE" "$BOT_DOC_URL" \
            -F chat_id="$TG_CHAT_ID" \
            -F "disable_web_page_preview=true" \
            -F "parse_mode=html" \
            -F caption="==============================%0A<b>    Building Kernel CLANG Failed [❌]</b>%0A<b>        Jiancong Tenan 🤬</b>%0A=============================="
        
    else
        # KASUS GAGAL: Gagal mengambil log (misal, URL tidak valid/timeout)
        echo "Gagal mengambil log dari Cirrus CI. Mengirim pesan error tanpa file log." >&2
        tg_post_msg "<b>Pembangunan Kernel Gagal [❌]</b>%0A<b>Kesalahan:</b> Gagal mendapatkan log dari Cirrus CI. Silakan cek Cirrus secara manual: <a href=\"https://cirrus-ci.com/task/$CIRRUS_TASK_ID\">Task ID $CIRRUS_TASK_ID</a>"
    fi
    
    # Kirim stiker terlepas dari berhasil atau tidaknya pengiriman log (optional)
    curl -s -X POST "$BOT_MSG_URL/../sendSticker" \
        -d sticker="CAACAgQAAx0EabRMmQACAnRjEUAXBTK1Ei_zbJNPFH7WCLzSdAACpBEAAqbxcR716gIrH45xdB4E" \
        -d chat_id="$TG_CHAT_ID"

    # Keluar dengan kode error 1
    exit 1
}

# Mengatur variabel lingkungan
function setup_env() {
    # Pastikan semua variabel Cirrus CI yang diperlukan ada, ini hanya contoh.
    : "${CIRRUS_WORKING_DIR:?Error: CIRRUS_WORKING_DIR not set}"
    : "${DEVICE_CODENAME:?Error: DEVICE_CODENAME not set}"
    : "${TG_TOKEN:?Error: TG_TOKEN not set}"
    : "${TG_CHAT_ID:?Error: TG_CHAT_ID not set}"
    : "${BUILD_USER:?Error: BUILD_USER not set}"
    : "${BUILD_HOST:?Error: BUILD_HOST not set}"
    : "${ANYKERNEL:?Error: ANYKERNEL not set}"
    : "${CIRRUS_TASK_ID:?Error: CIRRUS_TASK_ID not set}"

    # --- Core Build Variables ---
    export ARCH="${ARCH:-arm64}" 
    export CONFIG="${CONFIG:-vendor/bengal-perf_defconfig}" 
    export CLANG_DIR="${CLANG_DIR:-$CIRRUS_WORKING_DIR/greenforce-clang}" 
    
    # LD_IMPL DIHAPUS, akan menggunakan ld.lld hardcoded di compile()
    
    export KERNEL_NAME="mrt-Kernel"
    local KERNEL_ROOTDIR_BASE="$CIRRUS_WORKING_DIR/$DEVICE_CODENAME"
    export KERNEL_ROOTDIR="$KERNEL_ROOTDIR_BASE"
    export DEVICE_DEFCONFIG="$CONFIG" 
    export CLANG_ROOTDIR="$CLANG_DIR" 
    export KERNEL_OUTDIR="$KERNEL_ROOTDIR/out"

    # Verifikasi keberadaan dan versi toolchain
    if [ ! -d "$CLANG_ROOTDIR" ] || [ ! -f "$CLANG_ROOTDIR/bin/clang" ]; then
        echo "Error: Toolchain (Clang) tidak ditemukan di $CLANG_ROOTDIR." >&2
        exit 1
    fi

    # Mendapatkan versi toolchain
    CLANG_VER="$("$CLANG_ROOTDIR"/bin/clang --version | head -n 1 | perl -pe 's/\(http.*?\)//gs' | sed -e 's/  */ /g' -e 's/[[:space:]]*$//')"
    LLD_VER="$("$CLANG_ROOTDIR"/bin/ld.lld --version | head -n 1)" # Menggunakan ld.lld default

    # Export variabel KBUILD
    export KBUILD_BUILD_USER="$BUILD_USER"
    export KBUILD_BUILD_HOST="$BUILD_HOST"
    export KBUILD_COMPILER_STRING="$CLANG_VER with $LLD_VER"

    # Variabel lain
    # Diubah: Kembali ke Image.gz
    export IMAGE="$KERNEL_OUTDIR/arch/$ARCH/boot/Image.gz" 
    export DATE=$(date +"%Y%m%d-%H%M%S") 
    export BOT_MSG_URL="https://api.telegram.org/bot$TG_TOKEN/sendMessage"
    export BOT_DOC_URL="https://api.telegram.org/bot$TG_TOKEN/sendDocument"

    # Menyimpan waktu mulai
    export START=$(date +"%s")
    
    # --- Flag KSU dan Variabel ---
    export KSU_ENABLE="${KSU_ENABLE:-false}"          
    export KSU_VERSION="${KSU_VERSION:-main}"        
    export KSU_LKM_ENABLE="${KSU_LKM_ENABLE:-false}" 
    export KSU_OTHER_ENABLE="${KSU_OTHER_ENABLE:-false}" 
    export KSU_OTHER_URL="${KSU_OTHER_URL:-https://raw.githubusercontent.com/tiann/KernelSU}" 
}

# Menampilkan info lingkungan
function check() {
    echo "================================================"
    echo "              _  __  ____  ____               "
    echo "             / |/ / / __/ / __/               "
    echo "      __    /    / / _/  _\ \    __           "
    echo "     /_/   /_/|_/ /_/   /___/   /_/           "
    echo "    ___  ___  ____     _________________      "
    echo "   / _ \/ _ \/ __ \__ / / __/ ___/_  __/      "
    echo "  / ___/ , _/ /_/ / // / _// /__  / /         "
    echo " /_/  /_/|_|\____/\___/___/\___/ /_/          "
    echo "================================================"
    echo "BUILDER NAME         = ${KBUILD_BUILD_USER}"
    echo "ARCH                 = ${ARCH}" 
    echo "LINKER               = ld.lld (Default)" # Tampilkan nilai default
    echo "DEVICE_DEFCONFIG     = ${DEVICE_DEFCONFIG}"
    echo "TOOLCHAIN_VERSION    = ${KBUILD_COMPILER_STRING}"
    echo "KERNEL_ROOTDIR       = ${KERNEL_ROOTDIR}"
    echo "KSU_ENABLE           = ${KSU_ENABLE}" 
    echo "KSU_VERSION          = ${KSU_VERSION}"
    echo "KSU_LKM_ENABLE       = ${KSU_LKM_ENABLE}"
    echo "================================================"
}

# Proses kompilasi kernel (VERSI MODIFIKASI UNTUK MENGHINDARI RESTART CONFIG)
function compile() {
    cd "$KERNEL_ROOTDIR"

    tg_post_msg "<b>Buiild Kernel started..</b>%0A<b>Defconfig:</b> <code>$DEVICE_DEFCONFIG</code>%0A<b>Toolchain:</b> <code>$KBUILD_COMPILER_STRING</code>%0A<b>Arsitektur:</b> <code>$ARCH</code>"
    
    # --- Pembersihan Otomatis ---
    rm -rf "$KERNEL_OUTDIR"
    mkdir -p "$KERNEL_OUTDIR"
    
    # 1. KONFIGURASI DEFCONFIG AWAL
    echo "Membuat defconfig awal..."
    make -j$(nproc) O="$KERNEL_OUTDIR" ARCH="$ARCH" "$DEVICE_DEFCONFIG" || finerr
    
    # --- START Blok Conditional KSU Integration ---
    if [[ "$KSU_ENABLE" == "true" ]]; then
        echo "================================================"
        echo "           Memeriksa dan Mengintegrasikan Root Kernel"
        echo "================================================"
        
        if [ -f $KERNEL_ROOTDIR/KernelSU/kernel/Kconfig ]; then
            echo "KernelSU/SukiSU sudah terintegrasi, dilewati."
        else
            if [[ "$KSU_OTHER_ENABLE" == "true" ]]; then
                echo "Menggunakan URL KSU/SukiSU Kustom: $KSU_OTHER_URL, Versi: $KSU_VERSION"
                curl -SsL "$KSU_OTHER_URL/$KSU_VERSION/kernel/setup.sh" | bash -s "$KSU_VERSION" || finerr
            else
                KVER="$KSU_VERSION"
                
                if [ -f nongki.txt ]; then
                    printf "Peringatan: Kernel dideteksi non-GKI. Versi KernelSU akan dipaksa ke v0.9.5 (jika KVER lebih baru).\n"
                    if [[ "$KVER" != "v0.9.5" ]]; then
                         KVER="v0.9.5"
                    fi
                fi
                
                echo "Mengintegrasikan KernelSU versi: $KVER dari tiann/KernelSU."
                curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -s "$KVER" || finerr
            fi
        fi
        
        if [[ "$KSU_LKM_ENABLE" == "true" ]]; then
            echo "Mengaktifkan KernelSU sebagai LKM (Loadable Kernel Module)."
            if [ -f $KERNEL_ROOTDIR/drivers/kernelsu/Kconfig ]; then
                sed -i '/config KSU/,/help/{s/default y/default m/}' $KERNEL_ROOTDIR/drivers/kernelsu/Kconfig || echo "Peringatan: Gagal mengubah KSU menjadi LKM di Kconfig."
            else
                echo "Peringatan: drivers/kernelsu/Kconfig tidak ditemukan, gagal mengatur KSU sebagai LKM."
            fi
        fi
        
        # 2. SINKRONISASI KONFIGURASI SETELAH MODIFIKASI KSU
        echo "Integrasi KernelSU/SukiSU Selesai. Mensinkronkan konfigurasi (olddefconfig)..."
        # Ini penting untuk mengadopsi perubahan Kconfig yang dilakukan oleh KSU ke .config
        # dan mencegah 'Restart config' saat kompilasi penuh.
        make -j$(nproc) O="$KERNEL_OUTDIR" ARCH="$ARCH" olddefconfig || finerr 
        
    elif [ -f nongki.txt ]; then
        echo "Kernel Non-GKI terdeteksi. Harap pastikan CONFIG_KPROBES=y sudah diaktifkan, atau patching manual diperlukan."
    else
        echo "================================================"
        echo "   ROOT KERNEL DINETRALKAN. Melanjutkan build bersih."
        echo "   Untuk mengaktifkan, set KSU_ENABLE=true."
        echo "================================================"
    fi
    # --- END Blok Conditional KSU Integration ---
    
    echo "Lanjutkan ke kompilasi."
    
    # 3. Kompilasi
    local BIN_DIR="$CLANG_ROOTDIR/bin"
    
    # Tentukan prefix cross-compile berdasarkan ARCH
    local CC_PREFIX
    local CC32_PREFIX

    if [[ "$ARCH" == "arm64" ]]; then
        CC_PREFIX="aarch64-linux-gnu-"
        CC32_PREFIX="arm-linux-gnueabi-"
    elif [[ "$ARCH" == "arm" ]]; then
        CC_PREFIX="arm-linux-gnueabi-"
        CC32_PREFIX="arm-linux-gnueabi-"
    else
        CC_PREFIX="aarch64-linux-gnu-"
        CC32_PREFIX="arm-linux-gnueabi-"
    fi

    # Target make Image.gz
    make -j$(nproc) ARCH="$ARCH" O="$KERNEL_OUTDIR" \
        CC="$BIN_DIR/clang" \
        AR="$BIN_DIR/llvm-ar" \
        AS="$BIN_DIR/llvm-as" \
        LD="$BIN_DIR/ld.lld" \
        NM="$BIN_DIR/llvm-nm" \
        OBJCOPY="$BIN_DIR/llvm-objcopy" \
        OBJDUMP="$BIN_DIR/llvm-objdump" \
        OBJSIZE="$BIN_DIR/llvm-size" \
        READELF="$BIN_DIR/llvm-readelf" \
        STRIP="$BIN_DIR/llvm-strip" \
        HOSTCC="$BIN_DIR/clang" \
        HOSTCXX="$BIN_DIR/clang++" \
        HOSTLD="$BIN_DIR/ld.lld" \
        CROSS_COMPILE="$BIN_DIR/$CC_PREFIX" \
        CROSS_COMPILE_ARM32="$BIN_DIR/$CC32_PREFIX" \
        Image.gz || finerr # Target kompilasi Image.gz
        
    if ! [ -a "$IMAGE" ]; then
	    echo "Error: Image.gz tidak ditemukan setelah kompilasi." >&2
	    finerr
    fi
    
    # Kloning AnyKernel dan menyalin Image
    ANYKERNEL_DIR="$CIRRUS_WORKING_DIR/AnyKernel"
    rm -rf "$ANYKERNEL_DIR" 
	git clone --depth=1 "$ANYKERNEL" "$ANYKERNEL_DIR" || finerr
	# IMAGE yang disalin adalah Image.gz, disalin sebagai Image untuk AnyKernel
	cp "$IMAGE" "$ANYKERNEL_DIR/Image" || finerr
}

# Mendapatkan informasi commit dan kernel
function get_info() {
    cd "$KERNEL_ROOTDIR"
    
    export KERNEL_VERSION=$(grep 'Linux/arm64' "$KERNEL_OUTDIR/.config" | cut -d " " -f3 || echo "N/A")
    export UTS_VERSION=$(grep 'UTS_VERSION' "$KERNEL_OUTDIR/include/generated/compile.h" | cut -d '"' -f2 || echo "N/A")
    export TOOLCHAIN_FROM_HEADER=$(grep 'LINUX_COMPILER' "$KERNEL_OUTDIR/include/generated/compile.h" | cut -d '"' -f2 || echo "N/A")
    
    export LATEST_COMMIT="$(git log --pretty=format:'%s' -1 || echo "N/A")"
    export COMMIT_BY="$(git log --pretty=format:'by %an' -1 || echo "N/A")"
    export BRANCH="$(git rev-parse --abbrev-ref HEAD || echo "N/A")"
    export KERNEL_SOURCE="${CIRRUS_REPO_OWNER}/${CIRRUS_REPO_NAME}" 
    export KERNEL_BRANCH="$BRANCH" 
}

# Push kernel ke Telegram
function push() {
    cd "$CIRRUS_WORKING_DIR/AnyKernel"
    
    local ZIP_NAME="$KERNEL_NAME-$DEVICE_CODENAME-$DATE.zip"
    
    zip -r9 "$ZIP_NAME" * || finerr
    
    local ZIP_SHA1=$(sha1sum "$ZIP_NAME" | cut -d' ' -f1 || echo "N/A")
    local ZIP_MD5=$(md5sum "$ZIP_NAME" | cut -d' ' -f1 || echo "N/A")
    local ZIP_SHA256=$(sha256sum "$ZIP_NAME" | cut -d' ' -f1 || echo "N/A") 

    local END=$(date +"%s")
    local DIFF=$(("$END" - "$START"))
    local MINUTES=$(("$DIFF" / 60))
    local SECONDS=$(("$DIFF" % 60))
    
    # Menentukan status KSU
    local KSU_STATUS=""
    if [[ "$KSU_ENABLE" == "true" ]]; then
        KSU_STATUS="KernelSU: ✅ Enabled (Versi: $KSU_VERSION)"
        if [[ "$KSU_LKM_ENABLE" == "true" ]]; then
            KSU_STATUS="$KSU_STATUS (LKM)"
        fi
    else
        KSU_STATUS="KernelSU: 🚫 Disabled (Clean)"
    fi
    
    # Kirim dokumen ZIP
    curl -F document=@"$ZIP_NAME" "$BOT_DOC_URL" \
        -F chat_id="$TG_CHAT_ID" \
        -F "disable_web_page_preview=true" \
        -F "parse_mode=html" \
        -F caption="
==========================
<b>✅ Build Finished!</b>
<b>📦 Kernel:</b> $KERNEL_NAME
<b>📱 Device:</b> $DEVICE_CODENAME
<b>👤 Owner:</b> $CIRRUS_REPO_OWNER
<b>🛠️ Status:</b> $KSU_STATUS
<b>🏚️ Linux version:</b> $KERNEL_VERSION
<b>🌿 Branch:</b> $BRANCH
<b>🎁 Top commit:</b> $LATEST_COMMIT
<b>📚 SHA1:</b> <code>$ZIP_SHA1</code>
<b>📚 MD5:</b> <code>$ZIP_MD5</code>
<b>📚 SHA256:</b> <code>$ZIP_SHA256</code>
<b>👩‍💻 Commit author:</b> $COMMIT_BY
<b>🐧 UTS version:</b> $UTS_VERSION
<b>💡 Compiler:</b> $KBUILD_COMPILER_STRING
<b>💡 ARCH:</b> $ARCH
==========================
<b>⏱️ Compile took:</b> $MINUTES minute(s) and $SECONDS second(s).
<b>⚙️ Changes:</b> <a href=\"https://github.com/$KERNEL_SOURCE/commits/$KERNEL_BRANCH\">Here</a>"
}

## Alur Utama
#---------------------------------------------------------------------------------

# Panggil fungsi secara berurutan
setup_env
check
compile
get_info 
push