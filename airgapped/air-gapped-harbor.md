# Appendix: Air-Gapped Deployment Using Bootstrap Registry Appliance

## In this document, we will only capture the additional steps and/or differences that have not been addressed in the [primary air gap install document](/airgapped/air-gapped.md) 

## Introduction
We may not have an Enterprise registry available for the platform deployment in certain scenarios. In such a scenario, we can deploy Harbor Supervisor Service to perform most of the functionalities of an Enterprise registry. The process involves the following significant steps:

- Copy the relevant files and binaries to be moved to the air-gapped environment.
- Enable the Supervisor.
- Upload Kubernetes release OVAs to a Content Library.
- Create vSphere Namespace(s) for VKS Clusters(s).
- Configure the air-gapped Admin host in the air-gapped environment. 
- **(NEW) Deploy Bootstrap registry.**
- **(NEW) Install Contour and Harbor Supervisor Service to be used as Platform Registry.**
- Mirror Platform registry with the relevant container images to be used by the platform. 
- Install the relevant Supervisor Services.
- Deploy the VKS Cluster(s).
- Deploy the Tanzu Packages on the VKS Cluster(s).

The data flow of packages, binaries, and images between the internet-connected and air-gapped environment can be summarized by the picture below -

![image](harbor-dataflow.png)

## Terminology
* **Bootstrap registry** An OCI-compliant Harbor registry will be deployed on the vCenter. This registry will be used exclusively to upload the binaries necessary to enable Contour and Harbor Supervisor services on the Supervisor. It will not be utilized for any other purpose.
* **Platform registry** A Harbor Supervisor Service that performs all functionalities of an Enterprise grade Platform registry. 

## Bill of Materials
Besides the BOM referenced in the [primary air gap install document](/airgapped/air-gapped.md), we will be leveraging the following additional components - 

|Component|Version|Sample Hostname|
|---------|-------|----------------------------------|
|Bootstrap Registry|Harbor v2.12.2|registry0.env1.lab.test|
|Platform/Enterprise Registry|Harbor v2.9.1|registry1.env1.lab.test|

## 1. Download all required Plugins, Binaries, and Images
Besides downloading all the plugins, binaries, and images addressed in the [primary air gap install document](/airgapped/air-gapped.md) -

