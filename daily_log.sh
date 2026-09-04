#!/bin/bash

# Configuration file location to parse global properties and inventory mapping
CONFIG_FILE="/root/.config/companion-watchdog/config.txt"

# Safe default fallbacks if properties fail to load dynamically
ALERT_EMAIL="root@localhost"

# Extract global configuration metadata dynamically from the top lines of the file
if [ -f "$CONFIG_FILE" ]; then
    EXTRACTED_EMAIL=$(grep -v '^[[:space:]]*#' "$CONFIG_FILE" | grep "ALERT_EMAIL" | cut -d'=' -f2 | xargs)
    if [ -n "$EXTRACTED_EMAIL" ]; then
        ALERT_EMAIL="$EXTRACTED_EMAIL"
    fi
fi

# Define temporary file for building the monospaced HTML document layout
REPORT_FILE="/tmp/daily_companion_report.html"

# Cache the last 24 hours of log journal history into isolated variables
WATCHDOG_LOGS=$(journalctl -u companion-watchdog --since "24 hours ago" --no-pager)
COMPANION_LOGS=$(journalctl -u companion --since "24 hours ago" --no-pager)

# Calculate Global Summary Dashboard Matrix directly out of watchdog events
TOTAL_DISCONNECTS=$(echo "$WATCHDOG_LOGS" | grep -c -E "ALERT DETECTED:.*dropped offline|Startup Detection:.*is offline")
TOTAL_RECONNECTS=$(echo "$WATCHDOG_LOGS" | grep -v "Suppressing email alert" | grep -c -E "RECOVERY SUCCESSFUL|Dynamic Check:.*reconnected|State Check:.*online")
TOTAL_FAILED_CONN=$(echo "$WATCHDOG_LOGS" | grep -c -E "TIMEOUT REACHED:.*failed to reconnect|WARNING: Could not resolve")
TOTAL_EMAILS_SENT=$(echo "$WATCHDOG_LOGS" | grep -c -E "TIMEOUT REACHED:")

# Initialize the monospaced HTML container frame
echo "<html><body style='font-family: monospace; background-color: #1e1e1e; color: #d4d4d4; padding: 15px;'>" > "$REPORT_FILE"
echo "<h2>Bitfocus Companion Status Summary (Last 24 Hours)</h2>" >> "$REPORT_FILE"
echo "<p><strong>Generated at:</strong> $(date)</p>" >> "$REPORT_FILE"
echo "<hr style='border: 1px solid #444;' />" >> "$REPORT_FILE"

# Section: Summary Metrics Matrix
echo "<h3 style='color: #ff8c00;'>=== 24-HOUR WATCHDOG METRICS SUMMARY ===</h3>" >> "$REPORT_FILE"
echo "<pre style='font-family: monospace; background-color: #2d2d2d; padding: 12px; border-left: 4px solid #ff8c00; border-radius: 4px; line-height: 1.4;'>" >> "$REPORT_FILE"
printf "TOTAL DISCONNECT EVENTS   : %d\n" "$TOTAL_DISCONNECTS" >> "$REPORT_FILE"
printf "TOTAL RECONNECT EVENTS   : %d\n" "$TOTAL_RECONNECTS" >> "$REPORT_FILE"
printf "TOTAL FAILED CONNECTIONS : %d\n" "$TOTAL_FAILED_CONN" >> "$REPORT_FILE"
printf "TOTAL EMAILS SENT        : %d\n" "$TOTAL_EMAILS_SENT" >> "$REPORT_FILE"
echo -e "\n--- SUB-TOTAL BREAKDOWN BY SATELLITE NODE ---" >> "$REPORT_FILE"

# Dynamically pull mapped devices out of config.txt using loop isolation logic
if [ -f "$CONFIG_FILE" ]; then
    # Filter out comments and configuration variables, passing only pipe-delimited records
    grep -v '^[[:space:]]*#' "$CONFIG_FILE" | grep -F "|" | sort | while IFS= read -r line; do
        # Extract the Room Name out of the line up to the first pipe character
        ROOM_NAME=$(echo "$line" | cut -d'|' -f1 | xargs)

        if [ -n "$ROOM_NAME" ]; then
            # Parse metrics for this device explicitly out of the watchdog logs matching strings
            ROOM_DISC=$(echo "$WATCHDOG_LOGS" | grep -F "'$ROOM_NAME'" | grep -c -E "ALERT DETECTED|Startup Detection:.*offline")
            ROOM_RECON=$(echo "$WATCHDOG_LOGS" | grep -F "'$ROOM_NAME'" | grep -v "Suppressing email alert" | grep -c -E "RECOVERY SUCCESSFUL|Dynamic Check:.*reconnected|State Check:.*online")
            ROOM_FAIL=$(echo "$WATCHDOG_LOGS" | grep -F "'$ROOM_NAME'" | grep -c -E "TIMEOUT REACHED")

            # Append nicely formatted table rows into the matrix view
            printf "  %-15s | Disconnects: %-3d | Reconnects: %-3d | Failures: %-3d\n" "$ROOM_NAME" "$ROOM_DISC" "$ROOM_RECON" "$ROOM_FAIL" >> "$REPORT_FILE"
        fi
    done < <(grep -v '^[[:space:]]*#' "$CONFIG_FILE" | grep -F "|")
else
    echo "  [ERROR] Configuration inventory file not available for subtotals math." >> "$REPORT_FILE"
fi

echo "</pre>" >> "$REPORT_FILE"
echo "<hr style='border: 1px solid #444;' />" >> "$REPORT_FILE"


# Section 1: Watchdog Logs Append Block
echo "<h3 style='color: #4fc1ff;'>=== SECTION 1: COMPANION-WATCHDOG LIFECYCLE MANAGEMENT ===</h3>" >> "$REPORT_FILE"
echo "<pre style='font-family: monospace; background-color: #000; padding: 10px; border-radius: 4px; overflow-x: auto;'>" >> "$REPORT_FILE"
echo "$WATCHDOG_LOGS" >> "$REPORT_FILE"
echo "</pre>" >> "$REPORT_FILE"

echo "<hr style='border: 1px solid #444;' />" >> "$REPORT_FILE"


# Section 2: Companion Core Engine Logs Append Block
echo "<h3 style='color: #4fc1ff;'>=== SECTION 2: BITFOCUS COMPANION CORE ENGINE & SATELLITES ===</h3>" >> "$REPORT_FILE"
echo "<pre style='font-family: monospace; background-color: #000; padding: 10px; border-radius: 4px; overflow-x: auto;'>" >> "$REPORT_FILE"
echo "$COMPANION_LOGS" >> "$REPORT_FILE"
echo "</pre>" >> "$REPORT_FILE"

echo "<p style='color: #888; font-size: 11px;'>End of Daily Report.</p>" >> "$REPORT_FILE"
echo "</body></html>" >> "$REPORT_FILE"

CNT=$(cat "$REPORT_FILE" | grep -c "Version/Build mismatch detected")
if [ $CNT != 0 ];
then 
    COMMENT="UPGRADE NEEDED:"
else
    COMMENT="DAILY SUMMARY:"
fi

# Dispatch out through Postfix channels using your defined verified identity rules
mail -a "Content-Type: text/html; charset=UTF-8" \
     -s "$COMMENT Bitfocus Companion & Watchdog Active Logs" \
     -r "watchdog <$ALERT_EMAIL>" \
     "$ALERT_EMAIL" < "$REPORT_FILE"

# Safe footprint cleanup
rm -f "$REPORT_FILE"
