#!/bin/bash

echo "=== IBMi Snapshot Restore and Boot Script ==="

# -------------------------
# 1. Environment Variables
# -------------------------

API_KEY="${IBMCLOUD_API_KEY}"       # IAM API Key stored in Code Engine Secret
PVS_CRN="crn:v1:bluemix:public:power-iaas:dal10:a/21d74dd4fe814dfca20570bbb93cdbff:cc84ef2f-babc-439f-8594-571ecfcbe57a::" # Full PowerVS Workspace CRN
CLOUD_INSTANCE_ID="cc84ef2f-babc-439f-8594-571ecfcbe57a" # PowerVS Workspace ID
LPAR_NAME="empty-ibmi-lpar"            # Name of the target LPAR: "empty-ibmi-lpar"
REGION="us-south"
PRIMARY_LPAR="get-snapshot"


# Storage Tier. Must match the storage tier of the original volumes in the snapshot.
STORAGE_TIER="tier3"
# Corrected unique prefix for the new cloned volumes, excluding seconds (%S)
CLONE_NAME_PREFIX="CLONE-RESTORE-$(date +"%Y%m%d%H%M")"


# -------------------------
# 2. Initialization and Targeting
# -------------------------

echo "--- Step 1: Secure Authentication and Workspace Targeting ---"

# 1. Log in to IBM Cloud using an API Key and target the correct Region.
# The API key approach is ideal for automated deployment operations [1].
ibmcloud login --apikey $API_KEY -r $REGION || { 
    echo "ERROR: IBM Cloud login failed. Please verify API key and region."
    exit 1 
}

# 2. Target the specific Power Virtual Server workspace using its CRN.
# This explicitly sets the context required for subsequent 'ibmcloud pi' commands.
ibmcloud pi ws target $PVS_CRN || { 
    echo "ERROR: Failed to target PowerVS workspace $PVS_CRN."
    exit 1 
}

echo "Successfully targeted workspace."

# =============================================================
# Helper Function for Waiting for Asynchronous Clone Tasks
# (Volume cloning is an asynchronous operation handled via a Clone Task ID)
# =============================================================

# Function definition to poll the status of an asynchronous PowerVS clone task.
function wait_for_job() {
    CLONE_TASK_ID=$1
    echo "Waiting for asynchronous clone task ID: $CLONE_TASK_ID to complete..."
    
    # Loop continuously to check job status until completion or failure.
    while true; do
        # Use ibmcloud pi volume clone-async get to retrieve the clone task details. 
        # This is required for asynchronous volume clone requests (CLI v1.3.0 and newer) [1, 2].
        STATUS=$(ibmcloud pi volume clone-async get $CLONE_TASK_ID --json | jq -r '.status')
        
        # Check if the job status indicates successful completion.
        if [[ "$STATUS" == "completed" ]]; then
            echo "Clone Task $CLONE_TASK_ID completed successfully."
            break
        # Check if the job status indicates failure.
        elif [[ "$STATUS" == "failed" ]]; then
            echo "Error: Clone Task $CLONE_TASK_ID failed. Aborting script."
            exit 1
        # If still pending, wait 30 seconds before polling again.
        else
            echo "Clone Task $CLONE_TASK_ID status: $STATUS. Waiting 30 seconds..."
            sleep 30
        fi
    done
}


# =============================================================
# STEP 3a: Perform the Snapshot Operation on Primary LPAR
# =============================================================

# 1. Generate the unique snapshot name down to the minute (Year, Month, Day, Hour, Minute).
# This satisfies the requirement that snapshot names must be unique for your workspace [4].
SNAPSHOT_NAME="TMP_SNAP_$(date +"%Y%m%d%H%M")"

echo "--- Step 1: Initiating Snapshot on LPAR: $PRIMARY_LPAR ---"
echo "Generated Snapshot Name: $SNAPSHOT_NAME"

# --- Step 1: Execute Snapshot Operation and Capture ID ---
echo "Creating Snapshot: $SNAPSHOT_NAME on LPAR: $PRIMARY_LPAR"
# Note: The command output must be captured in JSON format to extract the Snapshot ID.
SNAPSHOT_JSON_OUTPUT=$(ibmcloud pi instance snapshot create "$PRIMARY_LPAR" --name "$SNAPSHOT_NAME" --json) || { 
    echo "Error initiating snapshot." 
    exit 1 
}

