#!/bin/bash

echo "[SNAP-ATTACH] ==============================="
echo "[SNAP-ATTACH] Job Started"
echo "[SNAP-ATTACH] Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "[SNAP-ATTACH] ==============================="




echo "=== IBMi Snapshot Restore and Boot Script ==="

# -------------------------
# 1a. Environment Variables
# -------------------------

API_KEY="${IBMCLOUD_API_KEY}"    # IAM API Key stored in Code Engine Secret
REGION="us-south"                # IBM Cloud Region
RESOURCE_GROP_NAME="Default"     # Targeted Resource Group
PVS_CRN="crn:v1:bluemix:public:power-iaas:dal10:a/21d74dd4fe814dfca20570bbb93cdbff:cc84ef2f-babc-439f-8594-571ecfcbe57a::" # Full PowerVS Workspace CRN
CLOUD_INSTANCE_ID="cc84ef2f-babc-439f-8594-571ecfcbe57a" # PowerVS Workspace ID
LPAR_NAME="empty-ibmi-lpar"      # Name of the target LPAR
PRIMARY_LPAR="get-snapshot"      # Name of the source LPAR for snapshot
STORAGE_TIER="tier3"             # Must match the storage tier of the original volumes in the snapshot.
CLONE_NAME_PREFIX="CLONE-RESTORE-$(date +"%Y%m%d%H%M")"  # Unique prefix for the new cloned volumes, excluding seconds (%S)

# -------------------------
# 1B. Dynamic Control Variables (Initialized for Cleanup Tracking)
# -------------------------

CLONE_BOOT_ID=""      # Tracks the ID of the dynamically created boot volume
CLONE_DATA_IDS=""     # Tracks the comma-separated IDs of the dynamically created data volumes
SOURCE_SNAPSHOT_ID="" # Tracks the ID of the discovered source snapshot
SOURCE_VOLUME_IDS=""  # Tracks the comma-separated IDs of the volumes contained within the snapshot
CLONE_TASK_ID=""      # Tracks the ID of the asynchronous cloning job
JOB_SUCCESS=0         # 0 = Failure (Default), 1 = Success (Set at end of script)

# =======================================================================
# SECTION 2A: CLEANUP FUNCTION DEFINITION (The entire cleanup operation)
# =======================================================================

# This function is executed automatically upon any script error (ERR) or exit (EXIT).
# =======================================================================
# CLEANUP FUNCTION — NO SNAPSHOT REMOVAL
# =======================================================================

