#!/bin/bash
# This script automatically generates an Ansible inventory file based on Tailscale status or API calls
# It prompts the user to select parent-child relationships and tags to group hosts
# It can also generate an inventory based on API calls

declare -A parent_children
declare -a parents
declare -a available_tags
declare -a used_hosts=()
declare -A hostname_counts

CONFIG_FILE="$HOME/.config/ansiscale/confansiscale.cfg"

# Load configuration
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    else
        echo "Config file not found. Creating with default values..."
        create_default_config
    fi
}

# Create default config file
create_default_config() {
    mkdir -p "$(dirname "$CONFIG_FILE")"
    cat > "$CONFIG_FILE" << EOL
API_KEY=''
TAILNET_ORG=''
CONNECT_TIMEOUT=10
MAX_TIME=30
RETRY=3
RETRY_DELAY=5
RETRY_MAX_TIME=60
DEBUG_MODE=false
MATCH_BY=name
EOL
    chmod 600 "$CONFIG_FILE"  # Secure the config file
}

# Save configuration
save_config() {
    cat > "$CONFIG_FILE" << EOL
API_KEY='${API_KEY}'
TAILNET_ORG='${TAILNET_ORG}'
CONNECT_TIMEOUT=${CONNECT_TIMEOUT}
MAX_TIME=${MAX_TIME}
RETRY=${RETRY}
RETRY_DELAY=${RETRY_DELAY}
RETRY_MAX_TIME=${RETRY_MAX_TIME}
DEBUG_MODE=${DEBUG_MODE}
MATCH_BY=${MATCH_BY}
EOL
}

# Add validate_api_key function
validate_api_key() {
    local key=$1
    if [[ ${#key} -eq 61 && $key =~ ^tskey-api-[a-zA-Z0-9-]+$ ]]; then
        echo -e "\033[1;32m(Valid API key)\033[0m"
        return 0
    else
        echo -e "\033[1;31m(Invalid API key)\033[0m"
        return 1
    fi
}

# Add first_run_setup function
first_run_setup() {
    clear
    echo -e "\033[1;34mFirst Time Setup\033[0m"
    echo -e "\033[1;34m---------------\033[0m"
    echo -e "\033[1;33mPlease visit: https://login.tailscale.com/admin/settings/general\033[0m"
    echo -e "\033[1;33mto find your API key and organization name.\033[0m"
    echo
    
    while true; do
        read -p "Enter API Key: " new_key
        if validate_api_key "$new_key"; then
            API_KEY="$new_key"
            break
        else
            echo -e "\033[1;33mAPI keys should be 61 characters long and start with 'ts'\033[0m"
            if ! get_yes_no "Try again?"; then
                exit 1
            fi
        fi
    done
    
    read -p "Enter Tailnet Organization: " TAILNET_ORG
    
    # Set default values for other settings
    CONNECT_TIMEOUT=10
    MAX_TIME=30
    RETRY=3
    RETRY_DELAY=5
    RETRY_MAX_TIME=60
    DEBUG_MODE=false
    MATCH_BY=name
    
    save_config
    echo -e "\033[1;32mConfiguration saved successfully!\033[0m"
    sleep 2
}

# Settings menu
settings_menu() {
    while true; do
        clear
        echo -e "\033[1;35mSettings Menu\033[0m"
        echo -e "\033[1;35m-------------\033[0m"
        echo -e "\033[1;36m1. Set API Key (current: ${API_KEY:0:10}...)\033[0m"
        echo -e "\033[1;36m2. Set Tailnet Organization (current: $TAILNET_ORG)\033[0m"
        echo -e "\033[1;36m3. Set Connection Timeout (current: $CONNECT_TIMEOUT)\033[0m"
        echo -e "\033[1;36m4. Set Max Time (current: $MAX_TIME)\033[0m"
        echo -e "\033[1;36m5. Set Retry Count (current: $RETRY)\033[0m"
        echo -e "\033[1;36m6. Set Retry Delay (current: $RETRY_DELAY)\033[0m"
        echo -e "\033[1;36m7. Set Retry Max Time (current: $RETRY_MAX_TIME)\033[0m"
        echo -e "\033[1;36m8. Toggle Debug Mode (current: $DEBUG_MODE)\033[0m"
        echo -e "\033[1;31m9. Back to Main Menu\033[0m"
        
        read -p $'\033[1;33mSelect an option: \033[0m' choice
        
        case $choice in
            1) 
                while true; do
                    read -p "Enter API Key: " new_key
                    if validate_api_key "$new_key"; then
                        API_KEY="$new_key"
                        break
                    else
                        echo -e "\033[1;33mAPI keys should be 61 characters long and start with 'ts'\033[0m"
                        if get_yes_no "Try again?"; then
                            continue
                        else
                            break
                        fi
                    fi
                done
                ;;
            2) read -p "Enter Tailnet Organization: " TAILNET_ORG ;;
            3) read -p "Enter Connection Timeout: " CONNECT_TIMEOUT ;;
            4) read -p "Enter Max Time: " MAX_TIME ;;
            5) read -p "Enter Retry Count: " RETRY ;;
            6) read -p "Enter Retry Delay: " RETRY_DELAY ;;
            7) read -p "Enter Retry Max Time: " RETRY_MAX_TIME ;;
            8) DEBUG_MODE=$([ "$DEBUG_MODE" = "true" ] && echo "false" || echo "true") ;;
            9) break ;;
            *) echo "Invalid option" ;;
        esac
        
        save_config
    done
}

