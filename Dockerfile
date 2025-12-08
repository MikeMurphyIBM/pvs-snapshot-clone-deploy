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
COPY linkedin.sh .

RUN chmod +x linkedin.sh

CMD ["./linkedin.sh"]


