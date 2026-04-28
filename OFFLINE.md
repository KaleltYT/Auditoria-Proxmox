# Sin acceso a Internet desde la shell de Proxmox

Si el nodo del cliente no llega a `raw.githubusercontent.com` (firewall, sin gateway, sin DNS, proxy corporativo…), aquí tienes:

1. **Diagnóstico rápido** copy-paste para localizar la causa.
2. **Soluciones** para los escenarios más comunes (con sus comandos).
3. **Cómo meter los scripts en el nodo sin Internet** (5 opciones, de más simple a más artesanal).

---

## 1. Diagnóstico rápido

Pega este bloque entero en la shell del nodo (web shell o SSH, como root). Te dice **qué falla exactamente**:

```bash
echo "=== Interfaces / IPs ==="; ip -br addr
echo; echo "=== Default route ==="; ip route | grep '^default' || echo '(SIN GATEWAY)'
echo; echo "=== DNS configurado ==="; grep -E '^(nameserver|search)' /etc/resolv.conf 2>/dev/null || echo '(SIN DNS)'
echo; echo "=== Ping al gateway ==="; GW=$(ip route | awk '/^default/ {print $3; exit}'); [ -n "$GW" ] && ping -c2 -W2 "$GW" || echo '(no hay gateway)'
echo; echo "=== Ping a 1.1.1.1 (capa 3 a Internet) ==="; ping -c2 -W2 1.1.1.1 || echo '(SIN salida a Internet)'
echo; echo "=== Resolución DNS ==="; getent hosts raw.githubusercontent.com || echo '(DNS no resuelve)'
echo; echo "=== HTTPS a GitHub (443) ==="; curl -sS -o /dev/null -w 'HTTP %{http_code} en %{time_total}s\n' --max-time 8 https://raw.githubusercontent.com/ || echo '(HTTPS bloqueado)'
echo; echo "=== Variables de proxy ==="; env | grep -iE '^(http|https|no)_proxy' || echo '(sin proxy en env)'
echo; echo "=== pve-firewall ==="; pve-firewall status 2>/dev/null
```

**Cómo interpretar el resultado** (mira la primera línea que falle):

| Síntoma | Causa probable | Ir a |
|---------|----------------|------|
| `SIN GATEWAY` o el ping al gateway falla | Falta default route o el gateway no responde | §2.1 |
| Ping a `1.1.1.1` falla pero al gateway responde | Firewall del cliente bloquea egress | §2.4 |
| `SIN DNS` o `DNS no resuelve` pero ping a 1.1.1.1 sí | Falta `/etc/resolv.conf` | §2.2 |
| HTTPS devuelve `000` o timeout pero hay DNS y ping | TLS/443 bloqueado o proxy obligatorio | §2.3 / §2.4 |
| `pve-firewall` está `enabled` y la regla por defecto bloquea | El propio firewall PVE está cerrado | §2.5 |

---

## 2. Soluciones por causa

### 2.1 No hay gateway / default route

Mira la red local y averigua la IP del router (suele ser `.1` o `.254` del subnet del nodo):

```bash
ip -br addr      # tu IP/máscara
ip route         # rutas actuales
```

Añade gateway temporal (no persiste tras reboot):

```bash
ip route add default via 192.168.1.1   # ajusta la IP
```

Para que persista, edita `/etc/network/interfaces` y añade `gateway X.X.X.X` en la sección de la interfaz/bridge correspondiente. Luego:

```bash
ifreload -a      # recarga sin tirar la red (Proxmox 7+)
# o, si no tienes ifreload:
systemctl restart networking
```

### 2.2 DNS sin configurar

`/etc/resolv.conf` debería contener al menos un `nameserver`:

```bash
cat > /etc/resolv.conf <<'EOF'
nameserver 1.1.1.1
nameserver 9.9.9.9
EOF
```

Si Proxmox lo regenera, configura el DNS desde el GUI: *Datacenter → Nodo → DNS* (o edita `/etc/network/interfaces` y `/etc/resolv.conf` y desactiva `systemd-resolved` si está sobrescribiendo).

Verifica:

```bash
getent hosts raw.githubusercontent.com
```

