#!/bin/bash
# Recovery for the caches deleted by scripts/acceptance.sh on 2026-09-09.
# Model identifiers were recovered from ~/.ollama/logs and
# ~/.lmstudio/.internal/model-index-cache.json, which survived the deletion.
#
# Run the sections you want. Nothing here is destructive.
set -uo pipefail

echo "=== Ollama models (15.5 GB) ==="
# Recovered from: grep 'model=registry.ollama.ai' ~/.ollama/logs
for m in codellama:7b-instruct deepseek-r1:8b llama3.2:3b; do
    echo "ollama pull $m"
done
echo "Run: for m in codellama:7b-instruct deepseek-r1:8b llama3.2:3b; do ollama pull \$m; done"

echo
echo "=== LM Studio models (6.5 GB) ==="
# Recovered from: ~/.lmstudio/.internal/model-index-cache.json
cat <<'EOF'
mlx-community/Llama-3.2-3B-Instruct-4bit                                      1.82 GB
lmstudio-community/DeepSeek-R1-Distill-Qwen-7B-GGUF
    DeepSeek-R1-Distill-Qwen-7B-Q4_K_M.gguf                                   4.68 GB
nomic-ai/nomic-embed-text-v1.5-GGUF
    nomic-embed-text-v1.5.Q4_K_M.gguf                                         0.08 GB

Re-download in the LM Studio app, or:
  lms get mlx-community/Llama-3.2-3B-Instruct-4bit
  lms get lmstudio-community/DeepSeek-R1-Distill-Qwen-7B-GGUF
  lms get nomic-ai/nomic-embed-text-v1.5-GGUF
EOF

echo
echo "=== Regenerate on demand, no action needed (9.9 GB) ==="
cat <<'EOF'
~/.npm/_cacache             4.1 GB   npm refetches automatically
~/.gradle/caches            2.8 GB   next gradle build repopulates
~/Library/Caches/Homebrew   1.4 GB   brew refetches automatically
~/Library/Caches/pip        919 MB   pip refetches automatically
EOF

echo
echo "=== Not recoverable from local metadata ==="
cat <<'EOF'
~/.cache/huggingface/hub    5.1 GB
  No surviving index named its contents. Whatever tool populated it
  (transformers, diffusers, huggingface-cli) will refetch on next use.
  Your HF auth token survived: ~/.cache/huggingface/token
EOF
