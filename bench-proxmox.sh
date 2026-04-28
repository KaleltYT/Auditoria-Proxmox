#!/usr/bin/env bash
# bench-proxmox.sh
# Banco de pruebas de rendimiento para nodos Proxmox VE.
# Genera un informe Markdown con resultados de CPU, memoria, disco y red.
#
# Uso rápido (en la shell del nodo Proxmox, como root):
#   bash <(curl -fsSL https://raw.githubusercontent.com/KaleltYT/Auditoria-Proxmox/main/bench-proxmox.sh) all
#   bash <(wget -qO- https://raw.githubusercontent.com/KaleltYT/Auditoria-Proxmox/main/bench-proxmox.sh) all
#
# Tests:
#   cpu           Benchmark CPU (sysbench, openssl speed, compresión).
#   mem           Memoria (sysbench memory o dd como fallback).
#   disk          Disco (fio si está; dd como fallback). Usa --bench-dir.
#   pveperf       Ejecuta pveperf (CPU + HD seek + fsync + DNS).
#   net-server    Inicia iperf3 en modo servidor. Ctrl-C para detener.
#   net-client    iperf3 cliente contra --target HOST[:PUERTO].
#   vm-net        Test entre dos VMs (--vm-a ID --vm-b ID, requiere qemu-guest-agent
#                 e iperf3 dentro de las VMs).
#   all           cpu + mem + pveperf + disk (NO toca la red).
#
# Opciones:
#   -o, --output FILE     Informe (def. /root/proxmox-bench-<host>-<fecha>.md)
#       --bench-dir DIR   Directorio para tempfiles de disco (def. /var/tmp)
#       --disk-size SZ    Tamaño del archivo de prueba de disco (def. 1G)
#       --duration S      Duración de cada test (def. 20)
#       --threads N       Hilos (def. nproc)
#       --target HOST     Servidor iperf3 para net-client
#       --port N          Puerto iperf3 (def. 5201)
#       --vm-a ID         ID de la VM cliente (vm-net)
#       --vm-b ID         ID de la VM servidor (vm-net)
#       --install         Ofrece apt install para los paquetes que falten
#       --serve [PORT]    Tras los tests, sirve el informe por HTTP (def. 8765)
#       --cleanup [PATH]  No mide: borra rastros (informe, history, tempfiles)
#       --print-base64 [PATH]  No mide: imprime el informe en gzip+base64 a stdout
#                         para copy/paste cuando --serve está bloqueado por firewall
#       --plain           Combinado con --print-base64, omite el gzip (más fácil de
#                         decodificar en Windows con certutil)
#   -h, --help            Ayuda

set -u
umask 077

unset HISTFILE
export HISTFILE=/dev/null
export HISTSIZE=0
export HISTFILESIZE=0

VERSION="1.0.0"
HOSTNAME_SHORT=$(hostname -s 2>/dev/null || hostname)
TODAY=$(date +%Y-%m-%d_%H%M%S)
DEFAULT_OUT="/root/proxmox-bench-${HOSTNAME_SHORT}-${TODAY}.md"
OUTPUT="$DEFAULT_OUT"

BENCH_DIR="/var/tmp"
DISK_SIZE="1G"
DURATION=20
THREADS=$(nproc 2>/dev/null || echo 4)
TARGET=""
PORT=5201
VM_A=""
VM_B=""
DO_INSTALL=0
SERVE=0
SERVE_PORT=8765
CLEANUP=0
CLEANUP_PATH=""
PRINT_B64=0
PRINT_B64_PATH=""
PRINT_B64_PLAIN=0

TESTS=()

SELF_PATH=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    SELF_PATH=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "")
fi

