# Use a lightweight Debian base image
FROM debian:stable-slim

# Set non-interactive mode for smooth dependency installation
ENV DEBIAN_FRONTEND=noninteractive

# Set HOME and working directory
ENV HOME=/root
WORKDIR ${HOME}

# -----------------------------------------------------------
# 1. Install Dependencies (curl, jq, and bash)
# -----------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    jq \
    bash && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------
# Install IBM Cloud CLI
# Then install Power Virtual Server and Code Engine Plugins
# -----------------------------------------------------------
RUN curl -fsSL https://clis.cloud.ibm.com/install/linux | bash && \
    ibmcloud plugin install power-iaas -f && \
    ibmcloud plugin install code-engine -f

# Ensure CLI binaries are present in PATH
ENV PATH="/root/.bluemix:${PATH}"

# -----------------------------------------------------------
# 2. Add Runtime Script and Define Entrypoint
# -----------------------------------------------------------
COPY run.logs.sh .

RUN chmod +x run.logs.sh

CMD ["/root/run.logs.sh"]

