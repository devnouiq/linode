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
    
    # Create the tenant Helm release with its own kustomization.yaml
    create_helm_release "$tenant_id" "$tenant_tier" "$release_version" "$tier_template_file"
    
    # Configure Git user
    configure_git "${git_user_email}" "${git_user_name}"

    # Push changes to Git
    commit_files "${repository_branch}" "${tenant_id}" "${tenant_tier}"
}

create_helm_release() {    
    local tenant_id="$1"
    local tenant_tier="$2"
    local release_version="$3"
    local tier_template_file="$4"

    # Ensure tenant_id does NOT already have 'tenant-' prefix
    local clean_tenant_id="${tenant_id#tenant-}"  # Removes 'tenant-' prefix if it exists

    # Define correct tenant folder path
    local tenant_folder="${manifests_path}/${tenant_tier}/tenant-${clean_tenant_id}"
    local tenant_manifest_file="${tenant_folder}/tenant-${clean_tenant_id}.yaml"
    local kustomization_file="${tenant_folder}/kustomization.yaml"

    # Create the tenant-specific directory
    mkdir -p "${tenant_folder}"

    # Copy the tier template to create the tenant manifest
    cp "${tier_template_file}" "${tenant_manifest_file}"

    # Replace placeholders in the manifest file
    sed -i "s|{TENANT_ID}|${clean_tenant_id}|g" "${tenant_manifest_file}"
    sed -i "s|{RELEASE_VERSION}|${release_version}|g" "${tenant_manifest_file}"

    echo "Created Helm release for tenant ${clean_tenant_id} in ${tenant_folder}"

    # Generate a unique kustomization.yaml for this tenant
    cat > "${kustomization_file}" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - tenant-${clean_tenant_id}.yaml
EOF

    echo "Created kustomization.yaml for tenant ${clean_tenant_id} in ${tenant_folder}"
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
    local max_retries=3
    local attempt=1

    cd ${repo_root_path} || { echo "Error: Failed to change directory to ${repo_root_path}"; exit 1; }
    git remote set-url origin git@github.com:devnouiq/linode.git

    echo "Current directory: $(pwd)"
    git remote -v

    while [[ $attempt -le $max_retries ]]; do
        echo "Attempt ${attempt}/${max_retries} to commit changes."

        # Pull latest changes with rebase
        git pull --autostash --rebase || {
            echo "Merge conflict detected. Retrying..."
            git rebase --abort
            git stash pop || { echo "Error applying stash"; exit 1; }

            # Ensure tenant folder is correctly added
            create_helm_release "${tenant_id}" "${tenant_tier}" "latest_version"

            # Stage, commit, and push changes
            git add .
            git commit -am "Resolved merge conflict for ${tenant_id}" || {
                echo "Error committing merge on attempt ${attempt}."
                attempt=$((attempt + 1))
                continue
            }

            git push origin "${repository_branch}" || {
                echo "Error pushing resolved conflict on attempt ${attempt}."
                attempt=$((attempt + 1))
                continue
            }

            echo "Successfully committed and pushed on retry attempt ${attempt}."
            return
        }

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

main "$@"
