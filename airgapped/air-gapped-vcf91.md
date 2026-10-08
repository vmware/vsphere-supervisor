# VKS Deployment Guide for VCF 9.1.0 air-gapped environments

## Introduction
vSphere Kubernetes Service (VKS) is the Kubernetes service that runs on top of vSphere Supervisor in VCF (VMware Cloud Foundation) and VVF (VMware vSphere Foundation) deployments. This guide describes the end-to-end procedure for deploying VKS clusters, Supervisor Services, and VKS Standard Packages in an air-gapped environment that has no direct internet access.

The procedure involves the following major steps:

1. Copy the required files and binaries from an internet-connected host to the air-gapped environment.
2. Enable Supervisor on a vCenter in the air-gapped environment.
3. Upload Kubernetes release OVAs to a vCenter Content Library.
4. Create vSphere Namespace(s) for the VKS clusters.
5. Configure the air-gapped Admin host.
6. Import the OCI images of Supervisor Services and VKS Standard Packages into the OCI registry on Software Depot.
7. Install the relevant Supervisor Services.
8. Deploy the VKS cluster(s).
9. Deploy the VKS Standard Packages on the VKS cluster(s).

The data flow of packages, binaries, and images between the internet-connected and air-gapped environments is summarized in the diagram below.

![image](depotreg-dataflow.png)

## Terminology
* **Bastion host** &mdash; A host (typically a Linux VM) that is connected to the Internet, or has access to download packages, binaries, and images from the Internet.
* **Admin host** &mdash; A host (typically a Linux VM) inside the air-gapped environment with no internet access. The Admin host has network connectivity to all hosts in the air-gapped environment. Files downloaded on the Bastion host are transferred to the Admin host, and administrators use the Admin host to interact with the platform.
* **VCF CLI** &mdash; The plugin-based CLI used to interact with Supervisor and VKS clusters.
* **VKS Standard Packages** &mdash; A curated set of services and add-ons (for example, cert-manager, Contour, Prometheus, Grafana) that administrators and users can install and manage on VKS clusters using the VCF CLI or relevant add-ons APIs.

## Prerequisites
* This guide applies to VCF / VVF 9.1.0 deployments. The OCI registry in VCF Software Depot is used as the OCI-compliant registry that hosts the OCI images for Supervisor Services and VKS Standard Packages.
* For VCF / VVF 9.1.1 and later deployments, please follow this [document](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-1/managing-vsphere-kubernetes-service/deploying-vks-in-airgappen-environment/deploy-vks-in-airgapped-environments.html) to leverage VCF download tool and VCF Software Depot for VKS deployments in airgapped environments.
* For VCF / VVF 9.0.0 deployments, an external OCI-compliant registry is required; please follow the [VKS Deployment Guide for VCF 9.0.0 air-gapped environments](/airgapped/air-gapped-vcf90.md) instead.
* For VCF / VVF deployments based on releases earlier than 9.0.0, an external OCI-compliant registry is required; please follow the legacy [VKS Deployment Guide for air-gapped environments](/airgapped/air-gapped.md) instead.

## Bill of Materials
The table below provides sample hostnames and versions used throughout the document for easy reference -

|Component|Version|Sample Hostname (where applicable)|
|---------|-------|----------------------------------|
|Bastion Host|Ubuntu 24.04.4|bastion.internet.lab.test|
|Admin Host (air-gapped)|Ubuntu 24.04.4 (identical to the Bastion Host)|admin.env1.lab.test|
|vCenter|9.1.0|vcenter.env1.lab.test|
|ESXi|9.1.0|esxi[0..xxx].env1.lab.test|
|Supervisor|9.1.0|supervisor0.env1.lab.test|
|VKS cluster|1.34.2|workload-vsphere-vks1|
|VKS Standard Packages|3.6.0-20260211||
|VKS Service|3.6.1||

In addition, the following packages and binaries should be installed on both the Bastion host and the Admin host:

