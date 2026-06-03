#!/usr/bin/env bash

bash _build.sh || exit 1

cd mokurin000.github.io

if [ -z "$(git status --porcelain)" ]; then
    echo "Nothing to commit, exiting"
    exit 0
fi

git add -A
git commit -m "chore: update blog"
git push
