# citrix-flex-image-export

Export a custom image from an **Azure Compute Gallery** to blob storage and generate the two SAS URIs needed to register it as a custom image in [Citrix Cloud DaaS](https://www.citrix.com/products/citrix-daas/) (Platform Flex / Virtual Apps and Desktops).

Supports **Trusted Launch** (Secure Boot + vTPM) images — both the OS VHD and the VM Guest State (VMGS) blob are exported automatically.

---

## How it works

Clicking **Deploy to Azure** opens a form in the Azure portal. Fill in your gallery and storage details, click **Create**, and wait ~10–15 minutes. When the deployment completes, open the **Outputs** tab — your two SAS URIs are ready to copy into the Citrix Cloud portal.

Under the hood, the deployment:

1. Creates a short-lived managed identity (no stored credentials)
2. Assigns it the minimum required roles on your gallery and storage account
3. Runs an Azure CLI script inside a temporary container that:
   - Creates a temporary managed disk from your gallery image version, in the deployment's own resource group
   - Calls `az disk grant-access --secure-vm-guest-state-sas` to get the OS and VMGS SAS URLs
   - Copies both blobs to your destination storage account via AzCopy
   - Deletes the temporary disk
   - Generates time-limited read SAS tokens on the output blobs
4. Writes the SAS URIs to the deployment outputs
5. Removes the script's container and its storage on success. The managed identity and its role assignments stay until you remove them: see [Cleaning up](#cleaning-up)

---

## Prerequisites

Before clicking Deploy:

1. **An Azure Compute Gallery image version** — image definition security type must be `TrustedLaunch` for VMGS export; standard Gen2 images are also supported (VMGS is skipped)
2. **A destination storage account** with a container named `vhd-output` (or a name of your choice)  
   - Create a container if needed: **Storage account → Containers → + Container**
3. **A new, dedicated resource group to deploy into.** The export identity becomes Contributor on it, and the temporary disk is created there. Delete it after the export (see [Cleaning up](#cleaning-up)).

---

## Deploy to Azure

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FJefferyMitchell%2Fcitrix-flex-image-export%2Fmain%2Fdeploy%2Fazuredeploy.json)

### Parameters

| Parameter | Description | Example |
|-----------|-------------|---------|
| **Gallery Resource Group** | Resource group containing the Azure Compute Gallery | `rg-images` |
| **Gallery Name** | Name of the Azure Compute Gallery | `MyImageGallery` |
| **Image Definition** | Image definition name | `WinServer2025DC` |
| **Image Version** | Version to export | `1.0.0` |
| **Dest Storage Account Name** | Storage account to receive the VHD and VMGS blobs | `mystorageaccount` |
| **Dest Storage Account Resource Group** | Resource group of that storage account | `rg-citrix-images` |
| **Output Container** | Container name in the storage account *(default: vhd-output)* | `vhd-output` |
| **SAS Hours** | How many hours the output SAS tokens remain valid *(default: 1)* | `1` |
| **Location** | Azure region for the export container *(defaults to deployment RG region)* | `eastus` |

> All parameters are within the **same Azure subscription**. Cross-subscription scenarios are not supported in this version.

---

## Outputs

When the deployment completes (~10–15 minutes), open the deployment and click **Outputs**:

| Output | Description |
|--------|-------------|
| `vhdUri` | Paste into **VHD URI** in Citrix Cloud |
| `guestDiskUri` | Paste into **Guest Disk URI** in Citrix Cloud *(Trusted Launch images only)* |
| `secureBootEnabled` | `true` for Trusted Launch images, `false` otherwise |
| `vTPMEnabled` | `true` for Trusted Launch images, `false` otherwise |
| `sasExpiry` | When the SAS tokens expire (1 hour from deployment) |

> **SAS tokens expire after 1 hour.** Complete the Citrix Cloud import before then. If the tokens expire, re-run this deployment to generate fresh SAS tokens.

---

## Importing into Citrix Cloud DaaS

After the deployment outputs are ready:

1. Open **Citrix Cloud** → **DaaS** (or **Virtual Apps and Desktops**)
2. Go to **Machine Catalogs** → **Create Machine Catalog**
3. Select **Azure** → **Custom Image** → **Use a virtual hard disk (VHD)**
4. Paste the `vhdUri` into the **VHD URI** field
5. For Trusted Launch images:
   - Paste `guestDiskUri` into the **Guest Disk URI** field
   - Enable **Secure Boot** and **vTPM**
6. Set **Machine Generation** to **Generation 2** (required for Trusted Launch)
7. Complete the catalog wizard

See [docs/import-to-citrix.md](docs/import-to-citrix.md) for step-by-step screenshots.

---

## Renewing SAS tokens

SAS tokens expire after 1 hour. To generate fresh tokens after expiry:

**Re-run the same deployment** — fill in the same parameters and click Create again. Fresh 1-hour SAS tokens are written to the Outputs tab when the deployment completes.

---

## Roles assigned by this deployment

The deployment creates a **User-Assigned Managed Identity** and assigns it the minimum required roles:

| Role | Scope | Purpose |
|------|-------|---------|
| `Contributor` | The resource group you deploy into | Create, export and delete the temporary managed disk |
| `Reader` | The gallery | Read the image version and its definition, and create a disk from it |
| `Storage Blob Data Contributor` | Destination storage account | Write VHD and VMGS blobs via AzCopy |
| `Storage Blob Delegator` | Destination storage account | Generate user-delegation SAS tokens (no account key) |

The identity has no write access to the gallery: the temporary disk is created in the resource group you deploy into, in the gallery's region. Because the identity is Contributor on that resource group, deploy into a **dedicated** resource group, not one holding anything else.

### Cleaning up

The identity and its role assignments outlive the export. While the identity exists, anyone who can assign it to a resource can act with its roles. Remove it when you're done, in this order:

```bash
RG=<the resource group you deployed into>
PRINCIPAL_ID=$(az identity show -g "$RG" -n id-export-citrix-flex-image --query principalId -o tsv)

# 1. The role assignments on the gallery and the storage account. Deleting the resource group
#    alone leaves these behind as "Identity not found" entries.
az role assignment list --all --assignee "$PRINCIPAL_ID" --query "[].id" -o tsv | xargs -r az role assignment delete --ids

# 2. The identity, and anything else in the deployment resource group
az group delete -n "$RG" --yes
```

The exported blobs and SAS URIs in your storage account are not affected. To renew the SAS tokens later, deploy again.

---

## Limitations

- **Same subscription**: gallery, destination storage, and deployment must be in the same Azure subscription
- **Azure Compute Gallery source only**: for images in Packer snapshots (not in a gallery), use `03-export-image.ps1` from [flex-image-builder](https://github.com/JefferyMitchell/flex-image-builder)
- **TrustedLaunch or standard Gen2**: images with other security types (e.g. ConfidentialVM) are not tested

---

## Related

- [flex-image-builder](https://github.com/JefferyMitchell/flex-image-builder) — Packer + Terraform pipeline for building and deploying Citrix Platform Flex custom images
