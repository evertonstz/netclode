# Agent overlay module - copies agent code into the image
{ config, pkgs, lib, ... }:

let
  # Agent source code - relative path when built in sandbox build dir
  # During ansible deploy, agent is copied to ./apps/agent/
  agentSrc = ./apps/agent;
in {
  # Copy agent source to /opt/netclode-agent
  system.activationScripts.copyAgent = lib.stringAfter [ "users" ] ''
    mkdir -p /opt/netclode-agent
    cp -r ${agentSrc}/* /opt/netclode-agent/
    chown -R agent:agent /opt/netclode-agent
  '';

  # Install agent dependencies on first boot
  systemd.services.netclode-agent-setup = {
    description = "Install Netclode Agent Dependencies";
    wantedBy = [ "netclode-agent.service" ];
    before = [ "netclode-agent.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = "agent";
      Group = "agent";
      WorkingDirectory = "/opt/netclode-agent";
      ExecStart = "/run/current-system/sw/bin/bun install";
      RemainAfterExit = true;
    };
  };
}
