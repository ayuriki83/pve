# Proxmox 설치
Proxmox + LXC(Ubuntu) + Synology

### Step0. 사전작업
```
echo "alias ls='ls --color=auto --show-control-chars'" >> /root/.bashrc
echo "alias ll='ls -al --color=auto --show-control-chars'" >> /root/.bashrc
source /root/.bashrc

cp /etc/apt/sources.list.d/pve-enterprise.list /etc/apt/sources.list.d/pve-enterprise.list.bak && \
echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" | tee /etc/apt/sources.list.d/pve-enterprise.list

cp /etc/apt/sources.list.d/ceph.list /etc/apt/sources.list.d/ceph.list.bak && \
echo "deb http://download.proxmox.com/debian/ceph-quincy bookworm no-subscription" | tee /etc/apt/sources.list.d/ceph.list

apt update && apt upgrade -y
apt install curl wget htop tree rsync neofetch git vim parted nfs-common net-tools -y

mkdir -p /tmp/scripts && cd /tmp/scripts
git clone https://github.com/ayuriki83/pve.git .
chmod +x pve_init.sh && chmod +x pve_partition.sh && chmod +x lxc_create.sh
```

### Step1. Proxmox 호스트
```
cd /tmp/scripts

# 1단계: Proxmox 초기설정
./pve_init.sh

# 2단계: 디스크 파티션 설정
./pve_partition.sh

# 3단계: LXC 컨테이너 생성
./lxc_create.sh
```

### Step2. LXC 컨테이너 내부
```
pct enter $CT_ID
cd /tmp/scripts
chmod +x docker.sh && chmod +x caddy_setup.sh

# 4단계: Docker 서비스 배포 (Caddyfile도 자동 생성됨)
./docker.sh

# 5단계: Caddy 서비스 관리 (필요시)
./caddy_setup.sh
```
