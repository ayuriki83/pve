#!/bin/bash

##################################################
# Proxmox 초기설정 자동화
# - root 파티션 확장
# - 보안 설정(UFW 등)
# - GPU 설정
# - Cloudflare Tunnel 설치 및 Proxmox 전용 설정
##################################################

#set -e

# 색상 정의
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# 로깅 함수
log_success() { echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] $*${NC}"; }
log_error() { echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*${NC}" >&2; }
log_warn() { echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $*${NC}"; }
log_info() { echo -e "${CYAN}[$(date '+%Y-%m-%d %H:%M:%S')] $*${NC}"; }
log_step() { echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] $*${NC}"; }

# 헤더 출력 함수
show_header() {
    local title="$1"
    echo
    echo -e "${PURPLE}════════════════════════════════════════════════════════════${NC}"
    echo -e "${PURPLE}   $title${NC}"
    echo -e "${PURPLE}════════════════════════════════════════════════════════════${NC}"
    echo
}

# 확인 메시지 함수
confirm_action() {
    local message="$1"
    local default="${2:-n}"
    
    echo
    if [[ "$default" == "y" ]]; then
        echo -ne "${YELLOW}⚠️ $message [Y/n]: ${NC}"
    else
        echo -ne "${YELLOW}⚠️ $message [y/N]: ${NC}"
    fi
    
    read -r response
    response=${response:-$default}
    
    case "$response" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

# 설정 파일 로드 함수
load_config() {
    local config_file="$1"
    
    if [[ -f "$config_file" ]]; then
        source "$config_file"
        log_success "설정 파일 로드됨: $config_file"
    else
        log_warn "설정 파일을 찾을 수 없습니다: $config_file (기본값 사용)"
    fi
}

# 설정 파일 위치
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/pve.env"

# 설정 파일 로드
load_config "$ENV_FILE"

# Root 권한 확인
if [[ $EUID -ne 0 ]]; then
    log_error "이 스크립트는 root 권한이 필요합니다"
    log_info "다음 명령으로 실행하세요: sudo $0"
    exit 1
fi

# root 파티션 크기 확장
expand_root_partition() {
    log_step "단계 1/3: root 파티션 크기 확장"

    local before_size
    before_size=$(lsblk -b /dev/mapper/pve-root -o SIZE -n | awk '{printf "%.2f", $1/1024/1024/1024}')
    log_info "확장 전 용량: ${before_size} GB"
    
    if lvresize -l +100%FREE /dev/pve/root >/dev/null 2>&1; then
        if resize2fs /dev/mapper/pve-root >/dev/null 2>&1; then
            local after_size
            after_size=$(lsblk -b /dev/mapper/pve-root -o SIZE -n | awk '{printf "%.2f", $1/1024/1024/1024}')
            log_success "root 파티션 확장 완료: ${before_size} GB → ${after_size} GB"
        else
            log_warn "파일시스템 크기 조정에 실패했지만 계속 진행합니다"
        fi
    else
        log_warn "LV 크기 조정을 건너뜁니다 (이미 최대 크기이거나 오류 발생)"
    fi
}

# 보안 설정
configure_security() {
    log_step "단계 1/3: 보안 설정"
    
    # AppArmor 비활성화
    log_info "AppArmor 비활성화 중..."
    systemctl stop apparmor >/dev/null 2>&1 || true
    systemctl disable apparmor >/dev/null 2>&1 || true
    systemctl mask apparmor >/dev/null 2>&1 || true
    log_success "AppArmor 비활성화 완료"
    
    # 기존 pve-firewall 비활성화
    log_info "기존 pve-firewall 비활성화 중..."
    systemctl stop pve-firewall >/dev/null 2>&1 || true
    systemctl disable pve-firewall >/dev/null 2>&1 || true
    log_success "pve-firewall 비활성화 완료"
    
    # UFW 설치 및 설정
    log_info "UFW 방화벽 설치 및 설정 중..."
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y ufw >/dev/null 2>&1
    
    # 포트 허용 설정
    # - 22    : SSH
    # - 45876 : (사용자 정의 서비스)
    local ports=("22" "45876")
    for port in "${ports[@]}"; do
        ufw allow "$port" >/dev/null 2>&1
        log_info "포트 $port 허용됨"
    done
    
    # 내부 네트워크 설정
    local current_ip
    current_ip=$(hostname -I | awk '{print $1}')
    local internal_network
    internal_network="$(echo "$current_ip" | awk -F. '{print $1"."$2"."$3".0/24"}')"
    
    echo
    log_info "현재 시스템 IP: $current_ip"
    log_info "자동 감지된 내부 네트워크: $internal_network"
    echo -ne "${CYAN}내부망 IP 대역을 입력하세요 [기본값: $internal_network]: ${NC}"
    read -r user_network
    user_network=${user_network:-$internal_network}
    
    ufw allow from "$user_network" >/dev/null 2>&1
    ufw --force enable >/dev/null 2>&1
    
    log_success "방화벽 설정 완료"
    echo
    log_info "현재 방화벽 상태:"
    ufw status verbose | while IFS= read -r line; do
        echo -e "${CYAN}  $line${NC}"
    done
}

# GPU 설정
configure_gpu() {
    log_step "단계 2/3: GPU 설정"
    
    echo
    log_info "GPU 종류를 선택하세요:"
    echo -e "${CYAN}  1) AMD (내장/외장 GPU)${NC}"
    echo -e "${CYAN}  2) Intel (내장/외장 GPU)${NC}"
    echo -e "${CYAN}  3) NVIDIA (외장 GPU)${NC}"
    echo -e "${CYAN}  4) 건너뛰기${NC}"
    
    echo -ne "${CYAN}선택 [1-4]: ${NC}"
    read -r gpu_choice
    
    case "$gpu_choice" in
        1)
            log_info "AMD GPU 설정 중..."
            apt-get install -y pve-firmware >/dev/null 2>&1
            sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="amd_iommu=on iommu=pt /' /etc/default/grub
            log_success "AMD GPU 설정 완료"
            ;;
        2)
            log_info "Intel GPU 설정 중..."
            sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="intel_iommu=on iommu=pt /' /etc/default/grub
            log_success "Intel GPU 설정 완료"
            ;;
        3)
            log_info "NVIDIA GPU 설정 중..."
            sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="iommu=pt /' /etc/default/grub
            modprobe vfio-pci >/dev/null 2>&1 || true
            echo -e "vfio\nvfio_iommu_type1\nvfio_pci\nvfio_virqfd" > /etc/modules-load.d/vfio.conf
            log_success "NVIDIA GPU 설정 완료"
            log_info "NVIDIA PCI 디바이스 ID는 'lspci -nn | grep -i nvidia' 명령으로 확인 가능합니다"
            ;;
        4)
            log_info "GPU 설정을 건너뜁니다"
            return 0
            ;;
        *)
            log_warn "잘못된 선택입니다. GPU 설정을 건너뜁니다"
            return 0
            ;;
    esac
    
    if [[ $gpu_choice =~ ^[1-3]$ ]]; then
        log_info "GRUB 설정 업데이트 중..."
        if update-grub >/dev/null 2>&1; then
            log_success "GRUB 업데이트 완료"
            log_info "재부팅 후 'ls -la /dev/dri/' 명령으로 GPU 장치를 확인하세요"
        else
            log_error "GRUB 업데이트에 실패했습니다"
        fi
    fi
}

