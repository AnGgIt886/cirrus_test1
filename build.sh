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

# Fungsi serbaguna untuk kloning Git atau mengunduh dan mengekstrak
function clone_or_download() {
    local url="$1"
    local target_dir="$2"
    local type="$3" # "source" atau "toolchain"
    local branch="$4" # Branch yang akan dikloning (opsional)

    echo "Memproses: $type dari $url ke $target_dir" >&2
    
    # MENGUBAH URUTAN: Prioritaskan pengunduhan file terkompresi terlebih dahulu
    if [[ "$url" =~ \.(tar\.gz|tgz|zip|tar)$ ]]; then
        local temp_file
        temp_file=$(mktemp)

        echo "Mengunduh file terkompresi..." >&2
        
        # Mengunduh file
        if curl -Ls -o "$temp_file" "$url"; then
             echo "File berhasil diunduh." >&2
        else
             echo "Error: Gagal mengunduh file dari URL: $url" >&2
             finerr
        fi

        # Membuat direktori target jika belum ada
        mkdir -p "$target_dir"
        
        echo "Mengekstrak file..." >&2
        # Ekstraksi
        if [[ "$url" =~ \.(tar\.gz|tgz|tar)$ ]]; then
            # Menggunakan --strip-components=1 untuk menghindari folder berlapis
            tar -xf "$temp_file" -C "$target_dir" --strip-components=1 || finerr
        elif [[ "$url" =~ \.zip$ ]]; then
            unzip -q "$temp_file" -d "$target_dir" || finerr
        fi

        rm -f "$temp_file"
    
    # Kloning Git (Dilakukan jika bukan file terkompresi dan merupakan URL HTTP/HTTPS/Git)
    elif [[ "$url" =~ ^(git@|http|https) ]]; then
        echo "Mengeksekusi Git clone..." >&2
        
        local clone_options="--depth=1"
        if [ -n "$branch" ]; then
            clone_options="$clone_options --branch $branch"
            echo "Mengkloning branch: $branch" >&2
        fi
        
        # Eksekusi Git clone dengan opsi yang sesuai
        git clone $clone_options "$url" "$target_dir" || finerr

    else
        echo "Error: URL tidak dikenali sebagai repositori Git atau file terkompresi yang didukung (tar.gz, tgz, zip, tar): $url" >&2
        finerr
    fi
    
    echo "$type berhasil diunduh/dikloning ke $target_dir." >&2
}

