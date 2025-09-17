#!/bin/bash

##################################################
# Dcoker backup Setting
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


# 사용자 입력 변수
NFS_IP=""
NFS_SHARE=""
MOUNTPOINT=""
BACKUP_SCRIPT="/docker/docker-backup.sh"

# STEP 1. 사용자 입력 받기
get_user_input() {
  log_step "Step 1. NFS 정보 입력"

  read -p "NFS 서버 IP 입력: " NFS_IP
  read -p "NFS 공유 폴더 이름 (예: docker-backup): " NFS_SHARE
  read -p "마운트 경로 (기본값: /mnt/nfs): " MOUNTPOINT
  MOUNTPOINT=${MOUNTPOINT:-/mnt/nfs}

  export NFS_IP NFS_SHARE MOUNTPOINT
  log_ok "입력값 → IP: $NFS_IP, SHARE: $NFS_SHARE, MOUNT: $MOUNTPOINT"
}

prepare_mountpoint() {
  log_step "Step 2. 마운트 경로 준비"
  if [ ! -d "$MOUNTPOINT" ]; then
    sudo mkdir -p "$MOUNTPOINT"
    log_ok "마운트 경로 생성됨: $MOUNTPOINT"
  else
    log_info "마운트 경로 이미 존재: $MOUNTPOINT"
  fi
}

update_fstab() {
  log_step "Step 3. /etc/fstab 등록"
  FSTAB_LINE="${NFS_IP}:/volume1/${NFS_SHARE} ${MOUNTPOINT} nfs4 rw,noatime,nodiratime,rsize=65536,wsize=65536,nconnect=8 0 0"

  if grep -q "$MOUNTPOINT" /etc/fstab; then
    log_info "fstab에 이미 등록됨: $MOUNTPOINT"
  else
    echo "$FSTAB_LINE" | sudo tee -a /etc/fstab
    log_ok "fstab에 등록 완료"
  fi
}

mount_nfs() {
  log_step "Step 4. NFS 마운트 적용"
  sudo mount -a
  if findmnt -t nfs4 "$MOUNTPOINT" > /dev/null; then
    log_ok "NFS 마운트 성공: $MOUNTPOINT"
  else
    log_error "NFS 마운트 실패"
    exit 1
  fi
}

generate_backup_script() {
  log_step "Step 5. 백업 스크립트 생성"
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

if ! findmnt -t nfs4 "$MOUNTPOINT" > /dev/null; then
  echo "백업NFS가 마운트되어 있지 않습니다. 마운트 시도 중..."
  mount -a
fi

if ! findmnt -t nfs4 "$MOUNTPOINT" > /dev/null; then
  echo "백업NFS 마운트 실패" | tee -a "\$LOGFILE"
  exit 1
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
  log_ok "백업 스크립트 생성 완료: $BACKUP_SCRIPT"
}

register_cron() {
  log_step "Step 6. 크론 등록"

  read -p "백업 실행 주기 (기본값: 매일 01:00 → '0 1 * * *'): " CRON_EXPR
  CRON_EXPR=${CRON_EXPR:-"0 1 * * *"}

  (crontab -l 2>/dev/null | grep -v "$BACKUP_SCRIPT"; echo "$CRON_EXPR $BACKUP_SCRIPT") | crontab -

  log_ok "크론 등록 완료: $CRON_EXPR $BACKUP_SCRIPT"
}

uninstall() {
  log_step "Uninstall 모드 실행"

  read -p "삭제할 마운트 경로 입력 (/mnt/nfs): " MOUNTPOINT
  MOUNTPOINT=${MOUNTPOINT:-/mnt/nfs}

  # fstab 정리
  if grep -q "$MOUNTPOINT" /etc/fstab; then
    sudo sed -i "\|$MOUNTPOINT|d" /etc/fstab
    log_ok "/etc/fstab 에서 $MOUNTPOINT 제거됨"
  fi

  # cron 정리
  (crontab -l 2>/dev/null | grep -v "$BACKUP_SCRIPT") | crontab -
  log_ok "crontab 에서 $BACKUP_SCRIPT 제거됨"

  # 스크립트와 로그 삭제
  if [ -f "$BACKUP_SCRIPT" ]; then
    rm -f "$BACKUP_SCRIPT"
    log_ok "백업 스크립트 삭제됨: $BACKUP_SCRIPT"
  fi

  if ls /docker/docker-backup.log* >/dev/null 2>&1; then
    rm -f /docker/docker-backup.log*
    log_ok "백업 로그파일 삭제됨: /docker/docker-backup.log*"
  fi

  log_ok "Uninstall 완료"
}

# ==============================
# Main
# ==============================
main() {
  echo
  echo "══════════════════════════════════════"
  echo "  Docker 백업 스크립트 설정 관리자"
  echo "══════════════════════════════════════"
  echo "1) Install (설치)"
  echo "2) Uninstall (삭제)"
  echo "q) 종료"
  echo "══════════════════════════════════════"
  echo

  read -p "원하는 작업을 선택하세요: " choice
  case "$choice" in
    1)
      get_user_input
      prepare_mountpoint
      update_fstab
      mount_nfs
      generate_backup_script
      register_cron
      log_ok "모든 단계 완료 (INSTALL)"
      ;;
    2)
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