# Function to get device attributes
get_device_attributes() {
    local nodeId=$1
    local response=$(curl -s \
        --connect-timeout "$(printf '%.0f' "$CONNECT_TIMEOUT")" \
        --max-time "$(printf '%.0f' "$MAX_TIME")" \
        --retry "$(printf '%.0f' "$RETRY")" \
        --retry-delay "$(printf '%.0f' "$RETRY_DELAY")" \
        --retry-max-time "$(printf '%.0f' "$RETRY_MAX_TIME")" \
        --request GET \
        --url "https://api.tailscale.com/api/v2/device/${nodeId}/attributes" \
        --header "Authorization: Bearer ${API_KEY}")
    echo "$response"
}

# Get Tailscale data (either via API or local status)
get_tailscale_data() {
    local mode=$1
    
    if [ "$mode" = "custom" ] && [ -n "$API_KEY" ] && [ -n "$TAILNET_ORG" ]; then
        # API call logic for custom mode
        response=$(curl -s \
            --connect-timeout "$(printf '%.0f' "$CONNECT_TIMEOUT")" \
            --max-time "$(printf '%.0f' "$MAX_TIME")" \
            --retry "$(printf '%.0f' "$RETRY")" \
            --retry-delay "$(printf '%.0f' "$RETRY_DELAY")" \
            --retry-max-time "$(printf '%.0f' "$RETRY_MAX_TIME")" \
            --request GET \
            --url "https://api.tailscale.com/api/v2/tailnet/${TAILNET_ORG}/devices" \
            --header "Authorization: Bearer ${API_KEY}")
        
        if [ $? -eq 0 ]; then
            # Create a temporary file to store the combined data
            temp_file=$(mktemp)
            echo "[" > "$temp_file"  # Start JSON array
            first=true
            
            # Extract device information and fetch attributes for each
            echo "$response" | jq -r '.devices[] | select(.nodeId != null) | "\(.name),\(.hostname),\(.nodeId)"' | while IFS=',' read -r name hostname nodeId; do
                # Get attributes for this device
                attrs=$(get_device_attributes "$nodeId")
                
                if $first; then
                    first=false
                else
                    echo "," >> "$temp_file"
                fi
                
                jq -n \
                    --arg name "$name" \
                    --arg hostname "$hostname" \
                    --arg nodeId "$nodeId" \
                    --argjson attrs "$attrs" \
                    '{
                        name: $name,
                        hostname: $hostname,
                        nodeId: $nodeId,
                        attributes: ($attrs.attributes // {})
                    }' >> "$temp_file"
            done
            
            echo "]" >> "$temp_file"  # End JSON array
            cat "$temp_file"
            rm "$temp_file"
            return 0
        fi
    fi
    
    # Use local status for tag-based inventory or if API fails
    tailscale status --json
}

