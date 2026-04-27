#!/usr/bin/env bash
# auditoria-proxmox.sh
# Auditoría completa de un nodo Proxmox VE (standalone o en clúster).
# Genera un informe Markdown listo para descargar y analizar en local.
#
# Uso rápido (en la shell del nodo Proxmox, como root):
#   bash <(curl -fsSL https://raw.githubusercontent.com/KaleltYT/Auditoria-Proxmox/main/auditoria-proxmox.sh)
#
# Opciones:
#   -o, --output FILE   Ruta del informe (por defecto /root/proxmox-audit-<host>-<fecha>.md)
#       --no-smart      Omite los tests SMART de discos (más rápido)
#       --quick         Modo rápido: omite SMART, logs largos y dmidecode de memoria
#   -h, --help          Muestra esta ayuda

set -u
# No usamos set -e: queremos continuar aunque algún comando falle.
umask 077

VERSION="1.0.0"
START_TS=$(date +%s)
HOSTNAME_SHORT=$(hostname -s 2>/dev/null || hostname)
TODAY=$(date +%Y-%m-%d_%H%M%S)
DEFAULT_OUT="/root/proxmox-audit-${HOSTNAME_SHORT}-${TODAY}.md"
OUTPUT="$DEFAULT_OUT"
DO_SMART=1
QUICK=0

usage() {
    sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--output) OUTPUT="${2:-}"; shift 2 ;;
        --no-smart)  DO_SMART=0; shift ;;
        --quick)     QUICK=1; DO_SMART=0; shift ;;
        -h|--help)   usage 0 ;;
        *) echo "Opción desconocida: $1" >&2; usage 1 ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Este script debe ejecutarse como root." >&2
    exit 1
fi

OUT_DIR=$(dirname -- "$OUTPUT")
if ! mkdir -p -- "$OUT_DIR" 2>/dev/null; then
    echo "ERROR: No puedo crear el directorio de salida: $OUT_DIR" >&2
    exit 1
