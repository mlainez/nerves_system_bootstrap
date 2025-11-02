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
      mix nerves.system.bootstrap <board> [--buildroot PATH] [--buildroot-url URL] [--buildroot-branch BRANCH]

  Examples:
      mix nerves.system.bootstrap beaglebone
      mix nerves.system.bootstrap pine64 --buildroot ~/src/buildroot-fork
      mix nerves.system.bootstrap pine64 --buildroot-url https://github.com/buildroot/buildroot.git
      mix nerves.system.bootstrap pine64 --buildroot-url https://github.com/buildroot/buildroot.git --buildroot-branch 2025.05.3

  Generated files include:
    - nerves_defconfig with complete Nerves configuration
    - linux-<version>.defconfig extracted from buildroot
    - fwup.conf for firmware creation and updates
    - fwup-ops.conf for post-installation operations
    - fwup_include/ directory with common configurations
    - mix.exs with proper dependencies and toolchain detection
    - post-build.sh and post-createfs.sh scripts
    - rootfs_overlay/ with basic Nerves configuration

  The system automatically detects the target architecture (aarch64, armv7, x86_64, riscv64)
  and configures the appropriate Nerves toolchain and fwup settings.
  """

    @impl true
  def run(argv) do
    {opts, positional, _invalid} =
      OptionParser.parse(argv, switches: [buildroot: :string, buildroot_url: :string, buildroot_branch: :string])

    case positional do
      [board_input] ->
        # Nettoyer le nom du board si il se termine par _defconfig
        board = String.replace_suffix(board_input, "_defconfig", "")

        # 1. Determine and prepare Buildroot
        buildroot_path = BuildrootManager.determine_buildroot(opts)

        # 2. Validate board defconfig exists
        BuildrootManager.validate_board_defconfig(buildroot_path, board)

        # 3. Create the app directory
        app = "nerves_system_#{board}"
        File.mkdir_p!(app)

        # 4. Process defconfig files
        defconfig_path = Path.join([buildroot_path, "configs", "#{board}_defconfig"])
        target_defconfig = Path.join(app, "nerves_defconfig")

        # Copy and clean the defconfig
        File.cp!(defconfig_path, target_defconfig)
        DefconfigProcessor.clean_defconfig_for_nerves(target_defconfig)
        DefconfigProcessor.append_nerves_config(target_defconfig)
        DefconfigProcessor.append_external_reference(target_defconfig, buildroot_path)
        DefconfigProcessor.append_nerves_system_name(target_defconfig, app)

        # 5. Copy kernel defconfig
        DefconfigProcessor.copy_kernel_defconfig(defconfig_path, buildroot_path, app)

        # 6. Copy U-Boot configuration fragments
        DefconfigProcessor.copy_uboot_fragments(target_defconfig, buildroot_path, app)

        # 7. Resolve toolchain
        toolchain_dep = PlatformDetector.infer_toolchain(defconfig_path)
        module_name = Macro.camelize(app)

        # 8. Generate all files using templates
        FileGenerator.generate_files(app, board, module_name, toolchain_dep, buildroot_path)

        # 9. Success message
        display_success_message(app, board)

      _ ->
        Mix.raise("""
        Usage: mix nerves.system.bootstrap <board> [--buildroot PATH] [--buildroot-url URL] [--buildroot-branch BRANCH]
        """)
    end
  end

  defp display_success_message(app, board) do
    Mix.shell().info("✅ Generated complete Nerves system for #{board} in #{app}/")
    Mix.shell().info("📝 Files created:")
    Mix.shell().info("   • nerves_defconfig - Complete Nerves Buildroot configuration")
    Mix.shell().info("   • linux-<version>.defconfig - Kernel configuration")
    Mix.shell().info("   • fwup.conf - Firmware configuration with A/B updates")
    Mix.shell().info("   • fwup-ops.conf - Post-installation operations")
    Mix.shell().info("   • fwup_include/ - Common fwup configurations")
    Mix.shell().info("   • mix.exs - Project file with auto-detected toolchain")
    Mix.shell().info("   • post-build.sh, post-createfs.sh - Build scripts")
    Mix.shell().info("   • rootfs_overlay/ - Nerves system overlays")
    Mix.shell().info("")
    Mix.shell().info("🚀 Next steps:")
    Mix.shell().info("   cd #{app}/")
    Mix.shell().info("   mix deps.get")
    Mix.shell().info("   mix compile")
  end
end
