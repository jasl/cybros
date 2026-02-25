# Execution Subsystem Design (v0.6)

Split from the original monolithic `execution_subsystem_design.md` for readability.

## Table of Contents

| File | Sections | Topics |
|------|----------|--------|
| [00_overview.md](00_overview.md) | 0-2 | Scope, principles, platform requirements, language strategy, runtime artifacts, requirements, threat model |
| [01_architecture.md](01_architecture.md) | 3-4 | Overall architecture, Monolith organization, data model (Territory, Facility, Directive, Policy) |
| [02_security_profiles.md](02_security_profiles.md) | 5-6 | Execution profiles (Untrusted/Trusted/Host/darwin-automation), Nexus registration & mTLS |
| [03_network_filesystem.md](03_network_filesystem.md) | 7-8 | Network egress policy (modes, allowlist, proxy, audit, JSON Schema), filesystem & IO control |
| [04_protocol_reliability.md](04_protocol_reliability.md) | 9-10 | DirectiveSpec protocol, reliability checklist (NAT, leases, logs, credentials, secrets) |
| [05_deployment_roadmap.md](05_deployment_roadmap.md) | 11-14 | Deployment topologies, installation/distribution, AgentCore integration, implementation roadmap (Phase 0-6) |
| [06_operations.md](06_operations.md) | 15-22 | API draft, scheduling/resources, UX rules, monorepo organization, territory capabilities, provisioning, monitoring, development pitfalls |
| [07_reference_analysis.md](07_reference_analysis.md) | — | Comparative analysis of 10 open-source agent projects + Claude.app |

## Protocol Schemas

- [conduits_api_openapi.yaml](../protocol/conduits_api_openapi.yaml) — OpenAPI spec for Conduits API
- [directivespec_capabilities_net.schema.v1.json](../protocol/directivespec_capabilities_net.schema.v1.json) — Network capability JSON Schema (V1, frozen)
