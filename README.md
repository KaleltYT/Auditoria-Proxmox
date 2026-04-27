# Auditoría Proxmox VE

Script de auditoría exhaustiva para nodos **Proxmox VE** (standalone o en clúster).
Genera un informe **Markdown** listo para descargar y analizar en local con un editor o un LLM.

> Pensado para consultoría: lo lanzas en la shell del nodo, te llevas el `.md` a tu
> equipo y revisas configuración, VMs, red, almacenamiento, BIOS y rendimiento sin
> tener que volver a entrar al servidor. Incluye modo **`--serve`** para descargar
> por navegador desde la propia web shell de Proxmox y modo **`--cleanup`** para
> borrar después todo rastro.

## Qué incluye el informe

1. Sistema operativo y host.
2. Proxmox VE — versión, paquetes, suscripción, repositorios APT.
3. Hardware — CPU, RAM, BIOS y placa base vía `dmidecode`, PCI/USB, IPMI, sensores.
4. Almacenamiento — discos (`lsblk`, NVMe, **SMART**), LVM, **ZFS** (pools, ARC), **Ceph**, storages PVE.
5. Red — interfaces, rutas, bridges, bonds, ethtool por NIC, sysctl.
6. Firewall — `pve-firewall`, reglas compiladas, nft/iptables.
7. Clúster — `pvecm status`, corosync, quorum.
8. VMs (QEMU) — `qm config` y `qm status` de cada una.
9. Contenedores LXC.
10. Backups y replicación — `jobs.cfg`, `vzdump.conf`, `pvesr`.
11. Alta disponibilidad (HA).
12. Usuarios y permisos — pveum, ACLs, sudoers.
13. SSH — `sshd -T`, configs, puertos en escucha.
14. Servicios y actualizaciones — demonios PVE, `apt list --upgradable`, historial APT.
15. Sincronización horaria.
16. Kernel, CPU y rendimiento — governor, mitigaciones, NUMA, hugepages, KSM, IOMMU, vmstat.
17. Logs recientes — journalctl con errores, dmesg.
18. **Exposición pública** — servicios bind 0.0.0.0, IP pública, NAT vs IP directa, comprobación opcional desde Internet vía `check-host.net`.
19. Recomendaciones automáticas (heurísticas).

## Requisitos

- Acceso **root** en el nodo Proxmox.
- Distro: Proxmox VE 7/8 sobre Debian.
- Comandos opcionales (mejoran el informe): `dmidecode`, `smartctl`, `ipmitool`, `lm-sensors`, `ethtool`, `nvme-cli`, `numactl`, `sysstat`, `python3`.

## Uso

### Descargar y ejecutar en una línea

Desde la shell del nodo Proxmox (o desde la web shell `https://NODO:8006` → Datacenter → Nodo → `_Shell`):

```bash
# con curl (preinstalado en Proxmox VE 7/8 instalado desde el ISO oficial):
bash <(curl -fsSL https://raw.githubusercontent.com/KaleltYT/Auditoria-Proxmox/main/auditoria-proxmox.sh)

# alternativa con wget (también suele estar en PVE):
bash <(wget -qO- https://raw.githubusercontent.com/KaleltYT/Auditoria-Proxmox/main/auditoria-proxmox.sh)
```

Por defecto el informe se guarda en `/root/proxmox-audit-<host>-<fecha>.md`.

#### ¿Está `curl` instalado por defecto en Proxmox?

- **Proxmox VE 7/8 instalado desde el ISO oficial**: sí, `curl` y `wget` vienen preinstalados.
- **Proxmox sobre Debian minimal** (`apt install proxmox-ve` encima de un Debian netinst pelado): `wget` casi siempre está; `curl` puede faltar. Si falla, instálalo con `apt update && apt install -y curl`, o usa la alternativa con `wget` de arriba.
- Comprobarlo a mano: `command -v curl wget`.

### Opciones

```
-o, --output FILE     Ruta del informe
    --no-smart        Omite tests SMART (más rápido)
    --quick           Modo rápido: omite SMART, logs largos y dmidecode de memoria
    --check-public    Comprueba activamente si el GUI (8006) es accesible desde
                      Internet usando https://check-host.net
    --serve [PORT]    Tras auditar, sirve el informe por HTTP en PORT (def. 8765)
                      con un nombre aleatorio para descargarlo desde el navegador.
                      Ctrl-C detiene el servidor y borra la copia temporal.
    --cleanup [PATH]  No audita: borra rastros (informe, script, history, viminfo).
                      Si se pasa PATH, borra ese informe concreto; en cualquier
                      caso busca y borra /root/proxmox-audit-*.md y /tmp/...
-h, --help            Ayuda.
```

## Cómo descargar el informe a tu equipo local

### Opción A — SCP (si tienes SSH directo al nodo)

```bash
scp root@<IP_NODO>:/root/proxmox-audit-*.md ./
```

### Opción B — desde la web shell de Proxmox (sin SSH)