# Fungsi untuk mengunduh kernel source dan toolchain
function download_kernel_tools() {
    echo "================================================"
    echo "       Memeriksa dan Mengunduh Dependensi"
    echo "================================================"

    # 1. Download/Kloning Kernel Source
    if [ ! -d "$KERNEL_ROOTDIR" ] || [ ! -d "$KERNEL_ROOTDIR/.git" ]; then
        if [ ! -z "$KERNEL_SOURCE_URL" ]; then
            echo "Kernel Source tidak ditemukan di $KERNEL_ROOTDIR atau bukan Git repo, mengunduh dari $KERNEL_SOURCE_URL..."
            rm -rf "$KERNEL_ROOTDIR"
            clone_or_download "$KERNEL_SOURCE_URL" "$KERNEL_ROOTDIR" "Kernel Source" "$KERNEL_BRANCH_TO_CLONE"
        else
            echo "Error: Kernel Source tidak ditemukan di $KERNEL_ROOTDIR dan KERNEL_SOURCE_URL tidak diatur." >&2
            exit 1
        fi
    else
        echo "Kernel Source ditemukan dan merupakan Git repo. Dilewati."
    fi
    
    # 2. Download/Kloning Toolchain (Clang)
    if [ ! -d "$CLANG_ROOTDIR" ] || [ ! -f "$CLANG_ROOTDIR/bin/clang" ]; then
        if [ ! -z "$CLANG_URL" ]; then
            echo "Toolchain (Clang) tidak ditemukan di $CLANG_ROOTDIR, mengunduh dari $CLANG_URL..."
            rm -rf "$CLANG_ROOTDIR"
            clone_or_download "$CLANG_URL" "$CLANG_ROOTDIR" "Clang Toolchain" "$CLANG_BRANCH_TO_CLONE" 
        else
            echo "Error: Toolchain (Clang) tidak ditemukan di $CLANG_ROOTDIR dan CLANG_URL tidak diatur." >&2
            exit 1
        fi
    else
        echo "Toolchain (Clang) ditemukan. Dilewati."
    fi
    
    echo "================================================"
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

    # --- Variabel Download Baru ---
    export KERNEL_SOURCE_URL="${KERNEL_SOURCE_URL:-}" 
    export KERNEL_BRANCH_TO_CLONE="${KERNEL_BRANCH_TO_CLONE:-}" 
    export CLANG_URL="${CLANG_URL:-}"
    export CLANG_BRANCH_TO_CLONE="${CLANG_BRANCH_TO_CLONE:-}" 
    
    # --- Core Build Variables ---
    export ARCH="${ARCH:-arm64}" 
    export CONFIG="${CONFIG:-vendor/bengal-perf_defconfig}" 
    export CLANG_DIR="${CLANG_DIR:-$CIRRUS_WORKING_DIR/greenforce-clang}" 
    
    export KERNEL_NAME="mrt-Kernel"
    local KERNEL_ROOTDIR_BASE="$CIRRUS_WORKING_DIR" 
    export KERNEL_ROOTDIR="$KERNEL_ROOTDIR_BASE"
    export DEVICE_DEFCONFIG="$CONFIG" 
    export CLANG_ROOTDIR="$CLANG_DIR" 
    export KERNEL_OUTDIR="$KERNEL_ROOTDIR/out"

    # Verifikasi toolchain dan dapatkan versi
    if [ ! -d "$CLANG_ROOTDIR" ] || [ ! -f "$CLANG_ROOTDIR/bin/clang" ]; then
        true 
    else
        # Mendapatkan versi toolchain (Hanya jika toolchain sudah ada)
        CLANG_VER="$("$CLANG_ROOTDIR"/bin/clang --version | head -n 1 | perl -pe 's/\(http.*?\)//gs' | sed -e 's/  */ /g' -e 's/[[:space:]]*$//')"
        LLD_VER="$("$CLANG_ROOTDIR"/bin/ld.lld --version | head -n 1)" # Menggunakan ld.lld default
        
        # Export variabel KBUILD
        export KBUILD_BUILD_USER="$BUILD_USER"
        export KBUILD_BUILD_HOST="$BUILD_HOST"
        export KBUILD_COMPILER_STRING="$CLANG_VER with $LLD_VER"
    fi

    # Variabel lain
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
    echo "  / ___/ , _/ /_/ / // / _// /__  / /         " # <-- PERBAIKAN: Menambahkan 'echo'
    echo " /_/  /_/|_|\____/\___/___/\___/ /_/          "
    echo "================================================"
    echo "BUILDER NAME         = ${KBUILD_BUILD_USER}"
    echo "ARCH                 = ${ARCH}" 
    echo "LINKER               = ld.lld (Default)"
    echo "DEVICE_DEFCONFIG     = ${DEVICE_DEFCONFIG}"
    echo "TOOLCHAIN_VERSION    = ${KBUILD_COMPILER_STRING}"
    echo "KERNEL_ROOTDIR       = ${KERNEL_ROOTDIR}"
    echo "CLANG_ROOTDIR        = ${CLANG_ROOTDIR}"
    echo "KERNEL_SOURCE_URL    = ${KERNEL_SOURCE_URL}"
    echo "KERNEL_BRANCH_CLONE  = ${KERNEL_BRANCH_TO_CLONE:-N/A}"
    echo "CLANG_URL            = ${CLANG_URL}"
    echo "CLANG_BRANCH_TO_CLONE    = ${CLANG_BRANCH_TO_CLONE:-N/A}"
    echo "KSU_ENABLE           = ${KSU_ENABLE}" 
    echo "KSU_VERSION          = ${KSU_VERSION}"
    echo "KSU_LKM_ENABLE       = ${KSU_LKM_ENABLE}"
    echo "================================================"
}