# Use 'jq' to extract the unique Snapshot ID (assuming jq is installed)
# The output contains the unique ID required for subsequent 'get' commands.
SNAPSHOT_ID=$(echo "$SNAPSHOT_JSON_OUTPUT" | jq -r '.snapshotID')
echo "Snapshot initiated successfully. ID: $SNAPSHOT_ID"

# --- Step 2: Polling Loop (Check every 90 seconds) ---
POLL_INTERVAL=90
EXPECTED_STATUS="AVAILABLE"  # Standardized to uppercase for robust comparison
ERROR_STATUS="ERROR"
CURRENT_STATUS=""

echo "--- Polling started: Checking snapshot status every ${POLL_INTERVAL} seconds ---"

while true; do
    
    # Get the status using the captured Snapshot ID
    STATUS_JSON=$(ibmcloud pi instance snapshot get "$SNAPSHOT_ID" --json 2>/dev/null)
    
    # 1. Extract status using jq
    # 2. Convert status to uppercase (tr '[:lower:]' '[:upper:]')
    # 3. Trim whitespace/periods (tr -d '[:space:].')
    CURRENT_STATUS=$(echo "$STATUS_JSON" | jq -r '.status' | tr '[:lower:]' '[:upper:]' | tr -d '[:space:].')

    if [[ "$CURRENT_STATUS" == "$EXPECTED_STATUS" ]]; then
        echo "SUCCESS: Snapshot is now $CURRENT_STATUS. Proceeding to next step."
        break  # Exit the while loop
        
    elif [[ "$CURRENT_STATUS" == "$ERROR_STATUS" ]]; then
        # The snapshot status can become "Error" [1]
        echo "FATAL ERROR: Snapshot failed. Status: $CURRENT_STATUS. Exiting script."
        exit 1
        
    elif [[ -z "$CURRENT_STATUS" || "$CURRENT_STATUS" == "NULL" ]]; then
        # Handle cases where status extraction fails temporarily
        echo "Warning: Status unavailable. Waiting ${POLL_INTERVAL} seconds..."
        
    else
        # Status is still in a transitional state (e.g., ADDING_VOLUMES_TO_GROUP, RESTORING) [1]
        echo "Snapshot status: $CURRENT_STATUS. Waiting ${POLL_INTERVAL} seconds..."
        sleep $POLL_INTERVAL
    fi
done

echo "--- Step 3: Snapshot is available for use ---"



# =============================================================
# STEP 3b: Dynamically Discover the Latest Snapshot ID
# =============================================================

echo "--- Step 3: Discovering the latest Snapshot ID in the Workspace (Target LPAR: $LPAR_NAME) ---"

# Command: List all snapshots in the entire workspace in JSON format.
SNAPSHOT_LIST_JSON=$(ibmcloud pi instance snapshot list --json)

if [ $? -ne 0 ] || [ -z "$SNAPSHOT_LIST_JSON" ]; then
    echo "Error: Failed to retrieve **workspace snapshot list (targeting LPAR $LPAR_NAME)**. Aborting."
    exit 1
fi

# Action: Use 'jq' to parse the JSON list, sort the snapshots by their creationDate, 
# select the very last entry (the latest one), and extract its unique snapshotID.
LATEST_SNAPSHOT_ID=$(echo "$SNAPSHOT_LIST_JSON" | \
    jq -r '.snapshots | sort_by(.creationDate) | last .snapshotID')

if [ -z "$LATEST_SNAPSHOT_ID" ] || [ "$LATEST_SNAPSHOT_ID" = "null" ]; then
    echo "Error: Could not find any snapshots for instance $LPAR_NAME. Aborting."
    exit 1
fi

SOURCE_SNAPSHOT_ID="$LATEST_SNAPSHOT_ID"

echo "Latest Snapshot ID found: $SOURCE_SNAPSHOT_ID"


# =============================================================
# STEP 4: Discover Source Volume IDs from the Snapshot
# =============================================================
echo "--- Step 4: Discovering Source Volume IDs from Snapshot: $SOURCE_SNAPSHOT_ID ---"

