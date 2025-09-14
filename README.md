# Proxmox
Proxmox + LXC(Ubuntu) + Synology

### Step0. Initial
```
echo "alias ls='ls --color=auto --show-control-chars'" >> /root/.bashrc
echo "alias ll='ls -al --color=auto --show-control-chars'" >> /root/.bashrc
source /root/.bashrc

mv /etc/apt/sources.list.d/pve-enterprise.sources /etc/apt/sources.list.d/pve-enterprise.sources.disabled
cp /etc/apt/sources.list.d/ceph.sources /etc/apt/sources.list.d/ceph.sources.bak

cat <<EOF | tee /etc/apt/sources.list.d/pve-no-subscription.sources
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF

cat <<EOF | tee /etc/apt/sources.list.d/ceph.sources
Types: deb
URIs: http://download.proxmox.com/debian/ceph-squid
Suites: trixie
Components: no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF

apt update && apt upgrade -y
apt install curl wget htop tree rsync neofetch git vim parted nfs-common net-tools -y

mkdir -p /tmp/scripts && cd /tmp/scripts
git clone https://github.com/ayuriki83/pve.git .
chmod +x pve_init.sh && chmod +x pve_partition.sh && chmod +x lxc_create.sh
```

### Step1. Proxmox Host
```
cd /tmp/scripts

# 1: Proxmox init
./pve_init.sh

# 2: Partitioning
./pve_partition.sh

# 3: LXC Container Create
./lxc_create.sh
```

### Step2. LXC Container
```
pct enter $CT_ID

# 4: Management Docker 
cd /tmp/scripts && ./docker.sh

# 5: Management Caddy (Optional)
cd /tmp/scripts && ./caddy_setup.sh
```
