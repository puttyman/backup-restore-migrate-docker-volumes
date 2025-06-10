#!/bin/bash

# Docker Volume Backup Script using rsync
# This script backs up Docker volumes from a remote server to local storage

set -euo pipefail

# Configuration
REMOTE_HOST="${REMOTE_HOST:-}"
REMOTE_USER="${REMOTE_USER:-root}"
REMOTE_DOCKER_ROOT="${REMOTE_DOCKER_ROOT:-/var/lib/docker/volumes}"
LOCAL_BACKUP_DIR="${LOCAL_BACKUP_DIR:-./docker-backups}"
SSH_KEY="${SSH_KEY:-}"
EXCLUDE_VOLUMES="${EXCLUDE_VOLUMES:-}"
DRY_RUN="${DRY_RUN:-false}"
VERBOSE="${VERBOSE:-false}"
COMPRESS="${COMPRESS:-true}"
DELETE_EXCLUDED="${DELETE_EXCLUDED:-false}"
KEEP_BACKUPS="${KEEP_BACKUPS:-7}"
AUTO_DETECT_DOCKER_ROOT="${AUTO_DETECT_DOCKER_ROOT:-true}"
CHECK_ALL_CONTEXTS="${CHECK_ALL_CONTEXTS:-true}"
INCLUDE_SYSTEM_DOCKER="${INCLUDE_SYSTEM_DOCKER:-true}"
# Interactive mode (true = ask for confirmation, false = non-interactive)
INTERACTIVE="${INTERACTIVE:-true}"

# Container-aware backup configuration
CONTAINER_STOP_TIMEOUT="${CONTAINER_STOP_TIMEOUT:-30}"
AUTO_RESTART_CONTAINERS="${AUTO_RESTART_CONTAINERS:-true}"
BACKUP_METHOD="${BACKUP_METHOD:-busybox}"
SHOW_PROGRESS="${SHOW_PROGRESS:-true}"
TEMP_BACKUP_DIR="${TEMP_BACKUP_DIR:-/tmp/docker-backups}"
FORCE_STOP="${FORCE_STOP:-false}"
AUTO_CONFIRM="${AUTO_CONFIRM:-false}"

# Trim whitespace from a string
trim() {
    local var="$*"
    # Remove leading whitespace
    var="${var#"${var%%[![:space:]]*}"}"
    # Remove trailing whitespace
    var="${var%"${var##*[![:space:]]}"}"
    printf '%s' "$var"
}

# Global arrays for tracking container operations
declare -gA CONTAINER_IMPACT=()
declare -a STOPPED_CONTAINERS
declare -A BACKUP_FILES
declare -gA VOLUME_MOUNT_POINTS=()

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" >&2
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Usage function
usage() {
    cat << EOF
Docker Volume Backup Script (Container-Aware)

Usage: $0 [OPTIONS]

Options:
    -h, --host HOST         Remote Docker host (required)
    -u, --user USER         Remote SSH user (default: root)
    -k, --key PATH          SSH private key path
    -d, --dest DIR          Local backup directory (default: ./docker-backups)
    -e, --exclude VOLUMES   Comma-separated list of volumes to exclude
    -i, --interactive      Interactive volume selection
    -n, --dry-run          Show what would be done without making changes
    -v, --verbose         Show more detailed output
    -c, --no-compress     Disable compression of backup files
    --delete              Delete excluded files from destination
    --interactive         Run in interactive mode (show prompts, default)
    --non-interactive     Run in non-interactive mode (no prompts)
    --keep N               Number of backups to keep (default: 7)
    --no-auto-detect       Disable automatic Docker root detection
    --no-contexts          Only check default Docker context
    --no-system            Skip system-level Docker check
    
Container Management Options:
    --stop-timeout N       Container stop timeout in seconds (default: 30)
    --non-interactive    Run in non-interactive mode (no prompts)
    --auto-confirm       Automatically confirm container operations in non-interactive mode
    --no-auto-restart    Do not automatically restart containers after backup
    --force-stop         Force stop containers if graceful stop fails
    --container-stop-timeout SECONDS
                      Timeout in seconds for graceful container stop (default: 30)
    --include-system-docker
                      Include system-level Docker volumes (requires sudo)
    --help               Show this help message
    --version            Show version information

Examples:
    $0 --host docker.example.com --user ubuntu --key ~/.ssh/id_rsa
    $0 -h 192.168.1.100 -u docker -d /backup/docker-volumes -e "temp_vol,cache_vol"
    $0 --host docker.example.com --interactive --user ubuntu --key ~/.ssh/id_rsa

EOF
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--host)
                REMOTE_HOST="$2"
                shift 2
                ;;
            -u|--user)
                REMOTE_USER="$2"
                shift 2
                ;;
            -k|--key)
                SSH_KEY="$2"
                shift 2
                ;;
            -d|--dest)
                LOCAL_BACKUP_DIR="$2"
                shift 2
                ;;
            -e|--exclude)
                EXCLUDE_VOLUMES="$2"
                shift 2
                ;;
            --non-interactive)
                INTERACTIVE="false"
                shift
                ;;
            --interactive)
                INTERACTIVE="true"
                shift
                ;;
            -n|--dry-run)
                DRY_RUN="true"
                shift
                ;;
            -v|--verbose)
                VERBOSE="true"
                shift
                ;;
            -c|--no-compress)
                COMPRESS="false"
                shift
                ;;
            --delete)
                DELETE_EXCLUDED="true"
                shift
                ;;
            --keep)
                KEEP_BACKUPS="$2"
                shift 2
                ;;
            --no-auto-detect)
                AUTO_DETECT_DOCKER_ROOT="false"
                shift
                ;;
            --no-contexts)
                CHECK_ALL_CONTEXTS="false"
                shift
                ;;
            --no-system)
                INCLUDE_SYSTEM_DOCKER="false"
                shift
                ;;
            --stop-timeout)
                CONTAINER_STOP_TIMEOUT="$2"
                shift 2
                ;;
            --no-auto-restart)
                AUTO_RESTART_CONTAINERS="false"
                shift
                ;;
            --no-progress)
                SHOW_PROGRESS="false"
                shift
                ;;
            --temp-dir)
                TEMP_BACKUP_DIR="$2"
                shift 2
                ;;
            --force-stop)
                FORCE_STOP="true"
                shift
                ;;
            --auto-confirm)
                AUTO_CONFIRM="true"
                shift
                ;;
            --help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
}

# Build SSH command
build_ssh_cmd() {
    local ssh_cmd="ssh"
    if [[ -n "$SSH_KEY" ]]; then
        ssh_cmd="ssh -i \"$SSH_KEY\""
    fi
    ssh_cmd="$ssh_cmd -o ConnectTimeout=10 -o BatchMode=yes"
    echo "$ssh_cmd"
}

# Build rsync SSH option
build_rsync_ssh() {
    if [[ -n "$SSH_KEY" ]]; then
        echo "ssh -i \"$SSH_KEY\""
    else
        echo "ssh"
    fi
}

# Validate configuration
validate_config() {
    if [[ -z "$REMOTE_HOST" ]]; then
        log_error "Remote host is required. Use -h/--host or set REMOTE_HOST environment variable."
        exit 1
    fi

    if [[ -n "$SSH_KEY" && ! -f "$SSH_KEY" ]]; then
        log_error "SSH key file not found: $SSH_KEY"
        exit 1
    fi

    # Test SSH connection
    log_info "Testing SSH connection to $REMOTE_USER@$REMOTE_HOST..."
    local ssh_cmd
    ssh_cmd=$(build_ssh_cmd)
    
    if ! eval "$ssh_cmd \"$REMOTE_USER@$REMOTE_HOST\" 'echo Connection successful'" &>/dev/null; then
        log_error "Cannot connect to $REMOTE_USER@$REMOTE_HOST"
        log_error "Please check your SSH key, username, and host connectivity"
        exit 1
    fi
    log_success "SSH connection successful"
}

