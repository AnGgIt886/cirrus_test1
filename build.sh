#!/usr/bin/env bash
#
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
    set +e
    local LOG_FILE="build.log"
    local LOG_URL="https://api.cirrus-ci.com/v1/task/${CIRRUS_TASK_ID}/logs/Build_kernel.log"
    local TG_MSG
    
    # Menangkap pesan log dari stdout/stderr sebelum exit, jika ada
    echo "Pembangunan GAGAL. Mencoba mengambil log dari ${LOG_URL}..." >&2

    # Ambil log menggunakan curl (Gunakan -f untuk mencegah curl menampilkan output error HTTP)
    if curl -Ls -f -o "${LOG_FILE}" "${LOG_URL}"; then
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
==============================" || echo "Gagal mengirim dokumen log." >&2 

    else
        echo "Gagal mengambil log dari Cirrus CI. Cek URL manual." >&2
        # Gunakan printf untuk format string yang lebih andal
        printf -v TG_MSG "<b>Pembangunan Kernel Gagal [❌]</b>\n<b>Kesalahan:</b> Gagal mendapatkan log dari Cirrus CI. Silakan cek Cirrus secara manual: <a href=\"https://cirrus-ci.com/task/%s\">Task ID %s</a>" "${CIRRUS_TASK_ID}" "${CIRRUS_TASK_ID}"
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
        # Menggunakan case yang lebih rapi untuk deteksi tipe kompresi
        case "${url}" in
            *.tar.gz|*.tgz|*.tar)
                tar -xf "${temp_file}" -C "${target_dir}" --strip-components=1 || finerr
                ;;
            *.zip)
                unzip -q "${temp_file}" -d "${target_dir}" || finerr
                ;;
            *)
                echo "Error internal: Tipe file terkompresi tidak didukung: ${url}" >&2; finerr
                ;;
        esac

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
        echo "Error: URL tidak dikenali sebagai repositori Git atau file terkompresi yang didukung: ${url}" >&2
        finerr
    fi
    
    echo "${type} berhasil diunduh/dikloning ke ${target_dir}." >&2
}

# Fungsi untuk mengunduh kernel source dan toolchain
function download_kernel_tools() {
    echo "================================================"
    echo "       Memeriksa dan Mengunduh Dependensi"
    echo "================================================"
    
    local download_needed=0 # Flag untuk cek apakah ada yang diunduh

    # 1. Download/Kloning Kernel Source
    if [[ ! -d "${KERNEL_ROOTDIR}" ]] || [[ ! -f "${KERNEL_ROOTDIR}/Makefile" ]]; then
        if [[ -n "${KERNEL_SOURCE_URL}" ]]; then
            echo "Kernel Source tidak ditemukan di ${KERNEL_ROOTDIR}, mengunduh..."
            clone_or_download "${KERNEL_SOURCE_URL}" "${KERNEL_ROOTDIR}" "Kernel Source" "${KERNEL_BRANCH_TO_CLONE}"
            download_needed=1
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
            download_needed=1
        else
            echo "Error: Toolchain (Clang) tidak ditemukan di ${CLANG_ROOTDIR} dan CLANG_URL tidak diatur." >&2
            exit 1
        fi
    else
        echo "Toolchain (Clang) ditemukan. Dilewati."
    fi
    
    # Cek sekali lagi apakah ada git yang perlu diinstal jika ada kloning baru (tergantung lingkungan CI)
    if [[ "${download_needed}" -eq 1 ]]; then
        echo "Dependensi berhasil disiapkan."
    fi
    
    echo "================================================"
}

