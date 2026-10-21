"""v1.104 xAI (Grok) compatibility for the grok1 worker and the claude/xai/* front routes.

Worker side, scoped to the xAI Responses provider so ChatGPT and native routes are untouched:
- store=false on every request; xAI otherwise stores responses (Grok's own client sends false).
- no `user` field: the Messages bridge fills it from Claude Code's metadata.user_id, which
  carries account and device ids.
- a terminal stream event whose response failed LiteLLM's typing stays a dict, and the
  provider's cost restatement then crashes on `.usage`, truncating the stream with no stop
  event. Return the base event instead, without the restatement.
Front side, scoped to claude/xai/* models: one prompt_cache_key per Claude Code subagent
(x-claude-code-agent-id). The bridge otherwise keys every subagent of a session on the same
session id, and xAI uses the key as its conversation id.
"""
import hashlib
import uuid

from litellm.integrations.custom_logger import CustomLogger
from litellm.llms.openai.responses.transformation import OpenAIResponsesAPIConfig
from litellm.llms.xai.responses.transformation import XAIResponsesAPIConfig


def install():
    cls = XAIResponsesAPIConfig
    if getattr(cls, '_cma_grok_compat_installed', False):
        return
    original_request = cls.transform_responses_api_request
    original_stream = cls.transform_streaming_response

    def request(self, model, input, response_api_optional_request_params, litellm_params, headers):
        result = original_request(self, model, input, response_api_optional_request_params, litellm_params, headers)
        result.pop('user', None)
        result['store'] = False
        return result

    def stream(self, model, parsed_chunk, logging_obj):
        try:
            return original_stream(self, model=model, parsed_chunk=parsed_chunk, logging_obj=logging_obj)
        except AttributeError:
            event = OpenAIResponsesAPIConfig.transform_streaming_response(
                self, model=model, parsed_chunk=parsed_chunk, logging_obj=logging_obj)
            if not hasattr(getattr(event, 'response', None), 'usage'):
                return event
            raise

    cls.transform_responses_api_request = request
    cls.transform_streaming_response = stream
    cls._cma_grok_compat_installed = True


def subagent_cache_key(data):
    """A stable per-subagent key, or None for the coordinator or a non-Grok model."""
    if '/xai/' not in str(data.get('model')) or data.get('prompt_cache_key'):
        return None
    headers = (data.get('proxy_server_request') or {}).get('headers') or {}
    named = {str(name).lower(): value for name, value in headers.items() if isinstance(value, str)}
    agent = named.get('x-claude-code-agent-id')
    if not agent:
        return None
    session = named.get('x-claude-code-session-id', '')
    # UUID-shaped, like the session id the bridge sends by default: the only key shape tried live.
    digest = hashlib.sha256((session + '\0' + agent).encode()).digest()
    return str(uuid.UUID(bytes=digest[:16], version=5))


class GrokCompat(CustomLogger):
    async def async_pre_call_hook(self, user_api_key_dict, cache, data, call_type):
        key = subagent_cache_key(data)
        return data if key is None else {**data, 'prompt_cache_key': key}


install()
callback = GrokCompat()
