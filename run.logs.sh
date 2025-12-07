#!/bin/bash

# ------------------------------------------------------------
# STRUCTURED LOGGING FUNCTIONS
# ------------------------------------------------------------
log_info()  { echo "[INFO]  [$SCRIPT_NAME] $1"; }
log_warn()  { echo "[WARN]  [$SCRIPT_NAME] $1" >&2; }
log_error() { echo "[ERROR] [$SCRIPT_NAME] $1" >&2; }
log_stage() {
    echo ""
    echo "==============================="
    echo "[STAGE] [$SCRIPT_NAME] $1"
    echo "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo "==============================="
    echo ""
}

SCRIPT_NAME="SNAP-CLONE-ATTACH-DEPLOY"
JOB_SUCCESS=0


log_stage "Starting Job"


# ============================================================
# 1. Environment Variables
# ============================================================
log_stage "Initializing Settings and Variables"
API_KEY="${IBMCLOUD_API_KEY}"
REGION="us-south"
RESOURCE_GROP_NAME="Default"
PVS_CRN="crn:v1:bluemix:public:power-iaas:dal10:a/21d74dd4fe814dfca20570bbb93cdbff:cc84ef2f-babc-439f-8594-571ecfcbe57a::"
CLOUD_INSTANCE_ID="cc84ef2f-babc-439f-8594-571ecfcbe57a"
LPAR_NAME="empty-ibmi-lpar"
PRIMARY_LPAR="get-snapshot"
STORAGE_TIER="tier3"
CLONE_NAME_PREFIX="CLONE-RESTORE-$(date +"%Y%m%d%H%M")"


# ============================================================
# Cleanup trap
# ============================================================
cleanup_on_failure() {

    if [[ $JOB_SUCCESS -eq 1 ]]; then
        log_info "Skipping cleanup — job completed successfully."
        return
    fi

    log_error "Critical Failure — Starting rollback cleanup."

    # (no change in this block except logs)
}

trap 'cleanup_on_failure' ERR EXIT

log_stage "Connecting to IBM Cloud"

ibmcloud login --apikey $API_KEY -r $REGION || { log_error "Cloud login failed"; exit 1; }
ibmcloud target -g $RESOURCE_GROP_NAME || { log_error "Resource group targeting failed"; exit 1; }
ibmcloud pi ws target $PVS_CRN || { log_error "Workspace targeting failed"; exit 1; }


# ============================================================
# STEP 1: TAKE SNAPSHOT
# ============================================================
log_stage "Taking snapshot on primary LPAR"

SNAPSHOT_NAME="TMP_SNAP_$(date +"%Y%m%d%H%M")"
log_info "Creating snapshot $SNAPSHOT_NAME on $PRIMARY_LPAR..."

SNAPSHOT_JSON_OUTPUT=$(ibmcloud pi instance snapshot create "$PRIMARY_LPAR" --name "$SNAPSHOT_NAME" --json)
SNAPSHOT_ID=$(echo "$SNAPSHOT_JSON_OUTPUT" | jq -r '.snapshotID')

log_info "Snapshot created. ID: $SNAPSHOT_ID"

log_info "Waiting for snapshot status to reach AVAILABLE..."

while true; do
    STATUS=$(ibmcloud pi instance snapshot get "$SNAPSHOT_ID" --json | jq -r '.status')
    
    if [[ "$STATUS" == "AVAILABLE" ]]; then
        log_info "Snapshot is available."
        break
    fi

    log_info "Snapshot status = $STATUS — retrying..."
    sleep 45
done


# ============================================================
# STEP 2: DISCOVER SOURCE VOLUMES
# ============================================================
log_stage "Discovering source volumes from snapshot"

SNAPSHOT_DETAIL=$(ibmcloud pi instance snapshot get "$SNAPSHOT_ID" --json)
SOURCE_VOLUME_IDS=$(echo "$SNAPSHOT_DETAIL" | jq -r '.volumeSnapshots | keys[]')

log_info "Discovered source volumes: $SOURCE_VOLUME_IDS"


# ============================================================
# STEP 3: CLASSIFY source volumes
# ============================================================
log_stage "Classifying Boot and Data volumes"

SOURCE_BOOT_ID=""
SOURCE_DATA_IDS=""

for VOL_ID in $SOURCE_VOLUME_IDS; do
    DETAIL=$(ibmcloud pi volume get "$VOL_ID" --json)
    IS_BOOTABLE=$(echo "$DETAIL" | jq -r '.bootable')
    
    if [[ "$IS_BOOTABLE" == "true" ]]; then
        SOURCE_BOOT_ID="$VOL_ID"
        log_info "Boot volume identified: $VOL_ID"
    else
        SOURCE_DATA_IDS="$SOURCE_DATA_IDS,$VOL_ID"
        log_info "Data volume identified: $VOL_ID"
    fi
done

SOURCE_DATA_IDS="${SOURCE_DATA_IDS#,}"


# ============================================================
# STEP 4: CREATE CLONES
# ============================================================
log_stage "Initiating volume clone operation"

CLONE_TASK_ID=$(ibmcloud pi volume clone-async create "$CLONE_NAME_PREFIX" \
    --volumes "$SOURCE_BOOT_ID,$SOURCE_DATA_IDS" \
    --target-tier "$STORAGE_TIER" --json | jq -r '.cloneTaskID')

log_info "Clone task ID: $CLONE_TASK_ID"


# ============================================================
# WAIT FOR clone task
# ============================================================
log_stage "Waiting on clone task to finish"

while true; do
    CLONE_STATE=$(ibmcloud pi volume clone-async get "$CLONE_TASK_ID_
