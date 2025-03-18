#!/bin/bash

# map templates and helm release folders -- this is mounted on 01-tenant-clone-repo.sh
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

    # get tier template file based on the tier for the tenant being provisioned 
    local tier_template_file
    tier_template_file=$(get_tier_template_file "$tenant_tier")
    
    # create the tenant helm release file based on the tier template file and tenant id
    create_helm_release "$tenant_id" "$tenant_tier" "$release_version" "$tier_template_file"
    
    # configure git user and ssh key so we can push changes to the gitops repo
    configure_git "${git_user_email}" "${git_user_name}"

    # push new helm release for the tenant and kustomization update to the gitops repo
    commit_files "${repository_branch}" "${tenant_id}" "${tenant_tier}"
}

create_helm_release() {    
    local tenant_id="$1"
    local tenant_tier="$2"
    local release_version="$3"
    local tier_template_file="$4"

    local tenant_manifest_file="${tenant_tier}/${tenant_id}.yaml"
    local kustomization_file="${manifests_path}/${tenant_tier}/kustomization.yaml"

    # Copy template to create tenant manifest
    cp "${tier_template_file}" "${manifests_path}/${tenant_manifest_file}"

    # Replace placeholders
    sed -i "s|{TENANT_ID}|${tenant_id}|g" "${manifests_path}/${tenant_manifest_file}"
    sed -i "s|{RELEASE_VERSION}|${release_version}|g" "${manifests_path}/${tenant_manifest_file}"

    # Ensure the kustomization file is updated safely
    echo "Adding tenant ${tenant_id} to ${kustomization_file}"

    # Avoid duplicate entries and concurrent modifications
    (grep -v "${tenant_id}.yaml" "${kustomization_file}" || true) > "${kustomization_file}.tmp"
    echo "  - ${tenant_id}.yaml" >> "${kustomization_file}.tmp"

    # Sort and remove duplicates
    sort -u "${kustomization_file}.tmp" > "${kustomization_file}"
    rm "${kustomization_file}.tmp"
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

        # Stash changes to prevent conflicts
        git stash push -m "Stashing before pull for tenant ${tenant_id}" || echo "Nothing to stash."

        # Pull latest changes with rebase
        git pull --autostash --rebase || {
            echo "Merge conflict detected. Retrying..."
            git rebase --abort
            git stash pop || { echo "Error applying stash"; exit 1; }

            # Ensure correct appending of kustomization.yaml
            create_helm_release "${tenant_id}" "${tenant_tier}" "latest_version"

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

main "$@"
