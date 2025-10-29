#!/usr/bin/env bash

##################################################
# LXC 컨테이너 내부 초기화 스크립트
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

# 설정 파일 로드 함수
load_config() {
    local config_file="$1"
    
    if [[ -f "$config_file" ]]; then
        source "$config_file"
        log_success "설정 파일 로드됨: $config_file"
    else
        log_warn "설정 파일을 찾을 수 없음: $config_file (기본값 사용)"
    fi
}

# 현재 스크립트 디렉토리
SCRIPT_DIR="/tmp/scripts"
ENV_FILE="$SCRIPT_DIR/lxc.env"

# 설정 파일 로드
load_config "$ENV_FILE"

# 환경변수 기본값 설정
BASIC_APT=${BASIC_APT:-"curl wget htop tree neofetch git vim net-tools nfs-common"}
LOCALE_LANG=${LOCALE_LANG:-"ko_KR.UTF-8"}
TIMEZONE=${TIMEZONE:-"Asia/Seoul"}
DOCKER_DATA_ROOT=${DOCKER_DATA_ROOT:-"/docker/core"}
DOCKER_DNS1=${DOCKER_DNS1:-"8.8.8.8"}
DOCKER_DNS2=${DOCKER_DNS2:-"1.1.1.1"}
DOCKER_BRIDGE_NET1=${DOCKER_BRIDGE_NET1:-"172.18.0.0/16"}
DOCKER_BRIDGE_GW1=${DOCKER_BRIDGE_GW1:-"172.18.0.1"}
DOCKER_BRIDGE_NM1=${DOCKER_BRIDGE_NM1:-"ProxyNet"}
DOCKER_BRIDGE_NET2=${DOCKER_BRIDGE_NET2:-"172.19.0.0/16"}
DOCKER_BRIDGE_GW2=${DOCKER_BRIDGE_GW2:-"172.19.0.1"}
DOCKER_BRIDGE_NM2=${DOCKER_BRIDGE_NM2:-"ProxyNet2"}
#ALLOW_PORTS=${ALLOW_PORTS:-"80/tcp 443/tcp 443/udp 45876 5574 9999 32400"}
ALLOW_PORTS=${ALLOW_PORTS:-"80/tcp 443/tcp 443/udp}

# 총 단계 수
readonly TOTAL_STEPS=12

# Bash 환경 설정
configure_bash() {
    log_step "단계 1/$TOTAL_STEPS: Bash 환경 설정"
    
    local bash_aliases=(
        "alias ls='ls --color=auto --show-control-chars'"
        "alias ll='ls -al --color=auto --show-control-chars'"
        "log() { echo \"[\$(date '+%T')] \$*\"; }"
        "info() { echo \"[INFO][\$(date '+%T')] \$*\"; }"
        "err() { echo \"[ERROR][\$(date '+%T')] \$*\"; }"
    )
    
    log_info "Bash 별칭 및 함수 추가 중..."
    for alias_line in "${bash_aliases[@]}"; do
        if ! grep -Fxq "$alias_line" /root/.bashrc; then
            echo "$alias_line" >> /root/.bashrc
        fi
    done
    
    source /root/.bashrc
    log_success "Bash 환경 설정 완료"
}

# 시스템 업데이트
update_system() {
    log_step "단계 2/$TOTAL_STEPS: 시스템 업데이트 및 기본 패키지 설치"
    
    log_info "패키지 목록 업데이트 중..."
    if apt-get update -qq >/dev/null 2>&1; then
        log_success "패키지 목록 업데이트 완료"
    else
        log_warn "패키지 목록 업데이트에 실패했지만 계속 진행"
    fi
    
    log_info "시스템 업그레이드 중..."
    if apt-get upgrade -y >/dev/null 2>&1; then
        log_success "시스템 업그레이드 완료"
    else
        log_warn "시스템 업그레이드에 실패했지만 계속 진행"
    fi
    
    log_info "기본 패키지 설치 중..."
    if apt-get install -y $BASIC_APT dnsutils >/dev/null 2>&1; then
        log_success "기본 패키지 설치 완료"
        echo -e "${CYAN}  설치된 패키지: $BASIC_APT dnsutils${NC}"
    else
        log_error "기본 패키지 설치에 실패"
        exit 1
    fi
}

# AppArmor 비활성화
disable_apparmor() {
    log_step "단계 3/$TOTAL_STEPS: AppArmor 비활성화"
    
    log_info "AppArmor 서비스 중지 및 비활성화 중..."
    systemctl stop apparmor >/dev/null 2>&1 || true
    systemctl disable apparmor >/dev/null 2>&1 || true
    
    log_info "AppArmor 패키지 제거 중..."
    if apt-get remove -y apparmor man-db >/dev/null 2>&1; then
        log_success "AppArmor 비활성화 완료"
    else
        log_warn "AppArmor 제거에 실패했지만 계속 진행"
    fi
}

# 로케일 및 폰트 설정
configure_locale() {
    log_step "단계 4/$TOTAL_STEPS: 로케일 및 폰트 설정"
    
    log_info "한국어 패키지 및 폰트 설치 중..."
    if apt-get install -y language-pack-ko fonts-nanum locales >/dev/null 2>&1; then
        log_success "한국어 패키지 설치 완료"
    else
        log_warn "한국어 패키지 설치에 실패했지만 계속 진행"
    fi
    
    log_info "로케일 생성 중..."
    if locale-gen $LOCALE_LANG >/dev/null 2>&1; then
        log_success "로케일 생성 완료: $LOCALE_LANG"
    else
        log_warn "로케일 생성에 실패"
    fi
    
    if update-locale LANG=$LOCALE_LANG >/dev/null 2>&1; then
        log_success "기본 로케일 설정 완료"
    else
        log_warn "기본 로케일 설정에 실패"
    fi
    
    # 환경변수 추가
    local locale_exports=(
        "export LANG=$LOCALE_LANG"
        "export LANGUAGE=$LOCALE_LANG"
        "export LC_ALL=$LOCALE_LANG"
    )
    
    for export_line in "${locale_exports[@]}"; do
        if ! grep -Fxq "$export_line" /root/.bashrc; then
            echo "$export_line" >> /root/.bashrc
        fi
    done
    
    log_success "로케일 환경변수 설정 완료"
}

# 시간대 설정
configure_timezone() {
    log_step "단계 5/$TOTAL_STEPS: 시간대 설정"
    
    log_info "시간대 설정 중: $TIMEZONE"
    if timedatectl set-timezone $TIMEZONE >/dev/null 2>&1; then
        local current_time=$(date '+%Y-%m-%d %H:%M:%S %Z')
        log_success "시간대 설정 완료: $current_time"
    else
        log_warn "시간대 설정에 실패"
    fi
}

# GPU 설정
configure_gpu() {
    log_step "단계 6/$TOTAL_STEPS: GPU 설정"
    
    if [[ -z "$GPU_CHOICE" ]]; then
        log_info "GPU 설정이 지정되지 않아 건너뜀뜀"
        return 0
    fi
    
    case "$GPU_CHOICE" in
        1) # AMD
            log_info "AMD GPU 도구 설치 중..."
            if apt-get install -y vainfo >/dev/null 2>&1; then
                log_success "AMD GPU 도구 설치 완료"
                if vainfo >/dev/null 2>&1; then
                    log_success "AMD GPU 정상 동작 확인"
                else
                    log_warn "AMD GPU 동작 확인 실패 (정상적일 수 있음)"
                fi
            else
                log_warn "AMD GPU 도구 설치에 실패"
            fi
            ;;
        2) # Intel
            log_info "Intel GPU 도구 설치 중..."
            if apt-get install -y vainfo intel-media-va-driver-non-free intel-gpu-tools >/dev/null 2>&1; then
                log_success "Intel GPU 도구 설치 완료"
                if vainfo >/dev/null 2>&1; then
                    log_success "Intel GPU 정상 동작 확인"
                else
                    log_warn "Intel GPU 동작 확인 실패 (정상적일 수 있음음)"
                fi
            else
                log_warn "Intel GPU 도구 설치에 실패"
            fi
            ;;
        3) # NVIDIA
            log_info "NVIDIA GPU 드라이버 설치 중..."
            if apt-get install -y nvidia-driver nvidia-utils-525 >/dev/null 2>&1; then
                log_success "NVIDIA GPU 드라이버 설치 완료"
                if nvidia-smi >/dev/null 2>&1; then
                    log_success "NVIDIA GPU 정상 동작 확인"
                else
                    log_warn "NVIDIA GPU 동작 확인 실패 (재부팅 후 확인 필요할 수 있음)"
                fi
            else
                log_warn "NVIDIA GPU 드라이버 설치에 실패"
            fi
            ;;
        *)
            log_info "GPU 설정을 건너뜀뜀"
            ;;
    esac
}