# Detect Docker configuration and data root
detect_docker_info() {
    local ssh_cmd
    ssh_cmd=$(build_ssh_cmd)
    
    log_info "Detecting Docker configuration on $REMOTE_HOST..."
    
    # Try to get Docker info to detect data root
    if [[ "$AUTO_DETECT_DOCKER_ROOT" == "true" ]]; then
        local docker_info
        if docker_info=$(eval "$ssh_cmd \"$REMOTE_USER@$REMOTE_HOST\" 'docker info --format \"{{.DockerRootDir}}\"'" 2>/dev/null); then
            if [[ -n "$docker_info" && "$docker_info" != "null" ]]; then
                REMOTE_DOCKER_ROOT="$docker_info/volumes"
                log_info "Auto-detected Docker root: $REMOTE_DOCKER_ROOT"
            else
                log_warning "Could not auto-detect Docker root, using default: $REMOTE_DOCKER_ROOT"
            fi
        else
            log_warning "Failed to get Docker info, using default root: $REMOTE_DOCKER_ROOT"
        fi
    fi
}

# Get Docker contexts available on remote host
get_docker_contexts() {
    local ssh_cmd
    ssh_cmd=$(build_ssh_cmd)
    
    if [[ "$CHECK_ALL_CONTEXTS" != "true" ]]; then
        echo "default"
        return 0
    fi
    
    log_info "Discovering Docker contexts on $REMOTE_HOST..."
    local contexts
    if contexts=$(eval "$ssh_cmd \"$REMOTE_USER@$REMOTE_HOST\" 'docker context ls --format \"{{.Name}}\"'" 2>/dev/null); then
        if [[ -n "$contexts" ]]; then
            echo "$contexts"
        else
            echo "default"
        fi
    else
        log_warning "Could not list Docker contexts, using default only"
        echo "default"
    fi
}

# Get volumes from a specific Docker context
get_volumes_from_context() {
    local context="$1"
    local ssh_cmd
    ssh_cmd=$(build_ssh_cmd)
    
    local docker_cmd="docker"
    if [[ "$context" != "default" ]]; then
        docker_cmd="docker --context $context"
    fi
    
    local volumes
    if volumes=$(eval "$ssh_cmd \"$REMOTE_USER@$REMOTE_HOST\" '$docker_cmd volume ls -q'" 2>/dev/null); then
        echo "$volumes"
    fi
}

# Get volumes from system-level Docker (with sudo)
get_system_volumes() {
    local ssh_cmd
    ssh_cmd=$(build_ssh_cmd)
    
    if [[ "$INCLUDE_SYSTEM_DOCKER" != "true" ]]; then
        return 0
    fi
    
    log_info "Checking system-level Docker volumes..."
    local volumes
    if volumes=$(eval "$ssh_cmd \"$REMOTE_USER@$REMOTE_HOST\" 'sudo docker volume ls -q'" 2>/dev/null); then
        if [[ -n "$volumes" ]]; then
            echo "$volumes"
        fi
    else
        log_warning "Could not access system-level Docker (sudo may not be available)"
    fi
}

# Get comprehensive list of all Docker volumes from all sources
get_all_volumes() {
    local all_volumes=""
    local contexts
    
    # Get volumes from all contexts
    contexts=$(get_docker_contexts)
    while IFS= read -r context; do
        if [[ -n "$context" ]]; then
            log_info "Checking volumes in context: $context"
            local context_volumes
            context_volumes=$(get_volumes_from_context "$context")
            if [[ -n "$context_volumes" ]]; then
                all_volumes="$all_volumes"$'\n'"$context_volumes"
            fi
        fi
    done <<< "$contexts"
    
    # Get system-level volumes
    local system_volumes
    system_volumes=$(get_system_volumes)
    if [[ -n "$system_volumes" ]]; then
        all_volumes="$all_volumes"$'\n'"$system_volumes"
    fi
    
    # Remove duplicates and empty lines
    if [[ -n "$all_volumes" ]]; then
        echo "$all_volumes" | sort -u | grep -v '^$' || true
    fi
}

# Get list of Docker volumes from remote host
get_remote_volumes() {
    # First detect Docker configuration
    detect_docker_info
    
    # Get volumes from all sources
    log_info "Retrieving Docker volumes from $REMOTE_HOST..."
    local volumes
    volumes=$(get_all_volumes)
    
    if [[ -z "$volumes" ]]; then
        log_error "Failed to retrieve Docker volumes. Make sure Docker is running and accessible on the remote host."
        exit 1
    fi
    
    echo "$volumes"
}

# Check if volume should be excluded
is_excluded() {
    local volume="$1"
    if [[ -z "$EXCLUDE_VOLUMES" ]]; then
        return 1
    fi
    
    IFS=',' read -ra EXCLUDED <<< "$EXCLUDE_VOLUMES"
    for excluded in "${EXCLUDED[@]}"; do
        excluded=$(echo "$excluded" | xargs) # trim whitespace
        if [[ "$volume" == "$excluded" ]]; then
            return 0
        fi
    done
    return 1
}

# Check if remote volume path exists
check_remote_volume() {
    local volume="$1"
    local ssh_cmd
    ssh_cmd=$(build_ssh_cmd)
    
    local remote_path="$REMOTE_DOCKER_ROOT/$volume/_data"
    if ! eval "$ssh_cmd \"$REMOTE_USER@$REMOTE_HOST\" 'test -d \"$remote_path\"'" 2>/dev/null; then
        log_warning "Volume path does not exist on remote: $remote_path"
        return 1
    fi
    return 0
}

