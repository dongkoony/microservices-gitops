#!/bin/bash

# Kubernetes 매니페스트 검증 스크립트
# 사용법: ./validate-manifests.sh [path] [options]

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
Kubernetes 매니페스트 검증 스크립트

사용법: $0 [path] [options]

매개변수:
  path          검증할 경로 (기본값: 현재 디렉터리)

옵션:
  -s, --service SERVICE     특정 서비스만 검증
  -e, --env ENVIRONMENT     특정 환경만 검증 (dev, staging, production)
  -k, --kustomize          Kustomize 빌드 검증
  -y, --yaml              YAML 구문 검증
  -d, --dry-run           Kubernetes dry-run 검증
  -p, --policy            정책 검증 (OPA/Gatekeeper)
  -a, --all               모든 검증 실행
  -v, --verbose           상세 출력
  -h, --help              도움말 출력

검증 유형:
  1. YAML 구문 검증 (yamllint)
  2. Kubernetes 매니페스트 구조 검증
  3. Kustomize 빌드 검증
  4. kubectl dry-run 검증
  5. 리소스 정책 검증
  6. 보안 정책 검증

예제:
  $0                                    # 현재 디렉터리 전체 검증
  $0 applications/api-gateway          # 특정 경로 검증
  $0 --service api-gateway --env dev   # 특정 서비스/환경 검증
  $0 --all --verbose                   # 모든 검증을 상세 모드로

EOF
}

