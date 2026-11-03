#!/bin/zsh
# Runs EngineIntegrationTests with real inference. Needs xcodebuild (Metal shaders)
# and local weights. Suites run one after another: two loaded models at once would
# not fit in 24 GB of unified memory. Missing weights → tests report SKIPPED.
set -uo pipefail
cd "$(dirname "$0")/.."
STATUS=0
for suite in MLXEngineIntegrationTests ZImageIntegrationTests CoreMLEngineIntegrationTests PromptAssistantIntegrationTests; do
  TEST_RUNNER_NIS_RUN_INTEGRATION=1 xcodebuild test \
    -scheme NativeImageStudio-Package -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath .build/xcode -only-testing:EngineIntegrationTests/$suite \
    -skipPackagePluginValidation -skipMacroValidation "$@" > .build/integration-$suite.log 2>&1 || STATUS=1
  grep -E "Test (case|Suite|run)|✔|✘|􁁛|􀢄|􀙟|recorded an issue|skipped|passed after|failed after|error:" .build/integration-$suite.log \
    | grep -v "/SourcePackages/checkouts/\|appintentsmetadataprocessor"
done
exit $STATUS
