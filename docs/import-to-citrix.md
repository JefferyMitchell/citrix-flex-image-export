# Importing a Custom Image into Citrix Cloud DaaS

After running the [citrix-flex-image-export](https://github.com/JefferyMitchell/citrix-flex-image-export) deployment and copying the output SAS URIs, follow these steps to register the image in Citrix Cloud and create a machine catalog from it.

---

## Prerequisites

- The deployment has completed and you have `vhdUri` and `guestDiskUri` from the deployment outputs
- You have Citrix Cloud administrator access to the DaaS service
- An existing on-premises network connection configured in Citrix Cloud (required for domain-joined catalogs)

---

## Step 1 — Navigate to Machine Catalogs

1. Sign in to [Citrix Cloud](https://citrix.cloud.com)
2. Open the **DaaS** tile (or **Virtual Apps and Desktops**)
3. In the left navigation, click **Machine Catalogs**
4. Click **Create Machine Catalog**

---

## Step 2 — Select the machine type

1. Select **Multi-session OS** (for Windows Server images) or **Single-session OS** (for Windows 11)
2. Select **Azure** as the location
3. Click **Next**

---

## Step 3 — Select Master Image

1. Select **Use a virtual hard disk (VHD)**
2. In the **VHD URI** field, paste the `vhdUri` from the deployment outputs
3. Set **Machine Generation** to **Generation 2**

### For Trusted Launch images (`secureBootEnabled = true`)

4. In the **Guest Disk URI** field, paste the `guestDiskUri` from the deployment outputs
5. Enable **Secure Boot**
6. Enable **vTPM**

> If `secureBootEnabled = false` in the deployment outputs, the image was not published with Trusted Launch security type. Leave the Guest Disk URI blank and leave Secure Boot and vTPM disabled.

---

## Step 4 — Configure the catalog

Complete the remaining wizard steps:

| Setting | Recommended value |
|---------|------------------|
| Machine size | Select based on persona (e.g. Standard_D4s_v5 for task workers) |
| Number of machines | Start with the number of concurrent users ÷ sessions per machine |
| Network | Select your Azure VNet (via on-premises network connection) |
| Storage type | Premium SSD (OS disk) |
| Machine naming | Choose a prefix; Citrix auto-appends numbers |
| Domain | Select your Active Directory domain (if domain-joined) |

---

## Step 5 — Review and finish

1. Review the summary
2. Provide a **Machine Catalog name** and optional description
3. Click **Finish**

Catalog creation provisions the Azure VMs, installs Citrix agents, and makes machines available in your delivery group. This typically takes 35–50 minutes depending on catalog size.

---

## SAS token expiry

The SAS tokens embedded in `vhdUri` and `guestDiskUri` expire **1 hour** after the deployment completes. Complete the Citrix Cloud import wizard before then.

To renew: re-run the [citrix-flex-image-export deployment](https://github.com/JefferyMitchell/citrix-flex-image-export) with the same parameters — fresh 1-hour SAS URIs will be in the Outputs tab.

---

## Troubleshooting

| Error | Cause | Fix |
|-------|-------|-----|
| "The specified VHD URL is invalid" | SAS token expired or missing `sp=r` permission | Re-run the export deployment to regenerate SAS tokens |
| "Guest Disk URI required" | `secureBootEnabled = true` but `guestDiskUri` was not entered | Paste the `guestDiskUri` from deployment outputs, or disable Secure Boot |
| "Master image could not be verified" | Machine Generation mismatch | Ensure **Generation 2** is selected; the image is Gen2 |
| "Master image must be a Windows 10 Multi-Session OS" | Windows Server image used with Single-session catalog | Change catalog type to Multi-session OS |
| Catalog stuck in provisioning | VMs failed to domain-join or install agent | Check network connectivity; ensure on-premises network connection is healthy |
