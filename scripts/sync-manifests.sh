#!/bin/bash

# ArgoCD 애플리케이션 동기화 스크립트
# 사용법: ./sync-manifests.sh [application] [options]

set -euo pipefail

# 색상 코드
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 로깅 함수
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ArgoCD 설정
ARGOCD_SERVER="${ARGOCD_SERVER:-argocd.your-domain.com}"
ARGOCD_TOKEN="${ARGOCD_TOKEN:-}"
ARGOCD_USERNAME="${ARGOCD_USERNAME:-admin}"
ARGOCD_PASSWORD="${ARGOCD_PASSWORD:-}"

# 사용법 출력
usage() {
    cat << EOF
ArgoCD 애플리케이션 동기화 스크립트

사용법: $0 [application] [options]

매개변수:
  application   특정 애플리케이션만 동기화 (선택적)
                형식: service-environment (예: api-gateway-dev)
                'all'이면 모든 애플리케이션 동기화

옵션:
  -e, --env ENVIRONMENT   특정 환경만 동기화 (dev, staging, production)
  -s, --service SERVICE   특정 서비스만 동기화 (api-gateway, auth-service 등)
  -p, --prune            Prune 옵션으로 동기화 (삭제된 리소스 정리)
  -f, --force            강제 동기화 (리소스 교체)
  -w, --wait             동기화 완료까지 대기
  -d, --dry-run          실제 동기화 없이 미리보기만
  --hard-refresh         하드 새로고침 후 동기화
  -h, --help             도움말 출력

환경변수:
  ARGOCD_SERVER     ArgoCD 서버 URL (기본: argocd.your-domain.com)
  ARGOCD_TOKEN      ArgoCD 인증 토큰
  ARGOCD_USERNAME   ArgoCD 사용자명 (기본: admin)
  ARGOCD_PASSWORD   ArgoCD 비밀번호

예제:
  $0                                    # 모든 애플리케이션 상태 확인
  $0 all                               # 모든 애플리케이션 동기화
  $0 api-gateway-dev                   # 특정 애플리케이션 동기화
  $0 --env dev                         # 개발 환경만 동기화
  $0 --service api-gateway            # api-gateway 모든 환경 동기화
  $0 api-gateway-prod --prune --wait  # 운영환경 prune으로 동기화하고 대기

EOF
}

# ArgoCD CLI 확인 및 로그인
check_argocd_cli() {
    if ! command -v argocd >/dev/null 2>&1; then
        log_error "argocd CLI가 설치되지 않았습니다."
        log_info "설치 방법: https://argo-cd.readthedocs.io/en/stable/cli_installation/"
        exit 1
    fi

    # 로그인 확인
    if [ -n "$ARGOCD_TOKEN" ]; then
        log_info "토큰으로 ArgoCD 인증 중..."
        argocd login "$ARGOCD_SERVER" --auth-token "$ARGOCD_TOKEN" --insecure
    elif [ -n "$ARGOCD_PASSWORD" ]; then
        log_info "사용자명/비밀번호로 ArgoCD 인증 중..."
        echo "$ARGOCD_PASSWORD" | argocd login "$ARGOCD_SERVER" --username "$ARGOCD_USERNAME" --password-stdin --insecure
    else
        log_info "대화형 로그인으로 ArgoCD 인증 중..."
        argocd login "$ARGOCD_SERVER" --insecure
    fi

    log_success "ArgoCD 인증 완료"
}

# 애플리케이션 목록 조회
get_applications() {
    local env_filter="$1"
    local service_filter="$2"
    
    log_info "애플리케이션 목록 조회 중..."
    
    local apps
    apps=$(argocd app list -o name | grep "elice-" | sort)
    
    if [ -n "$env_filter" ]; then
        apps=$(echo "$apps" | grep -- "-$env_filter\$")
    fi
    
    if [ -n "$service_filter" ]; then
        apps=$(echo "$apps" | grep "^$service_filter-")
    fi
    
    echo "$apps"
}

# 애플리케이션 상태 확인
check_app_status() {
    local app_name="$1"
    
    log_info "애플리케이션 상태 확인: $app_name"
    
    local status
    status=$(argocd app get "$app_name" -o json | jq -r '.status.sync.status')
    
    local health
    health=$(argocd app get "$app_name" -o json | jq -r '.status.health.status')
    
    case $status in
        "Synced")
            log_success "$app_name: 동기화됨 (Health: $health)"
            ;;
        "OutOfSync")
            log_warning "$app_name: 동기화 필요 (Health: $health)"
            ;;
        *)
            log_info "$app_name: $status (Health: $health)"
            ;;
    esac
    
    echo "$status"
}

# 애플리케이션 동기화
sync_application() {
    local app_name="$1"
    local sync_options="$2"
    
    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY-RUN] $app_name 동기화를 건너뜁니다."
        return 0
    fi
    
    log_info "애플리케이션 동기화 시작: $app_name"
    
    # 하드 새로고침 옵션
    if [ "$HARD_REFRESH" = "true" ]; then
        log_info "$app_name 하드 새로고침 중..."
        argocd app refresh "$app_name" --hard
        sleep 2
    fi
    
    # 동기화 실행
    local sync_cmd="argocd app sync $app_name"
    
    if [[ $sync_options == *"--prune"* ]]; then
        sync_cmd="$sync_cmd --prune"
    fi
    
    if [[ $sync_options == *"--force"* ]]; then
        sync_cmd="$sync_cmd --force"
    fi
    
    log_info "동기화 명령: $sync_cmd"
    
    if $sync_cmd; then
        log_success "$app_name 동기화 성공"
    else
        log_error "$app_name 동기화 실패"
        return 1
    fi
    
    # 동기화 완료 대기
    if [ "$WAIT_SYNC" = "true" ]; then
        log_info "$app_name 동기화 완료 대기 중..."
        argocd app wait "$app_name" --timeout 300
        log_success "$app_name 동기화 완료"
    fi
}