# Docker 설치
install_docker() {
    log_step "단계 7/$TOTAL_STEPS: Docker 설치"
    
    log_info "Docker 패키지 설치 중..."
    if apt-get install -y docker.io docker-compose-v2 >/dev/null 2>&1; then
        log_success "Docker 패키지 설치 완료"
    else
        log_error "Docker 설치에 실패"
        exit 1
    fi
    
    log_info "Docker 서비스 활성화 중..."
    if systemctl enable docker >/dev/null 2>&1 && systemctl start docker >/dev/null 2>&1; then
        log_success "Docker 서비스 시작 완료"
    else
        log_error "Docker 서비스 시작에 실패"
        exit 1
    fi
}

# Docker 데몬 설정
configure_docker_daemon() {
    log_step "단계 8/$TOTAL_STEPS: Docker 데몬 설정"
    
    log_info "Docker 데이터 디렉토리 생성 중..."
    mkdir -p "$(dirname "$DOCKER_DATA_ROOT")" /etc/docker
    
    log_info "Docker 데몬 설정 파일 생성 중..."
    cat > /etc/docker/daemon.json <<EOF
{
  "data-root": "$DOCKER_DATA_ROOT",
  "log-driver": "json-file",
  "log-opts": { 
    "max-size": "10m", 
    "max-file": "3" 
  },
  "storage-driver": "overlay2",
  "default-shm-size": "1g",
  "default-ulimits": {
    "nofile": {
      "name": "nofile",
      "hard": 65536,
      "soft": 65536
    }
  },
  "dns": ["$DOCKER_DNS1", "$DOCKER_DNS2"]
}
EOF
    
    log_success "Docker 데몬 설정 완료"
    echo -e "${CYAN}  - 데이터 디렉토리: $DOCKER_DATA_ROOT${NC}"
    echo -e "${CYAN}  - DNS 서버: $DOCKER_DNS1, $DOCKER_DNS2${NC}"
    
    log_info "Docker 서비스 재시작 중..."
    if systemctl restart docker >/dev/null 2>&1; then
        log_success "Docker 서비스 재시작 완료"
    else
        log_error "Docker 서비스 재시작에 실패"
        exit 1
    fi
}

# Docker 네트워크 생성
create_docker_network() {
    log_step "단계 9/$TOTAL_STEPS: Docker 사용자 네트워크 생성"

    for i in 1 2; do
        eval net="DOCKER_BRIDGE_NET$i"
        eval gw="DOCKER_BRIDGE_GW$i"
        eval name="DOCKER_BRIDGE_NM$i"
        subnet="${!net}"
        gateway="${!gw}"
        netname="${!name}"

        [ -z "$netname" ] && continue  # 이름이 없으면 스킵
        
        if docker network ls --format '{{.Name}}' | grep -wq "$netname"; then
            log_info "Docker 네트워크($netname) 이미 존재"
        else
            log_info "Docker 사용자 네트워크($netname) 생성 중..."
            if docker network create --subnet="$subnet" --gateway="$gateway" "$netname" >/dev/null 2>&1; then
                log_success "Docker 네트워크($netname) 생성 완료"
                echo -e "${CYAN}  - 서브넷: $subnet${NC}"
                echo -e "${CYAN}  - 게이트웨이: $gateway${NC}"
            else
                log_warn "Docker 네트워크($netname) 생성 실패"
            fi
        fi
    done
}

# UFW 방화벽 설정
configure_firewall() {
    log_step "단계 10/$TOTAL_STEPS: UFW 방화벽 설정"
    
    log_info "방화벽 규칙 설정 중..."
    
    # 내부망 허용
    local gateway_ip=$(ip route | awk '/default/ {print $3; exit}')
    local internal_net=""
    if [[ -n "$gateway_ip" && "$gateway_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        internal_net=$(echo "$gateway_ip" | awk -F. '{print $1"."$2"."$3".0/24"}')
    fi
    
    if [[ -n "$internal_net" ]]; then
        if ufw allow from "$internal_net" >/dev/null 2>&1; then
            log_success "내부망 허용 완료: $internal_net"
        else
            log_warn "내부망 설정 실패: $internal_net"
        fi
    else
        log_warn "내부망 IP를 찾을 수 없음음"
    fi
    
    # Docker 네트워크 허용
    for i in 1 2; do
        eval net="DOCKER_BRIDGE_NET$i"
        eval gw="DOCKER_BRIDGE_GW$i"
        eval name="DOCKER_BRIDGE_NM$i"
        subnet="${!net}"
        gateway="${!gw}"
        netname="${!name}"

        [ -z "$netname" ] && continue  # 이름이 없으면 스킵

        if ufw allow from "$subnet" >/dev/null 2>&1; then
            log_success "Docker 네트워크($netname) 방화벽 허용 완료: $subnet"
        else
            log_warn "Docker 네트워크($netname) 방화벽 허용 실패: $subnet"
        fi
    done

    # 개별 포트 허용
    local port_count=0
    for port in $ALLOW_PORTS; do
        # 포트 형식 검증
        if [[ "$port" =~ ^[0-9]+(/tcp|/udp)?$ ]]; then
            if ufw allow "$port" >/dev/null 2>&1; then
                ((port_count++))
                log_info "포트 $port 허용 완료"
            else
                log_warn "포트 $port 설정 실패"
            fi
        else
            log_warn "잘못된 포트 형식: $port"
        fi
    done
    log_success "개별 포트 허용 완료: $port_count개"
    
    # UFW 활성화
    local ufw_status=$(ufw status 2>/dev/null | head -n1)
    if [[ "$ufw_status" != "Status: active" ]]; then
        if ufw --force enable >/dev/null 2>&1; then
            log_success "UFW 방화벽 활성화 완료"
        else
            log_error "UFW 활성화에 실패"
        fi
    else
        log_success "UFW가 이미 활성화되어 있음"
    fi
}

# DNS 연결 테스트
test_dns() {
    log_step "단계 11/$TOTAL_STEPS: DNS 연결 테스트"
    
    log_info "외부 DNS 연결 테스트 중..."
    if dig @8.8.8.8 google.com +short >/dev/null 2>&1; then
        log_success "DNS 연결 정상"
    else
        log_warn "DNS 쿼리에 실패"
    fi
}

# 네트워크 규칙 설정
configure_network_rules() {
    log_step "단계 12/$TOTAL_STEPS: 네트워크 NAT 및 UFW 규칙 설정"
    
    local nat_iface=$(ip route | awk '/default/ {print $5; exit}')
    if [[ -z "$nat_iface" ]]; then
        log_warn "기본 네트워크 인터페이스를 찾을 수 없음"
        return 1
    fi
    
    # NAT 규칙 추가
    log_info "NAT 규칙 설정 중..."
    for i in 1 2; do
        eval net="DOCKER_BRIDGE_NET$i"
        eval gw="DOCKER_BRIDGE_GW$i"
        eval name="DOCKER_BRIDGE_NM$i"
        subnet="${!net}"
        gateway="${!gw}"
        netname="${!name}"

        [ -z "$netname" ] && continue  # 이름이 없으면 스킵

        if ! iptables -t nat -C POSTROUTING -s "$subnet" -o "$nat_iface" -j MASQUERADE 2>/dev/null; then
            if iptables -t nat -A POSTROUTING -s "$subnet" -o "$nat_iface" -j MASQUERADE 2>/dev/null; then
                log_success "Docker 네트워크($netname) NAT 규칙 추가 완료: $subnet"
            else
                log_warn "Docker 네트워크($netname) NAT 규칙 추가 실패: $subnet"
            fi
        else
            log_info "Docker 네트워크($netname) NAT 규칙 이미 존재: $subnet"
        fi
    done
    
    # UFW Docker 규칙 설정
    local ufw_after_rules="/etc/ufw/after.rules"
    if [[ -f "$ufw_after_rules" ]]; then
        log_info "UFW Docker 규칙 설정 중..."
        
        if ! grep -q "^:DOCKER-USER" "$ufw_after_rules" 2>/dev/null; then
            if cp "$ufw_after_rules" "${ufw_after_rules}".bak 2>/dev/null; then
                log_info "기존 UFW 규칙 백업 완료"
            fi
            
            if sed -i '/^COMMIT/i :DOCKER-USER - [0:0]\n-A DOCKER-USER -j RETURN' "$ufw_after_rules" 2>/dev/null; then
                log_success "UFW Docker 규칙 추가 완료"
                
                if ufw reload >/dev/null 2>&1; then
                    log_success "UFW 규칙 재로드 완료"
                else
                    log_warn "UFW 재로드에 실패"
                fi
            else
                log_warn "UFW Docker 규칙 추가에 실패"
            fi
        else
            log_info "UFW Docker 규칙이 이미 존재"
        fi
    else
        log_warn "UFW after.rules 파일을 찾을 수 없음"
    fi
}

# 메인 실행 함수
main() {
    show_header "LXC 컨테이너 초기화"
    
    log_info "시스템 정보"
    echo -e "${CYAN}  - OS: $(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)${NC}"
    echo -e "${CYAN}  - 커널: $(uname -r)${NC}"
    echo -e "${CYAN}  - 아키텍처: $(uname -m)${NC}"
    echo -e "${CYAN}  - 메모리: $(free -h | awk '/^Mem:/ {print $2}')${NC}"
    
    # 각 단계 실행
    configure_bash
    update_system
    disable_apparmor
    configure_locale
    configure_timezone
    configure_gpu
    install_docker
    configure_docker_daemon
    create_docker_network
    configure_firewall
    test_dns
    configure_network_rules
    
    # 완료 메시지
    echo
    log_success "════════════════════════════════════════════════════════════"
    log_success "  LXC 컨테이너 초기화가 완료되었습니다!"
    log_success "════════════════════════════════════════════════════════════"
    
    echo
    log_info "설치된 서비스 상태"
    echo -e "${CYAN}  - Docker: $(systemctl is-active docker)${NC}"
    echo -e "${CYAN}  - UFW: $(systemctl is-active ufw)${NC}"
    echo -e "${CYAN}  - 시간대: $(timedatectl | grep "Time zone" | awk '{print $3}')${NC}"
    
    log_success "초기화 스크립트 실행 완료!"
}

# 스크립트 실행
main
