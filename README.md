# gpu-passthrough script

A Bash script for managing GPU passthrough to KVM/libvirt virtual machines. It handles unloading GPU drivers, detaching the GPU from the host, starting the VM, and optionally launching Moonlight for remote streaming. It also supports recovering the GPU back to the host when you're done.

---

## Requirements

The following commands must be available on your system:

- `lspci` — for detecting GPU PCI IDs
- `virsh` — for managing libvirt VMs
- `xmllint` — for parsing VM XML configuration
- `curl` — for checking Sunshine availability
- `lsof` — for detecting processes using the GPU
- `modprobe` — for loading/unloading kernel modules
- `tput` — for colored terminal output

---

## Installation

1. Copy the script to a directory in your `$PATH`, e.g. `~/.local/bin/gpuvmpt`.
2. Make it executable:
   ```bash
   chmod +x gpuvmpt
   ```
3. Create a config directory:
   ```bash
   mkdir -p ~/.config/gpuvmpt
   ```

---

## Configuration

The script sources configuration files in this order:

| Path | Description |
|------|-------------|
| `~/.config/<script_name>/<script_name>.conf` | Main config file |
| `~/.config/<script_name>/<script_name>.d/*.conf` | Drop-in config files |
| `~/.<script_name>` | Legacy/personal config |

### Available Config Variables

| Variable | Description |
|----------|-------------|
| `MANUAL_MODULES` | Array of kernel modules to load/unload when using the `manual` GPU alias |
| `MOONLIGHT_CMD` | Custom command to launch Moonlight (overrides auto-detection) |
| `MOONLIGHT_AUTOSTART` | Set to `y` or `yes` to automatically launch Moonlight after VM start |
| `SUNSHINE_HOST` | Pre-set the Sunshine host IP (skips auto-detection) |
| `SKIP_GETIP` | Set to any non-empty value to skip waiting for the VM's IP address |

### Example Config

```bash
# ~/.config/gpuvmpt/gpuvmpt.conf

MOONLIGHT_AUTOSTART=yes
MOONLIGHT_CMD="flatpak run com.moonlight_stream.Moonlight"
```

### Hook Functions

You can define the following functions in your config to run custom commands at key points in the lifecycle:

| Function | When it runs |
|----------|--------------|
| `pre_vm_start` | Just before the VM is started |
| `post_vm_start` | Just after the VM is successfully started |
| `pre_vm_recover` | Just before the VM is shut down during recovery |
| `post_vm_recover` | Just after the VM has been shut down during recovery |

---

## Usage

```
gpuvmpt <gpu_alias> <vm_name> [action]
```

### Arguments

| Argument | Description |
|----------|-------------|
| `gpu_alias` | The GPU to manage. Currently supports `nvidia` or `manual` |
| `vm_name` | The name of the libvirt VM to start or recover |
| `action` | One of `start` (default), `stop`/`recover`, or `moonlight` |

### Actions

| Action | Description |
|--------|-------------|
| `start` *(default)* | Unloads GPU modules, detaches the GPU from the host, starts the VM, and optionally launches Moonlight |
| `stop` / `recover` | Shuts down the VM, reattaches the GPU to the host, and reloads the GPU modules |
| `moonlight` | Waits for the VM to get an IP, waits for Sunshine to come up, then launches Moonlight |

### Examples

```bash
# Start the win11 VM with the nvidia GPU
gpuvmpt nvidia win11

# Recover the nvidia GPU after shutting down win11
gpuvmpt nvidia win11 recover

# Launch Moonlight and auto-connect to the running win11 VM
gpuvmpt nvidia win11 moonlight
```

---

## How It Works

### `start` flow

1. Detects the GPU by searching `lspci` output for the alias name.
2. Validates the VM exists and is not already running.
3. Checks if GPU kernel modules are loaded.
4. If processes are using the GPU, prompts you to kill them and waits for the GPU to be free.
5. Unloads the GPU kernel modules via `modprobe -r`.
6. Detaches the GPU PCI devices from the host via `virsh nodedev-detach`.
7. Starts the VM via `virsh start`.
8. Optionally launches Moonlight to connect to the VM.

### `recover` flow

1. Shuts down the VM gracefully via `virsh shutdown`, waiting up to 30 seconds.
2. If the VM doesn't shut down in time, prompts to force it off via `virsh destroy`.
3. Reattaches the GPU PCI devices to the host via `virsh nodedev-reattach`.
4. Reloads the GPU kernel modules.

---

## Moonlight / Sunshine Integration

When Moonlight is launched, the script will:

1. Wait for the VM to receive an IP address (via `virsh domifaddr` or DHCP leases).
2. Poll the Sunshine web interface (`http://<ip>:47989`) until it's reachable.
3. Launch Moonlight and stream the `Desktop` session automatically.

If the IP can't be determined, you'll be prompted to enter the host IP manually. If left blank, Moonlight will open without auto-connecting.

> **Note:** Make sure you have already paired your Moonlight client with the Sunshine host before using the auto-connect feature.

---

## GPU Aliases

| Alias | Modules loaded/unloaded |
|-------|------------------------|
| `nvidia` | `nvidia`, `nvidia-drm`, `nvidia-modeset`, `nvidia-uvm` |
| `manual` | Modules defined in `MANUAL_MODULES` config variable |

---

## Notes

- The script uses `sudo` for privileged operations. You may want to configure passwordless `sudo` for the relevant commands.
- PipeWire is started automatically if it's not already running (via `gentoo-pipewire-launcher`). You may want to adjust this for non-Gentoo systems.
- Set the `DEBUG` environment variable to enable `set -x` for verbose output:
  ```bash
  DEBUG=1 gpu-vm nvidia win11
  ```
