---
include:
  - ../workflow-libraries/github-serial.yml
prompt_file: ../workflow-libraries/github-serial.md
tracker:
  provider:
    repo: jerryylj/stock_manage
workspace:
  root: ~/code/stock-manage-symphony-workspaces
hooks:
  after_create: |
    GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_KEY_0=http.version \
    GIT_CONFIG_VALUE_0=HTTP/1.1 \
    http_proxy=http://127.0.0.1:7890 \
    https_proxy=http://127.0.0.1:7890 \
    all_proxy=http://127.0.0.1:7890 \
    no_proxy=localhost,127.0.0.1 \
    NO_PROXY=localhost,127.0.0.1 \
    gh repo clone jerryylj/stock_manage . -- --depth 1
agent:
  max_turns: 40
  block_on_max_turns: true
codex:
  command: env -u http_proxy -u https_proxy -u all_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u no_proxy -u NO_PROXY codex app-server --config shell_environment_policy.inherit=all --config 'plugins."unified-computer-use@openai-bundled".enabled=false' --config 'plugins."computer-use@openai-bundled".enabled=false' --config 'model="ark-code-latest"' --config 'model_provider="volcengine"' --config 'model_reasoning_effort="low"' --config 'model_catalog_json="/Users/yd/.codex/model-catalogs/volcengine-glm-5-3-flash.json"' --config 'model_providers.volcengine.name="Volcengine"' --config 'model_providers.volcengine.base_url="https://ark.cn-beijing.volces.com/api/coding/v3"' --config 'model_providers.volcengine.env_key="ARK_API_KEY"' --config 'model_providers.volcengine.wire_api="responses"'
---
