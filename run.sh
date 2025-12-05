#!/bin/bash

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
cleanup_on_failure() {
    # If JOB_SUCCESS is 1, the script finished successfully, skip cleanup.
    if [ $JOB_SUCCESS -eq 1 ]; then
        echo "Script finished successfully. No cloned volume cleanup required."
        return 0
    fi

    echo "================================================================"
    echo "CRITICAL FAILURE DETECTED! Initiating volume rollback and deletion..."
    echo "================================================================"

      # --- INSERTED BLOCK: Shutdown LPAR ---
    LPAR_STATUS=$(ibmcloud pi instance get "$LPAR_NAME" --json | jq -r '.status')
    if [[ "$LPAR_STATUS" == "ACTIVE" || "$LPAR_STATUS" == "WARNING" ]]; then
        echo "LPAR $LPAR_NAME is $LPAR_STATUS. Initiating immediate shutdown before volume cleanup."
        
        # Command to shut down the LPAR (Immediate shutdown corresponds to 'stop' action)
        ibmcloud pi instance action "$LPAR_NAME" -o stop || {
             echo "Warning: Failed to initiate LPAR stop. Continuing cleanup, manual LPAR shutdown may be required."
        }
        
        # Poll and wait for LPAR to reach SHUTOFF state (using logic similar to Step 12)
        echo "Waiting for LPAR $LPAR_NAME to reach SHUTOFF status..."
        while true; do
            LPAR_STATUS=$(ibmcloud pi instance get "$LPAR_NAME" --json | jq -r '.status')
            if [[ "$LPAR_STATUS" == "SHUTOFF" || "$LPAR_STATUS" == "ERROR" ]]; then
                echo "LPAR $LPAR_NAME is now $LPAR_STATUS. Ready for volume detach."
                break
            fi
            echo "$LPAR_NAME status: $LPAR_STATUS. Waiting 30 seconds."
            sleep 30
        done
    fi
    # --- END OF SHUTDOWN BLOCK ---

    # 1. DELETING SNAPSHOT 

    if [ ! -z "$SOURCE_SNAPSHOT_ID" ]; then
    echo "Attempting to delete clone source snapshot: $SOURCE_SNAPSHOT_ID"
    # The appropriate command used here requires the unique Snapshot ID [3]
    ibmcloud pi instance snapshot delete "$SOURCE_SNAPSHOT_ID" || {
         echo "Warning: Failed to delete snapshot $SOURCE_SNAPSHOT_ID. MANUAL CLEANUP REQUIRED."
    }
    echo "Snapshot $SOURCE_SNAPSHOT_ID deleted."
    echo "Pausing for 20 seconds to allow asynchronous snapshot cleanup..."
    sleep 20
fi 

    # 2. Prepare list of IDs for cleanup. This relies on the global variables set in Step 5.

    ALL_CLONE_IDS=""
    
     # Check if any clone IDs were captured (Boot OR Data)
    if [ ! -z "$CLONE_BOOT_ID" ] || [ ! -z "$CLONE_DATA_IDS" ]; then
        
        # Prepare list of IDs for cleanup.
        ALL_CLONE_IDS="$CLONE_BOOT_ID"
        if [ ! -z "$CLONE_DATA_IDS" ]; then
            # Concatenate IDs
            ALL_CLONE_IDS=$(echo "$ALL_CLONE_IDS,$CLONE_DATA_IDS" | sed 's/,\+/,/g; s/^,//; s/,$//')
        fi
        
        echo "Tracked Cloned Volumes for Deletion: $ALL_CLONE_IDS"

        # 3. ATTEMPT DETACHMENT 
        # Use the bulk-detach command, available since CLI v1.3.0 
        echo "Attempting bulk detachment of volumes from LPAR '$LPAR_NAME'..."
        ibmcloud pi instance volume bulk-detach "$LPAR_NAME" --volumes "$ALL_CLONE_IDS" 2>/dev/null && 
        echo "Bulk detachment request accepted." || 
        echo "Warning: Detachment attempt failed or volumes were not attached."
        
        # Pause after asynchronous detachment request
        sleep 30 

            # --- INSERTED BLOCK: Synchronize Detachment Status (Wait for volumes to be detached) ---

    echo "--- Step 3.5: Synchronizing Detachment Status ---"
    
    # Define max wait time (e.g., 5 minutes) and polling interval
    MAX_WAIT=300 
    POLL_INTERVAL=15
    CURRENT_WAIT=0
    
    LPAR_ID="$LPAR_NAME" # Use the LPAR identifier for querying attached volumes
    
    while [ $CURRENT_WAIT -lt $MAX_WAIT ]; do
        
        echo "Polling LPAR $LPAR_ID for attached volumes..."

        # Action: List all volumes currently attached to the LPAR and extract only the volume IDs [3, 4]
        # We redirect stderr (2>/dev/null) in case of minor API hiccups during polling
        ATTACHED_IDS_JSON=$(ibmcloud pi instance volume list "$LPAR_ID" --json 2>/dev/null)

        # Use jq to extract volume IDs from the attached list
        ATTACHED_IDS=$(echo "$ATTACHED_IDS_JSON" | jq -r '.volumes[].volumeID')

        # Convert the CSV list of target CLONE IDs into a space-separated string for iteration
        CLONE_IDS_LIST=$(echo "$ALL_CLONE_IDS" | tr ',' ' ')
        
        ATTACHED_CLONES=""
        DETACHMENT_PENDING=0
        
        # Check if any of the target cloned IDs are still present in the currently attached list
        for CLONE_ID in $CLONE_IDS_LIST; do
            if echo "$ATTACHED_IDS" | grep -q "$CLONE_ID"; then
                ATTACHED_CLONES="$ATTACHED_CLONES $CLONE_ID"
                DETACHMENT_PENDING=1
            fi
        done
        
        if [ $DETACHMENT_PENDING -eq 0 ]; then
            echo "SUCCESS: All cloned volumes are successfully detached. Proceeding to deletion."
            break # Exit the polling loop, ready for deletion.
        else
            echo "Detachment pending for cloned volumes: $ATTACHED_CLONES. Waiting $POLL_INTERVAL seconds. Elapsed time: $CURRENT_WAIT/$MAX_WAIT seconds."
            sleep $POLL_INTERVAL
            CURRENT_WAIT=$((CURRENT_WAIT + $POLL_INTERVAL))
        fi
    done
    
    # Critical Final Check: If the loop exited due to timeout, flag a failure.
    if [ $CURRENT_WAIT -ge $MAX_WAIT ]; then
        echo "FATAL ERROR: Timeout reached ($MAX_WAIT seconds). Cloned volumes are still attached to LPAR $LPAR_ID. Manual cleanup required."
        exit 1 # Exit with failure code, preventing the bulk-delete command which would fail anyway.
    fi

    # --- END OF INSERTED BLOCK ---
    
        # 4. ATTEMPT DELETION (Stops charges)
        # Use the bulk-delete command, available since CLI v1.3.0 
        echo "Attempting permanent bulk deletion of cloned volumes..."
        ibmcloud pi volume bulk-delete --volumes "$ALL_CLONE_IDS" || { 
            # Critical step failed: Report manual cleanup required and exit.
            echo "FATAL ERROR: Failed to delete one or more cloned volumes. MANUAL CLEANUP REQUIRED for IDs: $ALL_CLONE_IDS"
            exit 1
        }
        echo "Cloned volumes deleted successfully."
        
    else
        # If no boot or data IDs were found, skip cleanup entirely.
        echo "No valid cloned Volume IDs found (failure occurred before cloning was tracked). No deletion required."
    fi


}

