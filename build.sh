#!/usr/bin/env bash
#
# Script Pembangunan Kernel (Dioptimalkan)
# Diadaptasi untuk Cirrus CI dengan Logika KernelSU Mirip GitHub Action (Mandiri).
#
# Keluar segera jika ada perintah yang gagal, variabel yang tidak diset, atau pipe yang gagal.
set -euo pipefail

## Deklarasi Fungsi Utama
#---------------------------------------------------------------------------------

# Fungsi untuk mengirim pesan ke Telegram
tg_post_msg() {
    local message="$1"
    # Menghilangkan -s karena error handling penting
    curl -X POST "${BOT_MSG_URL}" \
        -d chat_id="${TG_CHAT_ID}" \
        -d "disable_web_page_preview=true" \
        -d "parse_mode=html" \
        -d text="${message}"
}

# Fungsi untuk menangani kegagalan (find error)
function finerr() {
    # Pastikan fungsi ini tidak terpengaruh oleh 'set -e' internal
    local LOG_FILE="build.log"
    local LOG_URL="https://api.cirrus-ci.com/v1/task/${CIRRUS_TASK_ID}/logs/Build_kernel.log"
    local TG_MSG

    echo "Pembangunan GAGAL. Mencoba mengambil log dari ${LOG_URL}..." >&2

    # Ambil log menggunakan curl (Gunakan -f untuk mencegah curl menampilkan output error HTTP)
    if curl -Ls -o "${LOG_FILE}" "${LOG_URL}"; then
        echo "Log berhasil diambil. Mengirim log kegagalan ke Telegram..." >&2

        # Kirim dokumen log
        curl -F document="@${LOG_FILE}" "${BOT_DOC_URL}" \
            -F chat_id="${TG_CHAT_ID}" \
            -F "disable_web_page_preview=true" \
            -F "parse_mode=html" \
            -F caption="
==============================
<b>    Building Kernel CLANG Failed [❌]</b>
<b>        Jiancog Tenan 🤬</b>
==============================" || echo "Gagal mengirim dokumen log." >&2 # Tambahkan error handling untuk curl

    else
        echo "Gagal mengambil log dari Cirrus CI." >&2
        TG_MSG="<b>Pembangunan Kernel Gagal [❌]</b>%0A<b>Kesalahan:</b> Gagal mendapatkan log dari Cirrus CI. Silakan cek Cirrus secara manual: <a href=\"https://cirrus-ci.com/task/${CIRRUS_TASK_ID}\">Task ID ${CIRRUS_TASK_ID}</a>"
        tg_post_msg "${TG_MSG}" || echo "Gagal mengirim pesan error." >&2
    fi

    # Kirim stiker
    curl -s -X POST "${BOT_MSG_URL/sendMessage/sendSticker}" \
        -d sticker="CAACAgQAAx0EabRMmQACAnRjEUAXBTK1Ei_zbJNPFH7WCLzSdAACpBEAAqbxcR716gIrH45xdB4E" \
        -d chat_id="${TG_CHAT_ID}" || true # Izinkan kegagalan stiker
    
    exit 1
}

