# Use a lightweight base image
FROM alpine:latest

# Install necessary dependencies
RUN apk update && \
    apk add --no-cache \
        ca-certificates \
        git \
        openssh \
        openssl \
        wget \
        unzip \
        jq \
        yq \
        bash \
        curl # Added curl to fetch kubectl

# Install kubectl
ENV KUBECTL_VERSION=v1.27.0
RUN curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" && \
    chmod +x ./kubectl && \
    mv ./kubectl /usr/local/bin/kubectl

COPY . /
# Display installed versions
RUN git version && kubectl version --client && mkdir -p /root/.ssh/ && ssh-keyscan "github.com" >> /root/.ssh/known_hosts
