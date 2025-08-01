{
  config,
  lib,
  pkgs,
  buildEnv,
  ...
}:

let
  cfg = config.services.peering-manager;

  pythonFmt = pkgs.formats.pythonVars { };
  settingsFile = pythonFmt.generate "peering-manager-settings.py" cfg.settings;
  extraConfigFile = pkgs.writeTextFile {
    name = "peering-manager-extraConfig.py";
    text = cfg.extraConfig;
  };
  configFile = pkgs.concatText "configuration.py" [
    settingsFile
    extraConfigFile
  ];
  finalConfigFile =
    if (cfg.environmentFile != null) then "/var/lib/peering-manager/configuration.py" else configFile;

  pkg =
    (pkgs.peering-manager.overrideAttrs (old: {
      postInstall = ''
        ln -s ${finalConfigFile} $out/opt/peering-manager/peering_manager/configuration.py
      ''
      + lib.optionalString cfg.enableLdap ''
        ln -s ${cfg.ldapConfigPath} $out/opt/peering-manager/peering_manager/ldap_config.py
      '';
    })).override
      {
        inherit (cfg) plugins;
      };
  peeringManagerManageScript = pkgs.writeScriptBin "peering-manager-manage" ''
    #!${pkgs.stdenv.shell}
    export PYTHONPATH=${pkg.pythonPath}
    sudo -u peering-manager ${pkg}/bin/peering-manager "$@"
  '';

