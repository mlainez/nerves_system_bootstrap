defmodule Mix.Tasks.Nerves.System.Bootstrap do
  use Mix.Task
  require Logger

  alias NervesBootstrap.BuildrootManager
  alias NervesBootstrap.PlatformDetector
  alias NervesBootstrap.DefconfigProcessor
  alias NervesBootstrap.FileGenerator

  @shortdoc "Generate a complete Nerves system from a Buildroot defconfig"

  @moduledoc """
  Generates a complete Nerves system from a Buildroot defconfig with proper
  fwup configuration, toolchain setup, and Nerves-specific enhancements.

  Usage:
      mix nerves.system.bootstrap <board> [options]

  ## Options

    * `--buildroot PATH`          - Path to a local Buildroot source tree
    * `--buildroot-url URL`       - Git URL of a Buildroot repository (or fork)
    * `--buildroot-branch BRANCH` - Branch/tag to check out (used with --buildroot-url)
    * `--buildroot-external PATH` - Path to a Buildroot external tree

  ## Examples

      mix nerves.system.bootstrap beaglebone
      mix nerves.system.bootstrap pine64 --buildroot ~/src/buildroot
      mix nerves.system.bootstrap pine64 --buildroot-url https://github.com/user/buildroot-fork.git
      mix nerves.system.bootstrap pine64 --buildroot-url https://github.com/user/buildroot-fork.git --buildroot-branch 2025.05.3
      mix nerves.system.bootstrap pine64 --buildroot-external ~/src/my_external_tree

  ## Generated files

    * `nerves_defconfig` - Complete Nerves Buildroot configuration
    * `linux-<version>.defconfig` - Kernel configuration
    * `fwup.conf` - Firmware creation and A/B update configuration
    * `fwup-ops.conf` - Runtime operations (revert, factory-reset, etc.)
    * `fwup_include/` - Common fwup configuration includes
    * `mix.exs` - Project file with auto-detected toolchain
    * `post-build.sh`, `post-createfs.sh` - Buildroot build hook scripts
    * `rootfs_overlay/` - Root filesystem overlay with Nerves defaults

  The system automatically detects the target architecture (aarch64, armv7,
  x86_64, riscv64) and configures the appropriate Nerves toolchain and fwup
  settings.
  """

  @impl true
  def run(argv) do
    {opts, positional, _invalid} =
      OptionParser.parse(argv,
        switches: [
          buildroot: :string,
          buildroot_url: :string,
          buildroot_branch: :string,
          buildroot_external: :string
        ]
      )

    case positional do
      [board_input] ->
        board = String.replace_suffix(board_input, "_defconfig", "")
        bootstrap_system(board, opts)

      _ ->
        Mix.raise("""
        Usage: mix nerves.system.bootstrap <board> [options]

        Options:
          --buildroot PATH            Path to a local Buildroot source tree
          --buildroot-url URL         Git URL of a Buildroot repository (or fork)
          --buildroot-branch BRANCH   Branch/tag to check out
          --buildroot-external PATH   Path to a Buildroot external tree
        """)
    end
  end

  defp bootstrap_system(board, opts) do
    external_path = opts[:buildroot_external]

    {buildroot_path, defconfig_path} = resolve_buildroot_paths(board, external_path, opts)

    # Validate that the defconfig exists
    validation_path = external_path || buildroot_path
    BuildrootManager.validate_board_defconfig(validation_path, board)

    app = "nerves_system_#{board}"
    File.mkdir_p!(app)
    target_defconfig = Path.join(app, "nerves_defconfig")

    # Copy and process the defconfig for Nerves
    File.cp!(defconfig_path, target_defconfig)
    DefconfigProcessor.clean_defconfig_for_nerves(target_defconfig)
    DefconfigProcessor.append_nerves_config(target_defconfig)
    DefconfigProcessor.append_external_reference(target_defconfig, buildroot_path)
    DefconfigProcessor.append_nerves_system_name(target_defconfig, app)

    # Copy kernel defconfig
    DefconfigProcessor.copy_kernel_defconfig(defconfig_path, buildroot_path, app)

    # Copy U-Boot configuration fragments
    DefconfigProcessor.copy_uboot_fragments(target_defconfig, buildroot_path, app)

    # Resolve toolchain and generate all files
    toolchain_dep = PlatformDetector.infer_toolchain(defconfig_path)
    module_name = Macro.camelize(app)

    FileGenerator.generate_files(
      app,
      board,
      module_name,
      toolchain_dep,
      buildroot_path,
      defconfig_path
    )

    display_success_message(app, board)
  end

  defp resolve_buildroot_paths(board, external_path, opts) do
    if external_path do
      unless File.dir?(external_path) do
        Mix.raise("The --buildroot-external path does not exist: #{external_path}")
      end

      buildroot_path = Path.join(external_path, "buildroot")
      defconfig_path = Path.join([external_path, "configs", "#{board}_defconfig"])
      {buildroot_path, defconfig_path}
    else
      buildroot_path = BuildrootManager.determine_buildroot(opts)
      defconfig_path = Path.join([buildroot_path, "configs", "#{board}_defconfig"])
      {buildroot_path, defconfig_path}
    end
  end

  defp display_success_message(app, board) do
    Mix.shell().info("""

    Generated Nerves system for #{board} in #{app}/

    Files created:
      nerves_defconfig          Nerves Buildroot configuration
      linux-<version>.defconfig Kernel configuration
      fwup.conf                 Firmware update configuration
      fwup-ops.conf             Runtime operations
      fwup_include/             Common fwup includes
      mix.exs                   Project file
      post-build.sh             Buildroot post-build hook
      post-createfs.sh          Buildroot post-createfs hook
      rootfs_overlay/           Root filesystem overlay

    Next steps:
      cd #{app}/
      mix deps.get
      mix compile
    """)
  end
end
