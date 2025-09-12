#!/bin/bash

##################################################
# Docker 서비스 자동 배포 스크립트
# NFO 파일 기반 서비스 선택 및 자동 구성
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

# 서비스 목록 테이블 출력 함수
show_services_table() {
    local docker_names=("${@:1:$((($#-1)/2))}")
    local docker_req=("${@:$(((($#-1)/2)+1)):$((($#-1)/2))}")
    local optional_index=("${@:$#}")
    
    echo
    log_info "사용 가능한 Docker 서비스 목록"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    printf "${YELLOW}| %-5s | %-20s | %-10s | %-15s |${NC}\n" "번호" "서비스명" "필수여부" "설명"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    local opt_idx=1
    for i in "${!docker_names[@]}"; do
        local name="${docker_names[i]}"
        local req="${docker_req[i]}"
        local no=""
        local status=""
        local description=""
        
        if [[ "$req" == "true" ]]; then
            no="필수"
            status="Required"
            description="자동 설치됨"
        else
            no="$opt_idx"
            status="Optional"
            description="선택 설치"
            ((opt_idx++))
        fi
        
        printf "${CYAN}| %-5s | %-20s | %-10s | %-15s |${NC}\n" "$no" "$name" "$status" "$description"
    done
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# 파일 존재 확인 함수
check_required_files() {
    local nfo_file="$1"
    local env_file="$2"
    
    if [[ ! -f "$nfo_file" ]]; then
        log_error "NFO 파일을 찾을 수 없습니다: $nfo_file"
        log_info "docker.nfo 파일이 필요합니다"
        exit 1
    fi
    
    if [[ ! -f "$env_file" ]]; then
        log_warn "환경 설정 파일이 없습니다. 새로 생성합니다: $env_file"
        touch "$env_file"
    fi
    
    log_success "필수 파일 확인 완료"
}

# 환경 변수 로드 및 설정 함수
setup_environment_variables() {
    local nfo_file="$1"
    local env_file="$2"
    local -n env_values_ref=$3
    
    log_step "환경 변수 설정"
    
    # 기존 환경 변수 로드
    if [[ -f "$env_file" ]]; then
        log_info "기존 환경 설정 로드 중..."
        while IFS='=' read -r key val; do
            key=${key//[[:space:]]/}
            val=$(echo "$val" | sed -e 's/^"//' -e 's/"$//')
            env_values_ref[$key]=$val
        done < "$env_file"
    fi
    
    # NFO 파일에서 필요한 환경 변수 추출
    log_info "NFO 파일에서 환경 변수 분석 중..."
    mapfile -t env_keys < <(grep -oP '##\K[^#]+(?=##)' "$nfo_file" | sort -u)
    
    local new_vars_count=0
    for key in "${env_keys[@]}"; do
        if [[ -z "${env_values_ref[$key]}" ]]; then
            echo
            log_info "새로운 환경 변수 설정이 필요합니다: $key"
            
            # 키에 따른 기본값이나 안내 메시지 제공
            case "$key" in
                "DOMAIN")
                    echo -ne "${CYAN}도메인명을 입력하세요 (예: example.com): ${NC}"
                    ;;
                "API_TOKEN")
                    echo -ne "${CYAN}Cloudflare API 토큰을 입력하세요: ${NC}"
                    ;;
                "PROXMOX_IP")
                    echo -ne "${CYAN}Proxmox 서버 IP를 입력하세요 (예: 192.168.0.100): ${NC}"
                    ;;
                *)
                    echo -ne "${CYAN}'$key' 값을 입력하세요: ${NC}"
                    ;;
            esac
            
            read -r val
            env_values_ref[$key]=$val
            echo "$key=\"$val\"" >> "$env_file"
            ((new_vars_count++))
        fi
    done
    
    if [[ $new_vars_count -gt 0 ]]; then
        log_success "새로운 환경 변수 $new_vars_count 개가 설정되었습니다"
    else
        log_success "모든 환경 변수가 이미 설정되어 있습니다"
    fi
}

