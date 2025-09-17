#!/bin/bash

# 복사할 폴더 목록 (원본 경로)
SRC_DIRS="/docker"
# 복사할 파일 목록 (원본 경로)
SRC_FILES=(
  "/docker/rclone-after-service.sh"
)

# 예외폴더 (추가할 경우 예시 "a" "b")
EXCLUDE_DIRS=("core")

# 대상 폴더 경로
DEST_BASE="/mnt/nfs/docker"

# 로그 파일 경로
LOGFILE="/docker/docker-backup.log"

if findmnt -t nfs4 /mnt/nfs > /dev/null; then
  echo "백업NFS가 정상적으로 마운트되어 있습니다."
else
  echo "백업NFS가 마운트되어 있지 않습니다. 마운트 시도 중..."
  mount -a
  if findmnt -t nfs4 /mnt/nfs > /dev/null; then
    echo "백업NFS 마운트 성공"
  else
    echo "백업NFS 마운트 실패"
    exit 1
  fi
fi

if findmnt -t nfs4 /mnt/nfs > /dev/null; then
  echo "복사 작업 시작: $(date)" | tee -a "$LOGFILE"

  # SRC_BASE의 최상위 폴더 자동 분석
  for SRC in "$SRC_DIRS"/*/; do
    BASENAME=$(basename "$SRC")
    # 디렉토리가 아니면 스킵
    [[ ! -d "$SRC" ]] && continue
    # 제외 폴더면 스킵
    skip=0
    for exclude in "${EXCLUDE_DIRS[@]}"; do
      if [[ "$BASENAME" == "$exclude" ]]; then
        skip=1
        break
      fi
    done
    [[ "$skip" == 1 ]] && continue

    DEST="${DEST_BASE}/${BASENAME}"

    echo "[$(date)] 복사 시작: $SRC -> $DEST" | tee -a "$LOGFILE"
    start=$(date +%s)
    rsync -aW --delete --info=progress2 --mkpath "$SRC" "$DEST/"
    #rsync -aW --inplace --no-inc-recursive --delete --info=progress2 "$SRC" "$DEST/"
    status=$?
    end=$(date +%s)
    elapsed=$((end - start))

    if [ "$status" -eq 0 ]; then
      echo "[$(date)] 복사 완료: $SRC -> $DEST (${elapsed}초)" | tee -a "$LOGFILE"
    else
      echo "[$(date)] 복사 실패: $SRC -> $DEST (${elapsed}초)" | tee -a "$LOGFILE"
    fi
  done

  # 파일 복사
  for FILE in "${SRC_FILES[@]}"; do
    BASENAME=$(basename "$FILE")
    DEST="$DEST_BASE/$BASENAME"
    echo "[$(date)] 파일 복사 시작: $FILE -> $DEST" | tee -a "$LOGFILE"

    cp -p "$FILE" "$DEST"

    if [ $? -eq 0 ]; then
      echo "[$(date)] 파일 복사 완료: $FILE -> $DEST" | tee -a "$LOGFILE"
    else
      echo "[$(date)] 파일 복사 실패: $FILE -> $DEST" | tee -a "$LOGFILE"
    fi
  done

  echo "복사 작업 종료: $(date)" | tee -a "$LOGFILE"
else
  echo "백업NFS가 마운트지 않습니다. /etc/fstab 확인해보시기 바랍니다."
fi
