#!/bin/bash

##################################################
# Docker Caddy 자동화 스크립트
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

# 메뉴 출력 함수
show_menu() {
    echo
    log_info "작업을 선택하세요"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}  1. 추가 (add)    - 서비스 블록 추가${NC}"
    echo -e "${YELLOW}  2. 삭제 (remove) - 서비스 블록 삭제${NC}"
    echo -e "${YELLOW}  3. 종료 (exit)   - 스크립트 종료${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# 서비스 목록 출력 함수
show_service_list() {
    local title="$1"
    local services_list=("${@:2}")
    
    if [[ ${#services_list[@]} -eq 0 ]]; then
        log_info "현재 등록된 서비스가 없습니다"
        return 0
    fi
    
    echo
    log_info "$title"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    printf "${YELLOW}%-8s %-25s %s${NC}\n" "순번" "서브도메인" "리버스 프록시"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    local count=1
    for item in "${services_list[@]}"; do
        local rp_addr=$(awk "/@${item} host/ {
            found_rp = 0;
            for(i=1; i<=10; ++i) {
                getline;
                if (\$1 ~ /reverse_proxy/) {
                    print \$2;
                    found_rp = 1;
                    break;
                }
            }
            if (found_rp == 0) {
                print \"N/A\"
            }
        }" "$CADDYFILE")

        printf "${CYAN}%-8d %-25s %s${NC}\n" "$count" "${item}.${BASE_DOMAIN}" "$rp_addr"
        count=$((count+1))
    done
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
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

# 사용법 출력 함수
usage() {
    log_info "사용법: $0 [add|remove] 또는 $0 (메뉴 선택)"
    exit 1
}

# 입력 검증 함수
validate_input() {
    local value="$1"
    local name="$2"
    
    if [[ -z "$value" ]]; then
        log_error "$name 값이 비어 있습니다. 올바른 값을 입력해주세요"
        return 1
    fi
    
    return 0
}

# 설정 파일 로드 함수
load_config() {
    # lxc.env 파일만 확인 (통합됨)
    local config_files=(
        "$SCRIPT_DIR/lxc.env"
        "./lxc.env"
    )
    
    local config_loaded=false
    
    for file in "${config_files[@]}"; do
        if [[ -f "$file" ]]; then
            source "$file"
            log_success "설정 파일 로드됨: $file"
            config_loaded=true
            break
        fi
    done
    
    if [[ "$config_loaded" == false ]]; then
        log_error "환경 설정 파일(lxc.env)을 찾을 수 없습니다"
        log_info "docker.sh를 먼저 실행하여 환경변수를 설정해주세요"
        return 1
    fi
    
    # DOMAIN 값을 BASE_DOMAIN으로 설정
    if [[ -n "$DOMAIN" ]]; then
        BASE_DOMAIN="$DOMAIN"
        log_success "도메인 설정: $BASE_DOMAIN"
    else
        log_warn "DOMAIN 환경변수가 설정되지 않았습니다"
        echo -ne "${CYAN}도메인명을 입력하세요 (예: example.com): ${NC}"
        read -r BASE_DOMAIN
        
        if [[ -n "$BASE_DOMAIN" ]]; then
            # lxc.env 파일에 DOMAIN 추가
            echo "DOMAIN=\"$BASE_DOMAIN\"" >> "$file"
            log_success "도메인이 설정되었습니다: $BASE_DOMAIN"
        else
            log_error "도메인이 설정되지 않았습니다"
            return 1
        fi
    fi
    
    export BASE_DOMAIN
    return 0
}

# 경로 및 파일 변수 설정
CADDY_DIR="/docker/caddy"
CONFIG_DIR="${CADDY_DIR}/conf"
CADDYFILE="${CONFIG_DIR}/Caddyfile"
DOCKER_COMPOSE_FILE="/docker/caddy/docker-compose.yml"
SCRIPT_DIR=$(cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd)
PROXMOX_CONF="${SCRIPT_DIR}/proxmox.conf"

# 서비스 추가 함수
add_services() {
    log_step "Caddy 서비스 블록 추가"
    
    # Caddyfile 존재 확인
    if [[ ! -f "$CADDYFILE" ]]; then
        log_error "Caddyfile을 찾을 수 없습니다: $CADDYFILE"
        exit 2
    fi
    
    # 설정 파일 로드
    if ! load_config "$PROXMOX_CONF"; then
        exit 3
    fi
    
    # 현재 서비스 목록 조회
    local services_list=()
    local tmp_list=$(grep '^[[:space:]]*@.* host' "$CADDYFILE" | awk '{print $1}' | sed 's/@//g' | sort -u)
    
    while IFS= read -r line; do
        if [[ "$line" != "proxmox" && -n "$line" ]]; then
            services_list+=("$line")
        fi
    done <<< "$tmp_list"

    # 현재 서비스 목록 출력
    show_service_list "현재 등록된 서비스 목록" "${services_list[@]}"
    
    # 새 서비스 정보 입력
    local new_services=()
    
    log_info "새 서비스 정보를 입력하세요 (완료하려면 Enter)"
    
    while true; do
        echo
        echo -ne "${CYAN}서브도메인(호스트명) 입력 (예: app) [Enter로 완료]: ${NC}"
        read -r subdomain
        
        if [[ -z "$subdomain" ]]; then
            break
        fi
        
        # 중복 확인
        local is_duplicate=false
        for existing in "${services_list[@]}"; do
            if [[ "$existing" == "$subdomain" ]]; then
                log_warn "이미 존재하는 서브도메인입니다: $subdomain"
                is_duplicate=true
                break
            fi
        done
        
        if [[ "$is_duplicate" == true ]]; then
            continue
        fi
        
        echo -ne "${CYAN}리버스 프록시 주소 입력 (예: 192.168.0.1:8080 또는 container:80): ${NC}"
        read -r rp_addr
        
        if ! validate_input "$rp_addr" "리버스 프록시 주소"; then
            continue
        fi
        
        # IP 패턴일 경우 http:// 추가
        if [[ "$rp_addr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}:[0-9]+$ ]]; then
            rp_addr="http://${rp_addr}"
        fi
        
        new_services+=("$subdomain $rp_addr")
        log_success "추가될 서비스: ${subdomain}.${BASE_DOMAIN} → $rp_addr"
    done
    
    if [[ ${#new_services[@]} -eq 0 ]]; then
        log_info "추가할 서비스가 없습니다"
        return 0
    fi
    
    # 서비스 블록 생성
    local new_blocks=""
    for service in "${new_services[@]}"; do
        local hostname=$(echo "$service" | awk '{print $1}')
        local address=$(echo "$service" | awk '{print $2}')
        
        new_blocks+=$(cat <<BLOCK

    @${hostname} host ${hostname}.${BASE_DOMAIN}
    handle @${hostname} {
        reverse_proxy ${address} {
            header_up X-Forwarded-For {remote_host}
            header_up X-Real-IP {remote_host}
        }
    }
BLOCK
)
    done

    # Caddyfile 업데이트
    log_info "Caddyfile 업데이트 중..."
    if awk -v new_blocks="$new_blocks" '/^[[:space:]]*handle {/ {print new_blocks"\n\n    handle {"} !/^[[:space:]]*handle {/ {print}' "$CADDYFILE" > "${CADDYFILE}.tmp"; then
        mv "${CADDYFILE}.tmp" "$CADDYFILE"
        log_success "Caddyfile 업데이트 완료"
    else
        log_error "Caddyfile 업데이트에 실패했습니다"
        rm -f "${CADDYFILE}.tmp"
        return 1
    fi
    
    # 연속된 빈 줄 정리
    sed -i '/^$/N;/^\n$/D' "$CADDYFILE"
    
    log_success "서비스 블록 추가 완료"
    show_reload_instructions
}

# 서비스 삭제 함수
remove_services() {
    log_step "Caddy 서비스 블록 삭제"
    
    # Caddyfile 존재 확인
    if [[ ! -f "$CADDYFILE" ]]; then
        log_error "Caddyfile을 찾을 수 없습니다: $CADDYFILE"
        exit 2
    fi
    
    # 설정 파일 로드
    if ! load_config "$PROXMOX_CONF"; then
        exit 3
    fi
    
    while true; do
        # 현재 서비스 목록 조회
        local services_list=()
        local tmp_list=$(grep '^[[:space:]]*@.* host' "$CADDYFILE" | awk '{print $1}' | sed 's/@//g' | sort -u)
        
        while IFS= read -r line; do
            if [[ "$line" != "proxmox" && -n "$line" ]]; then
                services_list+=("$line")
            fi
        done <<< "$tmp_list"

        # 서비스가 없으면 종료
        if [[ ${#services_list[@]} -eq 0 ]]; then
            log_info "삭제할 서비스가 없습니다"
            return 0
        fi

        # 현재 서비스 목록 출력
        show_service_list "삭제 가능한 서비스 목록" "${services_list[@]}"
        
        echo
        echo -ne "${CYAN}삭제할 서비스의 순번을 입력하세요 (예: 1,3,5 또는 'q'로 종료): ${NC}"
        read -r selection
        
        # 종료 조건
        if [[ -z "$selection" ]] || [[ "$selection" == "q" ]]; then
            log_info "삭제 작업을 종료합니다"
            return 0
        fi

        # 입력값 파싱 및 검증
        IFS=',' read -ra selections <<< "$selection"
        local services_to_delete=()
        local invalid_selection=false

        for sel in "${selections[@]}"; do
            sel=$(echo "$sel" | xargs) # 공백 제거
            
            if ! [[ "$sel" =~ ^[0-9]+$ ]] || [[ "$sel" -lt 1 ]] || [[ "$sel" -gt ${#services_list[@]} ]]; then
                log_error "잘못된 순번입니다: $sel (1-${#services_list[@]} 범위 내에서 입력)"
                invalid_selection=true
                break
            fi
            
            services_to_delete+=("${services_list[$((sel-1))]}")
        done

        if [[ "$invalid_selection" == true ]]; then
            continue
        fi

        # 삭제 확인
        echo
        log_warn "다음 서비스들이 삭제됩니다:"
        for service in "${services_to_delete[@]}"; do
            echo -e "${YELLOW}  - ${service}.${BASE_DOMAIN}${NC}"
        done
        
        if ! confirm_action "정말로 삭제하시겠습니까?"; then
            log_info "삭제를 취소합니다"
            continue
        fi

        # 삭제 실행
        local deleted_count=0
        for service_to_delete in "${services_to_delete[@]}"; do
            log_info "삭제 중: ${service_to_delete}.${BASE_DOMAIN}"
            
            if awk -v service="$service_to_delete" '
            BEGIN { in_block=0; brace_level=0 }
            
            $0 ~ ("@" service " host") {
                in_block=1;
                next
            }
            
            in_block == 1 && $0 ~ /{/ {
                brace_level++
            }
            
            in_block == 1 && $0 ~ /}/ {
                brace_level--
            }
            
            in_block == 0 {
                print
            }
            
            in_block == 1 && brace_level == 0 {
                in_block=0
            }
            ' "$CADDYFILE" > "${CADDYFILE}.tmp" && mv "${CADDYFILE}.tmp" "$CADDYFILE"; then
                ((deleted_count++))
                log_success "삭제 완료: ${service_to_delete}.${BASE_DOMAIN}"
            else
                log_error "삭제 실패: ${service_to_delete}.${BASE_DOMAIN}"
            fi
        done
        
        # 연속된 빈 줄 정리
        sed -i '/^$/N;/^\n$/D' "$CADDYFILE"
        
        if [[ $deleted_count -gt 0 ]]; then
            log_success "총 $deleted_count 개의 서비스 블록이 삭제되었습니다"
            show_reload_instructions
        fi
        
        break
    done
}

# 재로드 안내 함수
show_reload_instructions() {
    echo
    log_info "Caddy 설정 적용 방법"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}  방법 1 (권장): docker restart caddy${NC}"
    echo -e "${YELLOW}  방법 2: cd /docker/caddy && docker-compose up -d --force-recreate${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# 메인 실행 함수
main() {
    show_header "Docker Caddy 자동화 스크립트"
    
    log_info "스크립트 정보"
    echo -e "${CYAN}  - Caddy 설정 디렉토리: $CONFIG_DIR${NC}"
    echo -e "${CYAN}  - Caddyfile 경로: $CADDYFILE${NC}"
    echo -e "${CYAN}  - 설정 파일: $PROXMOX_CONF${NC}"
    
    # 메뉴 모드 또는 인자 모드 처리
    if [[ $# -lt 1 ]]; then
        # 메뉴 모드
        while true; do
            show_menu
            echo -ne "${CYAN}선택: ${NC}"
            read -r selection
            
            case "$selection" in
                1|add)
                    add_services
                    ;;
                2|remove)
                    remove_services
                    ;;
                3|exit)
                    log_success "스크립트를 종료합니다"
                    exit 0
                    ;;
                *)
                    log_error "잘못된 선택입니다. 1, 2, 3 중 하나를 입력하세요"
                    ;;
            esac
            
            echo
            if ! confirm_action "다른 작업을 계속하시겠습니까?"; then
                log_success "스크립트를 종료합니다"
                break
            fi
        done
    else
        # 인자 모드
        case "$1" in
            add)
                add_services
                ;;
            remove)
                remove_services
                ;;
            *)
                usage
                ;;
        esac
    fi
    
    echo
    log_success "작업이 완료되었습니다"
}

# 스크립트 실행
main "$@"
