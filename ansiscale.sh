#!/bin/bash

declare -A parent_children
declare -a parents
declare -a available_tags
declare -a used_hosts=()
declare -A hostname_counts

# Get Tailscale status early to extract tags
TAILSCALE_STATUS=$(tailscale status --json)
if [ $? -ne 0 ]; then
    echo "Error: Failed to get Tailscale status"
    exit 1
fi

# Function to extract and display available tags
show_available_tags() {
    echo "Available tags from Tailscale:"
    mapfile -t available_tags < <(echo "$TAILSCALE_STATUS" | jq -r '
        [ (.Self, .Peer[]?) | .Tags[]? ] | unique[]
    ' 2>/dev/null)
    
    for i in "${!available_tags[@]}"; do
        echo "  $((i+1)). ${available_tags[$i]}"
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
        read -p "$1 (y/n): " yn
        case $yn in
            [Yy]* ) return 0;;
            [Nn]* ) return 1;;
            * ) echo "Please answer y or n.";;
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
            child=$(get_tag_selection "Enter child name or select a tag")
            if [ -z "${parent_children[$parent]}" ]; then
                parent_children["$parent"]="$child"
            else
                parent_children["$parent"]="${parent_children[$parent]} $child"
            fi
            
            if ! get_yes_no "Would you like to add another child?"; then
                break
            fi
        done
        
        if ! get_yes_no "Would you like to add another parent?"; then
            break
        fi
    done
}

# Collect parent-child relationships
collect_relationships

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
    
    echo "${indent}hosts:" >> inventory.yaml
    echo "$TAILSCALE_STATUS" | jq -r --arg tag "$tag_name" '
        (.Self, .Peer[]?)
        | select(.Tags[]? == $tag)
        | select(.HostName != null and .DNSName != null)
        | .HostName + "::" + (.DNSName | rtrimstr("."))
    ' | while IFS="::" read -r hostname dnsname; do
        # Check if hostname already exists
        if [[ -v "hostname_counts[$hostname]" ]]; then
            count=${hostname_counts[$hostname]}
            count=$((count + 1))
            hostname_counts[$hostname]=$count
            hostname="${hostname}_${count}"
        else
            hostname_counts[$hostname]=1
        fi

        echo "${indent}  ${hostname}: " >> inventory.yaml
        echo "${indent}    ansible_host: ${dnsname}" >> inventory.yaml

        # Keep track of which hosts we've assigned
        used_hosts+=("$hostname")
    done
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
    | .HostName as $hostname
    | select($used_hosts | index($hostname) | not)
    | "    " + $hostname + ": " +
      "\n      " + "ansible_host: " + (.DNSName | rtrimstr("."))
' >> inventory.yaml
