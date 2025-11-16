#!/bin/bash
# SVG Converter - Lightweight Alpine Version
#
# This script converts SVG files to multiple formats with configurable options:
#   - ICO (multi-resolution favicons)
#   - PNG (various sizes)
#   - React JS components
#   - React Native JS components

set -euo pipefail

# Version and script info
readonly VERSION="1.0.8"
SCRIPT_NAME="$(basename "$0")"

# Configuration constants
readonly MAX_SIZE=8192
readonly MIN_SIZE=8
readonly MAX_FILES=100
readonly TEMP_DIR="/tmp/svg-converter-$$"

# Global variables
declare -a CREATED_FILES=()
declare -a CONVERSION_SUMMARY=()
declare -a TEMP_FILES=()
SVG_CONVERTER="" # Will be set by check_dependencies

# Set readonly variables
readonly SCRIPT_NAME

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Detect color support
supports_color() {
    if [[ -n "${NO_COLOR:-}" ]]; then
        return 1
    fi

    if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
        local colors
        colors=$(tput colors 2>/dev/null || echo 0)
        [[ -n "$colors" && $colors -ge 8 ]] && return 0
    fi

    return 1
}

if ! supports_color; then
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    BOLD=''
    NC=''
fi

readonly RED GREEN YELLOW BLUE BOLD NC

# Initialize lightweight environment
init_lightweight_env() {
    # Ensure all required directories exist
    mkdir -p "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME"

    # Update font cache if needed
    if command -v fc-cache >/dev/null 2>&1; then
        fc-cache -f 2>/dev/null || true
    fi
}