Estás conectado a `https://IP_PRIVADA:8006` y abres `_Shell` en el nodo.
Lanza el script con **`--serve`** después de auditar:

```bash
# Si ya hiciste la auditoría:
python3 -m http.server 8765 --bind 0.0.0.0 --directory /root
# o (recomendado, copia con nombre aleatorio temporal):
bash <(curl -fsSL https://raw.githubusercontent.com/KaleltYT/Auditoria-Proxmox/main/auditoria-proxmox.sh) --serve 8765
```

El propio script te imprimirá una URL del tipo:

```
http://192.168.X.Y:8765/AbCd1234EfGh.md
```

Ábrela en el navegador del mismo equipo que usas para conectar al GUI (la URL es alcanzable porque ya estás en la misma red que el `:8006`). El navegador descarga el `.md`. Pulsa **Ctrl-C** en la shell para parar el servidor; la copia temporal se borra automáticamente.

> Si tienes firewall delante que bloquea el 8765, elige otro puerto (`--serve 18006`) o usa la opción C.

### Opción C — copiar/pegar por la consola web (informes pequeños / sin red)

En la shell del nodo:

```bash
gzip -c /root/proxmox-audit-*.md | base64 -w0; echo
```

Selecciona toda la salida en el terminal web, cópiala y pégala en tu equipo en un archivo `audit.b64`. Luego:

```bash
base64 -d audit.b64 | gunzip > audit.md
```

## Detección de exposición pública

La sección **18** del informe te dice si el Proxmox al que te conectas por IP privada es alcanzable también desde Internet:

- Lista todos los puertos que escuchan en `0.0.0.0` / `::` (típicamente 8006, 22, 3128, 5404).
- Detecta la **IP pública saliente** y la compara con las IPs locales:
  - Si **coincide** → el nodo está directamente en Internet.
  - Si **no coincide** → está detrás de NAT; el acceso externo sólo funciona si hay port-forward.
- Con la opción **`--check-public`**, lanza una prueba activa contra `https://check-host.net` para verificar si el `:8006` realmente responde desde nodos externos en Europa/EEUU/Asia.

```bash
./auditoria-proxmox.sh --check-public
```

> `check-host.net` es un servicio público; al usarlo le revelas la IP del cliente. Si eso no encaja con tu acuerdo de confidencialidad, prueba la accesibilidad manualmente desde otra red: `nc -zv <IP_PUBLICA> 8006`.

## Borrado de rastros (`--cleanup`)

Cuando ya tengas el `.md` en local y quieras dejar el nodo limpio:

```bash
bash /root/auditoria-proxmox.sh --cleanup /root/proxmox-audit-<host>-<fecha>.md
# o, si descargaste el script en memoria:
bash <(curl -fsSL https://raw.githubusercontent.com/KaleltYT/Auditoria-Proxmox/main/auditoria-proxmox.sh) --cleanup
```

Qué borra:

- El informe `.md` (con `shred -u` si está disponible) y cualquier `proxmox-audit-*.md` en `/root` y `/tmp`.
- El propio script si está en disco (`/root/auditoria-proxmox.sh`, `/tmp/...`, `./...`).
- Entradas de `~/.bash_history` que mencionen `auditoria-proxmox`, `proxmox-audit` o el repo.
- Historial en memoria del shell actual (`history -c`).
- Artefactos típicos: `.viminfo`, `.lesshst`, `.python_history`, `.wget-hsts`.

Qué **no** borra a propósito:

- Logs del sistema (`journald`, `/var/log/*`). Modificarlos sería intrusivo y delatador. El script no escribe nada propio en esos logs (salvo lo que el kernel registre por accesos a dispositivos al leer SMART/`dmidecode`, que es indistinguible de actividad normal).

Para minimizar rastros desde el principio, el script ya:

- Pone `HISTFILE=/dev/null`, `HISTSIZE=0` antes de hacer nada → sus comandos internos no entran en el history.
- Crea el informe con `umask 077` (sólo legible por root).

> **Importante**: si lanzas el script con `bash <(curl ...)`, ese comando *sí* queda en tu historial del shell antes de que el script se ejecute. `--cleanup` lo elimina al final.

## Tiempos orientativos

- `--quick`: ~10–30 s.
- Modo completo sin SMART: ~30–90 s.
- Modo completo con SMART: depende del número de discos.

## Seguridad

- El script **sólo lee** información: no modifica configuración, no instala paquetes, no toca VMs.
- El informe contiene datos sensibles (red, ACLs, repos, claves públicas SSH). Trátalo como confidencial y bórralo del nodo cuando termines.

## Limitaciones conocidas

- BIOS/UEFI real no es accesible desde el SO; sólo lo expuesto por DMI (`dmidecode`).
- En clúster, audita el **nodo donde se ejecuta**. Repítelo en cada nodo.
- Los `paste_file` truncan ficheros a 2000 líneas.
- `--cleanup` no es anti-forense profesional: borra lo evidente, no es resistente a un análisis forense del disco.

## Licencia

MIT.
