#!/usr/bin/env bash

zola build -o temp --force

if ! [ -d "mokurin000.github.io" ]; then
    git clone https://github.com/mokurin000/mokurin000.github.io
fi

rm -rf mokurin000.github.io/*
mv temp/* mokurin000.github.io

rmdir temp