# Mengatur variabel lingkungan dasar (Dioptimalkan)
function setup_env() {
    # Cek variabel wajib menggunakan :?
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
    export KERNEL_NAME="${KERNEL_NAME:-mrt-Kernel}" 
    
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

    # Menyimpan waktu mulai
    export START=$(date +"%s")
    
    # --- Flag KSU (Atur default ke false/nilai string) ---
    export KSU_ENABLE="${KSU_ENABLE:-false}"          
    export KSU_VERSION="${KSU_VERSION:-main}"        
    export KSU_LKM_ENABLE="${KSU_LKM_ENABLE:-false}" 
    export KSU_OTHER_ENABLE="${KSU_OTHER_ENABLE:-false}" 
    export KSU_EXPERIMENTAL="${KSU_EXPERIMENTAL:-false}"
    # Gunakan KSU_OTHER_URL yang lebih netral jika default, tapi tetap perlu set default
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
    if [[ "${COCCI_ENABLE}" == "true" ]]; then
        if [[ -n "${COCCI_REPO_URL}" ]]; then
            echo "Mengkloning repositori Cocci..."
            rm -rf "${COCCI_SCRIPT_DIR}"
            clone_or_download "${COCCI_REPO_URL}" "${COCCI_SCRIPT_DIR}" "Cocci Repo"
        else
            echo "Peringatan: COCCI_ENABLE=true, tetapi COCCI_REPO_URL tidak diatur. Melewati kloning Cocci."
        fi
    fi

    # 2. Deteksi dan Buat nongki.txt (Non-GKI check)
    if [[ ! -f "${KERNEL_ROOTDIR}/Makefile" ]]; then
        echo "Error: Makefile tidak ditemukan di ${KERNEL_ROOTDIR}. Tidak dapat menentukan versi kernel." >&2
        finerr
    fi

    # Subshell untuk menjaga direktori kerja dan set -e
    (
        set +e # Nonaktifkan set -e untuk grep/awk opsional
        cd "${KERNEL_ROOTDIR}"
        
        # Pengambilan versi kernel yang lebih ringkas dan kuat (menggunakan Bash read dan regex)
        local VERSION=0
        local PATCHLEVEL=0
        
        # Ambil VERSION dan PATCHLEVEL dari Makefile
        if grep -E '^(VERSION|PATCHLEVEL) = ' Makefile | while read -r KEY EQ VAL; do 
            case "$KEY" in
                VERSION) VERSION="$VAL" ;;
                PATCHLEVEL) PATCHLEVEL="$VAL" ;;
            esac
        done; then
            : # Lanjutkan
        fi
        
        # Logika: Kernel v5.10 ke atas dianggap GKI-compatible, di bawahnya Non-GKI.
        if [[ "${VERSION}" -lt 5 ]] || ( [[ "${VERSION}" -eq 5 ]] && [[ "${PATCHLEVEL}" -lt 10 ]] ); then
            echo "Kernel terdeteksi non-GKI (v${VERSION}.${PATCHLEVEL}). Membuat nongki.txt..."
            touch nongki.txt
        else
            echo "Kernel terdeteksi GKI-compatible atau lebih baru (v${VERSION}.${PATCHLEVEL}). Melewati pembuatan nongki.txt."
            rm -f nongki.txt
        fi
    )
    echo "KernelSU setup patching/Non-GKI check selesai."
}

