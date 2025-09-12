#!/bin/bash

##################################################
# Proxmox Disk Partition 자동화
# 요구: parted 기반 (GPT, Linux LVM 또는 Directory 타입 자동 생성)
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
log_success() { echo -e "${GREEN}✅ [$(date '+%Y-%m-%d %H:%M:%S')] $*${NC}" }
log_error() { echo -e "${RED}❌ [$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*${NC}" >&2 }
log_warn() { echo -e "${YELLOW}⚠️ [$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $*${NC}" }
log_info() { echo -e "${CYAN}ℹ️ [$(date '+%Y-%m-%d %H:%M:%S')] $*${NC}" }
log_step() { echo -e "${BLUE}🔄 [$(date '+%Y-%m-%d %H:%M:%S')] $*${NC}" }

# 헤더 출력 함수
show_header() {
    local title="$1"
    echo
    echo -e "${PURPLE}════════════════════════════════════════════════════════════${NC}"
    echo -e "${PURPLE}                  $title${NC}"
    echo -e "${PURPLE}════════════════════════════════════════════════════════════${NC}"
    echo
}

# 디스크 정보 출력 함수
show_disk_info() {
    echo
    log_info "현재 시스템의 디스크 정보"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    pvesm status | while IFS= read -r line; do
        if [[ $line =~ ^Name ]]; then
            echo -e "${YELLOW}  $line${NC}"
        else
            echo -e "${CYAN}  $line${NC}"
        fi
    done
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    # 설정된 백업 경로 표시
    if [[ -n "$BACKUP" ]]; then
        echo
        log_info "설정된 백업 경로: $BACKUP"
    fi
    
    echo
    log_success "스크립트 실행이 완료되었습니다!"
    echo -e "${GREEN}  다음 단계:${NC}"
    echo -e "${CYAN}    1. Proxmox 웹 인터페이스에서 저장소 상태 확인${NC}"
    echo -e "${CYAN}    2. 백업 스케줄 설정 (선택사항)${NC}"
    echo -e "${CYAN}    3. VM/컨테이너 생성 및 테스트${NC}"
}

# 스크립트 실행
main━━━━━━━━━━━━━━━━━━━━━━${NC}"
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT | while IFS= read -r line; do
        if [[ $line =~ ^NAME ]]; then
            echo -e "${YELLOW}  $line${NC}"
        else
            echo -e "${CYAN}  $line${NC}"
        fi
    done
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo
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

# 디스크 입력 검증 함수
validate_disk() {
    local disk="$1"
    
    if [[ -z "$disk" ]]; then
        return 1
    fi
    
    if [[ ! -b "/dev/$disk" ]]; then
        log_error "디스크 /dev/$disk를 찾을 수 없습니다"
        return 1
    fi
    
    return 0
}

# 설정 파일 위치
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/pve.env"

# 설정 파일 로드
load_config "$ENV_FILE"

# 환경변수 기본값 설정
MAIN=${MAIN:-"main"}
DATA=${DATA:-"data"}
DIR_NAME=${DIR_NAME:-"directory"}
VG_MAIN="vg-$MAIN"
LV_MAIN="lv-$MAIN"
LVM_MAIN="lvm-$MAIN"
VG_DATA="vg-$DATA"
LV_DATA="lv-$DATA"
LVM_DATA="lvm-$DATA"

# Root 권한 확인
if [[ $EUID -ne 0 ]]; then
    log_error "이 스크립트는 root 권한이 필요합니다"
    log_info "다음 명령으로 실행하세요: sudo $0"
    exit 1
fi