# Fungsi serbaguna untuk kloning Git atau mengunduh dan mengekstrak
function clone_or_download() {
    local url="$1"
    local target_dir="$2"
    local type="$3" # "source" atau "toolchain" atau "repo"
    local branch="${4:-}" # Branch yang akan dikloning (opsional, default kosong)
    local temp_file
    local clone_options=""
    
    echo "Memproses: ${type} dari ${url} ke ${target_dir}" >&2
    
    # Deteksi dan unduh/ekstrak file terkompresi
    if [[ "${url}" =~ \.(tar\.gz|tgz|zip|tar)$ ]]; then
        temp_file=$(mktemp)
        echo "Mengunduh file terkompresi..." >&2
        
        # Gunakan -f untuk mendeteksi error HTTP (ex: 404)
        curl -Ls -f -o "${temp_file}" "${url}" || { echo "Error: Gagal mengunduh file dari URL: ${url}" >&2; finerr; }
        echo "File berhasil diunduh." >&2
        
        mkdir -p "${target_dir}"
        
        echo "Mengekstrak file..." >&2
        if [[ "${url}" =~ \.(tar\.gz|tgz|tar)$ ]]; then
            tar -xf "${temp_file}" -C "${target_dir}" --strip-components=1 || finerr
        elif [[ "${url}" =~ \.zip$ ]]; then
            unzip -q "${temp_file}" -d "${target_dir}" || finerr
        fi

        rm -f "${temp_file}"
    
    # Deteksi dan kloning Git
    elif [[ "${url}" =~ ^(git@|http|https) ]]; then
        echo "Mengeksekusi Git clone..." >&2
        
        if [[ -n "${branch}" ]]; then
            clone_options="--branch ${branch}"
            echo "Mengkloning branch: ${branch}" >&2
        fi
        
        # Gunakan --depth=1 dan pastikan target_dir kosong
        rm -rf "${target_dir}"
        git clone --depth=1 ${clone_options} "${url}" "${target_dir}" || finerr

    else
        echo "Error: URL tidak dikenali sebagai repositori Git atau file terkompresi yang didukung (tar.gz, tgz, zip, tar): ${url}" >&2
        finerr
    fi
    
    echo "${type} berhasil diunduh/dikloning ke ${target_dir}." >&2
}

# Fungsi untuk mengunduh kernel source dan toolchain
function download_kernel_tools() {
    echo "================================================"
    echo "       Memeriksa dan Mengunduh Dependensi"
    echo "================================================"

    # 1. Download/Kloning Kernel Source
    if [[ ! -d "${KERNEL_ROOTDIR}" ]] || [[ ! -f "${KERNEL_ROOTDIR}/Makefile" ]]; then
        if [[ -n "${KERNEL_SOURCE_URL}" ]]; then
            echo "Kernel Source tidak ditemukan di ${KERNEL_ROOTDIR}, mengunduh..."
            clone_or_download "${KERNEL_SOURCE_URL}" "${KERNEL_ROOTDIR}" "Kernel Source" "${KERNEL_BRANCH_TO_CLONE}"
        else
            echo "Error: Kernel Source tidak ditemukan di ${KERNEL_ROOTDIR} dan KERNEL_SOURCE_URL tidak diatur." >&2
            exit 1
        fi
    else
        echo "Kernel Source ditemukan. Dilewati."
    fi
    
    # 2. Download/Kloning Toolchain (Clang)
    if [[ ! -d "${CLANG_ROOTDIR}" ]] || [[ ! -f "${CLANG_ROOTDIR}/bin/clang" ]]; then
        if [[ -n "${CLANG_URL}" ]]; then
            echo "Toolchain (Clang) tidak ditemukan di ${CLANG_ROOTDIR}, mengunduh..."
            clone_or_download "${CLANG_URL}" "${CLANG_ROOTDIR}" "Clang Toolchain" "${CLANG_BRANCH_TO_CLONE}" 
        else
            echo "Error: Toolchain (Clang) tidak ditemukan di ${CLANG_ROOTDIR} dan CLANG_URL tidak diatur." >&2
            exit 1
        fi
    else
        echo "Toolchain (Clang) ditemukan. Dilewati."
    fi
    
    echo "================================================"
}