# Function to extract custom tags from API response
extract_custom_tags() {
    local json_data=$1
    # Parse JSON input first
    echo "$json_data" | jq -r '
        . as $raw |
        try fromjson catch $raw |
        [.[] | 
        select(.attributes != null) |
        .attributes |
        to_entries[] |
        select(.key | startswith("custom:")) |
        {
            key: .key,
            value: .value
        }
        ] | unique_by(.value) | map(.value) | .[]'
}

# Function to get devices with specific custom tag value
get_devices_with_custom_tag() {
    local json_data=$1
    local tag_value=$2
    # Parse JSON input first
    echo "$json_data" | jq -r --arg value "$tag_value" '
        . as $raw |
        try fromjson catch $raw |
        .[] | 
        select(.attributes != null) |
        select(
            (.attributes | to_entries[] | select(.value == $value)) != null
        ) |
        {
            hostname: .hostname,
            dnsname: .name,
            value: $value
        }'
}

# Add this new function before main_menu()
generate_hosts_list() {
    echo -e "\033[1;33mFetching host data...\033[0m"
    local data=$(get_tailscale_data "custom")
    
    # Extract and sort unique DNS names
    echo "$data" | jq -r '
        . as $raw |
        try fromjson catch $raw |
        .[] | 
        select(.name != null) |
        .name
    ' | sort -u > hosts.txt
    
    local count=$(wc -l < hosts.txt)
    echo -e "\033[1;32mGenerated hosts.txt with $count unique hosts\033[0m"
    read -p "Press Enter to continue..."
}

# Modify the main_menu function - replace it entirely
main_menu() {
    while true; do
        clear
        echo -e "\033[1;34mAnsiscale Main Menu\033[0m"
        echo -e "\033[1;34m------------------\033[0m"
        echo -e "\033[1;31m1. Generate Inventory (Using Tags)\033[0m"
        echo -e "\033[1;32m2. Generate Inventory (Using Custom Data)\033[0m"
        echo -e "\033[1;33m3. Generate Hosts List\033[0m"
        echo -e "\033[1;35m4. Settings\033[0m"
        echo -e "\033[1;36m5. Exit\033[0m"
        
        read -p "Select an option: " choice
        
        case $choice in
            1) generate_inventory "tags" ;;
            2) echo -e "\033[1;33mMaking API request, this may take some time...\033[0m"
               generate_inventory "custom" ;;
            3) generate_hosts_list ;;
            4) settings_menu ;;
            5) exit 0 ;;
            *) echo "Invalid option" ;;
        esac
    done
}

# Function to generate inventory (your existing logic)
generate_inventory() {
    local mode=$1
    TAILSCALE_STATUS=$(get_tailscale_data "$mode")
    if [ $? -ne 0 ]; then
        echo -e "\033[1;31mError: Failed to get Tailscale data\033[0m"
        read -p $'\033[1;33mPress Enter to continue...\033[0m'
        return 1
    fi

    if [ "$mode" = "custom" ]; then
        echo "Available custom attributes:"
        custom_tags=($(extract_custom_tags "$TAILSCALE_STATUS"))
        
        if ((${#custom_tags[@]} == 0)); then
            echo "No custom attributes found in the API response."
            echo "API Response:"
            echo "$TAILSCALE_STATUS" | jq '.'
            read -p "Press Enter to continue..."
            return 1
        fi

        for i in "${!custom_tags[@]}"; do
            echo "$((i+1)). ${custom_tags[$i]}"
        done
        
        # Collect parent/child relationships first
        collect_custom_relationships "${custom_tags[@]}"
        
        # Ask about SSH keys
        local use_ssh_keys=false
        local KEY_DIR=""
        local USER=""
        local SSH_ALGO=""
        
        if get_yes_no "Would you like to add SSH keys to the hosts?"; then
            use_ssh_keys=true
            
            # Get SSH key directory
            echo -e "\033[1;34mPlease specify the directory containing your SSH keys\033[0m"
            echo -e "\033[1;33mExample: /home/example/ssh_keys/ansibledevicekeys\033[0m"
            read -p "Key directory: " KEY_DIR
            
            # Validate directory exists
            if [ ! -d "$KEY_DIR" ]; then
                echo -e "\033[1;31mDirectory does not exist. Creating it...\033[0m"
                mkdir -p "$KEY_DIR"
            fi
            
            # Get SSH user
            read -p "Enter SSH user for hosts: " USER
            
            # Get SSH algorithm
            echo -e "\033[1;34mSpecify the SSH key algorithm being used\033[0m"
            echo -e "\033[1;33mExample: if your keys are named 'id_ed25519_hostname.domain', enter 'id_ed25519'\033[0m"
            read -p "SSH algorithm (e.g., id_ed25519, id_rsa): " SSH_ALGO
            
            echo -e "\033[1;32mSSH Key Configuration:\033[0m"
            echo -e "\033[1;33mKeys should be named in the format: ${SSH_ALGO}_hostname.domain\033[0m"
            echo -e "\033[1;33mExample: ${SSH_ALGO}_device.tailnet.ts.net\033[0m"
            echo -e "\033[1;33mBoth private (no extension) and public (.pub) keys should exist\033[0m"
            read -p "Press Enter to continue..."
        fi

        # Initialize inventory file
        echo "# Ansible inventory generated from Tailscale custom data" > inventory.yaml
        echo "---" >> inventory.yaml
        
        # Write inventory structure using parent/child relationships
        for parent in "${parents[@]}"; do
            echo "$parent:" >> inventory.yaml
            
            if [ "$parent" = "all" ]; then
                echo "  hosts:" >> inventory.yaml
                devices_json=$(get_devices_with_custom_tag "$TAILSCALE_STATUS" "${custom_tags[0]}")
                if [ "$use_ssh_keys" = true ]; then
                    echo "$devices_json" | jq -r --arg user "$USER" --arg keydir "$KEY_DIR" --arg algo "$SSH_ALGO" '
                        "          " + .dnsname + ":\n" +
                        "          ansible_ssh_private_key_file: " + ($keydir + "/" + $algo + "_" + .dnsname) + "\n" +
                        "          ansible_user: " + $user
                    ' >> inventory.yaml
                else
                    echo "$devices_json" | jq -r '
                        "          " + .dnsname + ":\n" +
                        "          ansible_host: " + .dnsname
                    ' >> inventory.yaml
                fi
                continue
            fi
            
            if [ -n "${parent_children[$parent]}" ]; then
                echo "  children:" >> inventory.yaml
                for child in ${parent_children[$parent]}; do
                    echo "    $child:" >> inventory.yaml
                    echo "      hosts:" >> inventory.yaml
                    devices_json=$(get_devices_with_custom_tag "$TAILSCALE_STATUS" "$child")
                    if [ "$use_ssh_keys" = true ]; then
                        echo "$devices_json" | jq -r --arg user "$USER" --arg keydir "$KEY_DIR" --arg algo "$SSH_ALGO" '
                            "          " + .dnsname + ":\n" +
                            "          ansible_ssh_private_key_file: " + ($keydir + "/" + $algo + "_" + .dnsname) + "\n" +
                            "          ansible_user: " + $user
                        ' >> inventory.yaml
                    else
                        echo "$devices_json" | jq -r '
                            "          " + .dnsname + ":\n" +
                            "          ansible_host: " + .dnsname
                        ' >> inventory.yaml
                    fi
                done
            else
                echo "  hosts:" >> inventory.yaml
                devices_json=$(get_devices_with_custom_tag "$TAILSCALE_STATUS" "$parent")
                if [ "$use_ssh_keys" = true ]; then
                    echo "$devices_json" | jq -r --arg user "$USER" --arg keydir "$KEY_DIR" --arg algo "$SSH_ALGO" '
                        "          " + .dnsname + ":\n" +
                        "          ansible_ssh_private_key_file: " + ($keydir + "/" + $algo + "_" + .dnsname) + "\n" +
                        "          ansible_user: " + $user
                    ' >> inventory.yaml
                else
                    echo "$devices_json" | jq -r '
                        "          " + .dnsname + ":\n" +
                        "          ansible_host: " + .dnsname
                    ' >> inventory.yaml
                fi
            fi
        done
    else
        # Original tag-based inventory generation
        collect_relationships

        # Ask about SSH keys
        local use_ssh_keys=false
        local KEY_DIR=""
        local USER=""
        local SSH_ALGO=""
        
        if get_yes_no "Would you like to add SSH keys to the hosts?"; then
            use_ssh_keys=true
            
            # Get SSH key directory
            echo -e "\033[1;34mPlease specify the directory containing your SSH keys\033[0m"
            echo -e "\033[1;33mExample: /home/example/ssh_keys/ansibledevicekeys\033[0m"
            read -p "Key directory: " KEY_DIR
            
            # Validate directory exists
            if [ ! -d "$KEY_DIR" ]; then
                echo -e "\033[1;31mDirectory does not exist. Creating it...\033[0m"
                mkdir -p "$KEY_DIR"
            fi
            
            # Get SSH user
            read -p "Enter SSH user for hosts: " USER
            
            # Get SSH algorithm
            echo -e "\033[1;34mSpecify the SSH key algorithm being used\033[0m"
            echo -e "\033[1;33mExample: if your keys are named 'id_ed25519_hostname.domain', enter 'id_ed25519'\033[0m"
            read -p "SSH algorithm (e.g., id_ed25519, id_rsa): " SSH_ALGO
            
            echo -e "\033[1;32mSSH Key Configuration:\033[0m"
            echo -e "\033[1;33mKeys should be named in the format: ${SSH_ALGO}_hostname.domain\033[0m"
            echo -e "\033[1;33mExample: ${SSH_ALGO}_device-001.tailnet.ts.net\033[0m"
            echo -e "\033[1;33mBoth private (no extension) and public (.pub) keys should exist\033[0m"
            read -p "Press Enter to continue..."
        fi

        # Initialize inventory file
        echo "# Ansible inventory generated from Tailscale status" > inventory.yaml
        echo "---" >> inventory.yaml

        # Function to write hosts for a group
        write_hosts() {
            local group=$1
            local indent=$2
            local tag_name="$group"
            
            # Ensure tag_name includes 'tag:' prefix
            if [[ "$tag_name" != tag:* ]]; then
                tag_name="tag:$tag_name"
            fi
            
            if [ "$use_ssh_keys" = true ]; then
                echo "$TAILSCALE_STATUS" | jq -r --arg tag "$tag_name" --arg user "$USER" --arg keydir "$KEY_DIR" --arg algo "$SSH_ALGO" '
                    (.Self, .Peer[]?)
                    | select(.Tags[]? == $tag)
                    | select(.HostName != null and .DNSName != null)
                    | (.DNSName | rtrimstr(".")) as $hostname |
                    "    " + $hostname + ":\n" +
                    "      ansible_host: " + (.DNSName | rtrimstr(".")) + "\n" +
                    "      ansible_user: " + $user + "\n" +
                    "      ansible_ssh_private_key_file: " + ($keydir + "/" + $algo + "_" + (.DNSName | rtrimstr(".")))
                ' >> inventory.yaml
            else
                echo "$TAILSCALE_STATUS" | jq -r --arg tag "$tag_name" '
                    (.Self, .Peer[]?)
                    | select(.Tags[]? == $tag)
                    | select(.HostName != null and .DNSName != null)
                    | (.DNSName | rtrimstr(".")) as $hostname
                    | "    " + $hostname + ":\n      ansible_host: " + (.DNSName | rtrimstr("."))
                ' >> inventory.yaml
            fi

            # Keep track of which hosts we've assigned
            used_hosts+=("$hostname")
        }

        # Write inventory structure
        for parent in "${parents[@]}"; do
            echo "$parent:" >> inventory.yaml
            
            if [ "$parent" = "hosts" ]; then
                write_hosts "$parent" "  "
                continue
            fi
            
            if [ -n "${parent_children[$parent]}" ]; then
                echo "  children:" >> inventory.yaml
                for child in ${parent_children[$parent]}; do
                    echo "    $child:" >> inventory.yaml
                    write_hosts "$child" "      "
                done
            else
                write_hosts "$parent" "  "
            fi
        done

        # Before writing unknown hosts, ensure used_hosts_json is valid even if used_hosts is empty
        if [ "${#used_hosts[@]}" -eq 0 ]; then
            used_hosts_json='[]'
        else
            used_hosts_json=$(printf '%s\n' "${used_hosts[@]}" | jq -R . | jq -s .)
        fi

        # Add unknown group for unmatched hosts (those without matching tags)
        echo "unknown:" >> inventory.yaml
        echo "  hosts:" >> inventory.yaml
        echo "$TAILSCALE_STATUS" | jq -r --argjson used_hosts "$used_hosts_json" '
            (.Self, .Peer[]?)
            | select(.HostName != null and .DNSName != null)
            | (.DNSName | rtrimstr(".")) as $hostname
            | select($used_hosts | index($hostname) | not)
            | "    " + $hostname + ":\n      ansible_host: " + (.DNSName | rtrimstr("."))
        ' >> inventory.yaml
    fi
}

# Function to extract and display available tags
show_available_tags() {
    echo -e "\033[1;34mAvailable tags from Tailscale:\033[0m"
    mapfile -t available_tags < <(echo "$TAILSCALE_STATUS" | jq -r '
        [ (.Self, .Peer[]?) | .Tags[]? ] | unique[]
    ' 2>/dev/null)
    
    for i in "${!available_tags[@]}"; do
        echo -e "\033[1;36m  $((i+1)). ${available_tags[$i]}\033[0m"
    done
    echo
}

# Function to get tag selection
get_tag_selection() {
    local prompt=$1
    local selection
    
    while true; do
        read -p "$prompt (enter number or custom name): " selection
        if [[ "$selection" =~ ^[0-9]+$ ]]; then
            if (( selection > 0 && selection <= ${#available_tags[@]} )); then
                echo "${available_tags[$((selection-1))]}"
                return
            else
                echo "Invalid selection. Please enter a valid number."
            fi
        else
            # If it doesn't start with "tag:", add it
            if [[ "$selection" != tag:* ]]; then
                echo "tag:$selection"
            else
                echo "$selection"
            fi
            return
        fi
    done
}

# Function to get user input
get_yes_no() {
    while true; do
        read -p $'\033[1;33m'"$1"$' (y/n): \033[0m' yn
        case $yn in
            [Yy]* ) return 0;;
            [Nn]* ) return 1;;
            * ) echo -e "\033[1;31mPlease answer y or n.\033[0m";;
        esac
    done
}

# Function to collect parent-child relationships
collect_relationships() {
    show_available_tags

    if ! get_yes_no "Would you like to enter a parent?"; then
        parents+=("hosts")
        parent_children["hosts"]=""
        return
    fi

    while true; do
        parent=$(get_tag_selection "Enter parent name or select a tag")
        parents+=("$parent")
        parent_children["$parent"]=""
        
        while true; do
            echo "Enter child names or select tags (separate by semicolons):"
            read -p "Enter numbers or custom names: " child_input
            IFS=';' read -ra child_array <<< "$child_input"
            for child_selection in "${child_array[@]}"; do
                child_selection=$(echo "$child_selection" | xargs)  # Trim whitespace
                if [[ "$child_selection" =~ ^[0-9]+$ ]]; then
                    if (( child_selection > 0 && child_selection <= ${#available_tags[@]} )); then
                        child="${available_tags[$((child_selection-1))]}"
                    else
                        echo "Invalid selection: $child_selection"
                        continue
                    fi
                else
                    if [[ "$child_selection" != tag:* ]]; then
                        child="tag:$child_selection"
                    else
                        child="$child_selection"
                    fi
                fi
                if [ -z "${parent_children[$parent]}" ]; then
                    parent_children["$parent"]="$child"
                else
                    parent_children["$parent"]="${parent_children[$parent]} $child"
                fi
            done
            break
        done
        
        if ! get_yes_no "Would you like to add another parent?"; then
            break
        fi
    done
}

# Function to collect custom attribute relationships
collect_custom_relationships() {
    local custom_tags=("$@")
    echo -e "\033[1;34mAvailable custom attributes for grouping:\033[0m"
    for i in "${!custom_tags[@]}"; do
        echo -e "\033[1;36m  $((i+1)). ${custom_tags[$i]}\033[0m"
    done
    echo -e "\033[1;36m  $(( ${#custom_tags[@]} + 1 )). Enter custom group name\033[0m"
    echo

    if ! get_yes_no $'\033[1;33mWould you like to create parent groups?\033[0m'; then
        parents+=("all")
        parent_children["all"]=""
        return
    fi

    while true; do
        echo -e "\033[1;32mSelect parent group:\033[0m"
        read -p $'\033[1;33mEnter number or custom name: \033[0m' parent_choice
        
        if [[ "$parent_choice" =~ ^[0-9]+$ ]]; then
            if (( parent_choice > 0 && parent_choice <= ${#custom_tags[@]} )); then
                parent="${custom_tags[$((parent_choice-1))]}"
            elif (( parent_choice == ${#custom_tags[@]} + 1 )); then
                read -p "Enter custom group name: " parent
            else
                echo "Invalid selection"
                continue
            fi
        else
            parent="$parent_choice"
        fi
        
        parents+=("$parent")
        parent_children["$parent"]=""
        
        while get_yes_no "Would you like to add child groups to '$parent'?"; do
            echo "Enter child groups (separate by semicolons):"
            read -p "Enter numbers or custom names: " child_input
            IFS=';' read -ra child_array <<< "$child_input"
            for child_selection in "${child_array[@]}"; do
                child_selection=$(echo "$child_selection" | xargs)  # Trim whitespace
                if [[ "$child_selection" =~ ^[0-9]+$ ]]; then
                    if (( child_selection > 0 && child_selection <= ${#custom_tags[@]} )); then
                        child="${custom_tags[$((child_selection-1))]}"
                    elif (( child_selection == ${#custom_tags[@]} + 1 )); then
                        read -p "Enter custom group name: " child
                    else
                        echo "Invalid selection: $child_selection"
                        continue
                    fi
                else
                    child="$child_selection"
                fi
                if [ -z "${parent_children[$parent]}" ]; then
                    parent_children["$parent"]="$child"
                else
                    parent_children["$parent"]="${parent_children[$parent]} $child"
                fi
            done
            break
        done
        
        if ! get_yes_no "Would you like to add another parent group?"; then
            break
        fi
    done
}

# Load config and check for first run
load_config
if [ -z "$API_KEY" ] || [ -z "$TAILNET_ORG" ]; then
    first_run_setup
fi

# Start main menu
main_menu
