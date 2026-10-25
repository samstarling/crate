#!/bin/sh
# Submits a file to Apple's notary service and waits for the result, printing the
# notary log and failing if it isn't accepted.
#
# Usage: scripts/notarize.sh <file.zip|file.dmg>
# Needs ASC_API_KEY_PATH, ASC_API_KEY_ID and ASC_API_ISSUER_ID in the environment.
set -eu

file="$1"
auth="--key $ASC_API_KEY_PATH --key-id $ASC_API_KEY_ID --issuer $ASC_API_ISSUER_ID"

# shellcheck disable=SC2086
result=$(xcrun notarytool submit "$file" $auth --wait --output-format json)
echo "$result"

id=$(echo "$result" | plutil -extract id raw -)
status=$(echo "$result" | plutil -extract status raw -)

# shellcheck disable=SC2086
xcrun notarytool log "$id" $auth

if [ "$status" != "Accepted" ]; then
    echo "Notarization of $file finished with status: $status" >&2
    exit 1
fi
