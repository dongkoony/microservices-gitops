#!/bin/bash

# GitOps 이미지 업데이트 스크립트
# 사용법: ./update-image.sh <service> <tag> <environment>
# 예: ./update-image.sh api-gateway v1.2.3 dev

set -euo pipefail

# 색상 코드
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 로깅 함수
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 사용법 출력
usage() {
    cat << EOF
GitOps 이미지 업데이트 스크립트

사용법: $0 <service> <tag> <environment> [options]

매개변수:
  service      마이크로서비스 이름 (예: api-gateway, auth-service)
  tag          Docker 이미지 태그 (예: v1.2.3, dev-latest)
  environment  배포 환경 (dev, staging, production)

옵션:
  -r, --registry    Docker 레지스트리 (기본값: localhost:5000)
  -c, --commit      Git 커밋 메시지
  -p, --push        변경사항 자동 푸시
  -d, --dry-run     실제 변경 없이 미리보기만
  -h, --help        도움말 출력

예제:
  $0 api-gateway v1.2.3 dev
  $0 auth-service stg-20250107-abc1234 staging --push
  $0 user-service prod-v2.0.1 production --registry 123456789012.dkr.ecr.us-west-2.amazonaws.com

EOF
}

# 매개변수 검증
validate_params() {
    if [ $# -lt 3 ]; then
        log_error "매개변수가 부족합니다."
        usage
        exit 1
    fi

    SERVICE_NAME=$1
    IMAGE_TAG=$2
    ENVIRONMENT=$3

    # 유효한 환경인지 확인
    case $ENVIRONMENT in
        dev|staging|production)
            ;;
        *)
            log_error "유효하지 않은 환경입니다: $ENVIRONMENT"
            log_info "지원되는 환경: dev, staging, production"
            exit 1
            ;;
    esac

    # 서비스 디렉토리 존재 확인
    SERVICE_PATH="applications/${SERVICE_NAME}/overlays/${ENVIRONMENT}"
    if [ ! -d "$SERVICE_PATH" ]; then
        log_error "서비스 경로를 찾을 수 없습니다: $SERVICE_PATH"
        exit 1
    fi
}

# Git 상태 확인
check_git_status() {
    if ! git rev-parse --git-dir > /dev/null 2>&1; then
        log_error "Git 저장소가 아닙니다."
        exit 1
    fi

    if [ -n "$(git status --porcelain)" ] && [ "$DRY_RUN" != "true" ]; then
        log_warning "워킹 디렉토리에 커밋되지 않은 변경사항이 있습니다."
        git status --short
        read -p "계속하시겠습니까? [y/N]: " -r
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 0
        fi
    fi
}

# Kustomization.yaml에서 이미지 태그 업데이트
update_kustomization() {
    local kustomization_file="${SERVICE_PATH}/kustomization.yaml"
    
    if [ ! -f "$kustomization_file" ]; then
        log_error "kustomization.yaml 파일을 찾을 수 없습니다: $kustomization_file"
        exit 1
    fi

    log_info "이미지 태그 업데이트 중: $SERVICE_NAME -> $FULL_IMAGE_NAME"

    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY-RUN] 다음 변경사항이 적용됩니다:"
        echo "  파일: $kustomization_file"
        echo "  이미지: $DOCKER_REGISTRY/$SERVICE_NAME"
        echo "  태그: $IMAGE_TAG"
        return 0
    fi

    # yq를 사용하여 이미지 태그 업데이트 (yq가 없으면 sed 사용)
    if command -v yq >/dev/null 2>&1; then
        yq eval ".images[] |= select(.name == \"$DOCKER_REGISTRY/$SERVICE_NAME\").newTag = \"$IMAGE_TAG\"" -i "$kustomization_file"
    else
        # sed를 사용한 백업 방법
        sed -i.bak "s|newTag: .*|newTag: $IMAGE_TAG|g" "$kustomization_file"
        rm -f "${kustomization_file}.bak"
    fi

    log_success "이미지 태그가 업데이트되었습니다: $IMAGE_TAG"
}