# Cleanup function for trap
cleanup() {
    local exit_code=$?
    if [[ ${#TEMP_FILES[@]} -gt 0 ]]; then
        log_info "Cleaning up temporary files..."
        rm -f "${TEMP_FILES[@]}" 2>/dev/null || true
    fi
    [[ -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR" 2>/dev/null || true
    exit $exit_code
}

# Set up cleanup trap
trap cleanup EXIT INT TERM

# Logging functions
log_info() {
    echo -e "${GREEN}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_warn() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}" >&2
}

log_step() {
    echo -e "${BLUE}${BOLD}🔄 $1${NC}"
}

log_debug() {
    if [[ "${DEBUG:-false}" == "true" ]]; then
        echo -e "${BLUE}🐛 DEBUG: $1${NC}" >&2
    fi
}

# Show help
show_help() {
    cat <<EOF
${BOLD}$SCRIPT_NAME v$VERSION${NC}

Convert SVG files to multiple formats (ICO, PNG, React components).

${BOLD}USAGE:${NC}
    $SCRIPT_NAME [OPTIONS]

${BOLD}ENVIRONMENT VARIABLES:${NC}
    INPUT_SVG-PATH               Path to input SVG file (required)
    INPUT_OUTPUT-DIR             Output directory (default: ./)
    INPUT_FORMATS                Comma-separated formats: ico,png,react,react-native (default: ico,png,react,react-native)
    INPUT_PNG-SIZES              Comma-separated PNG sizes (default: 16,32,64,128,256)
    INPUT_ICO-SIZES              Comma-separated ICO sizes (default: 16,32,48,64)
    INPUT_BASE-NAME              Base name for output files (default: SVG filename)
    INPUT_REACT-TYPESCRIPT       Generate TypeScript files (default: false)
    INPUT_REACT-PROPS-INTERFACE  Props interface name (default: SVGProps)
    DEBUG                        Enable debug output (default: false)

${BOLD}EXAMPLES:${NC}
    # Basic usage
    INPUT_SVG-PATH=icon.svg $SCRIPT_NAME

    # Custom output with TypeScript
    INPUT_SVG-PATH=logo.svg INPUT_OUTPUT-DIR=dist INPUT_REACT-TYPESCRIPT=true $SCRIPT_NAME

    # PNG only with custom sizes
    INPUT_SVG-PATH=image.svg INPUT_FORMATS=png INPUT_PNG-SIZES=24,48,96 $SCRIPT_NAME

EOF
}

# Secure helper function to get input value from environment
get_input() {
    local key="$1"
    local default_value="${2:-}"

    # Support both hyphenated and underscored env names
    local env_var_underscore="INPUT_${key//-/_}"
    local env_var_hyphen="INPUT_${key}"

    # Retrieve value from either form
    local value=""
    if [[ -n "${!env_var_underscore:-}" ]]; then
        value="${!env_var_underscore}"
    else
        value="$(printenv "$env_var_hyphen" 2>/dev/null || true)"
    fi
    echo "${value:-$default_value}"
}

# Validate that a string contains only allowed characters
validate_safe_string() {
    local string="$1"
    local pattern="$2"
    local description="$3"

    if [[ ! "$string" =~ ^${pattern}$ ]]; then
        log_error "Invalid $description: '$string'. Allowed pattern: $pattern"
        return 1
    fi
}

# Validate numeric input
validate_number() {
    local value="$1"
    local min="$2"
    local max="$3"
    local description="$4"

    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        log_error "Invalid $description: '$value' is not a number"
        return 1
    fi

    if ((value < min || value > max)); then
        log_error "Invalid $description: '$value' must be between $min and $max"
        return 1
    fi
}

# Validate and sanitize file path
validate_path() {
    local path="$1"
    local description="$2"

    # Check for path traversal attempts
    if [[ "$path" =~ \.\. ]] || [[ "$path" =~ ^/ ]] && [[ "$description" == "output" ]]; then
        log_error "Invalid $description path: '$path' contains unsafe characters"
        return 1
    fi

    # Resolve and validate the path
    local resolved_path
    if [[ "$description" == "input" ]]; then
        resolved_path="$(realpath "$path" 2>/dev/null || echo "$path")"
    else
        resolved_path="$path"
    fi

    echo "$resolved_path"
}

# Validate size list
validate_sizes() {
    local sizes="$1"
    local description="$2"

    IFS=',' read -ra SIZE_ARRAY <<<"$sizes"

    if [[ ${#SIZE_ARRAY[@]} -gt 20 ]]; then
        log_error "Too many $description sizes specified (max: 20)"
        return 1
    fi

    for size in "${SIZE_ARRAY[@]}"; do
        size=$(echo "$size" | tr -d '[:space:]')
        validate_number "$size" "$MIN_SIZE" "$MAX_SIZE" "$description size" || return 1
    done
}

# Input variables validation
get_validated_inputs() {
    SVG_PATH=$(get_input 'SVG-PATH')
    OUTPUT_DIR=$(get_input 'OUTPUT-DIR' './')
    FORMATS=$(get_input 'FORMATS' 'ico,png,react,react-native')
    PNG_SIZES=$(get_input 'PNG-SIZES' '16,32,64,128,256')
    ICO_SIZES=$(get_input 'ICO-SIZES' '16,32,48,64')
    BASE_NAME=$(get_input 'BASE-NAME' '')
    REACT_TYPESCRIPT=$(get_input 'REACT-TYPESCRIPT' 'false')
    REACT_PROPS_INTERFACE=$(get_input 'REACT-PROPS-INTERFACE' 'SVGProps')
    DEBUG=$(get_input 'DEBUG' 'false')

    # Validate inputs
    validate_safe_string "$FORMATS" '[a-z,\-]+' "formats" || return 1
    validate_safe_string "$REACT_TYPESCRIPT" '(true|false)' "REACT_TYPESCRIPT" || return 1
    validate_safe_string "$DEBUG" '(true|false)' "DEBUG" || return 1
    validate_safe_string "$REACT_PROPS_INTERFACE" '[A-Za-z][A-Za-z0-9_]*' "REACT_PROPS_INTERFACE" || return 1

    if [[ -n "$BASE_NAME" ]]; then
        validate_safe_string "$BASE_NAME" '[A-Za-z0-9._\-]+' "base name" || return 1
    fi

    validate_sizes "$PNG_SIZES" "PNG" || return 1
    validate_sizes "$ICO_SIZES" "ICO" || return 1

    # Validate and sanitize paths
    if [[ "$OUTPUT_DIR" != */ ]]; then
        OUTPUT_DIR="${OUTPUT_DIR}/"
    fi
    OUTPUT_DIR=$(validate_path "$OUTPUT_DIR" "output") || return 1
    SVG_PATH=$(validate_path "$SVG_PATH" "input") || return 1

    # Make variables readonly
    readonly SVG_PATH OUTPUT_DIR FORMATS PNG_SIZES ICO_SIZES BASE_NAME REACT_TYPESCRIPT REACT_PROPS_INTERFACE DEBUG
}

# Validate required inputs
validate_inputs() {
    log_step "Validating inputs..."

    if [[ -z "$SVG_PATH" ]]; then
        log_error "SVG_PATH is required but not provided"
        show_help
        return 1
    fi

    if [[ ! -f "$SVG_PATH" ]]; then
        log_error "SVG file not found: $SVG_PATH"
        return 1
    fi

    if [[ ! "$SVG_PATH" =~ \.svg$ ]]; then
        log_error "File is not an SVG: $SVG_PATH"
        return 1
    fi

    # Check file size (basic safety check)
    local file_size
    file_size=$(stat -c%s "$SVG_PATH" 2>/dev/null || echo 0)
    if ((file_size > 10485760)); then # 10MB limit
        log_error "SVG file is too large (>10MB): $SVG_PATH"
        return 1
    fi

    # Create output directory if it doesn't exist
    if ! mkdir -p "$OUTPUT_DIR"; then
        log_error "Failed to create output directory: $OUTPUT_DIR"
        return 1
    fi

    # Create temp directory
    if ! mkdir -p "$TEMP_DIR"; then
        log_error "Failed to create temporary directory: $TEMP_DIR"
        return 1
    fi

    log_success "Input validation passed"
    log_debug "SVG_PATH:   $SVG_PATH"
    log_debug "OUTPUT_DIR: $OUTPUT_DIR"
    log_debug "FORMATS:    $FORMATS"
}

# Check if required tools are available
check_dependencies() {
    local missing_deps=()
    log_step "Checking dependencies..."

    # Initialize lightweight environment first
    init_lightweight_env

    # Check for SVG conversion capability (prioritize rsvg-convert for Alpine)
    if command -v rsvg-convert >/dev/null 2>&1; then
        log_info "✓ rsvg-convert found (lightweight and efficient)"
        SVG_CONVERTER="rsvg-convert"
    elif command -v magick >/dev/null 2>&1; then
        log_info "✓ ImageMagick found"
        SVG_CONVERTER="magick"
        # Test if ImageMagick can handle SVG
        if ! magick -list format | grep -q SVG; then
            log_warn "ImageMagick may not have full SVG support"
        fi
    elif command -v convert >/dev/null 2>&1; then
        log_info "✓ ImageMagick (legacy) found"
        SVG_CONVERTER="convert"
        # Test if ImageMagick can handle SVG
        if ! convert -list format | grep -q SVG; then
            log_warn "ImageMagick may not have full SVG support"
        fi
    else
        missing_deps+=("librsvg or imagemagick")
    fi

    # Check other dependencies based on requested formats
    if [[ "$FORMATS" =~ react ]]; then
        if ! command -v svgr >/dev/null 2>&1; then
            missing_deps+=("@svgr/cli")
        fi
    fi

    if ! command -v jq >/dev/null 2>&1; then
        missing_deps+=("jq")
    fi

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "Missing dependencies: ${missing_deps[*]}"
        log_error "Install them and try again."
        return 1
    fi

    # Make SVG_CONVERTER available globally
    readonly SVG_CONVERTER
    log_success "All dependencies satisfied"
}

# Get base name for output files
get_base_name() {
    if [[ -n "$BASE_NAME" ]]; then
        echo "$BASE_NAME"
    else
        basename "$SVG_PATH" .svg
    fi
}

# Helper function to convert SVG to PNG with specified size
convert_svg_to_png() {
    local input_svg="$1"
    local output_png="$2"
    local width="$3"
    local height="$4"

    log_debug "Converting $input_svg to $output_png (${width}x${height}) using $SVG_CONVERTER"

    if [[ "$SVG_CONVERTER" == "rsvg-convert" ]]; then
        if ! rsvg-convert -w "$width" -h "$height" "$input_svg" -o "$output_png" 2>/dev/null; then
            log_error "Failed to convert SVG to PNG using rsvg-convert"
            return 1
        fi
    elif [[ "$SVG_CONVERTER" == "magick" ]]; then
        if ! magick -background transparent -size "${width}x${height}" "$input_svg" "$output_png" 2>/dev/null; then
            log_error "Failed to convert SVG to PNG using ImageMagick"
            return 1
        fi
    elif [[ "$SVG_CONVERTER" == "convert" ]]; then
        if ! convert -background transparent -size "${width}x${height}" "$input_svg" "$output_png" 2>/dev/null; then
            log_error "Failed to convert SVG to PNG using ImageMagick (legacy)"
            return 1
        fi
    else
        log_error "No SVG converter available"
        return 1
    fi

    # Verify output file was created and has reasonable size
    if [[ ! -f "$output_png" ]] || [[ ! -s "$output_png" ]]; then
        log_error "Generated PNG file is missing or empty: $output_png"
        return 1
    fi

    log_debug "Successfully converted to PNG: $output_png ($(stat -c%s "$output_png" 2>/dev/null || echo "unknown") bytes)"
}

# Convert SVG to ICO format
convert_to_ico() {
    local base_name="$1"
    local output_file="${OUTPUT_DIR}${base_name}.ico"
    local tmp_png="${TEMP_DIR}/${base_name}_temp_ico.png"

    log_step "Converting to ICO format..."

    # Add temp file to cleanup list
    TEMP_FILES+=("$tmp_png")

    # Convert SVG to high-resolution PNG first
    local max_ico_size
    max_ico_size=$(echo "$ICO_SIZES" | tr ',' '\n' | sort -nr | head -n1)
    max_ico_size=${max_ico_size:-256}

    log_debug "Creating high-res intermediate PNG for ICO: ${max_ico_size}x${max_ico_size}"
    if ! convert_svg_to_png "$SVG_PATH" "$tmp_png" "$max_ico_size" "$max_ico_size"; then
        log_error "Failed to create intermediate PNG for ICO conversion"
        return 1
    fi

    # Create multi-resolution ICO using ImageMagick
    if command -v magick >/dev/null 2>&1; then
        log_debug "Using ImageMagick for ICO creation with sizes: $ICO_SIZES"
        if ! magick "$tmp_png" -define icon:auto-resize="$ICO_SIZES" "$output_file" 2>/dev/null; then
            log_error "Failed to create ICO file using ImageMagick"
            return 1
        fi
    elif command -v convert >/dev/null 2>&1; then
        log_debug "Using ImageMagick (legacy) for ICO creation with sizes: $ICO_SIZES"
        if ! convert "$tmp_png" -define icon:auto-resize="$ICO_SIZES" "$output_file" 2>/dev/null; then
            log_error "Failed to create ICO file using ImageMagick (legacy)"
            return 1
        fi
    else
        log_error "No ImageMagick installation found for ICO conversion"
        return 1
    fi

    CREATED_FILES+=("$output_file")
    CONVERSION_SUMMARY+=("ICO: $output_file (sizes: $ICO_SIZES)")
    log_success "Created ICO: $output_file"
}

# Convert SVG to PNG format(s) with parallel processing
convert_to_png() {
    local base_name="$1"
    log_step "Converting to PNG format(s)..."

    IFS=',' read -ra SIZES <<<"$PNG_SIZES"

    # Process sizes in parallel (limit to 4 concurrent jobs for efficiency)
    local max_jobs=4
    local current_jobs=0

    for size in "${SIZES[@]}"; do
        size=$(echo "$size" | tr -d '[:space:]')
        local output_file="${OUTPUT_DIR}${base_name}_${size}x${size}.png"

        # Wait if we've reached max concurrent jobs
        while ((current_jobs >= max_jobs)); do
            wait -n 2>/dev/null || true
            ((current_jobs--))
        done

        # Start conversion in background
        (
            if convert_svg_to_png "$SVG_PATH" "$output_file" "$size" "$size"; then
                log_success "Created PNG: $output_file"
            else
                log_error "Failed to create PNG: $output_file"
                exit 1
            fi
        ) &

        ((current_jobs++))
        CREATED_FILES+=("$output_file")
    done

    # Wait for all background jobs to complete
    wait

    CONVERSION_SUMMARY+=("PNG: ${#SIZES[@]} files created (sizes: $PNG_SIZES)")
}

# Convert SVG to React component
convert_to_react() {
    local base_name="$1"
    local extension="js"
    local output_file

    if [[ "$REACT_TYPESCRIPT" == "true" ]]; then
        extension="tsx"
    fi

    output_file="${OUTPUT_DIR}${base_name}.${extension}"

    log_step "Converting to React component..."

    local svgr_args=()

    # Add TypeScript flag if requested
    if [[ "$REACT_TYPESCRIPT" == "true" ]]; then
        svgr_args+=(--typescript)
    fi

    # Check if svgr supports props-interface option
    local supports_props_interface=false
    if svgr --help 2>/dev/null | grep -q "props-interface\|propsInterface"; then
        supports_props_interface=true
    fi

    # Add props interface if specified, supported, and not default
    if [[ -n "$REACT_PROPS_INTERFACE" ]] && [[ "$REACT_PROPS_INTERFACE" != "SVGProps" ]] && [[ "$supports_props_interface" == "true" ]]; then
        if svgr --help 2>/dev/null | grep -q "props-interface"; then
            svgr_args+=(--props-interface "$REACT_PROPS_INTERFACE")
        elif svgr --help 2>/dev/null | grep -q "propsInterface"; then
            svgr_args+=(--propsInterface "$REACT_PROPS_INTERFACE")
        fi
    elif [[ -n "$REACT_PROPS_INTERFACE" ]] && [[ "$REACT_PROPS_INTERFACE" != "SVGProps" ]] && [[ "$supports_props_interface" == "false" ]]; then
        log_warn "Props interface option not supported in this version of svgr, using default"
    fi

    # Convert SVG to React component
    if ! svgr "${svgr_args[@]}" "$SVG_PATH" >"$output_file"; then
        log_error "Failed to create React component"
        return 1
    fi

    CREATED_FILES+=("$output_file")
    CONVERSION_SUMMARY+=("React: $output_file (TypeScript: $REACT_TYPESCRIPT)")
    log_success "Created React component: $output_file"
}

# Convert SVG to React Native component
convert_to_react_native() {
    local base_name="$1"
    local extension="js"
    local output_file

    if [[ "$REACT_TYPESCRIPT" == "true" ]]; then
        extension="tsx"
    fi

    output_file="${OUTPUT_DIR}${base_name}.native.${extension}"

    log_step "Converting to React Native component..."

    local svgr_args=(--native)

    # Add TypeScript flag if requested
    if [[ "$REACT_TYPESCRIPT" == "true" ]]; then
        svgr_args+=(--typescript)
    fi

    # Check if svgr supports props-interface option
    local supports_props_interface=false
    if svgr --help 2>/dev/null | grep -q "props-interface\|propsInterface"; then
        supports_props_interface=true
    fi

    # Add props interface if specified, supported, and not default
    if [[ -n "$REACT_PROPS_INTERFACE" ]] && [[ "$REACT_PROPS_INTERFACE" != "SVGProps" ]] && [[ "$supports_props_interface" == "true" ]]; then
        if svgr --help 2>/dev/null | grep -q "props-interface"; then
            svgr_args+=(--props-interface "$REACT_PROPS_INTERFACE")
        elif svgr --help 2>/dev/null | grep -q "propsInterface"; then
            svgr_args+=(--propsInterface "$REACT_PROPS_INTERFACE")
        fi
    elif [[ -n "$REACT_PROPS_INTERFACE" ]] && [[ "$REACT_PROPS_INTERFACE" != "SVGProps" ]] && [[ "$supports_props_interface" == "false" ]]; then
        log_warn "Props interface option not supported in this version of svgr, using default"
    fi

    # Convert SVG to React Native component
    if ! svgr "${svgr_args[@]}" "$SVG_PATH" >"$output_file"; then
        log_error "Failed to create React Native component"
        return 1
    fi

    CREATED_FILES+=("$output_file")
    CONVERSION_SUMMARY+=("React Native: $output_file (TypeScript: $REACT_TYPESCRIPT)")
    log_success "Created React Native component: $output_file"
}

# Count total files that will be created
count_total_files() {
    local total_files=0
    IFS=',' read -ra FORMAT_ARRAY <<<"$FORMATS"

    for format in "${FORMAT_ARRAY[@]}"; do
        format=$(echo "$format" | tr -d '[:space:]')
        case "$format" in
        ico)
            total_files=$((total_files + 1))
            ;;
        png)
            IFS=',' read -ra PNG_ARRAY <<<"$PNG_SIZES"
            total_files=$((total_files + ${#PNG_ARRAY[@]}))
            ;;
        react)
            total_files=$((total_files + 1))
            ;;
        react-native)
            total_files=$((total_files + 1))
            ;;
        esac
    done

    echo "$total_files"
}

# Validate file count against MAX_FILES limit
validate_file_count() {
    log_step "Validating file count limits..."

    local total_files
    total_files=$(count_total_files)

    if ((total_files > MAX_FILES)); then
        log_error "Too many files would be created: $total_files (max: $MAX_FILES)"
        log_error "Reduce the number of PNG sizes or formats to stay within the limit"
        return 1
    fi

    log_success "File count validation passed: $total_files files will be created (max: $MAX_FILES)"
}

# Set GitHub Actions outputs
set_outputs() {
    local conversion_time=$1

    # Only set outputs if we're in GitHub Actions environment
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        local files_json
        local summary_text

        # Convert array to JSON
        files_json=$(printf '%s\n' "${CREATED_FILES[@]}" | jq -R . | jq -s -c .)

        # Create summary text
        summary_text=$(printf "Converted %s to %d files:\n%s" "$SVG_PATH" "${#CREATED_FILES[@]}" "$(printf '%s\n' "${CONVERSION_SUMMARY[@]}")")

        # Set outputs
        {
            echo "files-created=$files_json"
            echo "conversion-time=$conversion_time"
            echo "summary<<EOF"
            echo "$summary_text"
            echo "EOF"
        } >>"$GITHUB_OUTPUT"

        log_debug "GitHub Actions outputs set"
    fi
}

# Set error outputs when conversion fails
set_error_outputs() {
    local error_message=$1
    local conversion_time=${2:-0}

    # Only set outputs if we're in GitHub Actions environment
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        {
            echo "files-created=[]"
            echo "conversion-time=$conversion_time"
            echo "summary<<EOF"
            echo "Conversion failed: $error_message"
            echo "EOF"
        } >>"$GITHUB_OUTPUT"

        log_debug "GitHub Actions error outputs set"
    fi
}

# Main conversion function
main() {
    local start_time
    start_time=$(date +%s)

    # Handle help request
    if [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
        show_help
        exit 0
    fi

    log_info "🎨 SVG Converter v$VERSION (Lightweight) - Starting conversion..."

    # Get and validate inputs
    if ! get_validated_inputs; then
        log_error "Input validation failed"
        set_error_outputs "Input validation failed"
        exit 1
    fi

    if ! validate_inputs; then
        set_error_outputs "Input validation failed"
        exit 1
    fi

    if ! validate_file_count; then
        set_error_outputs "File count validation failed"
        exit 1
    fi

    log_info "📁 Input:   $SVG_PATH"
    log_info "📁 Output:  $OUTPUT_DIR"
    log_info "🎯 Formats: $FORMATS"

    if ! check_dependencies; then
        exit 1
    fi

    local base_name
    base_name=$(get_base_name)
    log_info "📝 Base name: $base_name"

    # Parse requested formats
    IFS=',' read -ra FORMAT_ARRAY <<<"$FORMATS"
    local conversion_errors=0

    for format in "${FORMAT_ARRAY[@]}"; do
        format=$(echo "$format" | tr -d '[:space:]')
        case "$format" in
        ico)
            convert_to_ico "$base_name" || ((conversion_errors++))
            ;;
        png)
            convert_to_png "$base_name" || ((conversion_errors++))
            ;;
        react)
            convert_to_react "$base_name" || ((conversion_errors++))
            ;;
        react-native)
            convert_to_react_native "$base_name" || ((conversion_errors++))
            ;;
        *)
            log_warn "Unknown format: $format"
            ((conversion_errors++))
            ;;
        esac
    done

    # Check if any conversions failed
    if ((conversion_errors > 0)); then
        log_error "$conversion_errors conversion(s) failed"
        local end_time=$(($(date +%s) - start_time))
        set_error_outputs "Conversion failed for $conversion_errors file(s)" "$end_time"
        exit 1
    fi

    # Calculate conversion time before setting outputs
    local end_time duration
    end_time=$(date +%s)
    duration=$((end_time - start_time))

    # Set GitHub Actions outputs with conversion time
    set_outputs "$duration"

    log_success "🎉 Conversion completed in ${duration}s! Created ${#CREATED_FILES[@]} files."

    # Print summary
    echo -e "\n${BOLD}📋 CONVERSION SUMMARY:${NC}"
    printf '%s\n' "${CONVERSION_SUMMARY[@]}"

    # Print file list if debug is enabled
    if [[ "${DEBUG:-false}" == "true" ]]; then
        echo -e "\n${BOLD}📄 CREATED FILES:${NC}"
        printf '%s\n' "${CREATED_FILES[@]}"
    fi
}

# Run main function
main "$@"
