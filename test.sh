#!/bin/bash
# 优化的 GCP API 密钥管理工具
# 支持 Gemini API 和 Vertex AI
# 版本: 2.2.1

# 仅启用 errtrace (-E) 与 nounset (-u)
set -Euo

# ===== 颜色定义 =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# ===== 全局配置 =====
# 版本信息
VERSION="2.2.0"
LAST_UPDATED="2025-05-24"

# 通用配置
PROJECT_PREFIX="${PROJECT_PREFIX:-gemini-key}"
MAX_RETRY_ATTEMPTS="${MAX_RETRY:-3}"
MAX_PARALLEL_JOBS="${CONCURRENCY:-20}"
BILLING_ACCOUNT="${BILLING_ACCOUNT:-}" # 全局变量，用于存储选择的结算账户
TEMP_DIR=""  # 将在初始化时设置

# Gemini模式配置
TIMESTAMP=$(date +%s)
# 改进的随机字符生成（兼容性更好）
if command -v openssl &>/dev/null; then
    RANDOM_CHARS=$(openssl rand -hex 2)
else
    RANDOM_CHARS=$(( RANDOM % 10000 ))
fi
EMAIL_USERNAME="momo${RANDOM_CHARS}${TIMESTAMP:(-4)}"
GEMINI_TOTAL_PROJECTS=175
PURE_KEY_FILE="key.txt"
COMMA_SEPARATED_KEY_FILE="comma_separated_keys_${EMAIL_USERNAME}.txt"
AGGREGATED_KEY_FILE="aggregated_verbose_keys_${EMAIL_USERNAME}.txt"
DELETION_LOG="project_deletion_$(date +%Y%m%d_%H%M%S).log"
CLEANUP_LOG="api_keys_cleanup_$(date +%Y%m%d_%H%M%S).log"

# Vertex模式配置
VERTEX_PROJECT_PREFIX="${VERTEX_PROJECT_PREFIX:-vertex}"
MAX_PROJECTS_PER_ACCOUNT=${MAX_PROJECTS_PER_ACCOUNT:-3}
SERVICE_ACCOUNT_NAME="${SERVICE_ACCOUNT_NAME:-vertex-admin}"
KEY_DIR="${KEY_DIR:-./keys}"
ENABLE_EXTRA_ROLES=("roles/iam.serviceAccountUser" "roles/aiplatform.user")

# ===== 初始化 =====
# 创建唯一的临时目录
TEMP_DIR=$(mktemp -d -t gcp_script_XXXXXX) || {
    echo "错误：无法创建临时目录"
    exit 1
}

# 创建密钥目录
mkdir -p "$KEY_DIR" 2>/dev/null || {
    echo "错误：无法创建密钥目录 $KEY_DIR"
    exit 1
}
chmod 700 "$KEY_DIR" 2>/dev/null || true

# 开始计时
SECONDS=0

# ===== 日志函数（带颜色） =====
log() { 
    local level="${1:-INFO}"
    local msg="${2:-}"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case "$level" in
        "INFO")     echo -e "${CYAN}[${timestamp}] [INFO] ${msg}${NC}" ;;
        "SUCCESS")  echo -e "${GREEN}[${timestamp}] [SUCCESS] ${msg}${NC}" ;;
        "WARN")     echo -e "${YELLOW}[${timestamp}] [WARN] ${msg}${NC}" >&2 ;;
        "ERROR")    echo -e "${RED}[${timestamp}] [ERROR] ${msg}${NC}" >&2 ;;
        *)          echo "[${timestamp}] [${level}] ${msg}" ;;
    esac
}

# ===== 错误处理 =====
handle_error() {
    local exit_code=$?
    local line_no=$1
    
    # 忽略某些非严重错误
    case $exit_code in
        141)  # SIGPIPE
            return 0
            ;;
        130)  # Ctrl+C
            log "INFO" "用户中断操作"
            exit 130
            ;;
    esac
    
    # 记录错误
    log "ERROR" "在第 ${line_no} 行发生错误 (退出码 ${exit_code})"
    
    # 严重错误才终止
    if [ $exit_code -gt 1 ]; then
        log "ERROR" "发生严重错误，请检查日志"
        return $exit_code
    else
        log "WARN" "发生非严重错误，继续执行"
        return 0
    fi
}

# 设置错误处理
trap 'handle_error $LINENO' ERR

# ===== 清理函数 =====
cleanup_resources() {
    local exit_code=$?
    
    # 清理临时文件
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR" 2>/dev/null || true
        log "INFO" "已清理临时文件"
    fi
    
    # 如果是正常退出，显示感谢信息
    if [ $exit_code -eq 0 ]; then
        echo -e "\n${CYAN}感谢使用 GCP API 密钥管理工具${NC}"
        echo -e "${YELLOW}请记得检查并删除不需要的项目以避免额外费用${NC}"
    fi
}

# 设置退出处理
trap cleanup_resources EXIT

# ===== 工具函数 =====

# 改进的重试函数（支持命令）
retry() {
    local max_attempts="$MAX_RETRY_ATTEMPTS"
    local attempt=1
    local delay
    
    while [ $attempt -le $max_attempts ]; do
        if "$@"; then
            return 0
        fi
        
        local error_code=$?
        
        if [ $attempt -ge $max_attempts ]; then
            log "ERROR" "命令在 ${max_attempts} 次尝试后失败: $*"
            return $error_code
        fi
        
        delay=$(( attempt * 5 + RANDOM % 3 ))
        log "WARN" "重试 ${attempt}/${max_attempts}: $* (等待 ${delay}s)"
        sleep $delay
        attempt=$((attempt + 1)) || true
    done
}

# 检查命令是否存在
require_cmd() { 
    if ! command -v "$1" &>/dev/null; then
        log "ERROR" "缺少依赖: $1"
        exit 1
    fi
}

# 交互确认（支持非交互式环境）
ask_yes_no() {
    local prompt="$1"
    local default="${2:-N}"
    local resp
    
    # 非交互式环境
    if [ ! -t 0 ]; then
        if [[ "$default" =~ ^[Yy]$ ]]; then
            log "INFO" "非交互式环境，自动选择: 是"
            return 0
        else
            log "INFO" "非交互式环境，自动选择: 否"
            return 1
        fi
    fi
    
    # 交互式环境
    if [[ "$default" == "N" ]]; then
        read -r -p "${prompt} [y/N]: " resp || resp="$default"
    else
        read -r -p "${prompt} [Y/n]: " resp || resp="$default"
    fi
    
    resp=${resp:-$default}
    [[ "$resp" =~ ^[Yy]$ ]]
}

# 生成唯一后缀
unique_suffix() { 
    if command -v uuidgen &>/dev/null; then
        uuidgen | tr -d '-' | cut -c1-6 | tr '[:upper:]' '[:lower:]'
    else
        echo "$(date +%s%N 2>/dev/null || date +%s)${RANDOM}" | sha256sum | cut -c1-6
    fi
}

# 生成项目ID
new_project_id() {
    local prefix="${1:-$PROJECT_PREFIX}"
    local suffix
    suffix=$(unique_suffix)
    echo "${prefix}-${suffix}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | cut -c1-30
}

