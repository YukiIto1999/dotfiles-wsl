{
  pkgs,
  lib,
  hostConfig,
  ...
}:

let
  username = hostConfig.dotfiles.host.username;
  homeDir = hostConfig.dotfiles.host.homeDir;
  homeConfig = hostConfig.home-manager.users.${username};
  cleanup = hostConfig.dotfiles.commands.cleanup;
  currentHomeFiles = "${homeConfig.home.activationPackage}/home-files";
  currentHomeFilesFixture = pkgs.runCommandLocal "home-manager-files" { } ''
    mkdir -p "$out/dotfiles-wsl/.codex"
    touch "$out/.bashrc"
    touch "$out/deployed-target"
    touch "$out/dotfiles-wsl/.codex/config.toml"
  '';
  currentGeneration = pkgs.runCommandLocal "home-manager-generation" { } ''
    mkdir -p "$out"
    ln -s ${currentHomeFilesFixture} "$out/home-files"
  '';
  historicalGeneration = pkgs.runCommandLocal "home-manager-generation" { } ''
    mkdir -p "$out/home-files/.local/share/dotfiles-agent"
    touch "$out/home-files/.local/share/dotfiles-agent/old"
  '';
  movedHomeGeneration = pkgs.runCommandLocal "home-manager-generation" { } ''
    mkdir -p "$out/home-files/.local/share/dotfiles-agent"
    touch "$out/home-files/.local/share/dotfiles-agent/moved-home"
  '';
  commandGeneration = pkgs.runCommandLocal "home-manager-generation" { } ''
    mkdir -p "$out/home-files/.local/share/dotfiles-agent"
    touch "$out/home-files/.local/share/dotfiles-agent/command-owned"
  '';
