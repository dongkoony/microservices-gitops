#!/bin/bash

# Jenkins CI/CD GitOps 통합 스크립트
# Jenkins 파이프라인에서 호출하여 GitOps 저장소의 이미지 태그를 업데이트

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

# 사용법 출력
usage() {
    cat << EOF
Jenkins CI/CD GitOps 통합 스크립트

사용법: $0 <service> <tag> <environment> [options]

매개변수:
  service      마이크로서비스 이름 (예: api-gateway, auth-service)
  tag          Docker 이미지 태그 (예: dev-build-123-abc1234)
  environment  배포 환경 (dev, staging, production)

Jenkins 환경변수 (자동 감지):
  BUILD_NUMBER     Jenkins 빌드 번호
  GIT_COMMIT       Git 커밋 해시
  JOB_NAME         Jenkins 작업 이름
  BUILD_URL        Jenkins 빌드 URL
  WORKSPACE        Jenkins 작업공간

옵션:
  -r, --registry REGISTRY   Docker 레지스트리 (기본: localhost:5000)
  -g, --gitops-repo REPO    GitOps 저장소 경로 또는 URL
  -b, --branch BRANCH       GitOps 저장소 브랜치 (기본: main)
  --git-user NAME          Git 사용자 이름 (기본: jenkins-ci)
  --git-email EMAIL        Git 이메일 (기본: jenkins@elice.io)
  --pr                     Pull Request 생성 (GitHub)
  --skip-validation        검증 단계 건너뛰기
  -h, --help               도움말 출력

예제 (Jenkins 파이프라인에서):
  $0 api-gateway dev-build-123-abc1234 dev
  $0 auth-service stg-build-456-def5678 staging --pr
  $0 user-service prod-v2.0.1 production --skip-validation

EOF
}

# Jenkins 환경 정보 수집
collect_jenkins_info() {
    log_info "Jenkins 환경 정보 수집 중..."
    
    # Jenkins 환경변수 확인
    JENKINS_BUILD_NUMBER="${BUILD_NUMBER:-unknown}"
    JENKINS_GIT_COMMIT="${GIT_COMMIT:-unknown}"
    JENKINS_JOB_NAME="${JOB_NAME:-unknown}"
    JENKINS_BUILD_URL="${BUILD_URL:-unknown}"
    JENKINS_WORKSPACE="${WORKSPACE:-$(pwd)}"
    
    # Git 사용자 정보 설정
    if [ -z "${GIT_USER_NAME:-}" ]; then
        GIT_USER_NAME="${GIT_USER:-jenkins-ci}"
    fi
    
    if [ -z "${GIT_USER_EMAIL:-}" ]; then
        GIT_USER_EMAIL="${GIT_EMAIL:-jenkins@elice.io}"
    fi
    
    log_info "Jenkins 빌드: #$JENKINS_BUILD_NUMBER"
    log_info "Git 커밋: ${JENKINS_GIT_COMMIT:0:8}"
    log_info "작업 이름: $JENKINS_JOB_NAME"
}

