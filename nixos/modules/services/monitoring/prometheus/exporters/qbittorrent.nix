{
  config,
  lib,
  pkgs,
}:
let
  inherit (lib) options types;

  cfg = config.services.prometheus.exporters.qbittorrent;
in
{
  port = 8090;

  extraOpts = {
    package = options.mkPackageOption pkgs "qbittorrent-exporter" { };

    url = options.mkOption {
      type = types.str;
      default = "http://localhost:8080";
      description = "The URL of the qBittorrent instance to monitor.";
    };

    username = options.mkOption {
      type = types.str;
      default = "admin";
      description = "The username for the qBittorrent instance.";
    };

    passwordFile = options.mkOption {
      type = types.path;
      description = "The path to a file containing the password for the qBittorrent instance.";
    };

    timeout = options.mkOption {
      type = types.ints.positive;
      default = 30;
      description = "Request timeout duration in seconds.";
    };

    basicAuth = options.mkOption {
      description = "Basic authentication for qBittorrent requests (e.g., if behind a reverse proxy).";
      default = { };
      type = types.submodule {
        options = {
          username = options.mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Basic auth username.";
          };

          passwordFile = options.mkOption {
            type = types.nullOr types.path;
            default = null;
            description = "Path to a file containing the basic auth password.";
          };
        };
      };
    };

    exporter = options.mkOption {
      description = "Exporter-specific settings.";
      default = { };
      type = types.submodule {
        options = {
          url = options.mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "URL displayed in startup logs.";
          };

          basicAuth = options.mkOption {
            description = "Basic authentication for the exporter's metrics endpoint.";
            default = { };
            type = types.submodule {
              options = {
                username = options.mkOption {
                  type = types.nullOr types.str;
                  default = null;
                  description = "Basic auth username for metrics endpoint.";
                };

                passwordFile = options.mkOption {
                  type = types.nullOr types.path;
                  default = null;
                  description = "Path to a file containing the basic auth password for metrics endpoint.";
                };
              };
            };
          };
        };
      };
    };

    features = options.mkOption {
      description = "Feature toggles for the exporter.";
      default = { };
      type = types.submodule {
        options = {
          tracker = options.mkOption {
            type = types.bool;
            default = true;
            description = "Get tracker info.";
          };

          highCardinality = options.mkOption {
            type = types.bool;
            default = false;
            description = "Enable high cardinality metrics for `qbittorrent_torrent_info` and `qbittorrent_tracker_info`.";
          };

          increasedCardinality = options.mkOption {
            type = types.bool;
            default = false;
            description = "Enable high cardinality metrics for additional torrent-related metrics like save path, state, and comment.";
          };

          labelWithTracker = options.mkOption {
            type = types.bool;
            default = false;
            description = "**[EXPERIMENTAL]** Add the torrent tracker to torrent metrics labels.";
          };

          labelWithHash = options.mkOption {
            type = types.bool;
            default = false;
            description = "**[EXPERIMENTAL]** Add the torrent hash to torrent metrics labels.";
          };
        };
      };
    };

    log = options.mkOption {
      description = "Logging configuration.";
      default = { };
      type = types.submodule {
        options = {
          level = options.mkOption {
            type = types.enum [
              "DEBUG"
              "INFO"
              "WARN"
              "ERROR"
            ];
            default = "INFO";
            description = "Logging verbosity level.";
          };

          dangerousShowPassword = options.mkOption {
            type = types.bool;
            default = false;
            description = "Expose password in logs (insecure, only for debugging).";
          };
        };
      };
    };

    tls = options.mkOption {
      description = "TLS configuration for qBittorrent connections.";
      default = { };
      type = types.submodule {
        options = {
          certificateAuthorityPath = options.mkOption {
            type = types.nullOr types.path;
            default = null;
            description = "Path to a CA certificate file to verify the qBittorrent TLS certificate.";
          };

          insecureSkipVerify = options.mkOption {
            type = types.bool;
            default = false;
            description = "Skip TLS certificate verification (insecure).";
          };

          minTlsVersion = options.mkOption {
            type = types.enum [
              "TLS_1_0"
              "TLS_1_1"
              "TLS_1_2"
              "TLS_1_3"
            ];
            default = "TLS_1_3";
            description = "Minimum TLS version to accept for qBittorrent connections.";
          };
        };
      };
    };

    extraEnvironmentVariables = options.mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "Additional environment variables to pass to the exporter.";
      example = lib.literalExpression ''
        {
          CUSTOM_VAR = "value";
        }
      '';
    };
  };

  serviceOpts =
    let
      # Build list of credentials to load
      credentials = [
        {
          name = "qbittorrent-password";
          path = cfg.passwordFile;
        }
      ]
      ++ lib.optional (cfg.basicAuth.passwordFile != null) {
        name = "qbittorrent-basic-auth-password";
        path = cfg.basicAuth.passwordFile;
      }
      ++ lib.optional (cfg.exporter.basicAuth.passwordFile != null) {
        name = "exporter-basic-auth-password";
        path = cfg.exporter.basicAuth.passwordFile;
      };

      # Base environment variables
      baseEnv = {
        QBITTORRENT_BASE_URL = cfg.url;
        QBITTORRENT_USERNAME = cfg.username;
        QBITTORRENT_TIMEOUT = toString cfg.timeout;
        EXPORTER_PORT = toString cfg.port;
        LOG_LEVEL = cfg.log.level;
        DANGEROUS_SHOW_PASSWORD = lib.boolToString cfg.log.dangerousShowPassword;
        ENABLE_TRACKER = lib.boolToString cfg.features.tracker;
        ENABLE_HIGH_CARDINALITY = lib.boolToString cfg.features.highCardinality;
        ENABLE_INCREASED_CARDINALITY = lib.boolToString cfg.features.increasedCardinality;
        ENABLE_LABEL_WITH_TRACKER = lib.boolToString cfg.features.labelWithTracker;
        ENABLE_LABEL_WITH_HASH = lib.boolToString cfg.features.labelWithHash;
        INSECURE_SKIP_VERIFY = lib.boolToString cfg.tls.insecureSkipVerify;
        MIN_TLS_VERSION = cfg.tls.minTlsVersion;
      }
      // lib.optionalAttrs (cfg.basicAuth.username != null) {
        QBITTORRENT_BASIC_AUTH_USERNAME = cfg.basicAuth.username;
      }
      // lib.optionalAttrs (cfg.exporter.url != null) {
        EXPORTER_URL = cfg.exporter.url;
      }
      // lib.optionalAttrs (cfg.exporter.basicAuth.username != null) {
        EXPORTER_BASIC_AUTH_USERNAME = cfg.exporter.basicAuth.username;
      }
      // lib.optionalAttrs (cfg.tls.certificateAuthorityPath != null) {
        CERTIFICATE_AUTHORITY_PATH = toString cfg.tls.certificateAuthorityPath;
      }
      // cfg.extraEnvironmentVariables;
    in
    {
      serviceConfig = {
        LoadCredential = builtins.map ({ name, path }: "${name}:${path}") credentials;
      };

      environment = baseEnv;

      script = ''
        export QBITTORRENT_PASSWORD_FILE="$CREDENTIALS_DIRECTORY/qbittorrent-password"
        ${lib.optionalString (cfg.basicAuth.passwordFile != null) ''
          export QBITTORRENT_BASIC_AUTH_PASSWORD="$(< $CREDENTIALS_DIRECTORY/qbittorrent-basic-auth-password)"
        ''}
        ${lib.optionalString (cfg.exporter.basicAuth.passwordFile != null) ''
          export EXPORTER_BASIC_AUTH_PASSWORD="$(< $CREDENTIALS_DIRECTORY/exporter-basic-auth-password)"
        ''}
        exec ${lib.getExe cfg.package}
      '';
    }
    // lib.optionalAttrs config.services.qbittorrent.enable {
      after = [ "qbittorrent.service" ];
      requires = [ "qbittorrent.service" ];
    };
}
