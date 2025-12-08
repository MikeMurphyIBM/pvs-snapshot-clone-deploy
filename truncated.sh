#!/bin/bash


##trying epoch and normal 12-08 1:16
#####################################################
# MODE 1 — log_print ONLY
# (quiet execution: NO echo, NO errors, NO command output)
#####################################################

# Uncomment BOTH lines below to activate this mode:
#exec >/dev/null 2>&1
#log_print() {
#    printf "[%s] %s\n" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$1"
#}


#####################################################
# MODE 2 — log_print + echo + errors (normal mode)
#####################################################

# >>> LEAVE THESE LINES UNCOMMENTED FOR FULL OUTPUT <<<
log_print() {
    printf "[%s] %s\n" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$1"
}




echo "[SNAP-ATTACH] ==============================="
echo "[SNAP-ATTACH] Job Started"
echo "[SNAP-ATTACH] Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "[SNAP-ATTACH] ==============================="

log_print "========================================================================="
log_print "Job 2:  Snapshot/Cloning/Restore Operations on Primary and Secondary LPAR"
log_print "========================================================================="
log_print ""


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
PRIMARY_INSTANCE_ID="c92f6904-8bd2-4093-acec-f641899cd658"  # Primary LPAR Instance ID
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
# CLEANUP FUNCTION — NO SNAPSHOT REMOVAL
# =======================================================================

