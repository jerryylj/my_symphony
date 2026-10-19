---
include:
  - ../workflow-libraries/github-serial.yml
prompt_file: ../workflow-libraries/github-serial.md
tracker:
  completion_policy: merged_pr
  provider:
    repo: kunkun-code-org/stock_manage
workspace:
  root: ~/code/stock-manage-symphony-workspaces
hooks:
  after_create: |
    git clone --depth 1 git@github.com:kunkun-code-org/stock_manage.git .
agent:
  max_turns: 40
  block_on_max_turns: true
codex:
  turn_sandbox_policy:
    type: workspaceWrite
    networkAccess: false
  command: env -u http_proxy -u https_proxy -u all_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u no_proxy -u NO_PROXY codex app-server --config shell_environment_policy.inherit=all --config 'plugins."unified-computer-use@openai-bundled".enabled=false' --config 'plugins."computer-use@openai-bundled".enabled=false' --config 'model="ark-code-latest"' --config 'model_provider="volcengine"' --config 'model_reasoning_effort="low"' --config 'model_catalog_json="/Users/yd/.codex/model-catalogs/volcengine-glm-5-3-flash.json"' --config 'model_providers.volcengine.name="Volcengine"' --config 'model_providers.volcengine.base_url="https://ark.cn-beijing.volces.com/api/coding/v3"' --config 'model_providers.volcengine.env_key="ARK_API_KEY"' --config 'model_providers.volcengine.wire_api="responses"'
---