# =============================================================
# 2b. Helper Function for Waiting for Asynchronous Clone Tasks
# (Volume cloning is an asynchronous operation handled via a Clone Task ID)
# =============================================================

# Function definition to poll the status of an asynchronous PowerVS clone task.
function wait_for_job() {
    CLONE_TASK_ID=$1
    echo "Waiting for asynchronous clone task ID: $CLONE_TASK_ID to complete..."
    
    # Loop continuously to check job status until completion or failure.
    while true; do
        # Use ibmcloud pi volume clone-async get to retrieve the clone task details. 
        # This is required for asynchronous volume clone requests (CLI v1.3.0 and newer) 
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
# 2c: TRAP ACTIVATION
# =======================================================================

# Activate the cleanup function upon any command failure (ERR) or script exit (EXIT)
trap 'cleanup_on_failure' ERR EXIT


# -------------------------
# 3. Initialization and Targeting
# -------------------------

echo "--- Secure Authentication and Targeting PowerVS Workspace ---"

ibmcloud login --apikey $API_KEY -r $REGION || { echo "ERROR: IBM Cloud login failed."; exit 1; }
ibmcloud target -g $RESOURCE_GROP_NAME || { echo "ERROR: Failed to target resource group."; exit 1; }
ibmcloud pi ws target $PVS_CRN || { echo "ERROR: Failed to target PowerVS workspace $PVS_CRN."; exit 1; }
echo "Successfully targeted workspace."

echo "Successfully targeted workspace."


# =============================================================
# 4: Perform the Snapshot Operation on Primary LPAR
# =============================================================

# 1. Generate the unique snapshot name down to the minute (Year, Month, Day, Hour, Minute).
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

echo "--- Step 3: Snapshot is available for use ---"



# =============================================================
# 5: Dynamically Discover the Latest Snapshot ID
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
# 6: Discover Source Volume IDs from the Snapshot
# =============================================================
echo "--- Discovering Source Volume IDs from Snapshot: $SOURCE_SNAPSHOT_ID ---"

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
# 7. Classify Source Volumes (Boot vs. Data)
# =============================================================

# Iterate through each discovered Source Volume ID
for VOL_ID in $SOURCE_VOLUME_IDS; do
    # Get detailed information for the live volume ID to check the bootable flag [1].
    VOLUME_DETAIL=$(ibmcloud pi volume get "$VOL_ID" --json 2>/dev/null)

    if [ $? -eq 0 ]; then
        # Check if the volume is explicitly marked as bootable=true [1].
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
# 8: Create Volume Clones from the Discovered Source Volumes
# =============================================================

echo "--- Step 5: Initiating volume cloning of all source volumes ---"

# CRITICAL FIX: The ibmcloud pi volume clone-async create command requires comma-separated IDs.
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

echo "--- Step 6: Waiting for asynchronous clone task completion ---"

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

echo "--- Step 7: Discovery Retry Loop (Waiting for API Synchronization) ---"

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


# --- CRITICAL INSERTION: API SYNCHRONIZATION PAUSE ---
echo "=========================================="
echo "Wait 2 minutes to allow cloned volumes to synchronize with the PVS API"
sleep 2m # Use 'sleep 120' or 'sleep 2m' (2 minutes)
echo "=========================================="

# =============================================================
# 8: Classify the Newly Cloned Volumes (Boot vs. Data)
# =============================================================

echo "--- Step 8: Classifying newly cloned volumes ---"
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

# Script is now ready to use $CLONE_BOOT_ID for the --boot-volume flag 
# and $CLONE_DATA_IDS for the --volumes flag in the instance volume attach command.

# =============================================================
# 9: Attach Cloned Volumes to the Empty LPAR
# =============================================================

echo "--- Retrieving current UUID for LPAR: $LPAR_NAME ---"  # Eliminates cached UUID for previously used LPAR of the same name.

# Command: ibmcloud pi instance list --json lists all instances.
# The JSON output is piped to jq to filter by name and extract the current instance ID.
# .pvmInstances[] is the array containing the instances in the list output.
LPAR_ID=$(ibmcloud pi instance list --json 2>/dev/null | \
          jq -r ".pvmInstances[] | select(.name == \"$LPAR_NAME\") | .id")

# Check if the ID was successfully retrieved and is not empty
if [[ -z "$LPAR_ID" ]]; then
    echo "FATAL ERROR: Could not find an active PVM Instance named '$LPAR_NAME' in the current workspace."
    echo "Action aborted. Please verify the instance status using 'ibmcloud pi instance list'."
    exit 1
else
    echo "SUCCESS: LPAR Name '$LPAR_NAME' successfully resolved to current UUID: $LPAR_ID"
    echo "The script will now use this UUID for subsequent operations."
fi


# Define the Instance ID (use UUID if possible)
# Placeholder: Use LPAR_ID if retrieved, otherwise fallback to LPAR_NAME
INSTANCE_IDENTIFIER="${LPAR_ID:-$LPAR_NAME}" 

# Construct the full attachment command
ATTACH_CMD="ibmcloud pi instance volume attach $INSTANCE_IDENTIFIER \
    --boot-volume $CLONE_BOOT_ID \
    --volumes $CLONE_DATA_IDS"

if [ ! -z "$CLONE_DATA_IDS" ]; then
    ATTACH_CMD="$ATTACH_CMD --volumes $CLONE_DATA_IDS"
    echo "Attaching boot volume ($CLONE_BOOT_ID) and data volumes ($CLONE_DATA_IDS) to $INSTANCE_IDENTIFIER."
else
    echo "Attaching only the boot volume ($CLONE_BOOT_ID) to $INSTANCE_IDENTIFIER."
fi


# Execute the asynchronous attachment command
$ATTACH_CMD || { 
    echo "FATAL ERROR: Failed to execute volume attachment command immediately. Exiting."
    exit 1
}

echo "Volume attachment request accepted by the API."

# --- MANDATORY WAIT TO ALLOW ASYNCHRONOUS STORAGE OPERATION TO COMPLETE ---
# Adjust this value based on volume size and environment latency. 180 seconds (3 minutes) 
# is a safer starting point for complex storage operations than zero delay.

MANDATORY_WAIT_SECONDS=180
echo "Waiting a mandatory ${MANDATORY_WAIT_SECONDS} seconds for asynchronous storage attachment..."
sleep $MANDATORY_WAIT_SECONDS


# =============================================================
# 10: Dynamic Polling and Status Verification
# =============================================================

LPAR_NAME="$INSTANCE_IDENTIFIER" # Use the identifier for messaging
POLL_INTERVAL=90        # Check status every 90 seconds
EXPECTED_STATUS="SHUTOFF"
ERROR_STATUS_1="ERROR"
ERROR_STATUS_2="FAILED"
CURRENT_STATUS=""

echo "--- Dynamic Polling started: Verifying LPAR status stability after attachment (Checking every ${POLL_INTERVAL} seconds) ---"

while true; do
    
    # Retrieve the current status of the LPAR.
    STATUS_JSON=$(ibmcloud pi instance get "$LPAR_NAME" --json 2>/dev/null)
    
    # Extract the status field
    CURRENT_STATUS=$(echo "$STATUS_JSON" | jq -r '.status' | tr '[:lower:]' '[:upper:]' | tr -d '[:space:].')

    # --- 1. Success Check ---
    if [[ "$CURRENT_STATUS" == "$EXPECTED_STATUS" ]]; then
        # The mandatory wait should ensure the system is stable now.
        echo "SUCCESS: Instance $LPAR_NAME is now in status $CURRENT_STATUS. Volume attachment verified complete and stable."
        break  # Exit the while loop to proceed to the next step
        
    # --- 2. Error Checks ---
    elif [[ "$CURRENT_STATUS" == "$ERROR_STATUS_1" || "$CURRENT_STATUS" == "$ERROR_STATUS_2" ]]; then
        echo "FATAL ERROR: Instance status is $CURRENT_STATUS. Volume attachment failed. Exiting script."
        exit 1
        
    elif [[ -z "$CURRENT_STATUS" || "$CURRENT_STATUS" == "NULL" ]]; then
        echo "Warning: Instance status temporarily unavailable or NULL. Waiting ${POLL_INTERVAL} seconds..."
        sleep $POLL_INTERVAL
        
    # --- 3. Waiting/In Progress ---
    else
        # Handles any unexpected transient states if the LPAR briefly left SHUTOFF
        echo "Instance status: $CURRENT_STATUS. Waiting for stable target status $EXPECTED_STATUS. Waiting ${POLL_INTERVAL} seconds..."
        sleep $POLL_INTERVAL
    fi
done

echo "--- Proceeding to LPAR boot configuration and start ---"

# =============================================================
# 11. Setting LPAR Boot Mode to Normal and Initializing Startup
# =============================================================

# --- Start the LPAR (Only runs after polling successfully breaks the loop) ---
echo "--- Setting LPAR $LPAR_NAME to Boot in NORMAL Mode ---"

# 1. Configure the Boot Mode and Operating Mode for the IBM i instance
# Boot Mode 'a' uses copy A of the Licensed Internal Code.
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
# 12: Verify LPAR Status is Active
# =============================================================
echo "--- Checking LPAR status ---"

while true; do
    # Action: Get the status of the virtual server instance
    LPAR_STATUS=$(ibmcloud pi instance get "$LPAR_NAME" --json | jq -r '.status')
    
    if [[ "$LPAR_STATUS" == "ACTIVE" ]]; then
        echo "SUCCESS: LPAR $LPAR_NAME is now ACTIVE from PVS API perspective."
        echo "Automation workflow successfully completed."
        # This exits the entire script/shell with a success code (0), preventing cleanup mechanisms.
        exit 0 
        
    elif [[ "$LPAR_STATUS" == "ERROR" ]]; then
        echo "Error: LPAR $LPAR_NAME entered ERROR state. Pausing for 45 seconds before re-checking to ensure state is permanent."

        sleep 45   #Pause for 45 seconds

            # Second immediate check
        LPAR_STATUS_RECHECK=$(ibmcloud pi instance get "$LPAR_NAME" --json | jq -r '.status')
        
        if [[ "$LPAR_STATUS_RECHECK" == "ERROR" ]]; then
            # If it's still ERROR after the delay, treat it as terminal failure.
            echo "FATAL ERROR: LPAR $LPAR_NAME confirmed ERROR state after 45s delay. Aborting."
            exit 1 # Abort with failure code
        else
            # Status recovered, continue polling
            echo "LPAR $LPAR_NAME status recovered to $LPAR_STATUS_RECHECK. Resuming main polling loop."
        fi
        
    else
        # Handles transient states like SHUTOFF, WARNING, or BUILDING
        echo "$LPAR_NAME status: $LPAR_STATUS. Waiting 60 seconds."
        sleep 60
    fi
done