# 安全检测服务是否已启用
is_service_enabled() {
    local proj="$1"
    local svc="$2"
    
    gcloud services list --enabled --project="$proj" --filter="name:${svc}" --format='value(name)' 2>/dev/null | grep -q .
}

# 带错误处理的命令执行
safe_exec() {
    local output
    local status
    
    output=$("$@" 2>&1)
    status=$?
    
    if [ $status -ne 0 ]; then
        echo "$output" >&2
        return $status
    fi
    
    echo "$output"
    return 0
}

# 检查环境
check_env() {
    log "INFO" "检查环境配置..."
    
    # 检查必要命令
    require_cmd gcloud
    
    # 检查 gcloud 配置
    if ! gcloud config list account --quiet &>/dev/null; then
        log "ERROR" "请先运行 'gcloud init' 初始化"
        exit 1
    fi
    
    # 检查登录状态
    local active_account
    active_account=$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null || true)
    
    if [ -z "$active_account" ]; then
        log "ERROR" "请先运行 'gcloud auth login' 登录"
        exit 1
    fi
    
    log "SUCCESS" "环境检查通过 (账号: ${active_account})"
}

# 选择结算账户的公共函数
select_billing_account() {
    log "INFO" "正在检查可用的结算账户..."
    local billing_accounts
    billing_accounts=$(gcloud billing accounts list --filter='open=true' --format='value(name,displayName)' 2>/dev/null || echo "")
    
    if [ -z "$billing_accounts" ]; then
        log "ERROR" "未找到任何开放的结算账户。"
        log "ERROR" "请访问 Google Cloud Console 创建或检查您的结算账户。"
        return 1
    fi
    
    local billing_array=()
    while IFS=$'\t' read -r id name; do
        billing_array+=("${id##*/} - $name")
    done <<< "$billing_accounts"
    
    local billing_count=${#billing_array[@]}
    
    if [ "$billing_count" -eq 1 ]; then
        BILLING_ACCOUNT="${billing_array[0]%% - *}"
        log "SUCCESS" "已自动选择唯一的结算账户: ${BILLING_ACCOUNT}"
    else
        echo "可用的结算账户:"
        for ((i=0; i<billing_count; i++)); do
            echo "$((i+1)). ${billing_array[i]}"
        done
        echo
        
        local acc_num
        read -r -p "请选择一个结算账户 [1-${billing_count}]: " acc_num
        
        if [[ "$acc_num" =~ ^[0-9]+$ ]] && [ "$acc_num" -ge 1 ] && [ "$acc_num" -le "$billing_count" ]; then
            BILLING_ACCOUNT="${billing_array[$((acc_num-1))]%% - *}"
            log "SUCCESS" "已选择结算账户: ${BILLING_ACCOUNT}"
        else
            log "ERROR" "无效的选择，操作已中止。"
            return 1
        fi
    fi
    return 0
}


# 配额检查（修复版）
check_quota() {
    log "INFO" "检查项目创建配额..."
    
    local current_project
    current_project=$(gcloud config get-value project 2>/dev/null || true)
    
    if [ -z "$current_project" ]; {
        log "WARN" "未设置默认项目，跳过配额检查"
        return 0
    }
    
    local projects_quota=""
    local quota_output
    
    # 尝试获取配额（GA版本）
    if quota_output=$(gcloud services quota list \
        --service=cloudresourcemanager.googleapis.com \
        --consumer="projects/${current_project}" \
        --filter='metric=cloudresourcemanager.googleapis.com/project_create_requests' \
        --format=json 2>/dev/null); then
        
        projects_quota=$(echo "$quota_output" | grep -oP '"effectiveLimit":\s*"\K[^"]+' | head -n 1)
    fi
    
    # 如果GA版本失败，尝试Alpha版本
    if [ -z "$projects_quota" ]; {
        log "INFO" "尝试使用 alpha 命令获取配额..."
        
        if quota_output=$(gcloud alpha services quota list \
            --service=cloudresourcemanager.googleapis.com \
            --consumer="projects/${current_project}" \
            --filter='metric:cloudresourcemanager.googleapis.com/project_create_requests' \
            --format=json 2>/dev/null); then
            
            projects_quota=$(echo "$quota_output" | grep -oP '"INT64":\s*"\K[^"]+' | head -n 1)
        fi
    }
    
    # 处理配额结果
    if [ -z "$projects_quota" ] || ! [[ "$projects_quota" =~ ^[0-9]+$ ]]; then
        log "WARN" "无法获取配额信息，将继续执行"
        if ! ask_yes_no "无法检查配额，是否继续？" "N"; then
            return 1
        fi
        return 0
    fi
    
    local quota_limit=$projects_quota
    log "INFO" "项目创建配额限制: ${quota_limit}"
    
    # 检查Gemini项目数量
    if [ "${GEMINI_TOTAL_PROJECTS:-0}" -gt "$quota_limit" ]; then
        log "WARN" "计划创建的项目数(${GEMINI_TOTAL_PROJECTS})超过配额(${quota_limit})"
        
        echo "请选择："
        echo "1. 继续尝试创建 ${GEMINI_TOTAL_PROJECTS} 个项目"
        echo "2. 调整为创建 ${quota_limit} 个项目"
        echo "3. 取消操作"
        
        local choice
        read -r -p "请选择 [1-3]: " choice
        
        case "$choice" in
            1) log "INFO" "将尝试创建 ${GEMINI_TOTAL_PROJECTS} 个项目" ;;
            2) GEMINI_TOTAL_PROJECTS=$quota_limit
               log "INFO" "已调整为创建 ${GEMINI_TOTAL_PROJECTS} 个项目" ;;
            *) log "INFO" "操作已取消"
               return 1 ;;
        esac
    fi
    
    return 0
}