### 2.3 Detrás de proxy HTTP/HTTPS corporativo

Configura el proxy para esta sesión y para `apt`:

```bash
# Para esta shell:
export http_proxy=http://proxy.empresa.local:3128
export https_proxy=$http_proxy
export no_proxy=localhost,127.0.0.1,.local

# Probar:
curl -sS -o /dev/null -w 'HTTP %{http_code}\n' https://raw.githubusercontent.com/
```

Y luego ya puedes ejecutar el one-liner habitual (curl/wget heredan las variables):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/KaleltYT/Auditoria-Proxmox/main/auditoria-proxmox.sh)
```

Para que `apt update` también funcione con proxy:

```bash
echo 'Acquire::http::Proxy  "http://proxy.empresa.local:3128";' >  /etc/apt/apt.conf.d/95proxy
echo 'Acquire::https::Proxy "http://proxy.empresa.local:3128";' >> /etc/apt/apt.conf.d/95proxy
```

### 2.4 Firewall del cliente bloquea egress

Si la política de salida del firewall perimetral del cliente bloquea el 443 a Internet, no hay arreglo desde el nodo: pide que abran temporalmente `443/tcp` saliente a `raw.githubusercontent.com` y `objects.githubusercontent.com`, o usa **§3** para meter el script sin red.

Test rápido del 443 a un host concreto sin DNS:

```bash
# IP de raw.githubusercontent.com (puede cambiar; resolver desde tu equipo)
curl -sS --resolve raw.githubusercontent.com:443:185.199.108.133 \
     -o /dev/null -w 'HTTP %{http_code}\n' --max-time 8 \
     https://raw.githubusercontent.com/
```

### 2.5 `pve-firewall` está cerrando la salida

El firewall integrado de Proxmox suele venir desactivado por defecto, pero si está activo y con política restrictiva:

```bash
pve-firewall status                          # ver estado
cat /etc/pve/firewall/cluster.fw             # ver reglas globales
cat /etc/pve/nodes/$(hostname)/host.fw 2>/dev/null   # reglas del nodo
```

Para una pausa temporal **muy** breve (vuelve a dejarlo como estaba al terminar):

```bash
pve-firewall stop          # detiene el servicio
# … hacer la auditoría/descarga …
pve-firewall start         # restáuralo
```

> **Avisa siempre al cliente** antes de tocar su firewall.

---

## 3. Cómo meter los scripts en el nodo SIN Internet

Si nada de lo anterior es viable (política rígida, red air-gapped, demo offline), aquí van cinco formas de subir los `.sh` al nodo. Elige la más cómoda para tu situación.

### 3.1 Copy-paste por la web shell (la más rápida)

1. En **tu equipo local** (con Internet), descarga el script:
   ```bash
   curl -fsSL -o /tmp/auditoria-proxmox.sh \
     https://raw.githubusercontent.com/KaleltYT/Auditoria-Proxmox/main/auditoria-proxmox.sh
   ```
2. Cópialo al portapapeles. En Linux: `xclip -selection clipboard < /tmp/auditoria-proxmox.sh`. En macOS: `pbcopy < /tmp/auditoria-proxmox.sh`. En Windows (PowerShell): `Get-Content /tmp/auditoria-proxmox.sh | Set-Clipboard`.
3. En la **web shell del nodo**:
   ```bash
   cat > /root/auditoria-proxmox.sh <<'PROXMOX_AUDIT_EOF'
   ```
   Pega ahora todo el contenido del script.
   En la línea siguiente escribe el delimitador y `Enter`:
   ```bash
   PROXMOX_AUDIT_EOF
   ```
4. Ejecuta:
   ```bash
   chmod +x /root/auditoria-proxmox.sh
   /root/auditoria-proxmox.sh
   ```

> El delimitador (`PROXMOX_AUDIT_EOF`) está entre comillas simples a propósito: evita que el shell expanda `$` dentro del script al pegarlo.

### 3.2 Versión base64 (si copy-paste rompe caracteres)

Algunas web shells comen tabs, espacios o saltos de línea raros. Codifícalo en base64:

1. En **tu equipo**:
   ```bash
   base64 -w0 /tmp/auditoria-proxmox.sh ; echo
   ```
2. Copia esa larga cadena.
3. En la **web shell del nodo**:
   ```bash
   cat > /tmp/audit.b64 <<'B64'
   ```
   Pega la cadena, luego `Enter` y:
   ```bash
   B64
   base64 -d /tmp/audit.b64 > /root/auditoria-proxmox.sh
   chmod +x /root/auditoria-proxmox.sh
   /root/auditoria-proxmox.sh
   ```

Mismo proceso para `bench-proxmox.sh`.

### 3.3 SCP desde tu portátil (si tienes SSH al nodo)

```bash
scp /tmp/auditoria-proxmox.sh /tmp/bench-proxmox.sh root@<IP_NODO>:/root/
ssh root@<IP_NODO> 'chmod +x /root/auditoria-proxmox.sh /root/bench-proxmox.sh'
```

Si no tienes SSH directo pero sí acceso a la web shell, esto no aplica — usa §3.1, §3.2 o §3.4.

### 3.4 Servir desde tu portátil por HTTP

Pon los scripts en una carpeta de tu equipo y arranca un servidor HTTP **temporal** en tu propio portátil:

```bash
cd /tmp                                          # carpeta con los .sh
python3 -m http.server 8080 --bind 0.0.0.0
```

Si tu portátil es alcanzable desde el nodo (mismo LAN, VPN o red de gestión), en la **shell del nodo**:

```bash
curl -fsSL -o /root/auditoria-proxmox.sh http://<IP_TU_PORTATIL>:8080/auditoria-proxmox.sh
curl -fsSL -o /root/bench-proxmox.sh     http://<IP_TU_PORTATIL>:8080/bench-proxmox.sh
chmod +x /root/*.sh
```

Cuando termines, **Ctrl-C** en tu portátil para parar el servidor.

> Si el nodo no tiene `curl` pero sí `wget`: `wget -q -O /root/auditoria-proxmox.sh http://...`.

### 3.5 Vía storage de Proxmox (snippets / ISO)

Truco menos conocido pero útil cuando sólo tienes el GUI:

1. En el GUI: *Datacenter → Storage → local → Snippets* (o *ISO Images* si snippets no está habilitado).
2. **Upload** del archivo `auditoria-proxmox.sh` desde tu equipo.
3. En la shell del nodo, los snippets viven en `/var/lib/vz/snippets/` (o ISOs en `/var/lib/vz/template/iso/`):
   ```bash
   cp /var/lib/vz/snippets/auditoria-proxmox.sh /root/
   chmod +x /root/auditoria-proxmox.sh
   ```

Para habilitar el contenido `snippets` en el storage `local`:
*Datacenter → Storage → local → Edit → Content* → marca **Snippets** → OK.

---

## 4. Una vez ejecutada la auditoría sin Internet

Si tampoco puedes subir el `.md` resultante a tu equipo (porque no hay `scp` desde fuera ni red), tienes los mismos caminos a la inversa:

- **`--serve 8765`** del propio script: levanta un HTTP en el nodo y lo descargas con el navegador desde el equipo desde el que conectas. **Funciona sólo si tu equipo alcanza al nodo en ese puerto**. El que llegues al `:8006` no garantiza que llegues al `:8765`: muchos firewalls de cliente / VPN sólo abren el puerto del GUI. Si el navegador te dice *"no se puede conectar"* o *"error al cargar"*, ese es el caso.
- **`--print-base64`** del propio script: imprime el informe en una sola línea base64 a stdout. **Sólo necesita la web shell**, no abre puertos. Es la opción a prueba de balas:

  ```bash
  bash <(curl -fsSL https://raw.githubusercontent.com/KaleltYT/Auditoria-Proxmox/main/auditoria-proxmox.sh) --print-base64
  # (sin argumento usa el último .md de /root; o pasa la ruta exacta)
  ```

  En tu equipo local:

  ```bash
  echo 'PEGA_AQUI_LA_LINEA' | base64 -d | gunzip > audit.md
  ```

- **Manual sin script**: `gzip -c informe.md | base64 -w0 ; echo` y copy/paste igual que arriba.
- **Subir el `.md` al *snippets* de PVE** → bajar desde el GUI.

### Si `--serve` está bloqueado por firewall

Es lo más habitual cuando conectas vía VPN o jump-host: tu cliente alcanza el GUI (`:8006`) pero no el puerto que abre `--serve`. Tres reacciones:

1. **Usa `--print-base64`** (recomendado, no requiere abrir nada).
2. **Comprueba si el bloqueo es local al nodo** (a veces `pve-firewall` o `iptables` del propio host):

   ```bash
   curl -sI http://127.0.0.1:8765/   # ¿responde el python local?
   pve-firewall status               # ¿está activo?
   iptables -L INPUT -n | grep 8765  # ¿hay regla específica?
   ```

   Si responde local pero no remoto, el firewall **del nodo** está cortando. Abrir sólo a tu IP cliente:

   ```bash
   iptables -I INPUT -p tcp --dport 8765 -s <TU_IP_CLIENTE> -j ACCEPT
   # tras descargar:
   iptables -D INPUT -p tcp --dport 8765 -s <TU_IP_CLIENTE> -j ACCEPT
   ```

3. **Si es un firewall de red intermedio**, no hay arreglo desde el nodo — usa `--print-base64`.

### Decodificar la base64 en tu equipo local

#### Linux / macOS (bash, zsh)

```bash
# Versión gzipped (default de --print-base64):
echo 'PEGA_AQUI_LA_LINEA' | base64 -d | gunzip > audit.md

# Versión sin gzip (--print-base64 --plain):
echo 'PEGA_AQUI_LA_LINEA' | base64 -d > audit.md
```

#### Windows — PowerShell (recomendado, no necesita instalar nada)

Abre **PowerShell** (no `cmd.exe`). En Windows 10/11 es nativo: `Win + R` → `powershell` → Enter.

**Versión gzipped** (default de `--print-base64`):

```powershell
# 1) Pega la línea entre las comillas:
$b64 = 'PEGA_AQUI_LA_LINEA_BASE64'

# 2) Decodifica + descomprime + guarda:
$bytes = [Convert]::FromBase64String($b64)
$ms  = [System.IO.MemoryStream]::new($bytes)
$gz  = [System.IO.Compression.GzipStream]::new($ms, [System.IO.Compression.CompressionMode]::Decompress)
$out = [System.IO.MemoryStream]::new()
$gz.CopyTo($out)
$gz.Dispose(); $ms.Dispose()
[System.IO.File]::WriteAllBytes("$PWD\audit.md", $out.ToArray())
Write-Host "Guardado: $PWD\audit.md ($($out.Length) bytes)"
$out.Dispose()
```

> **Importante**: usa el cast explícito `[System.IO.Compression.CompressionMode]::Decompress`. Pasar `'Decompress'` como string falla en PowerShell 5.1 con `Se encontraron varias sobrecargas ambiguas` porque `GzipStream` tiene constructores que también aceptan `CompressionLevel`.

**Versión sin gzip** (lánzalo con `--print-base64 --plain`):

```powershell
$b64 = 'PEGA_AQUI'
[IO.File]::WriteAllBytes("$PWD\audit.md", [Convert]::FromBase64String($b64))
```

#### Windows — `cmd.exe` con `certutil` (sólo versión `--plain`)

`certutil` viene con Windows desde XP y decodifica base64 nativamente, pero **no** sabe gunzipear. Por eso necesitas la versión `--plain`:

```cmd
:: 1) Lanza el script con --plain en el nodo:
::    bash <(curl -fsSL .../auditoria-proxmox.sh) --print-base64 --plain
::
:: 2) Pega la línea en notepad y guárdala como audit.b64
::
:: 3) En cmd:
certutil -decode audit.b64 audit.md
del audit.b64
```

#### Si tienes Git Bash, WSL o Cygwin en Windows

Funcionan los comandos de **Linux/macOS** de arriba tal cual.

Y al terminar, recuerda:

```bash
bash /root/auditoria-proxmox.sh --cleanup /root/proxmox-audit-*.md
# o, si copiaste también el script:
shred -u /root/auditoria-proxmox.sh /root/bench-proxmox.sh
```