in
{
  cleanup-home-backups =
    assert cleanup.cleanupHomeDir == homeDir;
    assert cleanup.cleanupCurrentHomeFiles == currentHomeFiles;
    assert
      cleanup.cleanupCurrentUsesBackupExtension == (
        hostConfig.home-manager.backupCommand == null && hostConfig.home-manager.backupFileExtension != null
      );
    pkgs.runCommandLocal "check-cleanup-home-backups"
      {
        nativeBuildInputs = [
          cleanup
          pkgs.gnused
        ];
      }
      ''
        set -euo pipefail

        fixture=$PWD/fixture
        configured_home="$fixture/configured-home"
        runtime_home="$fixture/runtime-home"
        mkdir -p "$configured_home/dotfiles-wsl/.codex"
        mkdir -p "$configured_home/.cache/unrelated"
        mkdir -p "$configured_home/.config/unrelated"
        mkdir -p "$configured_home/.local/share/dotfiles-agent"
        mkdir -p "$configured_home/.local/unrelated"
        mkdir -p "$configured_home/.vscode-server"
        mkdir -p "$runtime_home"
        mkdir -p "$runtime_home/.vscode-server"
        mkdir -p "$fixture/etc"
        mkdir -p "$fixture/profiles/system-profile/etc/systemd/system"
        mkdir -p "$fixture/profiles/same-generation-profile/etc/systemd/system"
        mkdir -p "$fixture/profiles/moved-home-profile/etc/systemd/system"
        mkdir -p "$fixture/profiles/command-profile/etc/systemd/system"
        touch "$configured_home/.bashrc.hm-back"
        touch "$configured_home/dotfiles-wsl/.codex/config.toml.hm-back"
        touch "$configured_home/dotfiles-wsl/.codex/keep"
        touch "$configured_home/dotfiles-wsl/unrelated.hm-back"
        touch "$configured_home/.cache/unrelated/outside.hm-back"
        touch "$configured_home/.config/unrelated/outside.hm-back"
        touch "$configured_home/.local/share/dotfiles-agent/old.hm-back"
        touch "$configured_home/.local/share/dotfiles-agent/old.legacy-back"
        touch "$configured_home/attribute-name.hm-back"
        touch "$configured_home/deployed-target.hm-back"
        touch "$configured_home/deployed-target.previous-back"
        touch "$configured_home/.local/share/dotfiles-agent/moved-home.moved-back"
        touch "$configured_home/.local/share/dotfiles-agent/command-owned.command-back"
        touch "$configured_home/.local/unrelated/outside.hm-back"
        touch "$runtime_home/.bashrc.hm-back"
        touch "$fixture/etc/nixos.bak.fixture"
        cat > "$fixture/profiles/system-profile/etc/systemd/system/home-manager-${username}.service" <<UNIT
        [Service]
        RequiresMountsFor=$configured_home
        Environment="HOME_MANAGER_BACKUP_EXT=legacy-back"
        ExecStart=/nix/store/hm-setup-env ${historicalGeneration}
        UNIT
        ln -s "$fixture/profiles/system-profile" "$fixture/profiles/system-1-link"
        cat > "$fixture/profiles/same-generation-profile/etc/systemd/system/home-manager-${username}.service" <<UNIT
        [Service]
        RequiresMountsFor=$configured_home
        Environment="HOME_MANAGER_BACKUP_EXT=previous-back"
        ExecStart=/nix/store/hm-setup-env ${currentGeneration}
        UNIT
        ln -s "$fixture/profiles/same-generation-profile" "$fixture/profiles/system-2-link"
        cat > "$fixture/profiles/moved-home-profile/etc/systemd/system/home-manager-${username}.service" <<UNIT
        [Service]
        RequiresMountsFor=$fixture/previous-home
        Environment="HOME_MANAGER_BACKUP_EXT=moved-back"
        ExecStart=/nix/store/hm-setup-env ${movedHomeGeneration}
        UNIT
        ln -s "$fixture/profiles/moved-home-profile" "$fixture/profiles/system-3-link"
        cat > "$fixture/profiles/command-profile/etc/systemd/system/home-manager-${username}.service" <<UNIT
        [Service]
        RequiresMountsFor=$configured_home
        Environment="HOME_MANAGER_BACKUP_COMMAND=/nix/store/backup-command"
        Environment="HOME_MANAGER_BACKUP_EXT=command-back"
        ExecStart=/nix/store/hm-setup-env ${commandGeneration}
        UNIT
        ln -s "$fixture/profiles/command-profile" "$fixture/profiles/system-4-link"

        sed \
          -e "s|${lib.escapeRegex homeDir}|$configured_home|g" \
          -e "s|${lib.escapeRegex currentHomeFiles}|${currentGeneration}/home-files|g" \
          -e "s|^system_root=/etc$|system_root=$fixture/etc|" \
          -e "s|/nix/var/nix/profiles/system|$fixture/profiles/system|g" \
          "$(type -P dotfiles-cleanup)" > "$fixture/dotfiles-cleanup"
        chmod +x "$fixture/dotfiles-cleanup"

        command_home="$fixture/command-home"
        mkdir -p "$command_home"
        touch "$command_home/deployed-target.hm-back"
        sed \
          -e "s|^configured_home=.*$|configured_home=$command_home|" \
          -e "s|^current_uses_backup_extension=1$|current_uses_backup_extension=0|" \
          -e "s|^system_profile=.*$|system_profile=$fixture/no-profiles/system|" \
          "$fixture/dotfiles-cleanup" > "$fixture/command-mode-cleanup"
        chmod +x "$fixture/command-mode-cleanup"
        HOME="$runtime_home" "$fixture/command-mode-cleanup" --delete > command-mode-delete
        test -e "$command_home/deployed-target.hm-back"

        if HOME="$runtime_home" "$fixture/dotfiles-cleanup" --system --vscode-server > combined 2>&1; then
          echo "system and home cleanup were accepted in one operation" >&2
          exit 1
        fi
        test -e "$configured_home/.vscode-server"
        test -e "$fixture/etc/nixos.bak.fixture"

        HOME="$runtime_home" "$fixture/dotfiles-cleanup" --system > system-preview
        grep -Fxq "would remove $fixture/etc/nixos.bak.fixture" system-preview
        test "$(wc -l < system-preview)" -eq 1
        test -e "$fixture/etc/nixos.bak.fixture"

        if HOME="$runtime_home" "$fixture/dotfiles-cleanup" --delete --system > system-delete 2>&1; then
          echo "system deletion did not require root" >&2
          exit 1
        fi
        test -e "$fixture/etc/nixos.bak.fixture"

        HOME="$runtime_home" "$fixture/dotfiles-cleanup" > preview
        test "$(grep -Fxc "would remove $configured_home/.bashrc.hm-back" preview)" -eq 1
        test "$(grep -Fxc "would remove $configured_home/dotfiles-wsl/.codex/config.toml.hm-back" preview)" -eq 1
        test -e "$configured_home/.bashrc.hm-back"
        test -e "$configured_home/dotfiles-wsl/.codex/config.toml.hm-back"

        HOME="$runtime_home" "$fixture/dotfiles-cleanup" --delete > deleted
        grep -Fxq "removed $configured_home/.bashrc.hm-back" deleted
        grep -Fxq "removed $configured_home/dotfiles-wsl/.codex/config.toml.hm-back" deleted
        test ! -e "$configured_home/.bashrc.hm-back"
        test ! -e "$configured_home/dotfiles-wsl/.codex/config.toml.hm-back"
        test ! -e "$configured_home/.local/share/dotfiles-agent/old.legacy-back"
        test ! -e "$configured_home/deployed-target.hm-back"
        test ! -e "$configured_home/deployed-target.previous-back"
        test -e "$configured_home/.local/share/dotfiles-agent/old.hm-back"
        test -e "$configured_home/attribute-name.hm-back"
        test -e "$configured_home/.local/share/dotfiles-agent/moved-home.moved-back"
        test -e "$configured_home/.local/share/dotfiles-agent/command-owned.command-back"
        test -e "$configured_home/.cache/unrelated/outside.hm-back"
        test -e "$configured_home/.config/unrelated/outside.hm-back"
        test -e "$configured_home/.local/unrelated/outside.hm-back"
        test -e "$configured_home/dotfiles-wsl/.codex/keep"
        test -e "$configured_home/dotfiles-wsl/unrelated.hm-back"
        test -e "$runtime_home/.bashrc.hm-back"

        HOME="$runtime_home" "$fixture/dotfiles-cleanup" --delete --vscode-server > vscode-delete
        grep -Fxq "removed $configured_home/.vscode-server" vscode-delete
        test ! -e "$configured_home/.vscode-server"
        test -e "$runtime_home/.vscode-server"
        touch $out
      '';
}