cleanup_on_failure() {
    # Ensure cleanup executes only once
    trap - ERR EXIT

    if [[ $JOB_SUCCESS -eq 1 ]]; then
        echo "[SNAP-ATTACH] Job finished successfully — no cleanup needed"
        return 0
    fi

    echo ""
    echo "================================================================================="
    echo "[CLEANUP] FAILURE DETECTED — BEGINNING SAFE CLEANUP OPERATIONS"
    echo "================================================================================="

    #
    # STEP 1 — Shutdown LPAR safely IF it exists
    #
    echo "[CLEANUP] Checking whether LPAR exists..."
    LPAR_JSON=$(ibmcloud pi instance get "$LPAR_NAME" --json 2>/dev/null || true)

    LPAR_EXISTS=$(echo "$LPAR_JSON" | jq -r '.pvmInstanceID // empty')

    if [[ -n "$LPAR_EXISTS" ]]; then
        STATUS=$(echo "$LPAR_JSON" | jq -r '.status')
        echo "[CLEANUP] Found active LPAR ($LPAR_NAME) with status=$STATUS"

        if [[ "$STATUS" != "SHUTOFF" ]]; then
            echo "[CLEANUP] Attempting shutdown..."
            ibmcloud pi instance action "$LPAR_NAME" --operation stop >/dev/null 2>&1 || true
        fi

        echo "[CLEANUP] Waiting for shutdown confirmation (max 2 minutes)"
        for ((i=0; i<12; i++)); do
            STATUS=$(ibmcloud pi instance get "$LPAR_NAME" --json 2>/dev/null | jq -r '.status' || true)
            if [[ "$STATUS" == "SHUTOFF" || "$STATUS" == "ERROR" ]]; then
                echo "[CLEANUP] LPAR shutdown confirmed"
                break
            fi
            sleep 10
        done
    else
        echo "[CLEANUP] No active LPAR found — skipping shutdown"
    fi


    #
    # STEP 2 — NEVER DELETE SNAPSHOT
    #
    if [[ -n "$SOURCE_SNAPSHOT_ID" ]]; then
        echo "[CLEANUP] Snapshot ID [$SOURCE_SNAPSHOT_ID] will NOT be deleted"
        echo "[CLEANUP] Snapshot preserved for retry, analysis, or manual deploy"
    fi


    #
    # STEP 3 — Remove cloned volumes
    #
    if [[ -z "$CLONE_BOOT_ID" && -z "$CLONE_DATA_IDS" ]]; then
        echo "[CLEANUP] No cloned volumes exist — cleanup complete"
        return 0
    fi

    DELETE_LIST="$CLONE_BOOT_ID"
    [[ -n "$CLONE_DATA_IDS" ]] && DELETE_LIST="$DELETE_LIST,$CLONE_DATA_IDS"

    # Cleanup formatting
    DELETE_LIST=$(echo "$DELETE_LIST" | sed 's/,,/,/g' | sed 's/^,//' | sed 's/,$//')

    echo "[CLEANUP] Marked cloned volumes for removal:"
    echo "          $DELETE_LIST"


    #
    # STEP 3a — Detach volumes if needed
    #
    echo "[CLEANUP] Requesting bulk-detach..."
    ibmcloud pi instance volume bulk-detach "$LPAR_NAME" --volumes "$DELETE_LIST" >/dev/null 2>&1 || true

    echo "[CLEANUP] Waiting up to 5 minutes for detachment..."
    for ((i=0; i<20; i++)); do
        ATTACHED=$(ibmcloud pi instance volume list "$LPAR_NAME" --json 2>/dev/null | jq -r '.volumes[].volumeID' || true)

        STILL_PRESENT=false
        for VOL in ${DELETE_LIST//,/ }; do
            if echo "$ATTACHED" | grep -q "$VOL"; then
                STILL_PRESENT=true
            fi
        done

        if [[ "$STILL_PRESENT" == false ]]; then
            echo "[CLEANUP] All volumes detached"
            break
        fi

        sleep 15
    done


    #
    # STEP 3b — DELETE permanently
    #
    
    echo "[CLEANUP] Deleting cloned volumes..."
    ibmcloud pi volume bulk-delete --volumes "$DELETE_LIST" >/dev/null 2>&1 || true

    echo "[CLEANUP] Verifying volume removal..."
    for VOL in ${DELETE_LIST//,/ }; do
        CHECK=$(ibmcloud pi volume get "$VOL" --json 2>/dev/null || true)
        if [[ "$CHECK" == "" || "$CHECK" == "null" ]]; then
            echo "[CLEANUP] Volume [$VOL] deleted"
        else
            echo "[WARNING] IBM API still reports volume [$VOL] exists — will require manual review"
        fi
    done

    echo ""
    echo "==================== CLEANUP COMPLETE ===================="
    echo ""
}



  

# =============================================================
# SECTION 2b. Helper Function for Waiting for Asynchronous Clone Tasks
# (Volume cloning is an asynchronous operation handled via a Clone Task ID)
# =============================================================

# Function definition to poll the status of an asynchronous PowerVS clone task.
function wait_for_job() {
    CLONE_TASK_ID=$1
    echo "Waiting for asynchronous clone task ID: $CLONE_TASK_ID to complete..."
    
    # Loop continuously to check job status until completion or failure.
    while true; do
        # Use ibmcloud pi volume clone-async get to retrieve the clone task details. 
        # This is required for asynchronous volume clone requests
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

# =======================================================================
# SECTION 2c: TRAP ACTIVATION
# =======================================================================

# Activate the cleanup function upon any command failure (ERR) or script exit (EXIT)
trap 'cleanup_on_failure' ERR EXIT


# -------------------------
# SECTION 3. Initialization and Targeting
# -------------------------

echo "--- Secure Authentication and Targeting PowerVS Workspace ---"

ibmcloud login --apikey $API_KEY -r $REGION || { echo "ERROR: IBM Cloud login failed."; exit 1; }
ibmcloud target -g $RESOURCE_GROP_NAME || { echo "ERROR: Failed to target resource group."; exit 1; }
ibmcloud pi ws target $PVS_CRN || { echo "ERROR: Failed to target PowerVS workspace $PVS_CRN."; exit 1; }
echo "Successfully targeted workspace."



# =============================================================
# SECTION 4: Perform the Snapshot Operation on Primary LPAR
# =============================================================

# Generate the unique snapshot name down to the minute (Year, Month, Day, Hour, Minute).
# This satisfies the requirement that snapshot names must be unique for your workspace.
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

# *** CRITICAL ASSIGNMENT STEP ***
SOURCE_SNAPSHOT_ID="$SNAPSHOT_ID"

# --- Step 2: Polling Loop (Check every 90 seconds) ---
POLL_INTERVAL=45
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
        # The snapshot status can become "Error"
        echo "FATAL ERROR: Snapshot failed. Status: $CURRENT_STATUS. Exiting script."
        exit 1
        
    elif [[ -z "$CURRENT_STATUS" || "$CURRENT_STATUS" == "NULL" ]]; then
        # Handle cases where status extraction fails temporarily
        echo "Warning: Status unavailable. Waiting ${POLL_INTERVAL} seconds..."
        
    else
        # Status is still in a transitional state (e.g., ADDING_VOLUMES_TO_GROUP, RESTORING)
        echo "Snapshot status: $CURRENT_STATUS. Waiting ${POLL_INTERVAL} seconds..."
        sleep $POLL_INTERVAL
    fi
done

echo "--- Step 2: Snapshot is available for use ---"



# =============================================================
# SECTION 5: Dynamically Discover the Latest Snapshot ID
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
# SECTION 6: Discover Source Volume IDs from the Snapshot
# =============================================================
echo "--- Step 4: Discovering Source Volume IDs from Snapshot: $SOURCE_SNAPSHOT_ID ---"

# Action: Retrieve the snapshot metadata in JSON format.
VOLUME_IDS_JSON=$(ibmcloud pi instance snapshot get $SOURCE_SNAPSHOT_ID --json)

if [ $? -ne 0 ]; then
    echo "Error retrieving snapshot details. Check snapshot ID: $SOURCE_SNAPSHOT_ID."
    exit 1
fi

# Action: Extract the list of original Volume IDs (UUIDs) as a space/newline-separated string.
SOURCE_VOLUME_IDS=$(echo "$VOLUME_IDS_JSON" | jq -r '.volumeSnapshots | keys[]')

if [ -z "$SOURCE_VOLUME_IDS" ]; then
    echo "Error: No Volume IDs found in the snapshot metadata. Aborting."
    exit 1
fi

# Initialize variables for classification
SOURCE_BOOT_ID=""
SOURCE_DATA_IDS=""
BOOT_FOUND=0

echo "All Source Volume IDs found. Checking individual volumes for Load Source designation..."

# =============================================================
# SECTION 7. Classify Source Volumes (Boot vs. Data)
# =============================================================

echo "--- Step 5: Classifying Source Volumes (Boot vs. Data) -----"

# Iterate through each discovered Source Volume ID
for VOL_ID in $SOURCE_VOLUME_IDS; do
    # Get detailed information for the live volume ID to check the bootable flag
    VOLUME_DETAIL=$(ibmcloud pi volume get "$VOL_ID" --json 2>/dev/null)

    if [ $? -eq 0 ]; then
        # Check if the volume is explicitly marked as bootable=true
        IS_BOOTABLE=$(echo "$VOLUME_DETAIL" | jq -r '.bootable')

        if [ "$IS_BOOTABLE" == "true" ]; then
            SOURCE_BOOT_ID="$VOL_ID"
            BOOT_FOUND=1
            echo "Identified Source Boot Volume ID: $SOURCE_BOOT_ID"
        else
            # Collect non-boot volumes (data volumes)
            SOURCE_DATA_IDS="$SOURCE_DATA_IDS,$VOL_ID"
        fi
    else
        echo "Warning: Failed to retrieve details for source volume ID: $VOL_ID. Skipping."
    fi
done

# Clean up the leading comma from the data volumes list, if necessary
SOURCE_DATA_IDS=${SOURCE_DATA_IDS#,}

if [ "$BOOT_FOUND" -ne 1 ]; then
    echo "FATAL ERROR: Could not identify the source boot volume among the volumes in the snapshot. Aborting."
    exit 1
fi

echo "Source Boot Volume ID: $SOURCE_BOOT_ID"
echo "Source Data Volume IDs (CSV): $SOURCE_DATA_IDS"

echo "--- Step 6: Calculating Total Volume Count"

# --- Pre-requisite: Dynamically Identify Expected Volume Count ---

# 1. Calculate the Boot Volume Count
BOOT_COUNT=0
if [ ! -z "$SOURCE_BOOT_ID" ]; then
    BOOT_COUNT=1
    echo "Counted 1 Source Boot Volume ID."
fi

# 2. Calculate the Data Volume Count
CLEANED_DATA_IDS=$(echo "$SOURCE_DATA_IDS" | tr ',' ' ' | tr '\n' ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

DATA_COUNT=0
if [ ! -z "$CLEANED_DATA_IDS" ]; then
    # Use 'wc -w' (word count) to count the number of IDs present.
    DATA_COUNT=$(echo "$CLEANED_DATA_IDS" | wc -w)
fi

echo "Counted $DATA_COUNT Source Data Volume ID(s)."

# 3. Calculate the Total Expected Volume Count
EXPECTED_VOLUME_COUNT=$((BOOT_COUNT + DATA_COUNT))

echo "--- Calculated Total Expected Volume Count: $EXPECTED_VOLUME_COUNT ---"


# =============================================================
# SECTION 8: Create Volume Clones from the Discovered Source Volumes
# =============================================================

echo "--- Step 7: Initiating volume cloning of all source volumes ---"

# The ibmcloud pi volume clone-async create command requires comma-separated IDs.
# We must convert the space/newline-separated $SOURCE_VOLUME_IDS string to comma-separated.
COMMA_SEPARATED_IDS=$(echo "$SOURCE_VOLUME_IDS" | tr ' ' ',')

# Re-target the workspace context (Ensures the PVS context remains active for the clone operation).
ibmcloud pi ws tg $PVS_CRN 

# Action: Use 'volume clone-async create' to initiate the clone task asynchronously.
CLONE_TASK_ID=$(ibmcloud pi volume clone-async create "$CLONE_NAME_PREFIX" \
    --volumes "$SOURCE_BOOT_ID,$COMMA_SEPARATED_IDS" \
    --target-tier $STORAGE_TIER \
    --json | jq -r '.cloneTaskID')


if [ -z "$CLONE_TASK_ID" ]; then
    echo "Error creating volume clone task. Aborting."
    exit 1
fi

echo "Clone task initiated. Task ID: $CLONE_TASK_ID"

echo "--- Step 7b: Waiting for asynchronous clone task completion ---"

# Check Clone Task Status: Monitor the status of the asynchronous task until it reports 'completed'.
while true; do
    # Use jq to extract the status from the JSON output of the task retrieval command.
    TASK_STATUS=$(ibmcloud pi volume clone-async get "$CLONE_TASK_ID" --json | jq -r '.status')
    
    if [ "$TASK_STATUS" == "completed" ]; then
        echo "Clone task $CLONE_TASK_ID completed successfully."
        break
    elif [ "$TASK_STATUS" == "failed" ] || [ "$TASK_STATUS" == "cancelled" ]; then
        echo "Error: Clone task $CLONE_TASK_ID failed with status: $TASK_STATUS. Aborting."
        exit 1
    else
        echo "Clone task status: $TASK_STATUS. Waiting $POLL_INTERVAL seconds..."
        sleep $POLL_INTERVAL
    fi
done

echo "--- Step 8: Discovery Retry Loop (Waiting for API Synchronization) ---"

# This loop addresses the observed latency between backend task completion and frontend API visibility.

# Define constants for the retry mechanism
MAX_RETRIES=20 # Total attempts (e.g., 20 attempts * 15 seconds = 5 minutes total wait)
RETRY_COUNT=0
POLL_INTERVAL=15 
FOUND_COUNT=0
NEW_CLONE_IDS="" # Initialize or clear discovery variable

while [[ $FOUND_COUNT -ne $EXPECTED_VOLUME_COUNT ]] && [[ $RETRY_COUNT -lt $MAX_RETRIES ]]
do
    RETRY_COUNT=$((RETRY_COUNT + 1))
    echo "Attempt $RETRY_COUNT of $MAX_RETRIES: Searching for volumes using prefix '$CLONE_NAME_PREFIX'..."

    # Action: Search volumes, filter by prefix, and extract IDs
    NEW_CLONE_IDS=$(ibmcloud pi volume list --long --json | \
        jq -r ".volumes[] | select(.name | contains(\"$CLONE_NAME_PREFIX\")) | .volumeID")

    FOUND_COUNT=$(echo "$NEW_CLONE_IDS" | wc -w) # Dynamic count check

    if [[ $FOUND_COUNT -ne $EXPECTED_VOLUME_COUNT ]]
    then
        # ===> FATAL EXIT CHECK <===
        if [[ $RETRY_COUNT -ge $MAX_RETRIES ]]; then
            echo "FATAL ERROR: Only $FOUND_COUNT out of $EXPECTED_VOLUME_COUNT volumes became visible after maximum retries ($MAX_RETRIES). Aborting due to API synchronization failure."
            exit 1
        fi
        
        # If max retries not hit, wait and try again
        echo "Found $FOUND_COUNT volume(s). Expected $EXPECTED_VOLUME_COUNT. Waiting $POLL_INTERVAL seconds..."
        sleep $POLL_INTERVAL
    fi
done

# Final check after the loop finishes
if [[ -z "$NEW_CLONE_IDS" ]]; then
    echo "CRITICAL ERROR: Failed to locate cloned volume IDs after waiting. API synchronization failed. Aborting."
    exit 1
fi

echo "Discovery successful! Located Volume IDs: $NEW_CLONE_IDS"


# --- API SYNCHRONIZATION PAUSE ---
echo "=========================================="
echo "Wait 2 minutes to allow cloned volumes to synchronize with the PVS API"
sleep 2m # Use 'sleep 120' or 'sleep 2m' (2 minutes)
echo "=========================================="

# =============================================================
# SECTION 9: Classify the Newly Cloned Volumes (Boot vs. Data)
# =============================================================

echo "--- Step 9: Classifying newly cloned volumes ---"
echo "#Action: DESIGNATE BOOT AND DATA VOLUMES by checking the explicit 'bootable' property."

# Initialize classification variables
CLONE_BOOT_ID=""
TEMP_DATA_IDS="" 
BOOT_FOUND_FLAG=0

# Loop through all newly discovered IDs (contained in the $NEW_CLONE_IDS variable)
for NEW_ID in $NEW_CLONE_IDS; do
    
    # Action: Fetch detailed information for the new clone volume using its ID
    # Command: ibmcloud pi volume get <VOLUME_ID> --json
    VOLUME_DETAIL=$(ibmcloud pi volume get "$NEW_ID" --json 2>/dev/null)

    # Check for retrieval success
    if [ $? -ne 0 ]; then
        echo "Warning: Failed to retrieve details for cloned volume ID: $NEW_ID. Skipping classification."
        continue
    fi
    
    # Action: Extract the 'bootable' status from the volume details
    # The bootable property returns 'true' or 'false'
    IS_BOOTABLE=$(echo "$VOLUME_DETAIL" | jq -r '.bootable')
    
    # Classification based on the volume attribute
    if [ "$IS_BOOTABLE" == "true" ]; then
        # This volume is explicitly flagged as the boot volume (Load Source)
        echo "Identified CLONE Boot Volume ID: $NEW_ID"
        CLONE_BOOT_ID="$NEW_ID"
        BOOT_FOUND_FLAG=1
    else
        # This is a data volume
        echo "Identified CLONE Data Volume ID: $NEW_ID"
        # Concatenate data IDs into a temporary list
        TEMP_DATA_IDS="$TEMP_DATA_IDS,$NEW_ID"
    fi
done

# Clean up and assign the final concatenated data volume list
# This removes any leading comma if the list is populated
CLONE_DATA_IDS=$(echo "$TEMP_DATA_IDS" | sed 's/,\+/,/g; s/^,//; s/,$//')

# CRITICAL FINAL CHECK: If no boot volume was found, abort the process.
if [ "$BOOT_FOUND_FLAG" -ne 1 ]; then
    echo "FATAL ERROR: Failed to identify the cloned boot volume ID using the 'bootable' property. Aborting."
    exit 1
fi

echo "Successfully designated CLONE_BOOT_ID: $CLONE_BOOT_ID"
echo "Successfully designated CLONE_DATA_IDS (CSV): $CLONE_DATA_IDS"


# =============================================================
# SECTION 10: Attach Cloned Volumes to the Empty LPAR
# =============================================================
echo "[SNAP-ATTACH] Resolving instance ID (UUID) ..."

INSTANCE_IDENTIFIER=$(ibmcloud pi instance list --json \
    | jq -r ".pvmInstances[] | select(.name == \"$LPAR_NAME\") | .id")

if [[ -z "$INSTANCE_IDENTIFIER" ]]; then
    echo "[FATAL] Instance ID could not be found for $LPAR_NAME"
    exit 1
fi

echo "[SNAP-ATTACH] Using instance ID: $INSTANCE_IDENTIFIER"

echo ""
echo "================ Attach Stage ================"
echo "[SNAP-ATTACH] BOOT VOLUME: $CLONE_BOOT_ID"
echo "[SNAP-ATTACH] DATA VOLUMES: $CLONE_DATA_IDS"
echo "=============================================="
echo ""

#
# STEP 1 — Attach BOOT FIRST
#
echo "[SNAP-ATTACH] Attaching BOOT volume first..."
ibmcloud pi instance volume attach "$INSTANCE_IDENTIFIER" \
    --volumes "$CLONE_BOOT_ID"
BOOT_EXIT=$?

if [[ $BOOT_EXIT -ne 0 ]]; then
    echo "[ERROR] Boot attach failed — backend refused"
    exit 1
fi

echo "[SNAP-ATTACH] Boot volume attach accepted — waiting 60 seconds"
sleep 60


#
# STEP 2 — Attach DATA volumes only if available
#
if [[ -n "$CLONE_DATA_IDS" ]]; then
    echo "[SNAP-ATTACH] Attaching DATA volumes..."

    ibmcloud pi instance volume attach "$INSTANCE_IDENTIFIER" \
        --volumes "$CLONE_DATA_IDS"
    DATA_EXIT=$?

    if [[ $DATA_EXIT -ne 0 ]]; then
        echo "[ERROR] Data volume attach failed — backend refused"
        exit 1
    fi

    echo "[SNAP-ATTACH] Data attach accepted — syncing"
fi



# =============================================================
# WAIT UNTIL VOLUMES ARE ATTACHED BEFORE BOOT
# =============================================================

JSON=$(ibmcloud pi instance get "$INSTANCE_IDENTIFIER" --json 2>/dev/null)

# normalize null into []
VOL_LIST=$(echo "$JSON" | jq -r '(.volumes // []) | .[]? | .volumeID')

ATTACHED_BOOT=$(echo "$VOL_LIST" | grep "$CLONE_BOOT_ID" || true)

DATA_MATCH=true
if [[ -n "$CLONE_DATA_IDS" ]]; then
    DATA_MATCH=$(echo "$VOL_LIST" | grep "$CLONE_DATA_IDS" || true)
fi

echo ""
echo "[SNAP-ATTACH] Waiting for volumes to attach..."

MAX_WAIT=420   # 20 minutes — snapshot metadata can lag
INTERVAL=30
WAITED=0

while true; do
    JSON=$(ibmcloud pi instance get "$INSTANCE_IDENTIFIER" --json 2>/dev/null)

    VOL_LIST=$(echo "$JSON" \
        | jq -r '(.volumes // []) | .[]? | .volumeID')

    ATTACHED_BOOT=$(echo "$VOL_LIST" | grep "$CLONE_BOOT_ID" || true)

    DATA_MATCH=true
    if [[ -n "$CLONE_DATA_IDS" ]]; then
        DATA_MATCH=$(echo "$VOL_LIST" | grep "$CLONE_DATA_IDS" || true)
    fi

    if [[ -n "$ATTACHED_BOOT" && ( -z "$CLONE_DATA_IDS" || -n "$DATA_MATCH" ) ]]; then
        echo "[SNAP-ATTACH] Volumes now attached and visible to API"
        break
    fi

    if [[ $WAITED -ge $MAX_WAIT ]]; then
        echo "[FATAL] Volumes never reflected in API after $MAX_WAIT seconds"
        echo "They might actually be attached — investigate manually"
        exit 22
    fi

    echo "[SNAP-ATTACH] Volumes not ready yet...checking again"
    sleep $INTERVAL
    WAITED=$((WAITED+INTERVAL))
done




# =============================================================
# BOOT INSTANCE SAFELY
# =============================================================

echo "[SNAP-ATTACH] Configuring NORMAL boot mode..."

ibmcloud pi instance operation "$INSTANCE_IDENTIFIER" \
    --operation-type boot \
    --boot-mode a \
    --boot-operating-mode normal || {
    echo "[FATAL] Failed to set boot mode"
    exit 1
}

echo "[SNAP-ATTACH] Starting instance..."

ibmcloud pi instance action "$INSTANCE_IDENTIFIER" --operation start || {
    echo "[FATAL] Failed to request LPAR start"
    exit 1
}


# =============================================================
# WAIT FOR ACTIVE STATE
# =============================================================

echo "[SNAP-ATTACH] Waiting for LPAR to go ACTIVE..."

MAX_BOOT_WAIT=1200 # 20 minutes
BOOT_WAITED=0
INTERVAL=30

while true; do
    STATUS=$(ibmcloud pi instance get "$INSTANCE_IDENTIFIER" --json | jq -r '.status')

    if [[ "$STATUS" == "ACTIVE" ]]; then
        echo "[SNAP-ATTACH] SUCCESS — LPAR is ACTIVE"
        JOB_SUCCESS=1
        break
    fi

    if [[ "$STATUS" == "ERROR" ]]; then
        echo "[FATAL] LPAR entered ERROR state"
        exit 1
    fi

    if [[ $BOOT_WAITED -ge $MAX_BOOT_WAIT ]]; then
        echo "[FATAL] LPAR failed to reach ACTIVE"
        exit 1
    fi

    echo "[SNAP-ATTACH] Status = $STATUS — waiting..."
    sleep $INTERVAL
    BOOT_WAITED=$((BOOT_WAITED+INTERVAL))
done

echo "--- Proceeding to LPAR boot configuration and start ---"

# =============================================================
# SECTION 12. Setting LPAR Boot Mode to Normal and Initializing Startup
# =============================================================

echo "--- Step 11: Setting LPAR $LPAR_NAME to Boot in NORMAL Mode and Initializing Start ---"

# 1. Configure the Boot Mode and Operating Mode for the IBM i instance
# Boot Mode 'a' uses copy A of the Licensed Internal Code.
# Boot Mode Normal is an unattended IPL
ibmcloud pi instance operation "$LPAR_NAME" \
    --operation-type boot \
    --boot-mode a \
    --boot-operating-mode normal || {
    echo "FATAL ERROR: Failed to configure IBM i boot operation."
    exit 1
}

# 2. Initiate the LPAR Start operation (This executes the power-on)
# The action command performs an operation (start) on a PVM server instance.
ibmcloud pi instance action "$LPAR_NAME" --operation start || { 
    echo "FATAL ERROR: Failed to initiate LPAR start command. Aborting."
    exit 1 
}

echo "LPAR '$LPAR_NAME' start initiated successfully in NORMAL mode."

# =============================================================
# SECTION 13: Verify LPAR Status is Active and (optionally) trigger snapshot-cleanup
# =============================================================

echo "--- Step 12: Checking LPAR status ---"

while true; do
    # Action: Get the status of the LPAR
    LPAR_STATUS=$(ibmcloud pi instance get "$LPAR_NAME" --json | jq -r '.status')
    
    if [[ "$LPAR_STATUS" == "ACTIVE" ]]; then
        echo "SUCCESS: LPAR $LPAR_NAME is now ACTIVE from PVS API perspective."
        echo "Automation workflow successfully completed."

        # Mark overall job success so rollback will NOT run
        JOB_SUCCESS=1

        echo ""
        echo "--------------------------------------------"
        echo "Restore & Boot Summary:"
        echo "--------------------------------------------"
        echo "Snapshot Taken            : Yes"
        echo "Volumes Cloned            : Yes"
        echo "Volumes Attached to LPAR  : Yes"
        echo "LPAR Boot Mode            : NORMAL (Mode A)"
        echo "LPAR Final Status         : ACTIVE"
        echo "--------------------------------------------"
        echo ""

        echo "--- Evaluating whether to trigger cleanup job ---"

        if [[ "${RUN_CLEANUP_JOB:-No}" == "Yes" ]]; then            
            echo "Switching Code Engine context to IBMi project"

            ibmcloud ce project select -n IBMi > /dev/null 2>&1 || {
                echo "ERROR: Unable to select cleanup project IBMi"
                exit 1
            }

            echo "Submitting Code Engine cleanup job: snapshot-cleanup"

            NEXT_RUN=$(ibmcloud ce jobrun submit --job snapshot-cleanup --output json | jq -r '.name')

            echo "Triggered cleanup instance: $NEXT_RUN"
        else
            echo "Skipping cleanup stage; RUN_CLEANUP_JOB is NOT set to Yes."
        fi
        
        echo "[SNAP-ATTACH] Job Completed Successfully"
        echo "[SNAP-ATTACH] Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"

        exit 0 
    elif [[ "$LPAR_STATUS" == "ERROR" ]]; then
        echo "Error: LPAR $LPAR_NAME entered ERROR state. Pausing for 120 seconds before re-checking to ensure state is permanent."

        sleep 120

        LPAR_STATUS_RECHECK=$(ibmcloud pi instance get "$LPAR_NAME" --json | jq -r '.status')
        
        if [[ "$LPAR_STATUS_RECHECK" == "ERROR" ]]; then
            echo "FATAL ERROR: LPAR $LPAR_NAME confirmed ERROR after retry. Exiting and triggering rollback."
            exit 1 
        else
            echo "LPAR recovered to $LPAR_STATUS_RECHECK—continuing monitoring."
        fi
    else
        echo "$LPAR_NAME status: $LPAR_STATUS. Waiting 60 seconds."
        sleep 60
    fi

done