# 启用服务API
enable_services() {
    local proj="$1"
    shift
    
    local services=("$@")
    
    # 如果没有指定服务，使用默认列表
    if [ ${#services[@]} -eq 0 ]; then
        services=(
            "aiplatform.googleapis.com"
            "iam.googleapis.com"
            "iamcredentials.googleapis.com"
            "cloudresourcemanager.googleapis.com"
            "generativelanguage.googleapis.com" # 确保Gemini API也在这里
        )
    fi
    
    log "INFO" "为项目 ${proj} 启用必要的API服务..."
    
    local failed=0
    for svc in "${services[@]}"; do
        if is_service_enabled "$proj" "$svc"; then
            log "INFO" "服务 ${svc} 已启用"
            continue
        fi
        
        log "INFO" "启用服务: ${svc}"
        if retry gcloud services enable "$svc" --project="$proj" --quiet; then
            log "SUCCESS" "成功启用服务: ${svc}"
        else
            log "ERROR" "无法启用服务: ${svc}"
            failed=$((failed + 1)) || true
        fi
    done
    
    if [ $failed -gt 0 ]; then
        log "WARN" "有 ${failed} 个服务启用失败"
        return 1
    fi
    
    return 0
}

# 进度条显示
show_progress() {
    local completed="${1:-0}"
    local total="${2:-1}"
    
    # 参数验证
    if [ "$total" -le 0 ]; then
        return
    fi
    
    # 确保不超过总数
    if [ "$completed" -gt "$total" ]; then
        completed=$total
    fi
    
    # 计算百分比
    local percent=$((completed * 100 / total))
    local bar_length=50
    local filled=$((percent * bar_length / 100))
    
    # 生成进度条 - 使用安全的方式循环
    local bar=""
    local i=0
    while [ $i -lt $filled ]; do
        bar+="█"
        i=$((i + 1)) || true
    done
    
    i=$filled
    while [ $i -lt $bar_length ]; do
        bar+="░"
        i=$((i + 1)) || true
    done
    
    # 显示进度
    printf "\r[%s] %3d%% (%d/%d)" "$bar" "$percent" "$completed" "$total"
    
    # 完成时换行
    if [ "$completed" -eq "$total" ]; then
        echo
    fi
}

# JSON解析（改进版本）
parse_json() {
    local json="$1"
    local field="$2"
    
    if [ -z "$json" ]; then
        log "ERROR" "JSON解析: 输入为空"
        return 1
    fi
    
    # 尝试使用 jq（如果可用）
    if command -v jq &>/dev/null; then
        local result
        result=$(echo "$json" | jq -r "$field" 2>/dev/null)
        if [ -n "$result" ] && [ "$result" != "null" ]; then
            echo "$result"
            return 0
        fi
    fi
    
    # 备用方法 - 针对keyString专门处理
    if [ "$field" = ".keyString" ]; then
        local value
        # 尝试多种模式匹配
        value=$(echo "$json" | grep -o '"keyString":"[^"]*"' | sed 's/"keyString":"//;s/"$//' | head -n 1)
        
        if [ -z "$value" ]; then
            # 第二种尝试
            value=$(echo "$json" | grep -o '"keyString" *: *"[^"]*"' | sed 's/"keyString" *: *"//;s/"$//' | head -n 1)
        fi
        
        if [ -n "$value" ]; then
            echo "$value"
            return 0
        fi
    fi
    
    # 通用字段处理
    local field_name
    field_name=$(echo "$field" | sed 's/^\.//; s/\[[0-9]*\]//g')
    local value
    value=$(echo "$json" | grep -o "\"$field_name\":[^,}]*" | sed "s/\"$field_name\"://;s/\"//g;s/^ *//;s/ *$//" | head -n 1)
    
    if [ -n "$value" ] && [ "$value" != "null" ]; then
        echo "$value"
        return 0
    fi
    
    log "WARN" "JSON解析: 无法提取字段 $field"
    return 1
}

# 写入密钥文件
write_keys_to_files() {
    local api_key="$1"
    
    if [ -z "$api_key" ]; then
        log "ERROR" "密钥为空，无法写入文件"
        return 1
    fi
    
    # 使用文件锁确保并发安全
    {
        flock -x 9
        
        # 写入纯密钥文件
        echo "$api_key" >> "$PURE_KEY_FILE"
        
        # 写入逗号分隔文件
        if [ -s "$COMMA_SEPARATED_KEY_FILE" ]; then
            echo -n "," >> "$COMMA_SEPARATED_KEY_FILE"
        fi
        echo -n "$api_key" >> "$COMMA_SEPARATED_KEY_FILE"
        
    } 9>"${TEMP_DIR}/keyfile.lock"
}

# ===== Gemini 相关函数 =====

# Gemini主菜单
gemini_main() {
    local start_time=$SECONDS
    
    echo -e "\n${CYAN}${BOLD}======================================================"
    echo -e "    Google Gemini API 密钥管理工具"
    echo -e "======================================================${NC}\n"
    
    check_env || return 1
    
    echo -e "${YELLOW}提示: Gemini API 需要绑定结算账户以确保所有功能可用。${NC}"
    echo -e "${YELLOW}虽然有免费额度，但超出部分会产生费用。${NC}\n"
    
    echo "请选择操作："
    echo "1. 创建新项目并获取API密钥"
    echo "2. 从现有项目获取API密钥"
    echo "3. 删除现有项目"
    echo "0. 返回主菜单"
    echo
    
    local choice
    read -r -p "请选择 [0-3]: " choice
    
    case "$choice" in
        1) gemini_create_projects ;;
        2) gemini_get_keys_from_existing ;;
        3) gemini_delete_projects ;;
        0) return 0 ;;
        *) log "ERROR" "无效选项"; return 1 ;;
    esac
    
    # 显示执行时间
    local duration=$((SECONDS - start_time))
    log "INFO" "操作完成，耗时: $((duration / 60))分$((duration % 60))秒"
}

# 创建Gemini项目 (已按要求修改)
gemini_create_projects() {
    log "INFO" "====== 创建新项目并获取Gemini API密钥 ======"

    # 【修改】强制选择结算账户，不再询问
    log "INFO" "为使用Gemini API，需要为新项目绑定一个结算账户。"
    if ! select_billing_account; then
        log "ERROR" "必须选择一个结算账户才能继续。操作已中止。"
        return 1
    fi

    # 检查配额
    check_quota || return 1
    
    # 询问项目数量
    local num_projects
    read -r -p "请输入要创建的项目数量 [默认: 5]: " num_projects
    num_projects=${num_projects:-5}
    
    if ! [[ "$num_projects" =~ ^[0-9]+$ ]] || [ "$num_projects" -lt 1 ] || [ "$num_projects" -gt 100 ]; then
        log "ERROR" "无效的项目数量 (请输入1-100之间的数字)"
        return 1
    fi
    
    # 询问项目前缀
    local project_prefix
    read -r -p "请输入项目前缀 (默认: gemini-api): " project_prefix
    project_prefix=${project_prefix:-gemini-api}
    
    # 验证前缀
    if ! [[ "$project_prefix" =~ ^[a-z][a-z0-9-]{0,20}$ ]]; then
        log "WARN" "项目前缀格式无效，使用默认值 'gemini-api'"
        project_prefix="gemini-api"
    fi
    
    # 确认操作
    echo -e "\n${YELLOW}即将创建 ${num_projects} 个项目，前缀: ${project_prefix}${NC}"
    echo -e "${YELLOW}所有项目将自动绑定到结算账户: ${BOLD}${BILLING_ACCOUNT}${NC}"
    if ! ask_yes_no "确认继续？" "N"; then
        log "INFO" "操作已取消"
        return 1
    fi
    
    # 准备输出文件
    local key_file="gemini_keys_$(date +%Y%m%d_%H%M%S).txt"
    local csv_file="gemini_keys_$(date +%Y%m%d_%H%M%S).csv"
    
    > "$key_file"
    echo -n > "$csv_file"
    
    log "INFO" "开始创建项目..."
    
    local success=0
    local failed=0
    
    local i=1
    while [ $i -le $num_projects ]; do
        local project_id
        project_id=$(new_project_id "$project_prefix")
        
        log "INFO" "[${i}/${num_projects}] 创建项目: ${project_id}"
        
        # 创建项目
        if ! retry gcloud projects create "$project_id" --quiet; then
            log "ERROR" "创建项目 ${project_id} 失败"
            failed=$((failed + 1)) || true
            show_progress "$i" "$num_projects"
            i=$((i + 1)) || true
            continue
        fi
        
        # 【修改】强制绑定结算账户
        log "INFO" "为项目 ${project_id} 关联结算账户..."
        if ! retry gcloud billing projects link "$project_id" --billing-account="$BILLING_ACCOUNT" --quiet; then
            log "ERROR" "关联结算账户失败: ${project_id}"
            log "INFO" "正在清理创建失败的项目: ${project_id}"
            gcloud projects delete "$project_id" --quiet 2>/dev/null || log "WARN" "清理项目 ${project_id} 失败，请手动检查。"
            failed=$((failed + 1)) || true
            show_progress "$i" "$num_projects"
            i=$((i + 1)) || true
            continue
        fi
        log "SUCCESS" "成功为项目 ${project_id} 绑定结算账户。"

        # 启用 API
        log "INFO" "启用 Generative Language API..."
        if ! retry gcloud services enable generativelanguage.googleapis.com --project="$project_id" --quiet; then
            log "ERROR" "启用API失败: ${project_id}"
            failed=$((failed + 1)) || true
            show_progress "$i" "$num_projects"
            i=$((i + 1)) || true
            continue
        fi
        
        # 创建API密钥
        log "INFO" "创建API密钥..."
        local key_output
        if ! key_output=$(retry gcloud services api-keys create \
            --project="$project_id" \
            --display-name="Gemini API Key" \
            --api-target=service=generativelanguage.googleapis.com \
            --format=json --quiet); then
            
            log "ERROR" "创建API密钥失败: ${project_id}"
            failed=$((failed + 1)) || true
            show_progress "$i" "$num_projects"
            i=$((i + 1)) || true
            continue
        fi
        
        # 提取密钥
        local api_key
        api_key=$(parse_json "$key_output" ".keyString")
        
        if [ -z "$api_key" ]; then
            log "ERROR" "无法提取API密钥: ${project_id}"
            failed=$((failed + 1)) || true
        else
            echo "$api_key" >> "$key_file"
            if [ -s "$csv_file" ]; then
                echo -n "," >> "$csv_file"
            fi
            echo -n "$api_key" >> "$csv_file"
            
            log "SUCCESS" "成功获取项目 ${project_id} 的API密钥"
            success=$((success + 1)) || true
        fi
        
        show_progress "$i" "$num_projects"
        
        # 避免过快请求
        sleep 1
        
        # 递增计数器
        i=$((i + 1)) || true
    done
    
    # 显示结果
    echo
    log "SUCCESS" "操作完成！"
    echo -e "${GREEN}成功: ${success}, ${RED}失败: ${failed}${NC}"
    echo "密钥已保存到:"
    echo "  - 每行一个: ${BOLD}${key_file}${NC}"
    echo "  - 逗号分隔: ${BOLD}${csv_file}${NC}"
    
    if [ "$success" -gt 0 ] && [ -s "$csv_file" ]; then
        echo -e "\n${CYAN}所有密钥 (逗号分隔):${NC}"
        cat "$csv_file"
        echo
    fi
}