usage() {
    sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--output)    OUTPUT="${2:-}"; shift 2 ;;
        --bench-dir)    BENCH_DIR="${2:-}"; shift 2 ;;
        --disk-size)    DISK_SIZE="${2:-}"; shift 2 ;;
        --duration)     DURATION="${2:-}"; shift 2 ;;
        --threads)      THREADS="${2:-}"; shift 2 ;;
        --target)       TARGET="${2:-}"; shift 2 ;;
        --port)         PORT="${2:-}"; shift 2 ;;
        --vm-a)         VM_A="${2:-}"; shift 2 ;;
        --vm-b)         VM_B="${2:-}"; shift 2 ;;
        --install)      DO_INSTALL=1; shift ;;
        --serve)
            SERVE=1
            if [[ "${2:-}" =~ ^[0-9]+$ ]]; then SERVE_PORT="$2"; shift 2; else shift; fi
            ;;
        --cleanup)
            CLEANUP=1
            if [[ -n "${2:-}" && "${2:0:1}" != "-" ]]; then CLEANUP_PATH="$2"; shift 2; else shift; fi
            ;;
        --print-base64)
            PRINT_B64=1
            if [[ -n "${2:-}" && "${2:0:1}" != "-" ]]; then PRINT_B64_PATH="$2"; shift 2; else shift; fi
            ;;
        --plain)        PRINT_B64_PLAIN=1; shift ;;
        -h|--help)      usage 0 ;;
        cpu|mem|disk|pveperf|net-server|net-client|vm-net|all)
            TESTS+=("$1"); shift ;;
        *) echo "Opción/test desconocido: $1" >&2; usage 1 ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: ejecútalo como root." >&2; exit 1
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { printf '[bench] %s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

w()        { printf '%s\n' "$*" >> "$OUTPUT"; }
blank()    { printf '\n'         >> "$OUTPUT"; }
section()    { blank; w "## $*"; blank; }
subsection() { blank; w "### $*"; blank; }

run_capture() {
    local desc="$1"; shift
    w "**${desc}**"
    w ''
    w '```'
    "$@" >> "$OUTPUT" 2>&1 || w "(comando devolvió código $?)"
    w '```'
    blank
}

run_sh_capture() {
    local desc="$1"; shift
    w "**${desc}**"
    w ''
    w '```'
    bash -c "$*" >> "$OUTPUT" 2>&1 || w "(comando devolvió código $?)"
    w '```'
    blank
}

secure_rm() {
    local f="$1"
    [[ -e "$f" ]] || return 0
    local rp; rp=$(readlink -f -- "$f" 2>/dev/null || echo "$f")
    if [[ -n "$SELF_PATH" && "$rp" == "$SELF_PATH" ]]; then return 0; fi
    if have shred; then shred -u -- "$f" 2>/dev/null || rm -f -- "$f"
    else rm -f -- "$f"
    fi
}

cleanup_traces() {
    local target_md="${1:-}"
    log "Limpiando rastros..."
    [[ -n "$target_md" && -e "$target_md" ]] && { secure_rm "$target_md"; log "  borrado: $target_md"; }
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        secure_rm "$f"; log "  borrado: $f"
    done < <(ls -1 /root/proxmox-bench-*.md /tmp/proxmox-bench-*.md 2>/dev/null || true)
    for s in /root/bench-proxmox.sh /tmp/bench-proxmox.sh; do
        [[ -f "$s" ]] && { secure_rm "$s"; [[ ! -e "$s" ]] && log "  borrado: $s"; }
    done
    # tempfiles del benchmark de disco
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        rm -f -- "$f"; log "  borrado tempfile: $f"
    done < <(ls -1 /var/tmp/pveBench-* /tmp/pveBench-* 2>/dev/null || true)
    for hf in "${HOME:-/root}/.bash_history" /root/.bash_history; do
        [[ -f "$hf" ]] && sed -i -E '/(bench-proxmox|proxmox-bench|Auditoria-Proxmox)/d' "$hf" 2>/dev/null || true
    done
    history -c 2>/dev/null || true
    log "Hecho."
}

serve_report() {
    local file="$1" port="${2:-8765}"
    [[ -f "$file" ]] || { log "ERROR: no existe $file"; return 1; }
    local token serve_dir
    token=$(head -c 18 /dev/urandom | base64 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c 24)
    [[ -z "$token" ]] && token="bench-$$"
    serve_dir=$(mktemp -d /tmp/pvebench-XXXXXX); chmod 700 "$serve_dir"
    cp -- "$file" "$serve_dir/${token}.md"; chmod 600 "$serve_dir/${token}.md"
    log ""
    log "============================================================"
    log " Informe disponible (URL aleatoria, un solo uso recomendado):"
    while IFS= read -r ip; do
        [[ -z "$ip" ]] && continue
        log "   http://${ip}:${port}/${token}.md"
    done < <(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
    log " Ctrl-C cuando termines: detiene y borra la copia."
    log ""
    log " Si el navegador NO carga la URL, un firewall en medio bloquea el puerto."
    log " Detén con Ctrl-C y usa el modo base64 (no necesita red):"
    log "   bash <(curl -fsSL https://raw.githubusercontent.com/KaleltYT/Auditoria-Proxmox/main/bench-proxmox.sh) --print-base64 '$file'"
    log "============================================================"
    trap 'rm -rf -- "'"$serve_dir"'"; log "Servidor detenido y copia borrada."; exit 0' INT TERM
    cd "$serve_dir" || return 1
    if have python3; then python3 -m http.server "$port" --bind 0.0.0.0
    elif have python; then python -m SimpleHTTPServer "$port"
    else log "ERROR: sin python."; rm -rf -- "$serve_dir"; return 1
    fi
}

ensure_pkg() {
    # ensure_pkg "fio" "fio"  -> command, paquete
    local cmd="$1" pkg="${2:-$1}"
    if have "$cmd"; then return 0; fi
    if [[ $DO_INSTALL -eq 1 ]]; then
        log "Instalando $pkg ..."
        apt-get update -qq && apt-get install -y -qq "$pkg" >/dev/null 2>&1
        have "$cmd"
    else
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Modo --cleanup
# ---------------------------------------------------------------------------
if [[ $CLEANUP -eq 1 ]]; then
    cleanup_traces "$CLEANUP_PATH"; exit 0
fi

# Modo --print-base64
if [[ $PRINT_B64 -eq 1 ]]; then
    f="$PRINT_B64_PATH"
    if [[ -z "$f" ]]; then
        f=$(ls -1t /root/proxmox-bench-*.md /tmp/proxmox-bench-*.md 2>/dev/null | head -1)
    fi
    if [[ -z "$f" || ! -f "$f" ]]; then
        echo "ERROR: no encontré informe. Pasa la ruta como --print-base64 PATH" >&2
        exit 1
    fi
    log "Imprimiendo $f ($(du -h "$f" | awk '{print $1}')) en base64."
    log "Selecciona TODA la línea de abajo. Para decodificar en local:"
    if [[ $PRINT_B64_PLAIN -eq 1 ]]; then
        log "  Linux/macOS:  echo 'PEGA_AQUI' | base64 -d > bench.md"
        log "  Windows cmd:  guarda en bench.b64 y:  certutil -decode bench.b64 bench.md"
        log "------------------ INICIO BASE64 ------------------"
        base64 -w0 -- "$f"
    else
        log "  Linux/macOS:  echo 'PEGA_AQUI' | base64 -d | gunzip > bench.md"
        log "  Windows PS:   ver OFFLINE.md (sección 'Decodificar base64 en Windows')"
        log "  (¿en cmd.exe? relánzame con --print-base64 --plain)"
        log "------------------ INICIO BASE64 ------------------"
        gzip -c -- "$f" | base64 -w0
    fi
    echo
    log "------------------- FIN BASE64 --------------------"
    exit 0
fi


# Si no hay tests pero hay --serve, sirve un informe ya existente.
if [[ ${#TESTS[@]} -eq 0 && $SERVE -eq 1 ]]; then
    LATEST=$(ls -1t /root/proxmox-bench-*.md 2>/dev/null | head -1)
    [[ -n "$LATEST" ]] && OUTPUT="$LATEST"
    [[ -z "${LATEST:-}" || ! -f "$OUTPUT" ]] && { log "No hay informe que servir."; exit 1; }
    serve_report "$OUTPUT" "$SERVE_PORT"; exit 0
fi

if [[ ${#TESTS[@]} -eq 0 ]]; then
    echo "ERROR: indica al menos un test (cpu, mem, disk, pveperf, net-server, net-client, vm-net, all)." >&2
    usage 1
fi

# Expandir 'all'
EXPANDED=()
for t in "${TESTS[@]}"; do
    if [[ "$t" == "all" ]]; then
        EXPANDED+=(cpu mem pveperf disk)
    else
        EXPANDED+=("$t")
    fi
done
TESTS=("${EXPANDED[@]}")

OUT_DIR=$(dirname -- "$OUTPUT")
mkdir -p -- "$OUT_DIR"
: > "$OUTPUT" || { echo "ERROR: no puedo escribir $OUTPUT" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Cabecera del informe
# ---------------------------------------------------------------------------
log "Informe en $OUTPUT"
PVE_VERSION=$(pveversion 2>/dev/null | head -n1 || echo 'no detectado')
w "# Benchmark Proxmox VE — ${HOSTNAME_SHORT}"
blank
w "- **Fecha:** $(date -Iseconds)"
w "- **Host:** $(hostname -f 2>/dev/null || hostname)"
w "- **Proxmox:** ${PVE_VERSION}"
w "- **Kernel:** $(uname -r)"
w "- **CPU:** $(lscpu 2>/dev/null | awk -F: '/Model name/ {gsub(/^ +/, "", $2); print $2; exit}')"
w "- **RAM total:** $(free -h | awk '/^Mem:/ {print $2}')"
w "- **Tests pedidos:** ${TESTS[*]}"
w "- **Generado por:** bench-proxmox.sh v${VERSION}"
blank
w "> Estos benchmarks generan **carga real** (CPU, I/O, red). Si el nodo está en producción"
w "> con VMs activas, los resultados pueden afectar a su rendimiento durante la ejecución."
blank
w "---"

# ---------------------------------------------------------------------------
# Estado del sistema antes de medir (ruido de fondo)
# ---------------------------------------------------------------------------
section "0. Estado del sistema antes de medir"
run_capture "uptime"               uptime
run_capture "Top procesos por CPU" bash -c "ps -eo pid,pcpu,pmem,comm --sort=-pcpu | head -10"
run_capture "Memoria"              free -h
run_capture "Cargas de I/O actuales (vmstat 1 3)" vmstat 1 3

# ---------------------------------------------------------------------------
# CPU
# ---------------------------------------------------------------------------
bench_cpu() {
    section "CPU"
    log "Bench CPU (sysbench / openssl / compresión)..."

    if ensure_pkg sysbench; then
        run_capture "sysbench cpu (single thread)" \
            sysbench cpu --cpu-max-prime=20000 --threads=1 --time="$DURATION" run
        run_capture "sysbench cpu (--threads=$THREADS)" \
            sysbench cpu --cpu-max-prime=20000 --threads="$THREADS" --time="$DURATION" run
    else
        w "_sysbench no disponible (\`apt install sysbench\` o usa --install). Salto CPU sysbench._"
        blank
    fi

    if have openssl; then
        run_capture "openssl speed -evp aes-256-gcm (cifrado HW)" \
            bash -c "openssl speed -seconds 5 -evp aes-256-gcm 2>&1 | tail -10"
        run_capture "openssl speed -evp sha256" \
            bash -c "openssl speed -seconds 5 -evp sha256 2>&1 | tail -10"
    fi

    # Compresión: bench rápido y sin dependencias adicionales
    if have gzip; then
        run_sh_capture "Compresión gzip de 256MB de /dev/urandom" \
            "dd if=/dev/urandom bs=1M count=256 2>/dev/null | { time gzip -c > /dev/null; } 2>&1"
    fi
    if have xz; then
        run_sh_capture "Compresión xz -3 de 128MB de /dev/urandom" \
            "dd if=/dev/urandom bs=1M count=128 2>/dev/null | { time xz -3 -c > /dev/null; } 2>&1"
    fi
    if have 7z; then
        run_capture "7z benchmark (1 minuto)" bash -c "timeout 65 7z b -mmt=$THREADS 2>&1 | tail -25"
    fi
}

# ---------------------------------------------------------------------------
# Memoria
# ---------------------------------------------------------------------------
bench_mem() {
    section "Memoria"
    log "Bench memoria..."

    if ensure_pkg sysbench; then
        run_capture "sysbench memory write 1M-block (--threads=1)" \
            sysbench memory --memory-block-size=1M --memory-total-size=10G \
                            --memory-oper=write --threads=1 run
        run_capture "sysbench memory read 1M-block (--threads=$THREADS)" \
            sysbench memory --memory-block-size=1M --memory-total-size=20G \
                            --memory-oper=read --threads="$THREADS" run
        run_capture "sysbench memory write 4K-block (latencia)" \
            sysbench memory --memory-block-size=4K --memory-total-size=2G \
                            --memory-oper=write --threads=1 run
    else
        w "_sysbench no disponible. Fallback con dd (orientativo)._"
        blank
        run_sh_capture "dd a /dev/null (lectura desde /dev/zero)" \
            "dd if=/dev/zero of=/dev/null bs=1M count=8192 2>&1"
        run_sh_capture "dd a /dev/shm (escritura RAM)" \
            "dd if=/dev/zero of=/dev/shm/bench-mem bs=1M count=4096 oflag=direct 2>&1; rm -f /dev/shm/bench-mem"
    fi
}

# ---------------------------------------------------------------------------
# Disco
# ---------------------------------------------------------------------------
bench_disk() {
    section "Disco / Almacenamiento"
    mkdir -p -- "$BENCH_DIR" 2>/dev/null
    if [[ ! -w "$BENCH_DIR" ]]; then
        w "_No puedo escribir en \`$BENCH_DIR\`. Cambia con --bench-dir._"; return
    fi

    # Avisar de qué storage subyacente toca
    local fstype mount
    mount=$(df -P "$BENCH_DIR" | awk 'NR==2 {print $6}')
    fstype=$(df -PT "$BENCH_DIR" | awk 'NR==2 {print $2}')
    w "**Directorio de prueba:** \`${BENCH_DIR}\` (montaje \`${mount}\`, FS \`${fstype}\`)"
    w "**Tamaño del archivo:** ${DISK_SIZE} · **Duración por test:** ${DURATION}s"
    blank

    log "Bench disco en $BENCH_DIR (tempfile ${DISK_SIZE}, $DURATION s/test)..."

    if ensure_pkg fio; then
        local TMP="${BENCH_DIR}/pveBench-$$-$(date +%s).fio"
        # Creamos el archivo previamente (layout) para que las comparaciones sean justas.
        run_sh_capture "fio: 4K random read (iodepth=32, $THREADS jobs, direct)" \
            "fio --name=randread --filename='$TMP' --size='$DISK_SIZE' --rw=randread \
                 --bs=4k --iodepth=32 --numjobs=$THREADS --direct=1 --time_based \
                 --runtime=$DURATION --group_reporting --ioengine=libaio --output-format=normal"
        run_sh_capture "fio: 4K random write (iodepth=32, $THREADS jobs, direct)" \
            "fio --name=randwrite --filename='$TMP' --size='$DISK_SIZE' --rw=randwrite \
                 --bs=4k --iodepth=32 --numjobs=$THREADS --direct=1 --time_based \
                 --runtime=$DURATION --group_reporting --ioengine=libaio --output-format=normal"
        run_sh_capture "fio: 1M sequential read" \
            "fio --name=seqread --filename='$TMP' --size='$DISK_SIZE' --rw=read \
                 --bs=1M --iodepth=8 --numjobs=1 --direct=1 --time_based \
                 --runtime=$DURATION --group_reporting --ioengine=libaio --output-format=normal"
        run_sh_capture "fio: 1M sequential write" \
            "fio --name=seqwrite --filename='$TMP' --size='$DISK_SIZE' --rw=write \
                 --bs=1M --iodepth=8 --numjobs=1 --direct=1 --time_based \
                 --runtime=$DURATION --group_reporting --ioengine=libaio --output-format=normal"
        run_sh_capture "fio: mixto 70/30 4K random (iodepth=16)" \
            "fio --name=mix --filename='$TMP' --size='$DISK_SIZE' --rw=randrw --rwmixread=70 \
                 --bs=4k --iodepth=16 --numjobs=$THREADS --direct=1 --time_based \
                 --runtime=$DURATION --group_reporting --ioengine=libaio --output-format=normal"
        rm -f -- "$TMP"
    else
        w "_fio no disponible. Fallback con dd (NO mide IOPS, sólo throughput aproximado)._"
        blank
        local TMP="${BENCH_DIR}/pveBench-dd-$$"
        run_sh_capture "dd write secuencial 1M*1024 (oflag=direct)" \
            "dd if=/dev/zero of='$TMP' bs=1M count=1024 oflag=direct conv=fdatasync 2>&1"
        run_sh_capture "Drop caches" "sync; echo 3 > /proc/sys/vm/drop_caches; echo OK"
        run_sh_capture "dd read secuencial 1M*1024 (iflag=direct)" \
            "dd if='$TMP' of=/dev/null bs=1M count=1024 iflag=direct 2>&1"
        rm -f -- "$TMP"
    fi
}

# ---------------------------------------------------------------------------
# pveperf
# ---------------------------------------------------------------------------
bench_pveperf() {
    section "pveperf (CPU + HD seek + fsync + DNS)"
    if ! have pveperf; then
        w "_pveperf no disponible — ¿estás en un nodo Proxmox?_"; return
    fi
    run_capture "pveperf en /"          pveperf /
    if [[ -d /var/lib/vz ]]; then
        run_capture "pveperf en /var/lib/vz" pveperf /var/lib/vz
    fi
    # un pveperf sobre cada storage tipo dir/zfs montado
    while IFS= read -r path; do
        [[ -z "$path" || "$path" == "/" || "$path" == "/var/lib/vz" ]] && continue
        run_capture "pveperf en $path" pveperf "$path"
    done < <(awk '/^(dir|zfspool|cifs|nfs):/{getline l; while(l ~ /^\s/){if(l ~ /path/){print $NF}; getline l}}' /etc/pve/storage.cfg 2>/dev/null \
              | awk '{print $NF}' | sort -u)
}

# ---------------------------------------------------------------------------
# Red
# ---------------------------------------------------------------------------
bench_net_server() {
    section "Red (servidor iperf3)"
    if ! ensure_pkg iperf3; then
        w "_iperf3 no disponible (apt install iperf3 o --install)._"; return
    fi
    log "Iniciando iperf3 servidor en :${PORT}. Ctrl-C para detener."
    w "Servidor iperf3 escuchando en \`:${PORT}\` durante esta ejecución. Lanza desde otro nodo:"
    w '```'
    w "iperf3 -c $(hostname -I | awk '{print $1}') -p ${PORT} -t 30"
    w '```'
    blank
    iperf3 -s -p "$PORT"
}

bench_net_client() {
    section "Red (cliente iperf3 → ${TARGET})"
    if [[ -z "$TARGET" ]]; then
        w "_Falta --target HOST[:PUERTO]._"; return
    fi
    if ! ensure_pkg iperf3; then
        w "_iperf3 no disponible._"; return
    fi
    local host port
    host="${TARGET%%:*}"
    port="${TARGET##*:}"; [[ "$host" == "$port" ]] && port="$PORT"
    run_capture "iperf3 TCP 30s" iperf3 -c "$host" -p "$port" -t 30
    run_capture "iperf3 TCP 30s reverso (-R)" iperf3 -c "$host" -p "$port" -t 30 -R
    run_capture "iperf3 TCP paralelo -P 4" iperf3 -c "$host" -p "$port" -t 20 -P 4
    run_capture "iperf3 UDP 1G/s 20s" iperf3 -c "$host" -p "$port" -t 20 -u -b 1G
}

# ---------------------------------------------------------------------------
# Red entre VMs (vía qemu-guest-agent + iperf3 dentro de la VM)
# ---------------------------------------------------------------------------
bench_vm_net() {
    section "Red entre VMs (${VM_A} ↔ ${VM_B})"
    if [[ -z "$VM_A" || -z "$VM_B" ]]; then
        w "_Faltan --vm-a ID y --vm-b ID._"; return
    fi
    if ! have qm; then w "_qm no disponible — ¿es un nodo Proxmox?_"; return; fi

    w "Requisitos en cada VM:"
    w "- \`qemu-guest-agent\` instalado y \`agent: 1\` en su configuración PVE."
    w "- \`iperf3\` instalado dentro del invitado."
    blank

    local IPB
    IPB=$(qm guest cmd "$VM_B" network-get-interfaces 2>/dev/null \
        | sed -n 's/.*"ip-address" *: *"\([0-9.]\+\)".*/\1/p' \
        | grep -v '^127\.' | head -1)
    if [[ -z "$IPB" ]]; then
        w "_No he podido obtener IP de la VM ${VM_B} (¿agente activo?). Pasa la IP manualmente con --target en net-client._"
        return
    fi
    w "**IP detectada de la VM ${VM_B}:** \`${IPB}\`"
    blank

    log "Lanzando iperf3 -s en VM ${VM_B} ..."
    qm guest exec "$VM_B" -- /bin/sh -c "iperf3 -s -D -p ${PORT} >/tmp/iperf3.log 2>&1 || true" >/dev/null 2>&1
    sleep 2
    run_capture "VM ${VM_A} → VM ${VM_B} TCP 30s" \
        qm guest exec "$VM_A" -- iperf3 -c "$IPB" -p "$PORT" -t 30
    run_capture "VM ${VM_A} → VM ${VM_B} TCP -R 20s" \
        qm guest exec "$VM_A" -- iperf3 -c "$IPB" -p "$PORT" -t 20 -R
    log "Parando iperf3 en VM ${VM_B} ..."
    qm guest exec "$VM_B" -- /bin/sh -c "pkill -f 'iperf3 -s' || true" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
for t in "${TESTS[@]}"; do
    case "$t" in
        cpu)        bench_cpu ;;
        mem)        bench_mem ;;
        disk)       bench_disk ;;
        pveperf)    bench_pveperf ;;
        net-server) bench_net_server ;;
        net-client) bench_net_client ;;
        vm-net)     bench_vm_net ;;
    esac
done

# ---------------------------------------------------------------------------
# Cierre
# ---------------------------------------------------------------------------
section "Estado del sistema tras los tests"
run_capture "uptime / load" uptime
run_capture "Memoria" free -h
run_capture "dmesg recientes" bash -c "dmesg --level=err,warn 2>/dev/null | tail -30"

blank
w "---"
w "_Generado por bench-proxmox.sh v${VERSION} en $(date -Iseconds)_"

SIZE=$(du -h "$OUTPUT" 2>/dev/null | awk '{print $1}')
log "Listo: $OUTPUT ($SIZE)"
log ""
log "Para descargarlo:"
log "  A) scp root@<NODO>:${OUTPUT} ./"
log "  B) bash <(curl -fsSL https://raw.githubusercontent.com/KaleltYT/Auditoria-Proxmox/main/bench-proxmox.sh) --serve 8765"
log "  C) Copy/paste base64 (recomendado si --serve está bloqueado por firewall):"
log "       bash <(curl -fsSL https://raw.githubusercontent.com/KaleltYT/Auditoria-Proxmox/main/bench-proxmox.sh) --print-base64 '${OUTPUT}'"
log "     En local: echo 'PEGA_AQUI' | base64 -d | gunzip > bench.md"
log ""
log "Limpieza posterior:"
log "  bash <(curl -fsSL https://raw.githubusercontent.com/KaleltYT/Auditoria-Proxmox/main/bench-proxmox.sh) --cleanup '${OUTPUT}'"

if [[ $SERVE -eq 1 ]]; then
    serve_report "$OUTPUT" "$SERVE_PORT"
fi
