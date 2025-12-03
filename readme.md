This automation script is designed to execute the post-provisioning steps for migrating an IBM i workload via snapshot restoration. 
It starts exactly where the pvs-api-deploy script ended: with the empty IBMi LPAR already provisioned and in the shutoff state.
The script dynamically discovers the volumes within the provided snapshot, clones them, attaches the cloned volumes (including the new boot volume) 
to the LPAR, and initiates an unattended (Normal mode) boot.
Required Utilities
This script requires:
1. ibmcloud CLI and the power-iaas plugin.
2. jq for JSON processing
.