# 필수 도구 확인
check_tools() {
    local missing_tools=()
    
    # 기본 도구
    for tool in kubectl kustomize; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_tools+=("$tool")
        fi
    done
    
    # 선택적 도구
    local optional_tools=("yamllint" "yq" "kubeval" "conftest")
    local available_optional=()
    
    for tool in "${optional_tools[@]}"; do
        if command -v "$tool" >/dev/null 2>&1; then
            available_optional+=("$tool")
        fi
    done
    
    if [ ${#missing_tools[@]} -gt 0 ]; then
        log_error "다음 필수 도구가 설치되지 않았습니다: ${missing_tools[*]}"
        exit 1
    fi
    
    log_info "사용 가능한 검증 도구: kubectl kustomize ${available_optional[*]}"
}

# YAML 구문 검증
validate_yaml_syntax() {
    local path="$1"
    local errors=0
    
    log_info "YAML 구문 검증 중: $path"
    
    if command -v yamllint >/dev/null 2>&1; then
        if yamllint -c <(echo "extends: relaxed") "$path" 2>/dev/null; then
            log_success "YAML 구문 검증 성공"
        else
            log_error "YAML 구문 검증 실패"
            ((errors++))
        fi
    else
        # yamllint가 없으면 기본 YAML 파싱 시도
        while IFS= read -r -d '' file; do
            if [[ $file == *.yaml || $file == *.yml ]]; then
                if ! python3 -c "import yaml; yaml.safe_load(open('$file'))" 2>/dev/null; then
                    log_error "YAML 구문 오류: $file"
                    ((errors++))
                fi
            fi
        done < <(find "$path" -type f \( -name "*.yaml" -o -name "*.yml" \) -print0)
        
        if [ $errors -eq 0 ]; then
            log_success "기본 YAML 구문 검증 성공"
        fi
    fi
    
    return $errors
}

# Kustomize 빌드 검증
validate_kustomize() {
    local path="$1"
    local errors=0
    
    log_info "Kustomize 빌드 검증 중: $path"
    
    # kustomization.yaml 파일이 있는 디렉터리 찾기
    while IFS= read -r -d '' kustomize_dir; do
        local dir=$(dirname "$kustomize_dir")
        log_info "Kustomize 빌드: $dir"
        
        if [ "$VERBOSE" = "true" ]; then
            kustomize build "$dir"
        else
            if kustomize build "$dir" >/dev/null 2>&1; then
                log_success "Kustomize 빌드 성공: $dir"
            else
                log_error "Kustomize 빌드 실패: $dir"
                if [ "$VERBOSE" = "true" ]; then
                    kustomize build "$dir" 2>&1 | head -20
                fi
                ((errors++))
            fi
        fi
    done < <(find "$path" -name "kustomization.yaml" -print0)
    
    return $errors
}

# Kubernetes 매니페스트 구조 검증
validate_k8s_manifests() {
    local path="$1"
    local errors=0
    
    log_info "Kubernetes 매니페스트 구조 검증 중: $path"
    
    # kubeval이 있으면 사용
    if command -v kubeval >/dev/null 2>&1; then
        while IFS= read -r -d '' file; do
            if [[ $file == *.yaml || $file == *.yml ]]; then
                if ! kubeval "$file" >/dev/null 2>&1; then
                    log_error "매니페스트 구조 검증 실패: $file"
                    if [ "$VERBOSE" = "true" ]; then
                        kubeval "$file" 2>&1 | head -10
                    fi
                    ((errors++))
                fi
            fi
        done < <(find "$path" -type f \( -name "*.yaml" -o -name "*.yml" \) -print0)
        
        if [ $errors -eq 0 ]; then
            log_success "Kubernetes 매니페스트 구조 검증 성공"
        fi
    else
        log_warning "kubeval이 설치되지 않아 매니페스트 구조 검증을 건너뜁니다."
    fi
    
    return $errors
}

# kubectl dry-run 검증
validate_kubectl_dry_run() {
    local path="$1"
    local errors=0
    
    log_info "kubectl dry-run 검증 중: $path"
    
    # Kubernetes 클러스터 연결 확인
    if ! kubectl cluster-info >/dev/null 2>&1; then
        log_warning "Kubernetes 클러스터에 연결할 수 없어 dry-run 검증을 건너뜁니다."
        return 0
    fi
    
    # kustomization.yaml이 있는 디렉터리에서 dry-run 실행
    while IFS= read -r -d '' kustomize_dir; do
        local dir=$(dirname "$kustomize_dir")
        log_info "kubectl dry-run: $dir"
        
        if kustomize build "$dir" | kubectl apply --dry-run=client -f - >/dev/null 2>&1; then
            log_success "kubectl dry-run 성공: $dir"
        else
            log_error "kubectl dry-run 실패: $dir"
            if [ "$VERBOSE" = "true" ]; then
                kustomize build "$dir" | kubectl apply --dry-run=client -f - 2>&1 | head -20
            fi
            ((errors++))
        fi
    done < <(find "$path" -name "kustomization.yaml" -print0)
    
    return $errors
}

# 보안 정책 검증
validate_security_policies() {
    local path="$1"
    local errors=0
    
    log_info "보안 정책 검증 중: $path"
    
    # 기본 보안 체크리스트
    while IFS= read -r -d '' file; do
        if [[ $file == *.yaml || $file == *.yml ]]; then
            local filename=$(basename "$file")
            
            # Deployment 보안 검증
            if grep -q "kind: Deployment" "$file"; then
                # securityContext 확인
                if ! grep -q "securityContext:" "$file"; then
                    log_warning "보안: securityContext가 없음: $filename"
                    ((errors++))
                fi
                
                # 리소스 제한 확인
                if ! grep -q "resources:" "$file"; then
                    log_warning "보안: 리소스 제한이 없음: $filename"
                    ((errors++))
                fi
                
                # readOnlyRootFilesystem 확인 (운영환경)
                if [[ $file == *production* ]] && ! grep -q "readOnlyRootFilesystem: true" "$file"; then
                    log_warning "보안: readOnlyRootFilesystem가 false: $filename"
                fi
            fi
            
            # Secret 평문 확인
            if grep -q "kind: Secret" "$file" && grep -q "data:" "$file"; then
                if grep -A 10 "data:" "$file" | grep -v "^[[:space:]]*#" | grep -q "[a-zA-Z0-9].*:.*[^=]$"; then
                    log_error "보안: Secret에 평문 데이터가 포함될 수 있음: $filename"
                    ((errors++))
                fi
            fi
        fi
    done < <(find "$path" -type f \( -name "*.yaml" -o -name "*.yml" \) -print0)
    
    if [ $errors -eq 0 ]; then
        log_success "기본 보안 정책 검증 통과"
    else
        log_warning "보안 정책 검증에서 $errors개의 문제 발견"
    fi
    
    # conftest (OPA) 검증
    if command -v conftest >/dev/null 2>&1; then
        if [ -f "policy/security.rego" ]; then
            log_info "OPA 보안 정책 검증 실행..."
            if conftest test --policy policy/ "$path"; then
                log_success "OPA 보안 정책 검증 성공"
            else
                log_error "OPA 보안 정책 검증 실패"
                ((errors++))
            fi
        fi
    fi
    
    return $errors
}

# 리소스 정책 검증
validate_resource_policies() {
    local path="$1"
    local errors=0
    
    log_info "리소스 정책 검증 중: $path"
    
    # HPA와 Deployment 복제본 일관성 확인
    while IFS= read -r -d '' dir; do
        local deployment_file="$dir/deployment.yaml"
        local hpa_file="$dir/hpa.yaml"
        
        if [ -f "$deployment_file" ] && [ -f "$hpa_file" ]; then
            local deployment_replicas
            deployment_replicas=$(yq eval '.spec.replicas // 1' "$deployment_file" 2>/dev/null || echo "1")
            
            local hpa_min_replicas
            hpa_min_replicas=$(yq eval '.spec.minReplicas // 1' "$hpa_file" 2>/dev/null || echo "1")
            
            if [ "$deployment_replicas" -lt "$hpa_min_replicas" ]; then
                log_warning "정책: Deployment 복제본($deployment_replicas) < HPA minReplicas($hpa_min_replicas): $(basename "$dir")"
                ((errors++))
            fi
        fi
    done < <(find "$path" -type d -name "overlays" -exec find {} -mindepth 1 -maxdepth 1 -type d \; -print0)
    
    if [ $errors -eq 0 ]; then
        log_success "리소스 정책 검증 통과"
    fi
    
    return $errors
}

# 검증 실행
run_validation() {
    local path="$1"
    local total_errors=0
    
    log_info "=== 매니페스트 검증 시작: $path ==="
    
    if [ "$VALIDATE_YAML" = "true" ]; then
        validate_yaml_syntax "$path" || ((total_errors+=$?))
    fi
    
    if [ "$VALIDATE_KUSTOMIZE" = "true" ]; then
        validate_kustomize "$path" || ((total_errors+=$?))
    fi
    
    if [ "$VALIDATE_K8S" = "true" ]; then
        validate_k8s_manifests "$path" || ((total_errors+=$?))
    fi
    
    if [ "$VALIDATE_DRY_RUN" = "true" ]; then
        validate_kubectl_dry_run "$path" || ((total_errors+=$?))
    fi
    
    if [ "$VALIDATE_SECURITY" = "true" ]; then
        validate_security_policies "$path" || ((total_errors+=$?))
    fi
    
    if [ "$VALIDATE_POLICY" = "true" ]; then
        validate_resource_policies "$path" || ((total_errors+=$?))
    fi
    
    if [ $total_errors -eq 0 ]; then
        log_success "=== 모든 검증 통과 ==="
    else
        log_error "=== 검증 실패: $total_errors개의 문제 발견 ==="
        exit 1
    fi
}

# 메인 함수
main() {
    # 기본값 설정
    local target_path="${1:-.}"
    SERVICE_FILTER=""
    ENV_FILTER=""
    VALIDATE_YAML="false"
    VALIDATE_KUSTOMIZE="false"
    VALIDATE_K8S="false"
    VALIDATE_DRY_RUN="false"
    VALIDATE_SECURITY="false"
    VALIDATE_POLICY="false"
    VERBOSE="false"

    # 첫 번째 인자가 옵션이면 현재 디렉터리를 기본으로 사용
    if [[ "$target_path" == -* ]]; then
        target_path="."
        set -- "$target_path" "$@"
    fi
    shift

    # 옵션 파싱
    while [[ $# -gt 0 ]]; do
        case $1 in
            -s|--service)
                SERVICE_FILTER="$2"
                shift 2
                ;;
            -e|--env)
                ENV_FILTER="$2"
                shift 2
                ;;
            -k|--kustomize)
                VALIDATE_KUSTOMIZE="true"
                shift
                ;;
            -y|--yaml)
                VALIDATE_YAML="true"
                shift
                ;;
            -d|--dry-run)
                VALIDATE_DRY_RUN="true"
                shift
                ;;
            -p|--policy)
                VALIDATE_POLICY="true"
                shift
                ;;
            --security)
                VALIDATE_SECURITY="true"
                shift
                ;;
            -a|--all)
                VALIDATE_YAML="true"
                VALIDATE_KUSTOMIZE="true"
                VALIDATE_K8S="true"
                VALIDATE_DRY_RUN="true"
                VALIDATE_SECURITY="true"
                VALIDATE_POLICY="true"
                shift
                ;;
            -v|--verbose)
                VERBOSE="true"
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

    # 기본 검증 활성화 (옵션이 없으면)
    if [ "$VALIDATE_YAML" = "false" ] && [ "$VALIDATE_KUSTOMIZE" = "false" ] && [ "$VALIDATE_K8S" = "false" ] && [ "$VALIDATE_DRY_RUN" = "false" ] && [ "$VALIDATE_SECURITY" = "false" ] && [ "$VALIDATE_POLICY" = "false" ]; then
        VALIDATE_YAML="true"
        VALIDATE_KUSTOMIZE="true"
        VALIDATE_K8S="true"
    fi

    # 필수 도구 확인
    check_tools

    # 경로 필터링
    if [ -n "$SERVICE_FILTER" ]; then
        target_path="applications/$SERVICE_FILTER"
        if [ -n "$ENV_FILTER" ]; then
            target_path="$target_path/overlays/$ENV_FILTER"
        fi
    fi

    # 경로 존재 확인
    if [ ! -d "$target_path" ]; then
        log_error "경로를 찾을 수 없습니다: $target_path"
        exit 1
    fi

    # 검증 실행
    run_validation "$target_path"
}

# 스크립트 실행
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi