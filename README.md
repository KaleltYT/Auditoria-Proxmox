# Auditoría Proxmox VE

Script de auditoría exhaustiva para nodos **Proxmox VE** (standalone o en clúster).
Genera un informe **Markdown** listo para descargar y analizar en local con un editor o un LLM.

> Pensado para consultoría: lo lanzas en la shell del nodo, te llevas el `.md` a tu
> equipo y revisas configuración, VMs, red, almacenamiento, BIOS y rendimiento sin
> tener que volver a entrar al servidor.

## Qué incluye el informe

1. **Sistema operativo y host** — `hostnamectl`, `uname`, `os-release`, uptime, locale.
2. **Proxmox VE** — versión, paquetes, suscripción, repositorios APT.
3. **Hardware** — CPU, RAM, BIOS y placa base vía `dmidecode`, PCI/USB, IPMI, sensores.
4. **Almacenamiento** — discos (`lsblk`, NVMe, **SMART**), LVM, **ZFS** (pools, ARC), **Ceph**, storages PVE, fstab.
5. **Red** — interfaces, rutas, bridges, bonds, `interfaces`, ethtool por NIC física, sysctl.
6. **Firewall** — `pve-firewall`, reglas compiladas, nft/iptables, configs de cluster/host.
7. **Clúster** — `pvecm status`, corosync, quorum.
8. **VMs (QEMU)** — listado, `qm config` y `qm status` de cada una.
9. **Contenedores LXC** — listado y configuración.
10. **Backups y replicación** — `jobs.cfg`, `vzdump.conf`, `pvesr`.
11. **Alta disponibilidad** — `ha-manager`, recursos.
12. **Usuarios y permisos** — pveum, ACLs, sudoers, usuarios locales con shell.
13. **SSH** — `sshd -T`, configs, puertos en escucha.
14. **Servicios y actualizaciones** — estado de demonios PVE, `apt list --upgradable`, historial APT.
15. **Sincronización horaria** — timedatectl, chrony, timesyncd.
16. **Kernel, CPU y rendimiento** — cmdline, governor, mitigaciones, NUMA, hugepages, KSM, IOMMU, vmstat, top, iostat.
17. **Logs recientes** — journalctl con errores, dmesg, reinicios.
18. **Recomendaciones automáticas** — heurísticas (swappiness, governor, agente QEMU, ZFS ARC, mitigaciones, IOMMU, backups…).

## Requisitos

- Acceso **root** (o vía `sudo -i`) en el nodo Proxmox.
- Distro: Proxmox VE 7/8 sobre Debian (también funciona en Debian puro, pero las secciones PVE quedarán vacías).
- Comandos opcionales (mejoran el informe pero no son obligatorios): `dmidecode`, `smartctl`, `ipmitool`, `lm-sensors`, `ethtool`, `nvme-cli`, `numactl`, `sysstat` (para `iostat`).

## Uso

### Opción A — descargar y ejecutar en una línea

Desde la shell del nodo Proxmox, como root:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/KaleltYT/Auditoria-Proxmox/main/auditoria-proxmox.sh)
```

Por defecto el informe se guarda en `/root/proxmox-audit-<host>-<fecha>.md`.

### Opción B — descargar primero, ejecutar después

```bash
curl -fsSL -o /root/auditoria-proxmox.sh \
    https://raw.githubusercontent.com/KaleltYT/Auditoria-Proxmox/main/auditoria-proxmox.sh
chmod +x /root/auditoria-proxmox.sh
/root/auditoria-proxmox.sh
```

### Opciones

```
-o, --output FILE   Ruta del informe (por defecto /root/proxmox-audit-<host>-<fecha>.md)
    --no-smart      Omite los tests SMART de discos (más rápido)
    --quick         Modo rápido: omite SMART, logs largos y dmidecode de memoria
-h, --help          Muestra la ayuda
```

Ejemplos:

```bash
# Informe en una ruta concreta
./auditoria-proxmox.sh -o /tmp/auditoria.md

# Modo rápido para una primera vista
./auditoria-proxmox.sh --quick

# Sin SMART (útil si los discos están detrás de RAID hardware)
./auditoria-proxmox.sh --no-smart
```

## Descargar el informe a tu equipo local

Desde **tu máquina** (no el nodo):

```bash
scp root@TU_NODO:/root/proxmox-audit-*.md ./
```

O con `rsync`:

```bash
rsync -avz root@TU_NODO:/root/proxmox-audit-*.md ./
```

## Higiene: borrar el informe del nodo

El informe incluye configuración sensible (red, ACLs, claves públicas, repos).
Cuando termines, bórralo del nodo:

```bash
shred -u /root/proxmox-audit-*.md
```

## Tiempos orientativos

- `--quick`: ~10–30 s.
- Modo completo sin SMART: ~30–90 s.
- Modo completo con SMART: depende del número de discos (cada `smartctl -a` puede tardar varios segundos).

## Seguridad

- El script **sólo lee** información. No modifica configuración, no instala paquetes, no toca VMs.
- Algunos comandos requieren root (`dmidecode`, `pveum`, `iptables`, etc.).
- El informe se crea con `umask 077` (sólo legible por root).

## Limitaciones conocidas

- La BIOS/firmware se audita vía DMI (`dmidecode`). Configuración real de UEFI/BIOS no es accesible desde el SO; para eso se necesita IPMI/Redfish o acceso físico.
- En clúster, el script audita **el nodo donde se ejecuta**. Para auditar todos los nodos, ejecútalo en cada uno.
- Los `paste_file` truncan ficheros a 2000 líneas para evitar informes gigantes.

## Licencia

MIT.
