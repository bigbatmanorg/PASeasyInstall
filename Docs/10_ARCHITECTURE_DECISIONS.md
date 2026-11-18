# 10 — Architecture Decisions (ADRs)

All are **Accepted for the proposed implementation**, subject to evidence-driven revision. Avoid reopening without a demonstrated defect or failed qualification gate.

| ID | Decision | Rationale | Reconsider only when... |
|---|---|---|---|
| ADR-01 | **One PowerShell module** with internal runner | Simplicity and ability to modify any code; no PSSteps dependency | None; this is a product requirement |
| ADR-02 | **Global sequential mutating scheduler initially** | Full lab reliability, Vault serialization, simpler recovery and debugging | End-to-end qualification passes, then measured install time justifies parallelism |
| ADR-03 | **Windows PowerShell 5.1 initial qualified controller** | Existing Windows Vault/DR evidence and native OS/WinRM integration | PS7 + GUI + secrets + detached execution are independently qualified |
| ADR-04 | **Optional NativeHTMLKit GUI** loaded on demand | Headless CLI/Gallery import without desktop dependencies | None; retain optionality |
| ADR-05 | **Local JSON persistence, no DB** | One operator/controller; inspectable and recoverable | Multi-controller multi-user writes become a real requirement |
| ADR-06 | **Durable remote attempts, independent verification** | Long vendor installations/reboots and transient networks make naive retries unsafe | Never remove this guarantee |
| ADR-07 | **Environment lease + Vault-authentication gate** | Prevent application-owned login collisions and double deploy | Only broaden gate granularity after demonstrable safe concurrency |
| ADR-08 | **Static component recipes, no plugin framework** | Components and variants are known and few; testability | Large external developer ecosystem becomes a proven requirement |
| ADR-09 | **Secure default + explicit lab overrides** | Realistic testing without insecure silent defaults | Only add overrides implemented and qualified per recipe |
| ADR-10 | **Host identity and shared prerequisites** | Co-location must not duplicate reboots/hardening/IIS/role changes | None; structural requirement |
| ADR-11 | **Module-managed separate controller process** | GUI closure must not stop an install; no permanent service | Unattended logoff persistence proves Scheduled Task mode required |
| ADR-12 | **Candidate log catalog + live discovery** | Admin-center paths valuable but not guaranteed version 15 or custom installs | Always verify paths on target |
| ADR-13 | **Operational health distinct from installed state** | Service files alone do not prove CPM/PSM/DR/PSMP functionality | None |
| ADR-14 | **No automatic general rollback** | CyberArk external registrations, keys and hardening are not atomic | A dedicated vendor-supported rollback recipe is independently qualified |
| ADR-15 | **Represent future variants explicitly, do not implement speculatively** | Distributed Vault/cluster/PSM modes require independent topology and acceptance | Once a concrete variant is prioritized, write its own recipe and tests |

## Explicit tradeoff: sequential versus parallel

The initial execution model may take longer than a mature parallel installer. That is acceptable because the user's highest priorities are *reliable, maintainable, focused*. There is still a single topological plan for multiple hosts and components; the operator can start a full deployment and leave it unattended under a qualified controller identity. The resource field in each node permits later selective concurrency without a second scheduler or API rewrite.

## Explicit tradeoff: Gallery installation versus GUI

A Gallery user installing the main module alone gets all CLI features. GUI requires separate NativeHTMLKit PowerShell SDK/UI modules (or an offline package), loaded when requested. Treat that optional dependency as a feature, not a contradictory second application.

## Explicit tradeoff: simplified process model versus unattended logoff

GUI-close persistence is a release requirement. Controller survival across **user logoff** depends on a qualified Scheduled Task identity and secret provider; it is a separate acceptance gate. Do not promise both based on the original same-user detached process workaround alone.
