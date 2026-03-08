# Nexus Role

## Role Statement

Nexus remains the general execution layer.

Its scope is:

- execution environment management
- shell and file execution
- browser and desktop automation
- deploy and data collection tasks
- sandbox profile enforcement

Its scope is not:

- programmable-agent deployment registration, run planning, or control-plane ownership
- prompt planning or final prompt assembly
- conversation logic
- LLM loop ownership

## Mapping To Product Concepts

Suggested long-term mapping:

- `Conduits::Territory` -> `ExecutionLocation`
- `Conduits::Facility` -> workspace backing resource or workspace handle
- `Conduits::Directive` -> execution request against an execution target

This mapping needs refinement during re-alignment because the current Conduits model was built before the new deployment-oriented programmable-agent split.

`ExecutionLocation`, `Workspace`, and `ExecutionTarget` are product-layer canonical models owned by Cybros.

Conduits should adapt to them, not define them.

## Important Consequence

Nexus and Cybros have already drifted during parallel development. The next integration phase must re-baseline protocol semantics instead of assuming current Conduits concepts are final.

## Mothership

Mothership should be treated as a protocol testbed and development stand-in, not as the product architecture blueprint.

Recommended workflow:

- define product semantics in Cybros docs first
- prototype protocol changes in Mothership when that speeds up Nexus iteration
- port the proven protocol behavior back into Cybros