# Docker 서비스 목록 파싱 함수
parse_docker_services() {
    local nfo_file="$1"
    local -n docker_names_ref=$2
    local -n docker_req_ref=$3
    
    log_step "Docker 서비스 목록 분석"
    
    local services_count=0
    while IFS= read -r line; do
        if [[ $line =~ ^__DOCKER_START__\ name=([^[:space:]]+)\ req=([^[:space:]]+) ]]; then
            docker_names_ref+=("${BASH_REMATCH[1]}")
            docker_req_ref+=("${BASH_REMATCH[2]}")
            ((services_count++))
        fi
    done < "$nfo_file"
    
    log_success "총 $services_count 개의 Docker 서비스를 찾았습니다"
}

# 선택적 서비스 선택 함수
select_optional_services() {
    local -n docker_names_ref=$1
    local -n docker_req_ref=$2
    local -n selected_services_ref=$3
    
    log_step "선택적 서비스 설정"
    
    # 선택 가능한 서비스 인덱스 생성
    local optional_index=()
    local opt_idx=1
    
    for i in "${!docker_names_ref[@]}"; do
        local name="${docker_names_ref[i]}"
        local req="${docker_req_ref[i]}"
        
        if [[ "$req" == "false" ]]; then
            optional_index+=("${i}:${opt_idx}:${name}")
            ((opt_idx++))
        fi
    done
    
    # 서비스 테이블 출력
    show_services_table "${docker_names_ref[@]}" "${docker_req_ref[@]}"
    
    if [[ ${#optional_index[@]} -eq 0 ]]; then
        log_warn "선택 가능한 옵션 서비스가 없습니다"
        return 0
    fi
    
    echo
    log_info "설치할 선택적 서비스를 선택하세요"
    echo -ne "${CYAN}서비스 번호를 ','로 구분하여 입력 (예: 1,3,5) [Enter로 건너뛰기]: ${NC}"
    read -r input_line
    
    if [[ -z "$input_line" ]]; then
        log_info "선택적 서비스 없이 진행합니다"
        return 0
    fi
    
    # 입력값 파싱
    IFS=',' read -r -a selected_nums <<< "$input_line"
    local selected_count=0
    
    for num in "${selected_nums[@]}"; do
        local num_trimmed=$(echo "$num" | xargs)
        
        for item in "${optional_index[@]}"; do
            local idx=${item%%:*}
            local rest=${item#*:}
            local n=${rest%%:*}
            local s=${rest#*:}
            
            if [[ "$num_trimmed" == "$n" ]]; then
                selected_services_ref["$s"]=1
                ((selected_count++))
                log_info "선택됨: $s"
            fi
        done
    done
    
    log_success "총 $selected_count 개의 선택적 서비스가 선택되었습니다"
}

# 최종 서비스 목록 생성 함수
generate_final_service_list() {
    local -n docker_names_ref=$1
    local -n docker_req_ref=$2
    local -n selected_services_ref=$3
    local -n all_services_ref=$4
    
    log_step "최종 설치 서비스 목록 생성"
    
    local required_services=()
    local optional_services=()
    
    # 필수 서비스와 선택된 옵션 서비스 분류
    for i in "${!docker_names_ref[@]}"; do
        local name="${docker_names_ref[i]}"
        local req="${docker_req_ref[i]}"
        
        if [[ "$req" == "true" ]]; then
            required_services+=("$name")
        elif [[ -n "${selected_services_ref[$name]}" ]]; then
            optional_services+=("$name")
        fi
    done
    
    # 전체 서비스 목록 생성
    all_services_ref=("${required_services[@]}" "${optional_services[@]}")
    
    echo
    log_info "최종 설치 서비스 목록"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    if [[ ${#required_services[@]} -gt 0 ]]; then
        echo -e "${YELLOW}필수 서비스:${NC}"
        for service in "${required_services[@]}"; do
            echo -e "${CYAN}  ✓ $service${NC}"
        done
    fi
    
    if [[ ${#optional_services[@]} -gt 0 ]]; then
        echo -e "${YELLOW}선택 서비스:${NC}"
        for service in "${optional_services[@]}"; do
            echo -e "${CYAN}  ✓ $service${NC}"
        done
    fi
    
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    log_success "총 ${#all_services_ref[@]} 개의 서비스가 설치됩니다"
}

# 개별 서비스 실행 함수
run_service_commands() {
    local service="$1"
    local nfo_file="$2"
    local -n env_values_ref=$3
    
    log_step "서비스 설정: $service"
    
    # 서비스 블록 라인 범위 찾기
    local line_start=$(awk '/^__DOCKER_START__ name='"$service"' /{print NR}' "$nfo_file" | head -n1)
    local line_end=$(awk 'NR>'$line_start' && /^__DOCKER_END__/{print NR; exit}' "$nfo_file")
    
    if [[ -z "$line_start" || -z "$line_end" ]]; then
        log_error "서비스 블록을 찾을 수 없습니다: $service"
        return 1
    fi
    
    # 블록 내용 추출
    mapfile -t block_lines < <(sed -n "${line_start},${line_end}p" "$nfo_file")
    
    # CMD 블록 실행
    execute_cmd_block "$service" "${block_lines[@]}"
    
    # EOF 파일들 생성
    create_eof_files "$service" "${block_lines[@]}"
    
    log_success "서비스 설정 완료: $service"
}

# CMD 블록 실행 함수
execute_cmd_block() {
    local service="$1"
    shift
    local block_lines=("$@")
    
    local in_cmd=0
    local cmd_lines=()
    
    # CMD 블록 추출
    for line in "${block_lines[@]}"; do
        if [[ "$line" == "__CMD_START__" ]]; then 
            in_cmd=1
            continue
        fi
        if [[ "$line" == "__CMD_END__" ]]; then 
            in_cmd=0
            continue
        fi
        if ((in_cmd)); then 
            cmd_lines+=("$line")
        fi
    done
    
    # CMD 실행
    if [[ ${#cmd_lines[@]} -gt 0 ]]; then
        log_info "명령어 실행 중: $service"
        
        for cmd in "${cmd_lines[@]}"; do
            log_info "실행: $cmd"
            if eval "$cmd" >/dev/null 2>&1; then
                log_success "명령 실행 완료: $cmd"
            else
                log_warn "명령 실행 실패하였지만 계속 진행: $cmd"
            fi
        done
    fi
}

# EOF 파일 생성 함수
create_eof_files() {
    local service="$1"
    shift
    local block_lines=("$@")
    
    local in_eofs=0
    local in_eof=0
    local eof_path=""
    local eof_content=""
    local created_files=0
    
    # EOF 블록 처리
    for line in "${block_lines[@]}"; do
        if [[ "$line" == "__EOFS_START__" ]]; then 
            in_eofs=1
            continue
        fi
        if [[ "$line" == "__EOFS_END__" ]]; then 
            in_eofs=0
            continue
        fi
        
        if ((in_eofs)); then
            if [[ "$line" =~ ^__EOF_START__\ (.+) ]]; then
                in_eof=1
                eof_path="${BASH_REMATCH[1]}"
                eof_content=""
                continue
            fi
            
            if [[ "$line" == "__EOF_END__" ]]; then
                in_eof=0
                
                # 환경변수 치환 (수정됨: ENV_VALUES → env_values_ref)
                local eof_output="$eof_content"
                for key in "${!env_values_ref[@]}"; do
                    eof_output=$(echo "$eof_output" | sed "s/##$key##/${env_values_ref[$key]}/g")
                done
                
                # 디렉토리 생성 및 파일 작성
                if mkdir -p "$(dirname "$eof_path")" 2>/dev/null; then
                    if echo -n "$eof_output" > "$eof_path"; then
                        log_success "파일 생성 완료: $eof_path"
                        ((created_files++))
                    else
                        log_error "파일 생성 실패: $eof_path"
                    fi
                else
                    log_error "디렉토리 생성 실패: $(dirname "$eof_path")"
                fi
                continue
            fi
            
            if ((in_eof)); then
                eof_content+="$line"$'\n'
            fi
        fi
    done
    
    if [[ $created_files -gt 0 ]]; then
        log_success "서비스 $service: $created_files 개의 파일이 생성되었습니다"
    fi
}

# CADDYS 블록 추출 함수
extract_caddys_block() {
    local service="$1"
    local nfo_file="$2"
    
    awk -v svc="$service" '
        $0 ~ ("^__DOCKER_START__ name=" svc " ") { in_docker=1; next }
        in_docker && /^__CADDYS_START__/ { in_caddys=1; next }
        in_docker && /^__CADDYS_END__/ { in_caddys=0; next }
        in_docker && in_caddys && /^__CADDY_START__/ { in_caddy=1; caddy_block=""; next }
        in_docker && in_caddys && /^__CADDY_END__/ { in_caddy=0; print caddy_block; next }
        in_docker && in_caddys && in_caddy { caddy_block = caddy_block $0 "\n"; next }
        in_docker && /^__DOCKER_END__/ { in_docker=0 }
    ' "$nfo_file"
}

# Caddyfile 생성 함수
generate_caddyfile() {
    local nfo_file="$1"
    local -n all_services_ref=$2
    local -n env_values_ref=$3
    
    log_step "Caddyfile 생성"
    
    # 서비스별 CADDY 블록 수집
    local combined_caddy=""
    local caddy_blocks_count=0
    
    for service in "${all_services_ref[@]}"; do
        local caddy_block=$(extract_caddys_block "$service" "$nfo_file")
        
        if [[ -n "$caddy_block" ]]; then
            # 환경변수 치환
            for key in "${!env_values_ref[@]}"; do
                caddy_block=${caddy_block//"##$key##"/"${env_values_ref[$key]}"}
            done
            
            if [[ -n "$combined_caddy" ]]; then
                combined_caddy+=$'\n'
            fi
            combined_caddy+="$caddy_block"
            ((caddy_blocks_count++))
            log_info "CADDY 블록 추가됨: $service"
        fi
    done
    
    # CADDYFILE 템플릿 추출
    local caddyfile_template=$(awk '
        BEGIN {in_final=0}
        /^__CADDYFILE_START__/ { in_final=1; next }
        /^__CADDYFILE_END__/ { in_final=0; exit }
        in_final { print }
    ' "$nfo_file")
    
    if [[ -z "$caddyfile_template" ]]; then
        log_error "CADDYFILE 템플릿을 찾을 수 없습니다"
        return 1
    fi
    
    # 환경변수 치환 및 _CADDYS_ 자리 치환
    for key in "${!env_values_ref[@]}"; do
        caddyfile_template=${caddyfile_template//"##$key##"/"${env_values_ref[$key]}"}
    done
    caddyfile_template=${caddyfile_template//"_CADDYS_"/"$combined_caddy"}
    
    # Caddyfile 생성
    local caddyfile_path="/docker/caddy/conf/Caddyfile"
    if echo "$caddyfile_template" > "$caddyfile_path"; then
        log_success "Caddyfile 생성 완료: $caddyfile_path"
        log_success "포함된 서비스 블록: $caddy_blocks_count 개"
    else
        log_error "Caddyfile 생성에 실패했습니다"
        return 1
    fi
}

# 최종 설정 및 권한 부여 함수
finalize_setup() {
    log_step "최종 설정 및 권한 부여"
    
    local files_to_chmod=(
        "/docker/rclone-after-service.sh"
        "/docker/docker-all-start.sh"
    )
    
    local chmod_count=0
    for file in "${files_to_chmod[@]}"; do
        if [[ -f "$file" ]]; then
            if chmod +x "$file" 2>/dev/null; then
                log_success "실행 권한 부여: $file"
                ((chmod_count++))
            else
                log_warn "실행 권한 부여 실패: $file"
            fi
        fi
    done
    
    # systemd 설정
    log_info "systemd 설정 업데이트 중..."
    if systemctl daemon-reload 2>/dev/null; then
        log_success "systemd daemon 재로드 완료"
    else
        log_warn "systemd daemon 재로드 실패"
    fi
    
    if systemctl enable rclone-after-service 2>/dev/null; then
        log_success "rclone-after-service 서비스 활성화 완료"
    else
        log_warn "rclone-after-service 서비스 활성화 실패"
    fi
    
    log_success "권한 설정 완료: $chmod_count 개의 파일"
}

# 메인 실행 함수
main() {
    show_header "Docker 서비스 자동 배포"
    
    # 파일 경로 설정
    local nfo_file="./docker.nfo"
    local env_file="./lxc.env"
    
    # 전역 변수 선언
    declare -A ENV_VALUES
    declare -a DOCKER_NAMES
    declare -a DOCKER_REQ
    declare -A SELECTED_SERVICES
    declare -a ALL_SERVICES
    
    log_info "배포 스크립트 정보"
    echo -e "${CYAN}  - NFO 파일: $nfo_file${NC}"
    echo -e "${CYAN}  - 환경 설정: $env_file${NC}"
    
    # 1단계: 필수 파일 확인
    check_required_files "$nfo_file" "$env_file"
    
    # 2단계: 환경 변수 설정
    setup_environment_variables "$nfo_file" "$env_file" ENV_VALUES
    
    # 3단계: Docker 서비스 파싱
    parse_docker_services "$nfo_file" DOCKER_NAMES DOCKER_REQ
    
    # 4단계: 선택적 서비스 선택
    select_optional_services DOCKER_NAMES DOCKER_REQ SELECTED_SERVICES
    
    # 5단계: 최종 서비스 목록 생성
    generate_final_service_list DOCKER_NAMES DOCKER_REQ SELECTED_SERVICES ALL_SERVICES
    
    # 6단계: 서비스별 실행
    log_step "Docker 서비스 배포 실행"
    for service in "${ALL_SERVICES[@]}"; do
        run_service_commands "$service" "$nfo_file" ENV_VALUES
    done
    
    # 7단계: Caddyfile 생성
    generate_caddyfile "$nfo_file" ALL_SERVICES ENV_VALUES
    
    # 8단계: 최종 설정
    finalize_setup
    
    # 완료 메시지
    echo
    log_success "════════════════════════════════════════════════════════════"
    log_success "  Docker 서비스 배포가 완료되었습니다!"
    log_success "════════════════════════════════════════════════════════════"
    
    echo
    log_info "배포 완료 정보"
    echo -e "${CYAN}  - 설치된 서비스: ${#ALL_SERVICES[@]} 개${NC}"
    echo -e "${CYAN}  - 생성된 환경변수: ${#ENV_VALUES[@]} 개${NC}"
    echo -e "${CYAN}  - Caddyfile: /docker/caddy/conf/Caddyfile${NC}"
    
    echo
    log_info "다음 단계"
    echo -e "${CYAN}  1. 기존 데이터가 있다면 적절한 위치로 이동${NC}"
    echo -e "${CYAN}  2. 서비스 시작: /docker/docker-all-start.sh${NC}"
    echo -e "${CYAN}  3. 로그 확인: docker-compose logs -f${NC}"
    
    echo
    log_warn "기존 데이터가 있는 경우 데이터를 이동한 후 /docker/docker-all-start.sh를 실행하세요"
}

# 스크립트 실행
main "$@"
