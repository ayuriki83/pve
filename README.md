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
apt install curl wget htop tree rsync git vim parted nfs-common net-tools -y

mkdir -p /tmp/scripts && cd /tmp/scripts
git clone -b working --single-branch https://github.com/ayuriki83/pve.git .
chmod +x pve_init.sh && chmod +x pve_partition.sh && chmod +x lxc_create.sh
```

### Step1. Proxmox Host
```
# Running in a proxmox
cd /tmp/scripts

# 1: Proxmox init
./pve_init.sh
```

### Step2. (Optional) Synology
```
# Running in a proxmox

# 2: Install synology
cd /tmp/scripts && ./synology.sh
```
```
# Running in a synology

# 3: Setting Up NFS Folder Sharing
- Enable the NFS Service
- Create a Backup Folder
- Assign the Backup Folder to NFS (Enable NFS Options, IP Range)
```
```
# Running in a container

# 4: NFS Backup Setting
cd /tmp/scripts && ./backup_setting.sh
```

### Step3. LXC Container
```
# Running in a proxmox

# 5: Partitioning (If you are not running Synology)
./pve_partition.sh

# 6: LXC Container Create
./lxc_create.sh
```
```
# Running in a container
# pct enter $CT_ID

# 7: Management Docker 
cd /tmp/scripts && ./docker.sh

# 8: Management Caddy (Optional)
cd /tmp/scripts && ./caddy_setup.sh
```