# ===== Vertex AI 相关函数 =====
# Vertex AI 部分保持不变，因为它已经使用了正确的逻辑

# Vertex主菜单
vertex_main() {
    local start_time=$SECONDS
    
    echo -e "\n${CYAN}${BOLD}======================================================"
    echo -e "    Google Vertex AI 密钥管理工具"
    echo -e "======================================================${NC}\n"
    
    check_env || return 1
    
    echo -e "${YELLOW}警告: Vertex AI 需要结算账户，会产生实际费用！${NC}\n"
    
    # 【优化】调用公共函数选择结算账户
    if ! select_billing_account; then
        return 1
    fi
    
    # 显示警告
    echo -e "\n${YELLOW}${BOLD}重要提醒:${NC}"
    echo -e "${YELLOW}• 使用 Vertex AI 将消耗 \$300 免费额度${NC}"
    echo -e "${YELLOW}• 超出免费额度后将产生实际费用${NC}"
    echo -e "${YELLOW}• 请确保已设置预算警报${NC}"
    echo
    
    if ! ask_yes_no "已了解费用风险，确认继续？" "N"; then
        log "INFO" "操作已取消"
        return 1
    fi
    
    # Vertex操作菜单
    echo -e "\n请选择操作:"
    echo "1. 创建新项目并生成密钥"
    echo "2. 在现有项目上配置 Vertex AI"
    echo "3. 管理服务账号密钥"
    echo "0. 返回主菜单"
    echo
    
    local choice
    read -r -p "请选择 [0-3]: " choice
    
    case "$choice" in
        1) vertex_create_projects ;;
        2) vertex_configure_existing ;;
        3) vertex_manage_keys ;;
        0) return 0 ;;
        *) log "ERROR" "无效选项"; return 1 ;;
    esac
    
    # 显示执行时间
    local duration=$((SECONDS - start_time))
    log "INFO" "操作完成，耗时: $((duration / 60))分$((duration % 60))秒"
}

# 创建Vertex项目
vertex_create_projects() {
    log "INFO" "====== 创建新项目并配置 Vertex AI ======"
    
    # 获取当前结算账户的项目数
    log "INFO" "检查结算账户 ${BILLING_ACCOUNT} 的项目数..."
    local existing_projects
    existing_projects=$(gcloud projects list --filter="billingAccountName:billingAccounts/${BILLING_ACCOUNT}" --format='value(projectId)' 2>/dev/null | wc -l)
    
    log "INFO" "当前已有 ${existing_projects} 个项目"
    
    local max_new=$((MAX_PROJECTS_PER_ACCOUNT - existing_projects))
    if [ "$max_new" -le 0 ]; then
        log "WARN" "结算账户已达到最大项目数限制 (${MAX_PROJECTS_PER_ACCOUNT})"
        return 1
    fi
    
    # 询问创建数量
    log "INFO" "最多可创建 ${max_new} 个新项目"
    local num_projects
    read -r -p "请输入要创建的项目数量 [1-${max_new}]: " num_projects
    
    if ! [[ "$num_projects" =~ ^[0-9]+$ ]] || [ "$num_projects" -lt 1 ] || [ "$num_projects" -gt "$max_new" ]; then
        log "ERROR" "无效的项目数量"
        return 1
    fi
    
    # 询问项目前缀
    local project_prefix
    read -r -p "请输入项目前缀 (默认: vertex): " project_prefix
    project_prefix=${project_prefix:-vertex}
    
    # 确认操作
    echo -e "\n${YELLOW}即将创建 ${num_projects} 个项目${NC}"
    echo "项目前缀: ${project_prefix}"
    echo "结算账户: ${BILLING_ACCOUNT}"
    echo
    
    if ! ask_yes_no "确认继续？" "N"; then
        log "INFO" "操作已取消"
        return 1
    fi
    
    # 创建项目
    log "INFO" "开始创建项目..."
    local success=0
    local failed=0
    
    local i=1
    while [ $i -le $num_projects ]; do
        local project_id
        project_id=$(new_project_id "$project_prefix")
        
        log "INFO" "[${i}/${num_projects}] 创建项目: ${project_id}"
        
        # 创建项目
        if ! retry gcloud projects create "$project_id" --quiet; then
            log "ERROR" "创建项目失败: ${project_id}"
            failed=$((failed + 1)) || true
            show_progress "$i" "$num_projects"
            i=$((i + 1)) || true
            continue
        fi
        
        # 关联结算账户
        log "INFO" "关联结算账户..."
        if ! retry gcloud billing projects link "$project_id" --billing-account="$BILLING_ACCOUNT" --quiet; then
            log "ERROR" "关联结算账户失败: ${project_id}"
            gcloud projects delete "$project_id" --quiet 2>/dev/null
            failed=$((failed + 1)) || true
            show_progress "$i" "$num_projects"
            i=$((i + 1)) || true
            continue
        fi
        
        # 启用API
        log "INFO" "启用必要的API..."
        if ! enable_services "$project_id"; then
            log "ERROR" "启用API失败: ${project_id}"
            failed=$((failed + 1)) || true
            show_progress "$i" "$num_projects"
            i=$((i + 1)) || true
            continue
        fi
        
        # 配置服务账号
        log "INFO" "配置服务账号..."
        if vertex_setup_service_account "$project_id"; then
            log "SUCCESS" "成功配置项目: ${project_id}"
            success=$((success + 1)) || true
        else
            log "ERROR" "配置服务账号失败: ${project_id}"
            failed=$((failed + 1)) || true
        fi
        
        show_progress "$i" "$num_projects"
        
        # 避免过快请求
        sleep 2
        
        # 递增计数器
        i=$((i + 1)) || true
    done
    
    # 显示结果
    echo -e "\n${GREEN}操作完成！${NC}"
    echo "成功: ${success}, 失败: ${failed}"
    echo "服务账号密钥已保存在: ${KEY_DIR}"
}

