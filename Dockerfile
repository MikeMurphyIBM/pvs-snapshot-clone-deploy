# Use Alpine Linux (small base image)
#FROM alpine:3.19

# Install required tools and IBM Cloud CLI dependencies
#RUN apk update && \
 #   apk add --no-cache bash curl jq openssl py3-pip python3

# --- Install IBM Cloud CLI ---
#RUN curl -fsSL https://clis.cloud.ibm.com/install/linux | bash

# Ensure ibmcloud command is visible
#ENV PATH="/root/.bluemix:$PATH"

# -----------------------------------------------------------
# Install required IBM Cloud plugins
# -----------------------------------------------------------

# Refresh plugin repo index
#RUN ibmcloud plugin repo-plugins

# Install PVS plugin (needed for snapshot/volume operations)
#RUN ibmcloud plugin install power-iaas -f

# Install Code Engine CLI (needed to submit Job 3)
#RUN ibmcloud plugin install code-engine -f

# -----------------------------------------------------------
# Copy and prepare the Job 2 script
# -----------------------------------------------------------
#COPY latest.sh /latest.sh

#RUN sed -i 's/\r$//' /latest.sh && chmod +x /latest.sh

#CMD ["/latest.sh"]

# Use Debian so date & commands behave consistently
FROM debian:stable-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV HOME=/root
WORKDIR ${HOME}

# Install base dependencies & GNU coreutils
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    curl \
    jq \
    ca-certificates \
    coreutils \
 && rm -rf /var/lib/apt/lists/*

# Install IBM Cloud CLI
RUN curl -fsSL https://clis.cloud.ibm.com/install/linux | bash

# Ensure CLI is available on PATH
ENV PATH="/root/.bluemix:$PATH"

# Install required plugins
RUN ibmcloud plugin repo-plugins && \
    ibmcloud plugin install power-iaas -f && \
    ibmcloud plugin install code-engine -f

# Copy script into container
COPY latest.sh .

RUN chmod +x latest.sh

CMD ["./latest.sh"]