# 1. 디렉토리 설정 공통 함수
setup_directory_storage() {
    local disk="$1"
    local mount_path="$2"
    local storage_name="$3"
    local label="$4"
    
    log_info "Directory(ext4) 파티션 생성 중..."
    
    # 파티션 생성
    if parted /dev/$disk --script mkpart primary ext4 0% 100%; then
        log_success "파티션 생성 완료"
    else
        log_error "파티션 생성에 실패했습니다"
        return 1
    fi
    
    partprobe /dev/$disk
    udevadm trigger
    sleep 2
    
    # 새 파티션 경로 찾기
    local partition=$(lsblk -nr -o NAME /dev/$disk | grep -v "^$disk$" | tail -n1)
    partition="/dev/$partition"
    
    log_info "파일시스템 생성 및 마운트 설정 중..."
    
    # 마운트 디렉토리 생성
    mkdir -p "$mount_path" >/dev/null 2>&1
    
    # ext4 파일시스템 생성 (레이블 포함)
    if mkfs.ext4 -L "$label" "$partition" >/dev/null 2>&1; then
        log_success "ext4 파일시스템 생성 완료 (레이블: $label)"
    else
        log_error "파일시스템 생성에 실패했습니다"
        return 1
    fi
    
    # UUID 획득
    local uuid=$(blkid -s UUID -o value "$partition")
    if [[ -z "$uuid" ]]; then
        log_error "UUID를 찾을 수 없습니다: $partition"
        return 1
    fi
    
    # fstab 설정
    if ! grep -qs "UUID=$uuid $mount_path" /etc/fstab; then
        echo "UUID=$uuid $mount_path ext4 defaults 0 2" >> /etc/fstab
        log_success "fstab 설정 완료"
    else
        log_info "이미 fstab에 등록되어 있습니다"
    fi
    
    # 마운트
    systemctl daemon-reload
    if mount -a; then
        log_success "디렉토리 마운트 완료: $mount_path"
    else
        log_error "마운트에 실패했습니다"
        return 1
    fi
    
    # Proxmox 저장소 등록
    if pvesm add dir "$storage_name" --path "$mount_path" --content backup,iso,vztmpl; then
        log_success "Proxmox Directory 저장소 등록 완료: $storage_name"
    else
        log_warn "Proxmox 저장소 등록에 실패했지만 마운트는 완료되었습니다"
    fi
    
    echo
    log_success "Directory 설정 완료"
    echo -e "${CYAN}  - 파티션: $partition${NC}"
    echo -e "${CYAN}  - UUID: $uuid${NC}"
    echo -e "${CYAN}  - 마운트 포인트: $mount_path${NC}"
    echo -e "${CYAN}  - 레이블: $label${NC}"
    echo -e "${CYAN}  - Proxmox 저장소: $storage_name${NC}"
}

# 메인 디스크 설정 함수
setup_main_disk() {
    log_step "단계 1/5: 메인 디스크 설정 (Linux LVM 타입)"
    
    show_disk_info
    
    echo -ne "${CYAN}메인 디스크명을 입력하세요 (예: nvme0n1, sda) [Enter로 건너뛰기]: ${NC}"
    read main_disk
    
    if [[ -z "$main_disk" ]]; then
        log_info "메인 디스크 설정을 건너뜁니다"
        return 0
    fi
    
    if ! validate_disk "$main_disk"; then
        return 1
    fi
    
    # 기존 파티션 확인 및 새 파티션 번호 계산
    local last_part_num=$(lsblk /dev/$main_disk | awk '/part/ {print $1}' | tail -n1 | grep -oP "${main_disk}p\K[0-9]+")
    
    if [[ -z "$last_part_num" ]]; then
        log_error "파티션 번호를 찾을 수 없습니다"
        return 1
    fi
    
    local part_num=$((last_part_num + 1))
    local partition="/dev/${main_disk}p${part_num}"
    
    # 여유 공간 계산
    local free_space_info=$(parted /dev/$main_disk unit MiB print free | awk '/Free Space/ {print $1, $2}' | tail -1)
    local start_pos=$(echo $free_space_info | awk '{print $1}' | sed 's/MiB//')
    local end_pos=$(echo $free_space_info | awk '{print $2}' | sed 's/MiB//')
    
    if [[ -z "$start_pos" ]] || [[ -z "$end_pos" ]]; then
        log_error "여유 공간을 찾을 수 없습니다"
        return 1
    fi
    
    start_pos=$((start_pos + 1))
    end_pos=$((end_pos - 1))
    
    log_info "새 파티션 정보:"
    echo -e "${CYAN}  - 파티션: $partition${NC}"
    echo -e "${CYAN}  - 시작 위치: ${start_pos} MiB${NC}"
    echo -e "${CYAN}  - 종료 위치: ${end_pos} MiB${NC}"
    echo -e "${CYAN}  - 크기: $((end_pos - start_pos)) MiB${NC}"
    
    if ! confirm_action "위 설정으로 파티션을 생성하시겠습니까?"; then
        log_info "메인 디스크 설정을 취소합니다"
        return 0
    fi
    
    log_info "파티션 생성 중..."
    
    # 파티션 생성
    if parted /dev/$main_disk --script unit MiB mkpart primary "${start_pos}MiB" "${end_pos}MiB"; then
        log_success "파티션 생성 완료: $partition"
    else
        log_error "파티션 생성에 실패했습니다"
        return 1
    fi
    
    # LVM 플래그 설정
    if parted /dev/$main_disk --script set $part_num lvm on; then
        log_success "LVM 플래그 설정 완료"
    else
        log_error "LVM 플래그 설정에 실패했습니다"
        return 1
    fi
    
    # 시스템에 변경사항 반영
    partprobe /dev/$main_disk
    udevadm trigger
    sleep 2
    
    # LVM 구조 생성
    log_info "LVM 구조 생성 중..."
    
    if pvcreate "$partition"; then
        log_success "Physical Volume 생성 완료"
    else
        log_error "Physical Volume 생성에 실패했습니다"
        return 1
    fi
    
    if vgcreate $VG_MAIN "$partition"; then
        log_success "Volume Group 생성 완료: $VG_MAIN"
    else
        log_error "Volume Group 생성에 실패했습니다"
        return 1
    fi
    
    if lvcreate -l 100%FREE -T $VG_MAIN/$LV_MAIN; then
        log_success "Thin Pool 생성 완료: $VG_MAIN/$LV_MAIN"
    else
        log_error "Thin Pool 생성에 실패했습니다"
        return 1
    fi
    
    # Proxmox 저장소 등록
    if pvesm add lvmthin $LVM_MAIN --vgname $VG_MAIN --thinpool $LV_MAIN --content images,rootdir; then
        log_success "Proxmox LVM-Thin 저장소 등록 완료: $LVM_MAIN"
    else
        log_warn "Proxmox 저장소 등록에 실패했지만 LVM 구조는 생성되었습니다"
    fi
    
    echo
    log_success "메인 디스크 설정 완료"
    echo -e "${CYAN}  - Physical Volume: $partition${NC}"
    echo -e "${CYAN}  - Volume Group: $VG_MAIN${NC}"
    echo -e "${CYAN}  - Thin Pool: $VG_MAIN/$LV_MAIN${NC}"
    echo -e "${CYAN}  - Proxmox 저장소: $LVM_MAIN${NC}"
}

