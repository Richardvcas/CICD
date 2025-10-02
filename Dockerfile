Got it 👍 Richard. Let’s make this VM Pave Temporal Workflow Confluence page more professional by adding explanations under each step — so it’s not just API request/response, but also describes why the step is needed, what happens internally, and what the outcome is.

Here’s the enhanced version with detailed elaboration 👇


---

VM Pave Temporal Workflow

1. Overview

This page describes the end-to-end workflow for VM Pave using Temporal, GitOps, and Argo CD.
The workflow provisions a new Virtual Machine (VM) in OpenShift based on user-provided specifications.

Key Highlights:

Workflow orchestrated by Temporal

Inputs received via Swagger API request (JSON format)

Activities executed in sequence for successful VM provisioning

Deployment driven by Argo CD after YAML commit in Bitbucket



---

2. High-Level Workflow

flowchart TD
    A[User raises request via Swagger API] --> B[Validate Inputs]
    B --> C[Hostname Generation]
    C --> D[IP Reservation (NetID Service)]
    D --> E[DNS Record Creation]
    E --> F[YAML Upload to Bitbucket]
    F --> G[ArgoCD Sync - VM Deployment in OpenShift]
    G --> H[Sophia AD Account Creation]
    H --> I[Veram Inventory Registration]
    I --> J[VM Monitoring Check]


---

3. Workflow Steps in Detail

Step 1: User Request via Swagger API

The process begins when a user raises a VM provisioning request through the Swagger API.
The request includes all required specifications such as CPU, memory, disk size, project ID, and owner details.
Temporal immediately starts a new workflow instance, generating a unique workflowId to track the request.

Request Example:


{
  "vmName": "wh-labocp-007",
  "projectId": "gkp123",
  "cpu": 4,
  "memory": "16Gi",
  "disk": "200Gi",
  "region": "us-east-1",
  "owner": "richard.xavier@company.com"
}

Response Example:


{
  "workflowId": "vm-pave-20250923-123456",
  "status": "IN_PROGRESS",
  "message": "VM Pave workflow triggered successfully"
}


---

Step 2: Validate Inputs

This activity validates the incoming request.
It ensures that all mandatory fields are present, values are within acceptable ranges, and project identifiers are valid.
Without proper validation, downstream processes such as hostname or IP generation may fail.

Request:


{
  "vmName": "wh-labocp-007",
  "cpu": 4,
  "memory": "16Gi"
}

Response:


{
  "status": "VALID",
  "message": "All inputs validated successfully"
}


---

Step 3: Hostname Generation

A consistent hostname is required for DNS, AD, and inventory systems.
The hostname generator follows corporate naming standards (region + project + sequence).
This ensures uniqueness and alignment with infrastructure policies.

Response:


{
  "hostname": "wh-labocp-007",
  "fqdn": "wh-labocp-007.gkp123.dev.company.com"
}


---

Step 4: IP Reservation

The workflow contacts the NetID IP Management service to reserve an IP address for the VM.
The reservation ensures no duplication across the network and guarantees that the IP is available when the VM is deployed.
This step is critical for networking and DNS mapping.

Response:


{
  "ipAddress": "10.25.46.112",
  "status": "RESERVED"
}


---

Step 5: DNS Creation

Once the IP is reserved, a DNS entry is created to map the hostname to the IP.
This enables both internal and external services to resolve the VM using its Fully Qualified Domain Name (FQDN).
If DNS fails, the VM cannot be accessed reliably.

Response:


{
  "status": "SUCCESS",
  "dnsRecord": "wh-labocp-007.gkp123.dev.company.com"
}


---

Step 6: YAML Upload to Bitbucket

After networking details are finalized, the workflow generates a values.yaml file containing the VM specifications.
This YAML is pushed to the Bitbucket Git repository, which acts as the source of truth for GitOps.
A commit triggers downstream ArgoCD sync automatically.

Response:


{
  "status": "COMMITTED",
  "repoUrl": "https://bitbucket.company.com/projects/vm-repo/wh-labocp-007"
}


---

Step 7: Argo CD Sync (VM Deployment)

ArgoCD continuously watches the Git repository.
When the new YAML is committed, ArgoCD detects the change and syncs it with the OpenShift cluster.
This results in a new VM object being created and deployed in the target namespace.

Response Example:


{
  "status": "DEPLOYED",
  "cluster": "ocp-lab1",
  "namespace": "gkp123",
  "vmStatus": "Running"
}


---

Step 8: Sophia AD Creation

To enable authentication and integration with enterprise services, a Sophia AD account is created for the VM.
This ensures secure access and identity management.

Response:


{
  "status": "SUCCESS",
  "adAccount": "svc_wh-labocp-007"
}


---

Step 9: Veram Inventory Registration

The VM must be registered in Veram Inventory, which is the enterprise system for tracking IT assets.
This step helps in auditing, compliance, and lifecycle management.

Response:


{
  "status": "SUCCESS",
  "inventoryId": "VERAM-343211"
}


---

Step 10: VM Monitoring Check

Finally, the VM is monitored to verify:

Power state (Running)

Network connectivity

Health probes (CPU/memory thresholds, agent registration)


This ensures the VM is fully functional before marking the workflow as SUCCESS.

Response:


{
  "vmName": "wh-labocp-007",
  "status": "RUNNING",
  "healthCheck": "PASSED"
}


---

4. Final Workflow Response

Once all steps are complete, the final response is returned:

{
  "workflowId": "vm-pave-20250923-123456",
  "vmName": "wh-labocp-007",
  "fqdn": "wh-labocp-007.gkp123.dev.company.com",
  "ipAddress": "10.25.46.112",
  "status": "SUCCESS",
  "message": "VM successfully provisioned"
}


---

5. Key Integrations

Step	Integration Service	Purpose

Input Validation	Swagger + Temporal	Ensures correct request payload
Hostname	Hostname Generator	Standardized naming
IP Reservation	NetID	Unique IP allocation
DNS	NetID DNS	Maps hostname to IP
YAML Upload	Bitbucket	Source of truth for GitOps
Deployment	ArgoCD	Syncs manifests to OpenShift
AD Account	Sophia	Creates service accounts
Inventory	Veram	Tracks VM assets
Monitoring	Prometheus / Custom API	Ensures VM health



---

✅ Now this page is detailed enough to stand as a professional Confluence document — each step has both technical detail + business justification.

Would you like me to now replicate the same detailed structure for:

1. VM Resize Workflow


2. VM Delete Workflow


3. VM Repave Workflow



so you’ll have a 4-page Confluence set with the same professional style?

