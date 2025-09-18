#!/bin/bash

##################################################
# 도커 백업 세팅
##################################################

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

# 공통 변수
NFS_IP=""
NFS_SHARE=""
MOUNTPOINT=""
BACKUP_SCRIPT="/docker/docker-backup.sh"

# 헤더 출력 함수
show_header() {
    local title="$1"
    echo
    echo -e "${PURPLE}════════════════════════════════════════════════════════════${NC}"
    echo -e "${PURPLE}   $title${NC}"
    echo -e "${PURPLE}════════════════════════════════════════════════════════════${NC}"
    echo
}

# STEP A. NFS 입력 받기
get_user_input_nfs() {
  log_step "NFS 백업 설정"

  read -p "NFS 서버 IP 입력: " NFS_IP
  read -p "NFS 공유 폴더 이름 (예: docker-backup): " NFS_SHARE
  read -p "마운트 경로 (기본값: /mnt/nfs): " MOUNTPOINT
  MOUNTPOINT=${MOUNTPOINT:-/mnt/nfs}

  export NFS_IP NFS_SHARE MOUNTPOINT
  log_info "입력값 → IP: $NFS_IP, SHARE: $NFS_SHARE, MOUNT: $MOUNTPOINT"
}

# STEP B. MP 경로 선택
get_user_input_mp() {
  log_step "MP(마운트포인트) 백업 설정"

  # /mnt/ 경로 중 ext4 만 필터링
  mapfile -t mp_list < <(mount | awk '$3 ~ /^\/mnt\// && $5=="ext4" {print $3}')

  if [ ${#mp_list[@]} -eq 0 ]; then
    log_error "ext4 타입의 /mnt/* 마운트포인트를 찾을 수 없습니다."
    exit 1
  fi

  echo "사용 가능한 마운트포인트 목록:"
  for i in "${!mp_list[@]}"; do
    printf "  %d) %s\n" $((i+1)) "${mp_list[$i]}"
  done
  echo

  while true; do
    read -p "백업에 사용할 마운트포인트 번호 선택 [1-${#mp_list[@]}]: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#mp_list[@]} )); then
      MOUNTPOINT="${mp_list[$((choice-1))]}"
      break
    else
      log_error "잘못된 입력입니다. 다시 시도하세요."
    fi
  done

  log_info "선택된 마운트 경로: $MOUNTPOINT"
}

prepare_mountpoint() {
  log_step "마운트 경로 준비"
  if [ ! -d "$MOUNTPOINT" ]; then
    sudo mkdir -p "$MOUNTPOINT"
    log_info "마운트 경로 생성됨: $MOUNTPOINT"
  else
    log_info "마운트 경로 이미 존재: $MOUNTPOINT"
  fi
}

update_fstab() {
  log_step "fstab 등록"
  FSTAB_LINE="${NFS_IP}:/volume1/${NFS_SHARE} ${MOUNTPOINT} nfs4 rw,noatime,nodiratime,rsize=65536,wsize=65536,nconnect=8 0 0"

  if grep -q "$MOUNTPOINT" /etc/fstab; then
    log_info "fstab에 이미 등록됨: $MOUNTPOINT"
  else
    echo "$FSTAB_LINE" | sudo tee -a /etc/fstab
    log_info "fstab에 등록 완료"
  fi
}

mount_nfs() {
  log_step "NFS 마운트 적용"
  sudo mount -a
  if findmnt -t nfs4 "$MOUNTPOINT" > /dev/null; then
    log_info "NFS 마운트 성공: $MOUNTPOINT"
  else
    log_error "NFS 마운트 실패"
    exit 1
  fi
}

generate_backup_script() {
  log_step "백업 스크립트 생성"
  sudo mkdir -p /docker

  cat > "$BACKUP_SCRIPT" <<EOF
#!/bin/bash
SRC_DIRS="/docker"
SRC_FILES=(
  "/docker/rclone-after-service.sh"
)
EXCLUDE_DIRS=("core")
DEST_BASE="$MOUNTPOINT/docker"

SCRIPT_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
LOGFILE="\$SCRIPT_DIR/docker-backup.log"

# 로그 로테이션 (7일 지난 로그 삭제)
find "\$SCRIPT_DIR" -maxdepth 1 -name "docker-backup.log.*" -type f -mtime +7 -exec rm -f {} \;
if [ -f "\$LOGFILE" ]; then
  mv "\$LOGFILE" "\$LOGFILE.\$(date +%Y%m%d)"
fi

echo "복사 작업 시작: \$(date)" | tee -a "\$LOGFILE"

for SRC in "\$SRC_DIRS"/*/; do
  BASENAME=\$(basename "\$SRC")
  [[ ! -d "\$SRC" ]] && continue
  skip=0
  for exclude in "\${EXCLUDE_DIRS[@]}"; do
    [[ "\$BASENAME" == "\$exclude" ]] && skip=1 && break
  done
  [[ "\$skip" == 1 ]] && continue

  DEST="\${DEST_BASE}/\${BASENAME}"
  echo "[\$(date)] 복사 시작: \$SRC -> \$DEST" | tee -a "\$LOGFILE"
  rsync -aW --delete --info=progress2 --mkpath "\$SRC" "\$DEST/"
done

for FILE in "\${SRC_FILES[@]}"; do
  BASENAME=\$(basename "\$FILE")
  DEST="\$DEST_BASE/\$BASENAME"
  echo "[\$(date)] 파일 복사: \$FILE -> \$DEST" | tee -a "\$LOGFILE"
  cp -p "\$FILE" "\$DEST"
done

echo "복사 작업 종료: \$(date)" | tee -a "\$LOGFILE"
EOF

  chmod +x "$BACKUP_SCRIPT"
  log_info "백업 스크립트 생성 완료: $BACKUP_SCRIPT"
}

register_cron() {
  log_step "크론 등록"
  read -p "백업 실행 주기 (기본값: 매일 09:00 → '0 9 * * *'): " CRON_EXPR
  CRON_EXPR=${CRON_EXPR:-"0 9 * * *"}
  
  # 백업 스크립트 파일 존재 및 권한 확인
  if [ ! -f "$BACKUP_SCRIPT" ]; then
    log_error "백업 스크립트 파일이 없습니다: $BACKUP_SCRIPT"
    return 1
  fi
  
  if [ ! -x "$BACKUP_SCRIPT" ]; then
    log_warn "백업 스크립트에 실행 권한이 없습니다. 권한을 추가합니다."
    chmod +x "$BACKUP_SCRIPT"
  fi
  
  # crontab 명령 실행 전에 임시 파일로 테스트
  TEMP_CRON="/tmp/new_cron_$$"
  
  # 기존 crontab 내용 + 새 크론 작업을 임시 파일에 작성
  {
    crontab -l 2>/dev/null | grep -v "$BACKUP_SCRIPT" || true
    echo "$CRON_EXPR $BACKUP_SCRIPT"
  } > "$TEMP_CRON"
  
  # crontab 등록 시도
  if crontab "$TEMP_CRON"; then
    log_info "crontab 명령 실행 성공"
    
    # 실제 등록 확인
    sleep 1  # 잠시 대기
    if crontab -l | grep -q "$BACKUP_SCRIPT"; then
      log_success "크론 등록 성공: $CRON_EXPR $BACKUP_SCRIPT"
      echo "등록된 백업 크론:"
      crontab -l | grep "$BACKUP_SCRIPT"
    else
      log_error "crontab 명령은 성공했으나 등록되지 않음"
    fi
  else
    log_error "crontab 명령 실행 실패 (종료코드: $?)"
  fi
  
  # 임시 파일 정리
  rm -f "$TEMP_CRON"
  
  # 크론 데몬 상태 확인
  if command -v systemctl >/dev/null; then
    if systemctl is-active --quiet cron 2>/dev/null; then
      echo "크론 서비스(cron) 실행 중"
    elif systemctl is-active --quiet crond 2>/dev/null; then
      echo "크론 서비스(crond) 실행 중"  
    else
      log_warn "크론 서비스가 실행되지 않고 있습니다"
      echo "다음 명령으로 크론 서비스를 시작하세요:"
      echo "  sudo systemctl start cron"
      echo "  또는"
      echo "  sudo systemctl start crond"
    fi
  elif command -v service >/dev/null; then
    if service cron status >/dev/null 2>&1; then
      echo "크론 서비스 실행 중"
    else
      log_warn "크론 서비스 상태를 확인할 수 없습니다"
    fi
  fi
}

uninstall() {
  log_step "Uninstall 모드 실행"
  read -p "삭제할 마운트 경로 입력 (/mnt/nfs): " MOUNTPOINT
  MOUNTPOINT=${MOUNTPOINT:-/mnt/nfs}

  if grep -q "$MOUNTPOINT" /etc/fstab; then
    sudo sed -i "\|$MOUNTPOINT|d" /etc/fstab
    log_info "/etc/fstab 에서 $MOUNTPOINT 제거됨"
  fi

  (crontab -l 2>/dev/null | grep -v "$BACKUP_SCRIPT") | crontab -
  log_info "crontab 에서 $BACKUP_SCRIPT 제거됨"

  if [ -f "$BACKUP_SCRIPT" ]; then
    rm -f "$BACKUP_SCRIPT"
    log_info "백업 스크립트 삭제됨: $BACKUP_SCRIPT"
  fi

  if ls /docker/docker-backup.log* >/dev/null 2>&1; then
    rm -f /docker/docker-backup.log*
    log_info "백업 로그파일 삭제됨"
  fi

  log_info "Uninstall 완료"
}

# ==============================
# Main
# ==============================
main() {
  show_header "Docker 백업 스크립트 설정 관리자"
  
  echo "1) NFS 백업 설정"
  echo "2) MP(마운트포인트) 백업 설정"
  echo "3) Uninstall (삭제)"
  echo "q) 종료"
  read -p "원하는 작업을 선택하세요: " choice
  case "$choice" in
    1)
      get_user_input_nfs
      prepare_mountpoint
      update_fstab
      mount_nfs
      generate_backup_script
      register_cron
      log_info "모든 단계 완료 (NFS 백업)"
      ;;
    2)
      get_user_input_mp
      generate_backup_script
      register_cron
      log_info "모든 단계 완료 (MP 백업)"
      ;;
    3)
      uninstall
      ;;
    q|Q)
      echo "종료합니다."
      exit 0
      ;;
    *)
      echo "잘못된 선택입니다."
      exit 1
      ;;
  esac
}

main
