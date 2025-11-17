#!/bin/bash
set -e

echo "STEP 0: Check kubeadm prerequisites"
echo "  - Ensure swap is disabled"
if swapon --show | grep -q 'partition'; then
    echo "    Swap is enabled -> disabling now..."
    swapoff -a
    (crontab -l 2>/dev/null; echo "@reboot /sbin/swapoff -a") | crontab - || true
else
    echo "    Swap is already disabled"
fi

echo "  - Load required kernel modules"
cat <<EOF > /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

echo "  - Make bridged network traffic visible to iptables"
if lsmod | grep -q br_netfilter; then
    echo "    br_netfilter module already loaded"
else
    echo "    Loading br_netfilter module..."
    modprobe br_netfilter
fi

cat <<EOF > /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF

sysctl --system >/dev/null

echo "  - Verify sysctl settings"
ip6_val=$(sysctl -n net.bridge.bridge-nf-call-ip6tables)
ip_val=$(sysctl -n net.bridge.bridge-nf-call-iptables)

if [ "$ip6_val" = "1" ] && [ "$ip_val" = "1" ]; then
    echo "    OK: net.bridge.bridge-nf-call-ip6tables = 1 and net.bridge.bridge-nf-call-iptables = 1"
else
    echo "    ERROR: one or both sysctl values are not set to 1"
    sysctl -a | grep net.bridge.bridge-nf-call
    exit 1
fi

echo "[OK] Kubeadm prerequisites successfully met."

echo "STEP 1: Install containerd runtime..."

if which containerd >/dev/null 2>&1; then
        echo "  - Containerd is already installed at $(which containerd)"
else
        echo "  - Installing prerequisites"
        apt-get update -qq
        apt-get install -y ca-certificates curl gnupg lsb-release >/dev/null

        echo "  - Adding Docker repository to apt"
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc

        tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

        apt-get update -qq

        echo "  - Installing containerd.io package"
        apt-get install -y containerd.io >/dev/null

        echo "  - Enabling and starting containerd"
        systemctl daemon-reload
        systemctl enable --now containerd >/dev/null
fi

echo "  - Verifying containerd status"
if systemctl is-active --quiet containerd; then
        echo "    OK: containerd service is active"
else
        echo "    ERROR: containerd service is not running"
        systemctl status containerd --no-pager -l
        exit 1
fi

echo "[OK] Containerd runtime ready."

echo "STEP 2: Install CNI plugins"
CNI_DIR="/opt/cni/bin"
mkdir -p "$CNI_DIR"

if [ "$(ls -1 $CNI_DIR 2>/dev/null | wc -l)" -gt 5 ]; then
        echo "  - CNI plugins already installed under $CNI_DIR"
else
        echo "  - Detecting system architecture"
        ARCH=$(uname -m)
        case "$ARCH" in
                x86_64)         ARCH="amd64" ;;
                aarch64)        ARCH="arm64" ;;
                armv7l)         ARCH="armv7" ;;
                *)              echo "Unsupported architecture: $ARCH"; exit 1 ;;
        esac
        echo "    Detected architecture: $ARCH"

        echo "    Fetching latest CNI release version"
        CNI_VERSION=$(curl -s https://api.github.com/repos/containernetworking/plugins/releases/latest | grep tag_name | cut -d '"' -f4)

        if [ -z "$CNI_VERSION" ]; then
                echo "    ERROR: Could not fetch latest CNI version"
                exit 1
        fi
        echo "    Latest CNI version: $CNI_VERSION"

        echo "  - Downloading and extracting CNI plugins"
        curl -L -o /tmp/cni-plugins.tgz "https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-linux-${ARCH}-${CNI_VERSION}.tgz"
        tar -C "$CNI_DIR" -xzvf /tmp/cni-plugins.tgz >/dev/null
        rm -f /tmp/cni-plugins.tgz
fi

echo "  - Verifying CNI plugin presence"
if [ "$(ls -1 $CNI_DIR | wc -l)" -gt 5 ]; then
        echo "    OK: CNI plugins found in $CNI_DIR"
else
        echo "    ERROR: CNI plugins missing in $CNI_DIR"
        exit 1
fi

echo "[OK] CNI plugins ready."

echo "STEP 3: Configure containerd to use systemd cgroup driver"

CONFIG_FILE="/etc/containerd/config.toml"

if [ ! -f "$CONFIG_FILE" ] || ! grep -q "SystemdCgroup" "$CONFIG_FILE"; then
        echo "  - Generating default containerd config"
        containerd config default > "$CONFIG_FILE"
fi

CONTAINERD_VERSION=$(containerd --version | awk '{print $3}' | cut -d '-' -f1)
CONTAINERD_VERSION="${CONTAINERD_VERSION#v}"
MAJOR_VERSION=$(echo "$CONTAINERD_VERSION" | cut -d. -f1)

echo "  - Detected containerd version: $CONTAINERD_VERSION"

if [ "$MAJOR_VERSION" -ge 2 ]; then
        TABLE='plugins."io.containerd.cri.v1.runtime".containerd.runtimes.runc.options'
else
        TABLE='plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options'
fi

echo "  - Setting SystemdCgroup = true under [$TABLE]"

if grep -q "SystemdCgroup" "$CONFIG_FILE"; then
        sed -i "s|SystemdCgroup *=.*|SystemdCgroup = true|g" "$CONFIG_FILE"
else
        sed -i "/$TABLE/ a\     SystemdCgroup = true" "$CONFIG_FILE"
fi

echo "  - Restarting containerd to apply changes"
systemctl restart containerd
systemctl status containerd --no-pager -l | grep Active

echo "[OK] Containerd configured to use systemd cgroup driver"

echo "STEP 4: Install Kubernetes components"

if which kubeadm >/dev/null 2>&1; then
        echo "  - Kubernetes components already installed :"
        kubeadm version
else
        LATEST_VERSION=$(curl -s https://api.github.com/repos/kubernetes/kubernetes/releases/latest | grep tag_name | cut -d '"' -f4)

        read -r -p "The latest Kubernetes version is $LATEST_VERSION. Do you want to override and use a specific version? [${LATEST_VERSION}] " USER_VERSION

        if [ -n "$USER_VERSION" ]; then
            K8S_VERSION="$USER_VERSION"
        else
            K8S_VERSION="$LATEST_VERSION"
        fi

        echo "  - Selected Kubernetes version: $K8S_VERSION"

        echo "  - Installing prerequisites"
        apt-get update -qq
        apt-get install -y ca-certificates curl gpg >/dev/null

        echo "  - Adding Kubernetes apt key"
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_VERSION%.*}/deb/Release.key" | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

        echo "  - Adding Kubernetes apt repository"
        echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_VERSION%.*}/deb/ /" > /etc/apt/sources.list.d/kubernetes.list

        echo "  - Updating package index and installing Kubernetes components"
        apt-get update -qq
        apt-get install -y kubelet kubeadm kubectl >/dev/null

        echo "  - Holding versions to prevent automatic updates"
        apt-mark hold kubelet kubeadm kubectl
fi

echo "  - Enabling kubelet service"
systemctl enable --now kubelet >/dev/null

echo "[OK] Kubernetes components installed and kubelet running"
