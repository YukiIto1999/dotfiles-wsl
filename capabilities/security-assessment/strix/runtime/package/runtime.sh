#!/usr/bin/env bash

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  printf '%s\n' 'Usage: dotfiles-strix-runtime inspect|cleanup RUN_ID' \
    'Inspect or remove only the sandbox containers labelled with the supplied owned Strix run ID.' \
    'Stop the owned assessment process before cleanup. This does not remove reports or prune images.'
  exit 0
fi
if (( $# != 2 )) || [[ $1 != inspect && $1 != cleanup ]] \
  || [[ ! $2 =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
  printf '%s\n' 'Usage: dotfiles-strix-runtime inspect|cleanup RUN_ID' >&2
  exit 2
fi

operation=$1
run_id=$2
container_ids=$(docker ps --all --quiet --filter "label=strix-run-id=$run_id")
if [[ -z "$container_ids" ]]; then
  printf '%s\n' '[]'
  exit 0
fi
mapfile -t containers <<< "$container_ids"

if [[ $operation == cleanup ]]; then
  docker rm --force --volumes "${containers[@]}" >/dev/null
  remaining=$(docker ps --all --quiet --filter "label=strix-run-id=$run_id")
  if [[ -n "$remaining" ]]; then
    printf '%s\n' 'dotfiles-strix-runtime: owned run containers remain; cleanup is incomplete' >&2
    exit 1
  fi
  printf '%s\n' '[]'
else
  docker inspect --format '{{json .}}' "${containers[@]}" \
    | jq --slurp '[.[] | {
        id: .Id,
        name: .Name,
        run_id: .Config.Labels["strix-run-id"],
        run_type: .Config.Labels["strix-run-type"],
        image: .Config.Image,
        state: {status: .State.Status, exit_code: .State.ExitCode, oom_killed: .State.OOMKilled},
        limits: {memory_bytes: .HostConfig.Memory, nano_cpus: .HostConfig.NanoCpus, pids: .HostConfig.PidsLimit}
      }]'
fi