# Mengatur variabel lingkungan dasar (Dioptimalkan)
function setup_env() {
    # Cek variabel wajib (menggunakan :? yang di-enforce oleh set -u)
    : "${CIRRUS_WORKING_DIR:?}"
    : "${DEVICE_CODENAME:?}"
    : "${TG_TOKEN:?}"
    : "${TG_CHAT_ID:?}"
    : "${ANYKERNEL:?}"
    : "${CIRRUS_TASK_ID:?}"

    # --- Variabel Download (Gunakan ekspansi parameter dengan default) ---
    export KERNEL_SOURCE_URL="${KERNEL_SOURCE_URL:-}" 
    export KERNEL_BRANCH_TO_CLONE="${KERNEL_BRANCH_TO_CLONE:-}" 
    export CLANG_URL="${CLANG_URL:-}"
    export CLANG_BRANCH_TO_CLONE="${CLANG_BRANCH_TO_CLONE:-}" 
    
    # --- Core Build Variables ---
    export ARCH="${ARCH:-arm64}" 
    export CONFIG="${CONFIG:-bengal-perf_defconfig}" 
    export KERNEL_NAME="${KERNEL_NAME:-mrt-Kernel}" # Default ditambahkan
    
    # Atur path relatif ke CIRRUS_WORKING_DIR
    export CLANG_DIR="${CLANG_DIR:-${CIRRUS_WORKING_DIR}/greenforce-clang}" 
    export KERNEL_ROOTDIR="${KERNEL_ROOTDIR:-${CIRRUS_WORKING_DIR}/kernel}" 
    export COCCI_SCRIPT_DIR="${COCCI_SCRIPT_DIR:-${CIRRUS_WORKING_DIR}/cocci}" 
    
    # Variabel Turunan
    export DEVICE_DEFCONFIG="${CONFIG}" 
    export CLANG_ROOTDIR="${CLANG_DIR}" 
    export KERNEL_OUTDIR="${KERNEL_ROOTDIR}/out"
    export IMAGE="${KERNEL_OUTDIR}/arch/${ARCH}/boot/Image.gz"
    export DTBO="${KERNEL_OUTDIR}/arch/${ARCH}/boot/dtbo.img"
    export DATE=$(date +"%Y%m%d-%H%M%S") 
    export BOT_MSG_URL="https://api.telegram.org/bot${TG_TOKEN}/sendMessage"
    export BOT_DOC_URL="https://api.telegram.org/bot${TG_TOKEN}/sendDocument"

    # Variabel kompilator tambahan (Diperlukan untuk perbaikan sintaksis)
    export USE_COMPILER_DEFAULT="${USE_COMPILER_DEFAULT:-true}"
    export USE_COMPILER_EXTRA="${USE_COMPILER_EXTRA:-}"
    export BUILD_TYPE="${BUILD_TYPE:-1}" # 1: Image.gz dtbo.img, 2: Image.gz, auto: Image.gz dtbo.img

    # Menyimpan waktu mulai
    export START=$(date +"%s")
    
    # --- Flag KSU (Atur default ke false/nilai string) ---
    export KSU_ENABLE="${KSU_ENABLE:-false}"          
    export KSU_VERSION="${KSU_VERSION:-main}"        
    export KSU_LKM_ENABLE="${KSU_LKM_ENABLE:-false}" 
    export KSU_OTHER_ENABLE="${KSU_OTHER_ENABLE:-false}" 
    export KSU_EXPERIMENTAL="${KSU_EXPERIMENTAL:-false}"
    export KSU_OTHER_URL="${KSU_OTHER_URL:-https://raw.githubusercontent.com/tiann/KernelSU}" 
    export KSU_SKIP_PATCH="${KSU_SKIP_PATCH:-true}"
    export COCCI_ENABLE="${COCCI_ENABLE:-true}" 
    export COCCI_REPO_URL="${COCCI_REPO_URL:-https://github.com/dabao1955/kernel_build_action.git}"
}