# Fungsi untuk mengatur variabel toolchain setelah diunduh
function setup_toolchain_env() {
    # Set default
    export KBUILD_BUILD_USER="${BUILD_USER:-Unknown User}"
    export KBUILD_BUILD_HOST="${BUILD_HOST:-CirrusCI}"
    export KBUILD_COMPILER_STRING="Toolchain Not Found" 

    if [[ -d "${CLANG_ROOTDIR}" ]] && [[ -f "${CLANG_ROOTDIR}/bin/clang" ]]; then
        # Mengambil versi clang dan lld (lebih efisien dengan meminimalisir pipe)
        local CLANG_VER
        local LLD_VER
        
        # Clang Version
        CLANG_VER=$("${CLANG_ROOTDIR}/bin/clang" --version 2>/dev/null | head -n 1)
        # Hapus URL (di dalam kurung) dan spasi berlebih
        CLANG_VER=$(echo "${CLANG_VER}" | sed -E 's/\(http.*?\)//g' | tr -s ' ' | sed -E 's/^[[:space:]]*//;s/[[:space:]]*$//')

        # LLD Version
        LLD_VER=$("${CLANG_ROOTDIR}/bin/ld.lld" --version 2>/dev/null | head -n 1)
        
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
         # Panggil lagi jika di setup_env gagal mendapatkan versi
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
    # Komando make dalam subshell untuk menghindari polusi PATH global
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
            echo "Warning: Kernel dideteksi non-GKI. Versi KernelSU dipaksa ke v0.9.5."
            KVER="v0.9.5"
        fi

        # 1.2 Kloning/Unduh KernelSU jika belum ada (KernelSU/kernel/Kconfig)
        if [[ ! -f KernelSU/kernel/Kconfig ]]; then
            local KSU_SETUP_URL="https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh"
            local KSU_BASH_ARG="${KVER}"
            local KSU_SOURCE_TYPE="tiann/KernelSU"
            
            # Logika KernelSU pihak ketiga (dioptimalkan)
            if [[ "${KSU_OTHER_ENABLE}" == "true" ]]; then
                KSU_SOURCE_TYPE="KSU/SukiSU Kustom"
                
                if [[ "${KSU_EXPERIMENTAL}" == "true" ]]; then
                    KSU_SETUP_URL="https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/kernel/setup.sh"
                    KSU_BASH_ARG="susfs-main"
                # Deteksi format URL dan set KSU_SETUP_URL/KSU_BASH_ARG (tidak perlu regex ganda)
                elif [[ "${KSU_OTHER_URL}" =~ ^https://github.com/ ]]; then
                    KSU_SETUP_URL="${KSU_OTHER_URL/github.com/raw.githubusercontent.com/}/${KSU_VERSION}/kernel/setup.sh"
                elif [[ "${KSU_OTHER_URL}" =~ ^https://raw.githubusercontent.com/ ]]; then
                    KSU_SETUP_URL="${KSU_OTHER_URL}/${KSU_VERSION}/kernel/setup.sh"
                else
                    echo "Error: KSU_OTHER_URL tidak dikenal." >&2; finerr
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
                # Menggunakan sed -i yang lebih hati-hati (tanpa backup)
                sed -i 's/\(CONFIG_KSU=\)y/\1m/g' "${DEFCONFIG_PATH}"
                echo "CONFIG_KSU diubah menjadi 'm' di ${DEFCONFIG_PATH} (KPROBES Aktif)."
            else
                # Jika KPROBES nonaktif, ubah default di Kconfig KernelSU
                # Asumsi Kconfig belum dimuat ke .config, jadi modif Kconfig source
                sed -i 's/\(default\) y/\1 m/' drivers/kernelsu/Kconfig
                echo "Default KSU diubah menjadi 'm' di Kconfig KernelSU (karena KPROBES nonaktif)."
            fi
            
        # 2.2 LKM NONAKTIF & NON-GKI AKTIF (Logika Patching/Cocci)
        elif [[ -f nongki.txt ]]; then
            local KPROBES_ACTIVE=0
            if grep -q "CONFIG_KPROBES=y" "${DEFCONFIG_PATH}" 2>/dev/null; then
                KPROBES_ACTIVE=1
            fi
            
            if [[ "${KPROBES_ACTIVE}" -eq 1 ]]; then
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
                end
            else
                 echo "Cocci/Semantic Patch dilewati karena COCCI_ENABLE nonaktif."
            fi
        fi
        
        # 3. SINKRONISASI KONFIGURASI
        echo "Mensinkronkan konfigurasi (olddefconfig) untuk menerapkan perubahan KSU/LKM."
        # Komando make dalam subshell untuk menghindari polusi PATH global
        (export PATH="${PATH_CLANG}"; make -j$(nproc) O="${KERNEL_OUTDIR}" ARCH="${ARCH}" olddefconfig) || finerr 
        
    else
        echo "================================================"
        echo "   ROOT KERNEL DINETRALKAN. Melanjutkan build bersih."
        echo "================================================"
    fi
    # --- END Blok Conditional KSU Integration ---
    
    echo "Lanjutkan ke kompilasi Image.gz dan dtbo.img."
    
    # 4. Kompilasi
    local PATH_BUILD="${CLANG_ROOTDIR}/bin:${PATH}"
    local CC_PREFIX="aarch64-linux-gnu-"
    local CC32_PREFIX="arm-linux-gnueabi-"

    # Memastikan toolchain prefix dikelola dengan baik
    if [[ "${ARCH}" != "arm64" ]]; then
        echo "Peringatan: ARCH bukan arm64. Menggunakan default aarch64/arm32 toolchain prefix." >&2
    fi

    # Komando make dalam subshell untuk menjaga PATH
    (
        export PATH="${PATH_BUILD}"

        make -j$(nproc) ARCH="${ARCH}" O="${KERNEL_OUTDIR}" \
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
            CROSS_COMPILE="${CC_PREFIX}" \
            CROSS_COMPILE_ARM32="${CC32_PREFIX}" \
            CROSS_COMPILE_COMPAT="${CC32_PREFIX}" \
            Image.gz dtbo.img
    ) || finerr 
        
    if [[ ! -f "${IMAGE}" ]]; then
	    echo "Error: Image.gz tidak ditemukan setelah kompilasi." >&2
	    finerr
    fi
    
    # Kloning AnyKernel dan menyalin Image
    local ANYKERNEL_DIR="${CIRRUS_WORKING_DIR}/AnyKernel"
    rm -rf "${ANYKERNEL_DIR}" 
    # Clone AnyKernel (tanpa --depth=1 karena tidak semua repo AnyKernel adalah git repo)
	git clone "${ANYKERNEL}" "${ANYKERNEL_DIR}" || finerr 
	cp "${IMAGE}" "${DTBO}" "${ANYKERNEL_DIR}" || finerr
}

# Mendapatkan informasi commit dan kernel (Dioptimalkan)
function get_info() {
    cd "${KERNEL_ROOTDIR}"
    
    # Ambil versi kernel dari .config 
    # Menggunakan regex/sed yang lebih cepat daripada cut/grep/awk berantai
    export KERNEL_VERSION=$(sed -nE 's/^# Linux\/(arm|arm64) version ([0-9.]+)\.[0-9]+\.([0-9]+)\..*/\2/p' "${KERNEL_OUTDIR}/.config" 2>/dev/null || echo "N/A")
    
    # UTS_VERSION akan ada setelah make Image.gz berhasil
    # Menggunakan sed untuk ekstraksi string
    export UTS_VERSION=$(sed -nE 's/.*#define UTS_VERSION "(.*)"/\1/p' "${KERNEL_OUTDIR}/include/generated/compile.h" 2>/dev/null || echo "N/A")
    
    # Inisialisasi default N/A
    export LATEST_COMMIT="Source Code Downloaded (No Git Info)"
    export COMMIT_CHANGE="N/A"
    export COMMIT_BY="N/A"
    export BRANCH="N/A"
    export KERNEL_SOURCE="${KERNEL_SOURCE_URL:-N/A}"
    export KERNEL_BRANCH="${KERNEL_BRANCH_TO_CLONE:-N/A}"
    
    # Cek direktori Git
    if [[ -d "${KERNEL_ROOTDIR}/.git" ]]; then
        # Menggunakan format log tunggal untuk efisiensi
        local GIT_LOG
        GIT_LOG=$(git log --pretty=format:'%s%n%H%nby %an' -1 2>/dev/null) || true # Izinkan kegagalan

        if [[ -n "${GIT_LOG}" ]]; then
            # Memecah string log menjadi variabel dengan read
            readarray -t LOG_ARRAY <<< "${GIT_LOG}"
            export LATEST_COMMIT="${LOG_ARRAY[0]:-N/A}"
            export COMMIT_CHANGE="${LOG_ARRAY[1]:-N/A}"
            export COMMIT_BY="${LOG_ARRAY[2]:-N/A}"
        fi
        
        if [[ -z "${KERNEL_BRANCH_TO_CLONE}" ]]; then
            export BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "N/A")"
        else
            export BRANCH="${KERNEL_BRANCH_TO_CLONE}"
        fi

        # KERNEL_SOURCE sudah diset di setup_env, tidak perlu diubah kecuali perlu verifikasi URL
    fi
    
    # Tambahkan info branch Clang jika ada
    local CLANG_INFO="${KBUILD_COMPILER_STRING}"
    if [[ -d "${CLANG_ROOTDIR}/.git" ]] && [[ -n "${CLANG_BRANCH_TO_CLONE}" ]]; then
        CLANG_INFO="${CLANG_INFO} (Branch: ${CLANG_BRANCH_TO_CLONE})"
    fi
    export KBUILD_COMPILER_STRING="${CLANG_INFO}"
}

# Push kernel ke Telegram (Dioptimalkan)
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
        KSU_STATUS+=$([[ "${KSU_LKM_ENABLE}" == "true" ]] && echo " (LKM)" || echo " (Built-in)")

        local KSU_PATCH_INFO=""
        if [[ -f "${KERNEL_ROOTDIR}/nongki.txt" ]]; then
             KSU_PATCH_INFO="Non-GKI: Aktif"
             local DEFCONFIG_PATH="${KERNEL_OUTDIR}/.config"
             
             if grep -q "CONFIG_KPROBES=y" "${DEFCONFIG_PATH}" 2>/dev/null; then
                 KSU_PATCH_INFO+=", Patch: Lewat (KPROBES Aktif)"
             elif [[ "${KSU_SKIP_PATCH}" == "true" ]]; then
                 KSU_PATCH_INFO+=", Patch: Lewat (Manual)"
             elif [[ "${COCCI_ENABLE}" == "true" ]]; then
                 KSU_PATCH_INFO+=", Patch: Cocci Diterapkan"
             else
                 KSU_PATCH_INFO+=", Patch: Lewat (Cocci Nonaktif)"
             fi
        fi
        KSU_STATUS+=" (Ver: ${KSU_VERSION}) ${KSU_PATCH_INFO}"
        
    else
        KSU_STATUS="KernelSU: 🚫 Disabled (Clean Build)"
    fi
    
    local CHANGES_LINK_TEXT="N/A"
    # Menggunakan KERNEL_SOURCE yang sudah diset di get_info (dengan default N/A)
    if [[ "${KERNEL_SOURCE}" != "N/A" ]] && [[ "${COMMIT_CHANGE}" != "N/A" ]]; then
        # Mengganti .git pada URL dengan string kosong
        CHANGES_LINK_TEXT="<a href=\"${KERNEL_SOURCE/%.git/}/commit/${COMMIT_CHANGE}\">Here</a>"
    fi
    
    # Gunakan printf untuk string multi-line yang lebih bersih
    printf -v CAPTION_MSG "
<b>✅ Build Finished!</b>
==========================
<b>📦 Kernel:</b> %s
<b>📱 Device:</b> %s
<b>👤 Owner:</b> %s
<b>🛠️ Status:</b> %s
<b>🏚️ Linux version:</b> %s
<b>🌿 Branch:</b> %s
<b>🎁 Top commit:</b> %s
<b>📚 SHA1:</b> <code>%s</code>
<b>📚 MD5:</b> <code>%s</code>
<b>📚 SHA256:</b> <code>%s</code>
<b>👩‍💻 Commit author:</b> %s
<b>🐧 UTS version:</b> %s
<b>💡 Compiler:</b> %s
<b>💡 ARCH:</b> %s
==========================
<b>⏱️ Compile took:</b> %d minute(s) and %d second(s).
<b>⚙️ Changes:</b> %s" \
    "${KERNEL_NAME}" \
    "${DEVICE_CODENAME}" \
    "${CIRRUS_REPO_OWNER:-N/A}" \
    "${KSU_STATUS}" \
    "${KERNEL_VERSION}" \
    "${BRANCH}" \
    "${LATEST_COMMIT}" \
    "${ZIP_SHA1}" \
    "${ZIP_MD5}" \
    "${ZIP_SHA256}" \
    "${COMMIT_BY}" \
    "${UTS_VERSION}" \
    "${KBUILD_COMPILER_STRING}" \
    "${ARCH}" \
    "${MINUTES}" \
    "${SECONDS}" \
    "${CHANGES_LINK_TEXT}"

    # Kirim dokumen ZIP
    curl -F document=@"${ZIP_NAME}" "${BOT_DOC_URL}" \
        -F chat_id="${TG_CHAT_ID}" \
        -F "disable_web_page_preview=true" \
        -F "parse_mode=html" \
        -F caption="${CAPTION_MSG}"
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
