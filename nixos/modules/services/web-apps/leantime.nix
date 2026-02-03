{
  lib,
  config,
  pkgs,
  ...
}:

let
  cfg = config.services.leantime;
  name = "leantime";
  leantimePhp = pkgs.php.withExtensions (
    { all, ... }:
    with all;
    [
      bcmath
      ctype
      curl
      dom
      exif
      fileinfo
      filter
      gd
      ldap
      mbstring
      mysqli
      opcache
      openssl
      pcntl
      pdo
      pdo_mysql
      session
      tokenizer
      zip
      simplexml
    ]
  );

  inherit (lib)
    types
    mkOption
    mkEnableOption
    mkPackageOption
    mkIf
    maintainers
    attrsets
    optionalAttrs
    ;
in
{
  meta.maintainers = with maintainers; [ jordycoding ];
  options = {
    services.leantime = {
      enable = mkEnableOption "leantime";
      user = mkOption {
        type = types.str;
        default = name;
        description = ''
          The user account to run leantime under
        '';
      };
      group = mkOption {
        type = types.str;
        default = name;
        description = ''
          Group for the leantime user
        '';
      };
      pool = mkOption {
        type = types.str;
        default = name;
        description = ''
          The name for the phpfpm pool used to run leantime.
          If set to the default value the phpfpm pool is created automatically.
          Otherwise it must be created manually.
        '';
      };
      dataDir = mkOption {
        type = types.path;
        default = "/var/lib/leantime";
        description = ''
          Path where leantime stores data.
          By default the directory and its subdirectories are created automatically.
          When changing it from the default you are responsible for creating it.
          Note: The storage path should contain the following folder structure:
            /storage
            /bootstrap
              /bootstrap/cache
        '';
      };
      database = {
        createLocally = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Whether a MySQL database should be created locally.
          '';
        };
        host = mkOption {
          type = types.str;
          default = "localhost";
          description = ''
            The host for the MySQL database.
          '';
        };
        name = mkOption {
          type = types.str;
          default = "leantime";
          description = ''
            The name of the MySQL database.
          '';
        };
        port = mkOption {
          type = types.port;
          default = 3306;
          description = ''
            The port used by MySQL.
          '';
        };
      };
      settings = mkOption {
        type = types.submodule {
          freeformType = types.attrsOf (
            types.oneOf [
              types.str
              types.int
              types.bool
            ]
          );
          options = {
            LEAN_OIDC_ENABLE = mkOption {
              type = types.bool;
              default = false;
              description = ''
                Enable OIDC support
              '';
            };
            LEAN_OIDC_PROVIDER_URL = mkOption {
              type = types.str;
              default = "";
              description = ''
                Url of OIDC server
              '';
            };
            LEAN_OIDC_CLIENT_ID = mkOption {
              type = types.str;
              description = ''
                OIDC Client id
              '';
              default = "";
            };
            LEAN_OIDC_CREATE_USER = mkOption {
              type = types.bool;
              description = ''
                Automatically create user if it doesn't exist.
                If user doesn't exist and this is set to false, logging in will fail
              '';
              default = false;
            };
            LEAN_OIDC_DEFAULT_ROLE = mkOption {
              type = types.int;
              description = ''
                Default role for users created by OIDC. Default is editor.
              '';
              default = 20;
            };
          };
        };
      };
      environmentFile = mkOption {
        type = types.nullOr types.path;
        description = ''
          Environmentfile to use for phpfpm. Can be used for secrets;
        '';
        default = null;
      };
      caddyVirtualHost = mkOption {
        type = types.nullOr types.str;
        description = ''
          Virtualhost to set up for caddy.
          When set to null caddy will not be set up.
        '';
      };
      package = mkPackageOption pkgs "leantime" { };
    };
  };
  config = mkIf cfg.enable {
    services.phpfpm.pools.${name} = mkIf (cfg.pool == name) {
      user = cfg.user;
      group = cfg.group;
      phpPackage = leantimePhp;
      settings = {
        "listen.owner" = "caddy";
        "listen.group" = "caddy";
        "listen.mode" = "0600";
        "pm" = "dynamic";
        "pm.max_children" = 32;
        "pm.max_requests" = 500;
        "pm.min_spare_servers" = 2;
        "pm.max_spare_servers" = 5;
        "php_admin_value[error_log]" = "stderr";
        "php_admin_flag[log_errors]" = true;
        "php_flag[display_errors]" = true;
        "catch_workers_output" = true;
      }
      // optionalAttrs (cfg.environmentFile != null) {
        "clear_env" = false;
      };
      phpEnv = {
        # LEAN_SESSION_PASSWORD = $LEAN_SESSION_PASSWORD
        LEAN_DB_SOCKET = "/run/mysqld/mysqld.sock";
        LEAN_DB_DATABASE = "leantime";
        LEAN_DB_USER = "leantime";
        LEAN_DB_PORT = "3306";
        LOG_LEVEL = "info";
        APP_DATA_PATH = cfg.dataDir;
      }
      // attrsets.mapAttrs (
        name: value: if builtins.isBool value then (if value then "true" else "false") else toString value
      ) cfg.settings;
      phpOptions = ''
        variables_order = "EGPCS"
      '';
    };

    systemd.services."phpfpm-${cfg.pool}".serviceConfig.EnvironmentFile = mkIf (
      cfg.pool == name && cfg.environmentFile != null
    ) cfg.environmentFile;

    systemd.tmpfiles.rules = mkIf (cfg.dataDir == "/var/lib/leantime") [
      "d /var/lib/leantime 0770 ${cfg.user} ${cfg.group} - -"
      "d /var/lib/leantime/storage 0770 ${cfg.user} ${cfg.group} - -"
      "d /var/lib/leantime/bootstrap 0770 ${cfg.user} ${cfg.group} - -"
      "d /var/lib/leantime/bootstrap/cache 0770 ${cfg.user} ${cfg.group} - -"
      "d /var/lib/leantime/userfiles 0770 ${cfg.user} ${cfg.group} - -"
      "d /var/lib/leantime/publicfiles 0770 ${cfg.user} ${cfg.group} - -"
    ];

    services.mysql = mkIf (cfg.database.createLocally) {
      enable = true;
      package = pkgs.mariadb;
      ensureUsers = [
        {
          name = "leantime";
          ensurePermissions = {
            "leantime.*" = "ALL PRIVILEGES";
          };
        }
      ];
      ensureDatabases = [ "leantime" ];
    };

    services.caddy = mkIf (cfg.caddyVirtualHost != null) {
      enable = true;
      virtualHosts.${cfg.caddyVirtualHost}.extraConfig = ''
        header {
           X-Frame-Options "DENY"
           X-XSS-Protection "1; mode=block; report=/xss-report"
           X-Content-Type-Options "nosniff"
           Referrer-Policy "no-referrer-when-downgrade"
           Content-Security-Policy "default-src 'self' http: https: data: blob: 'unsafe-inline'"
           Strict-Transport-Security "max-age=31536000; includeSubDomains"
        }
        root * ${cfg.package}/share/php/leantime/public
        try_files {path} {path}/ /index.php?{query}
        php_fastcgi unix//run/phpfpm/${cfg.pool}.sock
        encode gzip
        file_server
      '';
    };

    users.users.leantime = mkIf (cfg.user == name) {
      description = "leantime service user";
      isSystemUser = true;
      inherit (cfg) group;
    };
    users.groups.leantime = mkIf (cfg.group == name) { };
  };
}