# (其余函数如 gemini_get_keys_from_existing, gemini_delete_projects, vertex_configure_existing 等保持不变)
# ... 以下省略未修改的函数，以节省篇幅 ...
# ... (请将此代码块替换您脚本中的 gemini_create_projects 到 vertex_create_projects 之间的内容) ...
# ... 实际上，您只需用此完整脚本替换整个旧文件即可 ...

# ==============================================================
# 以下为脚本的其余部分，保持不变
# ==============================================================

# 从现有项目获取Gemini密钥
gemini_get_keys_from_existing() {
  # ... 此函数内容不变 ...
  log "INFO" "====== 从现有项目获取Gemini API密钥 ======"
    
    # 获取项目列表
    log "INFO" "获取项目列表..."
    local projects
    projects=$(gcloud projects list --format='value(projectId)' --filter='lifecycleState:ACTIVE' 2>/dev/null || echo "")
    
    if [ -z "$projects" ]; then
        log "ERROR" "未找到任何活跃项目"
        return 1
    fi
    
    # 转换为数组
    local project_array=()
    while IFS= read -r line; do
        project_array+=("$line")
    done <<< "$projects"
    
    local total=${#project_array[@]}
    log "INFO" "找到 ${total} 个项目"
    
    # 显示项目列表
    echo -e "\n项目列表:"
    local i=0
    while [ $i -lt $total ] && [ $i -lt 20 ]; do
        echo "$((i+1)). ${project_array[i]}"
        i=$((i + 1)) || true
    done
    
    if [ "$total" -gt 20 ]; then
        echo "... 还有 $((total-20)) 个项目"
    fi
    
    # 选择处理方式
    echo -e "\n请选择:"
    echo "1. 处理特定项目"
    echo "2. 处理所有项目"
    echo "0. 取消"
    
    local choice
    read -r -p "请选择 [0-2]: " choice
    
    local selected_projects=()
    
    case "$choice" in
        1)
            read -r -p "请输入项目编号（多个用空格分隔）: " -a numbers
            for num in "${numbers[@]}"; do
                if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "$total" ]; then
                    selected_projects+=("${project_array[$((num-1))]}")
                fi
            done
            ;;
        2)
            selected_projects=("${project_array[@]}")
            ;;
        0)
            log "INFO" "操作已取消"
            return 0
            ;;
        *)
            log "ERROR" "无效选项"
            return 1
            ;;
    esac
    
    if [ ${#selected_projects[@]} -eq 0 ]; then
        log "ERROR" "未选择任何项目"
        return 1
    fi
    
    # 确认操作
    echo -e "\n${YELLOW}将处理 ${#selected_projects[@]} 个项目${NC}"
    if ! ask_yes_no "确认继续？" "N"; then
        log "INFO" "操作已取消"
        return 1
    fi
    
    # 准备输出文件
    local key_file="gemini_keys_existing_$(date +%Y%m%d_%H%M%S).txt"
    local csv_file="gemini_keys_existing_$(date +%Y%m%d_%H%M%S).csv"
    
    > "$key_file"
    echo -n > "$csv_file"
    
    # 处理选定的项目
    local success=0
    local failed=0
    local current=0
    
    for project_id in "${selected_projects[@]}"; do
        current=$((current + 1)) || true
        log "INFO" "[${current}/${#selected_projects[@]}] 处理项目: ${project_id}"
        
        # 启用API
        if ! retry gcloud services enable generativelanguage.googleapis.com --project="$project_id" --quiet; then
            log "ERROR" "启用API失败: ${project_id}"
            failed=$((failed + 1)) || true
            show_progress "$current" "${#selected_projects[@]}"
            continue
        fi
        
        # 获取现有密钥
        local keys_list
        keys_list=$(gcloud services api-keys list --project="$project_id" --format='value(name)' 2>/dev/null || echo "")
        
        local got_key=false
        
        if [ -n "$keys_list" ]; then
            # 获取第一个密钥
            local key_name
            key_name=$(echo "$keys_list" | head -n 1)
            
            if [ -n "$key_name" ]; then
                local key_details
                key_details=$(gcloud services api-keys get-key-string "$key_name" --format=json 2>/dev/null || echo "")
                
                if [ -n "$key_details" ]; then
                    local api_key
                    api_key=$(parse_json "$key_details" ".keyString")
                    
                    if [ -n "$api_key" ]; then
                        echo "$api_key" >> "$key_file"
                        if [ -s "$csv_file" ]; then
                            echo -n "," >> "$csv_file"
                        fi
                        echo -n "$api_key" >> "$csv_file"
                        
                        log "SUCCESS" "获取到现有密钥"
                        success=$((success + 1)) || true
                        got_key=true
                    fi
                fi
            fi
        fi
        
        # 如果没有获取到现有密钥，创建新密钥
        if [ "$got_key" = false ]; then
            log "INFO" "创建新密钥..."
            
            local key_output
            if key_output=$(retry gcloud services api-keys create \
                --project="$project_id" \
                --display-name="Gemini API Key (New)" \
                --api-target=service=generativelanguage.googleapis.com \
                --format=json --quiet); then
                
                local api_key
                api_key=$(parse_json "$key_output" ".keyString")
                
                if [ -n "$api_key" ]; then
                    echo "$api_key" >> "$key_file"
                    if [ -s "$csv_file" ]; then
                        echo -n "," >> "$csv_file"
                    fi
                    echo -n "$api_key" >> "$csv_file"
                    
                    log "SUCCESS" "成功创建新密钥"
                    success=$((success + 1)) || true
                else
                    log "ERROR" "无法提取密钥"
                    failed=$((failed + 1)) || true
                fi
            else
                log "ERROR" "创建密钥失败"
                failed=$((failed + 1)) || true
            fi
        fi
        
        show_progress "$current" "${#selected_projects[@]}"
    done
    
    # 显示结果
    echo -e "\n${GREEN}操作完成！${NC}"
    echo "成功: ${success}, 失败: ${failed}"
    echo "密钥已保存到:"
    echo "- 每行一个: ${key_file}"
    echo "- 逗号分隔: ${csv_file}"
    
    if [ "$success" -gt 0 ] && [ -s "$csv_file" ]; then
        echo -e "\n${CYAN}密钥内容:${NC}"
        cat "$csv_file"
        echo
    fi
}

# 删除Gemini项目
gemini_delete_projects() {
  # ... 此函数内容不变 ...
  log "INFO" "====== 删除现有项目 ======"
    
    # 获取项目列表
    log "INFO" "获取项目列表..."
    local projects
    projects=$(gcloud projects list --format='value(projectId)' --filter='lifecycleState:ACTIVE' 2>/dev/null || echo "")
    
    if [ -z "$projects" ]; then
        log "ERROR" "未找到任何活跃项目"
        return 1
    fi
    
    # 转换为数组
    local project_array=()
    while IFS= read -r line; do
        project_array+=("$line")
    done <<< "$projects"
    
    local total=${#project_array[@]}
    log "INFO" "找到 ${total} 个项目"
    
    # 显示项目列表
    echo -e "\n项目列表:"
    local i=0
    while [ $i -lt $total ] && [ $i -lt 20 ]; do
        echo "$((i+1)). ${project_array[i]}"
        i=$((i + 1)) || true
    done
    
    if [ "$total" -gt 20 ]; then
        echo "... 还有 $((total-20)) 个项目"
    fi
    
    # 选择要删除的项目
    echo -e "\n请选择:"
    echo "1. 删除特定项目"
    echo "2. 删除包含特定前缀的项目"
    echo "0. 取消"
    
    local choice
    read -r -p "请选择 [0-2]: " choice
    
    local selected_projects=()
    
    case "$choice" in
        1)
            read -r -p "请输入项目编号（多个用空格分隔）: " -a numbers
            for num in "${numbers[@]}"; do
                if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "$total" ]; then
                    selected_projects+=("${project_array[$((num-1))]}")
                fi
            done
            ;;
        2)
            local prefix
            read -r -p "请输入项目前缀: " prefix
            for proj in "${project_array[@]}"; do
                if [[ "$proj" == "$prefix"* ]]; then
                    selected_projects+=("$proj")
                fi
            done
            ;;
        0)
            log "INFO" "操作已取消"
            return 0
            ;;
        *)
            log "ERROR" "无效选项"
            return 1
            ;;
    esac
    
    if [ ${#selected_projects[@]} -eq 0 ]; then
        log "ERROR" "未选择任何项目"
        return 1
    fi
    
    # 确认删除
    echo -e "\n${RED}${BOLD}警告: 即将删除 ${#selected_projects[@]} 个项目！${NC}"
    echo -e "${RED}此操作不可撤销！${NC}"
    echo
    echo "将删除的项目:"
    for proj in "${selected_projects[@]}"; do
        echo "  - $proj"
    done
    echo
    
    read -r -p "请输入 'DELETE' 确认删除: " confirm
    
    if [ "$confirm" != "DELETE" ]; then
        log "INFO" "删除操作已取消"
        return 1
    fi
    
    # 执行删除
    local success=0
    local failed=0
    local current=0
    
    for project_id in "${selected_projects[@]}"; do
        current=$((current + 1)) || true
        log "INFO" "[${current}/${#selected_projects[@]}] 删除项目: ${project_id}"
        
        if gcloud projects delete "$project_id" --quiet; then
            log "SUCCESS" "成功删除项目: ${project_id}"
            success=$((success + 1)) || true
        else
            log "ERROR" "删除项目失败: ${project_id}"
            failed=$((failed + 1)) || true
        fi
        
        show_progress "$current" "${#selected_projects[@]}"
    done
    
    # 显示结果
    echo -e "\n${GREEN}操作完成！${NC}"
    echo "成功删除: ${success}"
    echo "删除失败: ${failed}"
}

# 配置现有项目的Vertex AI
vertex_configure_existing() {
  # ... 此函数内容不变 ...
  log "INFO" "====== 在现有项目上配置 Vertex AI ======"
    
    # 获取项目列表
    log "INFO" "获取项目列表..."
    local projects
    # 先获取所有活跃项目
    local all_projects
    all_projects=$(gcloud projects list --format='value(projectId)' --filter="lifecycleState=ACTIVE" 2>/dev/null || echo "")
    
    # 筛选出与当前结算账户关联的项目
    local projects=""
    while IFS= read -r project_id; do
        if [ -n "$project_id" ]; then
            local billing_info
            billing_info=$(gcloud billing projects describe "$project_id" --format='value(billingAccountName)' 2>/dev/null || echo "")
            
            if [ -n "$billing_info" ] && [[ "$billing_info" == *"${BILLING_ACCOUNT}"* ]]; then
                projects="${projects}${projects:+$'\n'}${project_id}"
            fi
        fi
    done <<< "$all_projects"
    
    # 如果没有找到与结算账户关联的项目，提示用户
    if [ -z "$projects" ]; then
        log "WARN" "未找到与当前结算账户关联的项目"
        echo -e "\n${YELLOW}请选择操作:${NC}"
        echo "1. 显示所有项目（包括未关联当前结算账户的项目）"
        echo "2. 返回上级菜单"
        
        local list_choice
        read -r -p "请选择 [1-2]: " list_choice
        
        case "$list_choice" in
            1)
                log "INFO" "显示所有活跃项目"
                projects=$(gcloud projects list --format='value(projectId)' --filter='lifecycleState:ACTIVE' 2>/dev/null || echo "")
                ;;
            *)
                log "INFO" "返回上级菜单"
                return 0
                ;;
        esac
    else
        log "INFO" "找到与结算账户 ${BILLING_ACCOUNT} 关联的项目"
    fi
    
    if [ -z "$projects" ]; then
        log "ERROR" "未找到任何活跃项目"
        return 1
    fi
    
    # 转换为数组
    local project_array=()
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            project_array+=("$line")
        fi
    done <<< "$projects"
    
    local total=${#project_array[@]}
    
    # 检查是否找到项目
    if [ "$total" -eq 0 ]; then
        log "WARN" "未找到与当前结算账户关联的项目"
        echo -e "\n${YELLOW}请选择操作:${NC}"
        echo "1. 显示所有项目（包括未关联当前结算账户的项目）"
        echo "2. 返回上级菜单"
        
        local list_choice
        read -r -p "请选择 [1-2]: " list_choice
        
        case "$list_choice" in
            1)
                log "INFO" "显示所有活跃项目"
                # 使用先前获取的所有项目
                while IFS= read -r line; do
                    if [ -n "$line" ]; then
                        project_array+=("$line")
                    fi
                done <<< "$all_projects"
                total=${#project_array[@]}
                ;;
            *)
                log "INFO" "返回上级菜单"
                return 0
                ;;
        esac
    else
        log "INFO" "找到 ${total} 个与当前结算账户关联的项目"
    fi
    
    # 显示项目列表
    echo -e "\n项目列表:"
    for ((i=0; i<total && i<20; i++)); do
        local billing_info
        billing_info=$(gcloud billing projects describe "${project_array[i]}" --format='value(billingAccountName)' 2>/dev/null || echo "")
        
        local status=""
        if [ -n "$billing_info" ] && [[ "$billing_info" == *"${BILLING_ACCOUNT}"* ]]; then
            status="(已关联当前结算账户)"
        elif [ -n "$billing_info" ]; then
            status="(关联了其他结算账户)"
        else
            status="(未关联结算)"
        fi
        
        echo "$((i+1)). ${project_array[i]} ${status}"
    done
    
    if [ "$total" -gt 20 ]; then
        echo "... 还有 $((total-20)) 个项目"
    fi
    
    # 选择项目
    local selected_projects=()
    read -r -p "请输入项目编号（多个用空格分隔）: " -a numbers
    
    for num in "${numbers[@]}"; do
        if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "$total" ]; then
            selected_projects+=("${project_array[$((num-1))]}")
        fi
    done
    
    if [ ${#selected_projects[@]} -eq 0 ]; then
        log "ERROR" "未选择任何项目"
        return 1
    fi
    
    # 确认操作
    echo -e "\n${YELLOW}将为 ${#selected_projects[@]} 个项目配置 Vertex AI${NC}"
    if ! ask_yes_no "确认继续？" "N"; then
        log "INFO" "操作已取消"
        return 1
    fi
    
    # 处理选定的项目
    local success=0
    local failed=0
    local current=0
    
    for project_id in "${selected_projects[@]}"; do
        current=$((current + 1)) || true
        log "INFO" "[${current}/${#selected_projects[@]}] 处理项目: ${project_id}"
        
        # 检查结算账户
        local billing_info
        billing_info=$(gcloud billing projects describe "$project_id" --format='value(billingAccountName)' 2>/dev/null || echo "")
        
        if [ -z "$billing_info" ]; then
            log "WARN" "项目未关联结算账户，尝试关联..."
            if ! retry gcloud billing projects link "$project_id" --billing-account="$BILLING_ACCOUNT" --quiet; then
                log "ERROR" "关联结算账户失败: ${project_id}"
                failed=$((failed + 1)) || true
                show_progress "$current" "${#selected_projects[@]}"
                continue
            fi
        fi
        
        # 启用API
        log "INFO" "启用必要的API..."
        if ! enable_services "$project_id"; then
            log "ERROR" "启用API失败: ${project_id}"
            failed=$((failed + 1)) || true
            show_progress "$current" "${#selected_projects[@]}"
            continue
        fi
        
        # 配置服务账号
        log "INFO" "配置服务账号..."
        if vertex_setup_service_account "$project_id"; then
            log "SUCCESS" "成功配置项目: ${project_id}"
            success=$((success + 1)) || true
        else
            log "ERROR" "配置服务账号失败: ${project_id}"
            failed=$((failed + 1)) || true
        fi
        
        show_progress "$current" "${#selected_projects[@]}"
    done
    
    # 显示结果
    echo -e "\n${GREEN}操作完成！${NC}"
    echo "成功: ${success}, 失败: ${failed}"
    echo "服务账号密钥已保存在: ${KEY_DIR}"
}

# 配置Vertex服务账号
vertex_setup_service_account() {
  # ... 此函数内容不变 ...
    local project_id="$1"
    local sa_email="${SERVICE_ACCOUNT_NAME}@${project_id}.iam.gserviceaccount.com"
    
    # 检查服务账号是否存在
    if ! gcloud iam service-accounts describe "$sa_email" --project="$project_id" &>/dev/null; then
        log "INFO" "创建服务账号..."
        if ! retry gcloud iam service-accounts create "$SERVICE_ACCOUNT_NAME" \
            --display-name="Vertex AI Service Account" \
            --project="$project_id" --quiet; then
            log "ERROR" "创建服务账号失败"
            return 1
        fi
    else
        log "INFO" "服务账号已存在"
    fi
    
    # 分配角色
    local roles=(
        "roles/aiplatform.admin"
        "roles/iam.serviceAccountUser"
        "roles/iam.serviceAccountTokenCreator"
        "roles/aiplatform.user"
    )
    
    log "INFO" "分配IAM角色..."
    for role in "${roles[@]}"; do
        if retry gcloud projects add-iam-policy-binding "$project_id" \
            --member="serviceAccount:${sa_email}" \
            --role="$role" \
            --quiet &>/dev/null; then
            log "SUCCESS" "授予角色: ${role}"
        else
            log "WARN" "授予角色失败: ${role}"
        fi
    done
    
    # 生成密钥
    log "INFO" "生成服务账号密钥..."
    local key_file="${KEY_DIR}/${project_id}-${SERVICE_ACCOUNT_NAME}-$(date +%Y%m%d-%H%M%S).json"
    
    if retry gcloud iam service-accounts keys create "$key_file" \
        --iam-account="$sa_email" \
        --project="$project_id" \
        --quiet; then
        
        chmod 600 "$key_file"
        log "SUCCESS" "密钥已保存: ${key_file}"
        return 0
    else
        log "ERROR" "生成密钥失败"
        return 1
    fi
}

# 管理Vertex服务账号密钥
vertex_manage_keys() {
  # ... 此函数内容不变 ...
  log "INFO" "====== 管理服务账号密钥 ======"
    
    echo "请选择操作:"
    echo "1. 列出所有服务账号密钥"
    echo "2. 生成新密钥"
    echo "3. 删除旧密钥"
    echo "0. 返回"
    echo
    
    local choice
    read -r -p "请选择 [0-3]: " choice
    
    case "$choice" in
        1) vertex_list_keys ;;
        2) vertex_generate_keys ;;
        3) vertex_delete_keys ;;
        0) return 0 ;;
        *) log "ERROR" "无效选项"; return 1 ;;
    esac
}

