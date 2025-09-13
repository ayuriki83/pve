#!/bin/bash

##################################################
# Proxmox Ubuntu LXC 컨테이너 설치 자동화
##################################################

set -e

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
        log_warn "설정 파일을 찾을 수 없습니다: $config_file (기본값 사용)"
    fi
}

# IP 주소 검증 함수
validate_ip() {
    local ip="$1"
    local ip_regex="^([0-9]{1,3}\.){3}[0-9]{1,3}$"
    
    if [[ ! $ip =~ $ip_regex ]]; then
        return 1
    fi
    
    # 각 옥텟이 0-255 범위인지 확인
    IFS='.' read -ra octets <<< "$ip"
    for octet in "${octets[@]}"; do
        if [[ $octet -gt 255 ]]; then
            return 1
        fi
    done
    
    return 0
}

# 확인 메시지 함수
confirm_action() {
    local message="$1"
    
    echo
    echo -ne "${YELLOW}⚠️ $message [y/N]: ${NC}"
    read -r response
    
    case "$response" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

# 템플릿 정보 출력 함수
show_template_info() {
    echo
    log_info "사용 가능한 Ubuntu 템플릿 확인 중..."
    local available_templates=$(pveam available --section system | awk '/ubuntu-22.04-standard/ {print $2}' | sort -V)
    
    if [[ -z "$available_templates" ]]; then
        log_warn "사용 가능한 Ubuntu 템플릿이 없습니다. 템플릿 목록을 업데이트합니다..."
        pveam update >/dev/null 2>&1
        available_templates=$(pveam available --section system | awk '/ubuntu-22.04-standard/ {print $2}' | sort -V)
    fi
    
    if [[ -n "$available_templates" ]]; then
        log_info "사용 가능한 Ubuntu 22.04 템플릿 목록:"
        echo "$available_templates" | while IFS= read -r template; do
            echo -e "${CYAN}  - $template${NC}"
        done
    fi
}

# GPU 설정 출력 함수
show_gpu_options() {
    echo
    log_info "GPU 종류를 선택하세요:"
    echo -e "${CYAN}  1) AMD (내장/외장 GPU)${NC}"
    echo -e "${CYAN}  2) Intel (내장/외장 GPU)${NC}" 
    echo -e "${CYAN}  3) NVIDIA (외장 GPU)${NC}"
    echo -e "${CYAN}  4) GPU 없음 (건너뛰기)${NC}"
    
    echo -ne "${CYAN}선택 [1-4]: ${NC}"
    read gpu_choice
    
    case "$gpu_choice" in
        1|2|3)
            export GPU_CHOICE="$gpu_choice"
            log_success "GPU 설정: $(case $gpu_choice in 1) echo "AMD";; 2) echo "Intel";; 3) echo "NVIDIA";; esac)"
            ;;
        4)
            export GPU_CHOICE=""
            log_info "GPU 설정을 건너뜁니다"
            ;;
        *)
            log_info "잘못된 선택입니다. GPU 설정을 건너뜁니다"
            export GPU_CHOICE=""
            ;;
    esac
}

# 설정 파일 위치
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/pve.env"

# 설정 파일 로드
load_config "$ENV_FILE"

# 환경변수 기본값 설정
MAIN=${MAIN:-"main"}
VG_NAME="vg-$MAIN"
LV_NAME="lv-$MAIN"
LVM_NAME="lvm-$MAIN"
CT_ID=${CT_ID:-101}
HOSTNAME=${HOSTNAME:-"Ubuntu"}
STORAGE=${LVM_NAME:-"lvm-main"}
ROOTFS=${ROOTFS:-128}
MEMORY_GB=${MEMORY_GB:-18}
MEMORY=$((MEMORY_GB * 1024))
CORES=${CORES:-6}
CPU_LIMIT=${CPU_LIMIT:-6}
UNPRIVILEGED=${UNPRIVILEGED:-0}
RCLONE_GB=${RCLONE_GB:-256}
RCLONE_SIZE="${RCLONE_GB}G"
LV_RCLONE=${LV_RCLONE:-"lv-rclone"}
MNT_RCLONE=${MNT_RCLONE:-"/mnt/rclone"}
DIR_BACKUP=${DIR_BACKUP}
MNT_BACKUP=${MNT_BACKUP:-"/mnt/backup"}

# Root 권한 확인
if [[ $EUID -ne 0 ]]; then
    log_error "이 스크립트는 root 권한이 필요합니다"
    log_info "다음 명령으로 실행하세요: sudo ${BASH_SOURCE[0]}"
    exit 1
fi

# 1단계: Ubuntu 템플릿 준비
prepare_template() {
    log_step "단계 1/5: Ubuntu 템플릿 준비"
    
    show_template_info
    
    local latest_template=$(pveam available --section system | awk '/ubuntu-22.04-standard/ {print $2}' | sort -V | tail -1)
    local template="local:vztmpl/${latest_template}"
    local template_file="/var/lib/vz/template/cache/${latest_template}"
    
    log_info "선택된 템플릿: $latest_template"
    
    if [[ ! -f "$template_file" ]]; then
        log_info "템플릿 다운로드 중..."
        if pveam update >/dev/null 2>&1 && pveam download local "$latest_template" >/dev/null 2>&1; then
            log_success "템플릿 다운로드 완료: $latest_template"
        else
            log_error "템플릿 다운로드에 실패했습니다"
            exit 1
        fi
    else
        log_info "템플릿이 이미 존재합니다: $latest_template"
    fi
    
    export TEMPLATE="$template"
}

# 2단계: 네트워크 설정 입력
configure_network() {
    log_step "단계 2/5: 네트워크 설정"
    
    local gateway=$(ip route | awk '/default/ {print $3}')
    local current_ip=$(hostname -I | awk '{print $1}')
    local suggested_ip=$(echo $current_ip | awk -F. '{print $1"."$2"."$3"."($4+1)}')
    
    echo
    log_info "네트워크 정보"
    echo -e "${CYAN}  - 현재 호스트 IP: $current_ip${NC}"
    echo -e "${CYAN}  - 게이트웨이: $gateway${NC}"
    echo -e "${CYAN}  - 추천 컨테이너 IP: $suggested_ip${NC}"
    
    echo
    while true; do
        echo -ne "${CYAN}컨테이너에 할당할 IP 주소를 입력하세요 [기본값: $suggested_ip]: ${NC}"
        read user_ip
        user_ip=${user_ip:-$suggested_ip}
        
        # IP 형식 검증
        if validate_ip "$user_ip"; then
            # IP 충돌 검사 추가
            if ping -c 1 -W 1 "$user_ip" >/dev/null 2>&1; then
                log_warn "IP $user_ip가 이미 사용 중입니다. 다른 IP를 선택해주세요"
                continue
            fi
            
            # 게이트웨이와 같은 서브넷인지 검증
            local user_subnet=$(echo $user_ip | awk -F. '{print $1"."$2"."$3}')
            local gateway_subnet=$(echo $gateway | awk -F. '{print $1"."$2"."$3}')
            
            if [[ "$user_subnet" != "$gateway_subnet" ]]; then
                log_warn "입력된 IP($user_ip)가 게이트웨이($gateway)와 다른 서브넷입니다"
                if ! confirm_action "계속 진행하시겠습니까?"; then
                    continue
                fi
            fi
            
            export IP="${user_ip}/24"
            export GATEWAY="$gateway"
            log_success "네트워크 설정 완료: $user_ip (게이트웨이: $gateway)"
            break
        else
            log_error "올바르지 않은 IP 주소 형식입니다. 다시 입력해주세요"
        fi
    done
}

# 3단계: LXC 컨테이너 생성
create_container() {
    log_step "단계 3/5: LXC 컨테이너 생성"
    
    log_info "컨테이너 설정 정보"
    echo -e "${CYAN}  - 컨테이너 ID: $CT_ID${NC}"
    echo -e "${CYAN}  - 호스트명: $HOSTNAME${NC}"
    echo -e "${CYAN}  - 저장소: $STORAGE${NC}"
    echo -e "${CYAN}  - 루트 파일시스템: ${ROOTFS}GB${NC}"
    echo -e "${CYAN}  - 메모리: ${MEMORY_GB}GB${NC}"
    echo -e "${CYAN}  - CPU 코어: $CORES${NC}"
    echo -e "${CYAN}  - CPU 제한: $CPU_LIMIT${NC}"
    echo -e "${CYAN}  - 권한 모드: $([ $UNPRIVILEGED -eq 1 ] && echo "Unprivileged" || echo "Privileged")${NC}"
    echo -e "${CYAN}  - IP 주소: $IP${NC}"
    
    log_info "컨테이너 생성 중..."
    
    if pct create $CT_ID $TEMPLATE \
        --hostname $HOSTNAME \
        --storage $STORAGE \
        --rootfs $ROOTFS \
        --memory $MEMORY \
        --cores $CORES \
        --cpulimit $CPU_LIMIT \
        --net0 name=eth0,bridge=vmbr0,ip=$IP,gw=$GATEWAY \
        --features nesting=1,keyctl=1 \
        --unprivileged $UNPRIVILEGED \
        --description "Docker LXC ${ROOTFS}GB rootfs with Docker" \
        >/dev/null 2>&1; then
        log_success "LXC 컨테이너 생성 완료"
    else
        log_error "컨테이너 생성에 실패했습니다"
        exit 1
    fi
}

