#!/bin/bash
# =============================================================================
# ZeroClaw Build Script
# Provides build, clean, and distclean functionality
# =============================================================================

set -euo pipefail

# =============================================================================
# Configuration Variables
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/build"
DOCKER_DIR="$PROJECT_ROOT/docker"
CONFIG_DIR="$PROJECT_ROOT/config"

# Configurable defaults
DEFAULT_GATEWAY_PORT="42617"
DEFAULT_PROVIDER="zai-cn"
DEFAULT_MODEL="glm-4.7"

# Provider definitions (easily extensible)
declare -A PROVIDER_MODELS=(
    ["zai-cn"]="glm-4.7 glm-4.6 glm-5"
    ["moonshot"]="kimi-k2.5 kimi-k2-thinking kimi-k2-thinking-turbo"
    ["minimax-cn"]="minimax-m2.5 minimax-m2.1 minimax-m2"
    ["deepseek"]="deepseek-chat deepseek-coder deepseek-reasoner"
    ["ollama"]="llama3 mistral codellama"
    ["openai"]="gpt-4o gpt-4o-mini gpt-4-turbo"
    ["anthropic"]="claude-sonnet-4-20250514 claude-opus-4-20250514 claude-3-5-haiku-20241022"
    ["google"]="gemini-2.5-flash gemini-2.0-flash gemini-1.5-flash"
    ["openrouter"]="anthropic/claude-3.5-sonnet google/gemini-pro-1.5 meta-llama/llama-3.1-70b-instruct"
)

declare -A PROVIDER_DEFAULTS=(
    ["zai-cn"]="glm-4.7"
    ["moonshot"]="kimi-k2.5"
    ["minimax-cn"]="minimax-m2.5"
    ["deepseek"]="deepseek-chat"
    ["ollama"]="llama3"
    ["openai"]="gpt-4o"
    ["anthropic"]="claude-sonnet-4-20250514"
    ["google"]="gemini-2.5-flash"
    ["openrouter"]="anthropic/claude-3.5-sonnet"
)

# Debug mode flag (enabled with -d parameter)
DEBUG_MODE="false"

# Colors for output
RED='\033[0;31m'
GRAY='\033[0;37m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

detect_docker_compose() {
    # Check for Docker Compose V2 (plugin)
    if docker compose version > /dev/null 2>&1; then
        DOCKER_COMPOSE="docker compose"
        return 0
    # Check for Docker Compose V1 (standalone)
    elif command -v docker-compose > /dev/null 2>&1; then
        DOCKER_COMPOSE="docker-compose"
        return 0
    else
        print_error "docker-compose not found"
        return 1
    fi
}

detect_docker_compose || exit 1
readonly DOCKER_COMPOSE

# =============================================================================
# Traceback / Error Handling (Top-tier engineer pattern)
# =============================================================================
readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_VERSION="2.1.0"

# Error handler with stack trace
error_handler() {
    local line_no=$1
    local error_code=$2
    print_error "Error occurred in script '$SCRIPT_NAME' at line $line_no (exit code: $error_code)"
    print_error "Call stack:"
    local i=0
    while caller_frame=($(caller $i)); do
        local caller_line=${caller_frame[0]}
        local caller_func=${caller_frame[1]}
        local caller_file=${caller_frame[2]}
        print_error "  #$i: ${caller_file}:${caller_line} -> ${caller_func}"
        ((i++))
    done
    exit "$error_code"
}

# Cleanup handler
cleanup_handler() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        print_error "Script exited with error code: $exit_code"
    fi
    return "$exit_code"
}

trap 'error_handler ${LINENO} $?' ERR
trap 'cleanup_handler' EXIT

# =============================================================================
# Utility Functions
# =============================================================================
print_debug() {
    if [[ $DEBUG_MODE == "true" ]]; then
        echo -e "${GRAY}[DEBUG]${NC} $1" >&2
    fi
}
print_info() { echo -e "${BLUE}[INFO]${NC} $1" >&2; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1" >&2; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1" >&2; }
print_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

mask_sensitive_key() {
    local key="$1"
    local prefix_len="${2:-4}"
    local suffix_len="${3:-4}"
    local min_len="${4:-12}"

    if [[ -n $key ]]; then
        local key_len=${#key}
        if [[ $key_len -gt $min_len ]]; then
            echo "${key:0:prefix_len}...${key: -$suffix_len}"
        else
            echo "****"
        fi
    else
        echo "(not set)"
    fi
}

print_header() {
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}========================================${NC}" >&2
}

# Prompt for normal input (required - loops until non-empty input is provided)
prompt_normal_input() {
    local prompt_text="$1"
    local value=""

    while true; do
        echo -n "$prompt_text" >&2
        read -r value
        echo "" >&2

        if [[ -n $value ]]; then
            break
        else
            print_warning "Input cannot be empty. Please try again."
        fi
    done

    echo "$value"
}

# Prompt for sensitive input (required - loops until non-empty input is provided)
prompt_sensitive_input() {
    local prompt_text="$1"
    local value=""

    while true; do
        echo -n "$prompt_text" >&2
        read -rs value
        echo "" >&2

        if [[ -n $value ]]; then
            break
        else
            print_warning "Input cannot be empty. Please try again."
        fi
    done

    echo "$value"
}

# Validation functions
validate_docker() {
    if ! command -v docker &> /dev/null; then
        print_error "Docker is not installed"
        return 1
    fi

    if ! docker info &> /dev/null; then
        print_error "Docker is not running. Please start Docker first."
        return 1
    fi

    return 0
}

validate_directory() {
    local dir="$1"
    if [[ ! -d $dir ]]; then
        if ! mkdir -p "$dir" 2> /dev/null; then
            print_error "Cannot create directory: $dir"
            return 1
        fi
    fi
    return 0
}

# =============================================================================
# Provider/Model Selection Functions (DRY pattern)
# =============================================================================

prompt_provider() {
    local current_provider="${1:-}"
    local choice

    echo "" >&2
    echo "Available providers:" >&2
    echo "  1) zai-cn (default)" >&2
    echo "  2) moonshot" >&2
    echo "  3) minimax-cn" >&2
    echo "  4) deepseek" >&2
    echo "  5) ollama" >&2
    echo "  6) openai" >&2
    echo "  7) anthropic" >&2
    echo "  8) google" >&2
    echo "  9) openrouter" >&2

    if [[ -n $current_provider ]]; then
        echo -n "Select provider [${current_provider}]: " >&2
    else
        echo -n "Select provider [1]: " >&2
    fi
    read -r choice

    case "$choice" in
        1) echo "zai-cn" ;;
        2) echo "moonshot" ;;
        3) echo "minimax-cn" ;;
        4) echo "deepseek" ;;
        5) echo "ollama" ;;
        6) echo "openai" ;;
        7) echo "anthropic" ;;
        8) echo "google" ;;
        9) echo "openrouter" ;;
        *) echo "${current_provider:-${DEFAULT_PROVIDER}}" ;;
    esac
}

prompt_model() {
    local provider="$1"
    local current_model="${2:-}"
    local model

    local models="${PROVIDER_MODELS[$provider]:-}"

    if [[ -z $models ]]; then
        echo "${current_model:-${PROVIDER_DEFAULTS[$provider]:-${DEFAULT_PROVIDER}}}"
        return
    fi

    # Parse models into array
    read -ra model_array <<< "$models"
    local count=1

    echo "Available models:" >&2
    for model in "${model_array[@]}"; do
        local default_marker=""
        if [[ $count -eq 1 ]]; then
            default_marker=" (default)"
        fi
        echo "  $count) $model$default_marker" >&2
        ((count++))
    done

    echo -n "Select model [1]: " >&2
    read -r choice

    if [[ -z $choice ]]; then
        echo "${PROVIDER_DEFAULTS[$provider]}"
    else
        local idx=$((choice - 1))
        if [[ $idx -ge 0 ]] && [[ $idx -lt ${#model_array[@]} ]]; then
            echo "${model_array[$idx]}"
        else
            echo "${PROVIDER_DEFAULTS[$provider]}"
        fi
    fi
}

prompt_gateway_port() {
    local current_port="${1:-$DEFAULT_GATEWAY_PORT}"
    local port=""

    while true; do
        echo -en "Enter ZeroClaw gateway port (1025-65535) [${current_port}]: " >&2
        read -r port
        echo "" >&2

        if [[ -n $port && $port =~ ^[0-9]+$ && $port -ge 1025 && $port -le 65535 ]]; then
            echo "$port"
            return 0
        elif [[ -z $port ]]; then
            echo "$current_port"
            return 0
        else
            print_warning "Invalid port '$port'. Must be numeric between 1025-65535."
        fi
    done
}

# =============================================================================
# Environment Setup Functions (SRP pattern)
# =============================================================================

backup_env_file() {
    local env_file="$1"
    if [[ -f $env_file ]]; then
        local backup="${env_file}.backup.$(date +%Y%m%d_%H%M%S)"
        if cp "$env_file" "$backup" 2> /dev/null; then
            print_info "Backed up $env_file to $backup"
        else
            print_warning "Failed to backup $env_file file"
        fi
    fi
}

clean_backup_files() {
    local backup_dir="$BUILD_DIR/docker"
    if [[ -d $backup_dir ]]; then
        local backup_count
        backup_count=$(find "$backup_dir" -maxdepth 10 -name "*backup*" -type f 2> /dev/null | wc -l)
        if [[ $backup_count -gt 0 ]]; then
            find "$backup_dir" -maxdepth 10 -name "*backup*" -type f -delete 2> /dev/null
            print_info "Cleaned $backup_count backup file(s) from $backup_dir"
        fi
    fi
}

update_env_file() {
    local env_file="$1"
    local key="$2"
    local value="$3"

    if [[ -f $env_file ]]; then
        if grep -q "${key}[[:space:]]*=" "$env_file" 2> /dev/null; then
            sed -i "s|.*${key}[[:space:]]*=.*|${key}=${value}|" "$env_file"
        else
            echo "${key}=${value}" >> "$env_file"
        fi
    else
        validate_directory "$(dirname "$env_file")" || return 1
        echo "${key}=${value}" > "$env_file"
    fi
}

read_env_value() {
    local env_file="$1"
    local key="$2"
    local default="$3"

    if [[ -f $env_file ]]; then
        grep "^${key}=" "$env_file" 2> /dev/null | cut -d'=' -f2- || echo "$default"
    else
        echo "$default"
    fi
}

# Provider to API key environment variable mapping
declare -A PROVIDER_API_KEYS=(
    ["zai-cn"]="GLM_API_KEY"
    ["moonshot"]="MOONSHOT_API_KEY"
    ["minimax-cn"]="MINIMAX_API_KEY"
    ["deepseek"]="DEEPSEEK_API_KEY"
    ["ollama"]=""
    ["openai"]="OPENAI_API_KEY"
    ["anthropic"]="ANTHROPIC_API_KEY"
    ["google"]="GEMINI_API_KEY"
    ["openrouter"]="OPENROUTER_API_KEY"
)

copy_tailscale_env_file() {
    local tailscale_env_file="$1"
    local tailscale_env_example="$2"

    if [[ ! -f $tailscale_env_file ]]; then
        if [[ -f $tailscale_env_example ]]; then
            print_info "Copying Tailscale env file..."
            cp -v "$tailscale_env_example" "$tailscale_env_file"
        else
            print_warning "$tailscale_env_example not found, creating new configuration..."
            touch "$tailscale_env_file"
        fi
    else
        print_info "Tailscale env file already exists, skipping copy..."
    fi

    local tailscale_env_perms=$(stat -c "%a" "$tailscale_env_file" 2> /dev/null || echo "unknown")

    if [[ $tailscale_env_perms != "600" && $tailscale_env_perms != "400" ]]; then
        chmod 600 "$tailscale_env_file"
        print_info "Fix $tailscale_env_file Permissions to 600"
    fi
}

setup_tailscale_env() {
    local tailscale_env_file="$BUILD_DIR/docker/tailscale/env/.env.tailscale"
    local tailscale_env_example="$DOCKER_DIR/tailscale/.env.tailscale.example"

    validate_directory "$(dirname "$tailscale_env_file")" || return 1
    copy_tailscale_env_file "$tailscale_env_file" "$tailscale_env_example"

    local existing_auth_key=$(read_env_value "$tailscale_env_file" "TS_AUTHKEY" "")
    local need_update="true"

    if [[ -n $existing_auth_key ]]; then
        local force_update=1
        local masked_auth_key=$(mask_sensitive_key "$existing_auth_key" 8 6 14)

        echo "" >&2
        echo "Detect Current Tailscale Auth Key:" >&2
        echo "  $masked_auth_key" >&2
        echo "" >&2
        echo "Select an option:" >&2
        echo "  1) Skip Tailscale Auth Key update (default)" >&2
        echo "  2) Force update Tailscale Auth Key" >&2
        echo -n "Enter your choice [1]: " >&2
        read -r force_update
        echo "" >&2

        if [[ $force_update != "2" ]]; then
            print_info "Skipped Tailscale Auth Key update (using existing settings)."
            echo "" >&2
            need_update="false"
        fi
    fi

    if [[ $need_update == "true" ]]; then
        print_info "Setting up Tailscale Auth Key..."
        tailscale_auth_key=$(prompt_sensitive_input "Enter Tailscale Auth Key: ")

        umask 0077
        update_env_file "$tailscale_env_file" "TS_AUTHKEY" "${tailscale_auth_key:-}"
        umask 0022

        chmod 600 "$tailscale_env_file"

        local masked_auth_key=$(mask_sensitive_key "$tailscale_auth_key" 8 6 14)
        print_success "Tailscale Auth Key updated:"
        print_success "     $masked_auth_key"
    fi
}

get_tailscale_api_token() {
    local cfg_file="$BUILD_DIR/tailscale.cfg"
    local token=$(read_env_value "$cfg_file" "TAILSCALE_API_TOKEN" "")
    echo "$token"
}

load_tailscale_api_token() {
    local needs_prompt="true"
    local tailscale_cfg_file="$BUILD_DIR/tailscale.cfg"
    local tailscale_api_token=$(get_tailscale_api_token)

    if [[ -n $tailscale_api_token ]]; then
        local update_choice=1
        local masked_api_token=$(mask_sensitive_key "$tailscale_api_token" 8 6 14)

        echo "" >&2
        echo "Detect Tailscale API Access Token:" >&2
        echo "  $masked_api_token" >&2
        echo "" >&2
        echo "Select an option:" >&2
        echo "  1) Skip Tailscale API Access Token update (default)" >&2
        echo "  2) Force update Tailscale API Access Token" >&2
        echo -n "Enter your choice [1]: " >&2
        read -r update_choice
        echo "" >&2

        if [[ $update_choice != "2" ]]; then
            print_info "Skipped Tailscale API Access Token update (using existing settings)."
            echo "" >&2
            needs_prompt="false"
        fi
    fi

    if [[ $needs_prompt == "true" ]]; then
        print_info "Setting up Tailscale API Access Token..."
        print_info 'NOTE: Get from "https://login.tailscale.com/admin/settings/keys".'
        tailscale_api_token=$(prompt_sensitive_input "Enter Tailscale API Access Token: ")

        if [[ -z $tailscale_api_token ]]; then
            print_error "Tailscale API Access Token required."
            return 1
        fi

        umask 0077
        update_env_file "$tailscale_cfg_file" "TAILSCALE_API_TOKEN" "$tailscale_api_token"
        umask 0022

        chmod 600 "$tailscale_cfg_file"

        local masked_api_token=$(mask_sensitive_key "$tailscale_api_token" 8 6 14)
        print_success "Tailscale API Access Token updated:"
        print_success "     $masked_api_token"
    fi

    echo "$tailscale_api_token"
}

get_tailscale_dns_preferences() {
    local tailscale_api_token="$1"
    local raw_response=$(
        curl -s -w "\n%{http_code}" 'https://api.tailscale.com/api/v2/tailnet/-/dns/preferences' \
            --header "Authorization: Bearer $tailscale_api_token"
    )
    local status_code=$(echo "$raw_response" | tail -n1)
    local response_body=$(echo "$raw_response" | sed '$d')

    if [[ $status_code != "200" ]]; then
        print_error "Getting Tailscale dns preferences failed (HTTP $status_code): $response_body"
        echo ""
    else
        echo "$response_body"
    fi

}

set_tailscale_dns_preferences() {
    local tailscale_api_token="$1"
    local raw_response=$(
        curl -s -w "\n%{http_code}" \
            'https://api.tailscale.com/api/v2/tailnet/-/dns/preferences' \
            --request POST \
            --header 'Content-Type: application/json' \
            --header "Authorization: Bearer $tailscale_api_token" \
            --data '{"magicDNS": true}'
    )
    local status_code=$(echo "$raw_response" | tail -n1)
    local response_body=$(echo "$raw_response" | sed '$d')

    if [[ $status_code != "200" ]]; then
        print_error "Setting Tailscale dns preferences failed (HTTP $status_code): $response_body"
        return 1
    fi

    return 0
}

setup_tailscale_magicdns() {
    local tailscale_api_token="$1"
    local dns_response=$(get_tailscale_dns_preferences "$tailscale_api_token")

    if [[ -z $dns_response ]]; then
        print_error "Tailscale MagicDNS setup encountered issues. Please check your API token and network settings."
        return 1
    fi

    local magicdns_enabled=$(echo "$dns_response" | jq ".magicDNS")

    if [[ $magicdns_enabled == "true" ]]; then
        print_success "Tailscale MagicDNS already enabled"
        return 0
    fi

    print_info "Enabling Tailscale MagicDNS..."

    local result=$(set_tailscale_dns_preferences "$tailscale_api_token")

    if [[ $result -ne 0 ]]; then
        print_error "Tailscale MagicDNS setup encountered issues. Please check your API token and network settings."
        return 1
    fi

    print_success "Tailscale MagicDNS enabled successfully"

    return 0
}

get_tailscale_tailnet_settings() {
    local tailscale_api_token="$1"
    local raw_response=$(
        curl -s -w "\n%{http_code}" 'https://api.tailscale.com/api/v2/tailnet/-/settings' \
            --header "Authorization: Bearer $tailscale_api_token"
    )
    local status_code=$(echo "$raw_response" | tail -n1)
    local response_body=$(echo "$raw_response" | sed '$d')

    if [[ $status_code != "200" ]]; then
        print_error "Getting Tailscale tailnet settings failed (HTTP $status_code): $response_body"
        echo ""
    else
        echo "$response_body"
    fi
}

set_tailscale_tailnet_settings() {
    local tailscale_api_token="$1"
    local raw_response=$(
        curl -s -w "\n%{http_code}" \
            'https://api.tailscale.com/api/v2/tailnet/-/settings' \
            --request PATCH \
            --header 'Content-Type: application/json' \
            --header "Authorization: Bearer $tailscale_api_token" \
            --data '{"httpsEnabled": true}'
    )
    local status_code=$(echo "$raw_response" | tail -n1)
    local response_body=$(echo "$raw_response" | sed '$d')

    if [[ $status_code != "200" ]]; then
        print_error "Setting Tailscale tailnet settings failed (HTTP $status_code): $response_body"
        return 1
    fi

    return 0
}

setup_tailscale_https() {
    local tailscale_api_token="$1"
    local https_response=$(get_tailscale_tailnet_settings "$tailscale_api_token")

    if [[ -z $https_response ]]; then
        print_error "Tailscale HTTPS setup encountered issues. Please check your API token and network settings."
        return 1
    fi

    local https_enabled=$(echo "$https_response" | jq ".httpsEnabled")

    if [[ $https_enabled == "true" ]]; then
        print_success "Tailscale HTTPS already enabled"
        return 0
    fi

    print_info "Enabling Tailscale HTTPS..."

    local result=$(set_tailscale_tailnet_settings "$tailscale_api_token")

    if [[ $result -ne 0 ]]; then
        print_error "Tailscale HTTPS setup encountered issues. Please check your API token and network settings."
        return 1
    fi

    print_success "Tailscale HTTPS enabled successfully"

    return 0
}

setup_tailscale_features() {
    local tailscale_api_token=$(get_tailscale_api_token)

    if [[ -z $tailscale_api_token ]]; then
        print_error "No Tailscale API token available. Skipping Tailscale features configuration."
        return 1
    fi

    echo "" >&2
    print_info "Configuring Tailscale features (MagicDNS & HTTPS)..."

    local magicdns_enabled=$(setup_tailscale_magicdns "$tailscale_api_token")

    if [[ $magicdns_enabled -ne 0 ]]; then
        print_error "Tailscale MagicDNS setup encountered issues. Please check your API token and network settings."
        return 1
    fi

    print_success "Tailscale MagicDNS enabled successfully"

    local https_enabled=$(setup_tailscale_https "$tailscale_api_token")

    if [[ $https_enabled -ne 0 ]]; then
        print_error "Tailscale HTTPS setup encountered issues. Please check your API token and network settings."
        return 1
    fi

    print_success "Tailscale HTTPS enabled successfully"

    return 0
}

copy_zeroclaw_env_file() {
    local zeroclaw_env_file="$1"
    local zeroclaw_env_example="$2"

    if [[ ! -f $zeroclaw_env_file ]]; then
        # Check if .env.zeroclaw.example exists, copy it to preserve comments and format
        if [[ -f $zeroclaw_env_example ]]; then
            print_info "Copying ZeroClaw env file..."
            cp -v "$zeroclaw_env_example" "$zeroclaw_env_file"
        else
            print_warning "$zeroclaw_env_example not found, creating new configuration..."
            touch "$zeroclaw_env_file"
        fi
    else
        print_info "Zeroclaw env file already exists, skipping copy..."
    fi

    local zeroclaw_env_perms=$(stat -c "%a" "$zeroclaw_env_file" 2> /dev/null || echo "unknown")

    if [[ $zeroclaw_env_perms != "600" && $zeroclaw_env_perms != "400" ]]; then
        chmod 600 "$zeroclaw_env_file"
        print_info "Fix $zeroclaw_env_file Permissions to 600"
    fi
}

setup_zeroclaw_env() {
    local zeroclaw_env_file="$BUILD_DIR/docker/zeroclaw/env/.env.zeroclaw"
    local zeroclaw_env_example="$DOCKER_DIR/zeroclaw/.env.zeroclaw.example"

    validate_directory "$(dirname "$zeroclaw_env_file")" || return 1
    copy_zeroclaw_env_file "$zeroclaw_env_file" "$zeroclaw_env_example"

    local existing_provider=$(read_env_value "$zeroclaw_env_file" "ZEROCLAW_PROVIDER" "$DEFAULT_PROVIDER")
    local existing_model=$(read_env_value "$zeroclaw_env_file" "ZEROCLAW_MODEL" "$DEFAULT_MODEL")
    local existing_api_key=$(read_env_value "$zeroclaw_env_file" "ZEROCLAW_API_KEY" "")
    local existing_gateway_port=$(read_env_value "$zeroclaw_env_file" "ZEROCLAW_GATEWAY_PORT" "$DEFAULT_GATEWAY_PORT")
    local need_update="true"

    if [[ -n $existing_provider && -n $existing_model && -n $existing_api_key && -n $existing_gateway_port ]]; then
        local force_update=1
        local masked_api_key=$(mask_sensitive_key "$existing_api_key" 4 4 12)

        echo "" >&2
        echo "Detect Current AI Model Settings:" >&2
        echo "  Provider: $existing_provider" >&2
        echo "  Model:    $existing_model" >&2
        echo "  API Key:  $masked_api_key" >&2
        echo "  Gateway Port: $existing_gateway_port" >&2
        echo "" >&2
        echo "Select an option:" >&2
        echo "  1) Skip AI Model Settings update (default)" >&2
        echo "  2) Force update AI Model Settings" >&2
        echo -n "Enter your choice [1]: " >&2
        read -r force_update
        echo "" >&2

        if [[ $force_update != "2" ]]; then
            print_info "Skipped AI Model Settings update (using existing settings)."
            echo "" >&2
            need_update="false"
        fi
    fi

    if [[ $need_update == "true" ]]; then
        print_info "Setting up ZeroClaw AI Model Settings..."

        provider=$(prompt_provider)
        model=$(prompt_model "$provider" "$DEFAULT_MODEL")
        api_key=$(prompt_sensitive_input "Enter your LLM API key: ")
        gateway_port=$(prompt_gateway_port "${existing_gateway_port:-$DEFAULT_GATEWAY_PORT}")

        umask 0077

        update_env_file "$zeroclaw_env_file" "ZEROCLAW_PROVIDER" "$provider"
        update_env_file "$zeroclaw_env_file" "ZEROCLAW_MODEL" "$model"
        update_env_file "$zeroclaw_env_file" "ZEROCLAW_API_KEY" "$api_key"
        update_env_file "$zeroclaw_env_file" "ZEROCLAW_GATEWAY_PORT" "$gateway_port"

        if [[ -n ${PROVIDER_API_KEYS[$provider]:-} ]]; then
            update_env_file "$zeroclaw_env_file" "${PROVIDER_API_KEYS[$provider]}" "$api_key"
        fi

        umask 0022

        chmod 600 "$zeroclaw_env_file"

        local masked_api_key=$(mask_sensitive_key "$api_key" 4 4 12)

        print_success "ZeroClaw AI Model Settings updated:"
        print_success "     Provider: $provider"
        print_success "     Model: $model"
        print_success "     API Key: $masked_api_key"
        print_success "     Gateway Port: $gateway_port"
    fi
}

get_tailscale_devices() {
    print_info "Getting Tailscale tailnet devices list..."

    local tailscale_api_token="$1"
    local raw_response=$(
        curl -s -w "\n%{http_code}" "https://api.tailscale.com/api/v2/tailnet/-/devices" \
            -H "Authorization: Bearer $tailscale_api_token"
    )
    local status_code=$(echo "$raw_response" | tail -n1)
    local response_body=$(echo "$raw_response" | sed '$d')

    if [[ $status_code != "200" ]]; then
        print_error "Tailscale tailnet devices list failed (HTTP $status_code): $response_body"
        echo ""
    else
        echo "$response_body"
    fi
}

delete_tailscale_device() {
    print_info "Deleting Tailscale tailnet device..."

    local tailscale_api_token="$1" device_id="$2"
    local raw_response=$(
        curl -s -w "\n%{http_code}" "https://api.tailscale.com/api/v2/device/$device_id" \
            -X DELETE -H "Authorization: Bearer $tailscale_api_token" 2>&1
    )
    local status_code=$(echo "$raw_response" | tail -n1)
    local response_body=$(echo "$raw_response" | sed '$d')

    if [[ $status_code != "200" ]]; then
        print_error "Failed to remove Tailscale tailnet device $device_id (HTTP $status_code): $response_body"
        return 1
    fi

    print_success "Tailscale tailnet device $device_id removed successfully"
    return 0
}

remove_tailscale_devices() {
    local tailscale_api_token
    tailscale_api_token=$(load_tailscale_api_token)

    if [[ -z $tailscale_api_token ]]; then
        print_error "No Tailscale API token available. Skipping Tailscale devices cleanup."
        return 1
    fi

    devices_json=$(get_tailscale_devices "$tailscale_api_token")

    if [[ -z $devices_json ]]; then
        print_error "Tailscale tailnet devices list encountered issues. Please check your API token and network settings."
        return 1
    fi

    local devices_preview=$(echo "$devices_json" | jq -r '.devices[]? | {addresses, nodeId, hostname, connectedToControl}' 2> /dev/null || echo "{}")
    print_debug "Device Json Preview:"
    print_debug "$devices_preview"

    local tailscale_ids
    readarray -t tailscale_ids < <(echo "$devices_json" | jq -r '.devices[]? | select(.hostname == "tailscale") | .nodeId' 2> /dev/null)
    print_debug "Tailscale tailnet devices Ids: ${tailscale_ids[*]:-none}"
    local tailscale_count=${#tailscale_ids[@]}
    print_info "Tailscale tailnet devices count: $tailscale_count"

    if [[ $tailscale_count -gt 0 ]]; then
        local removed_count=0
        for device_id in "${tailscale_ids[@]}"; do
            print_info "Deleting Tailscale tailnet device: $device_id"
            if [[ -n $device_id ]]; then
                delete_tailscale_device "$tailscale_api_token" "$device_id" && ((removed_count++))
            fi
        done
        print_success "$removed_count Tailscale tailnet devices removed successfully"
    else
        print_info "No Tailscale tailnet device to clean."
    fi

    return 0
}

get_tailscale_policy() {
    local tailscale_api_token="$1"
    local raw_response=$(
        curl -s -w "\n%{http_code}" "https://api.tailscale.com/api/v2/tailnet/-/acl" \
            -H "Authorization: Bearer $tailscale_api_token"
    )
    local status_code=$(echo "$raw_response" | tail -n1)
    local response_body=$(echo "$raw_response" | sed '$d')

    if [[ $status_code != "200" ]]; then
        print_error "Getting Tailscale tailnet policy failed (HTTP $status_code): $response_body"
        echo ""
    else
        echo "$response_body"
    fi
}

set_tailscale_policy() {
    local tailscale_api_token="$1"
    local tailscale_tag_name="$2"
    local raw_response=$(
        curl -s -w "\n%{http_code}" "https://api.tailscale.com/api/v2/tailnet/-/acl" \
            -H "Authorization: Bearer $tailscale_api_token" \
            -X POST -H 'Content-Type: application/json' \
            -d "{
                \"tagOwners\": {
                    \"${tailscale_tag_name}\": [\"autogroup:admin\"]
                }
            }"
    )
    local status_code=$(echo "$raw_response" | tail -n1)
    local response_body=$(echo "$raw_response" | sed '$d')

    if [[ $status_code != "200" ]]; then
        print_error "Setting Tailscale tailnet policy failed (HTTP $status_code): $response_body"
        return 1
    fi

    return 0
}

setup_tailscale_policy() {
    local tailscale_tag_name="tag:tailscale"
    local tailscale_api_token=$(get_tailscale_api_token)

    if [[ -z $tailscale_api_token ]]; then
        print_error "No Tailscale API token available. Skipping Tailscale policy setup."
        return 1
    fi

    local raw_json=$(get_tailscale_policy "$tailscale_api_token")

    if [[ -z $raw_json ]]; then
        print_error "Tailscale tailnet policy check encountered issues. Please check your API token and network settings."
        return 1
    fi

    local policy_json=$(
        echo "$raw_json" | python3 -c "
import sys, re
text = sys.stdin.read()
text = re.sub(r'//.*', '', text)
text = re.sub(r',\s*([\]}])', r'\1', text)
print(text)" 2> /dev/null || echo "{}"
    )
    print_debug "Policy Json Preview:"
    print_debug "$policy_json"

    local need_update="true"

    if echo "$policy_json" | jq -e ".tagOwners[\"$tailscale_tag_name\"] | select(. != null) | contains([\"autogroup:admin\"])" > /dev/null 2>&1; then
        print_info "Tailscale tailnet policy already exists, skipping update..."
        need_update="false"
    fi

    if [[ $need_update == "true" ]]; then
        print_info "Setting up Tailscale tailnet policy for ZeroClaw..."
        set_tailscale_policy "$tailscale_api_token" "$tailscale_tag_name" || return 1
        print_success "Tailscale tailnet policy for ZeroClaw setup successfully"
    fi

    return 0
}

setup_environment() {
    print_info "Setting up environment settings for TailScale and ZeroClaw..."

    local build_docker_dir="$BUILD_DIR/docker"
    local tailscale_env_file="$build_docker_dir/tailscale/env/.env.tailscale"
    local zeroclaw_env_file="$build_docker_dir/zeroclaw/env/.env.zeroclaw"
    local tailscale_env_example="$DOCKER_DIR/tailscale/.env.tailscale.example"
    local zeroclaw_env_example="$DOCKER_DIR/zeroclaw/.env.zeroclaw.example"
    local provider model api_key gateway_port tailscale_auth_key

    setup_tailscale_env "$tailscale_env_file" "$tailscale_env_example"
    setup_zeroclaw_env "$zeroclaw_env_file" "$zeroclaw_env_example"

    remove_tailscale_devices

    if [[ $? -ne 0 ]]; then
        print_error "Tailscale devices remove encountered issues. Please check your API token and network settings."
        return 1
    fi

    setup_tailscale_policy

    if [[ $? -ne 0 ]]; then
        print_error "Tailscale policy setup encountered issues. Please check your API token and network settings."
        return 1
    fi

    setup_tailscale_features

    if [[ $? -ne 0 ]]; then
        print_error "Tailscale features setup encountered issues. Please check your API token and network settings."
        return 1
    fi

    print_success "TailScale and ZeroClaw environment setup completed successfully"

    return 0
}

# =============================================================================
# Docker Operations (Single Responsibility)
# =============================================================================

check_docker_command() {
    print_info "Checking docker command availability..."
    validate_docker || return 1
    print_success "Docker command is available"

    return 0
}

cleanup_old() {
    print_info "Cleaning up old containers and volumes..."

    cd "$DOCKER_DIR" || {
        print_error "Cannot change to docker directory" && return 1
    }
    $DOCKER_COMPOSE down || true
    docker system prune -a -f || true

    print_success "Cleanup completed"
}

tailscale_health_json() {
    if command -v jq > /dev/null 2>&1; then
        docker exec tailscale tailscale status --json 2> /dev/null |
            jq -r '{
            "loggedIn": (if .Self? and (.Self.UserStatus?.LoginState? == "Self") then true else false end),
            "ip": (.Self?.TailscaleIPs?[0] // ""),
            "authURL": (.LoginServers?[0]?.CurrentAuthURL // ""),
            "error": (.Error // "")
        } | @json' 2> /dev/null || echo '{"loggedIn":false,"ip":"","authURL":"","error":"parse_error"}'
    else
        local ip
        ip=$(docker exec tailscale tailscale ip -4 2> /dev/null | head -n1 | xargs || echo "")
        if [[ -n $ip ]]; then
            echo "{\"loggedIn\":true,\"ip\":\"$ip\",\"authURL\":\"\",\"error\":\"\"}"
        else
            echo '{"loggedIn":false,"ip":"","authURL":"","error":"no_jq"}'
        fi
    fi
}

json_get() {
    local json="$1" field="$2"
    echo "$json" | sed -n "s/.*\"$field\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n1 || echo ""
}

wait_tailscale_ready() {
    local max_retries=15 delay=2
    local retry=0 json ip logged_in error
    while ((retry < max_retries)); do
        json=$(tailscale_health_json)
        ip=$(json_get "$json" "ip")
        logged_in=$(json_get "$json" "loggedIn")
        error=$(json_get "$json" "error")
        if [[ -n $ip ]]; then
            print_success "Tailscale IP ready: $ip"
            echo "$ip"
            return 0
        fi
        if [[ -n $error && $error != "no_jq" ]]; then
            print_error "Tailscale: $error"
            return 1
        fi
        print_info "Tailscale ready check $((retry + 1))/$max_retries (IP: ${ip:-pending})"
        sleep "$delay"
        ((retry++))
        delay=$((delay + 1))
    done
    print_error "Tailscale timeout (30s)"
    return 1
}

# Extract pairing code from ZeroClaw logs
get_pairing_code() {
    docker logs zeroclaw 2>&1 | grep -oP '(?<=X-Pairing-Code: )\d+' | tail -1 || echo ""
}

# Check if Tailscale is authenticated (returns IP if ready, empty if not)
get_tailscale_ip() {
    json_get "$(tailscale_health_json)" "ip"
}

start_container() {
    print_info "Starting Containers..."

    cd "$DOCKER_DIR" || {
        print_error "Cannot change to docker directory" && return 1
    }

    # Start tailscale first (required for zeroclaw network)
    print_info "Starting Tailscale container..."
    if ! $DOCKER_COMPOSE up -d tailscale; then
        print_error "Failed to start Tailscale container"
        return 1
    fi

    # Wait for Tailscale container to be ready
    print_info "Waiting for Tailscale container to be ready..."
    sleep 5

    # Professional Tailscale readiness check with timeout
    print_info "Ensuring Tailscale is ready - 30s timeout"
    local tailscale_ip auth_url json error

    # Try JSON first for full status
    json=$(tailscale_health_json)
    tailscale_ip=$(json_get "$json" "ip")
    auth_url=$(json_get "$json" "authURL")
    error=$(json_get "$json" "error")

    if [[ -n $tailscale_ip ]]; then
        print_success "Tailscale ready IP: $tailscale_ip"
    elif [[ -n $auth_url ]]; then
        print_warning "Tailscale auth required: $auth_url"
        echo "Open URL in browser, then press Enter here..."
        read -r
        if ! wait_tailscale_ready; then
            print_error "Tailscale auth failed/timeout"
            return 1
        fi
        tailscale_ip=$(get_tailscale_ip)
    else
        if wait_tailscale_ready; then
            tailscale_ip=$(get_tailscale_ip)
        else
            print_error "Tailscale not ready after timeout"
            if [[ $error == "exec_error" ]]; then
                print_info "Container may not be healthy - check 'docker logs tailscale'"
            fi
            return 1
        fi
    fi

    print_success "Tailscale authenticated IP: $tailscale_ip"

    # Now start zeroclaw
    print_info "Starting ZeroClaw container..."
    if ! $DOCKER_COMPOSE up --build -d zeroclaw; then
        print_error "Failed to start ZeroClaw container"
        return 1
    fi

    print_success "Container started"

    # Wait for ZeroClaw to initialize and generate logs
    print_info "Waiting for ZeroClaw to initialize..."
    sleep 10

    # Get pairing code from logs
    local pairing_code
    pairing_code=$(get_pairing_code)

    if [[ -n $pairing_code ]]; then
        echo ""
        print_header "ZeroClaw Pairing Required"
        echo ""
        echo -e "${YELLOW}Pairing Code: ${CYAN}$pairing_code${NC}"
        echo ""
        echo "Please enter this code in the ZeroClaw web interface to pair your device."
        echo ""
        if [[ -n $tailscale_ip ]]; then
            echo -e "Access ZeroClaw at: ${CYAN}http://${tailscale_ip}:42617${NC}"
        fi
        echo ""
    else
        print_info "No pairing code found in logs. Device may already be paired."
    fi

    print_info "Container status:"
    $DOCKER_COMPOSE ps

    return 0
}

# =============================================================================
# Command Functions (Command Pattern)
# =============================================================================

show_help() {
    print_header "ZeroClaw Build Script v$SCRIPT_VERSION"
    cat << EOF

Usage: $0 [-d | --debug] [command1 [command2 ...]]
  -d, --debug  Enable debug output

Commands (multiple supported, executed sequentially):
  (none)/build - Clean build and run (default)
  help         - Show this help message
  clean        - Clean build artifacts (Docker + backups)
  distclean    - Deep clean (rm -rf build/)
  logs         - View container logs
  status       - Show container status
  stop         - Stop containers
  restart      - Restart containers
  remove       - Remove all Tailscale devices using API

Examples:
  $0                        # Clean build and run
  $0 clean remove           # Clean THEN remove Tailscale devices
  $0 distclean build        # Deep clean THEN build+run
  $0 help                   # Show help
  $0 logs                   # View logs
  $0 stop restart           # Stop THEN restart

EOF
}

do_clean() {
    print_header "Cleaning Build Artifacts"

    # First clean up Docker containers and volumes
    print_info "Cleaning up Docker containers and volumes..."
    cleanup_old || return 1

    print_info "Cleaning build directory..."

    clean_backup_files

    validate_directory "$BUILD_DIR" || return 1

    print_success "Build directory cleaned - config files preserved"

    return 0
}

do_distclean() {
    print_header "Deep Cleaning All Generated Files"

    # First clean up Docker containers and volumes
    print_info "Cleaning up Docker containers and volumes..."
    cleanup_old || return 1

    print_info "This will remove the entire build directory:"
    echo "  - Build artifacts"
    echo "  - All generated files"
    echo "  - Configuration files"
    echo "" >&2

    if [[ -d $BUILD_DIR ]]; then
        rm -rf "$BUILD_DIR"
        print_success "Build directory removed"
    else
        print_info "Build directory does not exist"
    fi

    print_success "Distclean completed!"

    return 0
}

# Build and run pipeline (Pipeline pattern)
pipeline_build_and_run() {
    local -a steps=(
        "do_clean:Step 1: Cleaning previous build"
        "setup_directories:Step 2: Setting up build directories"
        "check_docker_command:Step 3: Checking docker command availability"
        "setup_environment:Step 4: Setting up environment"
        "start_container:Step 5: Starting containers"
    )

    local step_func step_desc
    for step in "${steps[@]}"; do
        step_func="${step%%:*}"
        step_desc="${step#*:}"
        print_info "$step_desc..."

        $step_func

        if [ $? -ne 0 ]; then
            print_error "Failed at: $step_desc"
            return 1
        fi
    done

    print_success ""
    print_success "========================================"
    print_success "  Build and Run Complete!"
    print_success "========================================"
    print_info "Run '$0 logs' to view container logs"
    print_info "Run '$0 stop' to stop the container"
}

setup_directories() {
    print_info "Setting up build directories..."
    for subdir in docker; do
        validate_directory "$BUILD_DIR/$subdir" || return 1
    done
    # Zeroclaw subdirectory
    validate_directory "$BUILD_DIR/docker/zeroclaw/env" || return 1
    # Tailscale subdirectory
    validate_directory "$BUILD_DIR/docker/tailscale/env" || return 1
    print_success "Build directories created"

    return 0
}

do_logs() {
    cd "$DOCKER_DIR" || {
        print_error "Cannot change to docker directory" && return 1
    }
    $DOCKER_COMPOSE logs -f
}

do_status() {
    cd "$DOCKER_DIR" || {
        print_error "Cannot change to docker directory" && return 1
    }
    $DOCKER_COMPOSE ps -a
}

do_stop() {
    cd "$DOCKER_DIR" || {
        print_error "Cannot change to docker directory" && return 1
    }
    $DOCKER_COMPOSE down
    print_success "Containers stopped"
}

do_restart() {
    print_info "Restarting containers..."
    do_stop || return 1
    start_container || return 1
    print_success "Containers restarted"
}

# =============================================================================
# Main Entry Point (Router Pattern)
# =============================================================================

main() {
    local -a args=()
    local has_command="false"

    # Handle flags first
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d | --debug)
                print_info "Debug Mode Enabled"
                DEBUG_MODE="true"
                shift
                ;;
            help | --help | -h)
                show_help
                return 0
                ;;
            *)
                # Collect all remaining positional args
                args+=("$1")
                shift
                ;;
        esac
    done

    # If no args provided, default to build+run
    if [[ ${#args[@]} -eq 0 ]]; then
        args=("build")
    fi

    # Execute each command sequentially
    for arg in "${args[@]}"; do
        case "$arg" in
            clean)
                do_clean
                has_command="true"
                ;;
            distclean)
                do_distclean
                has_command="true"
                ;;
            logs)
                do_logs
                has_command="true"
                ;;
            status)
                do_status
                has_command="true"
                ;;
            stop)
                do_stop
                has_command="true"
                ;;
            restart)
                do_restart
                has_command="true"
                ;;
            remove)
                remove_tailscale_devices
                has_command="true"
                ;;
            build | "")
                pipeline_build_and_run
                has_command="true"
                ;;
            *)
                print_warning "Unknown command: $arg (skipping)"
                ;;
        esac
    done

    if [[ $has_command == "false" ]]; then
        show_help
    fi
}

main "$@"
