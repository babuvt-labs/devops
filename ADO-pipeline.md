# Azure DevOps Pipeline + Terraform Deployment Tutorial

I recently needed to use Terraform to deploy Azure services via Azure DevOps.

Having focused on Bicep for the past couple of years, it's been a while since I've used Terraform, so I was looking for a quick example Azure DevOps (ADO) deployment pipeline.

There are some good references out there, but I felt most of them skimmed over some key configuration, such as Azure subscription permissions or ADO secrets.

This guide will cover everything required to deploy an example Azure Service Bus instance via Terraform and ADO.

In addition to creating an example pipeline, we'll also add enhanced capabilities, including:

- Hosting the Terraform backend state on Azure blob storage
- Creating a deployment Service Principal + setting RBAC permissions on the Azure subscription
- Create a multi-stage ADO pipeline with an approval step
- Demonstrating how we can scale with multiple deployments

## Overall Topology

In this diagram, we can see all of the different supporting components required to deploy the Terraform code and the actual Service Bus instance itself.

There are a couple of things worth highlighting:

- **ADO build agent** - more advanced deployment scenarios sometimes require the use of self-hosted agents due to network or security requirements. But for simplicity, we'll use the ADO-hosted Linux (Ubuntu) build agent, which already has Terraform installed.
- **Git repo** - all of the pipeline config and Terraform code is hosted in a single ADO Git repo
- **Terraform state file** - the state file is hosted in the same Azure subscription, but this could be located on any storage account (permissions permitting)
- **Azure resource group** - the target resource group for the Service Bus instance is `env01-tfdemo-rg`. This will also be created by Terraform.

For easy reference, these are the files we'll be working with.

The pipeline yaml definitions can reside anywhere within our repo but I prefer to store them in a `/deploy` folder.

## Create the Service Principal

First things first, a Service Principal (SPN) is required to allow Terraform on the ADO build agent to authenticate against the Azure subscription and create Azure resources:

1. Within the Azure Portal, open **Microsoft Entra ID**
2. Create a new **App registration**, `tfdemo-spn` (accept the default settings)
3. Make a note of the *Application (client) ID* and *Directory (tenant) ID* as we'll need these later
4. Under Certificates & Secrets, create a new secret called `ADO`. Make a note of this value, too.

## Create the Terraform State Storage Account

Terraform stores its view of our infrastructure and associated metadata in a state file. The state file is central to Terraform's operation and must be stored in an appropriate location.

