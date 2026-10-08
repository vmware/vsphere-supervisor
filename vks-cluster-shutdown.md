# Shutdown of VKS Workload Cluster

This procedure is designed to handle temporary shutdown of a VKS Workload Cluster.
VKS and CAPI can create and destroy clusters but do not natively support clusters being shutdown.
Additionally, Kubernetes, notably *etcd* (the distributed database that backs the API server), does not
tolerate losing nodes - loss of quorum in *etcd* requires manual intervention to bring the cluster back up.
When shutting down *etcd* nodes, care must be taken to handle the shutdown in the correct order and to inform
*etcd* that the cluster is being scaled down.  CAPI handles this automatically with this procedure.
The cluster should be shutdown for the minimum amount of time needed for maintenance and no more than one month.
Workload cluster worker nodes and Persistent Volumes will be retained.  Pods will be terminated as part
of the shutdown procedure.  On restart, the Kubernetes cluster will restart, and restart services defined in the Kubernetes cluster.
For long term shutdown or archiving, do not use this procedure.  Instead, a backup of the cluster should be taken and
the cluster deleted, recreated and restored from the backup when needed.

# Preparation

Before beginning the shutdown procedure:  
* Check certificate expiry and rotate as necessary  
* Backup the cluster  
* Remove pod disruption budgets  
* Prepare applications for shutdown if necessary

## Certificate expiry

Certificates are used in a variety of places within the Kubernetes cluster.  If certificates expire while the cluster is shutdown, the cluster may not restart properly.
Check certificates and passwords and ensure that they will not expire during your planned shutdown period.
Instructions on how to check certificate expiry and rotate certificates if necessary are here: [https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-0/managing-vsphere-kuberenetes-service-clusters-and-workloads/managing-security-for-tkg-service-clusters/managing-tls-certificates-for-tkg-service-clusters.html](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-0/managing-vsphere-kuberenetes-service-clusters-and-workloads/managing-security-for-tkg-service-clusters/managing-tls-certificates-for-tkg-service-clusters.html)

## Backup the cluster

Shutting down the cluster should not result in data loss, but taking a backup is recommended as a basic precaution.
Make a copy of the Cluster spec as well to allow for easy re-creation of the Cluster to restore into.

## Remove Pod Disruption Budgets

Pod Disruption Budgets will prevent services from being completely shut down and block the overall cluster shut down
from completing.  Make copies of existing PDBs and either remove them or change them to allow for all Pods to be removed.

## Prepare applications for shutdown if necessary

This procedure is the equivalent of a power off of the Kubernetes cluster.  If any of the applications require an
orderly shutdown before being completely shutdown, that needs to be done before draining nodes or changing the control plane.

# Shutdown of a VKS Workload Cluster

Shutdown of a VKS Workload Cluster is the process of powering off all of the Control Plane and Worker Node VMs.
Once this has completed, the cluster will be powered off and will not respond to any API server requests and all
applications/services running in the cluster will not be available.  Kubernetes configuration and Persistent Volumes
will remain.  When the cluster is powered up, all applications will resume operation.

The shutdown procedure is:
* Ensure that the cluster is healthy and not being upgraded or scaled
  * Ensure that all nodes in the cluster are healthy
  * Ensure that Addons have been reconciled
  * Ensure that no CAPI operations are in progress
* Cordon and drain worker nodes  
* Scale down the control plane  
* Pause CAPI reconciliation  
* Power off the VMs  
  * Power off the control plane VM  
  * Power off the worker nodes

## Ensure that the cluster is healthy and not being upgraded or scaled

The nodes for the cluster should be healthy and there should not be any operations such as upgrade or scaling in progress.

### Ensure that all nodes in the cluster are healthy

