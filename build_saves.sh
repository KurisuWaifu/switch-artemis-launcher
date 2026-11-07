#!/bin/bash
set -e

rm -f nora2_save.zip seedsow_save.zip hamidashi_save.zip nora_save.zip

pushd ./common >/dev/null
zip -qr ../nora2_save.zip .
zip -qr ../seedsow_save.zip .
zip -qr ../hamidashi_save.zip .
zip -qr ../nora_save.zip .
popd >/dev/null


if [[ ! -d ./nora2_save ]]; then
  echo "Missing ./nora2_save directory" >&2
  exit 1
fi

pushd ./nora2_save >/dev/null
zip -qr ../nora2_save.zip .
popd >/dev/null

if [[ ! -d ./seedsow_save ]]; then
  echo "Missing ./seedsow_save directory" >&2
  exit 1
fi

pushd ./seedsow_save >/dev/null
zip -qr ../seedsow_save.zip .
popd >/dev/null

if [[ ! -d ./hamidashi_save ]]; then
  echo "Missing ./hamidashi_save directory" >&2
  exit 1
fi

pushd ./hamidashi_save >/dev/null
zip -qr ../hamidashi_save.zip .
popd >/dev/null

if [[ ! -d ./nora_save ]]; then
  echo "Missing ./nora_save directory" >&2
  exit 1
fi

pushd ./nora_save >/dev/null
zip -qr ../nora_save.zip .
popd >/dev/null