# virt-manager-micro-installer TEST UPDATE
# Minimal Debian 13 "Trixie" UEFI/GPT Automated Installer

This repository contains two production-grade shell scripts to automate the deployment of an ultra-lean, micro-footprint Debian 13 "Trixie" virtual machine inside **Virtual Machine Manager (virt-manager / KVM)**. 

Both setups drop legacy backwards compatibility entirely, standardizing strictly on modern **UEFI, GPT, and native systemd** management.

## 🔒 Security Architecture
* **Strict GPT Layout:** Isolated 128MB EFI System Partition (ESP) paired with a clean root filesystem.
* **Secure Boot Ready:** Provisions `shim-signed` alongside modern GRUB to pass host-level UEFI validation out-of-the-box.
* **AppArmor Hardening:** Mandatory process confinement pre-installed and initialized globally.
* **Automated Patching:** Pre-configured `unattended-upgrades` workflow targeting automated daily security updates.
* **Cryptographic SSH Access:** Automatically imports your public GitHub SSH keys into the root account and completely disables remote password authentication.
* **Zero Bloat:** Bypasses recommended/suggested packages entirely via tight `debootstrap` mechanics.

---

## 🛠️ Virt-Manager Pre-Requisites

Before executing either script, ensure your Virtual Machine Manager guest container is properly configured for a modern environment:

1. Create a blank VM instance in `virt-manager` (A disk size of 2GB to 4GB is plenty).
2. Attach the official **Debian 13 Live or Netinstall ISO** and check the box for **"Customize configuration before install"** at the final step.
3. Under the **Overview** menu, explicitly switch the **Firmware** drop-down from *BIOS* to **UEFI x86_64** (Requires `ovmf` / `edk2-ovmf` packages installed on your Linux host system).
4. Boot the machine into your live terminal environment.

---

## 🚀 Execution Guide

Once booted into the LiveCD, switch to root:
```bash
sudo su
```

### Step 1: Download the Script
```bash
curl -O https://raw.githubusercontent.com/conradmorevalue/virt-manager-micro-installer/main/install.sh
```

### Step 2: Run the Installation
Run **one** of the choices below.

#### Choice A: Bare-Minimum Pristine Base
```bash
bash install.sh conradmorevalue base
```

#### Choice B: Hardened Docker Host
```bash
bash install.sh conradmorevalue docker
```

---

## 🏁 Finalizing the Deployment

1. Once the execution pipeline successfully prints the completion prompt, shut down the VM:
   ```bash
   poweroff
   ```
2. Navigate to the VM hardware overview panel inside `virt-manager`, **remove the Live/Netinstall ISO** device mapping, and boot the machine.
3. Access the system securely from your host system using your standard keys:
   ```bash
   ssh root@<guest_vm_ip>
   ```