# 환경별 승인 확인
confirm_environment() {
    local env="$1"
    
    case $env in
        "staging")
            log_warning "스테이징 환경 동기화를 진행합니다."
            read -p "계속하시겠습니까? [y/N]: " -r
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                log_info "스테이징 환경 동기화가 취소되었습니다."
                return 1
            fi
            ;;
        "production")
            log_error "운영 환경 동기화는 매우 신중해야 합니다!"
            log_warning "운영 환경에 영향을 줄 수 있습니다."
            read -p "정말로 운영 환경을 동기화하시겠습니까? [y/N]: " -r
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                log_info "운영 환경 동기화가 취소되었습니다."
                return 1
            fi
            
            read -p "최종 확인: 'PRODUCTION'을 입력하세요: " -r
            if [[ $REPLY != "PRODUCTION" ]]; then
                log_info "운영 환경 동기화가 취소되었습니다."
                return 1
            fi
            ;;
    esac
    
    return 0
}

# 메인 함수
main() {
    # 기본값 설정
    TARGET_APP=""
    ENV_FILTER=""
    SERVICE_FILTER=""
    SYNC_OPTIONS=""
    PRUNE_OPTION="false"
    FORCE_OPTION="false"
    WAIT_SYNC="false"
    DRY_RUN="false"
    HARD_REFRESH="false"

    # 매개변수 파싱
    while [[ $# -gt 0 ]]; do
        case $1 in
            -e|--env)
                ENV_FILTER="$2"
                shift 2
                ;;
            -s|--service)
                SERVICE_FILTER="$2"
                shift 2
                ;;
            -p|--prune)
                PRUNE_OPTION="true"
                SYNC_OPTIONS="$SYNC_OPTIONS --prune"
                shift
                ;;
            -f|--force)
                FORCE_OPTION="true"
                SYNC_OPTIONS="$SYNC_OPTIONS --force"
                shift
                ;;
            -w|--wait)
                WAIT_SYNC="true"
                shift
                ;;
            -d|--dry-run)
                DRY_RUN="true"
                shift
                ;;
            --hard-refresh)
                HARD_REFRESH="true"
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            -*)
                log_error "알 수 없는 옵션: $1"
                usage
                exit 1
                ;;
            *)
                TARGET_APP="$1"
                shift
                ;;
        esac
    done

    log_info "=== ArgoCD 애플리케이션 동기화 시작 ==="

    if [ "$DRY_RUN" = "true" ]; then
        log_warning "DRY-RUN 모드: 실제 동기화는 수행되지 않습니다."
    fi

    # ArgoCD CLI 확인 및 로그인
    check_argocd_cli

    # 특정 애플리케이션 동기화
    if [ -n "$TARGET_APP" ] && [ "$TARGET_APP" != "all" ]; then
        # 환경 추출 및 승인 확인
        if [[ $TARGET_APP =~ -([^-]+)$ ]]; then
            local env="${BASH_REMATCH[1]}"
            if ! confirm_environment "$env"; then
                exit 0
            fi
        fi
        
        check_app_status "$TARGET_APP"
        sync_application "$TARGET_APP" "$SYNC_OPTIONS"
        exit 0
    fi

    # 애플리케이션 목록 조회
    local apps
    apps=$(get_applications "$ENV_FILTER" "$SERVICE_FILTER")

    if [ -z "$apps" ]; then
        log_warning "조건에 맞는 애플리케이션이 없습니다."
        exit 0
    fi

    log_info "대상 애플리케이션:"
    echo "$apps" | while read -r app; do
        echo "  - $app"
    done

    # 환경별 승인 확인
    if [ -n "$ENV_FILTER" ]; then
        if ! confirm_environment "$ENV_FILTER"; then
            exit 0
        fi
    fi

    # 상태 확인만 수행 (동기화 없음)
    if [ "$TARGET_APP" != "all" ] && [ -z "$TARGET_APP" ]; then
        log_info "애플리케이션 상태 확인 중..."
        echo "$apps" | while read -r app; do
            check_app_status "$app"
        done
        exit 0
    fi

    # 모든 애플리케이션 동기화
    local failed_apps=()
    echo "$apps" | while read -r app; do
        # 환경별 승인 확인
        if [[ $app =~ -([^-]+)$ ]]; then
            local env="${BASH_REMATCH[1]}"
            if [ -z "$ENV_FILTER" ]; then
                if ! confirm_environment "$env"; then
                    continue
                fi
            fi
        fi
        
        if ! sync_application "$app" "$SYNC_OPTIONS"; then
            failed_apps+=("$app")
        fi
    done

    # 결과 보고
    if [ ${#failed_apps[@]} -eq 0 ]; then
        log_success "=== 모든 애플리케이션 동기화 완료 ==="
    else
        log_error "=== 일부 애플리케이션 동기화 실패 ==="
        for app in "${failed_apps[@]}"; do
            echo "  - $app"
        done
        exit 1
    fi
}

# 스크립트 실행
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi