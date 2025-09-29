#!/usr/bin/env bash
#
# Script Pembangunan Kernel
# Diadaptasi dari build.sh yang disediakan.
#
# Menambahkan fitur KernelSU yang fleksibel dengan KSU_ENABLE, KSU_VERSION, dan LKM.
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
    if wget -q "$LOG_URL" -O "$LOG_FILE"; then
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

    export KERNEL_NAME="mrt-Kernel"
    local KERNEL_ROOTDIR_BASE="$CIRRUS_WORKING_DIR/$DEVICE_CODENAME"
    export KERNEL_ROOTDIR="$KERNEL_ROOTDIR_BASE"
    export DEVICE_DEFCONFIG="vendor/bengal-perf_defconfig"
    export CLANG_ROOTDIR="$CIRRUS_WORKING_DIR/greenforce-clang"
    export KERNEL_OUTDIR="$KERNEL_ROOTDIR/out"

    # Verifikasi keberadaan dan versi toolchain
    if [ ! -d "$CLANG_ROOTDIR" ] || [ ! -f "$CLANG_ROOTDIR/bin/clang" ]; then
        echo "Error: Toolchain (Clang) tidak ditemukan di $CLANG_ROOTDIR." >&2
        exit 1
    fi

    # Mendapatkan versi toolchain
    CLANG_VER="$("$CLANG_ROOTDIR"/bin/clang --version | head -n 1 | perl -pe 's/\(http.*?\)//gs' | sed -e 's/  */ /g' -e 's/[[:space:]]*$//')"
    LLD_VER="$("$CLANG_ROOTDIR"/bin/ld.lld --version | head -n 1)"

    # Export variabel KBUILD
    export KBUILD_BUILD_USER="$BUILD_USER"
    export KBUILD_BUILD_HOST="$BUILD_HOST"
    export KBUILD_COMPILER_STRING="$CLANG_VER with $LLD_VER"

    # Variabel lain
    export IMAGE="$KERNEL_OUTDIR/arch/arm64/boot/Image.gz" 
    export DATE=$(date +"%Y%m%d-%H%M%S") # Format tanggal yang lebih konsisten
    export BOT_MSG_URL="https://api.telegram.org/bot$TG_TOKEN/sendMessage"
    export BOT_DOC_URL="https://api.telegram.org/bot$TG_TOKEN/sendDocument"

    # Menyimpan waktu mulai
    export START=$(date +"%s")
    
    # --- Tambahan: Flag KSU dan Variabel Baru ---
    export KSU_ENABLE="${KSU_ENABLE:-false}"          # Menggantikan ${{ inputs.ksu }}
    export KSU_VERSION="${KSU_VERSION:-main}"        # Menggantikan ${{ inputs.ksu-version }}
    export KSU_LKM_ENABLE="${KSU_LKM_ENABLE:-false}" # Menggantikan ${{ inputs.ksu-lkm }}
    export KSU_OTHER_ENABLE="${KSU_OTHER_ENABLE:-false}" # Menggantikan ${{ inputs.ksu-other }}
    # KSU_OTHER_URL hanya digunakan jika KSU_OTHER_ENABLE=true
    export KSU_OTHER_URL="${KSU_OTHER_URL:-https://raw.githubusercontent.com/tiann/KernelSU}" 
    # KSU_SKIP_PATCH hanya untuk non-GKI, diabaikan di sini untuk menyederhanakan
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
    echo "BUILDER HOSTNAME     = ${KBUILD_BUILD_HOST}"
    echo "DEVICE_DEFCONFIG     = ${DEVICE_DEFCONFIG}"
    echo "TOOLCHAIN_VERSION    = ${KBUILD_COMPILER_STRING}"
    echo "KERNEL_ROOTDIR       = ${KERNEL_ROOTDIR}"
    # --- Tampilkan status KSU ---
    echo "KSU_ENABLE           = ${KSU_ENABLE}" 
    echo "KSU_VERSION          = ${KSU_VERSION}"
    echo "KSU_LKM_ENABLE       = ${KSU_LKM_ENABLE}"
    echo "================================================"
}

