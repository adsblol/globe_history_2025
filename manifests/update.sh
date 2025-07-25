#!/bin/bash
# Copyright 2023 kat
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -o errexit
set -o nounset
set -o pipefail
set -ex
function cleanup(){
    if [ -z "${AFTER_SCRIPT:-}" ]; then
        echo "[ info] AFTER_SCRIPT is not set, skipping"
    else
        bash -c "$AFTER_SCRIPT"
    fi
}
trap cleanup EXIT
# This script:
# Is idempotent. It can be run multiple times without causing any issues.
# 1. Gets the name of the pods starting with 'planes-readsb-' and put it in a variable called 'PODS'
# 2. For each pod, list the folders
#    like this: kubectl exec -ti $POD -- find /var/globe_history/$YEAR -maxdepth 2
# 3. For each folder, check if it's a path like /var/globe_history/YYYY/MM/DD and that it is older than 1 day.
# 4. If it is, check if we already backed it up.
#    We can check by seeing if there is a GitHub Release vYYYY.MM.DD
# 5. If we haven't backed it up,
#    5.1. MKTEMP a folder
#    5.2. kubectl cp the folder to the temp folder
#    5.3. tar the temp folder
#    5.4. Try splitting the tar since it might be too big for GitHub (2GB limit)
#    5.5. Upload the tar to GitHub releases
#    5.6. Add a new line to the README.md with the direct link to the download
#    5.7. Commit the README.md
#    5.8. Push the README.md
#    5.9. Delete the temp folder
# 6. If we have backed it up, do nothing.
# 7. If the folder is not a date, do nothing.
# 8. If the folder is not older than 1 day, do nothing.

# Try sorucing .env in current folder
CURRENT_DIR=$(dirname "$0")
if [ -f "$CURRENT_DIR/.envrc" ]; then
    source "$CURRENT_DIR/.envrc" || true
fi

CURRENT_YEAR=$(date +%Y)

PODS=$(kubectl -n adsblol get pods | grep planes-readsb | awk '{print $1}')
SAVEIFS=$IFS

# Ensure dependencies
for CMD in wget curl tar git gettext; do
    if ! command -v $CMD &> /dev/null
    then
        apt-get install -y $CMD || apt-get update && apt-get install -y $CMD
    fi
done

DATA_DIR=$(mktemp -d)
# We get README.txt, LICENSE-cc0.txt, and LICENSE-ODbL.txt from the github repo
for FILE in README.txt LICENSE-cc0.txt LICENSE-ODbL.txt; do
    wget -O "$DATA_DIR/$FILE" "https://raw.githubusercontent.com/adsblol/globe_history_$CURRENT_YEAR/main/$FILE"
done

#
# Let's make sure we have github-release in our path
if ! command -v github-release &> /dev/null
then
    # what system are we? darwin_amd64, linux_amd64, etc.
    SYSTEM=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m | sed 's/x86_64/amd64/g' | sed 's/aarch64/arm64/g')
    # If darwin, get fucked, amd64 only
    if [ "$SYSTEM" == "darwin" ]; then
        ARCH="amd64"
    fi
    URL="https://github.com/c4milo/github-release/releases/download/v1.1.0/github-release_v1.1.0_${SYSTEM}_${ARCH}.tar.gz"
    OUT=$(mktemp)
    while ! timeout 10 curl -L -s -o $OUT $URL; do
        echo "Failed to download github-release, retrying in 3s..."
        sleep 3
    done
    tar -C /usr/local/bin -xzf $OUT github-release
    rm $OUT
fi

