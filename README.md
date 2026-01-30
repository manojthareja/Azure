1. Update config/inputs.yaml file -

- Replace the region values if not already done.
- Set the subscription IDs
- For AzureDevOps, create a PAT (Personal Access Token) and replace the "token-1" in azure_devops_personal_access_token: "token-1" with your PAT -

    - Navigate to dev.azure.com and sign in to your organization.
    - Ensure you navigate to the organization you want to deploy to.
    - Click the User settings icon in the top right and select Personal access tokens.
    - Click + New Token.
    - Enter Azure Landing Zone Terraform Accelerator in the Name field.
    - Alter the Expiration drop down and select Custom defined.
    - Choose tomorrows date in the date picker.
    - Click the Show all scopes link at the bottom.
    - Check the following scopes:
        - Agent Pools: Read & manage
        - Build: Read & execute
        - Code: Full
        - Environment: Read & manage
        - Graph: Read & manage
        - Pipeline Resources: Use & manage
        - Project and Team: Read, write & manage
        - Service Connections: Read, query & manage
        - Variable Groups: Read, create & manage
    - Click Create.


- For GitHub, create a PAT (Personal Access Token) with the following scope, and replace the "token-1" in github_personal_access_token: "token-1" with your PAT.
    - Navigate to github.com.
    - Click on your user icon in the top right and select Settings.
    - Scroll down and click on Developer Settings in the left navigation.
    - Click Personal access tokens in the left navigation and select Tokens (classic).
    - Click Generate new token at the top and select Generate new token (classic).
    - Enter Azure Landing Zone Terraform Accelerator in the Note field.
    - Alter the Expiration drop down and select Custom.
    - Choose tomorrows date in the date picker.
    - Check the following scopes:
        - repo
        - workflow
        - admin:org
        - user: read:user
        - user: user:email
        - delete_repo
    - Click Generate token.

2. Run .\scripts\update-config.ps1 to ensure all module paths and configurations are properly set

3. Deploy the bootstrap infra using this script -

.\scripts\invoke-terraform.ps1 `
  -ModuleFolderPath "<path-to-bootstrap-folder>" `
  -TfvarsFileName "terraform.tfvars.json" `
  -TenantId "<your-tenant-id>" `
  -AutoApprove


4. Deploy the Platform Landing Zone using your chosen version control method and pipeline system.

- For Azure DevOps
    - Navigate to dev.azure.com and sign in to your organization.
    - Navigate to your project.
    - Click Pipelines in the left navigation.
    - Click the 02 Azure Landing Zones Continuous Delivery pipeline.
    - Click Run pipeline in the top right.
    - Take the defaults and click Run.
    - Your pipeline will run a plan.
    - If you provided apply_approvers to the bootstrap, it will prompt you to approve the apply stage.

Your pipeline will run an apply and deploy an Azure landing zone based on the starter module you choose.

- For GitHub
    - Navigate to github.com.
    - Navigate to your repository.
    - Click Actions in the top navigation.
    - Click the 02 Azure Landing Zones Continuous Delivery pipeline in the left navigation.
    - Click Run workflow in the top right, then keep the default branch and click Run workflow.
    - Your pipeline will run a plan.
    - If you provided apply_approvers to the bootstrap, it will prompt you to approve the apply job.

Your pipeline will run an apply and deploy an Azure landing zone based on the starter module you choose.