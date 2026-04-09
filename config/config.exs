import Config

config :tesla, disable_deprecated_builder_warning: true

if config_env() == :test do
  import_config "test.exs"
end
