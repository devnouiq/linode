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

    # Tenant Helm release file name
    local tenant_manifest_file="${tenant_tier}/${tenant_id}.yaml"
    local kustomization_file="${manifests_path}/${tenant_tier}/kustomization.yaml"

    # Create tenant Helm release file from template
    cp "${tier_template_file}" "${manifests_path}/${tenant_manifest_file}"

    # Replace placeholders
    sed -i "s|{TENANT_ID}|${tenant_id}|g" "${manifests_path}/${tenant_manifest_file}"
    sed -i "s|{RELEASE_VERSION}|${release_version}|g" "${manifests_path}/${tenant_manifest_file}"

    echo "Created Helm release for tenant ${tenant_id} in ${manifests_path}/${tenant_tier}"

    # Ensure new tenants are always added properly
    if ! grep -q "  - ${tenant_id}.yaml" "${kustomization_file}"; then
        cp "${kustomization_file}" "${kustomization_file}.bak"

        # Ensure a blank line before adding a new entry
        echo "" >> "${kustomization_file}.bak"
        echo "  - ${tenant_id}.yaml" >> "${kustomization_file}.bak"

        # Sort and remove duplicates while keeping formatting
        awk '!seen[$0]++' "${kustomization_file}.bak" > "${kustomization_file}"

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

            # Ensure conflicts in kustomization.yaml are resolved
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

            git checkout "${repository_branch}"
            git pull origin "${repository_branch}" --rebase

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

        # **Final Check Before Committing**
        if grep -q "<<<<<<<" "${manifests_path}/${tenant_tier}/kustomization.yaml"; then
            echo "Merge conflict detected again. Attempting to fix..."
            resolve_kustomization_conflict "${tenant_tier}"
        fi

        git add .
        git commit -am "Adding new tenant ${tenant_id} in tier ${tenant_tier}" || {
            echo "Error committing changes."
            attempt=$((attempt + 1))
            continue
        }

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

    # Backup the conflicted file before processing
    cp "${kustomization_file}" "${kustomization_file}.bak"

    # Ensure correct YAML structure
    {
        echo "apiVersion: kustomize.config.k8s.io/v1beta1"
        echo "kind: Kustomization"
        echo "resources:"
        echo "  - dummy-configmap.yaml"
    } > "${kustomization_file}.tmp"

    # Extract only valid tenant entries (removing conflict markers)
    grep -E "^\s+- tenant-[a-f0-9]+.yaml" "${kustomization_file}.bak" | sort -u >> "${kustomization_file}.tmp"

    # Ensure the final kustomization.yaml has a trailing newline
    echo "" >> "${kustomization_file}.tmp"

    # Replace the original file with the cleaned-up version
    mv "${kustomization_file}.tmp" "${kustomization_file}"
    rm "${kustomization_file}.bak"

    echo "Successfully resolved and reformatted ${kustomization_file}."
}

main "$@"