cleanup_on_failure() {
    # Ensure cleanup executes only once
    trap - ERR EXIT

    if [[ $JOB_SUCCESS -eq 1 ]]; then
        echo "Job finished successfully — no cleanup needed"
        return 0
    fi

    echo ""
    echo "[CLEANUP] FAILURE DETECTED — BEGINNING SAFE CLEANUP OPERATIONS"

    #
    # STEP 1 — Shutdown LPAR safely IF it exists
    #
    echo "Checking whether LPAR exists..."
    LPAR_JSON=$(ibmcloud pi instance get "$LPAR_NAME" --json 2>/dev/null || true)
    LPAR_EXISTS=$(echo "$LPAR_JSON" | jq -r '.pvmInstanceID // empty')

    if [[ -n "$LPAR_EXISTS" ]]; then
        STATUS=$(echo "$LPAR_JSON" | jq -r '.status')
        echo "[CLEANUP] Found active LPAR ($LPAR_NAME) with status=$STATUS"

        if [[ "$STATUS" != "SHUTOFF" ]]; then
            echo "Attempting shutdown..."
            ibmcloud pi instance action "$LPAR_NAME" --operation stop >/dev/null 2>&1 || true
        fi

        echo "Waiting for shutdown confirmation (max 2 minutes)"
        for ((i=0; i<12; i++)); do
            STATUS=$(ibmcloud pi instance get "$LPAR_NAME" --json 2>/dev/null | jq -r '.status' || true)
            if [[ "$STATUS" == "SHUTOFF" || "$STATUS" == "ERROR" ]]; then
                echo "[CLEANUP] LPAR shutdown confirmed"
                break
            fi
            sleep 10
        done
    else
        echo "No active LPAR found — skipping shutdown"
    fi

    #
    # STEP 2 — NEVER DELETE SNAPSHOT (for this job)
    #
    if [[ -n "$SOURCE_SNAPSHOT_ID" ]]; then
        echo "Snapshot ID [$SOURCE_SNAPSHOT_ID] will NOT be deleted"
        echo "Snapshot preserved for retry, analysis, or manual deploy"
    fi

    #
    # STEP 3 — Remove cloned volumes
    #
    if [[ -z "$CLONE_BOOT_ID" && -z "$CLONE_DATA_IDS" ]]; then
        echo "No cloned volumes exist — cleanup complete"
        return 0
    fi

    DELETE_LIST="$CLONE_BOOT_ID"
    [[ -n "$CLONE_DATA_IDS" ]] && DELETE_LIST="$DELETE_LIST,$CLONE_DATA_IDS"

    # Cleanup formatting
    DELETE_LIST=$(echo "$DELETE_LIST" | sed 's/,,/,/g; s/^,//; s/,$//')

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
# =============================================================

wait_for_job() {
    CLONE_TASK_ID=$1
    echo "Waiting for asynchronous clone task ID: $CLONE_TASK_ID to complete..."
    
    while true; do
        STATUS=$(ibmcloud pi volume clone-async get "$CLONE_TASK_ID" --json | jq -r '.status')
        
        if [[ "$STATUS" == "completed" ]]; then
            echo "Clone Task $CLONE_TASK_ID completed successfully."
            break
        elif [[ "$STATUS" == "failed" ]]; then
            echo "Error: Clone Task $CLONE_TASK_ID failed. Aborting script."
            exit 1
        else
            echo "Clone Task $CLONE_TASK_ID status: $STATUS. Waiting 30 seconds..."
            sleep 30
        fi
    done
}


# =======================================================================
# SECTION 2c: TRAP ACTIVATION
# =======================================================================

trap 'cleanup_on_failure' ERR EXIT


log_print "========================================================================="
log_print "Stage 1 of 7: IBM Cloud Authentication and Targeting PowerVS Workspace"
log_print "========================================================================="
log_print ""

ibmcloud login --apikey "$API_KEY" -r "$REGION" || { echo "ERROR: IBM Cloud login failed."; exit 1; }
ibmcloud target -g "$RESOURCE_GROP_NAME"      || { echo "ERROR: Failed to target resource group."; exit 1; }
ibmcloud pi ws target "$PVS_CRN"              || { echo "ERROR: Failed to target PowerVS workspace $PVS_CRN."; exit 1; }

log_print "Stage 1 of 7 Complete: Successfully authenticated into IBM Cloud"
log_print ""


log_print "========================================================="
log_print "Stage 2a of 7: Perform Snapshot Operation on primary LPAR"
log_print "========================================================="
log_print ""

SNAPSHOT_NAME="TMP_SNAP_$(date +"%Y%m%d%H%M")"

log_print "--- Step 1: Initiating Snapshot on LPAR: $PRIMARY_LPAR ---"
echo "Generated Snapshot Name: $SNAPSHOT_NAME"

log_print "Creating Snapshot: $SNAPSHOT_NAME on LPAR: $PRIMARY_LPAR"
SNAPSHOT_JSON_OUTPUT=$(ibmcloud pi instance snapshot create "$PRIMARY_LPAR" --name "$SNAPSHOT_NAME" --json) || { 
    echo "Error initiating snapshot." 
    exit 1 
}

# *** CRITICAL: assign, then log ***
SNAPSHOT_ID=$(echo "$SNAPSHOT_JSON_OUTPUT" | jq -r '.snapshotID')
log_print "Snapshot ID: $SNAPSHOT_ID"

SOURCE_SNAPSHOT_ID="$SNAPSHOT_ID"

POLL_INTERVAL=45
EXPECTED_STATUS="AVAILABLE"
ERROR_STATUS="ERROR"
CURRENT_STATUS=""

log_print "--- Polling started: Checking snapshot status every ${POLL_INTERVAL} seconds ---"

while true; do
    STATUS_JSON=$(ibmcloud pi instance snapshot get "$SNAPSHOT_ID" --json 2>/dev/null)
    CURRENT_STATUS=$(echo "$STATUS_JSON" | jq -r '.status' | tr '[:lower:]' '[:upper:]' | tr -d '[:space:].')

    if [[ "$CURRENT_STATUS" == "$EXPECTED_STATUS" ]]; then
        log_print "Stage 2a of 7 Complete: $SNAPSHOT_ID is now $CURRENT_STATUS. Proceeding to next step."
        break
    elif [[ "$CURRENT_STATUS" == "$ERROR_STATUS" ]]; then
        echo "FATAL ERROR: Snapshot failed. Status: $CURRENT_STATUS. Exiting script."
        exit 1
    elif [[ -z "$CURRENT_STATUS" || "$CURRENT_STATUS" == "NULL" ]]; then
        echo "Warning: Status unavailable. Waiting ${POLL_INTERVAL} seconds..."
        sleep $POLL_INTERVAL
    else
        echo "Snapshot status: $CURRENT_STATUS. Waiting ${POLL_INTERVAL} seconds..."
        sleep $POLL_INTERVAL
    fi
done

log_print ""
log_print "========================================================="
log_print "Stage 2b of 7: Dynamically Discover the latest Snapshot"
log_print "========================================================="
log_print ""

log_print "--- Step 2: Discovering the latest Snapshot ID in the Workspace (Target LPAR: $LPAR_NAME) ---"
log_print "Snapshot is available for use"

#trying shit here
SNAPSHOT_LIST_JSON=$(ibmcloud pi instance snapshot list --json)

if [[ $? -ne 0 || -z "$SNAPSHOT_LIST_JSON" ]]; then
    echo "Error: Failed to retrieve workspace snapshot list. Aborting."
    exit 1
fi

#
# Step 1: Get latest snapshot by timestamp (fallback/default)
#
LATEST_SNAPSHOT_ID=$(echo "$SNAPSHOT_LIST_JSON" | \
    jq -r '.snapshots | sort_by(.creationDate) | last .snapshotID')

if [[ -z "$LATEST_SNAPSHOT_ID" || "$LATEST_SNAPSHOT_ID" == "null" ]]; then
    echo "Error: Could not find any snapshots in workspace. Aborting."
    exit 1
fi


#
# Step 2: Try epoch-based matching
#
CLONE_TS=$(echo "$CLONE_NAME_PREFIX" | grep -oE '[0-9]{12}')
if [[ -z "$CLONE_TS" ]]; then
    echo "ERROR: Could not extract timestamp from clone naming convention."
    exit 1
fi

CLONE_TS_EPOCH=$(date -d "${CLONE_TS:0:8} ${CLONE_TS:8:2}:${CLONE_TS:10:2}:00" +%s)

THRESHOLD_SECONDS=120
BEST_MATCH=""
BEST_DELTA=999999

echo "$SNAPSHOT_LIST_JSON" | jq -c '.snapshots[]' | while read SNAP; do
    SNAP_NAME=$(echo "$SNAP" | jq -r '.name')
    SNAP_ID=$(echo "$SNAP" | jq -r '.snapshotID')
    SNAP_TS=$(echo "$SNAP_NAME" | grep -oE '[0-9]{12}')

    [[ -z "$SNAP_TS" ]] && continue

    SNAP_TS_EPOCH=$(date -d "${SNAP_TS:0:8} ${SNAP_TS:8:2}:${SNAP_TS:10:2}:00" +%s)

    DIFF=$(( CLONE_TS_EPOCH - SNAP_TS_EPOCH ))
    DIFF=${DIFF#-}

    if (( DIFF <= THRESHOLD_SECONDS )) && (( DIFF < BEST_DELTA )); then
        BEST_DELTA=$DIFF
        BEST_MATCH=$SNAP_ID
    fi
done


#
# Step 3: Final decision logic
#
if [[ -n "$BEST_MATCH" ]]; then
    echo "Matched Snapshot via epoch correlation: $BEST_MATCH"
    SOURCE_SNAPSHOT_ID="$BEST_MATCH"
else
    echo "WARNING: No snapshot matched within threshold; falling back to latest snapshot"
    SOURCE_SNAPSHOT_ID="$LATEST_SNAPSHOT_ID"
fi

log_print "Final Snapshot Selection: $SOURCE_SNAPSHOT_ID"
#shit ends here


: <<'END_COMMENT'
SNAPSHOT_LIST_JSON=$(ibmcloud pi instance snapshot list --json)

if [[ $? -ne 0 || -z "$SNAPSHOT_LIST_JSON" ]]; then
    echo "Error: Failed to retrieve workspace snapshot list. Aborting."
    exit 1
fi

#temporarily commenting out to trying epoch method for identification  and correlation
#LATEST_SNAPSHOT_ID=$(echo "$SNAPSHOT_LIST_JSON" | jq -r '.snapshots | sort_by(.creationDate) | last .snapshotID')

if [[ -z "$LATEST_SNAPSHOT_ID" || "$LATEST_SNAPSHOT_ID" == "null" ]]; then
    echo "Error: Could not find any snapshots in workspace. Aborting."
    exit 1
fi
#end of block

SOURCE_SNAPSHOT_ID="$LATEST_SNAPSHOT_ID"

# trial block
# Extract timestamp from clone name
CLONE_TS=$(echo "$CLONE_NAME_PREFIX" | grep -oE '[0-9]{12}')
if [[ -z "$CLONE_TS" ]]; then
    echo "ERROR: Could not extract timestamp from clone naming convention."
    exit 1
fi

# Convert clone timestamp to epoch
#CLONE_TS_EPOCH=$(date -d "${CLONE_TS:0:8} ${CLONE_TS:8:2}:${CLONE_TS:10:2}" +%s)#previous version
CLONE_TS_EPOCH=$(date -d "${CLONE_TS:0:8} ${CLONE_TS:8:2}:${CLONE_TS:10:2}:00" +%s)


THRESHOLD_SECONDS=120
BEST_MATCH=""
BEST_DELTA=999999

# Match snapshot based on closest timestamp
echo "$SNAPSHOT_LIST_JSON" | jq -c '.snapshots[]' | while read SNAP; do
    SNAP_NAME=$(echo "$SNAP" | jq -r '.name')
    SNAP_ID=$(echo "$SNAP" | jq -r '.snapshotID')
    
    SNAP_TS=$(echo "$SNAP_NAME" | grep -oE '[0-9]{12}')
    [[ -z "$SNAP_TS" ]] && continue

    #SNAP_TS_EPOCH=$(date -d "${SNAP_TS:0:8} ${SNAP_TS:8:2}:${SNAP_TS:10:2}" +%s)#previous version
    SNAP_TS_EPOCH=$(date -d "${SNAP_TS:0:8} ${SNAP_TS:8:2}:${SNAP_TS:10:2}:00" +%s)


    DIFF=$(( CLONE_TS_EPOCH - SNAP_TS_EPOCH ))
    DIFF=${DIFF#-} # absolute value

    if (( DIFF <= THRESHOLD_SECONDS )) && (( DIFF < BEST_DELTA )); then
        BEST_DELTA=$DIFF
        BEST_MATCH=$SNAP_ID
    fi
done

if [[ -z "$BEST_MATCH" ]]; then
    echo "ERROR: No matching snapshot found within ${THRESHOLD_SECONDS} seconds tolerance."
    exit 1
fi

SOURCE_SNAPSHOT_ID="$BEST_MATCH"
echo "Matched Snapshot: $SOURCE_SNAPSHOT_ID"
#tria block end
END_COMMENT


log_print "Stage 2b of 7 Complete: Latest Snapshot ID found: $SOURCE_SNAPSHOT_ID"
log_print ""


log_print "========================================================================"
log_print "Stage 3 of 7: Discover and Classify Source Volume IDs from the Snapshot"
log_print "========================================================================"
log_print ""

log_print "--- Discovering Source Volume IDs from Snapshot: $SOURCE_SNAPSHOT_ID ---"

VOLUME_IDS_JSON=$(ibmcloud pi instance snapshot get "$SOURCE_SNAPSHOT_ID" --json)

if [[ $? -ne 0 ]]; then
    echo "Error retrieving snapshot details. Check snapshot ID: $SOURCE_SNAPSHOT_ID."
    exit 1
fi

SOURCE_VOLUME_IDS=$(echo "$VOLUME_IDS_JSON" | jq -r '.volumeSnapshots | keys[]')

if [[ -z "$SOURCE_VOLUME_IDS" ]]; then
    echo "Error: No Volume IDs found in the snapshot metadata. Aborting."
    exit 1
fi

SOURCE_BOOT_ID=""
SOURCE_DATA_IDS=""
BOOT_FOUND=0

log_print "All Source Volume IDs found. Checking individual volumes for Load Source designation..."
echo "Stage 3 of 7: Classifying Source Boot/Data Volumes from Snapshot"

for VOL_ID in $SOURCE_VOLUME_IDS; do
    VOLUME_DETAIL=$(ibmcloud pi volume get "$VOL_ID" --json 2>/dev/null)

    if [[ $? -eq 0 ]]; then
        IS_BOOTABLE=$(echo "$VOLUME_DETAIL" | jq -r '.bootable')

        if [[ "$IS_BOOTABLE" == "true" ]]; then
            SOURCE_BOOT_ID="$VOL_ID"
            BOOT_FOUND=1
            log_print "Identified Source Boot Volume ID: $SOURCE_BOOT_ID"
        else
            SOURCE_DATA_IDS="$SOURCE_DATA_IDS,$VOL_ID"
        fi
    else
        echo "Warning: Failed to retrieve details for source volume ID: $VOL_ID. Skipping."
    fi
done

SOURCE_DATA_IDS=${SOURCE_DATA_IDS#,}

if [[ "$BOOT_FOUND" -ne 1 ]]; then
    echo "FATAL ERROR: Could not identify the source boot volume among the volumes in the snapshot. Aborting."
    exit 1
fi

log_print "Source Boot Volume ID: $SOURCE_BOOT_ID"
log_print "Source Data Volume IDs (CSV): $SOURCE_DATA_IDS"
log_print "Stage 3 of 7 Complete: Source Boot/Data Volumes Identified"
log_print ""

echo "--- Step 6: Calculating Total Volume Count ---"

BOOT_COUNT=0
if [[ -n "$SOURCE_BOOT_ID" ]]; then
    BOOT_COUNT=1
    echo "Counted 1 Source Boot Volume ID."
fi

CLEANED_DATA_IDS=$(echo "$SOURCE_DATA_IDS" | tr ',' ' ' | tr '\n' ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

DATA_COUNT=0
if [[ -n "$CLEANED_DATA_IDS" ]]; then
    DATA_COUNT=$(echo "$CLEANED_DATA_IDS" | wc -w)
fi

echo "Counted $DATA_COUNT Source Data Volume ID(s)."

EXPECTED_VOLUME_COUNT=$((BOOT_COUNT + DATA_COUNT))
echo "--- Calculated Total Expected Volume Count: $EXPECTED_VOLUME_COUNT ---"


log_print "========================================================================"
log_print "Stage 4 of 7: Create Volume Clones from the Source Volumes"
log_print "========================================================================"
log_print ""

log_print "--- Initiating volume cloning of all source volumes ---"

COMMA_SEPARATED_IDS=$(echo "$SOURCE_VOLUME_IDS" | tr ' ' ',')

# NOTE: SOURCE_BOOT_ID is one of SOURCE_VOLUME_IDS; to avoid duplicates,
# you *could* just use COMMA_SEPARATED_IDS here. Keeping your original
# pattern in case it's working with your environment:
CLONE_TASK_ID=$(ibmcloud pi volume clone-async create "$CLONE_NAME_PREFIX" \
    --volumes "$SOURCE_BOOT_ID,$COMMA_SEPARATED_IDS" \
    --target-tier "$STORAGE_TIER" \
    --json | jq -r '.cloneTaskID')

if [[ -z "$CLONE_TASK_ID" ]]; then
    echo "Error creating volume clone task. Aborting."
    exit 1
fi

log_print "Clone task initiated. Task ID: $CLONE_TASK_ID"

log_print "--- Waiting for asynchronous clone task completion ---"

while true; do
    TASK_STATUS=$(ibmcloud pi volume clone-async get "$CLONE_TASK_ID" --json | jq -r '.status')
    
    if [[ "$TASK_STATUS" == "completed" ]]; then
        log_print "Clone task $CLONE_TASK_ID completed successfully."
        break
    elif [[ "$TASK_STATUS" == "failed" || "$TASK_STATUS" == "cancelled" ]]; then
        echo "Error: Clone task $CLONE_TASK_ID failed with status: $TASK_STATUS. Aborting."
        exit 1
    else
        echo "Clone task status: $TASK_STATUS. Waiting $POLL_INTERVAL seconds..."
        sleep $POLL_INTERVAL
    fi
done

echo "--- Discovery Retry Loop (Waiting for API Synchronization) ---"

MAX_RETRIES=20
RETRY_COUNT=0
POLL_INTERVAL=15 
FOUND_COUNT=0
NEW_CLONE_IDS=""

while [[ $FOUND_COUNT -ne $EXPECTED_VOLUME_COUNT && $RETRY_COUNT -lt $MAX_RETRIES ]]; do
    RETRY_COUNT=$((RETRY_COUNT + 1))
    log_print "Attempt $RETRY_COUNT of $MAX_RETRIES: Searching for volumes using prefix '$CLONE_NAME_PREFIX'..."

    NEW_CLONE_IDS=$(ibmcloud pi volume list --long --json | \
        jq -r ".volumes[] | select(.name | contains(\"$CLONE_NAME_PREFIX\")) | .volumeID")

    FOUND_COUNT=$(echo "$NEW_CLONE_IDS" | wc -w)

    if [[ $FOUND_COUNT -ne $EXPECTED_VOLUME_COUNT ]]; then
        if [[ $RETRY_COUNT -ge $MAX_RETRIES ]]; then
            echo "FATAL ERROR: Only $FOUND_COUNT out of $EXPECTED_VOLUME_COUNT volumes became visible after maximum retries. Aborting."
            exit 1
        fi
        
        echo "Found $FOUND_COUNT volume(s). Expected $EXPECTED_VOLUME_COUNT. Waiting $POLL_INTERVAL seconds..."
        sleep $POLL_INTERVAL
    fi
done

if [[ -z "$NEW_CLONE_IDS" ]]; then
    echo "CRITICAL ERROR: Failed to locate cloned volume IDs after waiting. API synchronization failed. Aborting."
    exit 1
fi

log_print "Stage 4 of 7 Complete: Clone Volume(s) successfully created with Volume IDs: $NEW_CLONE_IDS"

echo "Wait 2 minutes to allow cloned volumes to synchronize with the PVS API"
sleep 2m

log_print ""
log_print "========================================================================"
log_print "Stage 5 of 7: Classify the Newly Cloned Volumes (Boot vs. Data)"
log_print "========================================================================"
log_print ""

echo "--- Step 9: Classifying newly cloned volumes ---"
log_print "#Action: DESIGNATE BOOT AND DATA VOLUMES by checking the explicit 'bootable' property."

CLONE_BOOT_ID=""
TEMP_DATA_IDS="" 
BOOT_FOUND_FLAG=0

for NEW_ID in $NEW_CLONE_IDS; do
    VOLUME_DETAIL=$(ibmcloud pi volume get "$NEW_ID" --json 2>/dev/null)

    if [[ $? -ne 0 ]]; then
        echo "Warning: Failed to retrieve details for cloned volume ID: $NEW_ID. Skipping classification."
        continue
    fi
    
    IS_BOOTABLE=$(echo "$VOLUME_DETAIL" | jq -r '.bootable')
    
    if [[ "$IS_BOOTABLE" == "true" ]]; then
        log_print "Identified CLONE Boot Volume ID: $NEW_ID"
        CLONE_BOOT_ID="$NEW_ID"
        BOOT_FOUND_FLAG=1
    else
        log_print "Identified CLONE Data Volume ID: $NEW_ID"
        TEMP_DATA_IDS="$TEMP_DATA_IDS,$NEW_ID"
    fi
done

CLONE_DATA_IDS=$(echo "$TEMP_DATA_IDS" | sed 's/,\+/,/g; s/^,//; s/,$//')

if [[ "$BOOT_FOUND_FLAG" -ne 1 ]]; then
    echo "FATAL ERROR: Failed to identify the cloned boot volume ID using the 'bootable' property. Aborting."
    exit 1
fi

log_print "Stage 5 of 7 Complete: Target Boot and Data Volumes Successfully Identified"
log_print ""
echo "CLONE_BOOT_ID: $CLONE_BOOT_ID"
echo "CLONE_DATA_IDS (CSV): $CLONE_DATA_IDS"


log_print "========================================================================"
log_print "Stage 6 of 7: Attach Cloned Volumes to the Empty LPAR"
log_print "========================================================================"
log_print ""

echo "[SNAP-ATTACH] Resolving instance ID (UUID) ..."

INSTANCE_IDENTIFIER=$(ibmcloud pi instance list --json \
    | jq -r ".pvmInstances[] | select(.name == \"$LPAR_NAME\") | .id")

if [[ -z "$INSTANCE_IDENTIFIER" ]]; then
    echo "[FATAL] Instance ID could not be found for $LPAR_NAME"
    exit 1
fi

echo "[SNAP-ATTACH] Using instance ID: $INSTANCE_IDENTIFIER"
echo ""
echo "[SNAP-ATTACH] BOOT VOLUME: $CLONE_BOOT_ID"
echo "[SNAP-ATTACH] DATA VOLUMES: $CLONE_DATA_IDS"
echo ""

# STEP 1 — Attach BOOT FIRST
log_print "Attaching BOOT volume first..."
ibmcloud pi instance volume attach "$INSTANCE_IDENTIFIER" --volumes "$CLONE_BOOT_ID"
BOOT_EXIT=$?

if [[ $BOOT_EXIT -ne 0 ]]; then
    echo "[ERROR] Boot attach failed — backend refused"
    exit 1
fi

log_print  "Boot volume attach accepted — waiting 60 seconds"
sleep 60

# STEP 2 — Attach DATA volumes only if available
if [[ -n "$CLONE_DATA_IDS" ]]; then
    log_print "Attaching DATA volumes..."
    ibmcloud pi instance volume attach "$INSTANCE_IDENTIFIER" --volumes "$CLONE_DATA_IDS"
    DATA_EXIT=$?

    if [[ $DATA_EXIT -ne 0 ]]; then
        echo "[ERROR] Data volume attach failed — backend refused"
        exit 1
    fi

    log_print "[SNAP-ATTACH] Data attach accepted — syncing"
fi


# =============================================================
# WAIT UNTIL VOLUMES ARE ATTACHED BEFORE BOOT
# =============================================================

echo ""
echo "[SNAP-ATTACH] Waiting for volumes to attach..."

MAX_WAIT=420   # 7 minutes
INTERVAL=15
WAITED=0

while true; do
    VOL_LIST=$(ibmcloud pi instance volume list "$INSTANCE_IDENTIFIER" --json 2>/dev/null \
        | jq -r '(.volumes // []) | .[]? | .volumeID')

    BOOT_PRESENT=$(echo "$VOL_LIST" | grep "$CLONE_BOOT_ID" || true)

    DATA_PRESENT=true
    if [[ -n "$CLONE_DATA_IDS" ]]; then
        DATA_PRESENT=$(echo "$VOL_LIST" | grep "$CLONE_DATA_IDS" || true)
    fi

    if [[ -n "$BOOT_PRESENT" && ( -z "$CLONE_DATA_IDS" || -n "$DATA_PRESENT" ) ]]; then
        log_print "Stage 6 of 7 Complete: Volumes visible on instance via API"
        break
    fi
    
    if [[ $WAITED -ge $MAX_WAIT ]]; then
        echo "[FATAL] Volumes never fully appeared after $MAX_WAIT seconds."
        echo "[WARN] Backend did not report attached volumes but attach commands were accepted."
        echo "[WARN] Storage may actually be attached — confirm manually."
        exit 22
    fi

    echo "[SNAP-ATTACH] Volumes not fully attached yet — checking again..."
    sleep $INTERVAL
    WAITED=$((WAITED+INTERVAL))
done

log_print ""
log_print "====================================================================="
log_print "Stage 7 of 7: BOOT IBMi Instance Safely w/Unassisted IPL"
log_print "====================================================================="
log_print ""

log_print "--- Setting LPAR boot mode and initiating startup ---"

STATUS=$(ibmcloud pi instance get "$INSTANCE_IDENTIFIER" --json | jq -r '.status')

if [[ "$STATUS" != "ACTIVE" ]]; then
    log_print "Configuring NORMAL boot mode..."

    ibmcloud pi instance operation "$INSTANCE_IDENTIFIER" \
        --operation-type boot \
        --boot-mode a \
        --boot-operating-mode normal || {
        echo "[FATAL] Failed to configure IBM i boot operation."
        exit 1
    }

    echo "Starting instance..."

    ibmcloud pi instance action "$INSTANCE_IDENTIFIER" --operation start || { 
        echo "[FATAL] Failed to initiate LPAR start command. Aborting."
        exit 1 
    }

    log_print "LPAR start command accepted."
else
    echo "LPAR is already ACTIVE — skipping boot/start request"
fi


# =============================================================
# WAIT FOR ACTIVE STATE
# =============================================================

log_print "Waiting for LPAR to reach ACTIVE state..."

MAX_BOOT_WAIT=1200  # 20 minutes
BOOT_WAITED=0
INTERVAL=30

while true; do
    STATUS=$(ibmcloud pi instance get "$INSTANCE_IDENTIFIER" --json | jq -r '.status')

    if [[ "$STATUS" == "ACTIVE" ]]; then
        log_print "SUCCESS — LPAR is ACTIVE"
        JOB_SUCCESS=1
        break
    fi

    if [[ "$STATUS" == "ERROR" ]]; then
        echo "[FATAL] LPAR entered ERROR state during boot"
        exit 1
    fi

    if [[ $BOOT_WAITED -ge $MAX_BOOT_WAIT ]]; then
        echo "[FATAL] LPAR failed to reach ACTIVE after $(($MAX_BOOT_WAIT/60)) minutes"
        exit 1
    fi

    log_print "LPAR still in state [$STATUS] — sleeping $INTERVAL seconds..."
    sleep $INTERVAL
    BOOT_WAITED=$((BOOT_WAITED+INTERVAL))
done


# =============================================================
# FINAL CONFIRMATION & OPTIONAL SNAPSHOT-CLEANUP JOB
# =============================================================

FINAL_STATUS=$(ibmcloud pi instance get "$INSTANCE_IDENTIFIER" --json | jq -r '.status')

if [[ "$FINAL_STATUS" != "ACTIVE" ]]; then
    echo "WARNING — API readback did not reflect ACTIVE state, verify manually"
else
    log_print "FINAL VALIDATION — LPAR ACTIVE confirmed from API"
fi

log_print "Stage 7 of 7 Complete: Successfully confirmed LPAR is Active from API readback"

log_print ""
log_print "--------------------------------------------"
log_print "****Snapshot Restore Summary****"
log_print "--------------------------------------------"
log_print "****Snapshot Taken            : Yes****"
log_print "****Volumes Cloned            : Yes****"
log_print "****Volumes Attached to LPAR  : Yes****"
log_print "****LPAR Boot Mode            : NORMAL (Mode A)****"
log_print "****LPAR Final Status         : ACTIVE****"
log_print "--------------------------------------------"
log_print ""

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

log_print "Job #2 Completed Successfully"
echo "[SNAP-ATTACH] Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"

JOB_SUCCESS=1
exit 0
