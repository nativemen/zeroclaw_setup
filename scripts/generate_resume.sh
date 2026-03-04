#!/bin/bash
# =============================================================================
# ZeroClaw Resume Generation Script
# Uses ZeroClaw Docker container to generate English resumes
# =============================================================================

set -e

# =============================================================================
# SECURITY CONFIGURATION - No defaults, must be provided by user
# =============================================================================
ZEROCLAW_HOST="${ZEROCLAW_HOST:-localhost}"
ZEROCLAW_PORT="${ZEROCLAW_PORT:-42617}"

# Security: API key and pairing token MUST be provided via environment
# No hardcoded defaults - this is intentional for security
ZEROCLAW_API_KEY="${ZEROCLAW_API_KEY:-}"
PAIRING_TOKEN="${PAIRING_TOKEN:-}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

# =============================================================================
# SECURITY: Input Validation Functions
# =============================================================================

# Validate that input contains only safe characters (prevent injection)
validate_input() {
    local input="$1"
    local input_name="$2"

    # Check for null or empty input
    if [[ -z "$input" ]]; then
        print_error "$input_name cannot be empty"
        return 1
    fi

    # Check for potentially dangerous characters that could be used in injection
    # Allow alphanumeric, spaces, common punctuation, but block special chars
    if [[ "$input" =~ [\<\>\'\"\`\$\(\)\|\;\&\\\\] ]]; then
        print_error "$input_name contains invalid characters"
        return 1
    fi

    # Check input length (prevent DoS with huge inputs)
    if [[ ${#input} -gt 10000 ]]; then
        print_error "$input_name exceeds maximum length of 10000 characters"
        return 1
    fi

    return 0
}

# Escape input for JSON (prevent JSON injection)
escape_json() {
    local input="$1"
    # Use printf for safe escaping
    printf '%s' "$input" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g; s/\r//g'
}

# Validate port number
validate_port() {
    local port="$1"
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [[ $port -lt 1 ]] || [[ $port -gt 65535 ]]; then
        print_error "Invalid port number: $port"
        return 1
    fi
    return 0
}

# Validate host (prevent SSRF - Server-Side Request Forgery)
validate_host() {
    local host="$1"

    # Block private IP ranges that could be used for SSRF
    if [[ "$host" =~ ^(127\.|10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.) ]]; then
        # Allow localhost and private ranges only if explicitly configured
        if [[ "$host" != "127.0.0.1" && "$host" != "localhost" && "$ZEROCLAW_ALLOW_PRIVATE" != "true" ]]; then
            print_warning "Private network addresses are not allowed by default"
            return 1
        fi
    fi

    # Block localhost if pairing is required and not provided
    return 0
}

# =============================================================================
# Security Check: Verify credentials are provided
# =============================================================================

check_security_config() {
    local missing_vars=()

    if [[ -z "$ZEROCLAW_API_KEY" ]]; then
        missing_vars+=("ZEROCLAW_API_KEY")
    fi

    if [[ -z "$PAIRING_TOKEN" ]]; then
        missing_vars+=("PAIRING_TOKEN")
    fi

    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        print_error "Missing required security configuration:"
        for var in "${missing_vars[@]}"; do
            echo "  - $var"
        done
        echo ""
        echo "Please set these environment variables before running the script:"
        echo "  export ZEROCLAW_API_KEY='your-api-key'"
        echo "  export PAIRING_TOKEN='your-pairing-token'"
        return 1
    fi

    # Validate token format (should not be simple/common values)
    if [[ "$PAIRING_TOKEN" =~ ^(demo|test|1234|password|secret)$ ]] || [[ ${#PAIRING_TOKEN} -lt 16 ]]; then
        print_error "Pairing token is too weak. Use a strong, unique token (minimum 16 characters)"
        return 1
    fi

    print_success "Security configuration validated"
    return 0
}

# Wait for ZeroClaw to be ready (with timeout and proper error handling)
wait_for_zeroclaw() {
    print_info "Waiting for ZeroClaw gateway..."
    local max_attempts=30
    local attempt=1

    # Validate host and port before connecting
    validate_host "$ZEROCLAW_HOST" || return 1
    validate_port "$ZEROCLAW_PORT" || return 1

    # Use HTTPS if available, fallback to HTTP
    local protocol="http"
    if [[ "$ZEROCLAW_USE_HTTPS" == "true" ]]; then
        protocol="https"
    fi

    while [ $attempt -le $max_attempts ]; do
        # Use timeout and fail on redirect (security)
        if curl -sf --connect-timeout 5 --max-time 10 \
            "${protocol}://${ZEROCLAW_HOST}:${ZEROCLAW_PORT}/health" > /dev/null 2>&1; then
            print_success "ZeroClaw gateway is ready"
            return 0
        fi
        echo -n "."
        sleep 2
        attempt=$((attempt + 1))
    done

    print_error "ZeroClaw gateway not available after $max_attempts attempts"
    return 1
}

# Get pairing token - require explicit configuration
get_pairing_token() {
    if [ -n "$PAIRING_TOKEN" ]; then
        print_info "Pairing token configured (length: ${#PAIRING_TOKEN} characters)"
        return 0
    fi

    print_error "PAIRING_TOKEN environment variable is not set"
    echo ""
    echo "To generate a resume, you must provide a pairing token:"
    echo "  export PAIRING_TOKEN='your-secure-token'"
    echo ""
    echo "Note: Token must be at least 16 characters and cannot be common values"
    return 1
}

# Generate resume (with input validation and secure API call)
generate_resume() {
    local prompt="$1"
    local output_file="$2"

    # Validate input prompt
    validate_input "$prompt" "Prompt" || return 1

    # Validate output file path (prevent path traversal)
    if [[ "$output_file" != "/dev/stdout" ]]; then
        if [[ "$output_file" =~ \.\./ ]] || [[ "$output_file" =~ ^/etc ]] || [[ "$output_file" =~ ^/root ]]; then
            print_error "Invalid output file path (path traversal detected)"
            return 1
        fi
    fi

    print_info "Generating resume..."

    # Sanitize prompt for JSON (prevent injection)
    local sanitized_prompt
    sanitized_prompt=$(escape_json "$prompt")

    # Build the request with secure options
    local json_payload="{\"message\": \"$sanitized_prompt\"}"

    # Determine protocol
    local protocol="http"
    if [[ "$ZEROCLAW_USE_HTTPS" == "true" ]]; then
        protocol="https"
    fi

    # Make secure API request with timeout and error handling
    local response
    local http_code
    http_code=$(curl -sf -w "%{http_code}" --connect-timeout 10 --max-time 60 \
        -X POST "${protocol}://${ZEROCLAW_HOST}:${ZEROCLAW_PORT}/webhook" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${PAIRING_TOKEN}" \
        -d "$json_payload" -o /tmp/zeroclaw_response_$$ 2>&1) || {
            print_error "Failed to connect to ZeroClaw gateway"
            return 1
        }

    # Check HTTP response code
    if [[ "$http_code" -eq 200 ]]; then
        cat /tmp/zeroclaw_response_$$ > "$output_file"
        rm -f /tmp/zeroclaw_response_$$
        print_success "Resume saved to $output_file"
    elif [[ "$http_code" -eq 401 ]]; then
        rm -f /tmp/zeroclaw_response_$$
        print_error "Authentication failed - invalid pairing token"
        return 1
    elif [[ "$http_code" -eq 403 ]]; then
        rm -f /tmp/zeroclaw_response_$$
        print_error "Access forbidden - pairing required"
        return 1
    else
        rm -f /tmp/zeroclaw_response_$$
        print_error "API request failed with HTTP code: $http_code"
        return 1
    fi
}

# Interactive mode (with input validation)
interactive_mode() {
    print_info "Starting interactive resume generation..."
    print_info "ZeroClaw gateway: http://${ZEROCLAW_HOST}:${ZEROCLAW_PORT}"
    print_info "Type 'exit' to quit"
    echo ""

    while true; do
        echo -n "> "
        read -r prompt

        if [ "$prompt" = "exit" ] || [ "$prompt" = "quit" ]; then
            print_info "Goodbye!"
            break
        fi

        if [ -n "$prompt" ]; then
            # Validate input before sending
            if validate_input "$prompt" "Prompt"; then
                generate_resume "$prompt" "/dev/stdout"
            fi
        fi
        echo ""
    done
}

# Show help
help() {
    echo "ZeroClaw Resume Generation Script"
    echo ""
    echo "Usage: $0 [command] [options]"
    echo ""
    echo "Commands:"
    echo "  generate <prompt>    Generate resume from prompt"
    echo "  interactive          Interactive mode"
    echo "  wait                 Wait for ZeroClaw to be ready"
    echo "  help                 Show this help message"
    echo ""
    echo "Environment Variables (ALL REQUIRED for security):"
    echo "  ZEROCLAW_HOST        ZeroClaw gateway host (default: localhost)"
    echo "  ZEROCLAW_PORT        ZeroClaw gateway port (default: 42617)"
    echo "  ZEROCLAW_API_KEY     Your API key (REQUIRED)"
    echo "  PAIRING_TOKEN        Pairing token for auth (REQUIRED, min 16 chars)"
    echo "  ZEROCLAW_USE_HTTPS   Use HTTPS instead of HTTP (optional)"
    echo "  ZEROCLAW_ALLOW_PRIVATE Allow private network addresses (optional)"
    echo ""
    echo "Security Requirements:"
    echo "  - ZEROCLAW_API_KEY must be provided (no defaults)"
    echo "  - PAIRING_TOKEN must be at least 16 characters"
    echo "  - Common tokens like 'demo', 'test', 'password' are blocked"
    echo "  - Input validation prevents injection attacks"
    echo "  - HTTPS is recommended when available"
    echo ""
    echo "Examples:"
    echo "  export ZEROCLAW_API_KEY='your-api-key'"
    echo "  export PAIRING_TOKEN='your-secure-token-min-16-chars'"
    echo "  $0 generate \"Create an English resume for a software engineer\""
    echo "  $0 interactive"
    echo ""
    echo "Security Note: Never commit API keys or tokens to version control!"
}

# Main
main() {
    # Check security configuration before any operation
    check_security_config || exit 1

    case "$1" in
        generate)
            wait_for_zeroclaw || exit 1
            generate_resume "$2" "resume.md"
            ;;
        interactive)
            wait_for_zeroclaw || exit 1
            interactive_mode
            ;;
        wait)
            wait_for_zeroclaw
            ;;
        help|--help|-h)
            help
            ;;
        *)
            help
            ;;
    esac
}

main "$@"