for POD in $PODS; do
    echo "[ info] Processing pod $POD"
    export YEAR=$(date +%Y)
    FOLDERS=$(kubectl -n adsblol exec -ti $POD -c readsb -- find /var/globe_history/ -maxdepth 3 -mindepth 3 | sort -r | head -n7 || true)
    READSB_VERSION=$(kubectl -n adsblol exec $POD -c readsb -- readsb --version || true)

    IFS=$'\n\r'
    for FOLDER in $FOLDERS; do
        IFS=$SAVEIFS
        # 3. Check if it is a date. /var/globe_history/YYYY/MM/DD
        DATE=$(printf "$FOLDER" | grep -Eo '[0-9]{4}/[0-9]{2}/[0-9]{2}' || true)
        if [ -z "$DATE" ]; then
            echo "[ info] $FOLDER is not a date. Skipping."
            continue
        fi
        # RELEASE_NAME=v2023.12.31-planes-readsb-test-0
        DATE_WITH_DOTS=$(echo $DATE | sed 's/\//./g')
        export DATE_WITH_DASHES=$(echo $DATE | sed 's/\//-/g')
        export RELEASE_NAME="v$DATE_WITH_DOTS-${POD}"
        export RELEASE_LINK="https://github.com/adsblol/globe_history_$CURRENT_YEAR/releases/tag/$RELEASE_NAME"
        TODAY=$(date +%Y/%m/%d)
        export TODAY_WITH_DASHES=$(date +%Y-%m-%d)
        export FOLDER=$FOLDER
        export POD=$POD
        # 3. Each folder is a day. We do not want to back up today's folder because it is still being written to.
        #    So we only want to back up folders that do not have today's date.
        if [ "$DATE" == "$TODAY" ]; then
            echo "[ info] $FOLDER is today's date. Skipping."
            continue
        fi
        # 4. Check if we already backed it up.
        #    We can check by seeing if there is a GitHub Release vYYYY.MM.DD
        RELEASE=$(curl -H "Authorization: Bearer $GITHUB_TOKEN" -s https://api.github.com/repos/adsblol/globe_history_$CURRENT_YEAR/releases | jq -r '.[].tag_name' | grep '^$RELEASE_NAME$' || true)
        # If it exists, we skip
        if [ ! -z "$RELEASE" ]; then
            echo "[ info] $RELEASE_NAME has already been backed up. Skipping."
            continue
        fi
        # Try seeing if file exists,
        # https://github.com/adsblol/globe_history_2024/releases/download/v2024.01.19-planes-readsb-staging-0/v2024.01.19-planes-readsb-staging-0.tar
        # If it exists, we skip
        FILE_URL="https://github.com/adsblol/globe_history_$CURRENT_YEAR/releases/download/$RELEASE_NAME/$RELEASE_NAME.tar"
        if curl -s --head $FILE_URL | head -n 1 | grep "HTTP/[123][.1]* [23].." > /dev/null; then
            echo "[ info] $FILE_URL has already been backed up. Skipping."
            continue
        fi
        # Otherwise let's get to work
        echo "[ info] Backing up $RELEASE_NAME"
        # 5.1. MKTEMP a folder
        TMP_FOLDER=$(mktemp -d)
        # 5.2. kubectl cp the folder to the temp folder
        COPY_TRIES=0
        until kubectl -n adsblol cp --retries=15 "$POD:$FOLDER" "$TMP_FOLDER"; do
            COPY_TRIES=$((COPY_TRIES+1))
            if [ $COPY_TRIES -gt 15 ]; then
                echo "[ error] Failed to copy $FOLDER from $POD after 15 tries. Exiting."
                exit 1
            fi
            echo "[ info] Failed to copy $FOLDER from $POD, retrying in 2s..."
            sleep 2
        done
        # If no data was copied, skip
        if [ ! "$(ls -A $TMP_FOLDER)" ]; then
            echo "[ info] $FOLDER is empty. Skipping."
            continue
        fi
        # Add the ODbL license to the folder
        cp "$DATA_DIR/LICENSE-cc0.txt" "$DATA_DIR/LICENSE-ODbL.txt" "$TMP_FOLDER"
        envsubst < "$DATA_DIR/README.txt" > "$TMP_FOLDER/README.txt"

        # 5.3. tar the temp folder (.tar, since it is zstd files inside)
        TMPTAR=$(mktemp -d)
        TARNAME="$TMPTAR/$RELEASE_NAME.tar"
        tar -C "$TMP_FOLDER" -cf "$TARNAME" .
        # 5.4. Try splitting the tar since it might be too big for GitHub (2GB limit)
        # Only split if the file is bigger than 2GB
        # WARNING! This only works on macos
        #if [ $(stat -f%z "$TARNAME") -gt 2000000000 ]; then
        # for linux,
        if [ $(stat -c%s "$TARNAME") -gt 2000000000 ]; then
            echo "[ info] $TARNAME is bigger than 2GB. Splitting."
            # Split the tar into 2GB chunks
            split -b 2000000000 "$TARNAME" "$TMPTAR/$RELEASE_NAME.tar."
            # Delete the original tar
            rm "$TARNAME"
        fi
        SHOULD_SKIP=0
        # check if these split files exist in the release, if they do, skip
        for FILE in $(ls "$TMPTAR"); do
            FILE_URL="https://github.com/adsblol/globe_history_$CURRENT_YEAR/releases/download/$RELEASE_NAME/$FILE"
            if curl -s --head $FILE_URL | head -n 1 | grep "HTTP/[123][.1]* [23].." > /dev/null; then
                echo "[ info] $FILE_URL has already been backed up. Skipping."
                SHOULD_SKIP=$((SHOULD_SKIP+1))
            fi
        done
        # if SHOULD_SKIP is the same as the n of files, skip
        if [ $SHOULD_SKIP -eq $(ls "$TMPTAR" | wc -l) ]; then
            echo "[ info] All files have already been backed up. Skipping."
            rm -rf "$TMPTAR" "$TMP_FOLDER"
            continue
        fi
        # 5.5. Upload the tar to GitHub releases
        README=$(echo '```' && cat "$TMP_FOLDER/README.txt" && echo '```')
        github-release adsblol/globe_history_$CURRENT_YEAR "$RELEASE_NAME" main "$README" "$TMPTAR/*"
        rm -rf "$TMPTAR" "$TMP_FOLDER"

    done
    # Run cleanup in the pod
    kubectl -n adsblol exec -ti $POD -- bash /var/globe_history/cleanup.sh || true
done
# AFTER_SCRIPT might be set in .envrc
# This is useful for running commands to clean up after the script