# 列出Vertex密钥
vertex_list_keys() {
  # ... 此函数内容不变 ...
  log "INFO" "扫描密钥目录: ${KEY_DIR}"
    
    if [ ! -d "$KEY_DIR" ]; then
        log "ERROR" "密钥目录不存在"
        return 1
    fi
    
    local key_files=()
    while IFS= read -r -d '' file; do
        key_files+=("$file")
    done < <(find "$KEY_DIR" -name "*.json" -type f -print0 2>/dev/null)
    
    if [ ${#key_files[@]} -eq 0 ]; then
        log "INFO" "未找到任何密钥文件"
        return 0
    fi
    
    echo -e "\n找到 ${#key_files[@]} 个密钥文件:"
    for ((i=0; i<${#key_files[@]}; i++)); do
        local filename
        filename=$(basename "${key_files[i]}")
        local size
        size=$(stat -f%z "${key_files[i]}" 2>/dev/null || stat -c%s "${key_files[i]}" 2>/dev/null || echo "unknown")
        echo "$((i+1)). ${filename} (${size} bytes)"
    done
}

# ===== 主菜单 =====

# 显示主菜单
show_menu() {
    echo -e "\n${CYAN}${BOLD}======================================================"
    echo -e "     GCP API 密钥管理工具 v${VERSION}"
    echo -e "     更新日期: ${LAST_UPDATED}"
    echo -e "======================================================${NC}\n"
    
    # 显示当前账号信息
    local current_account
    current_account=$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -n 1)
    local current_project
    current_project=$(gcloud config get-value project 2>/dev/null || echo "未设置")
    
    echo "当前账号: ${current_account:-未登录}"
    echo "当前项目: ${current_project}"
    echo
    
    # 风险提示
    echo -e "${RED}${BOLD}⚠️  风险提示 ⚠️${NC}"
    echo -e "${YELLOW}• Gemini API 和 Vertex AI 都需要绑定结算账户${NC}"
    echo -e "${YELLOW}• 创建资源会产生实际费用（超出免费额度后）${NC}"
    echo
    
    # 主菜单选项
    echo "请选择功能:"
    echo "1. Gemini API 密钥管理"
    echo "2. Vertex AI 密钥管理"
    echo "3. 设置和配置"
    echo "4. 帮助文档"
    echo "0. 退出"
    echo
    
    local choice
    read -r -p "请选择 [0-4]: " choice
    
    case "$choice" in
        1) gemini_main ;;
        2) vertex_main ;;
        3) show_settings ;;
        4) show_help ;;
        0) exit 0 ;;
        *) log "ERROR" "无效选项" ;;
    esac
}

