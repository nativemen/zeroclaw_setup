# MTU Synchronization Guide for WSL2 and Docker

This guide provides a standardized procedure for synchronizing the **Maximum Transmission Unit (MTU)** across Windows, WSL2, and Docker environments. Aligning these values is critical for preventing packet fragmentation and ensuring stable network performance, particularly when using VPNs or overlay networks.

---

## 1. Windows Host Configuration

### Environment Variables
To ensure networking tools or overlays respect the standard MTU, set the following system environment variable:

* **Variable:** `TS_DEBUG_MTU`
* **Value:** `1500`

### Verification
Open **PowerShell as Administrator** and run the following command to verify that all subinterfaces are correctly configured:

```powershell
netsh interface ipv4 show subinterfaces
```
> **Note:** Ensure the `MTU` column shows `1500` for your primary network adapters.

---

## 2. WSL2 (Ubuntu) Configuration

WSL2 virtual interfaces often default to 1500, but consistency can be enforced during the boot process via `/etc/wsl.conf`.

### Persistent Interface Setup
Edit the WSL configuration file:

```bash
sudo nano /etc/wsl.conf
```

Add the following block to ensure `eth0` is initialized with the correct MTU on startup:

```ini
[boot]
command="ifconfig eth0 mtu 1500"
```

---

## 3. Docker Engine Configuration

Docker bridge networks require explicit MTU definitions to match the host; otherwise, they may inherit smaller values from virtual interfaces, causing packet loss.

### Daemon Configuration
Edit (or create) the Docker daemon configuration file:

```bash
sudo nano /etc/docker/daemon.json
```

Apply the following configuration (including recommended DNS for reliability):

```json
{
  "dns": ["8.8.8.8", "1.1.1.1"],
  "mtu": 1500
}
```

### Apply Changes
Restart the Docker service using `systemctl` to apply the new MTU and DNS settings:

```bash
sudo systemctl restart docker
```

---

## 4. Final Verification

After configuring all layers, verify the settings within the WSL terminal:

```bash
# Check all network interfaces
ifconfig
```

### Configuration Checklist
- [x] **Windows Host:** `netsh` confirms MTU 1500 for active interfaces.
- [x] **WSL2 Environment:** `eth0` reports MTU 1500.
- [x] **Docker Engine:** `docker0` and associated container interfaces report MTU 1500.