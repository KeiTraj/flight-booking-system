#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULT_DIR="${ROOT_DIR}/jmeter/results"

echo "Preparing results directory at ${RESULT_DIR}..."
if [[ -d "${RESULT_DIR}" ]]; then
  find "${RESULT_DIR}" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
else
  mkdir -p "${RESULT_DIR}"
fi

echo "Starting JMeter load test via docker compose..."
(
  cd "${ROOT_DIR}"
  docker compose run --rm jmeter
)

echo
echo "Load test complete."
echo "Raw results: ${RESULT_DIR}/results.jtl"
echo "HTML report: ${RESULT_DIR}/report/index.html"