# 显示设置菜单
show_settings() {
  # ... 此函数内容不变 ...
  echo -e "\n${CYAN}${BOLD}====== 设置和配置 ======${NC}\n"
    
    echo "当前配置:"
    echo "1. 项目前缀: ${PROJECT_PREFIX}"
    echo "2. 最大重试次数: ${MAX_RETRY_ATTEMPTS}"
    echo "3. 并行任务数: ${MAX_PARALLEL_JOBS}"
    echo "4. Vertex密钥目录: ${KEY_DIR}"
    echo "5. Vertex服务账号名: ${SERVICE_ACCOUNT_NAME}"
    echo "6. 每账户最大项目数: ${MAX_PROJECTS_PER_ACCOUNT}"
    echo "0. 返回主菜单"
    echo
    
    local choice
    read -r -p "请选择要修改的设置 [0-6]: " choice
    
    case "$choice" in
        1)
            read -r -p "请输入新的项目前缀: " new_value
            if [[ "$new_value" =~ ^[a-z][a-z0-9-]{0,20}$ ]]; then
                PROJECT_PREFIX="$new_value"
                log "SUCCESS" "项目前缀已更新"
            else
                log "ERROR" "无效的项目前缀格式"
            fi
            ;;
        2)
            read -r -p "请输入最大重试次数 [1-10]: " new_value
            if [[ "$new_value" =~ ^[0-9]+$ ]] && [ "$new_value" -ge 1 ] && [ "$new_value" -le 10 ]; then
                MAX_RETRY_ATTEMPTS="$new_value"
                log "SUCCESS" "最大重试次数已更新"
            else
                log "ERROR" "无效的数值"
            fi
            ;;
        3)
            read -r -p "请输入并行任务数 [1-50]: " new_value
            if [[ "$new_value" =~ ^[0-9]+$ ]] && [ "$new_value" -ge 1 ] && [ "$new_value" -le 50 ]; then
                MAX_PARALLEL_JOBS="$new_value"
                log "SUCCESS" "并行任务数已更新"
            else
                log "ERROR" "无效的数值"
            fi
            ;;
        4)
            read -r -p "请输入密钥目录路径: " new_value
            if [ -n "$new_value" ]; then
                KEY_DIR="$new_value"
                mkdir -p "$KEY_DIR" 2>/dev/null
                log "SUCCESS" "密钥目录已更新"
            fi
            ;;
        5)
            read -r -p "请输入服务账号名称: " new_value
            if [[ "$new_value" =~ ^[a-z][a-z0-9-]{0,20}$ ]]; then
                SERVICE_ACCOUNT_NAME="$new_value"
                log "SUCCESS" "服务账号名称已更新"
            else
                log "ERROR" "无效的服务账号名称格式"
            fi
            ;;
        6)
            read -r -p "请输入每账户最大项目数 [1-10]: " new_value
            if [[ "$new_value" =~ ^[0-9]+$ ]] && [ "$new_value" -ge 1 ] && [ "$new_value" -le 10 ]; then
                MAX_PROJECTS_PER_ACCOUNT="$new_value"
                log "SUCCESS" "每账户最大项目数已更新"
            else
                log "ERROR" "无效的数值"
            fi
            ;;
        0)
            return 0
            ;;
        *)
            log "ERROR" "无效选项"
            ;;
    esac
    
    # 显示更新后的设置
    sleep 1
    show_settings
}

