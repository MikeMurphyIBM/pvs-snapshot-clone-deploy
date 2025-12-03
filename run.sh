Automated Restore Script (BASH/CLI)

#!/bin/sh

echo "=== IBM i Snapshot Restore and Boot Script ==="

# -------------------------
# 1. Environment Variables (Sourced from Preceding Deployment Script)
# -------------------------

API_KEY="${IBMCLOUD_API_KEY}"       # IAM API Key
PVS_CRN="${PVS_CRN}"                # Full PowerVS Workspace CRN
CLOUD_INSTANCE_ID="${CLOUD_INSTANCE_ID}" # PowerVS Workspace ID
LPAR_NAME="${LPAR_NAME}"            # Name of the target LPAR: "empty-ibmi-lpar"

# -------------------------
# 1B. Required Restore Variables (MUST BE UPDATED MANUALLY)
# -------------------------

# ID or Name of the source snapshot containing the volumes to be cloned.
SOURCE_SNAPSHOT_ID="<ID_OR_NAME_OF_SOURCE_SNAPSHOT>" 

# Storage Tier. Must match the storage tier of the original volumes in the snapshot.
# Example values: tier0, tier1, tier3 [3, 4].
STORAGE_TIER="tier1"

# Unique prefix for the new cloned volumes
CLONE_NAME_PREFIX="CLONE-RESTORE-$(date +%Y%m%d%H%M%S)"


# -------------------------
# 2. Initialization and Targeting
# -------------------------

echo "--- Logging into IBM Cloud and Targeting PowerVS Workspace ---"

# Log in using the API key (assumes the IAM_TOKEN process completed successfully upstream)
ibmcloud login --apikey $API_KEY --no-account || { echo "ERROR: IBM Cloud login failed."; exit 1; }

# Target the specific PowerVS workspace using the provided CRN [5, 6].
ibmcloud pi ws target $PVS_CRN || { echo "ERROR: Failed to target PowerVS workspace $PVS_CRN."; exit 1; }
echo "Successfully targeted workspace."


# =============================================================
# Helper Function for Waiting for Asynchronous Jobs
# =============================================================
# Cloning is an asynchronous operation, managed via a Job ID [7-10].

function wait_for_job() {
    JOB_ID=$1
    echo "Waiting for asynchronous job ID: $JOB_ID to complete..."
    
    while true; do
        # Retrieve the job status using the CLI command and jq [11].
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
# STEP 3: Discover Source Volume IDs from the Snapshot
# =============================================================
echo "--- Step 3: Discovering Source Volume IDs from Snapshot: $SOURCE_SNAPSHOT_ID ---"

# Action: Retrieve the snapshot metadata in JSON format. The metadata contains the
# 'volumeIDs' array, listing all volumes included in the snapshot [12, 13].
# We use the instance snapshot command because snapshots are tied to VM instances [14, 15].
VOLUME_IDS_JSON=$(ibmcloud pi instance snapshot get $LPAR_NAME --snapshot $SOURCE_SNAPSHOT_ID --json)

if [ $? -ne 0 ]; then
    echo "Error retrieving snapshot details. Check snapshot ID/Name and LPAR name."
    exit 1
fi

# Action: Extract the list of Volume IDs and format them as a single comma-separated string 
# which is the format required by the 'volume clone-async' command [16-18].
SOURCE_VOLUME_IDS=$(echo $VOLUME_IDS_JSON | jq -r '.volumeIDs | join(",")')

if [ -z "$SOURCE_VOLUME_IDS" ]; then
    echo "Error: No Volume IDs found in the snapshot metadata. Aborting."
    exit 1
fi

echo "Source Volume IDs found: $SOURCE_VOLUME_IDS"


# =============================================================
# STEP 4: Create Volume Clones from the Discovered Source Volumes
# =============================================================
echo "--- Step 4: Initiating volume cloning of all source volumes ---"

# Action: Use 'volume clone-async create' to initiate the clone task asynchronously. 
# This command returns a job ID [8, 19, 20].
CLONE_TASK_ID=$(ibmcloud pi volume clone-async create $CLONE_NAME_PREFIX \
    --volumes "$SOURCE_VOLUME_IDS" \
    --target-tier $STORAGE_TIER \
    --json | jq -r '.id')

if [ -z "$CLONE_TASK_ID" ]; then
    echo "Error creating volume clone task. Aborting."
    exit 1
fi

# Action: Wait for the asynchronous cloning job to complete.
wait_for_job $CLONE_TASK_ID

# Action: Find the IDs of the newly created clone volumes using the unique name prefix [1].
# The command lists all volumes, and jq filters by name.
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
# STEP 5: Attach Cloned Volumes to the LPAR
# =============================================================
echo "--- Step 5: Attaching cloned volumes to $LPAR_NAME (Must be in SHUTOFF state) ---"

# Requirement: The LPAR must be shut off before volume attachment [21, 22].
# Action: Build the base attachment command, specifying the required boot volume [23-25].
ATTACH_CMD="ibmcloud pi instance volume attach $LPAR_NAME --boot-volume $CLONE_BOOT_ID"

if [ ! -z "$CLONE_DATA_IDS" ]; then
    # Action: Include additional data volumes if they exist.
    ATTACH_CMD="$ATTACH_CMD --volumes $CLONE_DATA_IDS"
fi

echo "Executing attach command: $ATTACH_CMD"
# Execute the volume attachment command.
$ATTACH_CMD || {
    echo "ERROR: Failed to attach volumes to LPAR. Check LPAR status."
    exit 1
}

echo "Volumes attached successfully. Waiting 60 seconds for attachment to finalize."
sleep 60


# =============================================================
# STEP 6: Boot LPAR in Normal Server Operating Mode (Unattended IPL)
# =============================================================
echo "--- Step 6: Starting LPAR in Normal Server Operating Mode ---"

# Action: Initiate the boot operation using the specific IBM i operation command
# Setting '--boot-operating-mode normal' specifies an unattended IPL 
ibmcloud pi instance operation $LPAR_NAME \
    --operation-type boot \
    --boot-operating-mode normal \
    || { echo "Error: Failed to start LPAR in NORMAL mode."; exit 1; }

echo "LPAR $LPAR_NAME successfully booted in NORMAL mode."
echo "Automation workflow complete. Monitor the LPAR console for the OS IPL sequence."
