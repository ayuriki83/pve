#!/bin/bash

##################################################
# Synology DSM VM 설치/복구 스크립트
# - 단일 디스크 전체 패스스루 (OS + 데이터)
# - Bootloader 선택 및 자동 다운로드 포함
##################################################

#set -e
set -euo pipefail

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

# Step 1. 디스크 선택
select_disk() {
  log_step "Step 1. DSM 패스스루 디스크 선택"

  # 디스크 목록 가져오기
  mapfile -t disks < <(ls -1 /dev/disk/by-id/ | grep -E "ata|nvme|scsi")

  if [ ${#disks[@]} -eq 0 ]; then
    log_error "사용 가능한 디스크를 찾을 수 없습니다."
    exit 1
  fi

  echo
  echo "사용 가능한 디스크 목록:"
  for i in "${!disks[@]}"; do
    printf "  %d) %s -> %s\n" $((i+1)) "${disks[$i]}" "$(readlink -f /dev/disk/by-id/${disks[$i]})"
  done
  echo

  while true; do
    read -p "패스스루로 사용할 디스크 번호를 입력하세요 [1-${#disks[@]}]: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#disks[@]} )); then
      DISKID="${disks[$((choice-1))]}"
      DISKPATH="/dev/disk/by-id/$DISKID"
      break
    else
      log_warn "잘못된 입력입니다. 다시 시도하세요."
    fi
  done

  log_info "선택된 디스크: $DISKPATH"
}

# Step 2. 부트로더 선택 및 다운로드
select_bootloader() {
  log_step "Step 2. 부트로더 선택"
  echo "1) m-shell"
  echo "2) RR"
  echo "3) xTCRP"
  read -p "부트로더를 선택하세요 [1-3]: " IMAGE_CHOICE

  case $IMAGE_CHOICE in
    1)
      IMAGE_NAME="m-shell"
      LATESTURL=$(curl -sL -w %{url_effective} -o /dev/null "https://github.com/PeterSuh-Q3/tinycore-redpill/releases/latest")
      TAG="${LATESTURL##*/}"
      IMG_URL="https://github.com/PeterSuh-Q3/tinycore-redpill/releases/download/${TAG}/tinycore-redpill.${TAG}.m-shell.img.gz"
      ;;
    2)
      IMAGE_NAME="RR"
      LATESTURL=$(curl -sL -w %{url_effective} -o /dev/null "https://github.com/RROrg/rr/releases/latest")
      TAG="${LATESTURL##*/}"
      IMG_URL="https://github.com/RROrg/rr/releases/download/${TAG}/rr-${TAG}.img.zip"
      ;;
    3)
      IMAGE_NAME="xTCRP"
      LATESTURL=$(curl -sL -w %{url_effective} -o /dev/null "https://github.com/PeterSuh-Q3/tinycore-redpill/releases/latest")
      TAG="${LATESTURL##*/}"
      IMG_URL="https://github.com/PeterSuh-Q3/tinycore-redpill/releases/download/${TAG}/tinycore-redpill.${TAG}.xtcrp.img.gz"
      ;;
    *)
      log_error "잘못된 선택입니다. 종료합니다."
      exit 1
      ;;
  esac

  IMG_PATH="${BOOTLOADER_DIR}/${IMAGE_NAME}-${VMID}.img"
  mkdir -p "$BOOTLOADER_DIR"

  log_step "${IMAGE_NAME} 부트로더 다운로드 및 준비"
  if [[ "$IMG_URL" == *.zip ]]; then
    # unzip 활용으로 체크
    command -v unzip >/dev/null || { log_warn "unzip 미설치, 설치 진행"; apt-get update && apt-get install -y unzip; }
  
    curl -kL# "$IMG_URL" -o "${IMG_PATH}.zip"
    unzip -o "${IMG_PATH}.zip" -d "$BOOTLOADER_DIR"
    if [ -f "${BOOTLOADER_DIR}/rr.img" ]; then
      mv "${BOOTLOADER_DIR}/rr.img" "$IMG_PATH"
    fi
    rm -f "${IMG_PATH}.zip"
  else
    curl -kL# "$IMG_URL" -o "${IMG_PATH}.gz"
    gunzip -f "${IMG_PATH}.gz"
  fi

  if [ ! -f "$IMG_PATH" ]; then
    log_error "다운로드/추출 후 .img 파일을 찾을 수 없습니다."
    exit 1
  fi
  log_info "부트로더 준비 완료: $IMG_PATH"
}

# 설정 파일 위치
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/synology.env"

# 설정 파일 로드
load_config "$ENV_FILE"

# 환경변수 기본값 설정
VM_ID=${VM_ID:-100}
VM_NAME=${VM_NAME:-"Synology"}
MEMORY_GB=${MEMORY_GB:-8}
MEMORY=$((MEMORY_GB * 1024))
CORES=${CORES:-4}
SOCKETS=${SOCKETS:-1}
BRIDGE="vmbr0"
BOOTLOADER_DIR="/var/lib/vz/template/iso"

# Step 3. VM 생성
create_vm() {
  log_step "Step 3. VM(${VM_ID}) 생성"
  qm create $VM_ID \
    --name $VM_NAME \
    --memory $MEMORY \
    --cores $CORES \
    --sockets $SOCKETS \
    --cpu host \
    --net0 virtio,bridge=$BRIDGE \
    --bios seabios
  log_info "VM 생성 완료"
}

# Step 4. 디스크/부트로더 연결
attach_disks() {
  log_step "Step 4. DSM 디스크 패스스루 연결"
  qm set $VMID --sata0 $DISKPATH
  log_info "패스스루 디스크 연결 완료: $DISKPATH"

  log_step "Step 4-1. 부트로더 연결"
  qm set $VMID --args "-drive if=none,id=synoboot,format=raw,file=$IMG_PATH -device qemu-xhci,id=xhci -device usb-storage,bus=xhci.0,drive=synoboot,bootindex=0"
  log_info "부트로더 연결 완료"
}

# Step 5. 부팅 순서 설정
set_boot_order() {
  log_step "Step 5. 부팅 순서 설정"
  qm set $VMID --boot order=synoboot,sata0
  log_info "부팅 순서 설정 완료"
}

# Step 6. 최종 확인
final_check() {
  log_step "Step 6. 최종 VM 설정 확인"
  qm config $VMID
  log_info "Synology DSM VM(${VMID}) 준비 완료"
  log_info "'qm start $VMID' 실행 후, 브라우저에서 find.synology.com 으로 접속하세요"
}

# 메인 실행
main() {
  show_header "Syonolgy 설치 자동화 with passthrough"
  
  select_disk
  select_bootloader
  create_vm
  attach_disks
  set_boot_order
  final_check
}

main