### 1e. Download Bitnami Harbor OVA
Before enabling Supervisor Services in an air-gapped environment, we must host images in a bootstrap container registry. This bootstrap repository will be used exclusively to host the necessary images to enable Contour and Harbor Supervisor Services; it will not be utilized for any other purpose. The Debian-based Bitnami Harbor OVA (v2.12.2) can be downloaded from the [Bitnami portal](https://bitnami.com/redirect/to?from=%2Fstack%2Fharbor%2Fvirtual-machine&url=https%3A%2F%2Fmarketplace.cloud.vmware.com%2Fservices%2Fdetails%2Fharbor-singlevm%3Fslug%3Dtrue). The above link redirects to VMware Marketplace. Users must have a valid VMware/Broadcom CSP login and for the org to have the Marketplace tile enabled.

### 1f. Download Trivy Database for Platform Registry (Harbor Supervisor Service)
The Trivy vulnerability scanning database is available for download from gcr.io and is updated periodically. In an air-gapped environment, this database must be periodically downloaded to the Bootstrap machine and then moved to the air-gapped environment to be installed on the Platform container registry (Harbor Supervisor Service). 

```bash
TRIVY_TEMP_DIR=$(mktemp -d)
echo $TRIVY_TEMP_DIR

sudo curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sudo sh -s -- -b /usr/local/bin v0.58.0

### Sample output
### aquasecurity/trivy info checking GitHub for tag 'v0.58.0'
### aquasecurity/trivy info found version: 0.58.0 for v0.58.0/Linux/64bit
### aquasecurity/trivy info installed /usr/local/bin/trivy

trivy --cache-dir $TRIVY_TEMP_DIR image --download-db-only  

### Sample output
### 2025-01-04T00:10:09Z	INFO	[vulndb] Need to update DB
### 2025-01-04T00:10:09Z	INFO	[vulndb] Downloading vulnerability DB...
### 2025-01-04T00:10:09Z	INFO	[vulndb] Downloading artifact... repo="mirror.gcr.io/aquasec/trivy-db:2"
### 58.26 MiB / 58.26 MiB [----------------------------------------------] 100.00% 21.18 MiB p/s 3.0s
### 2025-01-04T00:10:14Z	INFO	[vulndb] Artifact successfully downloaded	### repo="mirror.gcr.io/aquasec/trivy-db:2"
```

### Summary
Copy **these additional files** to the Admin host within the air-gapped environment. 

## Complete Steps 2, 3, 4, and 5 referenced in the [primary air gap install document](/airgapped/air-gapped.md)

## Deploy Bootstrap registry
The Bitnami Harbor appliance deploys the Harbor service on port 80 by default. However, this needs to be modified to start the service on port 443. Additional configuration changes are also required. These steps would be best performed on the Admin Host. 

### Create Self Signed Certificates for the Bootstrap registry 
Using the `openssl` command, generate the required CA and certificate files for the Admin host. You can modify the reference to the Bootstrap registry hostname and IP address according to your environment's requirements. 

```bash
## Generate CA key pair. Modify as needed
openssl genrsa -out admin-ca.key 4096
openssl req -x509 -new -nodes -sha512 -days 3650 -subj "/C=US/ST=CA/L=PaloAlto/O=VCF/OU=Supervisor/CN=Harbor" -key admin-ca.key -out admin-ca.crt

## Generate Harbor certificate. Modify as needed
openssl genrsa -out registry0.key 4096
openssl req -sha512 -new -subj "/C=US/ST=CA/L=PaloAlto/O=VCF/OU=Supervisor/CN=registry0.env1.lab.test" -key registry0.key -out registry0.csr

cat > v3.ext <<-EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1=registry0.env1.lab.test
DNS.2=*.registry0.env1.lab.test
IP.1=192.168.100.57
EOF

openssl x509 -req -sha512 -days 365 -extfile v3.ext -CA admin-ca.crt -CAkey admin-ca.key -CAcreateserial -in registry0.csr -out registry0.crt
```
The above commands produce the following files :
```
registry0.crt
registry0.key
registry0.csr

admin-ca.crt
admin-ca.key
```

### Deploy Bootstrap Registry - Bitnami Harbor 
Next, we have to create a “post cloud-init” Harbor customization script that will modify the settings of the Bootstrap Harbor VM. Create a file `harbor.sh` with the following content. 

```bash
#!/bin/bash
sudo cp /opt/bitnami/nginx/conf/bitnami/certs/server.crt /opt/bitnami/nginx/conf/bitnami/certs/server.crt.bak
sudo cp /opt/bitnami/nginx/conf/bitnami/certs/server.key /opt/bitnami/nginx/conf/bitnami/certs/server.key.bak
sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
#
sudo sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
sudo rm -f /etc/ssh/sshd_not_to_be_run
sudo systemctl enable ssh
sudo systemctl start ssh
#
sudo sed -i 's/^listen 80/# listen 80/' /opt/bitnami/nginx/conf/nginx.conf
keytext='-----BEGIN PRIVATE KEY-----
MIIJQgIBADANBgkqhkiG9w0BAQEFAASCCSwwggkoAgEAAoICAQCuFlaLubI55mHl
RgTLW5ylZxx1WJUeK0CPvFHbE65mF6uEwIRpS4AjTS0JSTAl3i/7B7EgU/jQL03n
...
7CJM7ygWv3Dp7VcHVlB0EJXjn6GE2xhQ2fcwCoXdo+ljdxhAQGw4Fg05PtM9kphp
KnC5FAczR75inoD1wD5ySOn8xuuZig==
-----END PRIVATE KEY-----'
certtext='-----BEGIN CERTIFICATE-----
MIIGLjCCBBagAwIBAgIUQmStS/UuZW6DeSHwytm3uwCJckcwDQYJKoZIhvcNAQEN
BQAwgYExCzAJBgNVBAYTAlVTMQswCQYDVQQIDAJWQTEQMA4GA1UEBwwHQXNoYnVy
...
1wkh5ELnVuGf7uBIfOi04aOCnAwqhd48IL41ys6KqkaCamzZ1eH3Cii5uUBcANHZ
q3cl69e56akuxf3I1G/rfEcF71Nn7sBWTAKDl2/N2pL+O8rek8XSGplNOUNqaSN8
00U=
-----END CERTIFICATE-----'
sudo echo "$keytext"  > /opt/bitnami/nginx/conf/bitnami/certs/server.key
sudo echo "$certtext" > /opt/bitnami/nginx/conf/bitnami/certs/server.crt
#
sudo /opt/bitnami/ctlscript.sh restart bitnami.nginx
```
* The value of `certtext` has to be updated with the contents of `registry0.crt` (including `-----BEGIN CERTIFICATE-----` and ending with `-----END CERTIFICATE-----`).
* The value of `keytext` has to be updated with the contents of `registry0.key` (including `-----BEGIN PRIVATE KEY-----` and ending with `-----END PRIVATE KEY-----`).
* If the above process was not used to generate the self-signed certificates and key files, the contents can be replaced with the user-provided certificate and key file. 

Once the above file has been successfully created, please run the following command to encode (BASE64) it and copy its contents.  

```bash
## IMPORTANT to BASE64 encode this file
​​cat harbor.sh|base64 -w0;echo
```

Deploying the Bitnami Harbor OVA follows the same process as deploying any other OVA in vCenter. During the "Customize Template" step, provide the following required details:
- The CPU and Memory settings can be adjusted as required. 
- Network Configuration (optional if DHCP is being used)
- When providing an IP address, use the IP/netmask format. 
- In the `User data to be made available inside the instance` field, paste the content of the base64-encoded output captured in the previous command. 

![image](bitnami0.png)

Once Harbor is deployed and running, we can grab the default credentials from the VM’s console. SSH into the VM using the `bitnami` user and update the credentials using a secure password. Login to the Harbor UI using the `admin` user and the password provided, and update the credentials using a secure password. See the example below - 

![image](bitnami1.png)

### Add the Bootstrap Registry certificate to the Supervisor
The Supervisor must trust the Bootstrap registry certificate. To perform this step, navigate to Workload Management -> Supervisor -> Configure -> Container Registries. Click on Add Registry. 

![image](add-cert2.png)

Input the Registry host URL, TLS Certificate of the registry (the content of `registry0.crt`), Username, and Password. Note that while the UI states that the Username and Password are optional, they are currently mandatory.

![image](add-cert3.png)

### Add the Bootstrap Registry certificate to the Admin host Trust Store
You can use the commands below to add the Bootstrap Harbor certificate to the Admin host trust store. 

```bash
## Commands specific to Ubuntu
sudo cp registry0.crt /usr/local/share/ca-certificates 
sudo update-ca-certificates
```

Once the certificate is added to the trust store, log in to the Bootstrap Harbor endpoint using Docker. 

```bash
## Restart Docker Service
systemctl reload docker
systemctl restart docker

## Command to Login to Harbor Endpoint
docker login <repo-endpoint>


## Enter the username and password when prompted. The expected output is shown below:
=====
WARNING! Your password will be stored unencrypted in /root/.docker/config.json.
Configure a credential helper to remove this warning. See
https://docs.docker.com/engine/reference/commandline/login/#credential-stores

Login Succeeded
=====
```

### Upload Harbor and Contour Supervisor Services to the Enterprise Registry
Create a project, `sup-services,` with public access within the Bootstrap registry to upload Contour and Harbor Supervisor Services that must be installed on the Supervisor.


The Contour and Harbor Supervisor Services image bundle binaries downloaded in Step 1d must now be uploaded to the Bootstrap Harbor registry. Follow [steps 4 and 5 from the official documentation](https://techdocs.broadcom.com/us/en/vmware-cis/vsphere/vsphere-supervisor/8-0/vsphere-supervisor-services-and-workloads-8-0/deploying-supervisor-services-from-a-private-container-image-registry/relocate-supervisor-services-to-a-private-registry.html) to complete this critical step. While the official documentation refers to the `imgpkg` binary to perform the download function, the Tanzu CLI's `imgpkg plugin` performs an identical function. 

```bash
## Sample Commands
tanzu imgpkg copy --tar contour-v1.28.2.tar --to-repo registry0.env1.lab.test/sup-services/contour --cosign-signatures
tanzu imgpkg copy --tar harbor-v2.9.1.tar   --to-repo registry0.env1.lab.test/sup-services/harbor  --cosign-signatures
```

Additionally, the corresponding Contour and Harbor Supervisor Service YAMLs need to be updated with the new Bootstrap registry valid location -

```yaml
# Contour.yaml
...
Template:
  Spec:
    Fetch:
    - imgpkgBundle:
        image: registry0.env1.lab.test/sup-services/contour:v1.24.4_vmware.1-tkg.1
...
```

```yaml
# harbor.yaml
...
Template:
  Spec:
    Fetch:
    - imgpkgBundle:
        image: registry0.env1.lab.test/sup-services/harbor:v2.9.1_vmware.1-tkg.1
...
```

Once completed, add the required Supervisor Services to the Supervisor using the [steps provided in the documentation](https://techdocs.broadcom.com/us/en/vmware-cis/vsphere/vsphere-supervisor/8-0/vsphere-supervisor-services-and-workloads-8-0/deploying-supervisor-services-from-a-private-container-image-registry/install-and-use-the-supervisor-service.html).

## Install Contour and Harbor Supervisor Service to be used as Platform Registry

Follow the directions to install Contour and Harbor as Supervisor Service provided [here](https://techdocs.broadcom.com/us/en/vmware-cis/vsphere/vsphere-supervisor/8-0/vsphere-supervisor-services-and-workloads-8-0/installing-and-configuring-harbor-and-contour.html). 

### Harbor customization
For an air-gapped install, we have to disable the Trivy scanner from trying to update its database from the internet. To do so, we must append the following section at the end of the sample `harbor-data-values.yml` file. 

```yaml
# harbor-data-values.yml

trivy:
  enabled: true
  skipUpdate: true
  offline scan: true
```
---
## Complete Steps 6, 7, and 8 referenced in the primary air-gapped document.
While completing these steps, replace the reference to the Enterprise Registry with the Platform Registry (Harbor Supervisor Service)