# Action: Retrieve the snapshot metadata in JSON format.
# Correction 1: Removed $LPAR_NAME and the unnecessary --snapshot flag.
VOLUME_IDS_JSON=$(ibmcloud pi instance snapshot get $SOURCE_SNAPSHOT_ID --json)

if [ $? -ne 0 ]; then
    echo "Error retrieving snapshot details. Check snapshot ID/Name."
    exit 1
fi

# Action: Extract the list of original Volume IDs (the keys) and format them as a single comma-separated string.
# Correction 2 & 3: Corrected the input variable name and completed the missing 'jq' syntax.
SOURCE_VOLUME_IDS=$(echo "$VOLUME_IDS_JSON" | jq -r '.volumeSnapshots | keys | join(",")')

if [ -z "$SOURCE_VOLUME_IDS" ]; then
    echo "Error: No Volume IDs found in the snapshot metadata. Aborting."
    exit 1
fi

echo "Source Volume IDs found: $SOURCE_VOLUME_IDS"


# =============================================================
# STEP 5: Create Volume Clones from the Discovered Source Volumes
# =============================================================

echo "--- Step 5: Initiating volume cloning of all source volumes ---"

# --- DEBUGGING START ---
# Action: Enable verbose tracing to see the exact command executed and its error output (stderr).
set -x

# FIX: Re-target the workspace context (Ensures the PVS context remains active for the clone operation).
ibmcloud pi ws tg $PVS_CRN 
# ------------------------------------------------------------------------

# Action: Use 'volume clone-async create' to initiate the clone task asynchronously.
# The command 'ibmcloud pi volume clone-async create' asynchronously creates clone tasks whose status can be queried [1, 2].
CLONE_TASK_ID=$(ibmcloud pi volume clone-async create $CLONE_NAME_PREFIX \
    --volumes "$SOURCE_VOLUME_IDS" \
    --target-tier $STORAGE_TIER \
    --json | jq -r '.cloneTaskID')

    
# Action: Disable verbose tracing.
set +x
# --- DEBUGGING END ---

if [ -z "$CLONE_TASK_ID" ]; then
    echo "Error creating volume clone task. Aborting."
    exit 1
fi

echo "Clone task initiated. Task ID: $CLONE_TASK_ID"

echo "--- Step 6: Waiting for asynchronous clone task completion ---"

# Check Clone Task Status: Monitor the status of the asynchronous task until it reports 'completed'.
# The status of a clone request for the specified clone task ID can be queried using 'ibmcloud pi volume clone-async get' [3, 4].
while true; do
    # Use jq to extract the status from the JSON output of the task retrieval command.
    TASK_STATUS=$(ibmcloud pi volume clone-async get $CLONE_TASK_ID --json | jq -r '.status')
    
    if [ "$TASK_STATUS" == "completed" ]; then
        echo "Clone task $CLONE_TASK_ID completed successfully."
        break
    elif [ "$TASK_STATUS" == "failed" ] || [ "$TASK_STATUS" == "cancelled" ]; then
        echo "Error: Clone task $CLONE_TASK_ID failed with status: $TASK_STATUS. Aborting."
        exit 1
    else
        echo "Clone task status: $TASK_STATUS. Waiting 30 seconds..."
        sleep 30
    fi
done

echo "--- Step 7: Discovery Retry Loop (Waiting for API Synchronization) ---"

# This loop addresses the observed latency between backend task completion and frontend API visibility.
MAX_RETRIES=10
RETRY_COUNT=0
# Initialize variable to store the actual volume IDs (UUIDs)
NEW_CLONE_IDS=""

while [[ -z "$NEW_CLONE_IDS" ]] && [[ $RETRY_COUNT -lt $MAX_RETRIES ]]
do
    RETRY_COUNT=$((RETRY_COUNT + 1))
    echo "Attempt $RETRY_COUNT of $MAX_RETRIES: Searching for volumes using prefix '$CLONE_NAME_PREFIX'..."
    
    # Action: Search the full volume list and filter by the unique prefix, extracting the required Volume ID (UUID).
    NEW_CLONE_IDS=$(ibmcloud pi volume list --long --json | \
        jq -r ".volumes[] | select(.name | contains(\"$CLONE_NAME_PREFIX\")) | .volumeID")

    if [[ -z "$NEW_CLONE_IDS" ]]
    then
        # API cache has not updated yet. Wait 15 seconds before trying again.
        echo "Volumes not yet visible in the API inventory. Waiting 15 seconds..."
        sleep 15
    fi