fi
: > "$OUTPUT" || { echo "ERROR: No puedo escribir en $OUTPUT" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Helpers de salida
# ---------------------------------------------------------------------------
log()      { printf '[auditoria] %s\n' "$*" >&2; }
w()        { printf '%s\n' "$*" >> "$OUTPUT"; }
wn()       { printf '%s'   "$*" >> "$OUTPUT"; }
blank()    { printf '\n'         >> "$OUTPUT"; }

section()    { blank; w "## $*"; blank; }
subsection() { blank; w "### $*"; blank; }

have() { command -v "$1" >/dev/null 2>&1; }

# run "Descripción" cmd args...
# Captura stdout+stderr en un bloque de código markdown.
run() {
    local desc="$1"; shift
    w "**${desc}**"
    w ''
    w '```'
    if have "$1"; then
        "$@" 2>&1 || w "(comando devolvió código $?)"
    else
        w "(comando no disponible: $1)"
    fi
    w '```'
    blank
}

# run_sh "Descripción" "comando con pipes"
run_sh() {
    local desc="$1"; shift
    w "**${desc}**"
    w ''
    w '```'
    bash -c "$*" 2>&1 || w "(comando devolvió código $?)"
    w '```'
    blank
}

# paste_file "Etiqueta" /ruta/al/fichero  [lenguaje]
paste_file() {
    local label="$1" path="$2" lang="${3:-}"
    w "**${label}** — \`${path}\`"
    w ''
    if [[ -e "$path" ]]; then
        if [[ -d "$path" ]]; then
            w '```'
            ls -la --time-style=long-iso -- "$path" 2>&1
            w '```'
        else
            w "\`\`\`${lang}"
            # Limita a 2000 líneas para evitar informes gigantes.
            sed -n '1,2000p' -- "$path" 2>&1
            w '```'
        fi
    else
        w '_no existe_'
    fi
    blank
}

# ---------------------------------------------------------------------------
# Cabecera del informe
# ---------------------------------------------------------------------------
log "Generando informe en $OUTPUT"

PVE_VERSION=$(pveversion 2>/dev/null | head -n1 || echo 'no detectado')

w "# Auditoría Proxmox VE — ${HOSTNAME_SHORT}"
blank
w "- **Fecha:** $(date -Iseconds)"
w "- **Host:** $(hostname -f 2>/dev/null || hostname)"
w "- **Proxmox:** ${PVE_VERSION}"
w "- **Kernel:** $(uname -r)"
w "- **Generado por:** auditoria-proxmox.sh v${VERSION}"
w "- **Modo:** $([[ $QUICK -eq 1 ]] && echo 'rápido' || echo 'completo')"
blank
w "> Este informe contiene información sensible (configuración de red, usuarios, ACLs)."
w "> Manéjalo con cuidado: cifrado en tránsito y en reposo, y bórralo del nodo cuando no haga falta."
blank
w "---"

# ---------------------------------------------------------------------------
# 1. Sistema operativo y host
# ---------------------------------------------------------------------------
section "1. Sistema operativo y host"

run "Información del host (hostnamectl)"            hostnamectl
run "uname -a"                                       uname -a
paste_file "/etc/os-release" /etc/os-release ini
run "Uptime y carga"                                 uptime
run "Fecha y zona horaria (timedatectl)"             timedatectl
run "Variables de entorno relevantes"                bash -c 'env | grep -Ei "^(LANG|LC_|TZ|PATH)=" | sort'
run "Locale"                                         locale

# ---------------------------------------------------------------------------
# 2. Proxmox VE: versión, repositorios y suscripción
# ---------------------------------------------------------------------------
section "2. Proxmox VE — versión, repositorios y suscripción"

run "pveversion -v (paquetes PVE)"                   pveversion -v
run "Suscripción (pvesubscription get)"              pvesubscription get
run "Estado del clúster (resumen)"                   pvesh get /cluster/status --output-format=json

subsection "2.1 Repositorios APT"
paste_file "/etc/apt/sources.list" /etc/apt/sources.list
if [[ -d /etc/apt/sources.list.d ]]; then
    while IFS= read -r f; do
        paste_file "Repositorio adicional" "$f"
    done < <(find /etc/apt/sources.list.d -maxdepth 1 -type f \( -name '*.list' -o -name '*.sources' \) | sort)
fi
run "Lista de paquetes pve* instalados"              bash -c "dpkg -l | awk '/^ii/ && /pve|proxmox/ {print \$2, \$3}' | sort"

# ---------------------------------------------------------------------------
# 3. Hardware
# ---------------------------------------------------------------------------
section "3. Hardware"

run "CPU (lscpu)"                                    lscpu
run "Topología CPU (lscpu -e)"                       lscpu -e
run "Memoria (free -h)"                              free -h
run "Bancos de memoria instalados"                   bash -c "dmidecode -t memory 2>/dev/null | awk '/Memory Device|Size:|Type:|Speed:|Manufacturer:|Part Number:|Locator:/'"

subsection "3.1 BIOS / Placa base / Chasis"
run "BIOS"                                           dmidecode -t bios
run "System (fabricante/modelo/serie)"               dmidecode -t system
run "Baseboard (placa base)"                         dmidecode -t baseboard
run "Chasis"                                         dmidecode -t chassis
run "Procesador (DMI)"                               dmidecode -t processor
if [[ $QUICK -eq 0 ]]; then
    run "Memoria (DMI completo)"                     dmidecode -t memory
fi

subsection "3.2 PCI / USB"
run "PCI (lspci -nnk)"                               lspci -nnk
run "USB (lsusb)"                                    lsusb

subsection "3.3 IPMI / sensores"
run "Sensores hardware (sensors)"                    sensors
run "IPMI fru (si existe)"                           ipmitool fru
run "IPMI lan print"                                 ipmitool lan print

# ---------------------------------------------------------------------------
# 4. Almacenamiento
# ---------------------------------------------------------------------------
section "4. Almacenamiento"

subsection "4.1 Discos físicos"
run "lsblk (árbol de bloques)"                       lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL,SERIAL,ROTA,DISC-GRAN,WWN
run "blkid (UUIDs/etiquetas)"                        blkid
run "df -h"                                          df -hT
run "Particiones (cat /proc/partitions)"             cat /proc/partitions

if have nvme; then
    run "NVMe list"                                  nvme list
fi

if [[ $DO_SMART -eq 1 ]] && have smartctl; then
    subsection "4.2 SMART por disco"
    while IFS= read -r dev; do
        [[ -z "$dev" ]] && continue
        run "SMART de $dev"                          smartctl -a -- "$dev"
    done < <(smartctl --scan 2>/dev/null | awk '{print $1}')
fi

subsection "4.3 LVM"
run "Volúmenes físicos (pvs)"                        pvs -o +pv_used,pv_free
run "Grupos de volúmenes (vgs)"                      vgs
run "Volúmenes lógicos (lvs)"                        lvs -a -o +lv_layout,stripes,segtype,lv_attr,data_percent,metadata_percent
run "Detalle PVs (pvdisplay)"                        pvdisplay
run "Detalle LVs (lvdisplay)"                        lvdisplay

subsection "4.4 ZFS"
run "zpool list"                                     zpool list
run "zpool status -v"                                zpool status -v
run "zfs list -t all -o name,used,available,refer,mountpoint,compression,dedup,encryption" \
                                                    zfs list -t all -o name,used,available,refer,mountpoint,compression,dedup,encryption
run "Propiedades de pools"                           bash -c 'for p in $(zpool list -H -o name 2>/dev/null); do echo "=== $p ==="; zpool get all "$p"; done'
run "ARC stats (si ZFS)"                             bash -c "[ -r /proc/spl/kstat/zfs/arcstats ] && awk 'NR<=20' /proc/spl/kstat/zfs/arcstats || echo 'sin ZFS'"

subsection "4.5 Ceph"
run "ceph -s"                                        ceph -s
run "ceph osd tree"                                  ceph osd tree
run "ceph df"                                        ceph df
run "ceph osd df"                                    ceph osd df
paste_file "Configuración Ceph del clúster" /etc/pve/ceph.conf ini
paste_file "Configuración Ceph local"        /etc/ceph/ceph.conf ini

subsection "4.6 Almacenamiento de Proxmox"
run "pvesm status"                                   pvesm status
paste_file "/etc/pve/storage.cfg" /etc/pve/storage.cfg
run "Detalle de cada storage (pvesh)"                pvesh get /storage --output-format=json
run "Montajes"                                       findmnt -A
run "Entradas de fstab"                              cat /etc/fstab

# ---------------------------------------------------------------------------
# 5. Red
# ---------------------------------------------------------------------------
section "5. Red"

run "Interfaces (ip -br link)"                       ip -br link
run "Direcciones (ip -br addr)"                      ip -br addr
run "Tabla de rutas IPv4"                            ip route
run "Tabla de rutas IPv6"                            ip -6 route
run "Vecinos (ARP/NDP)"                              ip neigh
run "Bridges (bridge link)"                          bridge link
run "Bridges (bridge vlan)"                          bridge vlan
run "Bonds activos"                                  bash -c 'for b in /proc/net/bonding/*; do [ -f "$b" ] && echo "=== $b ===" && cat "$b"; done'
paste_file "/etc/network/interfaces" /etc/network/interfaces
if [[ -d /etc/network/interfaces.d ]]; then
    while IFS= read -r f; do
        paste_file "interfaces.d" "$f"
    done < <(find /etc/network/interfaces.d -maxdepth 1 -type f | sort)
fi
paste_file "/etc/hosts" /etc/hosts
paste_file "/etc/resolv.conf" /etc/resolv.conf

subsection "5.1 ethtool por interfaz física"
while IFS= read -r ifc; do
    [[ -z "$ifc" ]] && continue
    [[ "$ifc" == lo ]] && continue
    [[ "$ifc" == vmbr* || "$ifc" == tap* || "$ifc" == fwbr* || "$ifc" == fwln* || "$ifc" == fwpr* || "$ifc" == veth* || "$ifc" == bond* ]] && continue
    run "ethtool $ifc"                               ethtool "$ifc"
    run "ethtool -i $ifc (driver)"                   ethtool -i "$ifc"
    run "ethtool -k $ifc (offloads)"                 ethtool -k "$ifc"
done < <(ls /sys/class/net 2>/dev/null)

subsection "5.2 Sysctl de red y kernel"
run "Parámetros de red/VM relevantes"                bash -c '
sysctl -a 2>/dev/null | grep -E "^(net\.ipv4\.ip_forward|net\.ipv4\.conf\.all\.rp_filter|net\.bridge\.bridge-nf-call-iptables|net\.bridge\.bridge-nf-call-ip6tables|net\.core\.(rmem|wmem|netdev_max)|net\.ipv4\.tcp_(congestion_control|fastopen|sack|window_scaling)|vm\.swappiness|vm\.overcommit_memory|vm\.dirty_ratio|vm\.dirty_background_ratio|kernel\.numa_balancing|kernel\.sched_)" | sort
'

# ---------------------------------------------------------------------------
# 6. Firewall
# ---------------------------------------------------------------------------
section "6. Firewall"

run "Estado pve-firewall"                            pve-firewall status
run "Compilado pve-firewall (rules)"                 pve-firewall compile
paste_file "Firewall: cluster.fw" /etc/pve/firewall/cluster.fw
if [[ -d /etc/pve/firewall ]]; then
    while IFS= read -r f; do
        paste_file "Firewall config" "$f"
    done < <(find /etc/pve/firewall -maxdepth 1 -type f | sort)
fi
if have nft; then
    run "nft list ruleset"                           nft list ruleset
else
    run "iptables -S"                                iptables -S
    run "ip6tables -S"                               ip6tables -S
fi

# ---------------------------------------------------------------------------
# 7. Clúster Proxmox
# ---------------------------------------------------------------------------
section "7. Clúster Proxmox"

run "pvecm status"                                   pvecm status
run "pvecm nodes"                                    pvecm nodes
paste_file "/etc/pve/corosync.conf" /etc/pve/corosync.conf
paste_file "/etc/corosync/corosync.conf" /etc/corosync/corosync.conf
run "corosync-quorumtool -ls"                        corosync-quorumtool -ls
run "corosync-cfgtool -s"                            corosync-cfgtool -s

# ---------------------------------------------------------------------------
# 8. Máquinas virtuales (QEMU)
# ---------------------------------------------------------------------------
section "8. Máquinas virtuales (QEMU)"

run "qm list"                                        qm list

if have qm; then
    while IFS= read -r vmid; do
        [[ -z "$vmid" ]] && continue
        subsection "VM ${vmid}"
        run "qm config ${vmid}"                      qm config "$vmid"
        run "qm status ${vmid} --verbose"            qm status "$vmid" --verbose
        run "qm pending ${vmid} (cambios pendientes)" qm pending "$vmid"
    done < <(qm list 2>/dev/null | awk 'NR>1 {print $1}')
fi

# ---------------------------------------------------------------------------
# 9. Contenedores LXC
# ---------------------------------------------------------------------------
section "9. Contenedores LXC"

run "pct list"                                       pct list

if have pct; then
    while IFS= read -r ctid; do
        [[ -z "$ctid" ]] && continue
        subsection "CT ${ctid}"
        run "pct config ${ctid}"                     pct config "$ctid"
        run "pct status ${ctid}"                     pct status "$ctid"
    done < <(pct list 2>/dev/null | awk 'NR>1 {print $1}')
fi

# ---------------------------------------------------------------------------
# 10. Backups y replicación
# ---------------------------------------------------------------------------
section "10. Backups y replicación"

paste_file "Tareas de backup (jobs.cfg)" /etc/pve/jobs.cfg
paste_file "/etc/vzdump.conf" /etc/vzdump.conf
run "Tareas programadas de backup"                   pvesh get /cluster/backup --output-format=json
run "Estado de replicación (pvesr status)"           pvesr status
run "Definiciones de replicación"                    pvesr list

subsection "10.1 Proxmox Backup Server (si configurado)"
run "Storages tipo PBS"                              bash -c "grep -E 'pbs|type:.*pbs' /etc/pve/storage.cfg 2>/dev/null || echo '(sin PBS)'"

# ---------------------------------------------------------------------------
# 11. Alta disponibilidad
# ---------------------------------------------------------------------------
section "11. Alta disponibilidad (HA)"

run "ha-manager status"                              ha-manager status
run "Recursos HA"                                    ha-manager config
if [[ -d /etc/pve/ha ]]; then
    while IFS= read -r f; do
        paste_file "HA" "$f"
    done < <(find /etc/pve/ha -maxdepth 1 -type f 2>/dev/null | sort)
fi

# ---------------------------------------------------------------------------
# 12. Usuarios, permisos y autenticación
# ---------------------------------------------------------------------------
section "12. Usuarios, permisos y autenticación"

run "pveum user list"                                pveum user list
run "pveum group list"                               pveum group list
run "pveum role list"                                pveum role list
run "pveum acl list"                                 pveum acl list
paste_file "/etc/pve/user.cfg" /etc/pve/user.cfg
paste_file "/etc/pve/domains.cfg" /etc/pve/domains.cfg
run "Usuarios locales con shell"                     bash -c "awk -F: '\$7 !~ /(nologin|false)\$/ {print \$1, \$3, \$6, \$7}' /etc/passwd"
run "Grupo sudo"                                     bash -c "getent group sudo; getent group wheel 2>/dev/null"
paste_file "/etc/sudoers" /etc/sudoers
if [[ -d /etc/sudoers.d ]]; then
    while IFS= read -r f; do paste_file "sudoers.d" "$f"; done \
        < <(find /etc/sudoers.d -maxdepth 1 -type f ! -name 'README' | sort)
fi

# ---------------------------------------------------------------------------
# 13. SSH y acceso remoto
# ---------------------------------------------------------------------------
section "13. SSH y acceso remoto"

run "Configuración efectiva de sshd (sshd -T)"       bash -c "sshd -T 2>/dev/null | sort"
paste_file "/etc/ssh/sshd_config" /etc/ssh/sshd_config
if [[ -d /etc/ssh/sshd_config.d ]]; then
    while IFS= read -r f; do paste_file "sshd_config.d" "$f"; done \
        < <(find /etc/ssh/sshd_config.d -maxdepth 1 -type f | sort)
fi
run "Puertos en escucha"                             ss -tulpn

# ---------------------------------------------------------------------------
# 14. Servicios y actualizaciones
# ---------------------------------------------------------------------------
section "14. Servicios y actualizaciones"

run "Servicios PVE clave"                            bash -c '
for s in pve-cluster pveproxy pvedaemon pvestatd pve-firewall pvescheduler pve-ha-crm pve-ha-lrm corosync chrony systemd-timesyncd ssh sshd ksmtuned; do
    state=$(systemctl is-active "$s" 2>/dev/null)
    enab=$(systemctl is-enabled "$s" 2>/dev/null)
    [ -n "$state" ] && printf "%-20s active=%-10s enabled=%s\n" "$s" "$state" "$enab"
done'
run "Servicios fallidos"                             systemctl --failed --no-legend
run "Top de servicios por uso de memoria"            bash -c "systemd-cgtop -n1 -m --depth=2 2>/dev/null | head -30"
run "Paquetes con actualización pendiente"           bash -c "apt list --upgradable 2>/dev/null | sed 's/Listing\\.\\.\\.//'"
run "Historial APT (últimas 20 entradas)"            bash -c "ls -1t /var/log/apt/history.log* 2>/dev/null | head -3 | xargs -r zcat -f 2>/dev/null | tail -200"
run "Paquetes manualmente instalados (top 80)"       bash -c "apt-mark showmanual 2>/dev/null | head -80"

# ---------------------------------------------------------------------------
# 15. Tiempo y NTP
# ---------------------------------------------------------------------------
section "15. Sincronización horaria"

run "timedatectl"                                    timedatectl
run "chronyc sources -v"                             chronyc sources -v
run "chronyc tracking"                               chronyc tracking
run "systemd-timesyncd status"                       bash -c "systemctl status systemd-timesyncd --no-pager 2>&1 | head -20"

# ---------------------------------------------------------------------------
# 16. Kernel, CPU y rendimiento
# ---------------------------------------------------------------------------
section "16. Kernel, CPU y rendimiento"

run "Línea de comandos del kernel"                   cat /proc/cmdline
run "Módulos cargados (top 60)"                      bash -c "lsmod | head -60"
run "Governor de CPU (resumen)"                      bash -c "
for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do [ -r \"\$f\" ] && cat \"\$f\"; done | sort -u
"
run "Frecuencia actual por núcleo"                   bash -c "
paste <(ls -d /sys/devices/system/cpu/cpu[0-9]* 2>/dev/null) \
      <(for f in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq; do cat \"\$f\" 2>/dev/null; done) | head -32
"
run "Mitigaciones del CPU"                           bash -c "grep -H . /sys/devices/system/cpu/vulnerabilities/* 2>/dev/null | sed 's|/sys/devices/system/cpu/vulnerabilities/||'"
run "NUMA"                                           bash -c "have() { command -v \"\$1\" >/dev/null; }; if have numactl; then numactl --hardware; else echo '(numactl no instalado)'; fi"
run "Hugepages"                                      bash -c "grep -E 'Huge|Anonymous' /proc/meminfo; echo; grep . /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null"
run "KSM (Kernel Same-page Merging)"                 bash -c "for f in /sys/kernel/mm/ksm/*; do [ -f \"\$f\" ] && printf '%-32s %s\n' \"\$(basename \"\$f\")\" \"\$(cat \"\$f\")\"; done"
run "IOMMU activo"                                   bash -c "dmesg 2>/dev/null | grep -iE 'iommu|dmar|amd-vi' | head -20; echo; ls /sys/kernel/iommu_groups 2>/dev/null | wc -l | awk '{print \$1\" grupos IOMMU\"}'"
run "Snapshot vmstat (5 muestras)"                   vmstat 1 5
run "Top procesos (CPU)"                             bash -c "ps -eo pid,pcpu,pmem,vsz,rss,comm --sort=-pcpu | head -20"
run "Top procesos (memoria)"                         bash -c "ps -eo pid,pcpu,pmem,vsz,rss,comm --sort=-rss | head -20"
run "iostat (si está)"                               bash -c "iostat -xz 1 3 2>/dev/null || echo '(iostat no disponible — paquete sysstat)'"

# ---------------------------------------------------------------------------
# 17. Logs recientes
# ---------------------------------------------------------------------------
if [[ $QUICK -eq 0 ]]; then
section "17. Logs recientes"

run "journalctl -p err (últimos 7 días, máx 200 líneas)" bash -c "journalctl -p err --since '7 days ago' --no-pager 2>/dev/null | tail -200"
run "journalctl -u pve-cluster (últimas 80)"          bash -c "journalctl -u pve-cluster --no-pager 2>/dev/null | tail -80"
run "journalctl -u pveproxy (últimas 80)"             bash -c "journalctl -u pveproxy --no-pager 2>/dev/null | tail -80"
run "journalctl -u corosync (últimas 80)"             bash -c "journalctl -u corosync --no-pager 2>/dev/null | tail -80"
run "dmesg con errores y warnings"                    bash -c "dmesg --level=err,warn 2>/dev/null | tail -120"
run "Últimos reinicios"                               bash -c "last -x reboot shutdown 2>/dev/null | head -20"
fi

# ---------------------------------------------------------------------------
# 18. Recomendaciones automáticas (heurísticas)
# ---------------------------------------------------------------------------
section "18. Recomendaciones automáticas (revisión heurística)"

w "_Estas recomendaciones se generan automáticamente y pueden no aplicar a tu caso. Revísalas críticamente._"
blank

REC=()
add_rec() { REC+=("$1"); }

# Suscripción + repo enterprise
if grep -RhsE '^[[:space:]]*deb[[:space:]]+https?://enterprise\.proxmox\.com' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null | grep -q .; then
    if ! pvesubscription get 2>/dev/null | grep -q 'status: *active'; then
        add_rec "El repositorio **enterprise** está activo pero la suscripción no figura como **active**. Cambia al repo *no-subscription* o activa la suscripción para evitar fallos en \`apt update\`."
    fi
fi

# Repo no-subscription
if grep -RhsE 'pve-no-subscription' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null | grep -q .; then
    add_rec "Estás usando el repositorio **pve-no-subscription** (válido para test/lab; no recomendado en producción crítica)."
fi

# Swappiness
SW=$(sysctl -n vm.swappiness 2>/dev/null || echo "")
if [[ -n "$SW" && "$SW" -gt 10 ]]; then
    add_rec "\`vm.swappiness=$SW\` es alto para un hipervisor. Considera bajarlo a **10** (o menor con ZFS): \`echo 'vm.swappiness=10' >/etc/sysctl.d/99-pve.conf && sysctl --system\`."
fi

# Governor
GOV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || true)
if [[ -n "$GOV" && "$GOV" != "performance" ]]; then
    add_rec "El CPU governor es **$GOV**. Para hipervisores con cargas estables suele recomendarse **performance** (paquete \`cpufrequtils\`)."
fi

# Mitigaciones On
if grep -lE '(Vulnerable|Mitigation)' /sys/devices/system/cpu/vulnerabilities/* 2>/dev/null | grep -q .; then
    add_rec "Hay **mitigaciones de CPU activas**. Revisa el coste de rendimiento y, si tu entorno lo permite, evalúa ajustes (\`mitigations=\` en cmdline) — sólo con conocimiento del riesgo."
fi

# IOMMU
if ! dmesg 2>/dev/null | grep -qiE 'iommu|dmar|amd-vi'; then
    add_rec "**IOMMU no parece activo**. Si planeas PCI passthrough (GPUs, NICs SR-IOV…), habilítalo en BIOS y añade \`intel_iommu=on\` o \`amd_iommu=on\` al cmdline del kernel."
fi

# THP
THP=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null | grep -oE '\[[a-z]+\]' | tr -d '[]')
if [[ "$THP" == "always" ]]; then
    add_rec "**Transparent Hugepages** están en \`always\`. Para KVM suele ir bien, pero con ZFS puede causar latencias; valora \`madvise\`."
fi

# ZFS ARC sin límite
if [[ -r /sys/module/zfs/parameters/zfs_arc_max ]]; then
    ARC=$(cat /sys/module/zfs/parameters/zfs_arc_max)
    if [[ "$ARC" == "0" ]] && zpool list -H 2>/dev/null | grep -q .; then
        add_rec "ZFS está en uso pero **\`zfs_arc_max\` no está limitado**. En hipervisores conviene fijarlo (p. ej. al 25% de la RAM) en \`/etc/modprobe.d/zfs.conf\` para no competir con las VMs."
    fi
fi

# VMs sin qemu-guest-agent
if have qm; then
    BAD_AGENT=()
    while IFS= read -r vmid; do
        [[ -z "$vmid" ]] && continue
        if ! qm config "$vmid" 2>/dev/null | grep -qE '^agent: *1'; then
            BAD_AGENT+=("$vmid")
        fi
    done < <(qm list 2>/dev/null | awk 'NR>1 {print $1}')
    if [[ ${#BAD_AGENT[@]} -gt 0 ]]; then
        add_rec "VMs sin **qemu-guest-agent** habilitado: ${BAD_AGENT[*]}. Habilítalo (\`agent: 1\`) e instala el agente en el invitado para mejores backups y \`qm shutdown\`."
    fi
fi

# VMs con CPU type=kvm64 (genérico)
if have qm; then
    GEN_CPU=()
    while IFS= read -r vmid; do
        [[ -z "$vmid" ]] && continue
        if qm config "$vmid" 2>/dev/null | grep -qE '^cpu:.*(kvm64|qemu64)'; then
            GEN_CPU+=("$vmid")
        fi
    done < <(qm list 2>/dev/null | awk 'NR>1 {print $1}')
    if [[ ${#GEN_CPU[@]} -gt 0 ]]; then
        add_rec "VMs con CPU genérico (kvm64/qemu64): ${GEN_CPU[*]}. Considera \`host\` o \`x86-64-v3/v4\` si no migras entre hardware distinto — mejora notable de rendimiento."
    fi
fi

# Backups configurados
if [[ ! -s /etc/pve/jobs.cfg ]]; then
    add_rec "**No hay tareas de backup** definidas en \`/etc/pve/jobs.cfg\`. Configura backups de VMs/CTs (idealmente a un Proxmox Backup Server)."
fi

# rpfilter en bridge
RPF=$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null || echo "")
if [[ -n "$RPF" && "$RPF" -ne 0 && "$RPF" -ne 2 ]]; then
    add_rec "\`net.ipv4.conf.all.rp_filter=$RPF\`. En hipervisores con bridges puede romper tráfico asimétrico; evalúa **2 (loose)**."
fi

if [[ ${#REC[@]} -eq 0 ]]; then
    w "- Sin avisos automáticos. Revisa el resto del informe manualmente para optimizaciones específicas."
else
    for r in "${REC[@]}"; do w "- $r"; done
fi

# ---------------------------------------------------------------------------
# Cierre
# ---------------------------------------------------------------------------
END_TS=$(date +%s)
ELAPSED=$(( END_TS - START_TS ))

blank
w "---"
w "_Auditoría generada en ${ELAPSED}s — $(date -Iseconds)_"

SIZE=$(du -h "$OUTPUT" 2>/dev/null | awk '{print $1}')
log "Listo: $OUTPUT ($SIZE, ${ELAPSED}s)"
log ""
log "Para descargarlo a tu equipo local, desde tu máquina ejecuta:"
log "    scp root@${HOSTNAME_SHORT}:${OUTPUT} ./"
log ""
log "Recuerda borrar el informe del nodo cuando termines:"
log "    shred -u ${OUTPUT}"
