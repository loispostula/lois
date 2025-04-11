+++
title = "Infrastructure-As-Code drift resolution using updatecli"
author = ["Loïs Postula"]
publishDate = 2025-04-11T00:00:00+02:00
lastmod = 2025-04-11T17:07:31+02:00
tags = ["updatecli", "iac"]
draft = false
+++

Managing your infrastructure using Infrastructure-As-Code (IaC) offers mutliple benefits: version control, repeatability, code-review, disaster recovery.

But what happens when external factors – database server version update, automatic upgrade of a key component from a cloud provider – modify your infrastructure outside of your IaC configuration?

This post details how we handle these situations, leveraging [updatecli](https://www.updatecli.io/) to keep our Infrastructure-As-Code in sync with the real world.


## Problem: {#problem}


### Deploy and manage an Azure Kubernetes Cluster with Terraform {#deploy-and-manage-an-azure-kubernetes-cluster-with-terraform}

Let's deploy an aks cluster using terraform:

```terraform { linenos=true, linenostart=1 }
resource "azurerm_kubernetes_cluster" "this" {
  name                      = "my-aks-cluster-dev"
  resource_group_name       = "rg-dev"
  location                  = "East US"
  ...
  kubernetes_version        = "1.30.0"
  automatic_upgrade_channel = "patch"
}
```
<div class="src-block-caption">
  <span class="src-block-number">Code Snippet 1:</span>
  main.tf
</div>

The important part is the `automatic_upgrade_channel` argument that is set to patch. This enable the [cluster auto-upgrade](https://learn.microsoft.com/en-us/azure/aks/auto-upgrade-cluster) mechanism in Azure and your Cluster will automatically upgrade based on the channel configuration.


### Issue with the setup {#issue-with-the-setup}

Anytime the cluster is auto-upgraded, we need to go in the configuration, update the value and rerun a `terraform apply`, otherwise we might revert the cluster to it's previous version.

```bash
?> terraform plan
Note: Objects have changed outside of Terraform
Terraform detected the following changes made outside of Terraform since the
last "terraform apply" which may have affected this plan:
  # azurerm_kubernetes_cluster.this has changed
  ~ resource "azurerm_kubernetes_cluster" "k8s" {
      ~ kube_config                         = (sensitive value)
      ~ kube_config_raw                     = (sensitive value)
        name                                = "my-aks-cluster-dev"
        # (35 unchanged attributes hidden)
        # (8 unchanged blocks hidden)
    }
Unless you have made equivalent changes to your configuration, or ignored the
relevant attributes using ignore_changes, the following plan may include
actions to undo or respond to these changes.
─────────────────────────────────────────────────────────────────────────────
Terraform used the selected providers to generate the following execution
plan. Resource actions are indicated with the following symbols:
  ~ update in-place
Terraform will perform the following actions:
  # azurerm_kubernetes_cluster.this will be updated in-place
  ~ resource "azurerm_kubernetes_cluster" "this" {
      ~ kubernetes_version                  = "1.30.11" -> "1.30.10"
        name                                = "my-aks-cluster-dev"
        # (36 unchanged attributes hidden)
        # (8 unchanged blocks hidden)
    }
Plan: 0 to add, 1 to change, 0 to destroy.
Changes to Outputs:
  ~ kubeconfig                     = (sensitive value)You can apply this plan to save these new output values to the Terraform
state, without changing any real infrastructure.
```


## Solution {#solution}


### Updatecli {#updatecli}

[updatecli](https://www.updatecli.io/) is a CLI tool designed to `Continuously update everything`

-   You read informations using [`source`](https://www.updatecli.io/docs/core/source/)
-   You test informations using [`condition`](https://www.updatecli.io/docs/core/condition/)
-   You update information using [`target`](https://www.updatecli.io/docs/core/target/)
-   You perform side-effect using [`action`](https://www.updatecli.io/docs/plugins/actions/github/)

You compose those core elements into a pipeline manifest that updatecli can run
![](/img/updatecli_pipeline.png)

One of the major benefits of `updatecli` is it's wide variety of plugins, for each core components, you can use different plugins:

-   [`csv`](https://www.updatecli.io/docs/plugins/resource/csv/)
-   [`helm chart`](https://www.updatecli.io/docs/plugins/resource/helm_chart/)
-   [`npm`](https://www.updatecli.io/docs/plugins/resource/npm/)
-   [`shell`](https://www.updatecli.io/docs/plugins/resource/shell/)
-   [`yaml`](https://www.updatecli.io/docs/plugins/resource/yaml/)
-   ...


### Pipeline {#pipeline}


#### Source {#source}

To solve our issue, we first need to get the current version of the kubernetes cluster, this could done using [`azure-cli`](https://learn.microsoft.com/en-us/cli/azure/)

```bash
az aks show --resource-group rg-dev --name my-aks-cluster-dev --query kubernetesVersion | tr -d '"'
```

We can use the `hcl` plugin to retrieve the resource group and cluster name, this gives us the following pipeline

```yaml { linenos=true, linenostart=1 }
name: Bump AKS Cluster Version

sources:
  cluster_name:
    kind: hcl
    spec:
      file: main.tf
      path: resource.azurerm_kubernetes_cluster.this.name
  cluster_resource_group:
    kind: hcl
    spec:
      file: main.tf
      path: resource.azurerm_kubernetes_cluster.this.resource_group_name
  version:
    kind: shell
    spec:
      command: az aks show --resource-group {{ source "cluster_resource_group" }} --name {{ source "cluster_name" }} --query kubernetesVersion
      environments:
        - name: PATH
    transformers:
      - trimprefix: '"'
      - trimsuffix: '"'
```
<div class="src-block-caption">
  <span class="src-block-number">Code Snippet 2:</span>
  update_cluster_version.yaml
</div>

This gives us our current Kubernetes cluster version

```bash
############################
# BUMP AKS CLUSTER VERSION #
############################

source: source#cluster_name
-------------------
✔ value "my-aks-cluster-dev", found in file "main.tf", for path "resource.azurerm_kubernetes_cluster.this.name"'

source: source#cluster_resource_group
-----------------------------
✔ value "rg-dev", found in file "main.tf", for path "resource.azurerm_kubernetes_cluster.this.resource_group_name"'

source: source#version
--------------
The shell 🐚 command "/bin/sh /tmp/updatecli/bin/477c15.sh" ran successfully with the following output:
----
"1.30.11"
----
✔ shell command executed successfully
[transformers]
✔ Result correctly transformed from "\"1.30.11\"" to "1.30.11\""
✔ Result correctly transformed from "1.30.11\"" to "1.30.11"
```

<!--list-separator-->

-  Updatecli considerations:

    -   `{{ source "cluster_resource_group" }}`: In updatecli, you can reference another resource of the pipeline and feed it in a resource definition.
    -   `shell#environments`: In order to use `azure-cli` we need to whitelist the `PATH` variable.[^fn:1]
    -   [`transformers`](https://www.updatecli.io/docs/core/transformer/): We can manipulate a source result to a format that better suit our need.


#### Target {#target}

Now that we have the version, we can update it in our terraform configuration

```yaml { linenos=true, linenostart=1 }
targets:
  cluster_version:
    kind: hcl
    sourceid: version
    spec:
      file: main.tf
      path: resource.azurerm_kubernetes_cluster.this.kubernetes_version
```
<div class="src-block-caption">
  <span class="src-block-number">Code Snippet 3:</span>
  update_cluster_version.yaml
</div>

```bash
############################
# BUMP AKS CLUSTER VERSION #
############################

source: source#cluster_name
-------------------
✔ value "my-aks-cluster-dev", found in file "main.tf", for path "resource.azurerm_kubernetes_cluster.this.name"'

source: source#cluster_resource_group
-----------------------------
✔ value "rg-dev", found in file "main.tf", for path "resource.azurerm_kubernetes_cluster.this.resource_group_name"'

source: source#version
--------------
The shell 🐚 command "/bin/sh /tmp/updatecli/bin/477c15.sh" ran successfully with the following output:
----
"1.30.11"
----
✔ shell command executed successfully
[transformers]
✔ Result correctly transformed from "\"1.30.11\"" to "1.30.11\""
✔ Result correctly transformed from "1.30.11\"" to "1.30.11"

target: target#cluster_version
----------------------

**Dry Run enabled**

⚠ - changes detected:
	path "resource.azurerm_kubernetes_cluster.this.kubernetes_version" updated from "1.30.0" to "1.30.11" in file "main.tf"

=============================

SUMMARY:



⚠ Bump AKS Cluster Version:
	Source:
		✔ [cluster_name]
		✔ [cluster_resource_group]
		✔ [version]
	Target:
		⚠ [cluster_version]


Run Summary
===========
Pipeline(s) run:
  * Changed:    1
  * Failed:     0
  * Skipped:    0
  * Succeeded:  0
  * Total:      1
```


#### Final pipeline {#final-pipeline}

```yaml { linenos=true, linenostart=1 }
name: Bump AKS Cluster Version

scms:
  default:
    kind: github
    spec:
      branch: "main"
      email: "me@example.com"
      owner: "updatecli"
      repository: "infra"
      username: "updatecli-bot"
      token: '{{ requiredEnv "GITHUB_TOKEN" }}'
      commitusingapi: true

actions:
  default:
    kind: "github/pullrequest"
    scmid: "default"
    spec:
      automerge: false
      draft: false
      title: "Bump AKS Version"

sources:
  cluster_name:
    kind: hcl
    scmid: default
    spec:
      file: main.tf
      path: resource.azurerm_kubernetes_cluster.this.name
  cluster_resource_group:
    kind: hcl
    scmid: default
    spec:
      file: main.tf
      path: resource.azurerm_kubernetes_cluster.this.resource_group_name
  version:
    kind: shell
    scmid: default
    spec:
      command: az aks show --resource-group {{ source "cluster_resource_group" }} --name {{ source "cluster_name" }} --query kubernetesVersion
      environments:
        - name: PATH
    transformers:
      - trimprefix: '"'
      - trimsuffix: '"'

targets:
  cluster_version:
    kind: hcl
    scmid: default
    sourceid: version
    spec:
      file: main.tf
      path: resource.azurerm_kubernetes_cluster.this.kubernetes_version
```
<div class="src-block-caption">
  <span class="src-block-number">Code Snippet 4:</span>
  update_cluster_version.yaml
</div>

We've added an `scm` configuration to pull our Infrastructure-As-Code configuration from our vsc. And we've added an `action` resource to create a pull request with our changes.


### Alternative {#alternative}

In this scenario, we are managing the drift in a reactive way, anytime the pipeline is run, if the version of the cluster differs, we update our IaC to reflect this. An alternative approach would be to disable automatic upgrade and use updatecli to find available version and update to it.

```yaml { linenos=true, linenostart=1 }
sources:
  # Fetch from github release
  kubernetes:
    kind: githubRelease
    spec:
      owner: "kubernetes"
      repository: "kubernetes"
      token: "{{ requiredEnv .github.token }}"
      username: "john"
      versionFilter:
        kind: latest
    transformers:
      - trimPrefix: "v"
   # Fetch with azurecli
  azurecli:
    kind: shell
    spec:
      command: az aks get-versions --location eastus --output json | jq -r '.values | map(select(.capabilities.supportPlan | index("AKSLongTermSupport") and index("KubernetesOfficial"))) | first | .patchVersions | keys | sort_by(split(".") | map(tonumber)) | reverse | first'
      environments:
        - name: PATH
```

This is the beauty of `updatecli`, given a version `X` tested by `Y`, we update `Z`, and `XYZ` can be any kind of plugins.

[^fn:1]: For security reason, Updatecli doesn't pass the entire environment to the shell command but instead works with an allow list of environment variables. <https://www.updatecli.io/docs/plugins/resource/shell/>