# Proses kompilasi kernel (VERSI MODIFIKASI UNTUK MENGHINDARI RESTART CONFIG)
function compile() {
    # Amankan bahwa variabel KBUILD_COMPILER_STRING telah diinisialisasi
    if [ -z "$KBUILD_COMPILER_STRING" ]; then
         if [ ! -d "$CLANG_ROOTDIR" ] || [ ! -f "$CLANG_ROOTDIR/bin/clang" ]; then
             echo "Error: Toolchain (Clang) tidak ditemukan di $CLANG_ROOTDIR setelah proses download." >&2
             exit 1
         fi
         CLANG_VER="$("$CLANG_ROOTDIR"/bin/clang --version | head -n 1 | perl -pe 's/\(http.*?\)//gs' | sed -e 's/  */ /g' -e 's/[[:space:]]*$//')"
         LLD_VER="$("$CLANG_ROOTDIR"/bin/ld.lld --version | head -n 1)"
         export KBUILD_COMPILER_STRING="$CLANG_VER with $LLD_VER"
    fi

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
                # Menggunakan perl untuk pengubahan yang lebih andal di lingkungan CI
                perl -i -pe 's/default y/default m/' $KERNEL_ROOTDIR/drivers/kernelsu/Kconfig || echo "Peringatan: Gagal mengubah KSU menjadi LKM di Kconfig."
            else
                echo "Peringatan: drivers/kernelsu/Kconfig tidak ditemukan, gagal mengatur KSU sebagai LKM."
            fi
        fi
        
        # 2. SINKRONISASI KONFIGURASI SETELAN MODIFIKASI KSU
        echo "Integrasi KernelSU/SukiSU Selesai. Mensinkronkan konfigurasi (olddefconfig)..."
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
    local PATH="$CLANG_ROOTDIR/bin:$PATH"
    
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
        LLVM=1 \
        LLVM_IAS=1 \
        CC="clang" \
        AR="llvm-ar" \
        AS="llvm-as" \
        LD="ld.lld" \
        NM="llvm-nm" \
        OBJCOPY="llvm-objcopy" \
        OBJDUMP="llvm-objdump" \
        OBJSIZE="llvm-size" \
        READELF="llvm-readelf" \
        STRIP="llvm-strip" \
        HOSTCC="clang" \
        HOSTCXX="clang++" \
        HOSTLD="ld.lld" \
        CROSS_COMPILE="$CC_PREFIX" \
        CROSS_COMPILE_ARM32="$CC32_PREFIX" \
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
    # Pindahkan ke direktori kernel source untuk mengambil info Git
    cd "$KERNEL_ROOTDIR"
    
    export KERNEL_VERSION=$(grep 'Linux/arm64' "$KERNEL_OUTDIR/.config" | cut -d " " -f3 || echo "N/A")
    export UTS_VERSION=$(grep 'UTS_VERSION' "$KERNEL_OUTDIR/include/generated/compile.h" | cut -d '"' -f2 || echo "N/A")
    export TOOLCHAIN_FROM_HEADER=$(grep 'LINUX_COMPILER' "$KERNEL_OUTDIR/include/generated/compile.h" | cut -d '"' -f2 || echo "N/A")
    
    # Ambil info Git hanya jika KERNEL_ROOTDIR adalah repositori Git
    if [ -d "$KERNEL_ROOTDIR/.git" ]; then
        export LATEST_COMMIT="$(git log --pretty=format:'%s' -1 || echo "N/A")"
        export COMMIT_BY="$(git log --pretty=format:'by %an' -1 || echo "N/A")"
        
        # Tentukan Branch Kernel
        if [ -n "$KERNEL_BRANCH_TO_CLONE" ]; then
            export BRANCH="$KERNEL_BRANCH_TO_CLONE (Cloned)"
        else
            export BRANCH="$(git rev-parse --abbrev-ref HEAD || echo "N/A")"
        fi

        export KERNEL_SOURCE="${CIRRUS_REPO_OWNER}/${CIRRUS_REPO_NAME}" 
        export KERNEL_BRANCH="$BRANCH"
    else
        export LATEST_COMMIT="Source Code Downloaded (No Git Info)"
        export COMMIT_BY="N/A"
        export BRANCH="N/A"
        export KERNEL_SOURCE="N/A"
        export KERNEL_BRANCH="N/A"
    fi
    
    # Tentukan Compiler String Akhir (memasukkan info branch Clang jika dari Git)
    local CLANG_INFO="$KBUILD_COMPILER_STRING"
    if [ -d "$CLANG_ROOTDIR/.git" ] && [ -n "$CLANG_BRANCH_TO_CLONE" ]; then
        CLANG_INFO="$CLANG_INFO (Branch: $CLANG_BRANCH_TO_CLONE)"
    fi
    export KBUILD_COMPILER_STRING="$CLANG_INFO"
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
    
    # Membuat link perubahan (hanya jika ada info Git)
    local CHANGES_LINK_TEXT="N/A"
    if [[ "$KERNEL_SOURCE" != "N/A" && "$KERNEL_BRANCH" != "N/A" ]]; then
        local GIT_BRANCH_NAME="$BRANCH"
        if [[ "$BRANCH" == *"(Cloned)"* ]]; then
            GIT_BRANCH_NAME="$KERNEL_BRANCH_TO_CLONE"
        fi
        
        CHANGES_LINK_TEXT="<a href=\"https://github.com/$KERNEL_SOURCE/commits/$GIT_BRANCH_NAME\">Here</a>"
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
<b>⚙️ Changes:</b> $CHANGES_LINK_TEXT"
}

## Alur Utama
#---------------------------------------------------------------------------------

# Panggil fungsi secara berurutan
setup_env
download_kernel_tools
check
compile
get_info 
push