# Symphony

Symphony turns tracker work into isolated coding-agent runs. A workflow describes both the
runtime settings for one target repository and the instructions an agent follows while handling
its work.

## Workflow composition

**Workflow entry**:
A project-owned `WORKFLOW.md` selected at Symphony startup. It supplies project-specific runtime
settings and names the shared workflow sources from which its effective workflow is resolved.
_Avoid_: Root workflow, child workflow

**Workflow library**:
A repository-owned, reusable workflow source under `my/workflow-libraries/`. A library is either a
YAML configuration fragment or a Markdown agent-flow prompt; it is not an independently runnable
workflow.
_Avoid_: Template, base project

**Effective workflow**:
The validated configuration and prompt produced from one workflow entry and all of its workflow
libraries. Symphony runs only the effective workflow.
_Avoid_: Merged file, expanded config
