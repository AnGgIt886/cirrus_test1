#!/usr/bin/env bash
#
# Script Pembangunan Kernel
# Diadaptasi untuk Cirrus CI dengan Logika KernelSU Mirip GitHub Action (Mandiri).
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
    if wget -Q "$LOG_URL" -O "$LOG_FILE"; then
        echo "Log berhasil diambil. Mengirim log kegagalan ke Telegram..." >&2
        
        # Kirim dokumen log
        curl -F document=@"$LOG_FILE" "$BOT_DOC_URL" \
            -F chat_id="$TG_CHAT_ID" \
            -F "disable_web_page_preview=true" \
            -F "parse_mode=html" \
            -F caption="==============================%0A<b>    Building Kernel CLANG Failed [❌]</b>%0A<b>        Jiancong Tenan 🤬</b>%0A=============================="
        
    else
        echo "Gagal mengambil log dari Cirrus CI. Mengirim pesan error tanpa file log." >&2
        tg_post_msg "<b>Pembangunan Kernel Gagal [❌]</b>%0A<b>Kesalahan:</b> Gagal mendapatkan log dari Cirrus CI. Silakan cek Cirrus secara manual: <a href=\"https://cirrus-ci.com/task/$CIRRUS_TASK_ID\">Task ID $CIRRUS_TASK_ID</a>"
    fi
    
    # Kirim stiker terlepas dari berhasil atau tidaknya pengiriman log (optional)
    curl -s -X POST "$BOT_MSG_URL/../sendSticker" \
        -d sticker="CAACAgQAAx0EabRMmQACAnRjEUAXBTK1Ei_zbJNPFH7WCLzSdAACpBEAAqbxcR716gIrH45xdB4E" \
        -d chat_id="$TG_CHAT_ID"

    exit 1
}

