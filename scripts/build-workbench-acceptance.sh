#!/bin/bash
# Explicit preparation; an automatic edit check never performs these cold builds.
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/build-workbench.sh "${1:-debug}"
mkdir -p .build/workbench-consumers
container="$(mktemp -d "$PWD/.build/workbench-consumers/build.XXXXXX")"
fixture="$container/ConsumerApp"
python3.14 scripts/workbench_identity.py prepare-consumer --root "$PWD" --fixture "$fixture"
swift build --package-path "$fixture" --jobs 2 --product ConsumerScenarios --force-resolved-versions \
  -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete
bin="$(swift build --package-path "$fixture" --show-bin-path)"
toolchain="$(swift --version)"
python3.14 scripts/workbench_identity.py stamp-consumer --root "$PWD" \
  --fixture "$fixture" --runner "$bin/ConsumerScenarios" \
  --output "$PWD/.verdictui/workbench-consumer.json" --toolchain "$toolchain"
python3.14 scripts/workbench_identity.py inputs --root "$PWD" \
  --app "$PWD/dist/VerdictUI.app" --runner "$bin/ConsumerScenarios" \
  --receipt "$PWD/.verdictui/workbench-consumer.json" \
  --output "$PWD/dist/workbench-acceptance-inputs.json"
echo "WORKBENCH ACCEPTANCE INPUTS BUILT: $PWD/dist/VerdictUI.app"