# 4단계: RCLONE 저장소 및 LXC 설정
configure_rclone_and_lxc() {
    log_step "단계 4/5: RCLONE 저장소 생성 및 LXC 설정"
    
    local lv_path="/dev/${VG_NAME}/${LV_RCLONE}"
    local lxc_conf="/etc/pve/lxc/${CT_ID}.conf"
    
    # RCLONE LV 생성
    log_info "RCLONE 논리 볼륨 생성 중... (크기: $RCLONE_SIZE)"
    
    if ! lvs "$lv_path" >/dev/null 2>&1; then
        if lvcreate -V "$RCLONE_SIZE" -T "${VG_NAME}/${LV_NAME}" -n "$LV_RCLONE"; then
            log_success "논리 볼륨 생성 완료: $lv_path"
        else
            log_error "논리 볼륨 생성에 실패했습니다"
            exit 1
        fi
        
        if mkfs.ext4 "$lv_path" >/dev/null 2>&1; then
            log_success "ext4 파일시스템 생성 완료"
        else
            log_error "파일시스템 생성에 실패했습니다"
            exit 1
        fi
    else
        log_info "RCLONE 논리 볼륨이 이미 존재합니다: $lv_path"
    fi
    
    # LXC 설정 추가
    log_info "LXC 컨테이너 설정 추가 중..."

    if [ -n "$DIR_BACKUP" ]; then
        cat >> "$lxc_conf" <<EOF
mp0: $lv_path,mp=$MNT_RCLONE
mp1: $DIR_BACKUP,mp=$MNT_BACKUP
lxc.cgroup2.devices.allow: c 10:229 rwm
lxc.mount.entry = /dev/fuse dev/fuse none bind,create=file
lxc.apparmor.profile: unconfined
lxc.cgroup2.devices.allow: a
lxc.cap.drop:
EOF
    else
        cat >> "$lxc_conf" <<EOF
mp0: $lv_path,mp=$MNT_RCLONE
lxc.cgroup2.devices.allow: c 10:229 rwm
lxc.mount.entry = /dev/fuse dev/fuse none bind,create=file
lxc.apparmor.profile: unconfined
lxc.cgroup2.devices.allow: a
lxc.cap.drop:
EOF
    fi
    
    log_success "기본 LXC 설정 추가 완료"
}

# 5단계: GPU 설정
configure_gpu_settings() {
    log_step "단계 5/5: GPU 설정"
    
    show_gpu_options
    
    local lxc_conf="/etc/pve/lxc/${CT_ID}.conf"
    
    if [[ -z "$GPU_CHOICE" ]]; then
        log_info "GPU 설정을 건너뜁니다"
        return 0
    fi
    
    case "$GPU_CHOICE" in
        1|2) # AMD 또는 Intel
            log_info "AMD/Intel GPU 설정 추가 중..."
            cat >> "$lxc_conf" <<EOF
lxc.cgroup2.devices.allow: c 226:* rwm
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
EOF
            log_success "AMD/Intel GPU 설정 완료"
            ;;
        3) # NVIDIA
            log_info "NVIDIA GPU 설정 추가 중..."
            cat >> "$lxc_conf" <<EOF
lxc.cgroup2.devices.allow: c 195:* rwm
lxc.mount.entry: /dev/nvidia0 dev/nvidia0 none bind,optional,create=file
lxc.mount.entry: /dev/nvidiactl dev/nvidiactl none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-uvm dev/nvidia-uvm none bind,optional,create=file
EOF
            log_success "NVIDIA GPU 설정 완료"
            ;;
    esac
}

# 컨테이너 시작 및 초기화
start_and_initialize() {
    log_step "컨테이너 시작 및 초기화 스크립트 실행"
    
    log_info "LXC 컨테이너 시작 중..."
    if pct start $CT_ID >/dev/null 2>&1; then
        log_success "컨테이너 시작 완료"
    else
        log_error "컨테이너 시작에 실패했습니다"
        exit 1
    fi
    
    log_info "컨테이너 부팅 완료까지 대기 중... (5초)"
    sleep 5
    
    log_info "초기화 스크립트 및 설정 파일 업로드 중..."
    
    # 임시 스크립트 디렉토리 생성
    pct exec $CT_ID -- mkdir -p /tmp/scripts
    
    # GPU_CHOICE 환경변수를 lxc.env에 추가 (빈 값도 포함)
    if grep -q "^GPU_CHOICE=" "$SCRIPT_DIR/lxc.env"; then
        # 기존 항목이 있으면 교체
        sed -i "s/^GPU_CHOICE=.*/GPU_CHOICE=\"$GPU_CHOICE\"/" "$SCRIPT_DIR/lxc.env"
        log_info "기존 GPU 설정을 업데이트: ${GPU_CHOICE:-'없음'}"
    else
        # 기존 항목이 없으면 추가
        echo "GPU_CHOICE=\"$GPU_CHOICE\"" >> "$SCRIPT_DIR/lxc.env"
        log_info "GPU 설정을 환경변수 파일에 추가: ${GPU_CHOICE:-'없음'}"
    fi
    
    # 필요한 파일들 업로드
    local files_to_upload=(
        "lxc_init.sh"
        "lxc.env"
        "docker.nfo"
        "docker.sh"
        "caddy_setup.sh"
    )
    
    for file in "${files_to_upload[@]}"; do
        if [[ -f "$SCRIPT_DIR/$file" ]]; then
            if pct push $CT_ID "$SCRIPT_DIR/$file" "/tmp/scripts/$file"; then
                log_success "업로드 완료: $file"
            else
                log_warn "업로드 실패: $file"
            fi
        else
            log_warn "파일을 찾을 수 없습니다: $file"
        fi
    done
    
    log_info "컨테이너 내부 초기화 스크립트 실행 중..."
    if pct exec $CT_ID -- bash /tmp/scripts/lxc_init.sh; then
        log_success "초기화 스크립트 실행 완료"
    else
        log_error "초기화 스크립트 실행에 실패했습니다"
        exit 1
    fi
}

# 메인 실행 함수
main() {
    show_header "Proxmox Ubuntu LXC 컨테이너 자동화"
    
    log_info "시스템 정보"
    echo -e "${CYAN}  - Proxmox 버전: $(pveversion --verbose | head -1)${NC}"
    echo -e "${CYAN}  - 호스트 메모리: $(free -h | awk '/^Mem:/ {print $2}')${NC}"
    echo -e "${CYAN}  - 사용 가능한 저장소: $(pvesm status | grep -v 'Name' | wc -l)개${NC}"
    
    # 1단계: 템플릿 준비
    prepare_template
    
    # 2단계: 네트워크 설정
    configure_network
    
    # 3단계: 컨테이너 생성
    create_container
    
    # 4단계: RCLONE 및 LXC 설정
    configure_rclone_and_lxc
    
    # 5단계: GPU 설정
    configure_gpu_settings
    
    # 6단계: 컨테이너 시작 및 초기화
    start_and_initialize
    
    # 완료 메시지
    echo
    log_success "════════════════════════════════════════════════════════════"
    log_success "  LXC 컨테이너 자동화가 완료되었습니다!"
    log_success "════════════════════════════════════════════════════════════"
    
    echo
    log_info "컨테이너 정보"
    echo -e "${CYAN}  - 컨테이너 ID: $CT_ID${NC}"
    echo -e "${CYAN}  - 호스트명: $HOSTNAME${NC}"
    echo -e "${CYAN}  - IP 주소: $(echo $IP | cut -d'/' -f1)${NC}"
    echo -e "${CYAN}  - 상태: $(pct status $CT_ID)${NC}"
    
    echo
    log_info "접속 방법"
    echo -e "${CYAN}  - 호스트에서: pct enter $CT_ID${NC}"
}

# 스크립트 실행
main