# Cloudflare Tunnel 설정
configure_cf_tunnel() {
    log_step "단계 3/3: Proxmox용 Cloudflare Tunnel 설정"

    # cloudflared 설치
    log_info "cloudflared 설치 중..."
    wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -O /tmp/cloudflared.deb
    if dpkg -i /tmp/cloudflared.deb >/dev/null 2>&1; then
        log_success "cloudflared 설치 완료"
    else
        log_error "cloudflared 설치 실패"
        return 1
    fi

    # 사용자에게 hostname 입력 받기
    echo
    echo -ne "${CYAN}Proxmox 접속용 Cloudflare 도메인(예: proxmox.example.com): ${NC}"
    read -r HOSTNAME_CF
    if [[ -z "$HOSTNAME_CF" ]]; then
        log_error "도메인을 입력하지 않아 Cloudflare Tunnel 설정을 건너뜁니다."
        return 1
    fi
    log_info "입력된 hostname: $HOSTNAME_CF"

    # 사용자 안내
    log_warn "⚠️  'cloudflared tunnel login' 브라우저 인증이 필요합니다 (최초 1회)."
    if confirm_action "지금 Cloudflare에 로그인하시겠습니까?" "y"; then
        cloudflared tunnel login
    else
        log_warn "Cloudflare 로그인은 건너뜁니다. (나중에 수동 실행 필요)"
        return 0
    fi

    # 터널 생성
    local TUNNEL_NAME="proxmox-ui"
    cloudflared tunnel create $TUNNEL_NAME
    local TUNNEL_ID
    TUNNEL_ID=$(cloudflared tunnel list | grep "$TUNNEL_NAME" | awk '{print $1}')
    local CRED_FILE="/root/.cloudflared/${TUNNEL_ID}.json"
    local CONF_FILE="/etc/cloudflared/config.yml"

    # config.yml 작성
    log_info "config.yml 생성 중..."
    mkdir -p /etc/cloudflared
    cat > $CONF_FILE <<EOF
tunnel: $TUNNEL_ID
credentials-file: $CRED_FILE

ingress:
  - hostname: $HOSTNAME_CF
    service: https://127.0.0.1:8006
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF
    log_success "config.yml 생성 완료 ($CONF_FILE)"

    # DNS 자동 등록
    log_info "Cloudflare DNS에 $HOSTNAME_CF 자동 연결 중..."
    if cloudflared tunnel route dns $TUNNEL_NAME $HOSTNAME_CF >/dev/null 2>&1; then
        log_success "DNS 레코드가 자동 등록되었습니다 (CNAME → cfargotunnel)."
    else
        log_warn "DNS 자동 등록에 실패했습니다. Cloudflare 대시보드에서 직접 확인하세요."
    fi

    # 서비스 등록 및 실행
    log_info "cloudflared 서비스 등록 중..."
    cloudflared service install
    systemctl enable cloudflared
    systemctl restart cloudflared
    log_success "Cloudflare Tunnel 서비스 실행 완료"
}

# 메인 실행
main() {
    show_header "Proxmox 초기설정 자동화"
    
    log_info "시스템 정보"
    echo -e "${CYAN}  - OS: $(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2)${NC}"
    echo -e "${CYAN}  - 커널: $(uname -r)${NC}"
    echo -e "${CYAN}  - 메모리: $(free -h | awk '/^Mem:/ {print $2}')${NC}"
    echo -e "${CYAN}  - 디스크 사용량: $(df -h / | awk 'NR==2 {print $3"/"$2" ("$5")"}')${NC}"

    #expand_root_partition
    configure_security
    configure_gpu
    configure_cf_tunnel   # 🔥 Cloudflare Tunnel 추가됨
    
    echo
    log_success "════════════════════════════════════════════════════════════"
    log_success "  Proxmox 초기설정이 완료되었습니다!"
    log_success "════════════════════════════════════════════════════════════"
    echo
    
    log_warn "설정을 완전히 적용하려면 시스템을 재부팅해주세요"
    
    if confirm_action "지금 재부팅하시겠습니까?" "n"; then
        log_info "시스템을 재부팅합니다..."
        sleep 3
        reboot
    fi
}

main