# 변경사항 검증
validate_changes() {
    log_info "변경사항 검증 중..."
    
    # Kustomize 빌드 테스트
    if command -v kustomize >/dev/null 2>&1; then
        if kustomize build "$SERVICE_PATH" > /dev/null; then
            log_success "Kustomize 빌드 검증 성공"
        else
            log_error "Kustomize 빌드 검증 실패"
            exit 1
        fi
    else
        log_warning "kustomize가 설치되지 않아 빌드 검증을 건너뜁니다."
    fi

    # YAML 구문 검증
    if command -v yamllint >/dev/null 2>&1; then
        if yamllint "$SERVICE_PATH" >/dev/null 2>&1; then
            log_success "YAML 구문 검증 성공"
        else
            log_warning "YAML 구문 검증에 일부 경고가 있습니다."
        fi
    fi
}

# Git 커밋 및 푸시
commit_and_push() {
    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY-RUN] Git 커밋 및 푸시가 건너뛰어집니다."
        return 0
    fi

    log_info "Git에 변경사항 커밋 중..."

    # 변경된 파일 추가
    git add "$SERVICE_PATH/kustomization.yaml"

    # 커밋 메시지 생성
    if [ -z "$COMMIT_MESSAGE" ]; then
        COMMIT_MESSAGE="feat($SERVICE_NAME): $ENVIRONMENT 환경 이미지 태그 업데이트 to $IMAGE_TAG"
    fi

    git commit -m "$COMMIT_MESSAGE"
    log_success "커밋 완료: $COMMIT_MESSAGE"

    # 푸시 (옵션)
    if [ "$PUSH_CHANGES" = "true" ]; then
        log_info "원격 저장소에 푸시 중..."
        git push origin $(git branch --show-current)
        log_success "푸시 완료"
    fi
}

# 메인 함수
main() {
    # 기본값 설정
    DOCKER_REGISTRY="localhost:5000"
    COMMIT_MESSAGE=""
    PUSH_CHANGES="false"
    DRY_RUN="false"

    # 옵션 파싱
    while [[ $# -gt 3 ]]; do
        case $4 in
            -r|--registry)
                DOCKER_REGISTRY="$5"
                shift 2
                ;;
            -c|--commit)
                COMMIT_MESSAGE="$5"
                shift 2
                ;;
            -p|--push)
                PUSH_CHANGES="true"
                shift
                ;;
            -d|--dry-run)
                DRY_RUN="true"
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "알 수 없는 옵션: $4"
                usage
                exit 1
                ;;
        esac
    done

    # 매개변수 검증
    validate_params "$@"

    FULL_IMAGE_NAME="$DOCKER_REGISTRY/$SERVICE_NAME:$IMAGE_TAG"

    log_info "=== GitOps 이미지 업데이트 시작 ==="
    log_info "서비스: $SERVICE_NAME"
    log_info "환경: $ENVIRONMENT"
    log_info "이미지: $FULL_IMAGE_NAME"
    log_info "경로: $SERVICE_PATH"

    if [ "$DRY_RUN" = "true" ]; then
        log_warning "DRY-RUN 모드: 실제 변경사항은 적용되지 않습니다."
    fi

    # Git 상태 확인
    check_git_status

    # 이미지 태그 업데이트
    update_kustomization

    # 변경사항 검증
    validate_changes

    # Git 커밋 및 푸시
    commit_and_push

    log_success "=== GitOps 이미지 업데이트 완료 ==="
    
    if [ "$ENVIRONMENT" = "dev" ]; then
        log_info "개발 환경은 ArgoCD에 의해 자동으로 동기화됩니다."
    else
        log_info "ArgoCD UI에서 수동으로 동기화를 승인해주세요."
        log_info "ArgoCD URL: https://argocd.your-domain.com/applications/$SERVICE_NAME-$ENVIRONMENT"
    fi
}

# 스크립트 실행
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi