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
DEFAULT_IMAGE="ghcr.io/zeroclaw-labs/zeroclaw:v0.1.7"
DEFAULT_GATEWAY_PORT="42617"
DEFAULT_PROVIDER="deepseek"
DEFAULT_MODEL="deepseek-chat"

# Provider definitions (easily extensible)
declare -A PROVIDER_MODELS=(
    ["deepseek"]="deepseek-chat deepseek-coder deepseek-reasoner"
    ["ollama"]="llama3 mistral codellama"
    ["openai"]="gpt-4o gpt-4o-mini gpt-4-turbo"
    ["openrouter"]="anthropic/claude-3.5-sonnet google/gemini-pro-1.5 meta-llama/llama-3.1-70b-instruct"
    ["anthropic"]="claude-sonnet-4-20250514 claude-opus-4-20250514 claude-3-5-haiku-20241022"
    ["google"]="gemini-2.0-flash-exp gemini-1.5-pro gemini-1.5-flash"
)

declare -A PROVIDER_DEFAULTS=(
    ["deepseek"]="deepseek-chat"
    ["ollama"]="llama3"
    ["openai"]="gpt-4o"
    ["openrouter"]="anthropic/claude-3.5-sonnet"
    ["anthropic"]="claude-sonnet-4-20250514"
    ["google"]="gemini-2.0-flash-exp"
)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

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

print_info() { echo -e "${BLUE}[INFO]${NC} $1" >&2; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1" >&2; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1" >&2; }
print_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

print_header() {
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}========================================${NC}" >&2
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

# Get docker compose command (prioritizes v2, falls back to v1)
get_docker_compose() {
    if docker compose version &> /dev/null 2>&1; then
        echo "docker compose"
    elif command -v docker-compose &> /dev/null; then
        echo "docker-compose"
    else
        print_error "docker-compose not found"
        return 1
    fi
}

# =============================================================================
# Provider/Model Selection Functions (DRY pattern)
# =============================================================================

prompt_provider() {
    local current_provider="${1:-}"
    local choice

    echo "" >&2
    echo "Available providers:" >&2
    echo "  1) deepseek (default)" >&2
    echo "  2) ollama" >&2
    echo "  3) google" >&2
    echo "  4) openrouter" >&2
    echo "  5) openai" >&2
    echo "  6) anthropic" >&2
    echo "  7) other" >&2

    if [[ -n $current_provider ]]; then
        echo -n "Select provider [${current_provider}]: " >&2
    else
        echo -n "Select provider [1]: " >&2
    fi
    read -r choice

    case "$choice" in
        2) echo "ollama" ;;
        3) echo "google" ;;
        4) echo "openrouter" ;;
        5) echo "openai" ;;
        6) echo "anthropic" ;;
        7) echo "other" ;;
        *) echo "${current_provider:-deepseek}" ;;
    esac
}

prompt_model() {
    local provider="$1"
    local current_model="${2:-}"
    local model

    local models="${PROVIDER_MODELS[$provider]:-}"

    # Handle 'other' provider
    if [[ $provider == "other" ]]; then
        echo -n "Enter model name: " >&2
        read -r model
        echo "${model:-gpt-4o}"
        return
    fi

    if [[ -z $models ]]; then
        echo "${current_model:-${PROVIDER_DEFAULTS[$provider]:-gpt-4o}}"
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
        backup_count=$(find "$backup_dir" -maxdepth 1 -name ".env.backup.*" -type f 2> /dev/null | wc -l)
        if [[ $backup_count -gt 0 ]]; then
            find "$backup_dir" -maxdepth 1 -name ".env.backup.*" -type f -delete 2> /dev/null
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
    ["deepseek"]="DEEPSEEK_API_KEY"
    ["ollama"]=""
    ["openai"]="OPENAI_API_KEY"
    ["openrouter"]="OPENROUTER_API_KEY"
    ["anthropic"]="ANTHROPIC_API_KEY"
    ["google"]="GEMINI_API_KEY"
)

setup_environment() {
    local tailscale_env_file="$BUILD_DIR/docker/tailscale/env/.env.tailscale"
    local zeroclaw_env_file="$BUILD_DIR/docker/zeroclaw/env/.env.zeroclaw"
    local tailscale_env_example="$DOCKER_DIR/tailscale/.env.tailscale.example"
    local zeroclaw_env_example="$DOCKER_DIR/zeroclaw/.env.zeroclaw.example"
    local provider model api_key gateway_port tailscale_auth_key

    # Ensure docker subdirectory exists
    validate_directory "$BUILD_DIR/docker" || return 1

    # Setup Tailscale env file
    if [[ ! -f $tailscale_env_file ]]; then
        # Check if .env.tailscale.example exists, copy it to preserve comments and format
        if [[ -f $tailscale_env_example ]]; then
            print_info "Copying $tailscale_env_example to $tailscale_env_file to preserve comments..."
            cp -v "$tailscale_env_example" "$tailscale_env_file"
        else
            print_warning "$tailscale_env_example not found, creating new configuration..."
            touch "$tailscale_env_file"
        fi
    fi

    # Setup ZeroClaw env file
    if [[ ! -f $zeroclaw_env_file ]]; then
        # Check if .env.zeroclaw.example exists, copy it to preserve comments and format
        if [[ -f $zeroclaw_env_example ]]; then
            print_info "Copying $zeroclaw_env_example to $zeroclaw_env_file to preserve comments..."
            cp -v "$zeroclaw_env_example" "$zeroclaw_env_file"
        else
            print_warning "$zeroclaw_env_example not found, creating new configuration..."
            touch "$zeroclaw_env_file"
        fi
    fi

    # If either file is missing values, prompt for configuration
    local tailscale_needs_setup=$(read_env_value "$tailscale_env_file" "TS_AUTHKEY" "")
    local zeroclaw_needs_setup=$(read_env_value "$zeroclaw_env_file" "ZEROCLAW_API_KEY" "")

    if [[ -z $tailscale_needs_setup ]] || [[ -z $zeroclaw_needs_setup ]]; then
        print_info "Setting up configuration..."

        provider=$(prompt_provider)
        model=$(prompt_model "$provider" "$DEFAULT_MODEL")

        api_key=$(prompt_sensitive_input "Enter your LLM API key: ")

        echo -n "Enter gateway port [${DEFAULT_GATEWAY_PORT}]: " >&2
        read -r gateway_port
        gateway_port="${gateway_port:-$DEFAULT_GATEWAY_PORT}"

        # Prompt for Tailscale authentication (required)
        echo "" >&2
        echo "Tailscale Configuration:" >&2
        tailscale_auth_key=$(prompt_sensitive_input "Enter Tailscale Auth Key: ")

        # Update .env files with values (preserves comments from .env.*.example)
        # SECURITY: Use umask to restrict file permissions
        umask 0077

        # Update Tailscale env file
        update_env_file "$tailscale_env_file" "TS_AUTHKEY" "${tailscale_auth_key:-}"

        # Update ZeroClaw env file - only user-input variables needed
        # Other config variables use defaults from .env.zeroclaw.example
        update_env_file "$zeroclaw_env_file" "ZEROCLAW_API_KEY" "$api_key"

        # 同时设置 provider-specific API key
        if [[ -n ${PROVIDER_API_KEYS[$provider]:-} ]]; then
            update_env_file "$zeroclaw_env_file" "${PROVIDER_API_KEYS[$provider]}" "$api_key"
        fi

        update_env_file "$zeroclaw_env_file" "ZEROCLAW_PROVIDER" "$provider"
        update_env_file "$zeroclaw_env_file" "ZEROCLAW_MODEL" "$model"
        update_env_file "$zeroclaw_env_file" "ZEROCLAW_GATEWAY_PORT" "$gateway_port"

        # Restore normal umask
        umask 0022

        # Verify file permissions are correct
        chmod 600 "$tailscale_env_file" "$zeroclaw_env_file"

        print_success "Created $tailscale_env_file and $zeroclaw_env_file with secure permissions (600)"
    else
        print_info "Environment files exist, loading existing values..."

        # SECURITY: Check file permissions on existing env files
        local tailscale_env_perms zeroclaw_env_perms
        tailscale_env_perms=$(stat -c "%a" "$tailscale_env_file" 2> /dev/null || echo "unknown")
        zeroclaw_env_perms=$(stat -c "%a" "$zeroclaw_env_file" 2> /dev/null || echo "unknown")

        if [[ $tailscale_env_perms != "600" && $tailscale_env_perms != "400" ]]; then
            print_warning "Insecure file permissions on .env.tailscale: $tailscale_env_perms"
            print_warning "Fixing permissions..."
            chmod 600 "$tailscale_env_file"
            print_success "Permissions fixed to 600"
        fi

        if [[ $zeroclaw_env_perms != "600" && $zeroclaw_env_perms != "400" ]]; then
            print_warning "Insecure file permissions on .env.zeroclaw: $zeroclaw_env_perms"
            print_warning "Fixing permissions..."
            chmod 600 "$zeroclaw_env_file"
            print_success "Permissions fixed to 600"
        fi

        local existing_provider existing_model
        existing_provider=$(read_env_value "$zeroclaw_env_file" "ZEROCLAW_PROVIDER" "$DEFAULT_PROVIDER")
        existing_model=$(read_env_value "$zeroclaw_env_file" "ZEROCLAW_MODEL" "$DEFAULT_MODEL")

        # Prompt: Force update AI model settings? (default: skip)
        # Read existing API key and mask it for security display
        local existing_api_key
        existing_api_key=$(read_env_value "$zeroclaw_env_file" "ZEROCLAW_API_KEY" "")

        # Mask API key: show first 4 and last 4 characters
        local masked_api_key=""
        if [[ -n $existing_api_key ]]; then
            local key_len=${#existing_api_key}
            if [[ $key_len -gt 12 ]]; then
                masked_api_key="${existing_api_key:0:4}...${existing_api_key: -4}"
            else
                masked_api_key="****"
            fi
        else
            masked_api_key="(not set)"
        fi

        echo "" >&2
        echo "Detect Current AI Model Settings:" >&2
        echo "  Provider: $existing_provider" >&2
        echo "  Model:    $existing_model" >&2
        echo "  API Key:  $masked_api_key" >&2
        echo "" >&2
        echo "Select an option:" >&2
        echo "  1) Skip AI model settings update (default)" >&2
        echo "  2) Force update AI model settings" >&2
        echo -n "Enter your choice [1]: " >&2
        read -r force_update
        echo "" >&2

        if [[ $force_update == "2" ]]; then
            provider=$(prompt_provider "$existing_provider")
            model=$(prompt_model "$provider" "$existing_model")

            echo "" >&2
            echo -n "Update API key? (y/N): " >&2
            read -r update_key

            if [[ $update_key =~ ^[Yy]$ ]]; then
                api_key=$(prompt_sensitive_input "Enter your LLM API key: ")

                backup_env_file "$zeroclaw_env_file"
                update_env_file "$zeroclaw_env_file" "ZEROCLAW_API_KEY" "$api_key"
                print_success "API key updated"
            fi

            backup_env_file "$zeroclaw_env_file"
            update_env_file "$zeroclaw_env_file" "ZEROCLAW_PROVIDER" "$provider"
            update_env_file "$zeroclaw_env_file" "ZEROCLAW_MODEL" "$model"
            print_success "Provider: $provider, Model: $model"
        else
            print_info "Skipped AI model settings update (using existing configuration)"
            provider="$existing_provider"
            model="$existing_model"
        fi

        # Tailscale Configuration Update (show option to update)
        echo "" >&2
        echo "Detect Current Tailscale Configuration:" >&2
        local current_tailscale_key
        current_tailscale_key=$(read_env_value "$tailscale_env_file" "TS_AUTHKEY" "")
        local masked_tailscale_key=""
        if [[ -n $current_tailscale_key ]]; then
            local key_len=${#current_tailscale_key}
            if [[ $key_len -gt 14 ]]; then
                masked_tailscale_key="${current_tailscale_key:0:8}...${current_tailscale_key: -6}"
            else
                masked_tailscale_key="****"
            fi
            echo "  Auth Key:  $masked_tailscale_key" >&2
        else
            echo "  Auth Key:  (not set)" >&2
        fi
        echo "" >&2
        echo "Select an option:" >&2
        echo "  1) Skip Tailscale Auth Key update (default)" >&2
        echo "  2) Force update Tailscale Auth Key" >&2
        echo -n "Enter your choice [1]: " >&2
        read -r update_tailscale
        echo "" >&2

        if [[ $update_tailscale == "2" ]]; then
            tailscale_auth_key=$(prompt_sensitive_input "Enter Tailscale Auth Key: ")

            backup_env_file "$tailscale_env_file"
            update_env_file "$tailscale_env_file" "TS_AUTHKEY" "$tailscale_auth_key"
            print_success "Tailscale Auth Key updated"
        else
            print_info "Skipped Tailscale configuration update (using existing configuration)"
        fi
    fi
}

# =============================================================================
# Docker Operations (Single Responsibility)
# =============================================================================

check_docker() {
    print_info "Checking Docker..."
    validate_docker || return 1
    print_success "Docker is available"
}

pull_image() {
    print_info "Pulling ZeroClaw image..."
    if docker pull "$DEFAULT_IMAGE" 2> /dev/null; then
        print_success "Image pulled"
    else
        print_warning "Could not pull latest image, using cached version"
    fi
}

cleanup_old() {
    print_info "Cleaning up old containers and volumes..."

    local dc
    dc=$(get_docker_compose) || return 1

    cd "$DOCKER_DIR" || {
        print_error "Cannot change to docker directory" && return 1
    }
    $dc down -v || true
    print_success "Cleanup completed"
}

# ==================== NEW: Tailscale Health Functions ====================
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
# ==================== END Tailscale Functions =========================

cleanup_tailscale_offline() {
    local cfg_file="$BUILD_DIR/tailscale.cfg"

    # Detect existing config
    local current_api_token current_tailnet_id update_choice needs_prompt=false
    current_api_token=$(read_env_value "$cfg_file" "TAILSCALE_API_TOKEN" "")
    current_tailnet_id=$(read_env_value "$cfg_file" "TAILSCALE_TAILNET_ID" "")

    if [[ -n $current_api_token && -n $current_tailnet_id ]]; then
        # Mask API key like existing Tailscale logic
        local masked_key="****"
        if [[ ${#current_api_token} -gt 14 ]]; then
            masked_key="${current_api_token:0:8}...${current_api_token: -6}"
        fi

        echo "Detect Current Tailscale Configuration:" >&2
        echo "  Tailscale API Access Token:  $masked_key" >&2
        echo "  Tailnet ID:   $current_tailnet_id" >&2
        echo "" >&2
        echo "Select an option:" >&2
        echo "  1) Skip Tailscale devices management config update (default)" >&2
        echo "  2) Force update Tailscale devices management config" >&2
        echo -n "Enter your choice [1]: " >&2
        read -r update_choice
        echo "" >&2

        if [[ $update_choice != "2" ]]; then
            print_info "Skipped Tailscale devices management config update (using existing config)."
            tailscale_api_token="$current_api_token"
            tailscale_tailnet_id="$current_tailnet_id"
        else
            needs_prompt=true
        fi
    else
        needs_prompt=true
    fi

    if [[ $needs_prompt == true ]]; then
        print_info "Cleaning up offline Tailscale peers using API..."
        print_info 'NOTE: Please get a Tailscale API access token from "https://login.tailscale.com/admin/settings/keys".'
        tailscale_api_token=$(prompt_sensitive_input "Enter Tailscale API access token: ")

        if [[ -z $tailscale_api_token ]]; then
            print_error "Tailscale API access token required."
            return 1
        fi

        print_info 'Note: Please get your Tailscale tailnet ID from "https://login.tailscale.com/admin/settings/general".'
        tailscale_tailnet_id=$(prompt_sensitive_input "Enter your Tailscale tailnet ID: ")

        # Save to config
        if [[ ! -f $cfg_file ]]; then
            touch "$cfg_file"
        fi

        update_env_file "$cfg_file" "TAILSCALE_API_TOKEN" "$tailscale_api_token"
        update_env_file "$cfg_file" "TAILSCALE_TAILNET_ID" "$tailscale_tailnet_id"
        chmod 600 "$cfg_file"
        print_success "Saved Tailscale cleanup config to $cfg_file (600)"
    fi

    print_info "Using tailnet ID: $tailscale_tailnet_id"

    local devices_json http_code
    devices_json=$(curl -s -w "HTTP%{http_code}" \
        "https://api.tailscale.com/api/v2/tailnet/${tailscale_tailnet_id}/devices" \
        -H "Authorization: Bearer ${tailscale_api_token}")

    http_code="${devices_json: -3}"
    devices_json="${devices_json%???}"

    if [[ $http_code != "200" ]]; then
        print_error "Tailscale API fetch failed: HTTP $http_code. Check token/tailnet."
        return 1
    fi
    # DEBUG: Print JSON preview
    print_info "Device JSON preview (first 500 chars):"
    printf '%s...\n' "${devices_json}" >&2

    local offline_ids
    offline_ids=$(echo "$devices_json" | jq -r '.devices[]? | select(.connectedToControl == false) | .nodeId' 2> /dev/null || true)
    local offline_count=$(printf '%s\n' "$offline_ids" | grep -c .)
    print_info "Offline peers count: $offline_count"

    if [[ $offline_count -gt 0 ]]; then
        print_info "Offline nodeIds: $(printf '%s\n' \"$offline_ids\")"
        local removed_count=0
        while IFS= read -r device_id; do
            print_info "DELETE $device_id"
            if [[ -n $device_id ]]; then
                local curl_response
                curl_response=$(curl -s -w "HTTP%{http_code}" "https://api.tailscale.com/api/v2/device/$device_id" \
                    -X DELETE -H "Authorization: Bearer $tailscale_api_token" 2>&1)
                if [[ $curl_response == *"HTTP200"* ]]; then
                    print_success "Removed: expired offline device $device_id"
                    removed_count=$((removed_count+1))
                else
                    print_warning "Failed: $device_id - check scopes/key - response: $curl_response"
                fi
            fi
        done < <(printf '%s\n' "$offline_ids")
        print_success "Cleanup: expired $removed_count offline devices"
    else
        print_info "No offline devices to clean."
    fi
}

# Check Tailscale connection status and return detailed info
# Returns: IP address if connected, or status message
get_tailscale_status() {
    local json ip logged_in
    json=$(tailscale_health_json)
    ip=$(json_get "$json" "ip")
    logged_in=$(json_get "$json" "loggedIn")

    if [[ $logged_in == "true" ]]; then
        echo "$ip"
    elif [[ $ip == "" ]]; then
        echo "NeedsLogin"
    else
        echo "NoAuth"
    fi
}

# Extract current auth URL from docker logs
get_current_auth_url() {
    docker logs tailscale 2>&1 | grep -o 'https://login.tailscale.com/a/[a-zA-Z0-9]*' | tail -1
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
    print_info "Starting ZeroClaw container..."

    local dc
    dc=$(get_docker_compose) || return 1

    cd "$DOCKER_DIR" || {
        print_error "Cannot change to docker directory" && return 1
    }

    # Start tailscale first (required for zeroclaw network)
    print_info "Starting Tailscale container..."
    if ! $dc up -d tailscale; then
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

    cleanup_tailscale_offline

    # Now start zeroclaw
    print_info "Starting ZeroClaw container..."
    if ! $dc up -d zeroclaw; then
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
    $dc ps
}

# =============================================================================
# Command Functions (Command Pattern)
# =============================================================================

show_help() {
    print_header "ZeroClaw Build Script v$SCRIPT_VERSION"
    cat << EOF

Usage: $0 [command]

Commands:
  (none)   - Clean build and run (default)
  help     - Show this help message
  clean    - Clean build artifacts
  distclean - Deep clean (removes all generated files)
  logs     - View container logs
  status   - Show container status
  stop     - Stop containers
  restart  - Restart containers
  cleanup-tailscale-offline - Clean up offline Tailscale peers using API

Examples:
  $0           # Clean build and run
  $0 help      # Show help
  $0 clean     # Clean build artifacts
  $0 distclean # Deep clean all generated files
  $0 logs      # View logs
  $0 stop      # Stop containers

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
}

# Build and run pipeline (Pipeline pattern)
pipeline_build_and_run() {
    local -a steps=(
        "do_clean:Step 1: Cleaning previous build"
        "setup_directories:Step 2: Setting up build directories"
        "check_docker:Step 3: Checking Docker"
        "setup_environment:Step 4: Setting up environment"
        "setup_config:Step 5: Setting up config file"
        "pull_image:Step 6: Pulling latest image"
        "cleanup_old:Step 7: Cleaning up old containers"
        "start_container:Step 8: Starting container"
    )

    local step_func step_desc
    for step in "${steps[@]}"; do
        step_func="${step%%:*}"
        step_desc="${step##*:}"
        print_info "$step_desc..."

        if ! $step_func; then
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
    # Also create the zeroclaw/config subdirectory for config mounting
    validate_directory "$BUILD_DIR/docker/zeroclaw/config" || return 1
    # Also create the zeroclaw/env subdirectory for env file mounting
    validate_directory "$BUILD_DIR/docker/zeroclaw/env" || return 1
    # Also create the tailscale/env subdirectory for env file mounting
    validate_directory "$BUILD_DIR/docker/tailscale/env" || return 1
    print_success "Build directories created"
}

setup_config() {
    print_info "Setting up ZeroClaw configuration..."

    local src_config="$DOCKER_DIR/zeroclaw/config.toml"
    local dest_config="$BUILD_DIR/docker/zeroclaw/config/config.toml"

    if [[ ! -f $src_config ]]; then
        print_error "Source config not found: $src_config"
        return 1
    fi

    if cp --preserve "$src_config" "$dest_config" 2> /dev/null; then
        # Make config readable for container (container runs as root)
        print_success "Config copied to $dest_config"
    else
        print_error "Failed to copy config file"
        return 1
    fi
}

do_logs() {
    local dc
    dc=$(get_docker_compose) || return 1

    cd "$DOCKER_DIR" || {
        print_error "Cannot change to docker directory" && return 1
    }
    $dc logs -f
}

do_status() {
    local dc
    dc=$(get_docker_compose) || return 1

    cd "$DOCKER_DIR" || {
        print_error "Cannot change to docker directory" && return 1
    }
    $dc ps -a
}

do_stop() {
    local dc
    dc=$(get_docker_compose) || return 1

    cd "$DOCKER_DIR" || {
        print_error "Cannot change to docker directory" && return 1
    }
    $dc down -v
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
    local command="${1:-}"

    case "$command" in
        help | --help | -h)
            show_help
            ;;
        clean)
            do_clean
            ;;
        distclean)
            do_distclean
            ;;
        logs)
            do_logs
            ;;
        status)
            do_status
            ;;
        stop)
            do_stop
            ;;
        restart)
            do_restart
            ;;
        cleanup-tailscale-offline)
            cleanup_tailscale_offline "$@"
            ;;
        "")
            pipeline_build_and_run
            ;;
        *)
            print_error "Unknown command: $command"
            show_help
            return 1
            ;;
    esac
}

main "$@"
