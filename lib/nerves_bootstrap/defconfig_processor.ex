defmodule NervesBootstrap.DefconfigProcessor do
  @moduledoc """
  Processes Buildroot defconfig files for Nerves system generation,
  including cleaning, appending configurations, and kernel defconfig extraction.
  """

  @doc """
  Cleans a defconfig file by removing Nerves-incompatible options.
  """
  def clean_defconfig_for_nerves(defconfig_path) do
    content = File.read!(defconfig_path)

    cleaned_content =
      content
      |> String.split("\n")
      |> Enum.reject(fn line ->
        # Remove lines that conflict with Nerves
        String.starts_with?(line, "BR2_TARGET_GENERIC_HOSTNAME=") or
        String.starts_with?(line, "BR2_TARGET_GENERIC_ISSUE=") or
        String.starts_with?(line, "BR2_TARGET_GENERIC_PASSWD_SHA256=") or
        String.starts_with?(line, "BR2_SYSTEM_DHCP=") or
        String.starts_with?(line, "BR2_TARGET_ROOTFS_") or
        String.starts_with?(line, "BR2_TARGET_GENERIC_GETTY=") or
        String.starts_with?(line, "BR2_PACKAGE_BUSYBOX_CONFIG=") or
        String.starts_with?(line, "BR2_INIT_") or
        String.starts_with?(line, "BR2_SYSTEM_BIN_SH_") or
        String.starts_with?(line, "BR2_TARGET_OPTIMIZATION=") or
        String.starts_with?(line, "BR2_TOOLCHAIN_") or
        String.starts_with?(line, "BR2_TAR_OPTIONS=") or
        String.starts_with?(line, "BR2_BACKUP_SITE=") or
        String.starts_with?(line, "BR2_ENABLE_DEBUG=") or
        String.starts_with?(line, "BR2_GLOBAL_PATCH_DIR=") or
        String.starts_with?(line, "BR2_REPRODUCIBLE=") or
        String.starts_with?(line, "BR2_ROOTFS_SKELETON_") or
        String.starts_with?(line, "BR2_ROOTFS_DEVICE_TABLE=") or
        String.starts_with?(line, "BR2_ENABLE_LOCALE_") or
        String.starts_with?(line, "BR2_GENERATE_LOCALE=") or
        String.starts_with?(line, "BR2_ROOTFS_OVERLAY=") or
        String.starts_with?(line, "BR2_ROOTFS_POST_BUILD_SCRIPT=") or
        String.starts_with?(line, "BR2_ROOTFS_POST_IMAGE_SCRIPT=") or
        String.starts_with?(line, "BR2_ROOTFS_POST_SCRIPT_ARGS=")
      end)
      |> Enum.join("\n")

    File.write!(defconfig_path, cleaned_content)
  end

  @doc """
  Appends Nerves-specific configuration to a defconfig file.
  """
  def append_nerves_config(defconfig_path) do
    # Get toolchain information for this defconfig
    defconfig_content = File.read!(defconfig_path)
    {toolchain_name, version} = NervesBootstrap.PlatformDetector.infer_toolchain_from_content(defconfig_content)
    toolchain_url = NervesBootstrap.ToolchainResolver.get_toolchain_url(toolchain_name, version)

    nerves_config = """

    # External toolchain configuration
    BR2_TOOLCHAIN_EXTERNAL=y
    BR2_TOOLCHAIN_EXTERNAL_CUSTOM=y
    BR2_TOOLCHAIN_EXTERNAL_DOWNLOAD=y
    BR2_TOOLCHAIN_EXTERNAL_URL="#{toolchain_url}"
    BR2_TOOLCHAIN_EXTERNAL_CUSTOM_PREFIX="#{get_toolchain_prefix(defconfig_content)}"
    #{get_gcc_version_config(toolchain_url)}
    BR2_TOOLCHAIN_EXTERNAL_HEADERS_5_4=y
    BR2_TOOLCHAIN_EXTERNAL_CUSTOM_GLIBC=y
    # BR2_TOOLCHAIN_EXTERNAL_INET_RPC is not set
    BR2_TOOLCHAIN_EXTERNAL_CXX=y
    BR2_TOOLCHAIN_EXTERNAL_FORTRAN=y
    BR2_TOOLCHAIN_EXTERNAL_OPENMP=y

    # Nerves build configuration
    BR2_TAR_OPTIONS="--no-same-owner"
    BR2_BACKUP_SITE="http://dl.nerves-project.org"
    BR2_ENABLE_DEBUG=y
    BR2_GLOBAL_PATCH_DIR="${BR2_EXTERNAL_NERVES_PATH}/patches"
    BR2_REPRODUCIBLE=y

    # Nerves rootfs configuration
    BR2_ROOTFS_SKELETON_CUSTOM=y
    BR2_ROOTFS_SKELETON_CUSTOM_PATH="${BR2_EXTERNAL_NERVES_PATH}/board/nerves-common/skeleton"
    BR2_INIT_NONE=y
    BR2_ROOTFS_DEVICE_TABLE="${BR2_EXTERNAL_NERVES_PATH}/board/nerves-common/device_table.txt"

    # Locale configuration
    BR2_ENABLE_LOCALE_WHITELIST="locale-archive"
    BR2_GENERATE_LOCALE="en_US.UTF-8"

    # Nerves overlays and scripts
    BR2_ROOTFS_OVERLAY="${BR2_EXTERNAL_NERVES_PATH}/board/nerves-common/rootfs_overlay ${NERVES_DEFCONFIG_DIR}/rootfs_overlay"
    BR2_ROOTFS_POST_BUILD_SCRIPT="${NERVES_DEFCONFIG_DIR}/post-build.sh ${BR2_EXTERNAL_NERVES_PATH}/board/nerves-common/post-build.sh"
    BR2_ROOTFS_POST_IMAGE_SCRIPT="${NERVES_DEFCONFIG_DIR}/post-createfs.sh"

    # Target configuration
    BR2_TARGET_GENERIC_HOSTNAME="nerves"
    BR2_TARGET_GENERIC_ISSUE="Welcome to Nerves"
    BR2_SYSTEM_DHCP=""
    BR2_SYSTEM_BIN_SH_DASH=y
    BR2_TARGET_OPTIMIZATION="-Os -pipe"
    BR2_TARGET_ROOTFS_SQUASHFS=y
    BR2_TARGET_ROOTFS_SQUASHFS4_LZ4=y

    # Filesystem tools
    BR2_PACKAGE_E2FSPROGS=y
    BR2_PACKAGE_F2FS_TOOLS=y
    BR2_PACKAGE_HOST_F2FS_TOOLS=y

    # Busybox configuration for Nerves
    BR2_PACKAGE_BUSYBOX=y
    BR2_PACKAGE_BUSYBOX_CONFIG="${BR2_EXTERNAL_NERVES_PATH}/board/nerves-common/busybox.config"

    # Additional Nerves packages
    BR2_PACKAGE_CA_CERTIFICATES=y
    BR2_PACKAGE_LIBP11=y
    BR2_PACKAGE_UNIXODBC=y
    BR2_PACKAGE_CAIRO=y
    BR2_PACKAGE_DTC=y
    BR2_PACKAGE_LIBMNL=y
    BR2_PACKAGE_LIBNL=y
    BR2_NERVES_ADDITIONAL_IMAGE_FILES="${NERVES_DEFCONFIG_DIR}/fwup.conf"
    BR2_PACKAGE_NBTTY=y
    BR2_PACKAGE_BOARDID=y
    BR2_PACKAGE_NERVES_CONFIG=y
    BR2_PACKAGE_NERVES_CONFIG_ACCEPT_RNG_NOTICE=y

    # Kernel
    BR2_LINUX_KERNEL_USE_CUSTOM_CONFIG=y
    BR2_LINUX_KERNEL_NEEDS_HOST_OPENSSL=y
    BR2_LINUX_KERNEL_PATCH="${NERVES_DEFCONFIG_DIR}/linux"
    """

    File.write!(defconfig_path, File.read!(defconfig_path) <> nerves_config)
  end

  @doc """
  Appends external tree reference to defconfig.
  """
  def append_external_reference(defconfig_path, buildroot_path) do
    external_config = """

    # External tree reference
    BR2_EXTERNAL="#{buildroot_path}"
    """

    File.write!(defconfig_path, File.read!(defconfig_path) <> external_config)
  end

  @doc """
  Appends Nerves system name to defconfig.
  """
  def append_nerves_system_name(defconfig_path, app_name) do
    system_config = """

    # Nerves system identification
    BR2_TARGET_GENERIC_HOSTNAME="#{app_name}"
    BR2_NERVES_SYSTEM_NAME="#{app_name}"
    """

    File.write!(defconfig_path, File.read!(defconfig_path) <> system_config)
  end

  @doc """
  Copies and processes kernel defconfig from Buildroot to target directory.
  """
  def copy_kernel_defconfig(defconfig_path, buildroot_path, target_dir) do
    defconfig = File.read!(defconfig_path)

    # Extract kernel version
    kernel_version = case Regex.run(~r/BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE="([^"]+)"/, defconfig) do
      [_, version] -> version
      _ ->
        case Regex.run(~r/BR2_LINUX_KERNEL_CUSTOM_TARBALL_LOCATION="[^"]*linux-([^"\/]+)\.tar\.[^"]+"/, defconfig) do
          [_, version] -> version
          _ -> "6.1.55"  # Default fallback
        end
    end

    target_kernel_defconfig = Path.join(target_dir, "linux-#{kernel_version}.defconfig")

    # Handle custom tarball case
    if String.contains?(defconfig, "BR2_LINUX_KERNEL_CUSTOM_TARBALL=y") do
      Mix.shell().info("📦 Found custom kernel tarball configuration")
      # Extract tarball URL if present
      case Regex.run(~r/BR2_LINUX_KERNEL_CUSTOM_TARBALL_LOCATION="([^"]+)"/, defconfig) do
        [_, tarball_url] ->
          Mix.shell().info("🔗 Custom kernel tarball: #{tarball_url}")
        _ ->
          Mix.shell().info("⚠️ Custom tarball specified but no URL found")
      end
    end

    # First, check if using arch default config
    if String.contains?(defconfig, "BR2_LINUX_KERNEL_USE_ARCH_DEFAULT_CONFIG=y") do
      Mix.shell().info("📋 Using BR2_LINUX_KERNEL_USE_ARCH_DEFAULT_CONFIG=y, downloading kernel sources")

      # Determine architecture from defconfig
      arch_name = cond do
        defconfig =~ "BR2_aarch64=y" -> "arm64"
        defconfig =~ "BR2_arm=y" -> "arm"
        defconfig =~ "BR2_x86_64=y" -> "x86"
        defconfig =~ "BR2_i386=y" -> "x86"
        defconfig =~ "BR2_riscv=y" -> "riscv"
        defconfig =~ "BR2_mips=y" -> "mips"
        defconfig =~ "BR2_powerpc=y" -> "powerpc"
        true -> "arm"  # Default fallback
      end

      # Download kernel sources and extract defconfig
      case download_and_extract_kernel_defconfig(kernel_version, arch_name, target_kernel_defconfig) do
        :ok ->
          Mix.shell().info("✅ Successfully extracted kernel defconfig for #{arch_name}")
          add_nerves_kernel_configs(target_kernel_defconfig)
          # Update the nerves_defconfig to use the custom config file instead of arch default
          update_nerves_defconfig_for_custom_kernel(Path.join(target_dir, "nerves_defconfig"), kernel_version)
        :error ->
          Mix.shell().info("⚠️ Failed to download kernel sources, cannot continue")
      end

      Mix.shell().info("✅ Kernel defconfig: #{target_kernel_defconfig}")
    else
      # Standard logic for custom config files
      process_custom_kernel_config(defconfig, buildroot_path, target_dir, target_kernel_defconfig, kernel_version)
      Mix.shell().info("✅ Kernel defconfig: #{target_kernel_defconfig}")
    end
  end

  defp process_custom_kernel_config(defconfig, buildroot_path, target_dir, target_kernel_defconfig, kernel_version) do
    kernel_defconfig = case Regex.run(~r/BR2_LINUX_KERNEL_CUSTOM_CONFIG_FILE="([^"]+)"/, defconfig) do
      [_, config_file_path] ->
        # The path is relative to buildroot directory
        absolute_path = Path.join(buildroot_path, config_file_path)
        Mix.shell().info("📋 Found BR2_LINUX_KERNEL_CUSTOM_CONFIG_FILE: #{config_file_path}")
        if File.exists?(absolute_path) do
          absolute_path
        else
          Mix.shell().info("⚠️ Specified kernel config file does not exist: #{absolute_path}")
          nil
        end
      _ ->
        Mix.shell().info("🔍 No BR2_LINUX_KERNEL_CUSTOM_CONFIG_FILE found, searching for kernel defconfig...")

        # Try to extract board name from defconfig path for smarter search
        board_name = case Path.basename(target_dir) do
          "nerves_system_" <> board -> board
          board -> board
        end

        # Fallback to searching for kernel defconfig with platform-specific priority
        kernel_defconfig_candidates = [
          # First try board-specific kernel configs
          Path.join([buildroot_path, "board", "**", "#{board_name}", "linux*.config"]),
          Path.join([buildroot_path, "board", "**", "*#{board_name}*", "linux*.config"]),
          Path.join([buildroot_path, "board", "**", "linux-#{kernel_version}.config"]),
          # Then try generic patterns but filter by relevance
          Path.join([buildroot_path, "board", "**", "linux*.config"]),
          Path.join([buildroot_path, "configs", "**", "linux*.config"]),
          # Last resort: any defconfig, but we'll filter it
          Path.join([buildroot_path, "**", "linux-#{kernel_version}.defconfig"])
        ]

        found_configs = kernel_defconfig_candidates
        |> Enum.flat_map(&Path.wildcard/1)
        |> Enum.filter(&File.exists?/1)

        # Prioritize configs that match the board name
        prioritized_config = found_configs
        |> Enum.find(fn path ->
          path_lower = String.downcase(path)
          board_lower = String.downcase(board_name)
          String.contains?(path_lower, board_lower)
        end)

        case prioritized_config do
          nil ->
            # If no board-specific config found, take the first one but warn
            case found_configs do
              [first_config | _] ->
                Mix.shell().info("⚠️ No board-specific kernel config found for #{board_name}, using: #{first_config}")
                first_config
              [] ->
                Mix.shell().info("⚠️ No kernel config files found")
                nil
            end
          config ->
            Mix.shell().info("✅ Found board-specific kernel config: #{config}")
            config
        end
    end

    case kernel_defconfig do
      nil ->
        Mix.shell().info("⚠️ No kernel defconfig found, cannot continue")

      config_path ->
        Mix.shell().info("📋 Copying kernel defconfig from #{config_path}")
        File.cp!(config_path, target_kernel_defconfig)

        # Add Nerves-specific kernel configurations
        nerves_kernel_config = """

        # --- Nerves filesystem support ---
        CONFIG_F2FS_FS=y
        CONFIG_SQUASHFS=y
        CONFIG_SQUASHFS_LZ4=y

        # --- USB ETH support ---
        CONFIG_USB_GADGET=y
        CONFIG_USB_ETH=y
        """

        File.write!(target_kernel_defconfig, nerves_kernel_config, [:append])
    end
  end

  defp get_toolchain_prefix(defconfig) do
    cond do
      defconfig =~ "BR2_aarch64=y" ->
        "aarch64-nerves-linux-gnu"
      defconfig =~ "BR2_arm=y" ->
        "arm-nerves-linux-gnueabihf"
      defconfig =~ "BR2_x86_64=y" ->
        "x86_64-nerves-linux-musl"
      defconfig =~ "BR2_riscv=y" ->
        "riscv64-nerves-linux-gnu"
      true ->
        "arm-nerves-linux-gnueabihf"  # Default fallback
    end
  end

  defp get_gcc_version_config(toolchain_url) do
    # Extract GCC version from toolchain URL
    # Example URL: "https://github.com/nerves-project/toolchains/releases/download/v14.2.0/nerves_toolchain_..."
    case Regex.run(~r/v(\d+)\.(\d+)\./, toolchain_url) do
      [_, major, _minor] ->
        case major do
          "13" -> "BR2_TOOLCHAIN_EXTERNAL_GCC_13=y"
          "14" -> "BR2_TOOLCHAIN_EXTERNAL_GCC_14=y"
          "15" -> "BR2_TOOLCHAIN_EXTERNAL_GCC_15=y"
          "12" -> "BR2_TOOLCHAIN_EXTERNAL_GCC_12=y"
          "11" -> "BR2_TOOLCHAIN_EXTERNAL_GCC_11=y"
          _ ->
            Mix.shell().info("⚠️ Unknown GCC version #{major}, defaulting to GCC 14")
            "BR2_TOOLCHAIN_EXTERNAL_GCC_14=y"
        end
      _ ->
        Mix.shell().info("⚠️ Could not extract GCC version from URL: #{toolchain_url}, defaulting to GCC 14")
        "BR2_TOOLCHAIN_EXTERNAL_GCC_14=y"
    end
  end

  defp add_nerves_kernel_configs(target_path) do
    nerves_kernel_config = """

    # --- Nerves filesystem support ---
    CONFIG_F2FS_FS=y
    CONFIG_SQUASHFS=y
    CONFIG_SQUASHFS_LZ4=y

    # --- USB ETH support ---
    CONFIG_USB_GADGET=y
    CONFIG_USB_ETH=y
    """

    File.write!(target_path, nerves_kernel_config, [:append])
  end

  defp download_and_extract_kernel_defconfig(kernel_version, arch_name, target_path) do
    # Create a temporary directory for kernel download
    temp_dir = System.tmp_dir!() |> Path.join("kernel_download_#{:erlang.system_time()}")
    File.mkdir_p!(temp_dir)

    try do
      # Download kernel tarball
      kernel_url = "https://cdn.kernel.org/pub/linux/kernel/v#{String.slice(kernel_version, 0, 1)}.x/linux-#{kernel_version}.tar.xz"
      tarball_path = Path.join(temp_dir, "linux-#{kernel_version}.tar.xz")

      Mix.shell().info("📥 Downloading kernel #{kernel_version} from #{kernel_url}")

      case download_file(kernel_url, tarball_path) do
        :ok ->
          Mix.shell().info("✅ Downloaded kernel tarball")

          # Extract only the defconfig file we need
          defconfig_path_in_tar = "linux-#{kernel_version}/arch/#{arch_name}/configs/defconfig"
          extract_dir = Path.join(temp_dir, "extracted")

          case extract_defconfig_from_tarball(tarball_path, defconfig_path_in_tar, extract_dir) do
            {:ok, extracted_defconfig} ->
              File.cp!(extracted_defconfig, target_path)
              Mix.shell().info("✅ Extracted and copied kernel defconfig")
              :ok
            :error ->
              Mix.shell().info("❌ Failed to extract defconfig from tarball")
              :error
          end
        :error ->
          Mix.shell().info("❌ Failed to download kernel tarball")
          :error
      end
    after
      # Clean up temporary directory
      if File.exists?(temp_dir) do
        File.rm_rf!(temp_dir)
      end
    end
  end

  defp download_file(url, destination) do
    case System.cmd("curl", ["-L", "-o", destination, url], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, _} ->
        Mix.shell().info("❌ curl failed: #{output}")
        :error
    end
  end

  defp extract_defconfig_from_tarball(tarball_path, defconfig_path_in_tar, extract_dir) do
    File.mkdir_p!(extract_dir)

    case System.cmd("tar", ["-xf", tarball_path, "-C", extract_dir, defconfig_path_in_tar], stderr_to_stdout: true) do
      {_, 0} ->
        extracted_path = Path.join(extract_dir, defconfig_path_in_tar)
        if File.exists?(extracted_path) do
          {:ok, extracted_path}
        else
          :error
        end
      {output, _} ->
        Mix.shell().info("❌ tar extraction failed: #{output}")
        :error
    end
  end

  defp update_nerves_defconfig_for_custom_kernel(nerves_defconfig_path, kernel_version) do
    content = File.read!(nerves_defconfig_path)

    updated_content = content
    |> String.replace(
      "BR2_LINUX_KERNEL_USE_ARCH_DEFAULT_CONFIG=y",
      "BR2_LINUX_KERNEL_CUSTOM_CONFIG_FILE=\"${NERVES_DEFCONFIG_DIR}/linux-#{kernel_version}.defconfig\""
    )
    File.write!(nerves_defconfig_path, updated_content)
    Mix.shell().info("✅ Updated nerves_defconfig to use custom kernel config: ${NERVES_DEFCONFIG_DIR}/linux-#{kernel_version}.defconfig")
  end

end
