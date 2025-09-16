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

select_bootloader() {
  log_step "Step 1. 부트로더 선택"
  echo "1) RR"
  echo "2) m-shell"
  echo "3) xTCRP"
  read -p "부트로더 선택 [1-3]: " IMAGE_CHOICE
  case $IMAGE_CHOICE in
    1)
      IMAGE_NAME="RR"
      LATESTURL=$(curl -sL -w %{url_effective} -o /dev/null "https://github.com/RROrg/rr/releases/latest")
      TAG="${LATESTURL##*/}"
      IMG_URL="https://github.com/RROrg/rr/releases/download/${TAG}/rr-${TAG}.img.zip"
      ;;
    2)
      IMAGE_NAME="m-shell"
      LATESTURL=$(curl -sL -w %{url_effective} -o /dev/null "https://github.com/PeterSuh-Q3/tinycore-redpill/releases/latest")
      TAG="${LATESTURL##*/}"
      IMG_URL="https://github.com/PeterSuh-Q3/tinycore-redpill/releases/download/${TAG}/tinycore-redpill.${TAG}.m-shell.img.gz"
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

  IMG_PATH="${BOOTLOADER_DIR}/${IMAGE_NAME}-${VM_ID}.img"
  mkdir -p "$BOOTLOADER_DIR"

  log_step "${IMAGE_NAME} 부트로더 다운로드 및 준비"
  if [[ "$IMG_URL" == *.zip ]]; then
    # unzip 활용으로 체크
    command -v unzip >/dev/null || { log_warn "unzip 미설치, 설치 진행"; apt-get update && apt-get install -y unzip; }
  
    curl -kL# "$IMG_URL" -o "${IMG_PATH}.zip"
    unzip -o "${IMG_PATH}.zip" -d "$BOOTLOADER_DIR" &> /dev/null
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
  log_success "부트로더 준비 완료: $IMG_PATH"
}

select_disk() {
  log_step "Step 2. DSM 패스스루 디스크 선택"
  # by-id 파티션 제외, 실제 device 필터
  mapfile -t raw_disks < <(ls -1 /dev/disk/by-id/ | grep -E 'ata|nvme|scsi' | grep -v 'part[0-9]$' | grep -v '^nvme-eui\.')
  if [ ${#raw_disks[@]} -eq 0 ]; then
    mapfile -t raw_disks < <(ls -1 /dev/disk/by-id/ | grep -E 'ata|nvme|scsi' | grep -v 'part[0-9]$')
  fi
  disklist=()
  seen=()
  for id in "${raw_disks[@]}"; do
    dev=$(readlink -f /dev/disk/by-id/$id)
    if [ -b "$dev" ] && [[ "$dev" =~ ^/dev/(sd[a-z]|nvme[0-9]n[0-9])$ ]]; then
      if [[ ! " ${seen[*]} " =~ " ${dev} " ]]; then
        disklist+=("$id")
        seen+=("$dev")
      fi
    fi
  done
  if [ ${#disklist[@]} -eq 0 ]; then
    log_error "사용 가능한 디스크가 없습니다."
    exit 1
  fi
  for i in "${!disklist[@]}"; do
    num=$((i+1))
    dev=$(readlink -f /dev/disk/by-id/${disklist[$i]})
    size=$(lsblk -dnb -o SIZE "$dev" 2>/dev/null | numfmt --to=iec-i --suffix=B 2>/dev/null || echo "unknown")
    echo " $num) ${disklist[$i]} -> $dev ($size)"
  done
  while true; do
    read -p "패스스루 디스크 번호 선택 [1-${#disklist[@]}]: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#disklist[@]} )); then
      DISKID="${disklist[$((choice-1))]}"
      DISKPATH="/dev/disk/by-id/$DISKID"
      break
    else
      log_warn "잘못된 선택, 재입력"
    fi
  done
  log_info "선택된 디스크: $DISKPATH"
}

select_usb() {
  log_step "Step 3. USB 저장장치 선택 (없으면 엔터)"
  mapfile -t usb_ids < <(ls -1 /dev/disk/by-id/ | grep -Ei "usb" | grep -v part)
  if [ ${#usb_ids[@]} -eq 0 ]; then
    echo "USB 장치가 없습니다."
    USB_PATH=""
    return 0
  fi
  for i in "${!usb_ids[@]}"; do
    num=$((i+1))
    dev=$(readlink -f /dev/disk/by-id/${usb_ids[$i]})
    echo " $num) ${usb_ids[$i]} -> $dev"
  done
  read -p "USB 저장장치 번호 선택 [1-${#usb_ids[@]}] (선택 안하면 엔터): " choice
  if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#usb_ids[@]} )); then
    USB_PATH="/dev/disk/by-id/${usb_ids[$((choice-1))]}"
    log_info "선택된 USB 저장장치: $USB_PATH"
  else
    USB_PATH=""
    log_info "USB 저장장치를 추가하지 않음"
  fi
}

create_vm_and_set() {
  log_step "Step 4. VM 생성 및 구성"

  qm create $VM_ID \
    --name $VM_NAME \
    --memory $MEMORY \
    --cores $CORES \
    --sockets $SOCKETS \
    --cpu host \
    --net0 virtio,bridge=$BRIDGE

  # 디스크, 부트로더, USB args 조합
  BOOTLOADER_ARGS="-drive if=none,id=synoboot,format=raw,file=$IMG_PATH -device qemu-xhci,id=xhci -device usb-storage,bus=xhci.0,drive=synoboot,bootindex=0"
  SATA_ARGS="--sata0 $DISKPATH"
  if [ -n "$USB_PATH" ]; then
    USB_ARGS="-drive if=none,id=usbdisk,format=raw,file=$USB_PATH -device usb-storage,bus=xhci.0,drive=usbdisk"
  else
    USB_ARGS=""
  fi

  qm set $VM_ID $SATA_ARGS --args "$BOOTLOADER_ARGS $USB_ARGS" &> /dev/null
  log_info "VM 생성 및 연결 완료"
}

final_check() {
  log_step "Step 5. 최종 VM 설정 확인"
  qm config $VM_ID
  log_info "Synology DSM VM(${VM_ID}) 준비 완료"
  log_info "'qm start $VM_ID' 실행 후 find.synology.com 에 접속하세요"
}

main() {
  show_header "Synology 설치 자동화 with passthrough"

  select_bootloader
  select_disk
  select_usb
  create_vm_and_set
  final_check
}

main