# Fungsi untuk setup: kloning Cocci dan buat nongki.txt
function setup_kernel_patches() {
    if [[ "${KSU_ENABLE}" != "true" ]]; then
        echo "KernelSU dinonaktifkan. Lewati setup patching."
        return 0
    fi
    
    echo "================================================"
    echo "      Memeriksa Patching Eksternal & Non-GKI"
    echo "================================================"

    # 1. Kloning Repositori Cocci
    if [[ -n "${COCCI_REPO_URL}" ]] && [[ "${COCCI_ENABLE}" == "true" ]]; then
        echo "Mengkloning repositori Cocci..."
        rm -rf "${COCCI_SCRIPT_DIR}"
        clone_or_download "${COCCI_REPO_URL}" "${COCCI_SCRIPT_DIR}" "Cocci Repo"
    elif [[ "${COCCI_ENABLE}" == "true" ]]; then
        echo "Peringatan: COCCI_ENABLE=true, tetapi COCCI_REPO_URL tidak diatur. Melewati kloning Cocci."
    fi

    # 2. Deteksi dan Buat nongki.txt (Non-GKI check)
    if [[ ! -f "${KERNEL_ROOTDIR}/Makefile" ]]; then
        echo "Error: Makefile tidak ditemukan di ${KERNEL_ROOTDIR}. Tidak dapat menentukan versi kernel." >&2
        finerr
    fi

    (
        cd "${KERNEL_ROOTDIR}"
        local VERSION=$(grep -E '^VERSION = ' Makefile | awk '{print $3}' || echo 0)
        local PATCHLEVEL=$(grep -E '^PATCHLEVEL = ' Makefile | awk '{print $3}' || echo 0)

        # Logika: Kernel v5.10 ke atas dianggap GKI-compatible, di bawahnya Non-GKI.
        if [[ "${VERSION}" -lt 5 ]] || ( [[ "${VERSION}" -eq 5 ]] && [[ "${PATCHLEVEL}" -lt 10 ]] ); then
            echo "Kernel terdeteksi non-GKI (v${VERSION}.${PATCHLEVEL}). Membuat nongki.txt..."
            touch nongki.txt
        else
            echo "Kernel terdeteksi GKI-compatible atau lebih baru (v${VERSION}.${PATCHLEVEL}). Melewati pembuatan nongki.txt."
            rm -f nongki.txt
        fi
    ) # Subshell untuk menjaga direktori kerja
}

