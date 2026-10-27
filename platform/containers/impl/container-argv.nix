{
  lib,
  hostConfig,
  execTokens,
}:

let
  inherit (execTokens) valuesOf argvOfScript;
  declaredSlice = hostConfig.dotfiles.workstation.workload.slices.support;

  # 生成された start script が docker へ渡す argv。宣言のどの経路から来ても
  # ここに現れるので、extraOptions だけを見ると networks や user を取り逃す
  argvOf = name: argvOfScript hostConfig.systemd.services."docker-${name}".serviceConfig.ExecStart;

  containerArgv = lib.mapAttrs (
    name: _: argvOf name
  ) hostConfig.virtualisation.oci-containers.containers;

  allowedUlimit =
    value:
    let
      limits = builtins.match "(nofile|nproc)=([1-9][0-9]*):([1-9][0-9]*)" value;
    in
    value == "core=0:0"
    || (
      limits != null
      && builtins.fromJSON (builtins.elemAt limits 1) <= builtins.fromJSON (builtins.elemAt limits 2)
    );

  allowedTmpfs =
    value:
    let
      parts = lib.splitString ":" value;
      destination = builtins.head parts;
      options = lib.splitString "," (lib.last parts);
      keys = map (option: builtins.head (lib.splitString "=" option)) options;
    in
    builtins.length parts == 2
    && builtins.match "/[A-Za-z0-9_./-]+" destination != null
    && lib.all (part: part != "" && part != "." && part != "..") (
      lib.tail (lib.splitString "/" destination)
    )
    && lib.all (option: builtins.elem option options) [
      "rw"
      "nosuid"
      "nodev"
    ]
    && builtins.elem "size" keys
    && builtins.length keys == builtins.length (lib.unique keys)
    && lib.all (
      option:
      builtins.match "(rw|nosuid|nodev|size=[1-9][0-9]*[mg]|mode=0?[0-7]{3,4}|(uid|gid)=[0-9]+)" option
      != null
    ) options;

  # 値を取る flag は、値の検査と対で持つ。検査を書かずに語彙へ入れると
  # residual から消えるだけで無検査になる。-e と --log-driver は使わない
  flagRules = {
    "-p" = _: value: builtins.match "127\\.0\\.0\\.1:[0-9]+:[0-9]+" value != null;
    "-v" = name: value: allowedMount name value;
    "-u" = _: value: builtins.match "[1-9][0-9]*:[1-9][0-9]*" value != null;
    "--user" = _: value: builtins.match "[1-9][0-9]*:[1-9][0-9]*" value != null;
    "--env-file" = name: value: builtins.elem value (readableSecrets name);
    "--network" = _: value: value == "dotfiles-backends";
    "--cgroup-parent" = _: value: value == declaredSlice;
    "--memory" = _: value: builtins.match "[0-9]+[mg]" value != null;
    "--memory-swap" = _: value: builtins.match "[1-9][0-9]*[mg]" value != null;
    "--cpus" = _: value: builtins.match "([1-9][0-9]*(\\.[0-9]+)?|0\\.[0-9]*[1-9][0-9]*)" value != null;
    "--pids-limit" = _: value: builtins.match "[1-9][0-9]*" value != null;
    "--ulimit" = _: allowedUlimit;
    "--cap-drop" = _: value: value == "ALL";
    "--cap-add" =
      _: value:
      builtins.elem value [
        "CHOWN"
        "DAC_OVERRIDE"
        "FOWNER"
        "SETGID"
        "SETUID"
      ];
    "--security-opt" =
      _: value:
      builtins.elem value [
        "no-new-privileges"
        "no-new-privileges:true"
      ];
    "--tmpfs" = _: allowedTmpfs;
    "--shm-size" = _: value: builtins.match "[0-9]+[mg]" value != null;
    "--stop-timeout" = _: value: builtins.match "[1-9][0-9]*" value != null;
    "--name" = name: value: value == name;
    "--pull" = _: value: value == "never";
    "--log-driver" = _: value: value == "journald";
  };

  valuedFlags = builtins.attrNames flagRules;

  bareTokens = [
    "docker"
    "run"
    "--rm"
    "--init"
    "--read-only"
  ];

  # flag が取る値と、それ自身を argv から除いた残り
  residual =
    argv:
    let
      indexed = lib.imap0 (index: token: { inherit index token; }) argv;
      consumed = lib.concatLists (
        map (
          entry:
          lib.optionals (lib.elem entry.token valuedFlags) [
            entry.index
            (entry.index + 1)
          ]
          ++ lib.optional (lib.any (flag: lib.hasPrefix "${flag}=" entry.token) valuedFlags) entry.index
        ) indexed
      );
    in
    map (entry: entry.token) (
      builtins.filter (
        entry: !(lib.elem entry.index consumed) && !(lib.elem entry.token bareTokens)
      ) indexed
    );

  # image reference は argv の最後。: を含むかで判定すると
  # --security-opt=seccomp:unconfined のような flag が image 扱いになる
  unexpectedTokens = lib.concatLists (
    lib.mapAttrsToList (
      name: argv:
      let
        rest = residual argv;
      in
      map (token: "${name}:${token}") (lib.take (builtins.length rest - 1) rest)
      ++ lib.optional (
        rest == [ ] || lib.last rest != hostConfig.virtualisation.oci-containers.containers.${name}.image
      ) "${name}:image-reference-not-last"
    ) containerArgv
  );

  servicePolicies = map (service: service.containerPolicy) (
    builtins.attrValues hostConfig.dotfiles.platform.containers.services
  );
  combinePolicies =
    field:
    lib.zipAttrsWith (_: values: lib.concatLists values) (
      map (policy: policy.${field}) servicePolicies
    );

  # secret と named volume の識別子は Capability が service contract と一緒に所有する。
  secretReaders = combinePolicies "secretReaders";
  volumeOwners = combinePolicies "volumeOwners";
  readableSecrets =
    name:
    map (template: hostConfig.sops.templates.${template}.path) (
      builtins.attrNames (lib.filterAttrs (_: readers: builtins.elem name readers) secretReaders)
    );
  policyContainerNames = lib.unique (
    builtins.attrNames volumeOwners ++ lib.concatLists (builtins.attrValues secretReaders)
  );
  configuredContainerNames = builtins.attrNames hostConfig.virtualisation.oci-containers.containers;

  staleSecretReaders = lib.subtractLists (builtins.attrNames hostConfig.sops.templates) (
    builtins.attrNames secretReaders
  );
  stalePolicyContainers = lib.subtractLists configuredContainerNames policyContainerNames;

  # 前方一致は path の包含にならない。/nix/store/../../etc/shadow が通る
  insideStore =
    source: lib.hasPrefix "/nix/store/" source && !(builtins.elem ".." (lib.splitString "/" source));

  allowedMount =
    name: value:
    let
      parts = lib.splitString ":" value;
      source = builtins.head parts;
      fields = builtins.length parts;
      mode = if fields == 3 then lib.last parts else "";
    in
    # named volume の所有は宣言で決める。container 名の prefix では、
    # 別 backend の volume 名が一致したときに素通りする
    (fields == 2 && builtins.elem source (volumeOwners.${name} or [ ]))
    # store の artifact は読み取り専用に限る
    || (fields == 3 && mode == "ro" && insideStore source)
    # 生成した secret は、その読み手として宣言した container だけ
    || (fields == 3 && mode == "ro" && builtins.elem source (readableSecrets name))
    # state は container 名に対応する directory だけ
    || (fields == 2 && source == "/var/lib/${name}/data");

  wrongValues = lib.concatLists (
    lib.mapAttrsToList (
      name: argv:
      lib.concatLists (
        lib.mapAttrsToList (
          flag: rule:
          map (value: "${name}:${flag}=${value}") (
            builtins.filter (value: !(rule name value)) (valuesOf argv flag)
          )
        ) flagRules
      )
    ) containerArgv
  );

  # 宣言が無ければ検査も走らない。container ごとに一度ずつ現れることを要求する
  # daemon の既定の上限付き slice に落ちるため --cgroup-parent のない backend は不可
  requiredFlags = [
    "--name"
    "--network"
    "--cgroup-parent"
    "--pull"
  ];

  missingFlags = lib.concatLists (
    lib.mapAttrsToList (
      name: argv:
      map (flag: "${name}:${flag}") (
        builtins.filter (flag: builtins.length (valuesOf argv flag) != 1) requiredFlags
      )
    ) containerArgv
  );

  # named volume の持ち主は一つ。container 名の prefix 判定だけでは、
  # 別 container の volume 名が prefix に一致したとき素通りする
  namedVolumes = lib.mapAttrs (
    _: argv:
    builtins.filter (source: !(lib.hasPrefix "/" source)) (
      map (value: builtins.head (lib.splitString ":" value)) (valuesOf argv "-v")
    )
  ) containerArgv;

  sharedVolumes = builtins.filter (
    volume:
    builtins.length (
      builtins.filter (owned: builtins.elem volume owned) (builtins.attrValues namedVolumes)
    ) > 1
  ) (lib.unique (lib.concatLists (builtins.attrValues namedVolumes)));

  # ExecStart だけを見ると、同じ unit の他の Exec* から container を起こせる。
  # postStart は ExecStartPost を生むので、行数ではなく key 集合を固定する
  expectedExecKeys = [
    "ExecStart"
    "ExecStartPre"
    "ExecStop"
    "ExecStopPost"
  ];

  execKeysOf =
    name:
    let
      service = hostConfig.systemd.services."docker-${name}".serviceConfig;
    in
    builtins.filter (key: lib.hasPrefix "Exec" key) (builtins.attrNames service);

  strayExec = lib.concatLists (
    lib.mapAttrsToList (
      name: _:
      let
        service = hostConfig.systemd.services."docker-${name}".serviceConfig;
      in
      lib.optional (
        lib.sort builtins.lessThan (execKeysOf name) != lib.sort builtins.lessThan expectedExecKeys
      ) "${name}:exec-keys"
      ++ map (key: "${name}:${key}") (
        builtins.filter (key: builtins.length (lib.toList service.${key}) != 1) (execKeysOf name)
      )
    ) containerArgv
  );

  execScripts = lib.concatLists (
    lib.mapAttrsToList (
      name: _:
      let
        service = hostConfig.systemd.services."docker-${name}".serviceConfig;
      in
      map (key: builtins.head (lib.splitString " " (builtins.toString service.${key}))) (
        builtins.filter (key: key != "ExecStart") (execKeysOf name)
      )
    ) containerArgv
  );

  publishedPorts = lib.concatLists (
    lib.mapAttrsToList (
      name: argv:
      map (value: {
        owner = name;
        inherit value;
      }) (valuesOf argv "-p")
    ) containerArgv
  );

in
{
  inherit
    staleSecretReaders
    stalePolicyContainers
    secretReaders
    volumeOwners
    containerArgv
    publishedPorts
    unexpectedTokens
    wrongValues
    missingFlags
    strayExec
    sharedVolumes
    execScripts
    ;
}
