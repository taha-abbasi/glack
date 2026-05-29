#!/usr/bin/env bash
# Run Glack unit tests via xcodebuild.
# Usage: ./scripts/test.sh [optional xcodebuild args]
set -euo pipefail

cd "$(dirname "$0")/.."

# xcode-select on this Mac points at CommandLineTools — override to real Xcode.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# Regenerate the project if project.yml is newer than the .xcodeproj.
if [ project.yml -nt Glack.xcodeproj/project.pbxproj ] 2>/dev/null || [ ! -d Glack.xcodeproj ]; then
  xcodegen generate
fi

xcodebuild \
  -scheme Glack \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath ./build \
  CODE_SIGNING_ALLOWED=NO \
  test \
  "$@" \
  | grep -E '(Test Suite|Test Case|passed|failed|error:|warning:.*Glack/|✔|✗|◇|✘|BUILD )' \
  | head -200