# LVM 디스크 설정
setup_lvm_disk() {
    local disk="$1"
    
    log_info "Linux LVM 파티션 생성 중..."
    
    # 파티션 생성
    if parted /dev/$disk --script mkpart primary 0% 100%; then
        log_success "파티션 생성 완료"
    else
        log_error "파티션 생성에 실패했습니다"
        return 1
    fi
    
    if parted /dev/$disk --script set 1 lvm on; then
        log_success "LVM 플래그 설정 완료"
    else
        log_error "LVM 플래그 설정에 실패했습니다"
        return 1
    fi
    
    partprobe /dev/$disk
    udevadm trigger
    sleep 2
    
    # 새 파티션 경로 찾기
    local partition=$(lsblk -nr -o NAME /dev/$disk | grep -v "^$disk$" | tail -n1)
    partition="/dev/$partition"
    
    log_info "LVM 구조 생성 중..."
    
    # Physical Volume 생성
    if pvcreate --yes "$partition"; then
        log_success "Physical Volume 생성 완료: $partition"
    else
        log_error "Physical Volume 생성에 실패했습니다"
        return 1
    fi
    
    # Volume Group 생성
    if vgcreate $VG_DATA "$partition"; then
        log_success "Volume Group 생성 완료: $VG_DATA"
    else
        log_error "Volume Group 생성에 실패했습니다"
        return 1
    fi
    
    # Thin Pool 생성
    if lvcreate -l 100%FREE -T $VG_DATA/$LV_DATA; then
        log_success "Thin Pool 생성 완료: $VG_DATA/$LV_DATA"
    else
        log_error "Thin Pool 생성에 실패했습니다"
        return 1
    fi
    
    # Proxmox 저장소 등록
    if pvesm add lvmthin $LVM_DATA --vgname $VG_DATA --thinpool $LV_DATA --content images,rootdir; then
        log_success "Proxmox LVM-Thin 저장소 등록 완료: $LVM_DATA"
    else
        log_warn "Proxmox 저장소 등록에 실패했지만 LVM 구조는 생성되었습니다"
    fi
    
    echo
    log_success "보조 디스크 LVM 설정 완료"
    echo -e "${CYAN}  - Physical Volume: $partition${NC}"
    echo -e "${CYAN}  - Volume Group: $VG_DATA${NC}"
    echo -e "${CYAN}  - Thin Pool: $VG_DATA/$LV_DATA${NC}"
    echo -e "${CYAN}  - Proxmox 저장소: $LVM_DATA${NC}"
}