# Get containers using a specific volume
get_containers_using_volume() {
    local volume="$1"
    local ssh_cmd
    ssh_cmd=$(build_ssh_cmd)
    
    local containers=""
    
    # Check all Docker contexts for containers using this volume
    local contexts
    contexts=$(get_docker_contexts)
    
    while IFS= read -r context; do
        if [[ -n "$context" ]]; then
            local docker_cmd="docker"
            if [[ "$context" != "default" ]]; then
                docker_cmd="docker --context $context"
            fi
            
            # Try with volume name filter
            if context_containers=$(eval "$ssh_cmd \"$REMOTE_USER@$REMOTE_HOST\" '$docker_cmd ps -a --filter volume=$volume --format \"{{.Names}}:{{.Status}}\"'" 2>/dev/null); then
                if [[ -n "$context_containers" ]]; then
                    containers="$containers"$'\n'"$context_containers"
                fi
            fi
            
            # Try with mount point filter
            # First get all mounts
            local mounts
            mounts=$(eval "$ssh_cmd \"$REMOTE_USER@$REMOTE_HOST\" '$docker_cmd ps -a --format \"{{.Mounts}}\"'" 2>/dev/null)
            
            if [[ -n "$mounts" ]]; then
                if [[ "$VERBOSE" == "true" ]]; then
                    log_info "Found mounts: $mounts"
                fi
                
                # Process each mount to find matching containers
                while IFS= read -r mount_info; do
                    if [[ "$mount_info" =~ $volume ]]; then
                        if [[ "$VERBOSE" == "true" ]]; then
                            log_info "Found matching mount: $mount_info"
                        fi
                        
                        # Get container ID from mount info
                        local container_id="${mount_info%% *}"  # Get first field
                        
                        if [[ "$VERBOSE" == "true" ]]; then
                            log_info "Container ID: $container_id"
                        fi
                        
                        # Get container details
                        local container_details
                        container_details=$(eval "$ssh_cmd \"$REMOTE_USER@$REMOTE_HOST\" '$docker_cmd ps -a --format \"{{.Names}}:{{.Status}}\"' | grep -F \"$container_id\"" 2>/dev/null)
                        
                        if [[ -n "$container_details" ]]; then
                            if [[ "$VERBOSE" == "true" ]]; then
                                log_info "Found container details: $container_details"
                            fi
                            containers="$containers"$'\n'"$container_details"
                        else
                            if [[ "$VERBOSE" == "true" ]]; then
                                log_info "No details found for container ID: $container_id"
                            fi
                        fi
                    fi
                done <<< "$mounts"
            else
                if [[ "$VERBOSE" == "true" ]]; then
                    log_info "No mounts found for volume: $volume"
                fi
            fi
        fi
    done <<< "$contexts"
    
    # Also check system-level Docker if enabled
    if [[ "$INCLUDE_SYSTEM_DOCKER" == "true" ]]; then
        # Try with volume name filter
        if system_containers=$(eval "$ssh_cmd \"$REMOTE_USER@$REMOTE_HOST\" 'sudo docker ps -a --filter volume=$volume --format \"{{.Names}}:{{.Status}}\"'" 2>/dev/null); then
            if [[ -n "$system_containers" ]]; then
                containers="$containers"$'\n'"$system_containers"
            fi
        fi
        
        # Try with mount point filter
        # First get all mounts
        local mounts
        mounts=$(eval "$ssh_cmd \"$REMOTE_USER@$REMOTE_HOST\" 'sudo docker ps -a --format \"{{.Mounts}}\"'" 2>/dev/null)
        
        if [[ -n "$mounts" ]]; then
            # Process each mount to find matching containers
            while IFS= read -r mount_info; do
                if [[ "$mount_info" =~ $volume ]]; then
                    # Get container ID from mount info
                    local container_id="${mount_info%% *}"  # Get first field
                    
                    # Get container details
                    local container_details
                    container_details=$(eval "$ssh_cmd \"$REMOTE_USER@$REMOTE_HOST\" 'sudo docker ps -a --format \"{{.Names}}:{{.Status}}\"' | grep -F \"$container_id\"" 2>/dev/null)
                    
                    if [[ -n "$container_details" ]]; then
                        containers="$containers"$'\n'"$container_details"
                    fi
                fi
            done <<< "$mounts"
        fi
    fi
    
    # Remove duplicates and empty lines
    if [[ -n "$containers" ]]; then
        echo "$containers" | sort -u | grep -v '^$' || true
    fi
}

# Get volume mount points for a container
get_volume_mount_points() {
    local container="$1"
    local volume="$2"
    local ssh_cmd
    ssh_cmd=$(build_ssh_cmd)
    
    # Get mount information from container inspect
    local mount_info
    if mount_info=$(eval "$ssh_cmd \"$REMOTE_USER@$REMOTE_HOST\" 'docker inspect $container --format \"{{range .Mounts}}{{if eq .Name \\\"$volume\\\"}}{{.Destination}}{{end}}{{end}}\"'" 2>/dev/null); then
        if [[ -n "$mount_info" ]]; then
            echo "$mount_info"
        fi
    fi
}

# Global associative array to store container impact information
declare -gA CONTAINER_IMPACT