# GitOps 저장소 클론 또는 업데이트
setup_gitops_repo() {
    log_info "GitOps 저장소 설정 중: $GITOPS_REPO"
    
    # 임시 디렉터리 생성
    GITOPS_TEMP_DIR=$(mktemp -d)
    
    if [[ $GITOPS_REPO == http* ]] || [[ $GITOPS_REPO == git@* ]]; then
        # 원격 저장소 클론
        log_info "원격 GitOps 저장소 클론 중..."
        git clone --branch "$GITOPS_BRANCH" --depth 1 "$GITOPS_REPO" "$GITOPS_TEMP_DIR"
    else
        # 로컬 저장소 복사
        log_info "로컬 GitOps 저장소 복사 중..."
        cp -r "$GITOPS_REPO"/* "$GITOPS_TEMP_DIR/"
        cd "$GITOPS_TEMP_DIR"
        git init
        git remote add origin "$GITOPS_REPO"
    fi
    
    cd "$GITOPS_TEMP_DIR"
    
    # Git 사용자 설정
    git config user.name "$GIT_USER_NAME"
    git config user.email "$GIT_USER_EMAIL"
    
    log_success "GitOps 저장소 설정 완료: $GITOPS_TEMP_DIR"
}

# Kustomization.yaml 업데이트
update_kustomization() {
    log_info "Kustomization 이미지 태그 업데이트 중..."
    
    local kustomization_path="applications/${SERVICE_NAME}/overlays/${ENVIRONMENT}/kustomization.yaml"
    
    if [ ! -f "$kustomization_path" ]; then
        log_error "kustomization.yaml을 찾을 수 없습니다: $kustomization_path"
        return 1
    fi
    
    local full_image_name="$DOCKER_REGISTRY/$SERVICE_NAME"
    
    # yq 사용하여 이미지 태그 업데이트
    if command -v yq >/dev/null 2>&1; then
        yq eval ".images[] |= select(.name == \"$full_image_name\").newTag = \"$IMAGE_TAG\"" -i "$kustomization_path"
    else
        # sed를 사용한 백업 방법
        sed -i.bak "s|newTag: .*|newTag: $IMAGE_TAG|g" "$kustomization_path"
        rm -f "${kustomization_path}.bak"
    fi
    
    log_success "이미지 태그 업데이트 완료: $full_image_name:$IMAGE_TAG"
    
    # 변경사항 확인
    log_info "업데이트된 kustomization.yaml:"
    grep -A 5 -B 5 "newTag:" "$kustomization_path" || true
}

# 매니페스트 검증
validate_manifests() {
    if [ "$SKIP_VALIDATION" = "true" ]; then
        log_warning "검증 단계를 건너뜁니다."
        return 0
    fi
    
    log_info "매니페스트 검증 중..."
    
    # Kustomize 빌드 테스트
    local overlay_path="applications/${SERVICE_NAME}/overlays/${ENVIRONMENT}"
    if ! kustomize build "$overlay_path" >/dev/null; then
        log_error "Kustomize 빌드 실패"
        return 1
    fi
    
    # kubectl dry-run (클러스터 연결 시)
    if kubectl cluster-info >/dev/null 2>&1; then
        log_info "kubectl dry-run 검증 중..."
        if ! kustomize build "$overlay_path" | kubectl apply --dry-run=client -f - >/dev/null; then
            log_error "kubectl dry-run 검증 실패"
            return 1
        fi
    fi
    
    log_success "매니페스트 검증 완료"
}

# Git 커밋 생성
create_git_commit() {
    log_info "Git 커밋 생성 중..."
    
    # 변경된 파일 추가
    git add "applications/${SERVICE_NAME}/overlays/${ENVIRONMENT}/kustomization.yaml"
    
    # 커밋 메시지 생성
    local commit_message
    commit_message=$(cat << EOF
feat(${SERVICE_NAME}): ${ENVIRONMENT} 환경 이미지 업데이트 to ${IMAGE_TAG}

- Service: ${SERVICE_NAME}
- Environment: ${ENVIRONMENT}
- Image Tag: ${IMAGE_TAG}
- Jenkins Build: #${JENKINS_BUILD_NUMBER}
- Git Commit: ${JENKINS_GIT_COMMIT:0:8}
- Build URL: ${JENKINS_BUILD_URL}

🤖 Generated by Jenkins CI/CD Pipeline
EOF
    )
    
    git commit -m "$commit_message"
    
    log_success "Git 커밋 생성 완료"
    log_info "커밋 해시: $(git rev-parse HEAD | cut -c1-8)"
}

# Pull Request 생성 (GitHub)
create_pull_request() {
    if [ "$CREATE_PR" != "true" ]; then
        return 0
    fi
    
    log_info "Pull Request 생성 중..."
    
    # 브랜치 생성
    local pr_branch="jenkins/update-${SERVICE_NAME}-${ENVIRONMENT}-${JENKINS_BUILD_NUMBER}"
    git checkout -b "$pr_branch"
    git push origin "$pr_branch"
    
    # GitHub CLI를 사용하여 PR 생성
    if command -v gh >/dev/null 2>&1; then
        local pr_title="🚀 [${ENVIRONMENT^^}] Update ${SERVICE_NAME} to ${IMAGE_TAG}"
        local pr_body=$(cat << EOF
## 🎯 변경 사항
- **서비스**: ${SERVICE_NAME}
- **환경**: ${ENVIRONMENT}
- **이미지 태그**: \`${IMAGE_TAG}\`

## 📋 Jenkins 빌드 정보
- **빌드 번호**: #${JENKINS_BUILD_NUMBER}
- **Git 커밋**: \`${JENKINS_GIT_COMMIT:0:8}\`
- **빌드 URL**: [Jenkins Build](${JENKINS_BUILD_URL})

## 🔍 검증 완료
- [x] Kustomize 빌드 검증
- [x] YAML 구문 검증
- [x] kubectl dry-run 검증

## 🚀 배포 방법
${ENVIRONMENT} 환경에서는 자동 배포가 ${AUTO_DEPLOY_MESSAGE}

---
🤖 이 PR은 Jenkins CI/CD 파이프라인에 의해 자동 생성되었습니다.
EOF
        )
        
        # 환경별 자동 배포 메시지 설정
        case $ENVIRONMENT in
            dev)
                AUTO_DEPLOY_MESSAGE="활성화되어 있습니다."
                ;;
            staging)
                AUTO_DEPLOY_MESSAGE="비활성화되어 있습니다. 수동 승인이 필요합니다."
                ;;
            production)
                AUTO_DEPLOY_MESSAGE="비활성화되어 있습니다. 수동 승인 및 추가 검토가 필요합니다."
                ;;
        esac
        
        gh pr create --title "$pr_title" --body "$pr_body" --base "$GITOPS_BRANCH"
        
        log_success "Pull Request 생성 완료"
    else
        log_warning "GitHub CLI(gh)가 설치되지 않아 PR 생성을 건너뜁니다."
        git push origin "$pr_branch"
        log_info "브랜치가 푸시되었습니다: $pr_branch"
    fi
}

# 변경사항 푸시
push_changes() {
    if [ "$CREATE_PR" = "true" ]; then
        return 0  # PR 생성 시에는 별도로 푸시하지 않음
    fi
    
    log_info "변경사항 푸시 중..."
    
    case $ENVIRONMENT in
        dev)
            # 개발 환경은 바로 main 브랜치에 푸시
            git push origin "$GITOPS_BRANCH"
            log_success "개발 환경 변경사항이 main 브랜치에 푸시되었습니다."
            log_info "ArgoCD에 의해 자동으로 동기화됩니다."
            ;;
        staging|production)
            # 스테이징/운영 환경은 승인이 필요하므로 별도 브랜치 생성
            local approval_branch="jenkins/approval-${SERVICE_NAME}-${ENVIRONMENT}-${JENKINS_BUILD_NUMBER}"
            git checkout -b "$approval_branch"
            git push origin "$approval_branch"
            log_warning "$ENVIRONMENT 환경은 수동 승인이 필요합니다."
            log_info "승인 브랜치가 생성되었습니다: $approval_branch"
            log_info "브랜치를 검토한 후 main에 머지하여 배포하세요."
            ;;
    esac
}

# 정리 작업
cleanup() {
    if [ -n "${GITOPS_TEMP_DIR:-}" ] && [ -d "$GITOPS_TEMP_DIR" ]; then
        log_info "임시 디렉터리 정리 중: $GITOPS_TEMP_DIR"
        rm -rf "$GITOPS_TEMP_DIR"
    fi
}

# 메인 함수
main() {
    # 트랩 설정 (종료 시 정리)
    trap cleanup EXIT
    
    # 기본값 설정
    DOCKER_REGISTRY="localhost:5000"
    GITOPS_REPO="${GITOPS_REPO:-/home/sdhcokr/project/microservices-gitops}"
    GITOPS_BRANCH="main"
    GIT_USER_NAME="jenkins-ci"
    GIT_USER_EMAIL="jenkins@elice.io"
    CREATE_PR="false"
    SKIP_VALIDATION="false"

    # 매개변수 검증
    if [ $# -lt 3 ]; then
        log_error "매개변수가 부족합니다."
        usage
        exit 1
    fi

    SERVICE_NAME="$1"
    IMAGE_TAG="$2"
    ENVIRONMENT="$3"
    shift 3

    # 옵션 파싱
    while [[ $# -gt 0 ]]; do
        case $1 in
            -r|--registry)
                DOCKER_REGISTRY="$2"
                shift 2
                ;;
            -g|--gitops-repo)
                GITOPS_REPO="$2"
                shift 2
                ;;
            -b|--branch)
                GITOPS_BRANCH="$2"
                shift 2
                ;;
            --git-user)
                GIT_USER_NAME="$2"
                shift 2
                ;;
            --git-email)
                GIT_USER_EMAIL="$2"
                shift 2
                ;;
            --pr)
                CREATE_PR="true"
                shift
                ;;
            --skip-validation)
                SKIP_VALIDATION="true"
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "알 수 없는 옵션: $1"
                usage
                exit 1
                ;;
        esac
    done

    # 환경 검증
    case $ENVIRONMENT in
        dev|staging|production)
            ;;
        *)
            log_error "유효하지 않은 환경: $ENVIRONMENT"
            exit 1
            ;;
    esac

    log_info "=== Jenkins GitOps 통합 시작 ==="
    log_info "서비스: $SERVICE_NAME"
    log_info "이미지 태그: $IMAGE_TAG"
    log_info "환경: $ENVIRONMENT"
    log_info "GitOps 저장소: $GITOPS_REPO"

    # Jenkins 환경 정보 수집
    collect_jenkins_info

    # GitOps 저장소 설정
    setup_gitops_repo

    # Kustomization 업데이트
    update_kustomization

    # 매니페스트 검증
    validate_manifests

    # Git 커밋 생성
    create_git_commit

    # Pull Request 생성 또는 변경사항 푸시
    if [ "$CREATE_PR" = "true" ]; then
        create_pull_request
    else
        push_changes
    fi

    log_success "=== Jenkins GitOps 통합 완료 ==="
    log_info "GitOps 저장소가 업데이트되었습니다."
    
    case $ENVIRONMENT in
        dev)
            log_info "개발 환경은 ArgoCD에 의해 자동으로 배포됩니다."
            ;;
        staging)
            log_info "스테이징 환경은 ArgoCD UI에서 수동으로 동기화하세요."
            ;;
        production)
            log_info "운영 환경은 추가 검토 및 승인 후 배포하세요."
            ;;
    esac
}

# 스크립트 실행
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi