// A trimmed copy of https://models.dev/api.json?type=transcription as fetched on 13 November 2026: four of its
// nineteen providers and a few of their models, with the fields Oops ignores (env, npm, cost, limit…) kept so
// decoding proves it tolerates them.
let modelsDevFixture = #"""
{
 "groq": {"id": "groq", "env": ["GROQ_API_KEY"], "npm": "@ai-sdk/groq", "name": "Groq", "doc": "https://console.groq.com/docs/models",
  "models": {
   "whisper-large-v3-turbo": {"id": "whisper-large-v3-turbo", "type": "transcription", "name": "Whisper Large V3 Turbo",
    "description": "Speech transcription model for accurate audio-to-text and captioning workflows", "family": "whisper",
    "attachment": true, "reasoning": false, "tool_call": false, "temperature": true, "release_date": "2024-10-01", "last_updated": "2024-10-01",
    "modalities": {"input": ["audio"], "output": ["text"]}, "open_weights": true, "limit": {"context": 448, "output": 448},
    "canonical_model_id": "openai/whisper-large-v3-turbo"},
   "whisper-large-v3": {"id": "whisper-large-v3", "type": "transcription", "name": "Whisper", "family": "whisper",
    "modalities": {"input": ["audio"], "output": ["text"]}, "open_weights": true, "limit": {"context": 448, "output": 448},
    "canonical_model_id": "openai/whisper-large-v3"}
  }},
 "mistral": {"id": "mistral", "env": ["MISTRAL_API_KEY"], "npm": "@ai-sdk/mistral", "name": "Mistral",
  "models": {
   "voxtral-mini-latest": {"id": "voxtral-mini-latest", "type": "transcription", "name": "Voxtral Mini (latest)", "family": "voxtral",
    "attachment": true, "temperature": false, "release_date": "2026-02-04", "last_updated": "2026-02-04",
    "modalities": {"input": ["audio"], "output": ["text"]}, "open_weights": false, "limit": {"context": 0, "output": 0}}
  }},
 "vercel": {"id": "vercel", "env": ["AI_GATEWAY_API_KEY"], "npm": "@ai-sdk/gateway", "name": "Vercel AI Gateway",
  "models": {
   "openai/whisper-1": {"id": "openai/whisper-1", "type": "transcription", "name": "Whisper", "family": "whisper",
    "modalities": {"input": ["audio"], "output": ["text"]}, "provider": {"api": "https://ai-gateway.vercel.sh/v4/ai"},
    "canonical_model_id": "openai/whisper-1"},
   "google/gemini-3.5-transcribe": {"id": "google/gemini-3.5-transcribe", "type": "transcription", "name": "Gemini 3.5 Transcribe",
    "modalities": {"input": ["audio"], "output": ["text"]}, "cost": {"input": 2, "output": 12, "input_audio": 2},
    "canonical_model_id": "google/gemini-3.5-transcribe"},
   "microsoft/mai-transcribe-2-streaming": {"id": "microsoft/mai-transcribe-2-streaming", "type": "transcription",
    "name": "MAI-Transcribe-2-Streaming", "family": "mai", "modalities": {"input": ["audio"], "output": ["text"]}}
  }},
 "llmgateway": {"id": "llmgateway", "env": ["LLMGATEWAY_API_KEY"], "npm": "@ai-sdk/openai-compatible", "api": "https://api.llmgateway.io/v1",
  "name": "DevPass (LLM Gateway)",
  "models": {
   "gpt-live-transcribe": {"id": "gpt-live-transcribe", "type": "transcription", "name": "GPT-Live-Transcribe", "family": "gpt",
    "structured_output": false, "modalities": {"input": ["text", "audio"], "output": ["text"]}, "cost": {"input": 0, "output": 0},
    "canonical_model_id": "openai/gpt-live-transcribe"}
  }}
}
"""#