# 显示帮助文档
show_help() {
  # ... 此函数内容不变 ...
  echo -e "\n${CYAN}${BOLD}====== 帮助文档 ======${NC}\n"
    
    echo "请选择查看的帮助内容:"
    echo "1. 快速开始"
    echo "2. Gemini API 使用说明"
    echo "3. Vertex AI 使用说明"
    echo "4. 故障排除"
    echo "5. 最佳实践"
    echo "0. 返回主菜单"
    echo
    
    local choice
    read -r -p "请选择 [0-5]: " choice
    
    case "$choice" in
        1)
            echo -e "\n${BOLD}快速开始:${NC}"
            echo "1. 确保已安装 gcloud CLI"
            echo "2. 运行 'gcloud auth login' 登录"
            echo "3. 选择对应的功能进行操作"
            echo
            echo "Gemini API - 适合个人开发，有免费额度"
            echo "Vertex AI - 企业级服务，需要付费"
            ;;
        2)
            echo -e "\n${BOLD}Gemini API 使用说明:${NC}"
            echo "• 批量创建项目可能触发风控"
            echo "• 建议每次创建不超过20个项目"
            echo "• 定期清理不用的项目"
            echo "• API密钥会保存在本地文件中"
            ;;
        3)
            echo -e "\n${BOLD}Vertex AI 使用说明:${NC}"
            echo "• 必须有有效的结算账户"
            echo "• 会产生实际费用"
            echo "• 服务账号密钥保存在 ${KEY_DIR}"
            echo "• 请设置预算警报避免超支"
            ;;
        4)
            echo -e "\n${BOLD}故障排除:${NC}"
            echo "• 权限错误: 检查账号是否有足够权限"
            echo "• API启用失败: 检查项目是否有结算账户"
            echo "• 配额限制: 降低创建数量或等待"
            echo "• 认证失败: 重新运行 gcloud auth login"
            ;;
        5)
            echo -e "\n${BOLD}最佳实践:${NC}"
            echo "• 使用有意义的项目前缀"
            echo "• 定期备份API密钥"
            echo "• 监控使用量和费用"
            echo "• 不要在代码中硬编码密钥"
            echo "• 及时删除不用的资源"
            ;;
        0)
            return 0
            ;;
        *)
            log "ERROR" "无效选项"
            ;;
    esac
    
    echo
    read -r -p "按回车键继续..."
    show_help
}

# ===== 主程序入口 =====

main() {
    # 显示欢迎信息
    echo -e "${CYAN}${BOLD}"
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║          GCP API 密钥管理工具 v${VERSION}              ║"
    echo "║                                                       ║"
    echo "║          支持 Gemini API 和 Vertex AI                 ║"
    echo "╚═══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    # 检查环境
    check_env
    
    # 主循环
    while true; do
        show_menu
    done
}

# 运行主程序
main

