#!/bin/bash

echo "=== IBM i Snapshot Restore and Boot Script ==="

# -------------------------
# 1. Environment Variables
# -------------------------

API_KEY="${IBMCLOUD_API_KEY}"       # IAM API Key stored in Code Engine Secret
PVS_CRN="crn:v1:bluemix:public:power-iaas:dal10:a/21d74dd4fe814dfca20570bbb93cdbff:cc84ef2f-babc-439f-8594-571ecfcbe57a::" # Full PowerVS Workspace CRN
CLOUD_INSTANCE_ID="cc84ef2f-babc-439f-8594-571ecfcbe57a" # PowerVS Workspace ID
LPAR_NAME="empty-ibmi-lpar"            # Name of the target LPAR: "empty-ibmi-lpar"
REGION="us-south"

# Storage Tier. Must match the storage tier of the original volumes in the snapshot.
STORAGE_TIER="tier3"
# Unique prefix for the new cloned volumes
CLONE_NAME_PREFIX="CLONE-RESTORE-$(date +%Y%m%d%H%M%S)"


# -------------------------
# 2. Initialization and Targeting
# -------------------------

echo "--- Logging into IBM Cloud and Targeting PowerVS Workspace ---"

# Log in using the API key
ibmcloud login --apikey $API_KEY -r $REGION || { echo "ERROR: IBM Cloud login failed."; exit 1; }

#Target the Default Resource Group
# You would use the name or ID of the Default resource group here.
ibmcloud target -g Default || { echo "ERROR: Failed to target Default resource group."; exit 1; }


# Target the specific PowerVS workspace using the provided CRN [3, 4].
ibmcloud pi ws target $PVS_CRN || { echo "ERROR: Failed to target PowerVS workspace $PVS_CRN."; exit 1; }
echo "Successfully targeted workspace."


# =============================================================
# Helper Function for Waiting for Asynchronous Jobs
# =============================================================

function wait_for_job() {
    JOB_ID=$1
    echo "Waiting for asynchronous job ID: $JOB_ID to complete..."
    
    while true; do
        # Retrieve the job status using the CLI command and jq [5].
        STATUS=$(ibmcloud pi job get $JOB_ID --json | jq -r '.status')
        
        if [[ "$STATUS" == "completed" ]]; then
            echo "Job $JOB_ID completed successfully."
            break
        elif [[ "$STATUS" == "failed" ]]; then
            echo "Error: Job $JOB_ID failed. Aborting script."
            exit 1
        else
            echo "Job $JOB_ID status: $STATUS. Waiting 30 seconds..."
            sleep 30
        fi
    done
}


# =============================================================
# STEP 3: Dynamically Discover the Latest Snapshot ID
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

# Action: Use 'volume clone-async create' to initiate the clone task asynchronously [7-9].
CLONE_TASK_ID=$(ibmcloud pi volume clone-async create $CLONE_NAME_PREFIX \
    --volumes "$SOURCE_VOLUME_IDS" \
    --target-tier $STORAGE_TIER \
    --json | jq -r '.id')

    
# Action: Disable verbose tracing.
set +x
# --- DEBUGGING END ---

if [ -z "$CLONE_TASK_ID" ]; then
    echo "Error creating volume clone task. Aborting."
    exit 1
fi

# Action: Wait for the asynchronous cloning job to complete.
wait_for_job $CLONE_TASK_ID

# Action: Find the IDs of the newly created clone volumes using the unique name prefix.
NEW_CLONE_IDS=$(ibmcloud pi volume list --long --json | jq -r ".volumes[] | select(.name | startswith(\"$CLONE_NAME_PREFIX\")) | .volumeID")

if [ -z "$NEW_CLONE_IDS" ]; then
    echo "Error: Could not locate newly cloned volume IDs based on prefix $CLONE_NAME_PREFIX. Aborting."
    exit 1
fi

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
echo "--- Step 6: Attaching cloned volumes to $LPAR_NAME ---"

# IMPORTANT: The LPAR must be shut off for attachment to succeed [10-12].
# Check LPAR status and stop it if necessary (robustness check for "empty" instance).
STATUS=$(ibmcloud pi instance get $LPAR_NAME --json | jq -r '.status')
if [ "$STATUS" != "SHUTOFF" ]; then
    echo "LPAR status is $STATUS. Stopping instance for volume attachment."
    ibmcloud pi instance action $LPAR_NAME --operation immediate-shutdown || { echo "ERROR: Failed to stop LPAR."; exit 1; }
    sleep 30 # Allow time for status transition
fi

# Action: Attach the Load Source (Boot) volume using the --boot-volume flag [13-15].
# We build a single command line for all attachments.
ATTACH_CMD="ibmcloud pi instance volume attach $LPAR_NAME --boot-volume $CLONE_BOOT_ID"

if [ ! -z "$CLONE_DATA_IDS" ]; then
    # Action: Include additional data volumes if they exist.
    ATTACH_CMD="$ATTACH_CMD --volumes $CLONE_DATA_IDS"
fi

echo "Executing attach command: $ATTACH_CMD"

# Execute the volume attachment command.
$ATTACH_CMD || {
    echo "ERROR: Failed to attach volumes to LPAR. Check LPAR status and volume availability."
    exit 1
}

echo "Volumes attached successfully. Waiting 60 seconds for attachment to finalize."
sleep 60


# =============================================================
# STEP 7: Boot LPAR in Normal Server Operating Mode (Unattended IPL)
# =============================================================
echo "--- Step 7: Starting LPAR in Normal Server Operating Mode ---"

# Action: Initiate the boot operation using the IBM i operation command [16, 17].
# Setting '--boot-operating-mode normal' specifies an unattended IPL [18].
ibmcloud pi instance operation $LPAR_NAME \
    --operation-type boot \
    --boot-operating-mode normal \
    || { echo "Error: Failed to start LPAR in NORMAL mode."; exit 1; }

echo "LPAR $LPAR_NAME successfully booted in NORMAL mode. Monitoring status..."


# =============================================================
# STEP 8: Verify LPAR Status is Active
# =============================================================
echo "--- Step 8: Checking LPAR status ---"

while true; do
    LPAR_STATUS=$(ibmcloud pi instance get $LPAR_NAME --json | jq -r '.status')
    
    if [[ "$LPAR_STATUS" == "ACTIVE" ]]; then
        echo "SUCCESS: LPAR $LPAR_NAME is now ACTIVE."
        echo "Automation workflow complete. Monitor the LPAR console for the OS IPL sequence."
        break
    elif [[ "$LPAR_STATUS" == "ERROR" ]]; then
        echo "Error: LPAR $LPAR_NAME entered ERROR state after boot. Aborting."
        exit 1
    else
        echo "LPAR $LPAR_NAME status: $LPAR_STATUS (Expected: ACTIVE). Waiting 30 seconds..."
        sleep 30
    fi
done