done

# Final check after the loop finishes
if [[ -z "$NEW_CLONE_IDS" ]]; then
    echo "CRITICAL ERROR: Failed to locate cloned volume IDs after waiting 150 seconds. API synchronization failed. Aborting."
    exit 1
fi

echo "Discovery successful! Located Volume IDs: $NEW_CLONE_IDS"

# Action: Designate the Boot Volume and Data Volumes.
# ASSUMPTION: The first ID found is the boot volume (Load Source).
CLONE_BOOT_ID=$(echo "$NEW_CLONE_IDS" | head -n 1)
# Collect remaining IDs as data volumes, comma-separated list.
CLONE_DATA_IDS=$(echo "$NEW_CLONE_IDS" | tail -n +2 | tr '\n' ',' | sed 's/,$//')

echo "New Boot Volume ID (assumed): $CLONE_BOOT_ID"
echo "New Data Volume IDs: $CLONE_DATA_IDS"


# =============================================================
# STEP 6: Attach Cloned Volumes to the Empty LPAR
# =============================================================

# --- Re-target and LPAR Status Check Retry Loop ---

# IMPORTANT: Re-target the workspace to ensure CLI context is sound.
ibmcloud pi ws target "$PVS_CRN" || { echo "ERROR: Failed to re-target PowerVS workspace $PVS_CRN."; exit 1; }

# --- Configuration Variables (Adjust as needed) ---
# Assuming LPAR_NAME holds the instance identifier/name (e.g., "empty-ibmi-lpar")
LPAR_NAME="empty-ibmi-lpar" 
LPAR_ID="$LPAR_NAME" 

POLL_INTERVAL=90        # Check status every 90 seconds (adjust based on expected wait time)
EXPECTED_STATUS="SHUTOFF" # The required stable state after volume attachment completes.
ERROR_STATUS_1="ERROR"
ERROR_STATUS_2="FAILED"
CURRENT_STATUS=""

echo "--- Step 3: Dynamic Polling started: Waiting for instance $LPAR_NAME to finish volume operation and reach $EXPECTED_STATUS status (Checking every ${POLL_INTERVAL} seconds) ---"

while true; do
    
    # Use 'ibmcloud pi instance get' command to retrieve the current state of the VSI.
    # The --json flag is essential for parsing the output.
    STATUS_JSON=$(ibmcloud pi instance get "$LPAR_ID" --json 2>/dev/null)
    
    # Extract the '.status' field using 'jq', convert to uppercase, and strip whitespace.
    CURRENT_STATUS=$(echo "$STATUS_JSON" | jq -r '.status' | tr '[:lower:]' '[:upper:]' | tr -d '[:space:].')

    # --- 1. Success Check ---
    if [[ "$CURRENT_STATUS" == "$EXPECTED_STATUS" ]]; then
        echo "SUCCESS: Instance $LPAR_NAME is now in status $CURRENT_STATUS. Volume attachment confirmed complete."
        break  # Exit the while loop to proceed to the next step (LPAR start configuration)
        
    # --- 2. Error Checks ---
    elif [[ "$CURRENT_STATUS" == "$ERROR_STATUS_1" || "$CURRENT_STATUS" == "$ERROR_STATUS_2" ]]; then
        # This handles cases where the volume attachment itself failed, leaving the LPAR in an ERROR state.
        echo "FATAL ERROR: Instance status is $CURRENT_STATUS. The prior operation likely failed. Exiting script."
        exit 1
        
    elif [[ -z "$CURRENT_STATUS" || "$CURRENT_STATUS" == "NULL" ]]; then
        # Handle transient API issues or empty responses during the polling cycle.
        echo "Warning: Instance status temporarily unavailable or NULL. Waiting ${POLL_INTERVAL} seconds..."
        sleep $POLL_INTERVAL
        
    # --- 3. Waiting/In Progress ---
    else
        # This handles transient states like 'attaching_volume' or 'BUILDING'.
        echo "Instance status: $CURRENT_STATUS. Still waiting for target status $EXPECTED_STATUS. Waiting ${POLL_INTERVAL} seconds..."
        sleep $POLL_INTERVAL
    fi
