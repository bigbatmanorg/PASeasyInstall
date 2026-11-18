# 04 — Component Recipe Specifications

## Standard lifecycle

Every selected component builds this conceptual sequence (omit/merge phases where appropriate):

1. Identify target / inspect current installation.
2. Preflight OS, role, network, disk, DNS, account permissions, media and compatibility.
3. Stage files with trusted source version and SHA-256 verification.
4. Install shared host prerequisites **once**.
5. Execute vendor installer using documented automation paths.
6. Configure service endpoints, TLS, local account/service settings.
7. Register/integrate with Vault/PVWA as necessary through serialized Vault session gate.
8. Apply optional qualified hardening policy.
9. Verify service/process state, component registration, reachability and functional behavior.
10. Record a bounded diagnostics manifest and instructions for reconciling partial attempts.

**Required recipe declaration:** supported product versions; supported OS release/mode; required media; host compatibility; optional domain requirement; required Vault/PVWA state; elevated rights; exact nodes and resource gates; security controls and lab overrides; known logs; probes; recovery policy; and qualification tests.

## Primary Vault (`Standalone`)

**Dependencies:** dedicated Windows host, not joined to AD. **Media:** Vault, PACLI, keys/license, runtimes, vendor prerequisites. **Stages:** OS/media preflight → install/stage keys → configure first Vault → hardening → reboot/reconnection plan → health → authenticated logon/logoff probe. **Check:** required services, Vault port, version, client logon, file permissions/firewall baseline. **Recovery:** avoid repeated key generation and hardening if not provably safe. **Existing evidence:** supplied standalone workflow recorded 22/22 steps successful in the November 14 lab validation; not a qualification of this proposed rewrite.

## Primary with DR (`PrimaryWithDR`)

**Dependencies:** two distinct Windows hosts with compatible vendor packages and coordinated keys/configuration. **Stages:** primary → protected key relay → DR installation and standby settings → PADR install/configure before DR hardening → reboot → replication verification. **Checks:** services, replication progress/health, optional test Safe replication. **Critical:** do not confuse this with adding DR later to an existing production Vault. **Planner rule:** when a newly installed primary and DR are both selected, resolve them as a coordinated `PrimaryWithDR` topology, never run `Standalone` then add an unqualified DR as a second generic operation. **Evidence:** supplied lab report records 49/49 steps and test-Safe replication. **Future variants:** distributed Vault and Vault cluster require separate topology recipes, not a simple `DR=true` flag.

## PVWA (`Standard`)

**Dependencies:** compatible Vault; Windows IIS/.NET prerequisites; HTTPS host/cert settings. **Stages:** IIS and .NET → vendor install → bind trusted TLS cert (lab option to use self-signed) → Vault registration → optional hardening → verify. **Checks:** HTTPS endpoint, correct app context, Vault reachability, registration / authentication when test identity available; IIS/app logs. **Source risk:** supplied role disables certificate verification in selected registration paths; do not copy default.

## CPM (`Standard`)

**Dependencies:** compatible Vault and selected authentication pathway; optional PVWA when needed for selected registration/functional test. **Stages:** OS/.NET → install → registration → service account setup → hardening → verify. **Checks:** service status, Vault component registration, a controlled sample account/platform reconcile/change if configured. **Source risk:** role changes `validatePVWASecureConnect`; secure baseline must prefer validated TLS. Avoid claiming healthy based solely on a service running.

## PSM (`Standard`, future variants reserved)

**Dependencies:** Windows RDS-related prerequisites, compatible Vault and possibly PVWA registration; domain-dependent options. **Stages:** RDS and host prerequisites → install → postinstall → registration → optional hardening → reboot → verify. **Checks:** service/process state, registered component, a real test session to a disposable target where available. **Source risk:** supplied role uses Windows `Winlogon\DefaultPassword` during several stages; do **not** import plaintext autologon approach. If a vendor step truly requires interactive logon, model it as an explicit privileged test gate with a proven secure alternative or human-assisted stage. RDS grace/activation workarounds must never be silently applied as policy.

## PSMP (`Standard`)

**Dependencies:** specifically qualified Linux OS/version, Vault connectivity and dedicated Linux host by default. **Stages:** packages/preflight → installer config → install → register → secure SSH/gateway configuration → optional hardening → verify. **Checks:** systemd/service status, gateway listening, Vault connectivity, functional SSH session to a disposable target. **Source gap:** RHEL 8.6 source role uses a shell installer with `Hardening=No`; registration helper exists but the default task sequence does not clearly complete end-to-end registration; a new qualified recipe is needed.

## PTA (`Standard`)

**Dependencies:** specific qualified RHEL/compatible target, Vault connectivity, usually PVWA reachability; PTA vendor media. **Stages:** OS prerequisites → installer → API token/configure → audited SELinux handling if required → reboot if needed → verify. **Checks:** relevant services, installer API state, Vault and PVWA integration, optional event ingestion/functional test. **Source gap:** uploaded PTA role is an archive containing nested repeated copies; it performs broad OS updates, installer API calls with TLS verification disabled, and temporary SELinux disable/re-enable with reboots. Reimplement with scoped prerequisites, secure transport and explicit recovery checkpoints. `PTA` log catalog is not covered by the admin-center CSV and must be discovered in real qualified installations.

### PTA TLS audit continuation implementation

After successful PTA TLS configuration, registration and hardening, the public controller configures primary Vault TLS syslog using the checkpoint-pinned public CA bundle. For an existing Vault, set `vault.managementHost` to its Windows host record (or use the unique exact-address host record). Supply `Credentials[managementHost]` as an independent OS PSCredential; `VaultAdmin` remains a separate SecureString. The management endpoint defaults to `PAExec.Management`. The primary must be a running workgroup Vault at the configured address. Unrelated existing SIEM configuration and unknown translator hashes are refused. Certificate bytes contain no private key, and receiver ingestion requires separate functional evidence.

Use a literal PTA IPv4 host address; `options.ptaName` supplies its DNS certificate name. An explicit audited `Lab` override `PTA.SkipVaultSyslog=true` can omit primary mutation, with ingestion left NotTested. This implementation has controller/unit qualification only until its fresh product run is recorded in `Docs/Verification/pta-public-continuation-20261117/`.

## Active Directory (`NewForest`, `ExistingForest`, `JoinWindowsHost`)

**NewForest:** selected Windows Server must pass static IP/DNS, OS role and available-storage checks. Install AD DS/DNS roles, call Microsoft prerequisite test (`Test-ADDSForestInstallation`), then `Install-ADDSForest`, record promotion attempt and reboot; verify DC health, DNS SRV records, SYSVOL, forest info, replication as relevant. One-DC disposable lab is allowed; never imply production redundancy. Domain creation is a destructive/infrastructure-significant operation and requires deliberate approval.

**ExistingForest:** verify DNS, DC reachability, time sync, and account permissions. Do not modify forests or create users unless specifically selected.

**JoinWindowsHost:** only eligible selected hosts; configure DNS prerequisite as approved, join, reboot, verify secure channel and re-establish WinRM identity/credential assumptions after the domain transition. Vault/DR never domain joined through the installer. Linux join is deferred until each Linux PAM target supports and qualifies it; do not auto-join PSMP/PTA simply because they run Linux.

**Lab identities:** optional dedicated OU, ordinary users and clearly labeled disposable test principals. No automatic Domain Admins assignment. Prevent duplicate creation on resume and report identities for later cleanup.

## Dependency outline

```text
AD new/existing (optional) → eligible domain joins → Windows role prerequisites
Primary Vault verified → DR registration/replication
Primary Vault verified → PVWA / CPM / PSM / PSMP registrations
PVWA verified → PTA and tests that explicitly require PVWA
All selected components operational → final report
```

Dependency edges are per **node**, not coarse component status; software installation and Vault registration are separate. The planner may install media on an independent host before the Vault is ready but cannot register a component early.

## Compatibility and co-location

| Combination | Initial policy |
|---|---|
| Primary Vault + DR on same host | Block |
| Vault or DR + AD DC | Block |
| Vault or DR + PVWA/CPM/PSM | Block by default |
| PVWA + CPM same Windows host | Experimental lab until explicitly qualified |
| PSM + PVWA/CPM | Experimental lab; carefully inspect RDS/Windows hardening interference |
| PSMP + PTA same Linux host | Block until qualified |
| Multi-instance component on distinct hosts | Representable; only enable per qualified recipe variant |

Vendor PAS Orchestrator source states a single component per server limitation; our custom installation flow cannot inherit any implied co-location support. Each allowed pairing needs combined post-hardening and upgrade-impact tests.

## Version and variant policy

Use an explicit compatibility table keyed by CyberArk version, recipe revision, OS version, security profile and topology. Unknown combinations are `Unqualified`; `Lab` may allow experimental configurations with explicit warning and a report label, but it must not misstate vendor support. Future Distributed Vault, Cluster Vault, PSM alternate install modes and component extensions have independent `type:variant` entries with their own DAG and qualification evidence.