in
{
  options.services.peering-manager = with lib; {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Enable Peering Manager.

        This module requires a reverse proxy that serves `/static` separately.
        See this [example](https://github.com/peering-manager/contrib/blob/main/nginx.conf) on how to configure this.
      '';
    };

    environmentFile = mkOption {
      type = with types; nullOr path;
      default = null;
      example = "/run/secrets/peering-manager.env";
      description = ''
        Environment file as defined in {manpage}`systemd.exec(5)`.

        Secrets may be passed to the service without adding them to the world-readable
        Nix store, by specifying placeholder variables as the option value in Nix and
        setting these variables accordingly in the environment file.

        ```
          # snippet of peering-manager-related config
          services.peering-manager.settings.SOCIAL_AUTH_OIDC_SECRET = "$PM_OIDC_SECRET";
        ```

        ```
          # content of the environment file
          PM_OIDC_SECRET=topsecret
        ```

        Note that this file needs to be available on the host on which
        `peering-manager` is running.
      '';
    };

    enableScheduledTasks = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Set up [scheduled tasks](https://peering-manager.readthedocs.io/en/stable/setup/8-scheduled-tasks/)
      '';
    };

    listenAddress = mkOption {
      type = types.str;
      default = "[::1]";
      description = ''
        Address the server will listen on.
      '';
    };

    port = mkOption {
      type = types.port;
      default = 8001;
      description = ''
        Port the server will listen on.
      '';
    };

    plugins = mkOption {
      type = types.functionTo (types.listOf types.package);
      default = _: [ ];
      defaultText = literalExpression ''
        python3Packages: with python3Packages; [];
      '';
      description = ''
        List of plugin packages to install.
      '';
    };

    secretKeyFile = mkOption {
      type = types.path;
      description = ''
        Path to a file containing the secret key.
      '';
    };

    peeringdbApiKeyFile = mkOption {
      type = with types; nullOr path;
      default = null;
      description = ''
        Path to a file containing the PeeringDB API key.
      '';
    };

    settings = lib.mkOption {
      description = ''
        Configuration options to set in `configuration.py`.
        See the [documentation](https://peering-manager.readthedocs.io/en/stable/configuration/optional-settings/) for more possible options.
      '';

      default = { };

      type = lib.types.submodule {
        freeformType = pythonFmt.type;

        options = {
          ALLOWED_HOSTS = lib.mkOption {
            type = with lib.types; listOf str;
            default = [ "*" ];
            description = ''
              A list of valid fully-qualified domain names (FQDNs) and/or IP
              addresses that can be used to reach the peering manager service.
            '';
          };
        };
      };
    };

    extraConfig = mkOption {
      type = types.lines;
      default = "";
      description = ''
        Additional lines of configuration appended to the `configuration.py`.
        See the [documentation](https://peering-manager.readthedocs.io/en/stable/configuration/optional-settings/) for more possible options.
      '';
    };

    enableLdap = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Enable LDAP-Authentication for Peering Manager.

        This requires a configuration file being pass through `ldapConfigPath`.
      '';
    };

    ldapConfigPath = mkOption {
      type = types.path;
      description = ''
        Path to the Configuration-File for LDAP-Authentication, will be loaded as `ldap_config.py`.
        See the [documentation](https://peering-manager.readthedocs.io/en/stable/setup/6-ldap/#configuration) for possible options.
      '';
    };
  };

  imports = [
    (lib.mkRemovedOptionModule [ "services" "peering-manager" "enableOidc" ] ''
      The enableOidc option has been removed, since peering-manager has OIDC support builtin since version >= 1.9.0.

      Make sure to update your OIDC configuration according to the documentation:
      https://peering-manager.readthedocs.io/en/v1.9.3/administration/authentication/oidc/
    '')
    (lib.mkRemovedOptionModule [ "services" "peering-manager" "oidcConfigPath" ] ''
      The oidcConfigPath option has been removed, since peering-manager has OIDC support builtin since version >= 1.9.0.

      The new config settings for OIDC are explained in the documentation:
      https://peering-manager.readthedocs.io/en/v1.9.3/administration/authentication/oidc/
    '')
  ];

  config = lib.mkIf cfg.enable {
    services.peering-manager = {
      settings = {
        DATABASE = {
          NAME = "peering-manager";
          USER = "peering-manager";
          HOST = "/run/postgresql";
        };

        # Redis database settings. Redis is used for caching and for queuing background tasks such as webhook events. A separate
        # configuration exists for each. Full connection details are required in both sections, and it is strongly recommended
        # to use two separate database IDs.
        REDIS = {
          tasks = {
            UNIX_SOCKET_PATH = config.services.redis.servers.peering-manager.unixSocket;
            DATABASE = 0;
          };
          caching = {
            UNIX_SOCKET_PATH = config.services.redis.servers.peering-manager.unixSocket;
            DATABASE = 1;
          };
        };
      };

      extraConfig = ''
        with open("${cfg.secretKeyFile}", "r") as file:
          SECRET_KEY = file.readline()
      ''
      + lib.optionalString (cfg.peeringdbApiKeyFile != null) ''
        with open("${cfg.peeringdbApiKeyFile}", "r") as file:
          PEERINGDB_API_KEY = file.readline()
      '';

      plugins = (ps: (lib.optionals cfg.enableLdap [ ps.django-auth-ldap ]));
    };

    system.build.peeringManagerPkg = pkg;

    services.redis.servers.peering-manager.enable = true;

    services.postgresql = {
      enable = true;
      ensureDatabases = [ "peering-manager" ];
      ensureUsers = [
        {
          name = "peering-manager";
          ensureDBOwnership = true;
        }
      ];
    };

    environment.systemPackages = [ peeringManagerManageScript ];

    systemd.targets.peering-manager = {
      description = "Target for all Peering Manager services";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
        "redis-peering-manager.service"
      ];
    };

    systemd.services =
      let
        defaults = {
          environment = {
            PYTHONPATH = pkg.pythonPath;
          };
          serviceConfig = {
            WorkingDirectory = "/var/lib/peering-manager";
            User = "peering-manager";
            Group = "peering-manager";
            StateDirectory = "peering-manager";
            StateDirectoryMode = "0750";
            Restart = "on-failure";
          };
        };
      in
      {
        peering-manager-config = lib.mkIf (cfg.environmentFile != null) (
          lib.recursiveUpdate defaults {
            description = "Peering Manager config file setup";
            wantedBy = [ "peering-manager.target" ];
            serviceConfig = {
              Type = "oneshot";
              EnvironmentFile = [ cfg.environmentFile ];
              ExecStart = "${lib.getExe pkgs.envsubst} -i ${configFile} -o ${finalConfigFile}";
            };
          }
        );

        peering-manager-migration = lib.recursiveUpdate defaults {
          description = "Peering Manager migrations";
          wantedBy = [ "peering-manager.target" ];
          after = lib.mkIf (cfg.environmentFile != null) [ "peering-manager-config.service" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${pkg}/bin/peering-manager migrate";
          };
        };

        peering-manager = lib.recursiveUpdate defaults {
          description = "Peering Manager WSGI Service";
          wantedBy = [ "peering-manager.target" ];
          after = [
            "peering-manager-migration.service"
          ]
          ++ lib.optionals (cfg.environmentFile != null) [ "peering-manager-config.service" ];

          preStart = ''
            ${pkg}/bin/peering-manager remove_stale_contenttypes --no-input
          '';

          serviceConfig = {
            ExecStart = ''
              ${pkg.python.pkgs.gunicorn}/bin/gunicorn peering_manager.wsgi \
                --bind ${cfg.listenAddress}:${toString cfg.port} \
                --pythonpath ${pkg}/opt/peering-manager
            '';
          };
        };

        peering-manager-rq = lib.recursiveUpdate defaults {
          description = "Peering Manager Request Queue Worker";
          wantedBy = [ "peering-manager.target" ];
          after = [ "peering-manager.service" ];
          serviceConfig.ExecStart = "${pkg}/bin/peering-manager rqworker high default low";
        };

        peering-manager-housekeeping = lib.recursiveUpdate defaults {
          description = "Peering Manager housekeeping job";
          after = [ "peering-manager.service" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${pkg}/bin/peering-manager housekeeping";
          };
        };

        peering-manager-peeringdb-sync = lib.recursiveUpdate defaults {
          description = "PeeringDB sync";
          after = [ "peering-manager.service" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${pkg}/bin/peering-manager peeringdb_sync";
          };
        };

        peering-manager-prefix-fetch = lib.recursiveUpdate defaults {
          description = "Fetch IRR AS-SET prefixes";
          after = [ "peering-manager.service" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${pkg}/bin/peering-manager grab_prefixes";
          };
        };

        peering-manager-configuration-deployment = lib.recursiveUpdate defaults {
          description = "Push configuration to routers";
          after = [ "peering-manager.service" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${pkg}/bin/peering-manager configure_routers";
          };
        };

        peering-manager-session-poll = lib.recursiveUpdate defaults {
          description = "Poll peering sessions from routers";
          after = [ "peering-manager.service" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${pkg}/bin/peering-manager poll_bgp_sessions";
          };
        };
      };

    systemd.timers = {
      peering-manager-housekeeping = {
        description = "Run Peering Manager housekeeping job";
        wantedBy = [ "timers.target" ];
        timerConfig.OnCalendar = "daily";
      };

      peering-manager-peeringdb-sync = {
        enable = lib.mkDefault cfg.enableScheduledTasks;
        description = "Sync PeeringDB at 2:30";
        wantedBy = [ "timers.target" ];
        timerConfig.OnCalendar = "02:30:00";
      };

      peering-manager-prefix-fetch = {
        enable = lib.mkDefault cfg.enableScheduledTasks;
        description = "Fetch IRR AS-SET prefixes at 4:30";
        wantedBy = [ "timers.target" ];
        timerConfig.OnCalendar = "04:30:00";
      };

      peering-manager-configuration-deployment = {
        enable = lib.mkDefault cfg.enableScheduledTasks;
        description = "Push router configuration every hour 5 minutes before full hour";
        wantedBy = [ "timers.target" ];
        timerConfig.OnCalendar = "*:55:00";
      };

      peering-manager-session-poll = {
        enable = lib.mkDefault cfg.enableScheduledTasks;
        description = "Poll peering sessions from routers every hour";
        wantedBy = [ "timers.target" ];
        timerConfig.OnCalendar = "*:00:00";
      };
    };

    users.users.peering-manager = {
      home = "/var/lib/peering-manager";
      isSystemUser = true;
      group = "peering-manager";
    };
    users.groups.peering-manager = { };
    users.groups."${config.services.redis.servers.peering-manager.user}".members = [
      "peering-manager"
    ];
  };

  meta.maintainers = with lib.maintainers; [ yuka ];
}