Storing the state file locally is fine for basic testing, but for automated deployments, it must be hosted somewhere the ADO build agent can access. Typically, this is an Azure blob storage account (or an S3 bucket if you're using AWS).

The steps below describe how to implement this part of the configuration (this is completed manually). Within the Azure Portal:

1. Create a new resource group, `tfstate-tfdemo-rg`
2. Create a new storage account, `tfstatedemostg` (accept all default configuration settings)
3. Create a `tfstate` blob container
4. Under **Access Control (IAM)** for the storage account, grant the *Storage Blob Data Contributor* role to the SPN

There's no need to manually create the tfstate file. This will be automatically be created when Terraform first runs within the pipeline.

## Set Azure Subscription Permissions

In the above step, we granted the SPN permission to write the `tfstate` file to the storage account. The SPN also needs additional permissions to deploy the Azure resources in the wider subscription.

Setting appropriate SPN permissions is a topic in itself, but for now, we'll grant the SPN **Contributor** permissions on the entire subscription. This allows Terraform on the build agent to create the `env01-tfdemo-rg` resource group and the Service Bus resources inside it:

1. Within the Azure Portal, browse to the target subscription
2. Select **Access control (IAM)**
3. Create a new **role assignment** and assign the SPN the *Contributor* role

An alternate approach is to pre-create the target resource group. This allows the SPN permissions to be more tightly scoped to the existing resource group instead of the entire subscription.

## Create the Service Bus Terraform Code

In this example, we'll keep it nice and simple and deploy a Service Bus namespace and two queues. This is the Terraform code, `servicebus.tf`:

```terraform
# Service Bus - namespace
resource "azurerm_servicebus_namespace" "sbus" {
  name                = "${var.project}-${var.environment}-sbns"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  
  tags = local.tags
  
  local_auth_enabled            = false
  minimum_tls_version           = "1.2"
  network_rule_set {
    default_action                = "Allow"     
    public_network_access_enabled = true
    trusted_services_allowed      = false
  }
  public_network_access_enabled = true
  sku                           = "Standard"
}
 
# Service Bus - queue01
resource "azurerm_servicebus_queue" "queue01" {
  name         = "queue01"
  namespace_id = azurerm_servicebus_namespace.sbus.id
 
  default_message_ttl                     = "P14D"
  dead_lettering_on_message_expiration    = false
  duplicate_detection_history_time_window = "PT10M"
  enable_batched_operations               = true
  enable_partitioning                     = false
  lock_duration                           = "PT1M"
  max_delivery_count                      = 10
  max_size_in_megabytes                   = 1024
  requires_duplicate_detection            = false
  requires_session                        = false
}
 
# Service Bus - queue02
resource "azurerm_servicebus_queue" "queue02" {
  name         = "queue02"
  namespace_id = azurerm_servicebus_namespace.sbus.id
 
  default_message_ttl                     = "P14D"
  dead_lettering_on_message_expiration    = false
  duplicate_detection_history_time_window = "PT10M"
  enable_batched_operations               = true
  enable_partitioning                     = false
  lock_duration                           = "PT1M"
  max_delivery_count                      = 10
  max_size_in_megabytes                   = 1024
  requires_duplicate_detection            = false
  requires_session                        = false
}
```

Also of interest is the `providers.tf` file. Here, we can see that the state file is configured to be hosted on the storage account we created earlier:

```terraform
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~>3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~>3.0"
    }
  }
  backend "azurerm" {
    resource_group_name  = "tfstate-tfdemo-rg"
    storage_account_name = "tfstatetfdemostg"
    container_name       = "tfstate"
    key                  = "tfdemo.env01.tfstate"
  }
}
 
provider "azurerm" {
  features {}
}
```

## Configure Azure DevOps

Within ADO, we need to configure a couple of things to get everything working.

### Create a Variable Group

The variable group contains the details of the Service Principal we created earlier. Terraform will use these values to authenticate against the target Azure subscription:

1. Create a variable group, `Terraform_SPN`, within **Pipelines → Library**
2. Create the following variables using the SPN's values from earlier:
   - `ARM_CLIENT_ID`
   - `ARM_CLIENT_SECRET`
   - `ARM_SUBSCRIPTION_ID`
   - `ARM_TENANT_ID`

These variable names are of special significance to Terraform. When set as environment variables within the ADO build agent, Terraform will automatically attempt to authenticate against Azure using their values.

### Create the ADO Environment

By creating an ADO environment and referencing it within our pipeline, we can add an approval step.

When deploying the pipeline, we want an opportunity to review the output from the **Terraform Plan** stage. Only once we're comfortable with the planned changes do we approve the **Terraform Apply** stage to create the resources.

To create an ADO environment:

1. Within **Pipelines → Environments** select **New Environment**
2. Set the name as `env01` and click **Create**
3. Once created, select **Approvals and Checks** and click "+"
4. Select **Next** and add the required approver, i.e. ourselves (fine-tune these settings as required for your organization)

### Create the Pipeline

For this example, I'm leveraging an Azure DevOps yaml template. If we wish to later scale out our deployments with multiple environments, etc., it is much easier to create a single reusable Terraform deployment pipeline.

First, the template deployment pipeline definition, `terraform-template.yml`:

```yaml
parameters:
- name: rootFolder
  type: string
- name: tfvarsFile
  type: string
- name: adoEnvironment
  type: string
 
stages:
- stage: 'Terraform_Plan'
  displayName: 'Terraform Plan'
  jobs:
  - job: 'Terraform_Plan'
    pool:
      vmImage: 'ubuntu-latest'
    steps:
    - script: |
        echo "Running Terraform init..."
        terraform init
        echo "Running Terraform plan..."
        terraform plan -var-file ${{ parameters.tfvarsFile }}
      displayName: 'Terraform plan'
      workingDirectory: ${{ parameters.rootFolder }}
      env:
        ARM_CLIENT_SECRET: $(ARM_CLIENT_SECRET) # this needs to be explicitly set as it's a sensitive value
 
- stage: 'Terraform_Apply'
  displayName: 'Terraform Apply'
  dependsOn:
  - 'Terraform_Plan'
  condition: succeeded()
  jobs:
  - deployment: 'Terraform_Apply'
    pool:
      vmImage: 'ubuntu-latest'
    environment: ${{ parameters.adoEnvironment }} # using an ADO environment allows us to add a manual approval check
    strategy:
      runOnce:
        deploy:
          steps:
          - checkout: self
          - script: |
              echo "Running Terraform init..."
              terraform init
              echo "Running Terraform apply..."
              terraform apply -var-file ${{ parameters.tfvarsFile }} -auto-approve
            displayName: 'Terraform apply'
            workingDirectory: ${{ parameters.rootFolder }}
            env:
              ARM_CLIENT_SECRET: $(ARM_CLIENT_SECRET)
```

And the pipeline definition, `tfdemo-env01-terraform.yml`, for our specific deployment (`tfdemo-env01-rg`) that calls the template above:

```yaml
name: Terraform - deploy Service Bus to env01
 
trigger: none
 
variables:
  - group: Terraform_SPN
  - name: rootFolder
    value: '/terraform/'
  - name: tfvarsFile
    value: 'tfdemo.env01.tfvars'
  - name: adoEnvironment
    value: 'env01'
  
stages:
- template: templates/terraform-template.yml
  parameters:
    rootFolder: $(rootFolder)
    tfvarsFile: $(tfvarsFile)
    adoEnvironment: $(adoEnvironment)
```

To create the pipeline:

1. **Pipelines → New pipeline**
2. Select **Azure Repos Git**
3. Select the repo, i.e. `tfdemo`
4. Select **Existing Azure Pipelines YAML file**. Note - we select the pipeline .yml rather than the template .yml
5. From the **Run** dropdown, select **Save**
6. The default pipeline name of `tfdemo` is fine, but this can be renamed to something more meaningful, i.e. `tfdemo-env01-terraform`

Browsing our list of pipelines, our newly created pipeline is now visible.

That's it! We've created a new pipeline, the variable group and ADO environment.

## Run and Test the Pipeline

Finally, we're ready to run the pipeline and deploy our Service Bus instance for the first time.

After the pipeline has completed the `Terraform_Plan` stage, we can validate what Terraform expects to deploy. As the Service Bus instance doesn't yet exist, it correctly states that it will be created.

Now we've satisfied ourselves that the `Terraform_Plan` stage is correct, click **Review** and **Approve** on the `Terraform_Apply` stage.

The pipeline takes a few minutes to complete and the resource group and Service Bus instance are created successfully.

On the first run of the pipeline, you will be prompted to grant access to the `Terraform_SPN` variable group and the `ENV01` environment. Just click **Permit** when prompted.

## Scaling the Deployment

In this example, we've deployed a single resource group with limited resources. But it's possible quite easily to scale this approach.

For example, imagine the scenario where we must deploy an application hosting environment. Depending on the application, this could include a multitude of Azure services such as an AKS cluster, storage accounts, Application Gateway, VNET, Azure SQL databases, etc.

These services can all be deployed to the same resource group to provide a self-contained hosting environment, i.e. DEV. We can then take this a step further by deploying additional environments, i.e. UAT, PROD, etc., by reusing the same Terraform and pipeline definitions.

The key to making this work is **parameterising everything** within the Terraform and pipeline definitions.

The diagram below shows how, by copying/pasting our existing definitions, and updating a few key values within them, replica environments can easily be deployed.

## Conclusion

I hope you found this post useful. In this example, we deployed a simple Terraform definition for an Azure Service Bus instance using an ADO pipeline. This Terraform code can easily be extended to deploy additional Azure services as required.
