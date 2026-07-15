#!/bin/bash
set -e

# --- Core Configurations ---
TARGET_DISK="/dev/vda"
PART_EFI="${TARGET_DISK}1"
PART_ROOT="${TARGET_DISK}2"
MOUNT_DIR="/mnt"
DEBIAN_VERSION="trixie"
MIRROR="http://debian.org"
HOSTNAME="debian13-micro"

# --- Input Arguments ---
GITHUB_USER="$1"
MODE="$2" # Expects: "base" or "docker"

# --- Validation Checks ---
if [ -z "$GITHUB_USER" ] || [ -z "$MODE" ]; then
    echo "❌ ERROR: Missing arguments."
    echo "Usage: bash install.sh USERNAME [base|docker]"
    exit 1
fi

if [ "$MODE" != "base" ] && [ "$MODE" != "docker" ]; then
    echo "❌ ERROR: Mode must be 'base' or 'docker'."
    exit 1
fi

if [ ! -d "/sys/firmware/efi/efivars" ]; then
    echo "❌ ERROR: UEFI firmware must be enabled in virt-manager (Secure Boot OFF)."
    exit 1
fi

echo "=== 1. Formatting GPT Disk Structure ==="
wipefs -a ${TARGET_DISK}
# Allocates 128MB to EFI, and automatically gives ALL remaining disk space to root
sfdisk ${TARGET_DISK} <<EOF
label: gpt
size=128M, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
type=0FC63DAF-8483-4772-8E79-3D69D8477DE4
EOF

echo "=== 2. Building Filesystems ==="
mkfs.vfat -F 32 ${PART_EFI}
mkfs.ext4 -F ${PART_ROOT}

echo "=== 3. Mounting Volumes ==="
mount ${PART_ROOT} ${MOUNT_DIR}
mkdir -p ${MOUNT_DIR}/boot
mount ${PART_EFI} ${MOUNT_DIR}/boot

echo "=== 4. Bootstrapping Minimal Debian Standard ==="
# cloud-guest-utils provides the "growpart" tool for effortless scaling later
debootstrap --variant=minbase --include=ca-certificates,curl,gnupg,cloud-guest-utils ${DEBIAN_VERSION} ${MOUNT_DIR} ${MIRROR}

echo "=== 5. Injecting Network and System Configurations ==="
cat <<EOF > ${MOUNT_DIR}/etc/apt/apt.conf.d/99no-recommends
APT::Install-Recommends "false";
APT::Install-Suggests "false";
EOF

# Use unique UUIDs so the operating system never breaks if the disk geometry scales
ROOT_UUID=$(blkid -s UUID -o value ${PART_ROOT})
EFI_UUID=$(blkid -s UUID -o value ${PART_EFI})

cat <<EOF > ${MOUNT_DIR}/etc/fstab
UUID=${ROOT_UUID}  /      ext4   errors=remount-ro  0  1
UUID=${EFI_UUID}   /boot  vfat   umask=0077         0  2
EOF

echo "${HOSTNAME}" > ${MOUNT_DIR}/etc/hostname
cat <<EOF > ${MOUNT_DIR}/etc/hosts
127.0.0.1   localhost
127.0.1.1   ${HOSTNAME}
EOF

mkdir -p ${MOUNT_DIR}/etc/systemd/network
cat <<EOF > ${MOUNT_DIR}/etc/systemd/network/20-wired.network
[Match]
Name=en* eth*

[Network]
DHCP=yes
EOF

echo "=== 6. Authorizing GitHub SSH Keys ==="
mkdir -p ${MOUNT_DIR}/root/.ssh
chmod 700 ${MOUNT_DIR}/root/.ssh

if curl -sSf "https://github.com{GITHUB_USER}.keys" > ${MOUNT_DIR}/root/.ssh/authorized_keys; then
    chmod 600 ${MOUNT_DIR}/root/.ssh/authorized_keys
else
    echo "❌ ERROR: Failed to fetch GitHub keys."
    umount ${MOUNT_DIR}/boot && umount ${MOUNT_DIR}
    exit 1
fi

echo "=== 7. Chroot Package Installation & systemd-boot Setup ==="
mount --bind /dev ${MOUNT_DIR}/dev
mount --bind /proc ${MOUNT_DIR}/proc
mount --bind /sys ${MOUNT_DIR}/sys

ARCH=$(dpkg --print-architecture)

chroot ${MOUNT_DIR} /bin/bash -c "
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    
    # Minimal Hypervisor Packages (Replaced GRUB with systemd-boot)
    apt-get install -y linux-image-cloud-amd64 systemd systemd-boot \
                       apparmor apparmor-utils unattended-upgrades cron openssh-server qemu-guest-agent

    # Initialize systemd-boot loader
    bootctl install --no-variables

    cat <<EOF > /boot/loader/loader.conf
default debian.conf
timeout 1
EOF

    KERNEL_VERSION=\$(ls /lib/modules | head -n 1)

    cat <<EOF > /boot/loader/entries/debian.conf
title   Debian 13 (Micro)
linux   /vmlinuz-\${KERNEL_VERSION}
initrd  /initrd.img-\${KERNEL_VERSION}
options root=UUID=${ROOT_UUID} ro quiet
EOF

    # Dynamic post-install hook to auto-update boot entries when systemd patches the kernel
    mkdir -p /etc/kernel/postinst.d
    cat <<EOF > /etc/kernel/postinst.d/zz-update-systemd-boot
#!/bin/bash
KERNEL_VERSION=\\\$1
cat <<EOT > /boot/loader/entries/debian.conf
title   Debian 13 (Micro)
linux   /vmlinuz-\\\${KERNEL_VERSION}
initrd  /initrd.img-\\\${KERNEL_VERSION}
options root=UUID=${ROOT_UUID} ro quiet
EOT
EOF
    chmod +x /etc/kernel/postinst.d/zz-update-systemd-boot

    # Safe internal expansion engine tool
    cat <<'EOF' > /usr/local/bin/auto-resize-root
#!/bin/bash
growpart /dev/vda 2 || true
resize2fs /dev/vda2
EOF
    chmod +x /usr/local/bin/auto-resize-root

    # Check if user specifically requested Docker setup
    if [ \"$MODE\" = \"docker\" ]; then
        echo '>>> Installing Optional Docker Addon...'
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://docker.com | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
        
        echo \"deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://docker.com trixie stable\" > /etc/apt/sources.list.d/docker.list
        apt-get update
        apt-get install -y docker-ce docker-ce-cli containerd.io

        mkdir -p /etc/systemd/journald.conf.d
        echo -e \"[Journal]\nSystemMaxUse=50M\nSystemMaxFiles=5\" > /etc/systemd/journald.conf.d/01-maxsize.conf

        mkdir -p /etc/docker
        echo -e '{\n  \"security-opts\": [\"name=apparmor\"]\n}' > /etc/docker/daemon.json
        systemctl enable docker
    fi

    # Secure SSH Access
    mkdir -p /etc/ssh/sshd_config.d
    echo 'PermitRootLogin prohibit-password' > /etc/ssh/sshd_config.d/01-secure-root.conf
    
    # Enable system services
    systemctl enable systemd-networkd systemd-resolved ssh unattended-upgrades
    ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    
    apt-get clean
"

echo "=== 8. Cleaning Up Mount Points ==="
umount ${MOUNT_DIR}/sys && umount ${MOUNT_DIR}/proc && umount ${MOUNT_DIR}/dev
umount ${MOUNT_DIR}/boot && umount ${MOUNT_DIR}

echo "Success. System is secured and ready ($MODE edition). Reboot the VM."


REFERENCES:

