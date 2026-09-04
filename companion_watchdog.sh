#!/bin/bash


# The companion_watchdog.sh script is an automated, high-signal monitoring and self-healing framework designed
# for multi-node Bitfocus Companion home lab deployments. Its primary purpose is to maintain a constant, stable
# connection between a centralized Companion application host and its distributed hardware "satellites" (such 
# as Elgato Stream Decks located in different rooms) by bridging the gap between passive log auditing and
# proactive network orchestration.

# To achieve this, the script operates in two distinct phases:

#    Real-Time Log Tracking & Remediation: The watchdog continuously tails the server's system logs (journalctl)
#    to intercept device disconnections. If a satellite's network socket drops while its background process
#    remains deceptively alive, the script instantly catches the event and bypasses secure execution restrictions
#    by firing an out-of-band HTTP webhook trigger via curl. This tells the remote satellite's lightweight 
#    webhook daemon to natively restart its local service wrapper, executing an immediate connection recovery
#    in milliseconds.

#    Dynamic Inventory Mapping & Self-Repair: On initialization, the script parses a pipe-delimited configuration
#    inventory (config.txt), printing a visual report of your tracked estate to the console while strictly isolating
#    commented or disabled tracks in-memory. If an unmapped or freshly toggled satellite registers with the cluster, 
#    the script deploys a column-agnostic socket audit engine (ss). It pulls active network frames, cross-references
#    them with active memory maps to isolate unique unassigned peer nodes, and dynamically writes or updates 
#    hardware serial links back to your configuration profile on the fly without hardcoded networking assumptions.

echo "[$(date)] Starting $0"

# Define lookup paths for config location targets
CONFIG_DIR="$HOME/.config/companion-watchdog"
CONFIG_FILE_PRIMARY="$CONFIG_DIR/config.txt"
CONFIG_FILE_LOCAL="./config.txt"

# Select active config tracking target
if [ -f "$CONFIG_FILE_PRIMARY" ]; then
    ACTIVE_CONFIG="$CONFIG_FILE_PRIMARY"
elif [ -f "$CONFIG_FILE_LOCAL" ]; then
    ACTIVE_CONFIG="$CONFIG_FILE_LOCAL"
else
    mkdir -p "$CONFIG_DIR" 2>/dev/null
    ACTIVE_CONFIG="$CONFIG_FILE_PRIMARY"
    echo "# Dynamic Configuration File" > "$ACTIVE_CONFIG"
fi

echo "[$(date)] Using configuration file: $ACTIVE_CONFIG"

# State & Identity Registries
declare -A SATELLITE_HOOKS
declare -A SERIAL_MAP
declare -A OFFLINE_STATUS

# Global Parameter Variables
ALERT_EMAIL=""
DELAY_MINUTES=15

# Track whether this is the first configuration load
INITIAL_LOAD=true

# Function to parse config file and build in-memory mappings
load_config() {
    # Clear maps before reloading using safe quoting
    for key in "${!SATELLITE_HOOKS[@]}"; do unset SATELLITE_HOOKS["$key"]; done
    for key in "${!SERIAL_MAP[@]}"; do unset SERIAL_MAP["$key"]; done

    # Dynamically extract global variables from the top of the file
    ALERT_EMAIL=$(grep -i '^ALERT_EMAIL' "$ACTIVE_CONFIG" | cut -d'=' -f2 | xargs)
    local check_delay=$(grep -i '^DELAY_MINUTES' "$ACTIVE_CONFIG" | cut -d'=' -f2 | xargs)
    [ -n "$check_delay" ] && DELAY_MINUTES=$check_delay
    
    if [ "$INITIAL_LOAD" = true ]; then
        echo "[$(date)] Loading satellite inventory configuration definitions..."
        echo "[$(date)]    -> Alert Email Target: $ALERT_EMAIL"
        echo "[$(date)]    -> Notification Delay Window: $DELAY_MINUTES minutes"
    fi
    
    while IFS= read -r line || [ -n "$line" ]; do
        # Clean line structures (Strip comments and leading/trailing spaces first)
        line=$(echo "$line" | sed -e 's/#.*//' -e '/^[[:space:]]*$/d')
        [ -z "$line" ] && continue
        
        # Precision Gate: Skip parameter rows (lines with an '=' but NO pipe '|')
        if [[ "$line" == *=* ]] && [[ "$line" != *\|* ]]; then
            continue
        fi
        
        # Break fields securely using the pipe delimiter
        ROOM=$(echo "$line" | cut -d'|' -f1 | xargs)
        IP=$(echo "$line" | cut -d'|' -f2 | xargs)
        SERIAL=$(echo "$line" | cut -d'|' -f3 | xargs)

        if [ -n "$ROOM" ] && [ -n "$IP" ]; then
            SATELLITE_HOOKS["$ROOM"]="http://$IP:9000/hooks/restart-satellite"
            if [ -n "$SERIAL" ]; then
                SERIAL_MAP["$SERIAL"]="$ROOM"
            fi

            # Print inventory payload out ONLY during the initial boot sequence
            if [ "$INITIAL_LOAD" = true ]; then
                echo "[$(date)]    -> Loaded: $ROOM (${SERIAL:-MISSING}) @ $IP"
            fi
        fi
    done < "$ACTIVE_CONFIG"

    # Flip tracking boolean so subsequent discovery hot-reloads execute silently
    INITIAL_LOAD=false
}

# Helper thread handler to safely monitor the persistent drop window
manage_delayed_email_alert() {
    local target_room="$1"
    local delay_seconds=$(( DELAY_MINUTES * 60 ))
    
    # Extract the target client's IP from its registered webhook hook URL structure
    local target_url="${SATELLITE_HOOKS["$target_room"]}"
    local target_ip=$(echo "$target_url" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
    
    
    trigger_date=$(date)
    
    # Sleep for 1 minute to see if the connection is restored, if so, do nothing
    
    sleep 60 
    if [ -n "$target_ip" ] && ss -nt state established sport = :16622 2>/dev/null | grep -q "$target_ip"; then
        return
    fi
    
    # Sleep asynchronously without blocking live log monitoring streams    
    sleep $delay_seconds
    
    # LIVE ENVIRONMENTAL VERIFICATION (FIXED: Greps for the target IP address instead of Room Name)
    if [ -n "$target_ip" ] && ss -nt state established sport = :16622 2>/dev/null | grep -q "$target_ip"; then
        echo "[$(date)] Dynamic Check: '$target_room' ($target_ip) has reconnected. Suppressing email alert."
        return
    fi
    
    # Double-check if the main loop has already cleared its offline flag
    if [ "${OFFLINE_STATUS["$target_room"]}" != "true" ]; then
        echo "[$(date)] State Check: '$target_room' marked online in main memory. Suppressing email alert."
        return
    fi
    
    # If the IP is genuinely missing from the socket table, dispatch the email
    if [ -n "$ALERT_EMAIL" ]; then
        echo "[$(date)] TIMEOUT REACHED: '$target_room' failed to reconnect within $DELAY_MINUTES minutes. Sending email..."
        
        echo -e "Companion Watchdog Alert!\n\nConnection Lost at: $trigger_date\nDevice Location: $target_room\nStatus: OFFLINE\nDuration: Exceeded $DELAY_MINUTES minutes down. Webhook recovery initiated but connection remains dead." | mail -s "CRITICAL: Satellite Connection Drop - $target_room" -r "watchdog <notifications@companion.zwebify.com>" "$ALERT_EMAIL"
    fi
}

# Initial Config Import & Verification Dump
load_config

echo "[$(date)] Starting Bitfocus Companion Satellite Socket Watchdog..."

# Define log execution match parameters
regex_surface="Surface/Handler/streamdeck:"
regex_extract="streamdeck:([A-Z0-9]+)"

# ==============================================================================
# PHASE 1: STARTUP LOG CHECK (Parsing history since last Companion App initialization)
# ==============================================================================
echo "[$(date)] Phase 1: Replaying timeline to determine current active state..."

# Find the timestamp of the latest "Started" log entry from the companion unit
START_TIME=$(journalctl -u companion | grep -F "Started" | tail -n 1 | awk '$1 ~ /^[A-Z][a-z][a-z]$/ {print $1" "$2" "$3}')
[ -z "$START_TIME" ] && START_TIME="24 hours ago"

while read -r line; do
    if [[ "$line" =~ disconnected ]]; then
        if [[ "$line" =~ $regex_extract ]]; then
            SERIAL="${BASH_REMATCH[1]}"
            ROOM_NAME="${SERIAL_MAP["$SERIAL"]}"
            [ -n "$ROOM_NAME" ] && OFFLINE_STATUS["$ROOM_NAME"]="true"
        fi
    elif [[ "$line" =~ "Adding Satellite device" ]]; then
        if [[ "$line" =~ $regex_extract ]]; then
            SERIAL="${BASH_REMATCH[1]}"
            ROOM_NAME="${SERIAL_MAP["$SERIAL"]}"
            [ -n "$ROOM_NAME" ] && OFFLINE_STATUS["$ROOM_NAME"]="false"
        fi
    fi
done < <(journalctl -u companion --since "$START_TIME")

# Trigger initial startup recovery sequences
for ROOM_NAME in "${!SATELLITE_HOOKS[@]}"; do
    if [ "${OFFLINE_STATUS["$ROOM_NAME"]}" = "true" ]; then
        HOOK_URL="${SATELLITE_HOOKS["$ROOM_NAME"]}"
        echo "[$(date)]    -> Startup Detection: '$ROOM_NAME' is offline. Sending webhook update to $HOOK_URL..."
        curl -s --max-time 3 "$HOOK_URL" >/dev/null 2>&1 &
        # Launch non-blocking background fork to monitor the grace period safely
        manage_delayed_email_alert "$ROOM_NAME" &
    else
        echo "[$(date)]    -> Startup Detection: '$ROOM_NAME' is online."
    fi
done

# ==============================================================================
# PHASE 2: CONTINUOUS REAL-TIME MONITORING & LIVE AUTO-DISCOVERY
# ==============================================================================
echo "[$(date)] Phase 2: System synchronization complete. Monitoring live log streams..."

journalctl -u companion -f -n 0 | while read -r line; do

    # WATCHDOG MONITOR & DISCOVERY: Reconnection / Registration Check
    if [[ "$line" =~ "Adding Satellite device" ]]; then
        if [[ "$line" =~ $regex_extract ]]; then
            SERIAL="${BASH_REMATCH[1]}"
            ROOM_NAME="${SERIAL_MAP["$SERIAL"]}"

            # --- BULLETPROOF SOCKET AUTO-DISCOVERY ENGINE ---
            if [ -z "$ROOM_NAME" ]; then
                echo "[$(date)] Companion found new Satellite with serial [$SERIAL]. Scanning for IP address"

                # DYNAMIC LOCAL HOST IP DETECTION:
                # Queries internal kernel interface tables, drops the localhost address, and isolates active subnets
                LOCAL_CONTAINER_IPS=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '127.0.0.1' | grep -v '^$')

                # Pull ALL unique connected peer IPv4 strings on the satellite listener socket port (16622)
                RAW_SOCKET_IPS=$(ss -nt state established sport = :16622 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | sort -u)

                CANDIDATE_IPS=$(ss -nt state established sport = :16622 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | grep -v '172.16.10.166' | sort -u)
                # Filter out any local container IPs from the list of candidates dynamically
                CANDIDATE_IPS=""
                for ADDR in $RAW_SOCKET_IPS; do
                    if ! echo "$LOCAL_CONTAINER_IPS" | grep -q "^$ADDR$"; then
                    CANDIDATE_IPS="$CANDIDATE_IPS $ADDR"
                    fi
                done

                DETECTED_IP=""
                IS_EXISTING_IP_WITHOUT_SERIAL=false

                for CANDIDATE in $CANDIDATE_IPS; do
                    IP_ROOM=""
                    IP_HAS_SERIAL=false

                    # Inspect active in-memory configurations
                    for MAPPED_ROOM in "${!SATELLITE_HOOKS[@]}"; do
                        if [[ "${SATELLITE_HOOKS["$MAPPED_ROOM"]}" == *"$CANDIDATE"* ]]; then
                            IP_ROOM="$MAPPED_ROOM"

                            # Cross-reference: Does this room already have an assigned hardware serial?
                            for SE in "${!SERIAL_MAP[@]}"; do
                                if [ "${SERIAL_MAP["$SE"]}" = "$MAPPED_ROOM" ]; then
                                    IP_HAS_SERIAL=true
                                    break
                                fi
                            done
                            break
                        fi
                    done

                    # CASE A: The IP is explicitly mapped, but lacks a companion hardware serial string
                    if [ -n "$IP_ROOM" ] && [ "$IP_HAS_SERIAL" = false ]; then
                        DETECTED_IP="$CANDIDATE"
                        IS_EXISTING_IP_WITHOUT_SERIAL=true
                        break

                    # CASE B: The IP address is completely unassigned (e.g. commented out or net-new)
                    elif [ -z "$IP_ROOM" ]; then
                        DETECTED_IP="$CANDIDATE"
                        break
                    fi
                done

                if [ -n "$DETECTED_IP" ]; then
                    if [ "$IS_EXISTING_IP_WITHOUT_SERIAL" = true ]; then
                        echo "[$(date)] AUTO-CONFIG REPAIR: Found matching entry for IP $DETECTED_IP. Appending hardware serial [$SERIAL] inline..."
                        # Ensure we append ONLY to an uncommented live row matching this IP address
                        sed -i "/^[[:space:]]*#/! s/$DETECTED_IP.*/& | $SERIAL/" "$ACTIVE_CONFIG"
                        
                        NOTIFICATION_SUBJECT="Watchdog Inventory System Repair Notification"
                        NOTIFICATION_BODY="The system successfully repaired an existing configuration tracking element.\n\nDate Repaired: $(date)\nIP Address Node: $DETECTED_IP\nHardware Serial Associated: $SERIAL"
                    else
                        ROOM_NAME="Discovered-Device-$SERIAL"
                        echo "[$(date)] NEW SATELLITE DISCOVERED: Bounding hardware [$SERIAL] to IP $DETECTED_IP"
                        echo "$ROOM_NAME | $DETECTED_IP | $SERIAL  #Automatically added on $(date)" >> "$ACTIVE_CONFIG"
                        
                        NOTIFICATION_SUBJECT="NEW Satellite Device Discovered Automatically"
                        NOTIFICATION_BODY="A brand-new satellite node connected to the cluster network framework and has been registered inside config.txt.\n\nDate Found: $(date)\nAssigned Name ID: $ROOM_NAME\nLive IP Address: $DETECTED_IP\nDevice Serial Number: $SERIAL"
                    fi
                    
                    # Dispatch instant alert email with friendly sender layout for discovery/repair events
                    if [ -n "$ALERT_EMAIL" ]; then
                        echo -e "$NOTIFICATION_BODY" | mail -s "$NOTIFICATION_SUBJECT" -r "watchdog <notifications@companion.zwebify.com>" "$ALERT_EMAIL"
                    fi

                    # Refresh memory arrays securely
                    load_config
                    ROOM_NAME="${SERIAL_MAP["$SERIAL"]}"
                else
                    echo "[$(date)] WARNING: Could not resolve a unique unassigned network IP address for device [$SERIAL]."
                    continue
                fi
            fi

            # Safe Array Gate Check
            if [ -n "$ROOM_NAME" ]; then
                if [ "${OFFLINE_STATUS["$ROOM_NAME"]}" = "true" ]; then
                    echo "[$(date)] RECOVERY SUCCESSFUL: '$ROOM_NAME' connection has been successfully restored!"
                    OFFLINE_STATUS["$ROOM_NAME"]="false"
                fi
            fi
        fi

    # WATCHDOG MONITOR: Disconnection Trap Handling
    elif [[ "$line" =~ disconnected ]]; then
        if [[ "$line" =~ $regex_extract ]]; then
            SERIAL="${BASH_REMATCH[1]}"
            ROOM_NAME="${SERIAL_MAP["$SERIAL"]}"

            if [ -n "$ROOM_NAME" ]; then
                HOOK_URL="${SATELLITE_HOOKS["$ROOM_NAME"]}"

                if [ -n "$HOOK_URL" ]; then
                    if [ "${OFFLINE_STATUS["$ROOM_NAME"]}" != "true" ]; then
                        echo "[$(date)] ALERT DETECTED: '$ROOM_NAME' dropped offline. Triggering webhook at $HOOK_URL..."
                        OFFLINE_STATUS["$ROOM_NAME"]="true"
                        curl -s --max-time 3 "$HOOK_URL" >/dev/null 2>&1 &
                        # Launch non-blocking background fork to monitor the grace period safely
                        manage_delayed_email_alert "$ROOM_NAME" &
                    fi
                fi
            fi
        fi
    fi
done