# Analyze container impact for selected volumes
analyze_container_impact() {
    local volumes="$1"
    log_info "Analyzing container impact for selected volumes..."
    
    # Clear the global arrays
    CONTAINER_IMPACT=()
    VOLUME_MOUNT_POINTS=()
    
    local has_running_containers=false
    local total_containers=0
    
    # Convert newline-separated list to array
    local -a volume_array
    while IFS= read -r volume; do
        if [[ -n "$volume" ]]; then
            volume_array+=("$volume")
        fi
    done <<< "$volumes"
    
    for volume in "${volume_array[@]}"; do
        volume=$(trim "$volume")
        [[ -z "$volume" ]] && continue
        
        log_info "Checking containers for volume: $volume"
        
        # Get containers using this volume
        local containers
        containers=$(get_containers_using_volume "$volume" || true)
        
        if [[ -z "$containers" ]]; then
            log_info "No containers found using volume: $volume"
            continue
        fi
        
        log_info "Found containers for volume $volume: $containers"
        
        # Process each container
        local volume_containers=()
        while IFS= read -r container_info; do
            [[ -z "$container_info" ]] && continue
            
            local container_name
            local container_status
            local mount_point
            
            # Split container info into name:status
            container_name="${container_info%%:*}"
            container_status="${container_info#*:}"
            
            log_info "Processing container: $container_name (status: $container_status)"
            
            # Get mount point for this volume in the container
            mount_point=$(get_volume_mount_points "$container_name" "$volume" 2>/dev/null) || mount_point="/data"
            
            # Store the mount point for this volume
            VOLUME_MOUNT_POINTS["$volume"]="$mount_point"
            
            # Add to container impact with volume name included
            volume_containers+=("$container_name:$container_status:$mount_point:$volume")
            
            # Check if container is running
            if [[ "$container_status" =~ ^Up ]]; then
                has_running_containers=true
            fi
            
            total_containers=$((total_containers + 1))
            
        done <<< "$containers"
        
        # Store container info for this volume
        if [[ ${#volume_containers[@]} -gt 0 ]]; then
            CONTAINER_IMPACT["$volume"]=$(IFS=','; echo "${volume_containers[*]}")
            log_info "Stored impact data for volume $volume: ${CONTAINER_IMPACT[$volume]}"
        fi
    done
    
    log_info "Container impact analysis complete. Total containers found: $total_containers"
    
    # Print a warning if running containers were found
    if [[ "$has_running_containers" == "true" ]]; then
        log_warning "WARNING: Running containers detected that are using volumes to be backed up"
    fi
    
    # Return summary: has_running_containers:total_containers
    echo "$has_running_containers:$total_containers"
}

# Display container impact information
display_container_impact() {
    local impact_summary="$1"
    local has_running="${impact_summary%%:*}"
    local total_containers="${impact_summary##*:}"
    
    echo >&2
    log_info "Container Impact Analysis"
    echo "=========================" >&2
    echo >&2
    
    # Check if we have any container impact data
    if [[ ${#CONTAINER_IMPACT[@]} -eq 0 ]]; then
        log_info "No containers are using the selected volumes."
        return 0
    fi
    
    # Additional check - if total_containers is 0 but we have CONTAINER_IMPACT data, something is wrong
    if [[ $total_containers -eq 0 ]]; then
        log_warning "Inconsistent data: CONTAINER_IMPACT has ${#CONTAINER_IMPACT[@]} entries but total_containers is 0. Using CONTAINER_IMPACT data."
    fi
    
    # Use the summary data instead of recounting to avoid inconsistency
    if [[ "$has_running" == "true" ]]; then
        log_warning "Found container(s) using the selected volumes (including running containers):"
    else
        log_info "Found container(s) using the selected volumes (all stopped):"
    fi
    
    local containers_found=0
    local running_containers_found=0
    local container_entries=()
    
    # First, collect all container info to properly count and deduplicate
    for volume in "${!CONTAINER_IMPACT[@]}"; do
        local container_info="${CONTAINER_IMPACT[$volume]}"
        [[ -z "$container_info" ]] && continue
        
        IFS=',' read -ra entries <<< "$container_info"
        for entry in "${entries[@]}"; do
            [[ -z "$entry" ]] && continue
            container_entries+=("$entry")
            
            # Check if this is a running container
            IFS=':' read -r -a parts <<< "$entry"
            if [[ ${#parts[@]} -ge 2 ]]; then
                local container_status="${parts[1]}"
                if [[ "$container_status" =~ ^Up ]]; then
                    running_containers_found=$((running_containers_found + 1))
                fi
            fi
        done
    done
    
    containers_found=${#container_entries[@]}
    
    if [[ $containers_found -eq 0 ]]; then
        log_info "No containers are using the selected volumes."
        return 0
    fi
    
    log_warning "Found $containers_found container(s) using the selected volumes:"
    echo >&2
    
    # Group containers by volume for display
    declare -A volume_map
    for entry in "${container_entries[@]}"; do
        IFS=':' read -r -a parts <<< "$entry"
        if [[ ${#parts[@]} -lt 3 ]]; then
            continue
        fi
        
        local container_name="${parts[0]}"
        local container_status="${parts[1]}"
        local mount_point="${parts[2]}"
        local volume_name="${parts[3]:-unknown_volume}"
        
        # Store container info under its volume
        if [[ -z "${volume_map[$volume_name]:-}" ]]; then
            volume_map["$volume_name"]="$container_name:$container_status:$mount_point"
        else
            volume_map["$volume_name"]="${volume_map[$volume_name]},$container_name:$container_status:$mount_point"
        fi
    done
    
    # Display the information grouped by volume
    for volume in "${!volume_map[@]}"; do
        echo -e "  ${BOLD}Volume: $volume${NC}" >&2
        
        IFS=',' read -ra container_entries <<< "${volume_map[$volume]}"
        for entry in "${container_entries[@]}"; do
            [[ -z "$entry" ]] && continue
            
            IFS=':' read -r -a parts <<< "$entry"
            if [[ ${#parts[@]} -lt 3 ]]; then
                continue
            fi
            
            local container_name="${parts[0]}"
            local container_status="${parts[1]}"
            local mount_point="${parts[2]}"
            
            # Color status based on container state
            local status_color="${YELLOW}"
            if [[ "$container_status" == "running"* || "$container_status" == "Up"* ]]; then
                status_color="${GREEN}"
            elif [[ "$container_status" == *"paused"* ]]; then
                status_color="${YELLOW}"
            elif [[ "$container_status" == *"exited"* || "$container_status" == *"dead"* ]]; then
                status_color="${RED}"
            fi
            
            printf "  • Container: %s (Status: %s%s%s, Mount: %s)\n" \
                "$container_name" "$status_color" "$container_status" "$NC" "$mount_point" >&2
        done
        echo >&2
    done
    
    # Use the summary data for consistent decision making
    if [[ "$has_running" == "true" ]]; then
        log_warning "Some containers are currently running and will need to be stopped for safe backup."
        return 1  # Indicate that containers need to be managed
    else
        log_info "All containers are already stopped."
        return 0
    fi
}

# Confirm container operations with user
confirm_container_operations() {
    local impact_summary="$1"
    local has_running="${impact_summary%%:*}"
    local total_containers="${impact_summary##*:}"
    
    # Check if we have any running containers in CONTAINER_IMPACT
    local running_containers_found=0
    local running_containers=()
    local container_map=()
    
    # First collect all running containers to avoid duplicates
    for volume in "${!CONTAINER_IMPACT[@]}"; do
        local container_info="${CONTAINER_IMPACT[$volume]}"
        [[ -z "$container_info" ]] && continue
        
        IFS=',' read -ra container_entries <<< "$container_info"
        for entry in "${container_entries[@]}"; do
            [[ -z "$entry" ]] && continue
            
            IFS=':' read -r -a parts <<< "$entry"
            if [[ ${#parts[@]} -lt 3 ]]; then
                continue
            fi
            
            local container_name="${parts[0]}"
            local container_status="${parts[1]}"
            local mount_point="${parts[2]}"
            
            # Only include running containers
            if [[ "$container_status" =~ ^Up ]]; then
                # Check if we've already seen this container
                local seen=0
                for ((i = 0; i < ${#container_map[@]}; i++)); do
                    if [[ "${container_map[i]%%:*}" == "$container_name" ]]; then
                        seen=1
                        break
                    fi
                done
                
                if [[ $seen -eq 0 ]]; then
                    container_map+=("$container_name:$container_status:$mount_point")
                    running_containers+=("$container_name")
                    running_containers_found=$((running_containers_found + 1))
                fi
            fi
        done
    done
    
    # If no running containers, just return success
    if [[ $running_containers_found -eq 0 ]]; then
        log_info "No running containers detected. Proceeding with backup."
        return 0
    fi
    
    # In non-interactive mode, check if we should proceed automatically
    if [[ "$INTERACTIVE" != "true" ]]; then
        if [[ "$AUTO_CONFIRM" == "true" ]]; then
            log_warning "Running containers detected in non-interactive mode with auto-confirm. Containers will be stopped."
            return 0
        else
            log_warning "Running containers detected but running in non-interactive mode without auto-confirm. Containers will not be stopped."
            log_warning "Use --interactive or --auto-confirm to enable container management."
            return 1
        fi
    fi
    
    # In dry-run mode, just log what would happen
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would prompt to stop running containers"
        return 0
    fi
    
    echo >&2
    log_warning "WARNING: The following containers are currently running and will be stopped:"
    echo >&2
    
    # Display the running containers
    for container_info in "${container_map[@]}"; do
        IFS=':' read -r -a parts <<< "$container_info"
        local container_name="${parts[0]}"
        local container_status="${parts[1]}"
        local mount_point="${parts[2]}"
        
        printf "  • %-30s (Status: %s, Mount: %s)\\n" \
            "$container_name" "$container_status" "$mount_point" >&2
    done
    
    echo >&2
    log_warning "Stopping these containers is required for a consistent backup."
    log_warning "The containers will be automatically restarted after the backup completes."
    
    # If auto-confirm is enabled, don't prompt
    if [[ "$AUTO_CONFIRM" == "true" ]]; then
        log_info "Auto-confirm is enabled. Containers will be stopped automatically."
        return 0
    fi
    
    # Interactive prompt
    while true; do
        echo >&2
        read -r -p "Do you want to stop these containers and continue with the backup? [y/N] " response
        case "${response,,}" in
            y|yes)
                log_info "User confirmed to stop containers and continue with backup"
                return 0
                ;;
            n|no|''|*)
                log_info "Backup cancelled by user"
                exit 1
                ;;
        esac
    done
}

# Stop containers safely
stop_containers_safely() {
    local volumes="$1"
    
    # Initialize array to track stopped containers if not already done
    if [[ -z "${STOPPED_CONTAINERS:-}" ]]; then
        declare -g -a STOPPED_CONTAINERS=()
    else
        # Clear any existing stopped containers to avoid duplicates
        STOPPED_CONTAINERS=()
    fi
    
    local stop_errors=()
    local containers_to_stop=()
    
    log_info "Stopping containers that use the selected volumes..."
    
    # Convert volumes string to array for processing
    local -a volume_array
    while IFS= read -r volume; do
        if [[ -n "$volume" ]]; then
            volume_array+=("$volume")
        fi
    done <<< "$volumes"
    
    # Process each volume
    for volume in "${volume_array[@]}"; do
        [[ -z "$volume" ]] && continue
        
        # Get container info for this volume
        local container_info="${CONTAINER_IMPACT[$volume]:-}"
        [[ -z "$container_info" ]] && continue
        
        # Process each container for this volume
        IFS=',' read -ra container_entries <<< "$container_info"
        for entry in "${container_entries[@]}"; do
            [[ -z "$entry" ]] && continue
            
            # Extract container name and status
            IFS=':' read -r -a parts <<< "$entry"
            [[ ${#parts[@]} -lt 2 ]] && continue
            
            local container_name="${parts[0]}"
            local container_status="${parts[1]}"
            
            # Only process running containers
            if [[ "$container_status" =~ ^Up ]]; then
                # Check if we've already processed this container
                local already_added=false
                for existing in "${containers_to_stop[@]}"; do
                    if [[ "$existing" == "$container_name" ]]; then
                        already_added=true
                        break
                    fi
                done
                
                if [[ "$already_added" == "false" ]]; then
                    containers_to_stop+=("$container_name")
                fi
            fi
        done
    done
    
    # Check if we have any containers to stop
    if [[ ${#containers_to_stop[@]} -eq 0 ]]; then
        log_info "No running containers need to be stopped."
        return 0
    fi
    
    # Stop each container that needs to be stopped
    for container_name in "${containers_to_stop[@]}"; do
        log_info "Stopping container: $container_name"
        
        local ssh_cmd
        ssh_cmd=$(build_ssh_cmd)
        
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would stop container: $container_name"
            STOPPED_CONTAINERS+=("$container_name")
            continue
        fi
        
        # Try graceful stop first
        if eval "$ssh_cmd \"$REMOTE_USER@$REMOTE_HOST\" 'docker stop --time=$CONTAINER_STOP_TIMEOUT $container_name'" &>/dev/null; then
            log_success "Container $container_name stopped gracefully"
            STOPPED_CONTAINERS+=("$container_name")
        elif [[ "$FORCE_STOP" == "true" ]]; then
            log_warning "Graceful stop failed, force stopping container: $container_name"
            if eval "$ssh_cmd \"$REMOTE_USER@$REMOTE_HOST\" 'docker kill $container_name'" &>/dev/null; then
                log_success "Container $container_name force stopped"
                STOPPED_CONTAINERS+=("$container_name")
            else
                log_error "Failed to force stop container: $container_name"
                stop_errors+=("$container_name")
            fi
        else
            log_error "Failed to stop container: $container_name (use --force-stop to force)"
            stop_errors+=("$container_name")
        fi
    done
    
    # Handle any errors that occurred during container stopping
    if [[ ${#stop_errors[@]} -gt 0 ]]; then
        log_error "Failed to stop some containers: ${stop_errors[*]}"
        
        if [[ "$INTERACTIVE" == "true" ]]; then
            echo >&2
            echo -n "Continue with backup anyway? (y/N): " >&2
            read -r CONTINUE
            if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
                log_info "Backup cancelled due to container stop failures."
                exit 1
            fi
        else
            log_warning "Continuing with backup despite container stop failures (non-interactive mode)"
        fi
    fi
    
    # Log summary of stopped containers
    if [[ ${#STOPPED_CONTAINERS[@]} -gt 0 ]]; then
        log_success "Stopped ${#STOPPED_CONTAINERS[@]} container(s): ${STOPPED_CONTAINERS[*]}"
    else
        log_info "No containers needed to be stopped."
    fi
}

restart_stopped_containers() {
    # Check if we should restart containers
    if [[ "$AUTO_RESTART_CONTAINERS" != "true" ]]; then
        log_info "Auto-restart of containers is disabled (--no-auto-restart)"
        return 0
    fi
    
    # Check if there are any containers to restart
    if [[ -z "${STOPPED_CONTAINERS:-}" ]] || [[ ${#STOPPED_CONTAINERS[@]} -eq 0 ]]; then
        log_info "No containers to restart"
        return 0
    fi
    
    log_info "Restarting ${#STOPPED_CONTAINERS[@]} stopped container(s)..."
    
    local restart_errors=()
    local ssh_cmd
    ssh_cmd=$(build_ssh_cmd)
    
    # Make a copy of the array to avoid issues with modifying it during iteration
    local containers_to_restart=("${STOPPED_CONTAINERS[@]}")
    local restart_success=0
    
    # Sort containers to restart in reverse order (LIFO)
    # This is often useful for dependencies between containers
    local sorted_containers=()
    for container in "${containers_to_restart[@]}"; do
        sorted_containers=("$container" "${sorted_containers[@]}")
    done
    
    for container in "${sorted_containers[@]}"; do
        if [[ -z "$container" ]]; then
            continue
        fi
        
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would restart container: $container"
            restart_success=$((restart_success + 1))
            continue
        fi
        
        log_info "Restarting container: $container"
        
        # Try to start the container
        if eval "$ssh_cmd \"$REMOTE_USER@$REMOTE_HOST\" 'docker start $container'" &>/dev/null; then
            # Verify the container is actually running
            local status
            status=$(eval "$ssh_cmd \"$REMOTE_USER@$REMOTE_HOST\" 'docker inspect -f \"{{.State.Status}}\" $container 2>/dev/null'" 2>/dev/null || true)
            
            if [[ "$status" == "running" ]]; then
                log_success "Successfully restarted container: $container"
                restart_success=$((restart_success + 1))
                
                # Remove from STOPPED_CONTAINERS array
                for i in "${!STOPPED_CONTAINERS[@]}"; do
                    if [[ "${STOPPED_CONTAINERS[i]}" == "$container" ]]; then
                        unset 'STOPPED_CONTAINERS[i]'
                        break
                    fi
                done
            else
                log_error "Container $container did not start successfully (status: ${status:-unknown})"
                restart_errors+=("$container")
            fi
        else
            log_error "Failed to restart container: $container"
            restart_errors+=("$container")
        fi
        
        # Small delay between restarts to avoid overwhelming the Docker daemon
        sleep 1
    done
    
    # Rebuild the array to remove gaps from unset
    STOPPED_CONTAINERS=("${STOPPED_CONTAINERS[@]}")
    
    # Log summary
    if [[ $restart_success -gt 0 ]]; then
        log_success "Successfully restarted $restart_success container(s)"
    fi
    
    if [[ ${#restart_errors[@]} -gt 0 ]]; then
        log_error "Failed to restart ${#restart_errors[@]} container(s): ${restart_errors[*]}"
        return 1
    fi
    
    return 0
}

# Create backup archive using busybox container
create_remote_backup_archive() {
    local volume="$1"
    local container="$2"
    local mount_path="$3"
    local timestamp=$(date +"%Y%m%d_%H%M%S")
    local ssh_cmd
    ssh_cmd=$(build_ssh_cmd)
    
    # Create remote temp directory
    local remote_temp_file="$TEMP_BACKUP_DIR/${volume}_${container}_${timestamp}.tar.gz"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "Would create backup archive: $remote_temp_file"
        echo "$remote_temp_file"
        return 0
    fi
    
    # Ensure remote temp directory exists
    eval "$ssh_cmd \"$REMOTE_USER@$REMOTE_HOST\" 'mkdir -p $TEMP_BACKUP_DIR'" &>/dev/null
    
    # Create backup using busybox
    local docker_cmd
    if [[ "$container" == "direct-backup" ]]; then
        # Direct volume mount method (when no containers are using the volume)
        log_info "Creating backup archive for volume $volume using direct mount (mount: $mount_path)"
        docker_cmd="docker run --rm -v $volume:$mount_path -v $TEMP_BACKUP_DIR:/backup busybox tar czf /backup/$(basename "$remote_temp_file") -C $mount_path ."
    else
        # Existing container method (when containers are using the volume)
        log_info "Creating backup archive for volume $volume from container $container (mount: $mount_path)"
        docker_cmd="docker run --rm --volumes-from $container -v $TEMP_BACKUP_DIR:/backup busybox tar czf /backup/$(basename "$remote_temp_file") -C / $mount_path"
    fi
    
    if [[ "$VERBOSE" == "true" ]]; then
        log_info "Executing: $docker_cmd"
    fi
    
    if eval "$ssh_cmd \"$REMOTE_USER@$REMOTE_HOST\" '$docker_cmd'" &>/dev/null; then
        log_success "Backup archive created: $remote_temp_file"
        echo "$remote_temp_file"
        return 0
    else
        log_error "Failed to create backup archive for volume $volume"
        return 1
    fi
}

# Download backup with progress
download_backup_with_progress() {
    local remote_file="$1"
    local local_dest="$2"
    local ssh_cmd
    ssh_cmd=$(build_rsync_ssh)
    
    # Build rsync command with progress
    local rsync_args=()
    rsync_args+=("-a")  # archive mode
    rsync_args+=("-e" "$ssh_cmd")
    
    # Add compression if enabled
    if [[ "$COMPRESS" == "true" ]]; then
        rsync_args+=("-z")
    fi
    
    # Add progress indicators if enabled
    if [[ "$SHOW_PROGRESS" == "true" ]]; then
        rsync_args+=("--progress" "--stats")
    fi
    
    # Add verbose flag if enabled
    if [[ "$VERBOSE" == "true" ]]; then
        rsync_args+=("-v")
    fi
    
    # Add dry-run flag if enabled
    if [[ "$DRY_RUN" == "true" ]]; then
        rsync_args+=("-n")
    fi
    
    local source="$REMOTE_USER@$REMOTE_HOST:$remote_file"
    
    if [[ "$VERBOSE" == "true" ]]; then
        log_info "Downloading: rsync ${rsync_args[*]} '$source' '$local_dest'"
    fi
    
    # Execute rsync with progress
    if rsync "${rsync_args[@]}" "$source" "$local_dest"; then
        if [[ "$DRY_RUN" != "true" ]]; then
            log_success "Downloaded backup: $(basename "$remote_file")"
        else
            log_info "Dry run download completed: $(basename "$remote_file")"
        fi
        return 0
    else
        log_error "Failed to download backup: $(basename "$remote_file")"
        return 1
    fi
}

# Backup volume using busybox method (with fallback for volumes without containers)
backup_volume_with_busybox() {
    local volume="$1"
    local timestamp=$(date +"%Y%m%d_%H%M%S")
    local backup_dir="$LOCAL_BACKUP_DIR/$volume"
    local latest_link="$LOCAL_BACKUP_DIR/$volume/latest"
    local current_backup="$backup_dir/$timestamp"

    log_info "Backing up volume: $volume"

    # Create backup directory structure
    mkdir -p "$current_backup"

    # Detect container using the volume
    local containers
    containers=$(get_containers_using_volume "$volume")
    local container_name=""
    local mount_path="/data"
    local container_was_stopped=false

    if [[ -n "$containers" ]]; then
        # Pick the first container
        container_name=$(echo "$containers" | head -n 1 | cut -d: -f1)
        
        # Check if this container was already stopped by stop_containers_safely
        for stopped_container in "${STOPPED_CONTAINERS[@]}"; do
            if [[ "$stopped_container" == "$container_name" ]]; then
                container_was_stopped=true
                break
            fi
        done
        
        # If container is running and wasn't stopped by stop_containers_safely, we need to stop it
        if [[ "$container_was_stopped" == "false" ]]; then
            local container_status
            container_status=$(docker inspect -f '{{.State.Status}}' "$container_name" 2>/dev/null || true)
            
            if [[ "$container_status" == "running" ]]; then
                log_warning "Container $container_name is running but wasn't stopped by stop_containers_safely. Stopping it now..."
                if ! docker stop --time="$CONTAINER_STOP_TIMEOUT" "$container_name" >/dev/null; then
                    if [[ "$FORCE_STOP" == "true" ]]; then
                        if ! docker kill "$container_name" >/dev/null; then
                            log_error "Failed to force stop container: $container_name"
                            return 1
                        fi
                    else
                        log_error "Failed to stop container: $container_name (use --force-stop to force)"
                        return 1
                    fi
                fi
                STOPPED_CONTAINERS+=("$container_name")
                container_was_stopped=true
            fi
        fi

        # Try to get the actual mount path
        local found_mount
        found_mount=$(get_volume_mount_points "$container_name" "$volume")
        if [[ -n "$found_mount" ]]; then
            mount_path="$found_mount"
        fi
    else
        log_info "No containers found using volume $volume. Using direct volume backup method."
        container_name="direct-backup"
        mount_path="/volume_data"
    fi

    # DRY RUN: Only print what would be done, do not perform any actions
    if [[ "$DRY_RUN" == "true" ]]; then
        local remote_archive="$TEMP_BACKUP_DIR/${volume}_${container_name}_${timestamp}.tar.gz"
        echo "--- DRY RUN ---"
        echo "Would backup volume: $volume"
        echo "  Using container: $container_name"
        echo "  Mount path: $mount_path"
        echo "  Would create remote archive: $remote_archive"
        echo "----------------"
        return 0
    fi

    log_info "Starting backup process for volume: $volume"
    # Create backup archive
    local remote_archive
    remote_archive=$(create_remote_backup_archive "$volume" "$container_name" "$mount_path")

    if [[ $? -eq 0 && -n "$remote_archive" ]]; then
        # Download backup file
        local local_file="$current_backup/$(basename "$remote_archive")"
        if download_backup_with_progress "$remote_archive" "$local_file"; then
            if [[ "$DRY_RUN" != "true" ]]; then
                # Update latest symlink
                rm -f "$latest_link"
                ln -sf "$timestamp" "$latest_link"
                log_success "Volume $volume backed up successfully"
            else
                log_info "Dry run completed for volume $volume"
            fi
            return 0
        else
            log_error "Failed to download backup for volume $volume"
            return 1
        fi
    else
        log_error "Failed to create backup for volume $volume"
        return 1
    fi
}


# Main backup function that chooses method
backup_volume() {
    local volume="$1"
    
    # Create backup directory structure
    local timestamp=$(date +"%Y%m%d_%H%M%S")
    local backup_dir="$LOCAL_BACKUP_DIR/$volume"
    local latest_link="$LOCAL_BACKUP_DIR/$volume/latest"
    local current_backup="$backup_dir/$timestamp"
    
    # Create backup directory
    mkdir -p "$current_backup"
    
    # Call the busybox backup method
    backup_volume_with_busybox "$volume"
}

# Cleanup remote temporary files
cleanup_remote_temp_files() {
    # Check if BACKUP_FILES is set and has elements
    if [[ -z "${BACKUP_FILES:-}" ]] || [[ ${#BACKUP_FILES[@]} -eq 0 ]]; then
        return 0
    fi
    
    log_info "Cleaning up remote temporary files..."
    
    local ssh_cmd
    ssh_cmd=$(build_ssh_cmd)
    
    for key in "${!BACKUP_FILES[@]}"; do
        local remote_file="${BACKUP_FILES[$key]}"
        if [[ -n "$remote_file" && "$DRY_RUN" != "true" ]]; then
            if [[ "$VERBOSE" == "true" ]]; then
                log_info "Removing remote file: $remote_file"
            fi
            eval "$ssh_cmd \"$REMOTE_USER@$REMOTE_HOST\" 'rm -f $remote_file'" &>/dev/null || true
        fi
    done
    
    # Remove temp directory if empty
    if [[ "$DRY_RUN" != "true" ]]; then
        eval "$ssh_cmd \"$REMOTE_USER@$REMOTE_HOST\" 'rmdir $TEMP_BACKUP_DIR 2>/dev/null || true'" &>/dev/null || true
    fi
}

# Clean up old backups
cleanup_old_backups() {
    local volume="$1"
    local backup_dir="$LOCAL_BACKUP_DIR/$volume"
    
    if [[ ! -d "$backup_dir" ]]; then
        return 0
    fi
    
    log_info "Cleaning up old backups for volume $volume (keeping $KEEP_BACKUPS most recent)"
    
    # Find backup directories (timestamp format: YYYYMMDD_HHMMSS)
    local backup_dirs
    backup_dirs=$(find "$backup_dir" -maxdepth 1 -type d -name "20[0-9][0-9][0-1][0-9][0-3][0-9]_[0-2][0-9][0-5][0-9][0-5][0-9]" | sort -r)
    
    local count=0
    while IFS= read -r backup_path; do
        if [[ -n "$backup_path" ]]; then
            count=$((count + 1))
            if [[ $count -gt $KEEP_BACKUPS ]]; then
                if [[ "$DRY_RUN" == "true" ]]; then
                    log_info "Would remove: $(basename "$backup_path")"
                else
                    log_info "Removing old backup: $(basename "$backup_path")"
                    rm -rf "$backup_path"
                fi
            fi
        fi
    done <<< "$backup_dirs"
}

# Interactive volume selection
select_volumes_interactively() {
    local all_volumes="$1"
    local selected_volumes=""
    
    if [[ -z "$all_volumes" ]]; then
        log_error "No volumes available for selection"
        return 1
    fi
    
    # Convert volumes to array for easier handling
    local volume_array=()
    while IFS= read -r volume; do
        if [[ -n "$volume" ]]; then
            volume_array+=("$volume")
        fi
    done <<< "$all_volumes"
    
    
    if [[ ${#volume_array[@]} -eq 0 ]]; then
        log_error "No volumes available for selection"
        return 1
    fi
    
    echo >&2
    log_info "Interactive Volume Selection"
    echo "=============================" >&2
    echo >&2
    echo "Available Docker volumes:" >&2
    echo >&2
    
    # Display volumes with numbers and exclusion status
    for i in "${!volume_array[@]}"; do
        local volume="${volume_array[$i]}"
        local status=""
        if is_excluded "$volume"; then
            status=" ${YELLOW}(excluded by config)${NC}"
        fi
        printf "%2d) %s%s\n" $((i+1)) "$volume" "$status" >&2
    done
    
    echo >&2
    echo "Selection options:" >&2
    echo "  • Enter volume numbers separated by spaces (e.g., 1 3 5)" >&2
    echo "  • Enter 'all' to select all non-excluded volumes" >&2
    echo "  • Enter 'q' to quit" >&2
    echo >&2
    
    # Function to validate selection
    validate_selection() {
        local selection="$1"
        local temp_selected=()
        
        if [[ "$selection" == "all" ]]; then
            for volume in "${volume_array[@]}"; do
                if ! is_excluded "$volume"; then
                    temp_selected+=("$volume")
                fi
            done
            if [[ ${#temp_selected[@]} -eq 0 ]]; then
                log_error "No volumes available (all are excluded)"
                return 1
            fi
            selected_volumes=$(printf "%s\n" "${temp_selected[@]}")
            return 0
        elif [[ "$selection" == "q" ]]; then
            log_info "Volume selection cancelled."
            exit 0
        fi
        
        # Parse individual numbers
        for num in $selection; do
            if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "${#volume_array[@]}" ]; then
                local volume="${volume_array[$((num-1))]}"
                if is_excluded "$volume"; then
                    log_warning "Volume $volume is excluded by configuration, skipping"
                else
                    temp_selected+=("$volume")
                fi
            else
                log_error "Invalid selection: $num"
                return 1
            fi
        done
        
        if [ ${#temp_selected[@]} -eq 0 ]; then
            log_error "No valid volumes selected."
            return 1
        fi
        
        # Remove duplicates
        selected_volumes=$(printf "%s\n" "${temp_selected[@]}" | sort -u)
        return 0
    }
    
    # Get user selection
    while true; do
        echo -n "Your selection: " >&2
        read -r USER_SELECTION
        
        if validate_selection "$USER_SELECTION"; then
            break
        else
            echo "Please try again." >&2
            echo >&2
        fi
    done
    
    echo >&2
    log_info "Selected volumes for backup:"
    while IFS= read -r volume; do
        if [[ -n "$volume" ]]; then
            echo "  • $volume" >&2
        fi
    done <<< "$selected_volumes"
    
    echo >&2
    echo -n "Proceed with backup? (y/N): " >&2
    read -r CONFIRM
    
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        log_info "Backup cancelled."
        exit 0
    fi
    
    # Return selected volumes to stdout (not stderr)
    printf "%s\n" "$selected_volumes"
}

# Main function
main() {
    parse_args "$@"
    
    # Show configuration if verbose
    if [[ "$VERBOSE" == "true" ]]; then
        log_info "Configuration:"
        log_info "  Remote Host: $REMOTE_HOST"
        log_info "  Remote User: $REMOTE_USER"
        log_info "  SSH Key: ${SSH_KEY:-"(default)"}"
        log_info "  Local Backup Dir: $LOCAL_BACKUP_DIR"
        log_info "  Exclude Volumes: ${EXCLUDE_VOLUMES:-"(none)"}"
        log_info "  Interactive Mode: $INTERACTIVE"
        log_info "  Dry Run: $DRY_RUN"
        log_info "  Compress: $COMPRESS"
        log_info "  Keep Backups: $KEEP_BACKUPS"
        log_info "  Auto-detect Docker Root: $AUTO_DETECT_DOCKER_ROOT"
        log_info "  Check All Contexts: $CHECK_ALL_CONTEXTS"
        log_info "  Include System Docker: $INCLUDE_SYSTEM_DOCKER"
        echo >&2
        log_info "Container-Aware Settings:"
        log_info "  Container Stop Timeout: ${CONTAINER_STOP_TIMEOUT}s"
        log_info "  Auto Restart Containers: $AUTO_RESTART_CONTAINERS"
        log_info "  Show Progress: $SHOW_PROGRESS"
        log_info "  Force Stop: $FORCE_STOP"
        log_info "  Temp Backup Dir: $TEMP_BACKUP_DIR"
    fi
    
    validate_config
    
    # Create backup directory
    mkdir -p "$LOCAL_BACKUP_DIR"
    
    # Get list of volumes
    local all_volumes
    all_volumes=$(get_remote_volumes)
    
    if [[ -z "$all_volumes" ]]; then
        log_warning "No Docker volumes found on remote host"
        exit 0
    fi
    
    local volume_count
    volume_count=$(echo "$all_volumes" | wc -l)
    log_info "Found $volume_count Docker volumes"
    
    # Determine which volumes to backup
    local volumes_to_backup
    if [[ "$INTERACTIVE" == "true" ]]; then
        volumes_to_backup=$(select_volumes_interactively "$all_volumes")
    else
        volumes_to_backup="$all_volumes"
        
        if [[ "$VERBOSE" == "true" ]]; then
            log_info "Volumes found:"
            echo "$all_volumes" | while read -r vol; do
                if [[ -n "$vol" ]]; then
                    if is_excluded "$vol"; then
                        echo "  - $vol (excluded)"
                    else
                        echo "  - $vol"
                    fi
                fi
            done
        fi
    fi
    
    # Filter out excluded volumes for non-interactive mode
    filtered_volumes=""
    while IFS= read -r volume; do
        if [[ -n "$volume" ]]; then
            if [[ "$INTERACTIVE" != "true" ]] && is_excluded "$volume"; then
                log_warning "Skipping excluded volume: $volume"
                continue
            fi
            # Always add as newline-separated
            filtered_volumes+="$volume\n"
        fi
    done <<< "$volumes_to_backup"
    # Remove trailing newline
    filtered_volumes=$(echo -e "$filtered_volumes" | grep -v '^$')
    if [[ -z "$filtered_volumes" ]]; then
        log_warning "No volumes to backup after filtering"
        exit 0
    fi
    
    # Analyze container impact for selected volumes
    # Note: We call analyze_container_impact directly (not in a subshell) 
    # so that the CONTAINER_IMPACT array is populated in the current shell
    analyze_container_impact "$filtered_volumes" > /tmp/impact_summary.tmp
    local impact_summary=$(cat /tmp/impact_summary.tmp)
    rm -f /tmp/impact_summary.tmp
    local has_running_containers="${impact_summary%%:*}"
    local total_containers="${impact_summary##*:}"
    
    # Debug output
    if [[ "$VERBOSE" == "true" ]]; then
        log_info "DEBUG: impact_summary='$impact_summary'"
        log_info "DEBUG: has_running_containers='$has_running_containers'"
        log_info "DEBUG: total_containers='$total_containers'"
        log_info "DEBUG: CONTAINER_IMPACT has ${#CONTAINER_IMPACT[@]} entries"
    fi
    
    # Show container impact to user
    local containers_need_management=false
    if display_container_impact "$impact_summary"; then
        # display_container_impact returns 0 if no containers need management
        log_info "No container management needed. Proceeding with backup."
    else
        # display_container_impact returns 1 if containers need to be managed
        containers_need_management=true
        
        # Ask for confirmation (or auto-confirm if set)
        if ! confirm_container_operations "$impact_summary"; then
            log_error "Container operations were not confirmed. Exiting."
            exit 1
        fi
        
        # Stop the containers
        log_info "Stopping running containers..."
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would stop running containers"
        else
            if ! stop_containers_safely "$filtered_volumes"; then
                log_error "Failed to stop some containers. Check logs for details."
                exit 1
            fi
            
            # Set a flag to restart containers after backup
            CONTAINERS_NEED_RESTART=true
        fi
    fi

    # DRY RUN: Print simulation summary and exit
    if [[ "$DRY_RUN" == "true" ]]; then
        echo
        echo "[DEBUG] filtered_volumes: [$filtered_volumes]"
        echo "[DEBUG] CONTAINER_IMPACT keys: ${!CONTAINER_IMPACT[@]}"
        for k in "${!CONTAINER_IMPACT[@]}"; do echo "  $k -> ${CONTAINER_IMPACT[$k]}"; done
        echo "====== DRY RUN SUMMARY ======"
        echo "Volumes that would be backed up:"
        local idx=1
        # Ensure filtered_volumes is newline-separated and not empty
        filtered_volumes=$(echo -e "$filtered_volumes" | grep -v '^$')
        for volume in $filtered_volumes; do
            if [[ -n "$volume" ]]; then
                echo "  $idx) $volume"
                idx=$((idx+1))
            fi
        done
        echo
        echo "Containers that would be stopped (if any):"
        for volume in $filtered_volumes; do
            containers="${CONTAINER_IMPACT[$volume]:-}"
            if [[ -n "$containers" ]]; then
                IFS=',' read -ra container_arr <<< "$containers"
                for entry in "${container_arr[@]}"; do
                    cname=$(echo "$entry" | cut -d: -f1)
                    cstatus=$(echo "$entry" | cut -d: -f2)
                    if [[ "$cstatus" =~ ^Up ]]; then
                        echo "  $cname (would be stopped before backup, started after)"
                    fi
                done
            fi
        done
        echo
        echo "Backup files that would be created:"
        idx=1
        for volume in $filtered_volumes; do
            if [[ -n "$volume" ]]; then
                containers="${CONTAINER_IMPACT[$volume]:-}"
                cname=""
                if [[ -n "$containers" ]]; then
                    # Use the first container name if available, otherwise empty
                    cname=$(echo "$containers" | awk -F, '{print $1}' | cut -d: -f1)
                fi
                ts="SIMULATED_TIMESTAMP"
                archive="$TEMP_BACKUP_DIR/${volume}_${cname}_${ts}.tar.gz"
                echo "  $idx) $archive"
                idx=$((idx+1))
            fi
        done
        echo "=============================="
        exit 0
    fi

    # Backup each volume
    local success_count=0
    local processed_count=0
    local backup_start_time=$(date +%s)
    local total_volumes
    
    # Convert filtered_volumes to an array to handle spaces in volume names
    local -a volumes_array
    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            volumes_array+=("$line")
        fi
    done <<< "$filtered_volumes"
    
    total_volumes=${#volumes_array[@]}
    
    log_info "Starting backup process..."

    for volume in "${volumes_array[@]}"; do
        if [[ -n "$volume" ]]; then
            processed_count=$((processed_count + 1))
            log_info "Processing volume $processed_count of $total_volumes: $volume"

            if backup_volume "$volume"; then
                success_count=$((success_count + 1))

                # Cleanup old backups if not in dry-run mode
                if [[ "$DRY_RUN" != "true" && "$KEEP_BACKUPS" -gt 0 ]]; then
                    cleanup_old_backups "$volume"
                fi
            fi
        fi
    done

    # Cleanup remote temporary files
    cleanup_remote_temp_files

    # Restart containers if they were stopped
    restart_stopped_containers

    # Calculate backup duration
    local backup_end_time=$(date +%s)
    local backup_duration=$((backup_end_time - backup_start_time))
    local duration_formatted
    if [[ $backup_duration -ge 60 ]]; then
        duration_formatted="$((backup_duration / 60))m $((backup_duration % 60))s"
    else
        duration_formatted="${backup_duration}s"
    fi

    # Summary
    echo >&2
    log_info "Backup Summary"
    log_info "=============="
    log_info "Duration: $duration_formatted"
    log_info "Volumes processed: $success_count/$processed_count"
    log_info "Backup method: $BACKUP_METHOD"

    if [[ -n "${STOPPED_CONTAINERS:-}" ]] && [[ ${#STOPPED_CONTAINERS[@]} -gt 0 ]]; then
        log_info "Containers managed: ${#STOPPED_CONTAINERS[@]}"
    fi

    if [[ $success_count -eq $processed_count ]] && [[ $processed_count -gt 0 ]]; then
        log_success "All volumes backed up successfully!"
        exit 0
    elif [[ $processed_count -eq 0 ]]; then
        log_warning "No volumes were processed (all excluded or none found)"
        exit 0
    else
        log_error "Some volumes failed to backup ($((processed_count - success_count)) failed)"
        exit 1
    fi
}

# Cleanup function for graceful exit
cleanup_on_exit() {
    local exit_code=$?
    
    # Clean up temporary files if they exist
    if [[ -n "${TEMP_FILES[@]}" ]]; then
        cleanup_remote_temp_files
    fi
    
    # Restart containers if they were stopped and auto-restart is enabled
    if [[ -n "${STOPPED_CONTAINERS:-}" && ${#STOPPED_CONTAINERS[@]} -gt 0 && "$AUTO_RESTART_CONTAINERS" == "true" ]]; then
        log_info "Attempting to restart stopped containers due to interruption..."
        restart_stopped_containers
    fi
    
    exit $exit_code
}

# Handle Ctrl+C and other signals gracefully
trap 'cleanup_on_exit' INT TERM EXIT

# Run main function with all arguments
main "$@"