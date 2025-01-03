#!/bin/bash

# Map templates and helm release folders
repo_root_path="/mnt/vol/linode"
manifests_path="${repo_root_path}/gitops/application-plane/production/tenants"

main() {
    local tenant_id="$1"
    local tenant_tier="$2"
    local git_user_email="$3"
    local git_user_name="$4"
    local repository_branch="$5"

    # Remove tenant helm release file and update kustomization
    remove_tenant_helm_release "${tenant_id}" "${tenant_tier}"

    # Configure git user for HTTPS operations
    configure_git "${git_user_email}" "${git_user_name}"

    # Push updated helm releases
    commit_files "${repository_branch}" "${tenant_id}" "${tenant_tier}"
}

remove_tenant_helm_release() {
    local tenant_id="$1"
    local tenant_tier="$2"

    # Tenant helm release file name based on tenant_tier and tenant_id
    local tenant_manifest_file="${tenant_tier}/${tenant_id}.yaml"

    # Full path for tenant helm release file
    local tenant_manifest_path="${manifests_path}/${tenant_manifest_file}"

    # Remove tenant helm release file
    echo "Removing tenant manifest file: ${tenant_manifest_path}"
    rm "${tenant_manifest_path}" || { echo "Error: Failed to remove ${tenant_manifest_path}"; exit 1; }

    # Update kustomization file by removing the tenant helm release file
    local kustomization_file="${manifests_path}/${tenant_tier}/kustomization.yaml"
    echo "Updating kustomization file: ${kustomization_file}"
    sed -i "/- ${tenant_id}\.yaml/d" "${kustomization_file}" || { echo "Error: Failed to update ${kustomization_file}"; exit 1; }
}

configure_git() {
    local git_user_email="$1"
    local git_user_name="$2"

    # Configure Git user details
    git config --global user.email "${git_user_email}"
    git config --global user.name "${git_user_name}"

    # Ensure .ssh directory exists
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh

    # Create SSH config for GitHub
    cat <<EOF > /root/.ssh/config
Host github.com
    User git
    IdentityFile /root/.ssh/id_rsa
    StrictHostKeyChecking no
EOF

    chmod 600 /root/.ssh/config
}

commit_files() {
    local repository_branch="$1"
    local tenant_id="$2"
    local tenant_tier="$3"

    cd ${repo_root_path} || { echo "Error: Failed to change directory to ${repo_root_path}"; exit 1; }

    # Ensure remote URL uses SSH
    git remote set-url origin git@github.com:devnouiq/linode.git

    echo "Current directory: $(pwd)"
    git remote -v

    git status
    git pull || { echo "Error pulling repository"; exit 1; }
    git add . || { echo "Error staging changes"; exit 1; }
    git commit -am "Removing tenant ${tenant_id} in tier ${tenant_tier}" || { echo "Error committing changes"; exit 1; }
    git push origin "${repository_branch}" || { echo "Error pushing changes"; exit 1; }
}

main "$@"
