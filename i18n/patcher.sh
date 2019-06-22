#!/bin/bash
# Creates a patch file from a diff
GLOB="$1" # pattern to diff on
PATCH_NAME="$2"

TARGET_BRANCH="57969-i18n-linters-eslint-vue"
SRC_BRANCH="master"

CMD_TARGET="git checkout $TARGET_BRANCH"

CMD="git diff $SRC_BRANCH..$TARGET_BRANCH -- $GLOB >> $PATCH_NAME.patch"

eval $CMD_TARGET && $CMD