# Proses kompilasi kernel
function compile() {
    cd "$KERNEL_ROOTDIR"

    tg_post_msg "<b>Buiild Kernel started..</b>%0A<b>Defconfig:</b> <code>$DEVICE_DEFCONFIG</code>%0A<b>Toolchain:</b> <code>$KBUILD_COMPILER_STRING</code>"
    
    # --- Pembersihan Otomatis ---
    rm -rf "$KERNEL_OUTDIR"
    mkdir -p "$KERNEL_OUTDIR"
    
    # --- START Blok Conditional KSU Integration (Diadaptasi dari logika KernelSU Action) ---
    if [[ "$KSU_ENABLE" == "true" ]]; then
        echo "================================================"
        echo "           Memeriksa dan Mengintegrasikan Root Kernel"
        echo "================================================"
        
        # 1. Cek apakah KernelSU sudah terintegrasi (dengan KernelSU/kernel/Kconfig)
        if [ -f $KERNEL_ROOTDIR/KernelSU/kernel/Kconfig ]; then
            echo "KernelSU/SukiSU sudah terintegrasi, dilewati."
        else
            # 2. Integrasi KernelSU
            if [[ "$KSU_OTHER_ENABLE" == "true" ]]; then
                # Menggunakan URL/Repo Kustom
                echo "Menggunakan URL KSU/SukiSU Kustom: $KSU_OTHER_URL, Versi: $KSU_VERSION"
                # URL kustom diasumsikan sudah lengkap (misalnya https://raw.githubusercontent.com/User/Repo)
                curl -SsL "$KSU_OTHER_URL/$KSU_VERSION/kernel/setup.sh" | bash -s "$KSU_VERSION" || finerr
            else
                # Menggunakan Repo tiann/KernelSU Resmi
                KVER="$KSU_VERSION"
                
                # 2a. Cek kernel non-GKI (dengan file nongki.txt sebagai penanda)
                if [ -f nongki.txt ]; then
                    printf "Peringatan: Kernel dideteksi non-GKI. Versi KernelSU akan dipaksa ke v0.9.5 (jika KVER lebih baru).\n"
                    # Logika frstprjkt: memaksa v0.9.5 untuk non-GKI jika versi yang diminta lebih baru
                    if [[ "$KVER" != "v0.9.5" ]]; then
                         KVER="v0.9.5"
                    fi
                fi
                
                echo "Mengintegrasikan KernelSU versi: $KVER dari tiann/KernelSU."
                # Menggunakan tiann/KernelSU resmi
                curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -s "$KVER" || finerr
            fi
        fi
        
        # 3. Logika KSU LKM (Loadable Kernel Module)
        if [[ "$KSU_LKM_ENABLE" == "true" ]]; then
            echo "Mengaktifkan KernelSU sebagai LKM (Loadable Kernel Module)."
            # LKM mode: Mengubah KSU menjadi module (m) di source Kconfig
            # Asumsi KSU Kconfig sudah ada setelah setup.sh
            # Perhatikan: Ini mungkin perlu disesuaikan tergantung lokasi Kconfig KSU Anda.
            if [ -f $KERNEL_ROOTDIR/drivers/kernelsu/Kconfig ]; then
                sed -i '/config KSU/,/help/{s/default y/default m/}' $KERNEL_ROOTDIR/drivers/kernelsu/Kconfig || echo "Peringatan: Gagal mengubah KSU menjadi LKM di Kconfig."
            else
                echo "Peringatan: drivers/kernelsu/Kconfig tidak ditemukan, gagal mengatur KSU sebagai LKM."
            fi
        fi
        
        # 4. Logika Patching Non-GKI (jika bukan LKM)
        elif [ -f nongki.txt ]; then
            echo "Kernel Non-GKI terdeteksi. Harap pastikan CONFIG_KPROBES=y sudah diaktifkan, atau patching manual diperlukan."
            # Patch CoCCI untuk non-GKI sering memerlukan skrip eksternal yang spesifik.
            # Mengingat tidak ada skrip yang diberikan (seperti ${{ github.action_path }}/kernelsu/apply_cocci.sh), 
            # pengguna harus memastikan KPROBES di-enable di defconfig.
        fi
        
        echo "Integrasi KernelSU/SukiSU Selesai. Lanjutkan ke defconfig."

    else
        echo "================================================"
        echo "   ROOT KERNEL DINETRALKAN. Melanjutkan build bersih."
        echo "   Untuk mengaktifkan, set KSU_ENABLE=true."
        echo "================================================"
    fi
    # --- END Blok Conditional KSU Integration ---
    
    # Konfigurasi Defconfig
    make -j$(nproc) O="$KERNEL_OUTDIR" ARCH=arm64 "$DEVICE_DEFCONFIG" || finerr
    
    # Kompilasi
    local BIN_DIR="$CLANG_ROOTDIR/bin"
    
    make -j$(nproc) ARCH=arm64 O="$KERNEL_OUTDIR" \
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
        CROSS_COMPILE="$BIN_DIR/aarch64-linux-gnu-" \
        CROSS_COMPILE_ARM32="$BIN_DIR/arm-linux-gnueabi-" \
        Image.gz || finerr 
        
    if ! [ -a "$IMAGE" ]; then
	    echo "Error: Image.gz tidak ditemukan setelah kompilasi." >&2
	    finerr
    fi
    
    # Kloning AnyKernel dan menyalin Image
    ANYKERNEL_DIR="$CIRRUS_WORKING_DIR/AnyKernel"
    rm -rf "$ANYKERNEL_DIR" 
	git clone --depth=1 "$ANYKERNEL" "$ANYKERNEL_DIR" || finerr
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