* `wget`
* `curl`
* `ssh` and `sshpass`
* `docker` (preferably from the official Docker website &mdash; https://docs.docker.com/engine/install/)
* `jq`
* `yq` (some Linux distributions ship an older or alternative implementation of `yq`; the latest release is available at https://github.com/mikefarah/yq/releases)
* `openssl` for certificate generation and validation
* `imgpkg` for pulling and pushing Carvel package images &mdash; see https://carvel.dev/imgpkg/docs/develop/install/#via-script-macos-or-linux
* `python3` to run the image migration script &mdash; see https://www.python.org/downloads/
* Additional troubleshooting and diagnostic tools as needed.

## 1. Download all required plugins, binaries, and images
This stage uses the Ubuntu 24.04.4-based Bastion host (**bastion.internet.lab.test**). The following plugins, binaries, and packages must be downloaded; each plays a role in the platform deployment process.

### 1a. VMware vSphere Kubernetes release OVA files
VMware vSphere Kubernetes releases (VKrs) provide the Kubernetes software distribution for VKS clusters. VMware distributes Kubernetes releases as virtual machine templates, which you synchronize with the platform using a vCenter Content Library. Download the latest Kubernetes release files from https://wp-content.broadcom.com/v2/latest/. The versions to download depend on your workload requirements; we recommend downloading three or more of the latest versions. Follow [Step #3 in the official documentation](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-1/managing-vsphere-kubernetes-service/administering-kubernetes-releases-for-tkg-service-clusters/create-a-local-content-library-for-air-gapped-cluster-provisioning.html) to download the appropriate Kubernetes release files for each version. The VKR shipped with VCF 9.1.0 is version 1.34.2.

### 1b. VCF CLI and Plugins
The VCF CLI and its plugins are first installed on the Bastion host (`bastion.internet.lab.test`); the same tarballs are then transferred to the Admin host and installed there. At the time of writing, VCF CLI 9.1.0 is the supported version for vSphere and Supervisor 9.1.0.

In internet-connected VCF deployments, the VCF CLI binary can be downloaded from the vSphere Supervisor home page or from the VCF Automation Tenant Portal. In the internet-restricted environment that this guide covers, follow [Installing the VCF CLI in Internet Restricted Environments](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-consumption/latest/consumer-interfaces-in-vcf/installing-and-using-vcf-cli-v9/installing-the-vcf-cli-in-internet-connected-environments/installing-the-vcf-cli-in-internet-restricted-environments(2).html) to download the VCF Consumption CLI and its plugin bundle. The download steps are summarized below.

```bash
## Download VCF CLI and VCF CLI Plugins
1. Open a browser and navigate to https://support.broadcom.com.
2. Login with your account credentials.
3. Navigate to `My Downloads` page and search for `VCF consumption CLI`.
4. Click on `VCF consumption CLI` to navigate to the VCF consumption CLI download page.
5. Click on `CLI` link, then select release version 9.1.0 to download the desired VCF CLI tar for the target OS to run VCF CLI commands.
6. Click on `Plugin-Bundles` link, then select release version 9.1.0 to download the desired VCF CLI plugin bundle tar for the target OS to run VCF CLI commands.

## Install VCF CLI on the bastion host (Linux/amd64 example)
tar -xzvf ./VCF-Consumption-CLI-Linux_AMD64-9.1.0.tar.gz
sudo install ./vcf-cli-linux_amd64 /usr/local/bin/vcf

## Verify the installation
vcf version

## Sample output
version: v9.1.0.0.25296329
buildDate: 2026-03-20
sha: 987b58e
releaseType: ga
arch: amd64

## Install the desired VCF CLI plugins on the bastion host from the plugin bundle
mkdir -p ~/vcf-plugin-bundle
tar -xvzf VCF-Consumption-CLI-PluginBundle-Linux_AMD64-9.1.0.0.25305443.tar.gz -C ~/vcf-plugin-bundle/

## Install a single plugin (example: addon) or all plugins
vcf plugin install addon  --local-source ~/vcf-plugin-bundle/
vcf plugin install all --local-source ~/vcf-plugin-bundle/

## Verify the plugins are installed
vcf plugin list

# Sample output if all plugins are installed
  NAME                DESCRIPTION                                                                       INSTALLED  STATUS
  addon               Add-on lifecycle management                                                       v3.6.1     installed
  cluster             Kubernetes cluster operations                                                     v3.6.1     installed
  imgpkg              package, distribute, and relocate your configuration and dependent oci images as  v9.1.0     installed
                      one oci artifact
... (additional plugin lines truncated for brevity) ...
```

### 1c. Binaries and YAML files required for Supervisor Services
Supervisor Services are Carvel packages defined by a configuration file (the package YAML). The configuration file contains a reference to the image that holds the package manifest. Before migrating a Supervisor Service to the OCI registry on Software Depot, you must extract the package-manifest image reference from the YAML.

#### Download the package manifest YAMLs from the Broadcom Support Portal
Two package manifest YAML files must be downloaded for each Supervisor Service. Use the following steps to find them:

1. Log in to the [Broadcom Support Portal](https://support.broadcom.com).
2. Navigate to **My Downloads** and search for *Supervisor Services*.
3. Click the Supervisor Service you want to install (for example, *ArgoCD*).
4. Click the desired version to open the download page for that service version.
5. Download both of the following package manifest YAMLs:

| File Name on the download page | Purpose |
|--------------------------------|---------|
| Installation Package Manifest (VCF 9.0 or older and disconnected/airgapped VCF 9.1) | Used to identify the OCI image(s) to download from the source registry, as described below. |
| Installation Package Manifest (Internet Connected VCF 9.1 and newer) | Used later to register and install the service on a Supervisor after the images are uploaded to Software Depot. |

> [!NOTE]
> The downloaded files are named differently from the **File Name** labels shown on the portal. For ArgoCD 1.1.0, the first manifest is `supervisor-service-argocd-legacy-1.1.0-25100889.yml` and the second is `supervisor-service-argocd-depot-1.1.0-25100889.yml`.

#### Identify the image to download from the package manifest YAML
To extract the image reference, open the first manifest (the one with `legacy` in its filename) and look up the field `spec.template.spec.fetch.imgpkgBundle[].image` on the `Package` object. For example, in the ArgoCD Supervisor Service 1.1.0 configuration file `supervisor-service-argocd-legacy-1.1.0-25100889.yml`, the image reference that must be migrated to the air-gapped environment is:

`projects.packages.broadcom.com/vsphere/supervisor/argocd-service/1.1.0/argocd-service:v1.1.0_vmware.1`

```yaml
...
---
apiVersion: data.packaging.carvel.dev/v1alpha1
kind: Package
metadata:
  name: argocd-service.vsphere.vmware.com.1.1.0-25100889
spec:
  refName: argocd-service.vsphere.vmware.com
  template:
    spec:
      deploy:
      - kapp: {}
      fetch:
      - imgpkgBundle:
          image: projects.packages.broadcom.com/vsphere/supervisor/argocd-service/1.1.0/argocd-service:v1.1.0_vmware.1
...
```

#### Example: Download the ArgoCD Supervisor Service binaries and associated YAML files
At the time of writing, the latest ArgoCD Supervisor Service version is **1.1.0**. Refer to the vSphere Supervisor Services page on the Broadcom Support Portal for newer versions. Following the steps in [Download the package manifest YAMLs](#download-the-package-manifest-yamls-from-the-broadcom-support-portal), download both manifests for version 1.1.0:

* `supervisor-service-argocd-legacy-1.1.0-25100889.yml` (*Installation Package Manifest (VCF 9.0 or older and disconnected/airgapped VCF 9.1)*) &mdash; used **only** to look up the package-manifest image reference for migration (as described above).
* `supervisor-service-argocd-depot-1.1.0-25100889.yml` (*Installation Package Manifest (Internet Connected VCF 9.1 and newer)*) &mdash; the configuration file used to register and install the ArgoCD Supervisor Service on a Supervisor 9.1.0 cluster after the images are uploaded to Software Depot.

Run the following command from the Bastion host to download the image bundle as a tarball using the [`oci_image_depot_migrator.py`](/airgapped/scripts/oci_image_depot_migrator.py) Python script. The script requires the `imgpkg` CLI and a Python 3 runtime to be installed on the Bastion host.

```bash
## Show usage of the oci_image_depot_migrator.py script
./oci_image_depot_migrator.py --help

## Sample output
usage: oci_image_depot_migrator.py [-h] -s REPO [-t FQDN] [--work-dir WORK_DIR] ACTION

Migrate OCI images from projects.packages.broadcom.com to a target Software Depot.

Action is a required positional argument:
  download | upload | copy | map-target-repo

Common options:
  -s / --source-image-repo  REPO   always required
  -t / --target-depot-fqdn  FQDN   required for upload, copy, map-target-repo
  --work-dir DIR                   where tars and depot-ca.crt live (default: cwd)

positional arguments:
  ACTION                download | upload | copy | map-target-repo (see examples below).

options:
  -h, --help            show this help message and exit
  -s REPO, --source-image-repo REPO
                        Source bundle reference, e.g. projects.packages.broadcom.com/.../image:tag
  -t FQDN, --target-depot-fqdn FQDN
                        Target Software Depot FQDN. Required for upload, copy, and map-target-repo.
  --work-dir WORK_DIR   Directory for .tar, depot-ca.crt, and imgpkg cwd. Default: current working directory.

Actions:
  download          Download OCI tars to local --work-dir.
                    Uses imgpkg copy -b <REPO> --to-tar <derived>.tar.
                    Requires -s. -t is not required. The tar is kept on disk.

  upload            Upload an existing OCI tar to the target depot.
                    Expects a tar under --work-dir whose name matches the one
                    that download would produce for the same -s argument.
                    Requires -s and -t. Tar and depot CA are deleted on success.

  copy              Copy OCI images from source repo to target depot.
                    Does download + upload in one run and expects connectivity to both source and target.
                    Requires -s and -t. Temporary tar and depot CA are deleted on success.

  map-target-repo   Print the target Software Depot repo URL for a given OCI image (no tag).
                    Pure path conversion; does not run imgpkg to download or upload.
                    Requires -s and -t.

Tar naming:
  Basename is derived from the last segment of the source reference.
  ':' and unsafe characters are normalized.
  Example: .../argocd-service:v1.1.0_vmware.1 -> argocd-service-v1.1.0_vmware.1.tar

Examples:
  oci_image_depot_migrator.py copy \
      -s 'projects.packages.broadcom.com/.../argocd-service:v1.1.0_vmware.1' \
      -t 'fleet-10-144-79-70.vcfd.broadcom.net'

  oci_image_depot_migrator.py download \
      -s 'projects.packages.broadcom.com/.../image:tag'

  oci_image_depot_migrator.py upload \
      -s 'projects.packages.broadcom.com/.../image:tag' \
      -t 'fleet-10-144-79-70.vcfd.broadcom.net'

  oci_image_depot_migrator.py map-target-repo \
      -s 'projects.packages.broadcom.com/.../image:tag' \
      -t 'fleet-10-144-79-70.vcfd.broadcom.net'

## Download ArgoCD Supervisor Service Binaries
./oci_image_depot_migrator.py download -s projects.packages.broadcom.com/vsphere/supervisor/argocd-service/1.1.0/argocd-service:v1.1.0_vmware.1

## Sample output
oci_image_depot_migrator — download operation:
  Download the image bundle from the source repository as a local tar file (imgpkg copy -b … --to-tar). The tar is kept after this command finishes.

  Source bundle:  projects.packages.broadcom.com/vsphere/supervisor/argocd-service/1.1.0/argocd-service:v1.1.0_vmware.1
  Work directory: /root
  Output tar:       /root/argocd-service-v1.1.0_vmware.1.tar

+ imgpkg copy -b projects.packages.broadcom.com/vsphere/supervisor/argocd-service/1.1.0/argocd-service:v1.1.0_vmware.1 --to-tar /root/argocd-service-v1.1.0_vmware.1.tar --cosign-signatures
copy | exporting 6 images...
copy | will export projects.packages.broadcom.com/vsphere/supervisor/argocd-service/1.1.0/argocd-service@sha256:079b2362c304475fce764e74787e2dfca0fa55c5c794f44ed8026b9a2dd165f4
... (additional layer/SHA lines truncated for brevity) ...
copy | exported 6 images
copy | writing layers...
copy | done: file 'manifest.json' (123.918µs)
... (additional layer/SHA lines truncated for brevity) ...

Succeeded
/root/argocd-service-v1.1.0_vmware.1.tar
Done.
```

A bundle tar file named `argocd-service-v1.1.0_vmware.1.tar` is created in the same directory as the script. Repeat the same steps for every Supervisor Service that you intend to install in the air-gapped environment. The Supervisor Service configuration YAML files are available on the [Broadcom Support Portal](https://support.broadcom.com): after logging in, navigate to **My Downloads** and search for *vSphere Supervisor Services*. At the time of writing, the latest VKS Service version is **3.6.3**; download this version because it is required for the VKS upgrade later in this guide.

The table below provides the sample list of Supervisor Services that can be downloaded from Broadcom Support Portal and installed on the platform -

|Service Name|Type|Version|
|------------|----|-------|
|VKS Service|Core|3.6.3|
|ArgoCD|Standard|1.1.0|
|CA Cluster Issuer|Standard|0.0.2|
|Consumption Interface|Standard|9.1.0|
|Contour|Standard|1.33.1|
|ExternalDNS|Standard|0.18.0|
|Harbor|Standard|2.14.2|
|Metrics Aggregator|Standard|0.1.0|
|Supervisor Management Proxy|Standard|0.4.1|

If your air-gapped environment does not have VCF Automation installed, you must also download the Harbor Supervisor Service image so it can be uploaded to the OCI registry on Software Depot for later installation. The Harbor Supervisor Service shipped with VCF 9.1.0 includes two configuration YAMLs:

* `legacy-harbor-svs-v2.14.2+vmware.2-vks.1-25220498.yml` &mdash; used only to look up the package-manifest image reference for migration.
* `harbor-svs-v2.14.2+vmware.2-vks.1-25512404.yml` &mdash; the configuration YAML used with Software Depot when registering and installing Harbor.

Use the following command to download the Harbor 9.1.0 package image bundle.

```bash
./oci_image_depot_migrator.py download -s projects.packages.broadcom.com/vsphere/supervisor/harbor-service/2.14.2/harbor:v2.14.2_vmware.2-vks.1
```

### 1d. VKS Standard Packages
VKS Standard Packages let administrators and users add and manage standard services and add-ons on VKS clusters by using the VCF CLI or Carvel custom resources. Examples include `cert-manager`, Contour, Prometheus, Grafana, and more. Use the [`oci_image_depot_migrator.py`](scripts/oci_image_depot_migrator.py) script to download the VKS Standard Packages bundle as a local tar file (for example, `vks-standard-packages-3.6.0-20260211.tar`) into the script directory:

```bash
./oci_image_depot_migrator.py download -s projects.packages.broadcom.com/vsphere/supervisor/vks-standard-packages/3.6.0-20260211/vks-standard-packages:3.6.0-20260211
```

### Summary
The following files, binaries, and packages have been successfully downloaded in this section and **must be transferred to the Admin host**.
* Kubernetes Release OVA files.
* VCF CLI tar (e.g. `VCF-Consumption-CLI-Linux_AMD64-9.1.0.tar.gz`).
* VCF CLI plugin bundle tar (e.g. `VCF-Consumption-CLI-PluginBundle-Linux_AMD64-9.1.0.tar.gz`).
* VKS Add-on bundle tar produced by the image migrator (e.g. `vks-standard-packages-3.6.0-20260211.tar`). This file can be gzipped if needed.
* Supervisor Service image bundle tars and their configuration YAML files.

## 2. Enable the Supervisor
Using the steps and directions in the official [documentation](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-9-0-and-later/9-1/vsphere-supervisor-installation-and-configuration.html), configure the required networking, storage policies, and profiles and enable the Supervisor on `vcenter.env1.lab.test`.

## 3. Create a Kubernetes release content library and upload Kubernetes release images
The Kubernetes release OVAs downloaded on the Bastion host and copied to the Admin host must be uploaded to a Content library within the vCenter. Before proceeding, a local content library must be created. The "Create a Local Content Library (for air-gapped Cluster Provisioning)" [documentation](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-9-0-and-later/9-1/vsphere-supervisor-installation-and-configuration/updating-vsphere-supervisor/updating-the-vsphere-with-tanzu-environment/configuring-a-subscribed-content-library-for-supervisor-images-in-air-gapped-environment/create-a-remote-content-library-pulisher-in-a-local-environment.html) provides instructions on creating and importing Kubernetes Release (Kr) images into the content library. **Step #12** provides details on files (downloaded previously in step 1a) that need to be uploaded to the local content library.

## 4. Create vSphere Namespace(s) for VKS Clusters(s)
If not already created, a vSphere namespace should be created. Refer to "[Create and Configure a vSphere Namespace on the Supervisor](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-9-0-and-later/9-1/vsphere-supervisor-installation-and-configuration/configuring-and-managing-vsphere-namespaces/create-and-configure-a-vsphere-namespace.html)" to configure the vSphere Namespace.

## 5. Configure Admin host
The Admin host (**admin.env1.lab.test**) is essential for the remaining deployment stages. It is used to upload binaries and image bundles to the registry, deploy VKS clusters, and install add-on packages on those clusters &mdash; effectively the control center for the air-gapped deployment. This guide uses an Ubuntu 24.04.4 system with Docker installed. If Docker is not installed, follow the [official Docker documentation](https://docs.docker.com/engine/install/ubuntu/) (some steps must be adapted for an air-gapped installation). The recommended Admin host configuration is:
* CPU: 2 vCPUs
* Memory: 4 GB
* Storage: 150–200 GB of free space

Note: Before moving forward, verify that all the files mentioned in the Summary section in Step 1 have been successfully copied to the Admin host.

### 5a. Download and install kubectl
`kubectl` is the standard command-line tool for interacting with Kubernetes clusters; it is used in this guide to manage Supervisor and VKS clusters together with the VCF CLI. The legacy `kubectl-vsphere` plugin has been deprecated in vSphere 9.1.0 and replaced by the VCF CLI; it is not required for this guide.

You can download and install the `kubectl` binary on the Admin host either from the Supervisor Cluster Kube-API server UI or by running the commands below.

```bash
wget https://<Supervisor-KubeAPI-Endpoint>/wcp/plugin/linux-amd64/vsphere-plugin.zip --no-check-certificate

## Sample Command:
wget https://supervisor0.env1.lab.test/wcp/plugin/linux-amd64/vsphere-plugin.zip --no-check-certificate

## After downloading the vsphere-plugin.zip file, use the following commands to unzip it and add the kubectl binary to the executable path.
unzip ./vsphere-plugin.zip
cd ./bin
sudo install kubectl /usr/local/bin/kubectl

## Verify the version by executing the below command
kubectl version
```

### 5b. Log in to the Supervisor
Log in to the Supervisor using the VCF CLI. The VCF CLI and the required plugins were transferred from the Bastion host in step 1b; install them on the Admin host with the same `vcf plugin install ...` commands shown there before continuing.

Before running VCF CLI commands, download and install the vCenter trusted root CA certificates so that VCF CLI can trust the certificate of the Supervisor.

```bash
# Download vCenter trusted root CA certificates with below command or download via the "Download trusted root CA certificates" link on the vCenter login UI.
wget https://<vCenter-IP>/certs/download.zip --no-check-certificate

# Unzip and install the trusted root CA certificates
unzip download.zip -d .
cd certs/lin
for f in *; do cp $f /etc/ssl/certs/$f.crt; done

# Connect to vSphere Namespace using VCF CLI
vcf context create <context-name> --endpoint <SupervisorAPIEndpoint> --username <sso_username> --type k8s
vcf context use <context-name>:<namespace-name>

## Sample Command to login and use context of namespace ns01 for VKS cluster deployment later.
vcf context create supervisor1 --endpoint https://supervisor0.env1.lab.test --username administrator@vsphere.local --type k8s
vcf context use supervisor1:ns01
```

### 5c. Enable OCI image upload on Software Depot

The Software Depot in VCF Fleet runs a OCI registry, which does not allow OCI image push by default. Use the [`toggle_software_depot_oci_image_upload.sh`](scripts/toggle_software_depot_oci_image_upload.sh) script to enable OCI image upload on the Fleet Software Depot. The script requires the VSP FQDN and the VSP admin credentials.

To find the VSP FQDN, log in to the VCF Operations UI and navigate to **Build &rarr; Lifecycle &rarr; VCF Management &rarr; Components &rarr; VSP**.

> [!IMPORTANT]
> After all required OCI uploads are complete, you must run the script with the `disable` action to turn off OCI image uploads to Software Depot since the uploading is not gated with auth, and you can enable the uploads again when more image uploads are needed later.

```bash
./toggle_software_depot_oci_image_upload.sh enable \
    --vsp-host       <vsp-host-fqdn>       \
    --admin-username <admin-username>      \
    --admin-password '<admin-password>'

## Sample command to enable OCI image upload on Software Depot
./toggle_software_depot_oci_image_upload.sh enable \
    --vsp-host           vcf-stls-wcp-pod13-136.lvn.broadcom.net \
    --admin-username admin@vsp.local                             \
    --admin-password 'Test!23Test!23'

Mode: enable (offlineWriteEnabled=true)
VSP URL: https://vcf-stls-wcp-pod13-136.lvn.broadcom.net
Payload:
{
  "spec": {
    "configuration": {
      "oci": {
        "offlineWriteEnabled": true
      }
    }
  }
}

==> Logging in to obtain access token...
==> Looking up vcf-fleet-depot component id...
    vcf-fleet-depot id: 0da90acd-84e7-498a-9cb0-8d0990c9a30c
==> Applying configuration update...
    task id: txrzuhy23zfipp4vnp54cvmzoe
==> Waiting for task to complete...
Still waiting for task to be done... (current status: Pending)
Still waiting for task to be done... (current status: Pending)
... (additional waiting lines truncated for brevity) ...
Still waiting for task to be done... (current status: Running)
Software Depot config update is success!

```

## 6. Upload packages to the Software Depot

### 6a. Upload Supervisor Services to the OCI registry on Software Depot
All Supervisor Service image bundles downloaded in step 1c must be uploaded to the Software Depot using the [`oci_image_depot_migrator.py`](scripts/oci_image_depot_migrator.py) script. The Software Depot FQDN is required for the upload. The script will upload the image(s) to a repo on the Software Depot that can support the image reference in a Supervisor Service package yaml, for example, the image will be pushed to /vcf-service-argocd/ga/1.1.0/argocd-service:v1.1.0_vmware.1 for image path /vcf/vcf-service-argocd/ga/1.1.0/argocd-service:v1.1.0_vmware.1 in the ArgoCD service package yaml.

```bash
./oci_image_depot_migrator.py upload -s <supervisor-service-package-image-on-projects.packages.broadcom.com> -t <software-depot-fqdn>

## Sample Command for ArgoCD Supervisor Service with example Software Depot FQDN as the target: fleet-10-144-79-70.vcfd.broadcom.net
./oci_image_depot_migrator.py upload -s projects.packages.broadcom.com/vsphere/supervisor/argocd-service/1.1.0/argocd-service:v1.1.0_vmware.1 -t fleet-10-144-79-70.vcfd.broadcom.net

## Sample Output
oci_image_depot_migrator — upload operation:
  1) Use the existing local tar (must match the name derived from --source-image-repo).
  2) Map the source repo path to the target depot repo URL (see below).
  3) Fetch the target depot TLS certificate, then upload the tar with imgpkg.
  4) Remove the temporary tar and certificate files after a successful upload.

  Source bundle (for path mapping & tar name): projects.packages.broadcom.com/vsphere/supervisor/argocd-service/1.1.0/argocd-service:v1.1.0_vmware.1
  Target depot FQDN: fleet-10-144-79-70.vcfd.broadcom.net
  Target repo URL:   fleet-10-144-79-70.vcfd.broadcom.net/vcf-service-argocd/ga/1.1.0/argocd-service
  Work directory:    /root
  Tar file:          /root/argocd-service-v1.1.0_vmware.1.tar
  Temporary CA file: /root/depot-ca.crt

Step 2: Source repo path maps to the target repo URL above (used as --to-repo).
Step 3: Fetching target depot TLS certificate…
+ openssl s_client -connect fleet-10-144-79-70.vcfd.broadcom.net:443 -showcerts | awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/' > /root/depot-ca.crt
+ imgpkg copy --tar /root/argocd-service-v1.1.0_vmware.1.tar --to-repo fleet-10-144-79-70.vcfd.broadcom.net/vcf-service-argocd/ga/1.1.0/argocd-service --cosign-signatures --registry-ca-cert-path /root/depot-ca.crt
copy | importing 6 images...
... (additional progress output truncated for brevity) ...
```

If the Admin host is located in a DMZ and has connectivity to `projects.packages.broadcom.com`, you can use `copy` to download from the source and upload to the Software Depot in a single step:

```bash
./oci_image_depot_migrator.py copy -s <supervisor-service-package-image-on-projects.packages.broadcom.com> -t <software-depot-fqdn>

## Sample Command for ArgoCD Supervisor Service (target: fleet-10-144-79-70.vcfd.broadcom.net)
./oci_image_depot_migrator.py copy -s projects.packages.broadcom.com/vsphere/supervisor/argocd-service/1.1.0/argocd-service:v1.1.0_vmware.1 -t fleet-10-144-79-70.vcfd.broadcom.net
```

### 6b. Upload VKS Standard Packages to the OCI registry on Software Depot
The VKS Standard Packages bundle, downloaded in step 1d, must be uploaded to the OCI registry on Software Depot using the [`oci_image_depot_migrator.py`](scripts/oci_image_depot_migrator.py) script. The upload command requires the Software Depot FQDN. To find it, log in to VCF Operations and navigate to **Build &rarr; Lifecycle &rarr; VCF Management &rarr; Components**; the FQDN is shown for the Fleet components.

```bash
./oci_image_depot_migrator.py upload -s projects.packages.broadcom.com/vsphere/supervisor/vks-standard-packages/3.6.0-20260211/vks-standard-packages:3.6.0-20260211 -t <software-depot-fqdn>

## Sample Command with example Software Depot FQDN as the target: fleet-10-144-79-70.vcfd.broadcom.net
./oci_image_depot_migrator.py upload -s projects.packages.broadcom.com/vsphere/supervisor/vks-standard-packages/3.6.0-20260211/vks-standard-packages:3.6.0-20260211 -t fleet-10-144-79-70.vcfd.broadcom.net
```

If the Admin host is located in a DMZ and has connectivity to `projects.packages.broadcom.com`, you can copy the VKS Standard Packages bundle directly from the source to the Software Depot in a single step:

```bash
./oci_image_depot_migrator.py copy -s projects.packages.broadcom.com/vsphere/supervisor/vks-standard-packages/3.6.0-20260211/vks-standard-packages:3.6.0-20260211 -t  <software-depot-fqdn>

## Sample Command with example Software Depot FQDN as the target: fleet-10-144-79-70.vcfd.broadcom.net
./oci_image_depot_migrator.py copy -s projects.packages.broadcom.com/vsphere/supervisor/vks-standard-packages/3.6.0-20260211/vks-standard-packages:3.6.0-20260211 -t fleet-10-144-79-70.vcfd.broadcom.net
```

If your air-gapped environment does not have VCF Automation installed, you must also upload the Harbor Supervisor Service image to the OCI registry on Software Depot. The command below uploads the Harbor 9.1.0 package image:

```bash
./oci_image_depot_migrator.py upload -s projects.packages.broadcom.com/vsphere/supervisor/harbor-service/2.14.2/harbor:v2.14.2_vmware.2-vks.1 -t <software-depot-fqdn>
```

### 6c. Disable OCI image upload on Software Depot

By default OCI image push on the Software Depot OCI registry should be disabled since the OCI image push is not gated with auth, use the same [`toggle_software_depot_oci_image_upload.sh`](scripts/toggle_software_depot_oci_image_upload.sh) script as described in section 5c to disable OCI image upload on the Fleet Software Depot.

```bash
./toggle_software_depot_oci_image_upload.sh disable \
    --vsp-host       <vsp-host-fqdn>        \
    --admin-username <admin-username>       \
    --admin-password '<admin-password>'

## Sample command to disable OCI image uploads on Software Depot
./toggle_software_depot_oci_image_upload.sh disable \
    --vsp-host       vcf-stls-wcp-pod13-136.lvn.broadcom.net \
    --admin-username admin@vsp.local                         \
    --admin-password 'Test!23Test!23'

Mode: disable (offlineWriteEnabled=false)
VSP URL: https://vcf-stls-wcp-pod13-136.lvn.broadcom.net
Payload:
{
  "spec": {
    "configuration": {
      "oci": {
        "offlineWriteEnabled": false
      }
    }
  }
}
==> Logging in to obtain access token...
==> Looking up vcf-fleet-depot component id...
    vcf-fleet-depot id: 0da90acd-84e7-498a-9cb0-8d0990c9a30c
==> Applying configuration update...
    task id: xyy7bylqqbgbvpc45ug5xtesia
==> Waiting for task to complete...
Still waiting for task to be done... (current status: Pending)
Still waiting for task to be done... (current status: Pending)
... (additional waiting lines truncated for brevity) ...
Still waiting for task to be done... (current status: Running)
Software Depot config update is success!
```

## 7. Ensure Harbor is configured on Supervisor

In a VCF deployment that includes VCF Automation, follow [Using Harbor as a VCF service documentation](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-1/using-harbor-as-vcf-service/using-harbor-as-a-vcf-service.html) to install and configure Harbor as a VCF service on a Supervisor in a VCF region. Once Harbor VCF service is up and the corresponding Supervisor Service images and VKS Standard Packages images are uploaded to the OCI registry on Software Depot, Supervisor Services and VKS Standard Packages can be installed using the same workflows as in an internet-connected environment.

If your VCF deployment does not include VCF Automation, or you are running a VVF deployment, perform step 7a and 7b first, then follow [Deploy Harbor Supervisor Service in VVF without VCFA](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-1/using-harbor-as-vcf-service/installing-and-configuring-harbor-and-contour/deploy-harbor-supervisor-service-in-vvf-without-vcfa.html) to install the Harbor Supervisor Service manually.

### 7a. Configure a management proxy on the Supervisor to pull Harbor images from Software Depot

Software Depot lives on the management network, so a management proxy is required to pull Harbor Supervisor Service images from it. The [`manage-depot-image-proxy.sh`](scripts/manage-depot-image-proxy.sh) script can add and remove this management proxy on a Supervisor in a vCenter. It requires that the Software Depot endpoint is already configured on the vCenter and that you have the vCenter and Supervisor identifiers along with the necessary credentials. If the Supervisor is configured with a proxy for image pulling, this domain `depot-image-proxy.kube-system.svc.cluster.local` should be added to the list of hosts excluded from the configured supervisor proxy via Supervisor proxy configuration UI or API.
```bash
./manage-depot-image-proxy.sh -h

## Sample Output
Usage:
  manage-depot-image-proxy.sh add    VC_HOST VC_ROOT_SSH_PASSWORD VC_ADMIN_USER VC_ADMIN_PASSWORD SUPERVISOR_ID
  manage-depot-image-proxy.sh remove VC_HOST VC_ROOT_SSH_PASSWORD VC_ADMIN_USER VC_ADMIN_PASSWORD SUPERVISOR_ID

  VC_HOST                 vCenter host domain (must match server cert; SSH as root; also REST https host)
  VC_ROOT_SSH_PASSWORD    root password for sshpass to vCenter
  VC_ADMIN_USER           vCenter API user (e.g. administrator@vsphere.local)
  VC_ADMIN_PASSWORD       vCenter API password
  SUPERVISOR_ID           Supervisor ID for container-image-registries

Requires: ssh, sshpass on your workstation (vCenter hop). On vCenter: sshpass must also be
installed for Control Plane VM hops (password from decryptK8Pwd.py PWD: line). Passwords may be visible
in process listings; quote arguments that contain shell metacharacters.

VC_ROOT_SSH_PASSWORD is only for workstation -> vCenter (root). Supervisor Control Plane VM root SSH from
vCenter uses the PWD value from /usr/lib/vmware-wcp/decryptK8Pwd.py for the matched cluster.

Options:
  -h, --help    Show this message

## Command to add a management proxy to a Supervisor
./manage-depot-image-proxy.sh add <VC_HOST> <VC_ROOT_SSH_PASSWORD> <VC_ADMIN_USER> <VC_ADMIN_PASSWORD> <SUPERVISOR_ID>

## Sample command and output
./manage-depot-image-proxy.sh add lvn-dvm-10-162-200-127.dvm.lvn.broadcom.net 'OOKMwN_Kp_r8wlg8' administrator@vsphere.local 'OOKMwN_Kp_r8wlg8' 284256be-074e-4750-8c9b-f57dfea4fb0a
Warning: Permanently added '10.161.117.40' (ED25519) to the list of known hosts.

VMware vCenter Server
Release: 9.1.0.0
Version: 9.1.0.0
Build: 25370922
Type: vCenter Server with an embedded Platform Services Controller

Supervisor topology clusters: domain-c52
Matched cluster_id=domain-c52 floating_ip=10.161.112.94
Control Plane VM management IPs (3): 10.161.119.189 10.161.115.81 10.161.117.145
Generated CA and server cert in /tmp/depot-image-proxy.mA5QH9
Configuring control plane VM 10.161.119.189 ...
Warning: Permanently added '10.161.119.189' (ECDSA) to the list of known hosts.
Welcome to Supervisor on vSphere Zones!
Warning: Permanently added '10.161.119.189' (ECDSA) to the list of known hosts.
Welcome to Supervisor on vSphere Zones!
service/depot-image-proxy created
deployment.apps/coredns restarted
Done control plane VM 10.161.119.189
Configuring control plane VM 10.161.115.81 ...
Warning: Permanently added '10.161.115.81' (ECDSA) to the list of known hosts.
Welcome to Supervisor on vSphere Zones!
Warning: Permanently added '10.161.115.81' (ECDSA) to the list of known hosts.
Welcome to Supervisor on vSphere Zones!
service/depot-image-proxy unchanged
deployment.apps/coredns restarted
Done control plane VM 10.161.115.81
Configuring control plane VM 10.161.117.145 ...
Warning: Permanently added '10.161.117.145' (ECDSA) to the list of known hosts.
Welcome to Supervisor on vSphere Zones!
Warning: Permanently added '10.161.117.145' (ECDSA) to the list of known hosts.
Welcome to Supervisor on vSphere Zones!
service/depot-image-proxy unchanged
deployment.apps/coredns restarted
Done control plane VM 10.161.117.145
Registered depot-registry with supervisor 284256be-074e-4750-8c9b-f57dfea4fb0a (HTTP 201)
All steps finished (add).
```

### 7b. Update the image reference in the Harbor Supervisor Service package YAML
The Harbor package YAML downloaded in step 1c (`harbor-svs-v2.14.2+vmware.2-vks.1-25512404.yml`) must have its `image` reference updated so the images are pulled through the management proxy from Software Depot. The original reference looks like this:

```yaml
      fetch:
        - imgpkgBundle:
            image: "depot.kube-system.svc/vcf/vcf-supervisor-services/supervisor-service-harbor/ga/2.14.2/harbor:v2.14.2_vmware.2-vks.1"
```

Replace it with the management-proxy URL:

```yaml
      fetch:
        - imgpkgBundle:
            image: "depot-image-proxy.kube-system.svc.cluster.local/supervisor-service-harbor/ga/2.14.2/harbor:v2.14.2_vmware.2-vks.1"
```

After updating the YAML, register the Harbor package YAML on the vCenter, then follow the [Deploy Harbor Supervisor Service in VVF without VCFA](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-1/using-harbor-as-vcf-service/installing-and-configuring-harbor-and-contour/deploy-harbor-supervisor-service-in-vvf-without-vcfa.html) document to install the Harbor Supervisor Service on the Supervisor and configure Software Depot as the upstream registry for Supervisor Services and other component images.

## 8. Deploy VKS Cluster(s)

### 8a. Update vSphere Kubernetes Service (VKS) to the latest version
At the time of writing, the latest VKS release is 3.6.3. Each VKS release introduces additional features and fixes, so it is recommended to apply these updates before deploying clusters. This guide updates the core VKS Service from 3.6.1 to 3.6.3. This step requires that the VKS 3.6.3 binary tar and configuration YAML files have already been downloaded on the Bastion host and uploaded to the OCI registry on Software Depot using the previous steps. Follow the [Upgrade the VKS Service version](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-1/managing-vsphere-kubernetes-service/installing-and-upgrading-the-tkg-service/upgrade-the-tkg-service-version.html) procedure in the official documentation to complete the upgrade.

### 8b. Deploy a workload cluster
Deploy a VKS cluster (an Ubuntu-based example is shown below). Review each section of the cluster configuration and adjust fields to suit your environment. For details, see the [Workflow for Provisioning VKS Clusters Using `kubectl`](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-consumption/latest/managing-vsphere-kuberenetes-service-clusters-and-workloads/provisioning-tkg-service-clusters/workflow-for-provisioning-tkg-clusters-using-kubectl.html) and the [v1beta1 default cluster example](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-consumption/latest/managing-vsphere-kuberenetes-service-clusters-and-workloads/provisioning-tkg-service-clusters/using-the-cluster-v1beta1-api/using-the-versioned-clusterclass/v1beta1-example-default-cluster.html).

The `Cluster` v1beta1 / v1beta2 API supports many configuration options. The snippet below shows the additional variables you can set to apply a default `podSecurityStandard`:
```yaml
## vksConfig.yaml
...
    variables:
      - name: podSecurityStandard
        value:
          audit: restricted
          auditVersion: latest
          enforce: privileged
          enforceVersion: latest
          warn: privileged
          warnVersion: latest
...
```

```bash
## Deploy the VKS cluster
kubectl create -f <vksConfig.yaml> -n ns01

## Check the status of cluster creation
kubectl get cluster -n ns01
kubectl describe cluster workload-vsphere-vks1 -n ns01
```

### 8c. Deploy VKS Standard Package(s) on a workload cluster
VKS Standard Packages can be deployed from the VKS Standard repository using the VCF CLI from the Admin host. The example below uses `cert-manager` to illustrate the workflow.

Log in to the VKS workload cluster using the VCF CLI from the Admin host. (The `kubectl-vsphere` plugin is deprecated in vSphere 9.1.0; use `vcf context` instead.)

```bash
## Create a VCF CLI context for the Supervisor (if not already created in 5b)
vcf context create <context-name> --endpoint <SupervisorAPIEndpoint> --username <sso_username> --type k8s

## Switch the active context to the target VKS workload cluster
vcf context use <context-name>:<vsphere-namespace>:<vks-cluster-name>

## Sample commands
vcf context create supervisor1 --endpoint https://supervisor0.env1.lab.test --username administrator@vsphere.local --type k8s
vcf context use supervisor1:ns01:workload-vsphere-vks1
```

After Harbor is installed and configured successfully on the Supervisor in step 7, the default add-on package repository (pointing to Harbor) will be configured and installed automatically. Verify the add-on repository and list the available packages:

```bash
vcf addon repository list

## Sample output
  NAME                                           NAMESPACE                 SOURCE
  default-addonrepository-3.6.0                  vmware-system-vks-public  projects.packages.broadcom.com/vsphere/supervisor/vks-standard-packages/3.6.0-20260211/vks-standard-packages:3.6.0-20260211
  default-addonrepository-3.6.0-regional-harbor  vmware-system-vks-public  depot.kube-system.svc/vcf/vks-standard-packages/ga/3.6.0-20260211/vks-standard-packages:3.6.0-20260211

vcf addon repository-install list

## Sample output
  NAME                        NAMESPACE                 ADDONREPOSITORY                                READY
  default-addon-repo-install  vmware-system-vks-public  default-addonrepository-3.6.0-regional-harbor  True

vcf addon available list

## Sample output (truncated)
  NAMESPACE                 ADDONNAME                    DESCRIPTION
  vmware-system-vks-public  ako                          Integrates VMware NSX Advanced Load Balancer with Kubernetes for L4-L7 services.
  vmware-system-vks-public  cert-manager                 Certificate management
  vmware-system-vks-public  contour                      An ingress controller
  vmware-system-vks-public  external-dns                 DNS synchronization
  vmware-system-vks-public  fluent-bit                   Fluent Bit log processor and forwarder
  vmware-system-vks-public  harbor                       OCI Registry
  vmware-system-vks-public  istio                        Networking service mesh solution for containers
  vmware-system-vks-public  prometheus                   Time-series database for metrics
  vmware-system-vks-public  velero                       Open source backup, restore, DR, and migration tool for Kubernetes
  ...

vcf addon available list cert-manager

## Sample Output
  NAMESPACE                 ADDONNAME     VERSION                ADDON-RELEASE-NAME                                        PACKAGE
  vmware-system-vks-public  cert-manager  1.18.2+vmware.2-vks.2  cert-manager.kubernetes.vmware.com.1.18.2-vmware.2-vks.2  cert-manager.kubernetes.vmware.com/1.18.2+vmware.2-vks.2
  vmware-system-vks-public  cert-manager  1.18.3+vmware.1-vks.1  cert-manager.kubernetes.vmware.com.1.18.3-vmware.1-vks.1  cert-manager.kubernetes.vmware.com/1.18.3+vmware.1-vks.1
  vmware-system-vks-public  cert-manager  1.19.1+vmware.1-vks.1  cert-manager.kubernetes.vmware.com.1.19.1-vmware.1-vks.1  cert-manager.kubernetes.vmware.com/1.19.1+vmware.1-vks.1
  vmware-system-vks-public  cert-manager  1.19.2+vmware.1-vks.1  cert-manager.kubernetes.vmware.com.1.19.2-vmware.1-vks.1  cert-manager.kubernetes.vmware.com/1.19.2+vmware.1-vks.1
```

Install `cert-manager` using the commands below.

```bash
## List the available cert-manager versions
vcf addon available list cert-manager

## Sample output
  NAMESPACE                 ADDONNAME     VERSION                ADDON-RELEASE-NAME                                        PACKAGE
  vmware-system-vks-public  cert-manager  1.18.2+vmware.2-vks.2  cert-manager.kubernetes.vmware.com.1.18.2-vmware.2-vks.2  cert-manager.kubernetes.vmware.com/1.18.2+vmware.2-vks.2
  vmware-system-vks-public  cert-manager  1.18.3+vmware.1-vks.1  cert-manager.kubernetes.vmware.com.1.18.3-vmware.1-vks.1  cert-manager.kubernetes.vmware.com/1.18.3+vmware.1-vks.1
  vmware-system-vks-public  cert-manager  1.19.1+vmware.1-vks.1  cert-manager.kubernetes.vmware.com.1.19.1-vmware.1-vks.1  cert-manager.kubernetes.vmware.com/1.19.1+vmware.1-vks.1
  vmware-system-vks-public  cert-manager  1.19.2+vmware.1-vks.1  cert-manager.kubernetes.vmware.com.1.19.2-vmware.1-vks.1  cert-manager.kubernetes.vmware.com/1.19.2+vmware.1-vks.1

## Install cert-manager
vcf addon install create cert-manager \
    --addon-release-name <cert-manager.kubernetes.vmware.com.1.19.1-vmware.1-vks.1> \
    --namespace <namespaceName> \
    --cluster-name <clusterName>

## Sample command
vcf addon install create cert-manager \
    --addon-release-name cert-manager.kubernetes.vmware.com.1.19.1-vmware.1-vks.1 \
    --namespace ns01 \
    --cluster-name workload-vsphere-vks1

## Sample output
Installing addon 'cert-manager' for cluster 'workload-vsphere-vks1'. Are you sure? [y/N]: y
Addon 'cert-manager' is being installed in the cluster workload-vsphere-vks1

## Verify the cert-manager pods
kubectl get pods -n cert-manager

## Sample output
NAME                                       READY   STATUS    RESTARTS   AGE
cert-manager-7c7fcc8598-zcwc6              1/1     Running   0          26s
cert-manager-cainjector-68c447777d-b92xj   1/1     Running   0          26s
cert-manager-webhook-7b9544c879-t4pg8      1/1     Running   0          26s
```

> **Note:** In the sample commands above, the `cert-manager` add-on is registered in the `namespaceName` namespace, but the actual `cert-manager` pods always run in the `cert-manager` namespace. If a `cert-manager` namespace already exists, the package deployment reuses it. If the installation fails, label the `cert-manager` namespace with `pod-security.kubernetes.io/enforce=privileged` and delete the ReplicaSets in the `cert-manager` namespace; this lets the deployment recreate the ReplicaSets and pods.