# Fungsi serbaguna untuk kloning Git atau mengunduh dan mengekstrak
function clone_or_download() {
    local url="$1"
    local target_dir="$2"
    local type="$3" # "source" atau "toolchain" atau "repo"
    local branch="$4" # Branch yang akan dikloning (opsional)

    echo "Memproses: $type dari $url ke $target_dir" >&2
    
    if [[ "$url" =~ \.(tar\.gz|tgz|zip|tar)$ ]]; then
        local temp_file
        temp_file=$(mktemp)

        echo "Mengunduh file terkompresi..." >&2
        if curl -Ls -o "$temp_file" "$url"; then
             echo "File berhasil diunduh." >&2
        else
             echo "Error: Gagal mengunduh file dari URL: $url" >&2
             finerr
        fi

        mkdir -p "$target_dir"
        
        echo "Mengekstrak file..." >&2
        if [[ "$url" =~ \.(tar\.gz|tgz|tar)$ ]]; then
            tar -xf "$temp_file" -C "$target_dir" --strip-components=1 || finerr
        elif [[ "$url" =~ \.zip$ ]]; then
            unzip -q "$temp_file" -d "$target_dir" || finerr
        fi

        rm -f "$temp_file"
    
    elif [[ "$url" =~ ^(git@|http|https) ]]; then
        echo "Mengeksekusi Git clone..." >&2
        
        local clone_options="--depth=0"
        if [ -n "$branch" ]; then
            clone_options="$clone_options --branch $branch"
            echo "Mengkloning branch: $branch" >&2
        fi
        
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
            echo "Kernel Source tidak ditemukan di $KERNEL_ROOTDIR, mengunduh dari $KERNEL_SOURCE_URL..."
            rm -rf "$KERNEL_ROOTDIR"
            clone_or_download "$KERNEL_SOURCE_URL" "$KERNEL_ROOTDIR" "Kernel Source" "$KERNEL_BRANCH_TO_CLONE"
        else
            echo "Error: Kernel Source tidak ditemukan di $KERNEL_ROOTDIR dan KERNEL_SOURCE_URL tidak diatur." >&2
            exit 1
        fi
    else
        echo "Kernel Source ditemukan. Dilewati."
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

# Mengatur variabel lingkungan dasar
function setup_env() {
    # Pastikan semua variabel Cirrus CI yang diperlukan ada
    : "${CIRRUS_WORKING_DIR:?Error: CIRRUS_WORKING_DIR not set}"
    : "${DEVICE_CODENAME:?Error: DEVICE_CODENAME not set}"
    : "${TG_TOKEN:?Error: TG_TOKEN not set}"
    : "${TG_CHAT_ID:?Error: TG_CHAT_ID not set}"
    : "${ANYKERNEL:?Error: ANYKERNEL not set}"
    : "${CIRRUS_TASK_ID:?Error: CIRRUS_TASK_ID not set}"

    # --- Variabel Download ---
    export KERNEL_SOURCE_URL="${KERNEL_SOURCE_URL:-}" 
    export KERNEL_BRANCH_TO_CLONE="${KERNEL_BRANCH_TO_CLONE:-}" 
    export CLANG_URL="${CLANG_URL:-}"
    export CLANG_BRANCH_TO_CLONE="${CLANG_BRANCH_TO_CLONE:-}" 
    
    # --- Core Build Variables ---
    export ARCH="${ARCH:-arm64}" 
    export CONFIG="${CONFIG:-bengal-perf_defconfig}" 
    export CLANG_DIR="${CLANG_DIR:-$CIRRUS_WORKING_DIR/greenforce-clang}" 
    
    export KERNEL_NAME="mrt-Kernel"
    export KERNEL_ROOTDIR="${KERNEL_ROOTDIR:-$CIRRUS_WORKING_DIR/kernel}" # Default: kernel
    export DEVICE_DEFCONFIG="$CONFIG" 
    export CLANG_ROOTDIR="$CLANG_DIR" 
    export KERNEL_OUTDIR="$KERNEL_ROOTDIR/out"

    # Variabel lain
    export IMAGE="$KERNEL_OUTDIR/arch/$ARCH/boot/Image.gz" 
    export DATE=$(date +"%Y%m%d-%H%M%S") 
    export BOT_MSG_URL="https://api.telegram.org/bot$TG_TOKEN/sendMessage"
    export BOT_DOC_URL="https://api.telegram.org/bot$TG_TOKEN/sendDocument"

    # Menyimpan waktu mulai
    export START=$(date +"%s")
    
    # --- Flag KSU ---
    export KSU_ENABLE="${KSU_ENABLE:-false}"          
    export KSU_VERSION="${KSU_VERSION:-main}"        
    export KSU_LKM_ENABLE="${KSU_LKM_ENABLE:-false}" 
    export KSU_OTHER_ENABLE="${KSU_OTHER_ENABLE:-false}" 
    export KSU_OTHER_URL="${KSU_OTHER_URL:-https://raw.githubusercontent.com/tiann/KernelSU}" 
    export KSU_SKIP_PATCH="${KSU_SKIP_PATCH:-true}"
    export COCCI_ENABLE="${COCCI_ENABLE:-true}" 
    
    # Lokasi script Cocci
    export COCCI_REPO_URL="${COCCI_REPO_URL:-https://github.com/dabao1955/kernel_build_action.git}" # URL repositori Cocci
    export COCCI_SCRIPT_DIR="${COCCI_SCRIPT_DIR:-$CIRRUS_WORKING_DIR/cocci}" 
}

# Fungsi untuk setup: kloning Cocci dan buat nongki.txt (Menggantikan setup_script)
function setup_kernel_patches() {
    if [[ "$KSU_ENABLE" == "true" ]]; then
        echo "================================================"
        echo "      Memeriksa Patching Eksternal & Non-GKI"
        echo "================================================"

        # 1. Kloning Repositori Cocci (Jika URL Disediakan)
        if [ -n "$COCCI_REPO_URL" ]; then
            echo "Mengkloning repositori Cocci dari $COCCI_REPO_URL ke $COCCI_SCRIPT_DIR..."
            rm -rf "$COCCI_SCRIPT_DIR"
            clone_or_download "$COCCI_REPO_URL" "$COCCI_SCRIPT_DIR" "Cocci Repo"
        else
            if [[ "$COCCI_ENABLE" == "true" ]]; then
                 echo "Peringatan: COCCI_ENABLE=true, tetapi COCCI_REPO_URL tidak diatur. Melewati kloning Cocci."
            fi
        fi

        # 2. Deteksi dan Buat nongki.txt
        # Kunci: nongki.txt harus berada di root kernel source ($KERNEL_ROOTDIR)
        cd "$KERNEL_ROOTDIR"
        
        local VERSION=$(grep -E '^VERSION = ' Makefile | awk '{print $3}')
        local PATCHLEVEL=$(grep -E '^PATCHLEVEL = ' Makefile | awk '{print $3}')
        
        if [ "$VERSION" -lt 5 ] || ([ "$VERSION" -eq 5 ] && [ "$PATCHLEVEL" -lt 10 ]); then
            echo "Kernel terdeteksi non-GKI (v$VERSION.$PATCHLEVEL). Membuat nongki.txt di $KERNEL_ROOTDIR..."
            touch nongki.txt
        else
            echo "Kernel terdeteksi GKI-compatible atau lebih baru. Melewati pembuatan nongki.txt."
            # Pastikan file tidak ada jika kernel GKI
            rm -f nongki.txt
        fi
        
        # Kembali ke direktori kerja utama
        cd "$CIRRUS_WORKING_DIR"
    fi
}

# Fungsi untuk mengatur variabel toolchain setelah diunduh
function setup_toolchain_env() {
    export KBUILD_BUILD_USER="${BUILD_USER:-Unknown User}"
    export KBUILD_BUILD_HOST="${BUILD_HOST:-CirrusCI}"
    
    if [ -d "$CLANG_ROOTDIR" ] && [ -f "$CLANG_ROOTDIR/bin/clang" ]; then
        CLANG_VER="$("$CLANG_ROOTDIR"/bin/clang --version | head -n 1 | perl -pe 's/\(http.*?\)//gs' | sed -e 's/  */ /g' -e 's/[[:space:]]*$//')"
        LLD_VER="$("$CLANG_ROOTDIR"/bin/ld.lld --version | head -n 1)" 
        
        export KBUILD_COMPILER_STRING="$CLANG_VER with $LLD_VER"
    else
        export KBUILD_COMPILER_STRING="Toolchain Not Found"
    fi
}


# Menampilkan info lingkungan
function check() {
    echo "================================================"
    echo "       Informasi Lingkungan Build Kernel"
    echo "================================================"
    echo "DEVICE_DEFCONFIG     = ${DEVICE_DEFCONFIG}"
    echo "TOOLCHAIN_VERSION    = ${KBUILD_COMPILER_STRING}"
    echo "KSU_ENABLE           = ${KSU_ENABLE}" 
    echo "KSU_VERSION          = ${KSU_VERSION}"
    echo "KSU_LKM_ENABLE       = ${KSU_LKM_ENABLE}"
    echo "KSU_SKIP_PATCH       = ${KSU_SKIP_PATCH} (Patch Non-GKI)"
    echo "COCCI_ENABLE         = ${COCCI_ENABLE} (JIKA Non-GKI & Patch Aktif)" 
    echo "COCCI_SCRIPT_DIR     = ${COCCI_SCRIPT_DIR}"
    echo "================================================"
}

# Proses kompilasi kernel
function compile() {
    # Safety check untuk toolchain
    if [ -z "$KBUILD_COMPILER_STRING" ] || [ "$KBUILD_COMPILER_STRING" == "Toolchain Not Found" ]; then
         setup_toolchain_env
         if [ "$KBUILD_COMPILER_STRING" == "Toolchain Not Found" ]; then
             echo "Error: Toolchain (Clang) tidak ditemukan di $CLANG_ROOTDIR." >&2
             exit 1
         fi
    fi

    cd "$KERNEL_ROOTDIR"

    tg_post_msg "<b>Buiild Kernel started..</b>%0A<b>Defconfig:</b> <code>$DEVICE_DEFCONFIG</code>%0A<b>Toolchain:</b> <code>$KBUILD_COMPILER_STRING</code>%0A<b>Arsitektur:</b> <code>$ARCH</code>"
    
    rm -rf "$KERNEL_OUTDIR"
    mkdir -p "$KERNEL_OUTDIR"
    
    # 1. KONFIGURASI DEFCONFIG AWAL
    echo "Membuat defconfig awal..."
    make -j$(nproc) O="$KERNEL_OUTDIR" ARCH="$ARCH" "$DEVICE_DEFCONFIG" || finerr
    
    # --- START Blok Conditional KSU Integration (MENYESUAIKAN action.yml) ---
    
    if [[ "$KSU_ENABLE" == "true" ]]; then
        echo "================================================"
        echo "           Memeriksa dan Mengintegrasikan Root Kernel"
        echo "================================================"
        
        # 1. Kloning/Unduh KernelSU jika belum ada
        if [ -f KernelSU/kernel/Kconfig ]; then
            echo "KernelSU sudah diinisialisasi, dilewati."
        else
            local KVER="$KSU_VERSION"
            
            # 1.1 Cek Non-GKI & set KVER (Ini berlaku untuk KernelSU Resmi & Kustom)
            if [ -f nongki.txt ]; then
                # Non-GKI: Force KVER ke v0.9.5 (sesuai action.yml)
                printf "Warning: Kernel dideteksi non-GKI. Versi KernelSU dipaksa ke v0.9.5 (sesuai batasan Non-GKI).\n"
                KVER=v0.9.5
            fi

            if [[ "$KSU_OTHER_ENABLE" == "true" ]]; then
                # Logika KernelSU pihak ketiga (MENDUKUNG GIT & RAW)
                
                KVER="$KSU_VERSION" # Tetap gunakan versi kustom untuk curl
                echo "Menggunakan URL KSU/SukiSU Kustom: $KSU_OTHER_URL, Versi: $KSU_VERSION"
                
                local KSU_SETUP_URL
                
                # Deteksi format URL
                if [[ "$KSU_OTHER_URL" =~ ^https://github.com/ ]]; then
                    # Kasus 1: Link GIT Biasa (e.g., https://github.com/SukiSU-Ultra/SukiSU-Ultra)
                    # Pola RAW: URL_BASE/raw/branch/path
                    KSU_SETUP_URL="${KSU_OTHER_URL}/raw/${KSU_VERSION}/kernel/setup.sh"
                    echo "Format URL terdeteksi: GitHub Repository."
                elif [[ "$KSU_OTHER_URL" =~ ^https://raw.githubusercontent.com/ ]]; then
                    # Kasus 2: Link RAW (e.g., https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra)
                    # Pola RAW: URL_BASE/branch/path (tidak perlu /raw/ lagi)
                    KSU_SETUP_URL="${KSU_OTHER_URL}/${KSU_VERSION}/kernel/setup.sh"
                    echo "Format URL terdeteksi: GitHub Raw Content."
                else
                    echo "Error: KSU_OTHER_URL tidak dikenal (bukan github.com atau raw.githubusercontent.com)." >&2
                    finerr
                fi

                echo "Mengunduh setup.sh dari: $KSU_SETUP_URL"
                curl -SsL "$KSU_SETUP_URL" | bash -s "$KSU_VERSION" || finerr
                
            else 
                # Logika KernelSU Resmi
                echo "Mengintegrasikan KernelSU versi: $KVER dari tiann/KernelSU."
                curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -s "$KVER" || finerr
            fi
        fi
        
        # 2. LOGIKA KSU LKM dan APPLY_COCCI.SH (Mengikuti alur action.yml)
        
        local DEFCONFIG_PATH="arch/$ARCH/configs/$DEVICE_DEFCONFIG"
        
        if [[ "$KSU_LKM_ENABLE" == "true" ]]; then
            # KASUS A: LKM AKTIF (Modifikasi di defconfig)
            echo "Mengaktifkan KernelSU sebagai LKM (Loadable Kernel Module)."
            
            if grep -q "CONFIG_KPROBES=y" "$DEFCONFIG_PATH" ; then
                # Jika KPROBES di defconfig aktif, ganti KSU=y ke KSU=m di defconfig
                sed -i 's/CONFIG_KSU=y/CONFIG_KSU=m/g' "$DEFCONFIG_PATH"
                echo "CONFIG_KSU diubah menjadi 'm' di $DEFCONFIG_PATH."
            else
                # Jika KPROBES tidak aktif, ganti default di Kconfig KernelSU
                sed -i '/config KSU/,/help/{s/default y/default m/}' drivers/kernelsu/Kconfig
                echo "Default KSU diubah menjadi 'm' di Kconfig KernelSU."
            fi
            
        elif [ -f nongki.txt ]; then
            # KASUS B: LKM NONAKTIF & NON-GKI AKTIF (Logika Patching/Cocci)
            
            if grep -q "CONFIG_KPROBES=y" "$DEFCONFIG_PATH" ; then
                echo "CONFIG_KPROBES is enabled, skip patch."
            elif [[ "$KSU_SKIP_PATCH" == "true" ]]; then
                echo "ksu-skip-patch is enabled, skip patch."
            elif [[ "$COCCI_ENABLE" == "true" ]]; then
                # Hanya jika semua syarat terpenuhi (Non-GKI, KPROBES mati, skip-patch mati, Cocci diizinkan)
                
                local COCCI_SCRIPT="$COCCI_SCRIPT_DIR/kernelsu/apply_cocci.sh"
                
                if [ -f "$COCCI_SCRIPT" ]; then
                    echo "Menerapkan Coccinelle/Semantic Patch (Non-GKI)..."
                    bash "$COCCI_SCRIPT" || finerr 
                    echo "Cocci/Semantic Patch berhasil diterapkan."
                else
                    echo "Peringatan: Script Cocci '$COCCI_SCRIPT' tidak ditemukan di lokasi '$COCCI_SCRIPT_DIR'. Lewati patching Non-GKI."
                fi
            else
                 echo "Cocci/Semantic Patch dilewati karena COCCI_ENABLE tidak diatur ke 'true' atau skrip tidak ditemukan."
            fi
        fi
        
        # 3. SINKRONISASI KONFIGURASI 
        echo "Mensinkronkan konfigurasi (olddefconfig) untuk menerapkan perubahan KSU/LKM."
        make -j$(nproc) O="$KERNEL_OUTDIR" ARCH="$ARCH" olddefconfig || finerr 
        
    else
        echo "================================================"
        echo "   ROOT KERNEL DINETRALKAN. Melanjutkan build bersih."
        echo "   Untuk mengaktifkan, set KSU_ENABLE=true."
        echo "================================================"
    fi
    # --- END Blok Conditional KSU Integration ---
    
    echo "Lanjutkan ke kompilasi."
    
    # 4. Kompilasi
    local PATH="$CLANG_ROOTDIR/bin:$PATH"
    
    local CC_PREFIX
    local CC32_PREFIX

    if [[ "$ARCH" == "arm64" ]]; then
        CC_PREFIX="aarch64-linux-gnu-"
        CC32_PREFIX="arm-linux-gnueabi-"
    else
        CC_PREFIX="aarch64-linux-gnu-"
        CC32_PREFIX="arm-linux-gnueabi-"
    fi

    # Target make Image.gz
    make -j$(nproc) ARCH="$ARCH" O="$KERNEL_OUTDIR" \
        LLVM="1" \
        LLVM_IAS="1" \
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
    
    export KERNEL_VERSION=$(grep 'Linux/arm64' "$KERNEL_ROOTDIR/.config" | cut -d " " -f3 || echo "N/A")
    export UTS_VERSION=$(grep 'UTS_VERSION' "$KERNEL_ROOTDIR/include/generated/compile.h" | cut -d '"' -f2 || echo "N/A")
    
    if [ -d "$KERNEL_ROOTDIR/.git" ]; then
        export LATEST_COMMIT="$(git log --pretty=format:'%s' -1 || echo "N/A")"
        export COMMIT_BY="$(git log --pretty=format:'by %an' -1 || echo "N/A")"
        
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
        
        # Cek status patching untuk pesan di Telegram
        if [ -f "$KERNEL_ROOTDIR/nongki.txt" ]; then
             KSU_STATUS="$KSU_STATUS, Non-GKI: Aktif"
             local DEFCONFIG_PATH="arch/$ARCH/configs/$DEVICE_DEFCONFIG"
             if grep -q "CONFIG_KPROBES=y" "$DEFCONFIG_PATH"; then
                 KSU_STATUS="$KSU_STATUS (KPROBES Aktif, Patch/Cocci Dilewati)"
             elif [[ "$KSU_SKIP_PATCH" == "true" ]]; then
                 KSU_STATUS="$KSU_STATUS (Patch Dilewati Manual)"
             elif [[ "$COCCI_ENABLE" == "true" ]]; then
                 KSU_STATUS="$KSU_STATUS (Cocci Diterapkan)"
             else
                 KSU_STATUS="$KSU_STATUS (Cocci Dinonaktifkan)"
             fi
        fi
        
    else
        KSU_STATUS="KernelSU: 🚫 Disabled (Clean)"
    fi
    
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
setup_toolchain_env
setup_kernel_patches 
check
compile
get_info 
push