# 보조 디스크 설정 함수
setup_secondary_disk() {
    log_step "단계 2/5: 보조/백업 디스크 설정"
    
    show_disk_info
    
    echo -ne "${CYAN}보조/백업 디스크명을 입력하세요 (예: nvme1n1, sdb) [Enter로 건너뛰기]: ${NC}"
    read secondary_disk
    
    if [[ -z "$secondary_disk" ]]; then
        log_info "보조/백업 디스크 설정을 건너뜁니다"
        return 0
    fi
    
    if ! validate_disk "$secondary_disk"; then
        return 1
    fi
    
    echo
    log_info "보조/백업 디스크 파티션 유형을 선택하세요:"
    echo -e "${CYAN}  1) Linux LVM (컨테이너/VM 저장용)${NC}"
    echo -e "${CYAN}  2) Directory (백업/ISO/템플릿 저장용)${NC}"
    
    echo -ne "${CYAN}선택 [1/2]: ${NC}"
    read secondary_type
    
    case "$secondary_type" in
        1|2)
            ;;
        *)
            log_error "잘못된 선택입니다"
            return 1
            ;;
    esac
    
    log_warn "⚠️  주의: 디스크 /dev/$secondary_disk의 모든 데이터가 삭제됩니다!"
    
    if ! confirm_action "계속 진행하시겠습니까?"; then
        log_info "보조 디스크 설정을 취소합니다"
        return 0
    fi
    
    log_info "디스크 초기화 중..."
    
    # 기존 시그니처 제거 및 파티션 테이블 생성
    wipefs -a /dev/$secondary_disk >/dev/null 2>&1
    parted /dev/$secondary_disk --script mklabel gpt
    
    if [[ "$secondary_type" == "1" ]]; then
        setup_lvm_disk "$secondary_disk"
    else
        # 2. 보조디스크 설정시 디렉토리인 경우 공통 함수 사용
        setup_directory_storage "$secondary_disk" "/mnt/directory" "directory" "DIRECTORY"
    fi
}

# 3. USB 장치 추가 설정 함수
setup_usb_devices() {
    log_step "단계 3/5: USB 장치 추가 설정"
    
    # USB 장치 확인
    show_disk_info
    
    local usb_devices=$(lsblk -o NAME,TRAN | grep usb | awk '{print $1}' | sed 's/├─//g' | sed 's/└─//g' | grep -E '^sd[a-z]$')
    
    if [[ -z "$usb_devices" ]]; then
        log_warn "USB 저장 장치를 찾을 수 없습니다"
        if ! confirm_action "USB 장치를 수동으로 추가하시겠습니까?"; then
            log_info "USB 장치 설정을 건너뜁니다"
            return 0
        fi
        
        echo -ne "${CYAN}USB 디스크명을 입력하세요 (예: sdb, sdc): ${NC}"
        read manual_usb_disk
        
        if [[ -n "$manual_usb_disk" ]] && validate_disk "$manual_usb_disk"; then
            usb_devices="$manual_usb_disk"
        else
            log_error "올바른 USB 디스크명을 입력하지 않았습니다"
            return 1
        fi
    else
        log_success "다음 USB 장치들이 감지되었습니다:"
        echo "$usb_devices" | while IFS= read -r line; do
            echo -e "${GREEN}  - /dev/$line${NC}"
        done
        echo
        
        if ! confirm_action "감지된 USB 장치들을 설정하시겠습니까?"; then
            log_info "USB 장치 설정을 건너뜁니다"
            return 0
        fi
    fi
    
    local usb_count=1
    
    # 각 USB 장치를 순서대로 설정
    echo "$usb_devices" | while IFS= read -r usb_disk; do
        if [[ -z "$usb_disk" ]]; then
            continue
        fi
        
        log_info "USB 장치 /dev/$usb_disk 설정 중..."
        
        local mount_path="/mnt/usb"
        local storage_name="usb"
        
        # 여러 USB 장치인 경우 번호 추가
        if [[ $usb_count -gt 1 ]]; then
            mount_path="/mnt/usb${usb_count}"
            storage_name="usb${usb_count}"
        fi
        
        log_warn "⚠️  주의: USB 디스크 /dev/$usb_disk의 모든 데이터가 삭제됩니다!"
        
        if confirm_action "USB 디스크 /dev/$usb_disk를 $mount_path에 설정하시겠습니까?"; then
            # 기존 시그니처 제거 및 파티션 테이블 생성
            wipefs -a /dev/$usb_disk >/dev/null 2>&1
            parted /dev/$usb_disk --script mklabel gpt
            
            # 공통 함수 사용하여 디렉토리 설정
            setup_directory_storage "$usb_disk" "$mount_path" "$storage_name" "USB-${usb_count}"
        else
            log_info "USB 디스크 /dev/$usb_disk 설정을 건너뜁니다"
        fi
        
        ((usb_count++))
    done
    
    log_success "USB 장치 설정 완료"
}