# Fungsi untuk mengatur variabel toolchain setelah diunduh
function setup_toolchain_env() {
    export KBUILD_BUILD_USER="${BUILD_USER:-Unknown User}"
    export KBUILD_BUILD_HOST="${BUILD_HOST:-CirrusCI}"
    export KBUILD_COMPILER_STRING="Toolchain Not Found" # Default aman

    if [[ -d "${CLANG_ROOTDIR}" ]] && [[ -f "${CLANG_ROOTDIR}/bin/clang" ]]; then
        # Mengambil versi clang dan lld (memanfaatkan subshell untuk clean execution)
        local CLANG_VER LLD_VER
        
        CLANG_VER=$( \
            "${CLANG_ROOTDIR}/bin/clang" --version 2>/dev/null | \
            head -n 1 | \
            sed -E 's/\(http.*?\)//g' | \
            sed -E 's/  */ /g' | \
            sed -E 's/^[[:space:]]*//;s/[[:space:]]*$//' \
        )
        
        LLD_VER=$( \
            "${CLANG_ROOTDIR}/bin/ld.lld" --version 2>/dev/null | \
            head -n 1 \
        )
        
        export KBUILD_COMPILER_STRING="${CLANG_VER} with ${LLD_VER}"
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
    if [[ "${KBUILD_COMPILER_STRING}" == "Toolchain Not Found" ]]; then
         setup_toolchain_env
         if [[ "${KBUILD_COMPILER_STRING}" == "Toolchain Not Found" ]]; then
             echo "Error: Toolchain (Clang) tidak ditemukan di ${CLANG_ROOTDIR}." >&2
             exit 1
         fi
    fi

    # Masuk ke root kernel
    cd "${KERNEL_ROOTDIR}"

    tg_post_msg "<b>Buiild Kernel started..</b>%0A<b>Defconfig:</b> <code>${DEVICE_DEFCONFIG}</code>%0A<b>Toolchain:</b> <code>${KBUILD_COMPILER_STRING}</code>%0A<b>Arsitektur:</b> <code>${ARCH}</code>"

    # Hapus dan buat ulang outdir
    rm -rf "${KERNEL_OUTDIR}"
    mkdir -p "${KERNEL_OUTDIR}"
    
    # 1. KONFIGURASI DEFCONFIG AWAL
    echo "Membuat defconfig awal..."
    local PATH_CLANG="${CLANG_ROOTDIR}/bin:${PATH}"
    (export PATH="${PATH_CLANG}"; make -j$(nproc) O="${KERNEL_OUTDIR}" ARCH="${ARCH}" "${DEVICE_DEFCONFIG}") || finerr
    
    # --- START Blok Conditional KSU Integration ---
    if [[ "${KSU_ENABLE}" == "true" ]]; then
        echo "================================================"
        echo "           Memeriksa dan Mengintegrasikan Root Kernel"
        echo "================================================"
        
        local KVER="${KSU_VERSION}"
        local DEFCONFIG_PATH="${KERNEL_OUTDIR}/.config"

        # 1.1 Cek Non-GKI & set KVER
        if [[ -f nongki.txt ]]; then
            # Non-GKI: Force KVER ke v0.9.5
            printf "Warning: Kernel dideteksi non-GKI. Versi KernelSU dipaksa ke v0.9.5.\n"
            KVER="v0.9.5"
        fi

        # 1.2 Kloning/Unduh KernelSU jika belum ada (KernelSU/kernel/Kconfig)
        if [[ ! -f KernelSU/kernel/Kconfig ]]; then
            local KSU_SETUP_URL="https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh"
            local KSU_BASH_ARG="${KVER}"
            local KSU_SOURCE_TYPE="tiann/KernelSU"
            
            if [[ "${KSU_OTHER_ENABLE}" == "true" ]]; then
                # Logika KernelSU pihak ketiga
                KSU_SOURCE_TYPE="KSU/SukiSU Kustom"
                
                # Deteksi format URL dan set KSU_SETUP_URL/KSU_BASH_ARG
                if [[ "${KSU_OTHER_URL}" =~ ^https://github.com/ ]]; then
                    KSU_SETUP_URL="${KSU_OTHER_URL}/raw/${KSU_VERSION}/kernel/setup.sh"
                elif [[ "${KSU_OTHER_URL}" =~ ^https://raw.githubusercontent.com/ ]]; then
                    KSU_SETUP_URL="${KSU_OTHER_URL}/${KSU_VERSION}/kernel/setup.sh"
                else
                    echo "Error: KSU_OTHER_URL tidak dikenal." >&2; finerr
                fi

                if [[ "${KSU_EXPERIMENTAL}" == "true" ]]; then
                    KSU_SETUP_URL="https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/kernel/setup.sh"
                    KSU_BASH_ARG="susfs-main"
                fi
            fi
            
            echo "Mengintegrasikan ${KSU_SOURCE_TYPE} versi: ${KVER} (Script: ${KSU_SETUP_URL})"
            # Eksekusi setup.sh yang di-pipe (Gunakan -L untuk mengikuti redirect)
            curl -LSs "${KSU_SETUP_URL}" | bash -s "${KSU_BASH_ARG}" || finerr
        else
            echo "KernelSU sudah diinisialisasi, dilewati."
        fi
        
        # 2. LOGIKA KSU LKM dan APPLY_COCCI.SH
        
        # 2.1 LKM AKTIF (Modifikasi di .config)
        if [[ "${KSU_LKM_ENABLE}" == "true" ]]; then
            echo "Mengaktifkan KernelSU sebagai LKM (Loadable Kernel Module)."
            
            # Cek KPROBES di .config, jika aktif, ubah KSU=y ke KSU=m
            if grep -q "CONFIG_KPROBES=y" "${DEFCONFIG_PATH}" 2>/dev/null; then
                sed -i 's/CONFIG_KSU=y/CONFIG_KSU=m/g' "${DEFCONFIG_PATH}"
                echo "CONFIG_KSU diubah menjadi 'm' di ${DEFCONFIG_PATH}."
            else
                # Jika KPROBES nonaktif, ubah default di Kconfig KernelSU
                sed -i 's/default y/default m/' drivers/kernelsu/Kconfig
                echo "Default KSU diubah menjadi 'm' di Kconfig KernelSU (karena KPROBES nonaktif)."
            fi
            
        # 2.2 LKM NONAKTIF & NON-GKI AKTIF (Logika Patching/Cocci)
        elif [[ -f nongki.txt ]]; then
            
            # Kondisi Patching: Non-GKI (nongki.txt ada) && KPROBES mati && skip-patch mati && Cocci diizinkan
            if grep -q "CONFIG_KPROBES=y" "${DEFCONFIG_PATH}" 2>/dev/null; then
                echo "CONFIG_KPROBES aktif di Non-GKI, skip patch Non-GKI."
            elif [[ "${KSU_SKIP_PATCH}" == "true" ]]; then
                echo "ksu-skip-patch aktif, skip patch Non-GKI."
            elif [[ "${COCCI_ENABLE}" == "true" ]]; then
                local COCCI_SCRIPT="${COCCI_SCRIPT_DIR}/kernelsu/apply_cocci.sh"
                
                if [[ -f "${COCCI_SCRIPT}" ]]; then
                    echo "Menerapkan Coccinelle/Semantic Patch (Non-GKI)..."
                    bash "${COCCI_SCRIPT}" || finerr 
                    echo "Cocci/Semantic Patch berhasil diterapkan."
                else
                    echo "Peringatan: Script Cocci '${COCCI_SCRIPT}' tidak ditemukan. Lewati patching Non-GKI."
                fi
            else
                 echo "Cocci/Semantic Patch dilewati karena COCCI_ENABLE nonaktif."
            fi
        fi
        
        # 3. SINKRONISASI KONFIGURASI
        echo "Mensinkronkan konfigurasi (olddefconfig) untuk menerapkan perubahan KSU/LKM."
        (export PATH="${PATH_CLANG}"; make -j$(nproc) O="${KERNEL_OUTDIR}" ARCH="${ARCH}" olddefconfig) || finerr 
        
    else
        echo "================================================"
        echo "   ROOT KERNEL DINETRALKAN. Melanjutkan build bersih."
        echo "================================================"
    fi
    # --- END Blok Conditional KSU Integration ---
    
    echo "Lanjutkan ke kompilasi Image.gz dan dtbo.img."
    
    # 4. Kompilasi
    local PATH="${CLANG_ROOTDIR}/bin:${PATH}"
    local CC_PREFIX="aarch64-linux-gnu-"
    local CC32_PREFIX="arm-linux-gnueabi-"

    # Jika ARCH bukan arm64, set prefix sesuai kebutuhan (asumsi arm64 yang paling umum)
    if [[ "${ARCH}" != "arm64" ]]; then
        # Biarkan default jika tidak ada logika khusus, atau tambahkan logika untuk ARM/x86 jika diperlukan
        echo "Peringatan: ARCH bukan arm64. Menggunakan default aarch64/arm32 toolchain prefix." >&2
    fi

    # 4a. Tentukan variabel kompiler (Compiler Arguments)
    local COMPILER_ARGS=""
    
    if [[ "${USE_COMPILER_DEFAULT}" == "true" ]]; then
        # Mengatur variabel kompiler secara eksplisit (Clang dan LLVM tools)
        COMPILER_ARGS="CC=clang AR=llvm-ar AS=llvm-as LD=ld.lld NM=llvm-nm OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump OBJSIZE=llvm-size READELF=llvm-readelf STRIP=llvm-strip HOSTCC=clang HOSTCXX=clang++ HOSTLD=ld.lld"
    elif [[ -n "${USE_COMPILER_EXTRA}" ]]; then
        # Menggunakan variabel tambahan yang disediakan (untuk compiler/toolset kustom)
        COMPILER_ARGS="${USE_COMPILER_EXTRA}"
    fi

    # 4b. Tentukan target make (Build Targets)
    local BUILD_TARGETS=""
    
    if [[ "${BUILD_TYPE}" == "1" ]]; then
        BUILD_TARGETS="Image.gz dtbo.img"
    elif [[ "${BUILD_TYPE}" == "2" ]]; then
        BUILD_TARGETS="Image.gz"
    elif [[ "${BUILD_TYPE}" == "auto" ]]; then
        BUILD_TARGETS="Image.gz dtbo.img" # Asumsi default "auto" adalah build penuh
    fi
    
    # Target make Image.gz dan dtbo.img
    # Semua variabel dan target sekarang dioperasikan sebagai string tunggal setelah substitusi shell
    (export PATH="${PATH}"; 
     make -j$(nproc) ARCH="${ARCH}" O="${KERNEL_OUTDIR}" \
        LLVM="1" \
        LLVM_IAS="1" \
        ${COMPILER_ARGS} \
        CROSS_COMPILE="${CC_PREFIX}" \
        CROSS_COMPILE_ARM32="${CC32_PREFIX}" \
        CROSS_COMPILE_COMPAT="${CC32_PREFIX}" \
        ${BUILD_TARGETS} \
        || finerr)
        
    if [[ ! -f "${IMAGE}" ]]; then
	    echo "Error: Image.gz tidak ditemukan setelah kompilasi." >&2
	    finerr
    fi
    
    # Kloning AnyKernel dan menyalin Image
    local ANYKERNEL_DIR="${CIRRUS_WORKING_DIR}/AnyKernel"
    rm -rf "${ANYKERNEL_DIR}" 
	git clone --depth=1 "${ANYKERNEL}" "${ANYKERNEL_DIR}" || finerr
	cp "${IMAGE}" "${DTBO}" "${ANYKERNEL_DIR}" || finerr
}

# Mendapatkan informasi commit dan kernel
function get_info() {
    cd "${KERNEL_ROOTDIR}"
    
    # Ambil versi kernel dari .config (lebih akurat sebelum UTS_VERSION dibuat)
    export KERNEL_VERSION=$(grep 'Linux/arm64' "${KERNEL_OUTDIR}/.config" | cut -d " " -f3 || echo "N/A")
    # UTS_VERSION akan ada setelah make Image.gz berhasil
    export UTS_VERSION=$(grep 'UTS_VERSION' "${KERNEL_OUTDIR}/include/generated/compile.h" 2>/dev/null | cut -d '"' -f2 || echo "N/A")
    
    # Inisialisasi default N/A
    export LATEST_COMMIT="Source Code Downloaded (No Git Info)"
    export COMMIT_CHANGE="N/A"
    export COMMIT_BY="N/A"
    export BRANCH="N/A"
    export KERNEL_SOURCE="N/A"
    export KERNEL_BRANCH="N/A"
    
    if [[ -d "${KERNEL_ROOTDIR}/.git" ]]; then
        # Gunakan %h untuk commit singkat dan pastikan ada data sebelum diekspor
        export LATEST_COMMIT="$(git log --pretty=format:'%s' -1 2>/dev/null || echo "N/A")"
        export COMMIT_CHANGE="$(git log --pretty=format:'%H' -1 2>/dev/null || echo "N/A")"
        export COMMIT_BY="$(git log --pretty=format:'by %an' -1 2>/dev/null || echo "N/A")"
        
        if [[ -n "${KERNEL_BRANCH_TO_CLONE}" ]]; then
            export BRANCH="${KERNEL_BRANCH_TO_CLONE}"
        else
            export BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "N/A")"
        fi

        export KERNEL_SOURCE="${KERNEL_SOURCE_URL}"
        export KERNEL_BRANCH="${KERNEL_BRANCH_TO_CLONE}"
    fi
    
    local CLANG_INFO="${KBUILD_COMPILER_STRING}"
    if [[ -d "${CLANG_ROOTDIR}/.git" ]] && [[ -n "${CLANG_BRANCH_TO_CLONE}" ]]; then
        CLANG_INFO="${CLANG_INFO} (Branch: ${CLANG_BRANCH_TO_CLONE})"
    fi
    export KBUILD_COMPILER_STRING="${CLANG_INFO}"
}

# Push kernel ke Telegram
function push() {
    local ANYKERNEL_DIR="${CIRRUS_WORKING_DIR}/AnyKernel"
    cd "${ANYKERNEL_DIR}"
    
    local ZIP_NAME="${KERNEL_NAME}-${DEVICE_CODENAME}-${DATE}.zip"
    
    # Kompresi AnyKernel
    zip -r9 "${ZIP_NAME}" ./* || finerr # Menggunakan ./* agar zip tidak menyertakan direktori AnyKernel/
    
    # Hitung Checksum
    local ZIP_SHA1=$(sha1sum "${ZIP_NAME}" | cut -d' ' -f1 || echo "N/A")
    local ZIP_MD5=$(md5sum "${ZIP_NAME}" | cut -d' ' -f1 || echo "N/A")
    local ZIP_SHA256=$(sha256sum "${ZIP_NAME}" | cut -d' ' -f1 || echo "N/A") 

    local END=$(date +"%s")
    local DIFF=$((END - START))
    local MINUTES=$((DIFF / 60))
    local SECONDS=$((DIFF % 60))
    
    # Menentukan status KSU (Logika disederhanakan)
    local KSU_STATUS=""
    if [[ "${KSU_ENABLE}" == "true" ]]; then
        KSU_STATUS="KernelSU: ✅ Enabled"
        if [[ "${KSU_LKM_ENABLE}" == "true" ]]; then
            KSU_STATUS="${KSU_STATUS} (LKM)"
        else
            KSU_STATUS="${KSU_STATUS} (Built-in)"
        fi

        local KSU_PATCH_INFO=""
        if [[ -f "${KERNEL_ROOTDIR}/nongki.txt" ]]; then
             KSU_PATCH_INFO="Non-GKI: Aktif"
             local DEFCONFIG_PATH="${KERNEL_OUTDIR}/.config"
             if grep -q "CONFIG_KPROBES=y" "${DEFCONFIG_PATH}" 2>/dev/null; then
                 KSU_PATCH_INFO="${KSU_PATCH_INFO}, Patch: Lewat (KPROBES Aktif)"
             elif [[ "${KSU_SKIP_PATCH}" == "true" ]]; then
                 KSU_PATCH_INFO="${KSU_PATCH_INFO}, Patch: Lewat (Manual)"
             elif [[ "${COCCI_ENABLE}" == "true" ]]; then
                 KSU_PATCH_INFO="${KSU_PATCH_INFO}, Patch: Cocci Diterapkan"
             else
                 KSU_PATCH_INFO="${KSU_PATCH_INFO}, Patch: Lewat (Cocci Nonaktif)"
             fi
        fi
        KSU_STATUS="${KSU_STATUS} (Ver: ${KSU_VERSION}) ${KSU_PATCH_INFO}"
        
    else
        KSU_STATUS="KernelSU: 🚫 Disabled (Clean Build)"
    fi
    
    local CHANGES_LINK_TEXT="N/A"
    if [[ "${KERNEL_SOURCE}" != "N/A" ]] && [[ "${COMMIT_CHANGE}" != "N/A" ]]; then
        # Asumsi KERNEL_SOURCE adalah URL Git
        CHANGES_LINK_TEXT="<a href=\"${KERNEL_SOURCE/%.git/}/commit/${COMMIT_CHANGE}\">Here</a>"
    fi
    
    # Kirim dokumen ZIP
    curl -F document=@"${ZIP_NAME}" "${BOT_DOC_URL}" \
        -F chat_id="${TG_CHAT_ID}" \
        -F "disable_web_page_preview=true" \
        -F "parse_mode=html" \
        -F caption="
<b>✅ Build Finished!</b>
==========================
<b>📦 Kernel:</b> ${KERNEL_NAME}
<b>📱 Device:</b> ${DEVICE_CODENAME}
<b>👤 Owner:</b> ${CIRRUS_REPO_OWNER:-N/A}
<b>🛠️ Status:</b> ${KSU_STATUS}
<b>🏚️ Linux version:</b> ${KERNEL_VERSION}
<b>🌿 Branch:</b> ${BRANCH}
<b>🎁 Top commit:</b> ${LATEST_COMMIT}
<b>📚 SHA1:</b> <code>${ZIP_SHA1}</code>
<b>📚 MD5:</b> <code>${ZIP_MD5}</code>
<b>📚 SHA256:</b> <code>${ZIP_SHA256}</code>
<b>👩‍💻 Commit author:</b> ${COMMIT_BY}
<b>🐧 UTS version:</b> ${UTS_VERSION}
<b>💡 Compiler:</b> ${KBUILD_COMPILER_STRING}
<b>💡 ARCH:</b> ${ARCH}
==========================
<b>⏱️ Compile took:</b> ${MINUTES} minute(s) and ${SECONDS} second(s).
<b>⚙️ Changes:</b> ${CHANGES_LINK_TEXT}"
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
