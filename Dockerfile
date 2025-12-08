# Use Alpine Linux (small base image)
FROM alpine:3.19

# Install required tools and IBM Cloud CLI dependencies
RUN apk update && \
    apk add --no-cache bash curl jq openssl py3-pip python3

# --- Install IBM Cloud CLI ---
RUN curl -fsSL https://clis.cloud.ibm.com/install/linux | bash

# Ensure ibmcloud command is visible
ENV PATH="/root/.bluemix:$PATH"

# -----------------------------------------------------------
# Install required IBM Cloud plugins
# -----------------------------------------------------------

# Refresh plugin repo index
RUN ibmcloud plugin repo-plugins

# Install PVS plugin (needed for snapshot/volume operations)
RUN ibmcloud plugin install power-iaas -f

# Install Code Engine CLI (needed to submit Job 3)
RUN ibmcloud plugin install code-engine -f

# -----------------------------------------------------------
# Copy and prepare the Job 2 script
# -----------------------------------------------------------
COPY truncated.sh /truncated.sh

RUN sed -i 's/\r$//' /truncated.sh && chmod +x /truncated.sh

CMD ["/truncated.sh"]