This command needs to be executed against the *workload* cluster, not the Supervisor cluster.
`WORKLOAD_KUBECONFIG` should have the path of the Kubernetes config for the workload cluster.
```
KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl wait --for=condition=Ready node --all --timeout=10s
```
### Ensure that Addons have been reconciled
This will return "True" if all Addons are reconciled.
```
kubectl get cluster "$CLUSTER_NAME" -n "$KUBENAMESPACE" -o jsonpath='{.status.conditions[?(@.type == "AddonsReconciled")].status}'
```
### Ensure that no CAPI operations are in progress
```
kubectl get cluster "$CLUSTER_NAME" -n "$KUBENAMESPACE" -o json | jq -r '.status.conditions[] | select(.type=="RollingOut" or .type=="ScalingUp" or .type=="ScalingDown" or .type=="Remediating") | .type + ": " + .status'
```
All conditions should return `False`.
## Cordon and drain worker nodes
All pods should be stopped (except for DaemonSet pods which cannot be) before the control plane is scaled down.
This will stop any running applications and reduce the load on the control plane before the control plane is scaled down.
If you have Pod Disruption Budgets set, you will need to remove these to enable all pods to be stopped - make a copy of the names
and specs for when restarting the cluster.
### Cordon the worker nodes
Cordon the worker nodes first.  This will prevent pods being started on different nodes as nodes are drained.
```
KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl cordon $(KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o name)
```
### Drain the worker nodes
This command also needs to be executed against the workload cluster.
```
KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o name | xargs -I{} env KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl drain {} --ignore-daemonsets --delete-emptydir-data --force
```
The drain command will block until the nodes have completed draining.
## Scale down the control plane
Scale down the control plane to 1 node - this will avoid loss of quorum when control plane nodes are shutdown.  CAPI will
automatically do this the correct way.
### Note original number of control plane nodes
Before scaling down, take note of the number of control plane node replicas currently set.  You will need this when
restarting the cluster to get the same level of redundancy and performance you had before.
Sample command (unless otherwise noted all kubectl commands are executing against the Supervisor Kubernetes cluster)  
```
kubectl -n "$KUBENAMESPACE" get cluster "$CLUSTER_NAME" -o=jsonpath='{.spec.topology.controlPlane.replicas}'
```
### Scale down number of replicas with CAPI
Tell CAPI to reduce the number of replicas for the control plane to 1 in the /spec/topology/controlPlane/replicas field of the Cluster resource.
```
kubectl -n "$KUBENAMESPACE" patch cluster "$CLUSTER_NAME" --type='json' -p='[{"op": "replace", "path": "/spec/topology/controlPlane/replicas", "value": 1}]'
```
### Wait for the control plane to scale down and be healthy
These steps are very important - do not power off any control plane VMs until there is only one healthy control plane VM
running.  Failure to do so may result in the *etcd* database losing quorum.
Refer to [https://knowledge.broadcom.com/external/article/423616/recovery-etcd-quorum-loss-for-vks-cluste.html](https://knowledge.broadcom.com/external/article/423616/recovery-etcd-quorum-loss-for-vks-cluste.html)
if quorum is lost.

#### Check that the control plane has scaled down
```
kubectl wait kubeadmcontrolplane -n "$KUBENAMESPACE" -l "cluster.x-k8s.io/cluster-name=${CLUSTER_NAME}" --for=jsonpath='{.status.replicas}'=1 --timeout=600s
```
#### Verify that the remaining VM is healthy
```
KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl wait --for=condition=Ready node --all --timeout=60s
```
## Pause CAPI reconciliation
After the control plane has scaled down, pause CAPI reconciliation for the cluster.  This prevents CAPI from replacing nodes due to Machine Health Check failing.
Set the field `spec.paused` of the Cluster resource to true.

```
kubectl -n "$KUBENAMESPACE" patch cluster "$CLUSTER_NAME" --type='json' -p='[{"op": "replace", "path": "/spec/paused", "value": true}]'
```
## Shutdown the virtual machines for the nodes
The virtual machines for the nodes are controlled by VM Operator.  Normally, VM Operator will turn the virtual machine
back on if it is powered off or suspended.  Setting the `vmservice.virtualmachine.pause` property to true on the vCenter
Virtual Machine record causes VM Operator to ignore changes in the virtual machine power state.  After setting this
value, power off the virtual machine via vCenter (sample CLI commands for this are provided below).  You will need the
UUIDs of the virtual machines to do this (the bare UUID, not with the `vsphere://` prefix).
### Setup GOVC environment variables
The sample commands working with vCenter use *govc*.  These environment variables need to be set for *govc* to access vCenter.

`GOVC_URL` — vCenter server URL, e.g. `https://<vc-hostname>`

`GOVC_USERNAME` — vCenter username, e.g. `administrator@vsphere.local`

`GOVC_PASSWORD` — vCenter password for that user

`GOVC_INSECURE` — set to "1" to skip TLS certificate verification (needed for self-signed vCenter certificates)

`GOVC_DATACENTER` — datacenter path/name, required if the vCenter has more than one datacenter

### Power off the control plane VM
Power off the control plane VM first - this will prevent any operations related to nodes going unavailable as the worker
nodes are shut down.
#### Retrieve UUID of control plane VM
Get the UUID of the control plane VM from the Machine resource for it.  The Machine resource label
`cluster.x-k8s.io/cluster-name` has the cluster name.  Control plane machines will also have the flag
`cluster.x-k8s.io/control-plane` set in the label.
```
kubectl get machines -n "$KUBENAMESPACE" -l "cluster.x-k8s.io/cluster-name=${CLUSTER_NAME},cluster.x-k8s.io/control-plane" -o jsonpath='{range .items[*]}{.spec.providerID}{"\n"}{end}' | sed 's|^vsphere://||'
```
#### Set the `vmservice.virtualmachine.pause` property for the VM.
```
govc vm.change -vm.uuid="$UUID" -e vmservice.virtualmachine.pause=true
```
#### Power off the control plane VM
```
govc vm.power -s -vm.uuid="$UUID"
```
### Power off the worker nodes
#### Retrieve UUIDs of the worker nodes
```
kubectl get machines -n "$KUBENAMESPACE" -l "cluster.x-k8s.io/cluster-name=${CLUSTER_NAME},"'!cluster.x-k8s.io/control-plane' -o jsonpath='{range .items[*]}{.spec.providerID}{"\n"}{end}' | sed 's|^vsphere://||'
```
#### Set the `vmservice.virtualmachine.pause` property for each VM.
```
govc vm.change -vm.uuid="$UUID" -e vmservice.virtualmachine.pause=true
```
#### Power off each worker node VM
```
govc vm.power -s -vm.uuid="$UUID"
```
Your VKS cluster is now shutdown.

# Restarting a VKS Workload Cluster
When you are ready to resume operations of the workload cluster, it will need to be restarted in the reverse order of the shutdown procedure.

* Power on the VMs  
  * Power up the worker nodes  
  * Wait for worker nodes to power up  
  * Power up the control plane  
  * Wait for the control plane to start  
* At this point, the cluster should be working, verify the cluster is accessible and all nodes are healthy  
* Resume CAPI reconciliation  
* Scale up the control plane to its original number of replicas  
* Uncordon worker nodes  
* Restore Pod Disruption Budgets
* Verify the cluster and applications are working fully

## Power up the VMs
Worker nodes should be powered up first so that the control plane does not register any worker nodes as being offline
and attempt to shift pods to another worker node.
### Power up each worker node VM
For each of the worker node VMs, power it on via vCenter (use the list of UUIDs obtained previously)
```
govc vm.power -on -vm.uuid="$UUID"
```
### Clear the vmservice.virtualmachine.pause property for each VM.
```
govc vm.change -vm.uuid="$UUID" -e vmservice.virtualmachine.pause=false
```
### Wait for the worker nodes to power up
Check each of the worker nodes VMs to ensure that it is powered on.
```
govc vm.info -vm.uuid="$UUID" -json | jq -r '.virtualMachines[0].runtime.powerState'
```
### Power up the control plane VM
Use the UUID for the control plane node obtained previously.
```
govc vm.power -on -vm.uuid="$UUID"
```
### Clear the `vmservice.virtualmachine.pause` property for the control plane VM.
```
govc vm.change -vm.uuid="$UUID" -e vmservice.virtualmachine.pause=false
```
### Wait for the control plane to start
Wait for the Kubernetes API server to come online
```
until KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl get --raw='/readyz' >/dev/null 2>&1; do
	sleep 5
done
```
## Verify that all nodes have rejoined the cluster
Check that the nodes are all marked healthy and the number of nodes matches what is expected (1 control plane node plus the number of worker nodes expected).
```
KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl wait --for=condition=Ready node --all --timeout=600s && KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl get nodes
```
## Resume CAPI reconciliation
```
kubectl -n "$KUBENAMESPACE" patch cluster "$CLUSTER_NAME" --type='json' -p='[{"op": "replace", "path": "/spec/paused", "value": false}]'
```
## Scale up the control plane to its original number of replicas
Set `CONTROL_PLANE_NODES` to the original number of nodes obtained when you shutdown the cluster.
```
kubectl -n "$KUBENAMESPACE" patch cluster "$CLUSTER_NAME" --type='json' -p='[{"op": "replace", "path": "/spec/topology/controlPlane/replicas", "value": '"$CONTROL_PLANE_NODES"'}]'
```
## Wait for the control plane to scale up
```
kubectl wait kubeadmcontrolplane -n "$KUBENAMESPACE" -l "cluster.x-k8s.io/cluster-name=${CLUSTER_NAME}" --for=jsonpath='{.status.readyReplicas}'=$CONTROL_PLANE_NODES --timeout=600s
```
## Uncordon all of the worker nodes
```
KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl uncordon $(KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o name)
```
## Restore Pod Disruption Budgets
If any Pod Disruption Budgets were paused or modified during the shutdown process, restore them here.

## Verify that the cluster is working fully
At this point, the Kubernetes cluster should begin scheduling pods and services.  This may take some time.
Check that all services and applications restart properly.

# Scripts
Sample scripts are provided to shutdown and restart a cluster.  Use these scripts at your own
risk!  Before running the scripts review the procedures above and be aware of what operations will be executed.

Shutdown script - [shutdown-vks-cluster.sh](scripts/shutdown-vks-cluster.sh)

Restart script - [restart-vks-cluster.sh](scripts/restart-vks-cluster.sh)