# 4. Proxmox 백업공간 선택 함수
setup_backup_selection() {
    log_step "단계 4/5: Proxmox 백업공간 선택"
    
    echo
    log_info "현재 설정된 저장소 목록:"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    local available_storages=()
    local storage_paths=()
    local counter=1
    
    # Directory 타입 저장소만 필터링
    while IFS= read -r line; do
        if [[ $line =~ ^Name ]]; then
            continue
        fi
        
        local storage_name=$(echo "$line" | awk '{print $1}')
        local storage_type=$(echo "$line" | awk '{print $2}')
        
        if [[ "$storage_type" == "dir" ]]; then
            local storage_path=$(pvesm path "$storage_name" 2>/dev/null | head -1 | cut -d'/' -f1-3)
            if [[ -n "$storage_path" ]]; then
                available_storages+=("$storage_name")
                storage_paths+=("$storage_path")
                echo -e "${GREEN}  $counter) $storage_name ($storage_path)${NC}"
                ((counter++))
            fi
        fi
    done < <(pvesm status)
    
    echo -e "${CYAN}  $counter) 백업 설정 안함${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    if [[ ${#available_storages[@]} -eq 0 ]]; then
        log_warn "백업 가능한 저장소가 없습니다"
        return 0
    fi
    
    echo -ne "${CYAN}백업 저장소를 선택하세요 [1-$counter]: ${NC}"
    read backup_choice
    
    if [[ "$backup_choice" -ge 1 ]] && [[ "$backup_choice" -lt $counter ]]; then
        local selected_index=$((backup_choice - 1))
        local selected_storage="${available_storages[$selected_index]}"
        local selected_path="${storage_paths[$selected_index]}"
        
        log_success "선택된 백업 저장소: $selected_storage ($selected_path)"
        
        # pve.env 파일에 BACKUP 변수 추가/업데이트
        if [[ -f "$ENV_FILE" ]]; then
            # 기존 BACKUP 변수 제거
            sed -i '/^BACKUP=/d' "$ENV_FILE"
        fi
        
        # 새 BACKUP 변수 추가
        echo "BACKUP=\"$selected_path\"" >> "$ENV_FILE"
        log_success "pve.env 파일에 BACKUP 변수가 저장되었습니다: $selected_path"
        
    elif [[ "$backup_choice" -eq $counter ]]; then
        log_info "백업 설정을 하지 않습니다"
    else
        log_warn "잘못된 선택입니다. 백업 설정을 건너뜁니다"
    fi
}

# 메인 실행 함수
main() {
    show_header "Proxmox Disk Partition 자동화"
    
    log_info "시스템 정보"
    echo -e "${CYAN}  - 호스트명: $(hostname)${NC}"
    echo -e "${CYAN}  - Proxmox 버전: $(pveversion --verbose | head -1)${NC}"
    echo -e "${CYAN}  - 현재 저장소: $(pvesm status | grep -v 'Name' | wc -l)개${NC}"
    
    # 기존 저장소 정보 출력
    echo
    log_info "현재 Proxmox 저장소 목록"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    pvesm status | while IFS= read -r line; do
        if [[ $line =~ ^Name ]]; then
            echo -e "${YELLOW}  $line${NC}"
        else
            echo -e "${CYAN}  $line${NC}"
        fi
    done
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    # 1단계: 메인 디스크 설정
    setup_main_disk
    
    echo
    # 2단계: 보조 디스크 설정
    setup_secondary_disk
    
    echo
    # 3단계: USB 장치 추가 설정
    setup_usb_devices
    
    echo
    # 4단계: Proxmox 백업공간 선택
    setup_backup_selection
    
    # 5단계: 종료
    echo
    log_success "════════════════════════════════════════════════════════════"
    log_success "  모든 설정이 완료되었습니다!"
    log_success "════════════════════════════════════════════════════════════"
    
    echo
    log_info "최종 파티션 상태"
    show_disk_info
    
    echo
    log_info "최종 Proxmox 저장소 상태"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    # 설정된 백업 경로 표시
    if [[ -n "$BACKUP" ]]; then
        echo
        log_info "설정된 백업 경로: $BACKUP"
    fi
    
    echo
    log_success "스크립트 실행이 완료되었습니다!"
    echo -e "${GREEN}  다음 단계:${NC}"
    echo -e "${CYAN}    1. Proxmox 웹 인터페이스에서 저장소 상태 확인${NC}"
    echo -e "${CYAN}    2. 백업 스케줄 설정 (선택사항)${NC}"
echo -e "${CYAN}    3. VM/컨테이너 생성 및 디스크 테스트${NC}"
}

# 스크립트 실행
main