done

echo "--- Proceeding to LPAR boot configuration and start ---"


# --- Step 3: Dynamic Polling Loop: Wait for Attachment Completion (Task State Clearance) ---

echo "Polling started: Waiting for instance $LPAR_NAME to clear task_state and reach $EXPECTED_STATUS status (Checking every ${POLL_INTERVAL} seconds)"

while true; do
    
    # Retrieve the current status of the instance [5, 6].
    STATUS_JSON=$(ibmcloud pi instance get "$LPAR_NAME" --json 2>/dev/null)
    
    # Extract status, convert to uppercase, and strip whitespace for robust comparison.
    CURRENT_STATUS=$(echo "$STATUS_JSON" | jq -r '.status' | tr '[:lower:]' '[:upper:]' | tr -d '[:space:].')

    if [[ "$CURRENT_STATUS" == "$EXPECTED_STATUS" ]]; then
        # The volume operation is complete and the instance is in the stable SHUTOFF state.
        echo "SUCCESS: Instance $LPAR_NAME is now in status $CURRENT_STATUS. Proceeding to start."
        break  # Exit the while loop to proceed to the next step
        
    elif [[ "$CURRENT_STATUS" == "$ERROR_STATUS_1" || "$CURRENT_STATUS" == "$ERROR_STATUS_2" ]]; then
        echo "FATAL ERROR: Instance status is $CURRENT_STATUS. The volume attachment or LPAR state has failed. Exiting script."
        exit 1
        
    elif [[ -z "$CURRENT_STATUS" || "$CURRENT_STATUS" == "NULL" ]]; then
        # Handle cases where status extraction fails temporarily
        echo "Warning: Instance status temporarily unavailable or NULL. Waiting ${POLL_INTERVAL} seconds..."
        sleep $POLL_INTERVAL
        
    else
        # Status is still transitional (e.g., ATTACHING_VOLUME, WARNING, etc.)
        echo "Instance status: $CURRENT_STATUS. Still waiting for target status $EXPECTED_STATUS. Waiting ${POLL_INTERVAL} seconds..."
        sleep $POLL_INTERVAL
    fi
done

# --- Step 4: Start the LPAR (Only runs after polling successfully breaks the loop) ---
echo "--- Step 4: Starting LPAR $LPAR_NAME in NORMAL mode (Mode A) ---"

# 1. Configure the Boot Mode and Operating Mode for the IBM i instance
# Boot Mode 'a' uses copy A of the Licensed Internal Code (LIC) [7].
ibmcloud pi instance operation "$LPAR_NAME" \
    --operation-type boot \
    --boot-mode a \
    --boot-operating-mode normal || {
    echo "FATAL ERROR: Failed to configure IBM i boot operation."
    exit 1
}

# 2. Initiate the LPAR Start operation (This executes the power-on)
# The action command performs an operation (start) on a PVM server instance [8, 9].
ibmcloud pi instance action "$LPAR_NAME" --operation start || { 
    echo "FATAL ERROR: Failed to initiate LPAR start command. Aborting."
    exit 1 
}

echo "LPAR '$LPAR_NAME' start initiated successfully in NORMAL mode."


# =============================================================
# STEP 8: Verify LPAR Status is Active
# =============================================================
echo "--- Step 8: Checking LPAR status ---"

while true; do
    LPAR_STATUS=$(ibmcloud pi instance get "$LPAR_NAME" --json | jq -r '.status')
    
    if [[ "$LPAR_STATUS" == "ACTIVE" ]]; then
        echo "SUCCESS: LPAR $LPAR_NAME is now ACTIVE."
        echo "Automation workflow complete. Monitor the LPAR console for the OS IPL sequence."
        break
    elif [[ "$LPAR_STATUS" == "ERROR" ]]; then
        echo "Error: LPAR $LPAR_NAME entered ERROR state after boot. Aborting."
        exit 1
    else
        echo "$LPAR_NAME status: $LPAR_STATUS. Waiting 30 seconds."
        sleep 30
    fi
done
