#!/bin/bash

# Define paths
repo_root_path="/mnt/vol/linode"
tier_templates_path="${repo_root_path}/gitops/application-plane/production/tier-templates"
manifests_path="${repo_root_path}/gitops/application-plane/production/tenants"

main() {
    local tenant_id="$1"
    local release_version="$2"
    local tenant_tier="$3"
    local git_user_email="$4"
    local git_user_name="$5"
    local repository_branch="$6"

    # Get the appropriate tier template
    local tier_template_file
    tier_template_file=$(get_tier_template_file "$tenant_tier")

    # Create the tenant Helm release file
    create_helm_release "$tenant_id" "$tenant_tier" "$release_version" "$tier_template_file"

    # Configure Git user
    configure_git "${git_user_email}" "${git_user_name}"

    # Commit changes to Git
    commit_files "${repository_branch}" "${tenant_id}" "${tenant_tier}"
}

create_helm_release() {    
    local tenant_id="$1"
    local tenant_tier="$2"
    local release_version="$3"
    local tier_template_file="$4"

    # Tenant helm release file name
    local tenant_manifest_file="${tenant_tier}/${tenant_id}.yaml"
    local kustomization_file="${manifests_path}/${tenant_tier}/kustomization.yaml"

    # Create tenant helm release file from template
    cp "${tier_template_file}" "${manifests_path}/${tenant_manifest_file}"

    # Replace placeholders
    sed -i "s|{TENANT_ID}|${tenant_id}|g" "${manifests_path}/${tenant_manifest_file}"
    sed -i "s|{RELEASE_VERSION}|${release_version}|g" "${manifests_path}/${tenant_manifest_file}"

    echo "Created Helm release for tenant ${tenant_id} in ${manifests_path}/${tenant_tier}"

    # Ensure proper formatting and order in kustomization.yaml
    if ! grep -q "  - ${tenant_id}.yaml" "${kustomization_file}"; then
        cp "${kustomization_file}" "${kustomization_file}.bak"

        # Insert new tenant while preserving order and formatting
        {
            head -n 3 "${kustomization_file}.bak"  # Retain headers
            echo "  - ${tenant_id}.yaml"  # Add new entry on a new line
            tail -n +4 "${kustomization_file}.bak"  # Keep existing entries
        } > "${kustomization_file}"

        # Sort and clean up
        awk '!seen[$0]++' "${kustomization_file}" > "${kustomization_file}.tmp" && mv "${kustomization_file}.tmp" "${kustomization_file}"
        rm "${kustomization_file}.bak"
    fi
}

get_tier_template_file() {
    local tenant_tier="$1"    
    case "$tenant_tier" in
        "basic") echo "${tier_templates_path}/basic_tenant_template.yaml" ;;
        "premium") echo "${tier_templates_path}/premium_tenant_template.yaml" ;;
        "advanced") echo "${tier_templates_path}/advanced_tenant_template.yaml" ;;
        *) echo "Invalid tenant tier $tenant_tier"; exit 1 ;;
    esac
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
    local max_retries=5
    local attempt=1

    cd ${repo_root_path} || { echo "Error: Failed to change directory to ${repo_root_path}"; exit 1; }
    git remote set-url origin git@github.com:devnouiq/linode.git

    echo "Current directory: $(pwd)"
    git remote -v

    while [[ $attempt -le $max_retries ]]; do
        echo "Attempt ${attempt}/${max_retries} to commit changes."

        # Stash any local changes before pulling
        git stash push -m "Stashing before pull for tenant ${tenant_id}" || echo "Nothing to stash."

        # Pull latest changes and handle conflicts
        git pull --autostash --rebase || {
            echo "Merge conflict detected. Attempting to resolve..."

            if grep -q "<<<<<<<" "${manifests_path}/${tenant_tier}/kustomization.yaml"; then
                echo "Conflict detected in kustomization.yaml. Fixing..."
                resolve_kustomization_conflict "${tenant_tier}"
            fi

            git add .

            git commit -am "Auto-resolved merge conflict in ${tenant_tier}/kustomization.yaml" || {
                echo "Error committing merge on attempt ${attempt}."
                attempt=$((attempt + 1))
                continue
            }

            git push origin "${repository_branch}" || {
                echo "Error pushing resolved conflict on attempt ${attempt}."
                attempt=$((attempt + 1))
                continue
            }

            echo "Successfully committed and pushed after resolving merge conflict."
            return
        }

        # Apply stashed changes
        git stash pop || echo "No stashed changes to apply."

        # Stage and commit
        git add .
        git commit -am "Adding new tenant ${tenant_id} in tier ${tenant_tier}" || {
            echo "Error committing changes."
            attempt=$((attempt + 1))
            continue
        }

        # Push changes
        git push origin "${repository_branch}" && {
            echo "Successfully pushed changes on attempt ${attempt}."
            return
        }

        echo "Push failed, retrying..."
        attempt=$((attempt + 1))
    done

    echo "Failed to commit changes after ${max_retries} attempts. Manual intervention required."
    exit 1
}

resolve_kustomization_conflict() {
    local tenant_tier="$1"
    local kustomization_file="${manifests_path}/${tenant_tier}/kustomization.yaml"

    echo "Resolving merge conflict in ${kustomization_file}..."

    # Backup the conflicted file
    cp "${kustomization_file}" "${kustomization_file}.bak"

    # Create a temporary file for cleaned-up resources
    temp_file=$(mktemp)

    # Start fresh with correct YAML headers
    {
        echo "apiVersion: kustomize.config.k8s.io/v1beta1"
        echo "kind: Kustomization"
        echo "resources:"
        echo "  - dummy-configmap.yaml"
    } > "${temp_file}"

    # Extract valid tenant entries, ensuring each is on a new line
    grep -E "^\s+- [a-z0-9-]+.yaml" "${kustomization_file}.bak" | sort -u >> "${temp_file}"

    # Ensure a new line at the end of the file
    echo "" >> "${temp_file}"

    # Replace the original file with cleaned-up version
    mv "${temp_file}" "${kustomization_file}"
    rm "${kustomization_file}.bak"

    echo "Successfully resolved merge conflict in ${kustomization_file}."
}

main "$@"
