#!/bin/bash
set -euo pipefail

# 색상 정의
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

log_step()   { echo -e "${CYAN}[STEP] $*${NC}"; }
log_info()   { echo -e "${YELLOW}[INFO] $*${NC}"; }
log_ok()     { echo -e "${GREEN}[OK] $*${NC}"; }
log_error()  { echo -e "${RED}[ERROR] $*${NC}"; }

CONFIG_FILE="./backup.env"

# STEP 1. 사용자 입력 받기
get_user_input() {
  log_step "Step 1. NFS 정보 입력"

  read -p "NFS 서버 IP 입력: " NFS_IP
  read -p "NFS 공유 폴더 이름 (예: docker-backup): " NFS_SHARE
  read -p "마운트 경로 (기본값: /mnt/nfs): " MOUNTPOINT
  MOUNTPOINT=${MOUNTPOINT:-/mnt/nfs}

  echo "NFS_IP=$NFS_IP" > "$CONFIG_FILE"
  echo "NFS_SHARE=$NFS_SHARE" >> "$CONFIG_FILE"
  echo "MOUNTPOINT=$MOUNTPOINT" >> "$CONFIG_FILE"

  log_ok "입력값 저장됨: $CONFIG_FILE"
}

# STEP 2. 마운트 경로 준비
prepare_mountpoint() {
  log_step "Step 2. 마운트 경로 준비"
  source "$CONFIG_FILE"

  if [ ! -d "$MOUNTPOINT" ]; then
    sudo mkdir -p "$MOUNTPOINT"
    log_ok "마운트 경로 생성됨: $MOUNTPOINT"
  else
    log_info "마운트 경로 이미 존재: $MOUNTPOINT"
  fi
}

# STEP 3. /etc/fstab 등록
update_fstab() {
  log_step "Step 3. /etc/fstab 등록"
  source "$CONFIG_FILE"

  FSTAB_LINE="${NFS_IP}:/volume1/${NFS_SHARE} ${MOUNTPOINT} nfs4 rw,noatime,nodiratime,rsize=65536,wsize=65536,nconnect=8 0 0"

  if grep -q "$MOUNTPOINT" /etc/fstab; then
    log_info "fstab에 이미 등록됨: $MOUNTPOINT"
  else
    echo "$FSTAB_LINE" | sudo tee -a /etc/fstab
    log_ok "fstab에 등록 완료"
  fi
}

# STEP 4. NFS 마운트 적용
mount_nfs() {
  log_step "Step 4. NFS 마운트 적용"
  source "$CONFIG_FILE"

  sudo mount -a
  if findmnt -t nfs4 "$MOUNTPOINT" > /dev/null; then
    log_ok "NFS 마운트 성공: $MOUNTPOINT"
  else
    log_error "NFS 마운트 실패"
    exit 1
  fi
}

# STEP 5. 백업 스크립트 생성
generate_backup_script() {
  log_step "Step 5. 백업 스크립트 생성"
  source "$CONFIG_FILE"

  BACKUP_SCRIPT="/usr/local/bin/docker-backup.sh"

  cat > "$BACKUP_SCRIPT" <<EOF
#!/bin/bash
SRC_DIRS="/docker"
SRC_FILES=(
  "/docker/rclone-after-service.sh"
)
EXCLUDE_DIRS=("core")
DEST_BASE="$MOUNTPOINT/docker"
LOGFILE="/docker/docker-backup.log"

if findmnt -t nfs4 "$MOUNTPOINT" > /dev/null; then
  echo "백업NFS가 정상적으로 마운트되어 있습니다."
else
  echo "백업NFS가 마운트되어 있지 않습니다. 마운트 시도 중..."
  mount -a
  if ! findmnt -t nfs4 "$MOUNTPOINT" > /dev/null; then
    echo "백업NFS 마운트 실패"
    exit 1
  fi
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
  cp -p "\$FILE" "\$DEST"
done

echo "복사 작업 종료: \$(date)" | tee -a "\$LOGFILE"
EOF

  chmod +x "$BACKUP_SCRIPT"
  log_ok "백업 스크립트 생성 완료: $BACKUP_SCRIPT"
}

# ==============================
# Main
# ==============================
main() {
  get_user_input
  prepare_mountpoint
  update_fstab
  mount_nfs
  generate_backup_script
  log_ok "모든 단계 완료"
}

main
