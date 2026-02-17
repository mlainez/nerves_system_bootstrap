defmodule NervesBootstrap.DefconfigProcessor do
  @moduledoc """
  Processes Buildroot defconfig files for Nerves system generation,
  including cleaning, appending configurations, and kernel defconfig extraction.
  """

  @doc """
  Prepares a complete Nerves defconfig in a single pass.

  Reads the source defconfig once, applies all transformations (cleaning,
  Nerves config, external reference, system name), deduplicates, and writes
  the result to `target_path`.
  """
  def prepare_nerves_defconfig(source_path, target_path, app_name) do
    content = File.read!(source_path)

    # Validate kernel version >= 5.4 before proceeding
    validate_kernel_version_minimum(content)

    result =
      content
      |> clean_content_for_nerves()
      |> append_nerves_config_to_content()
      |> append_lines(system_name_lines(app_name))
      |> deduplicate_defconfig()

    File.write!(target_path, result)
  end

  @doc """
  Copies and processes kernel defconfig from Buildroot to target directory.
  """
  def copy_kernel_defconfig(defconfig_path, buildroot_path, target_dir) do
    initial_defconfig = File.read!(defconfig_path)

    # Extract kernel version and validate against Buildroot support
    kernel_version =
      case Regex.run(~r/BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE="([^"]+)"/, initial_defconfig) do
        [_, version] ->
          validated_version = validate_kernel_version_against_buildroot(version, buildroot_path)

          if validated_version != version do
            Mix.shell().info(
              "⚠️ Kernel version #{version} not supported by this Buildroot version, using #{validated_version}"
            )

            # Update defconfig with the validated version
            updated_defconfig =
              String.replace(
                initial_defconfig,
                "BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE=\"#{version}\"",
                "BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE=\"#{validated_version}\""
              )

            File.write!(defconfig_path, updated_defconfig)

            Mix.shell().info(
              "✅ Updated #{defconfig_path} with kernel version #{validated_version}"
            )

            validated_version
          else
            version
          end

        _ ->
          # Check for custom Git repository version
          case Regex.run(~r/BR2_LINUX_KERNEL_CUSTOM_REPO_VERSION="([^"]+)"/, initial_defconfig) do
            [_, repo_version] ->
              # Extract version from repo version string (e.g., "qcom-v6.16.7-unoq" -> "6.16.7")
              case Regex.run(~r/v?([0-9]+\.[0-9]+\.[0-9]+)/, repo_version) do
                [_, version] -> version
                _ -> get_default_kernel_version_for_buildroot(buildroot_path)
              end

            _ ->
              # Check for custom tarball
              case Regex.run(
                     ~r/BR2_LINUX_KERNEL_CUSTOM_TARBALL_LOCATION="[^"]*linux-([^"\/]+)\.tar\.[^"]+"/,
                     initial_defconfig
                   ) do
                [_, version] -> version
                _ -> get_default_kernel_version_for_buildroot(buildroot_path)
              end
          end
      end

    # Re-read the defconfig after potential updates
    defconfig = File.read!(defconfig_path)

    target_kernel_defconfig = Path.join(target_dir, "linux-#{kernel_version}.defconfig")

    # Check for custom kernel configuration (Git repo, tarball, etc.)
    cond do
      String.contains?(defconfig, "BR2_LINUX_KERNEL_CUSTOM_GIT=y") ->
        Mix.shell().info("📦 Found custom kernel Git repository configuration")
        # Extract Git repo URL and version
        repo_url =
          case Regex.run(~r/BR2_LINUX_KERNEL_CUSTOM_REPO_URL="([^"]+)"/, defconfig) do
            [_, url] -> url
            _ -> nil
          end

        repo_version =
          case Regex.run(~r/BR2_LINUX_KERNEL_CUSTOM_REPO_VERSION="([^"]+)"/, defconfig) do
            [_, version] -> version
            _ -> nil
          end

        if repo_url && repo_version do
          Mix.shell().info("🔗 Custom kernel Git repo: #{repo_url} (#{repo_version})")
          # For custom Git repo, process as custom config
          process_custom_kernel_config(
            defconfig,
            buildroot_path,
            target_dir,
            target_kernel_defconfig,
            kernel_version
          )
        else
          Mix.shell().info("⚠️ Custom Git repo specified but missing URL or version")

          process_custom_kernel_config(
            defconfig,
            buildroot_path,
            target_dir,
            target_kernel_defconfig,
            kernel_version
          )
        end

        Mix.shell().info("✅ Kernel defconfig: #{target_kernel_defconfig}")

      String.contains?(defconfig, "BR2_LINUX_KERNEL_CUSTOM_TARBALL=y") ->
        Mix.shell().info("📦 Found custom kernel tarball configuration")
        # Extract tarball URL if present
        case Regex.run(~r/BR2_LINUX_KERNEL_CUSTOM_TARBALL_LOCATION="([^"]+)"/, defconfig) do
          [_, tarball_url] ->
            Mix.shell().info("🔗 Custom kernel tarball: #{tarball_url}")
            # For custom tarball, process as custom config
            process_custom_kernel_config(
              defconfig,
              buildroot_path,
              target_dir,
              target_kernel_defconfig,
              kernel_version
            )

          _ ->
            Mix.shell().info("⚠️ Custom tarball specified but no URL found")

            process_custom_kernel_config(
              defconfig,
              buildroot_path,
              target_dir,
              target_kernel_defconfig,
              kernel_version
            )
        end

        Mix.shell().info("✅ Kernel defconfig: #{target_kernel_defconfig}")

      String.contains?(defconfig, "BR2_LINUX_KERNEL_USE_ARCH_DEFAULT_CONFIG=y") ->
        Mix.shell().info(
          "📋 Using BR2_LINUX_KERNEL_USE_ARCH_DEFAULT_CONFIG=y, downloading kernel sources"
        )

        # Determine architecture from defconfig
        arch_name =
          cond do
            defconfig =~ "BR2_aarch64=y" -> "arm64"
            defconfig =~ "BR2_arm=y" -> "arm"
            defconfig =~ "BR2_x86_64=y" -> "x86"
            defconfig =~ "BR2_i386=y" -> "x86"
            defconfig =~ "BR2_riscv=y" -> "riscv"
            defconfig =~ "BR2_mips=y" -> "mips"
            defconfig =~ "BR2_powerpc=y" -> "powerpc"
            # Default fallback
            true -> "arm"
          end

        # Download kernel sources and extract defconfig
        case download_and_extract_kernel_defconfig(
               kernel_version,
               arch_name,
               target_kernel_defconfig
             ) do
          :ok ->
            Mix.shell().info("✅ Successfully extracted kernel defconfig for #{arch_name}")
            add_nerves_kernel_configs(target_kernel_defconfig)
            # Update the nerves_defconfig to use the custom config file instead of arch default
            update_nerves_defconfig_for_custom_kernel(
              Path.join(target_dir, "nerves_defconfig"),
              kernel_version
            )

          :error ->
            Mix.shell().info("⚠️ Failed to download kernel sources, cannot continue")
        end

        Mix.shell().info("✅ Kernel defconfig: #{target_kernel_defconfig}")

      true ->
        # Standard logic for custom config files
        process_custom_kernel_config(
          defconfig,
          buildroot_path,
          target_dir,
          target_kernel_defconfig,
          kernel_version
        )

        Mix.shell().info("✅ Kernel defconfig: #{target_kernel_defconfig}")
    end
  end

  @doc """
  Copies U-Boot configuration fragments from Buildroot to the Nerves system directory
  and updates the nerves_defconfig to use NERVES_DEFCONFIG_DIR paths.
  """
  def copy_uboot_fragments(defconfig_path, buildroot_path, target_dir) do
    defconfig = File.read!(defconfig_path)

    # Look for U-Boot config fragment files
    case Regex.run(~r/BR2_TARGET_UBOOT_CONFIG_FRAGMENT_FILES="([^"]+)"/, defconfig) do
      [_, fragment_files] ->
        Mix.shell().info("📋 Found U-Boot config fragments: #{fragment_files}")

        # Create uboot directory in the target system
        uboot_dir = Path.join(target_dir, "uboot")
        File.mkdir_p!(uboot_dir)

        # Process each fragment file (can be space-separated)
        fragments = String.split(fragment_files, " ", trim: true)

        copied_fragments =
          Enum.reduce(fragments, [], fn fragment, acc ->
            source_path = Path.join(buildroot_path, fragment)
            fragment_name = Path.basename(fragment)
            target_path = Path.join(uboot_dir, fragment_name)

            if File.exists?(source_path) do
              File.cp!(source_path, target_path)
              Mix.shell().info("📄 Copied U-Boot fragment: #{fragment} -> uboot/#{fragment_name}")
              acc ++ ["${NERVES_DEFCONFIG_DIR}/uboot/#{fragment_name}"]
            else
              Mix.shell().info("⚠️ U-Boot fragment not found: #{source_path}")
              acc
            end
          end)

        # Update the nerves_defconfig to use NERVES_DEFCONFIG_DIR paths
        if length(copied_fragments) > 0 do
          new_fragment_line =
            "BR2_TARGET_UBOOT_CONFIG_FRAGMENT_FILES=\"#{Enum.join(copied_fragments, " ")}\""

          updated_defconfig =
            String.replace(
              defconfig,
              ~r/BR2_TARGET_UBOOT_CONFIG_FRAGMENT_FILES="[^"]*"/,
              new_fragment_line
            )

          File.write!(defconfig_path, updated_defconfig)

          Mix.shell().info(
            "✅ Updated nerves_defconfig with NERVES_DEFCONFIG_DIR paths for U-Boot fragments"
          )
        end

      _ ->
        Mix.shell().info("ℹ️ No U-Boot config fragments found in defconfig")
    end
  end

  defp process_custom_kernel_config(
         defconfig,
         buildroot_path,
         target_dir,
         target_kernel_defconfig,
         kernel_version
       ) do
    cond do
      # First check for custom Git repository configuration
      String.contains?(defconfig, "BR2_LINUX_KERNEL_CUSTOM_GIT=y") ->
        repo_url =
          case Regex.run(~r/BR2_LINUX_KERNEL_CUSTOM_REPO_URL="([^"]+)"/, defconfig) do
            [_, url] -> url
            _ -> nil
          end

        repo_version =
          case Regex.run(~r/BR2_LINUX_KERNEL_CUSTOM_REPO_VERSION="([^"]+)"/, defconfig) do
            [_, version] -> version
            _ -> nil
          end

        if repo_url && repo_version do
          Mix.shell().info("🔗 Using custom kernel Git repository: #{repo_url} (#{repo_version})")
          # Extract kernel version from repo version if possible, otherwise use provided version
          extracted_version =
            case Regex.run(~r/v?([0-9]+\.[0-9]+\.[0-9]+)/, repo_version) do
              [_, version] -> version
              _ -> kernel_version
            end

          # Clone the custom kernel repository and extract the appropriate defconfig
          case clone_and_extract_kernel_defconfig(
                 repo_url,
                 repo_version,
                 defconfig,
                 target_kernel_defconfig,
                 extracted_version
               ) do
            :ok ->
              Mix.shell().info("✅ Successfully extracted kernel defconfig from custom repository")
              # Update the nerves_defconfig to use the custom config file instead of other options
              update_nerves_defconfig_for_custom_kernel(
                Path.join(target_dir, "nerves_defconfig"),
                extracted_version
              )

            :error ->
              Mix.shell().info(
                "⚠️ Failed to extract from custom repository, creating fallback config"
              )

              arch = determine_kernel_arch_from_defconfig(defconfig)
              create_minimal_kernel_config(target_kernel_defconfig, extracted_version, arch)
              # Still update nerves_defconfig even with fallback
              update_nerves_defconfig_for_custom_kernel(
                Path.join(target_dir, "nerves_defconfig"),
                extracted_version
              )
          end
        else
          Mix.shell().info("⚠️ Custom Git repo specified but missing URL or version")
          arch = determine_kernel_arch_from_defconfig(defconfig)
          create_minimal_kernel_config(target_kernel_defconfig, kernel_version, arch)
        end

      # Check for custom tarball configuration
      String.contains?(defconfig, "BR2_LINUX_KERNEL_CUSTOM_TARBALL=y") ->
        case Regex.run(~r/BR2_LINUX_KERNEL_CUSTOM_TARBALL_LOCATION="([^"]+)"/, defconfig) do
          [_, tarball_url] ->
            Mix.shell().info("🔗 Using custom kernel tarball: #{tarball_url}")
            # Extract kernel version from URL if possible
            extracted_version =
              case Regex.run(~r/linux-([0-9]+\.[0-9]+\.[0-9]+)/, tarball_url) do
                [_, version] -> version
                _ -> kernel_version
              end

            # For custom kernel tarballs, we create a minimal defconfig
            # since the exact config will depend on the custom kernel
            arch = determine_kernel_arch_from_defconfig(defconfig)
            create_minimal_kernel_config(target_kernel_defconfig, extracted_version, arch)

          _ ->
            Mix.shell().info("⚠️ Custom tarball specified but no URL found")
            arch = determine_kernel_arch_from_defconfig(defconfig)
            create_minimal_kernel_config(target_kernel_defconfig, kernel_version, arch)
        end

      # Standard custom config file processing
      true ->
        process_standard_custom_config(
          defconfig,
          buildroot_path,
          target_dir,
          target_kernel_defconfig,
          kernel_version
        )
    end
  end

  defp process_standard_custom_config(
         defconfig,
         buildroot_path,
         target_dir,
         target_kernel_defconfig,
         kernel_version
       ) do
    # Standard custom config file processing
    kernel_defconfig =
      case Regex.run(~r/BR2_LINUX_KERNEL_CUSTOM_CONFIG_FILE="([^"]+)"/, defconfig) do
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
          Mix.shell().info(
            "🔍 No BR2_LINUX_KERNEL_CUSTOM_CONFIG_FILE found, searching for kernel defconfig..."
          )

          # Try to extract board name from defconfig path for smarter search
          board_name =
            case Path.basename(target_dir) do
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

          found_configs =
            kernel_defconfig_candidates
            |> Enum.flat_map(&Path.wildcard/1)
            |> Enum.filter(&File.exists?/1)

          # Prioritize configs that match the board name
          prioritized_config =
            found_configs
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
                  Mix.shell().info(
                    "⚠️ No board-specific kernel config found for #{board_name}, using: #{first_config}"
                  )

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
        Mix.shell().info("⚠️ No kernel defconfig found, creating minimal config")
        arch = determine_kernel_arch_from_defconfig(defconfig)
        create_minimal_kernel_config(target_kernel_defconfig, kernel_version, arch)
        # Update nerves_defconfig to point to the created kernel config file
        update_nerves_defconfig_for_custom_kernel(
          Path.join(target_dir, "nerves_defconfig"),
          kernel_version
        )

      config_path ->
        Mix.shell().info("📋 Copying kernel defconfig from #{config_path}")
        File.cp!(config_path, target_kernel_defconfig)
        add_nerves_kernel_configs(target_kernel_defconfig)
        # Update nerves_defconfig to point to the copied kernel config file
        update_nerves_defconfig_for_custom_kernel(
          Path.join(target_dir, "nerves_defconfig"),
          kernel_version
        )
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
        # Default fallback
        "arm-nerves-linux-gnueabihf"
    end
  end

  # Returns the C library config line. Nerves exclusively uses glibc.
  # For x86_64 (musl-based toolchain), emit a warning but allow it.
  defp get_c_library_config(toolchain_prefix) do
    if String.contains?(toolchain_prefix, "musl") do
      Mix.shell().info(
        "WARNING: This toolchain uses musl instead of glibc. " <>
          "Nerves officially supports glibc only. Some packages may not work correctly."
      )

      "BR2_TOOLCHAIN_EXTERNAL_CUSTOM_MUSL=y"
    else
      "BR2_TOOLCHAIN_EXTERNAL_CUSTOM_GLIBC=y"
    end
  end

  # Removes Nerves-incompatible options from defconfig content.
  # Returns the cleaned content string.
  defp clean_content_for_nerves(content) do
    content
    |> String.split("\n")
    |> Enum.reject(fn line ->
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
  end

  # Appends Nerves-specific Buildroot configuration to content string.
  # Resolves toolchain URL and generates all required config lines.
  defp append_nerves_config_to_content(content) do
    {toolchain_name, version} =
      NervesBootstrap.PlatformDetector.infer_toolchain_from_content(content)

    toolchain_url = NervesBootstrap.ToolchainResolver.get_toolchain_url(toolchain_name, version)
    toolchain_prefix = get_toolchain_prefix(content)
    gcc_version_config = get_gcc_version_config(toolchain_url)
    c_lib_config = get_c_library_config(toolchain_prefix)

    nerves_config = """

    # External toolchain configuration
    BR2_TOOLCHAIN_EXTERNAL=y
    BR2_TOOLCHAIN_EXTERNAL_CUSTOM=y
    BR2_TOOLCHAIN_EXTERNAL_DOWNLOAD=y
    BR2_TOOLCHAIN_EXTERNAL_URL="#{toolchain_url}"
    BR2_TOOLCHAIN_EXTERNAL_CUSTOM_PREFIX="#{toolchain_prefix}"
    #{gcc_version_config}
    BR2_TOOLCHAIN_EXTERNAL_HEADERS_5_4=y
    #{c_lib_config}
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

    content <> nerves_config
  end

  defp system_name_lines(app_name) do
    """

    # Nerves system identification
    BR2_TARGET_GENERIC_HOSTNAME="#{app_name}"
    BR2_NERVES_SYSTEM_NAME="#{app_name}"
    """
  end

  defp append_lines(content, lines), do: content <> lines

  # Validates that the kernel version in the defconfig is >= 5.4.
  # Nerves toolchains use BR2_TOOLCHAIN_EXTERNAL_HEADERS_5_4 as a fixed baseline,
  # so kernels older than 5.4 are incompatible.
  defp validate_kernel_version_minimum(defconfig_content) do
    kernel_version = extract_kernel_version_from_content(defconfig_content)

    case kernel_version do
      nil ->
        # No explicit kernel version found; can't validate, proceed
        :ok

      version ->
        case version_to_sortable(version) do
          sortable when sortable < {5, 4, 0} ->
            Mix.raise("""
            Kernel version #{version} is too old for Nerves.

            Nerves toolchains require kernel headers >= 5.4 \
            (BR2_TOOLCHAIN_EXTERNAL_HEADERS_5_4). Kernels older than 5.4 are \
            incompatible with the Nerves toolchain.

            Please update your defconfig to use a kernel >= 5.4.
            """)

          _ ->
            :ok
        end
    end
  end

  # Extracts a kernel version string from defconfig content by checking
  # multiple possible Buildroot kernel version settings.
  defp extract_kernel_version_from_content(content) do
    cond do
      match = Regex.run(~r/BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE="([^"]+)"/, content) ->
        Enum.at(match, 1)

      match = Regex.run(~r/BR2_LINUX_KERNEL_CUSTOM_REPO_VERSION="([^"]+)"/, content) ->
        repo_version = Enum.at(match, 1)

        case Regex.run(~r/v?([0-9]+\.[0-9]+\.[0-9]+)/, repo_version) do
          [_, version] -> version
          _ -> nil
        end

      match =
          Regex.run(
            ~r/BR2_LINUX_KERNEL_CUSTOM_TARBALL_LOCATION="[^"]*linux-([0-9]+\.[0-9]+\.[0-9]+)\.tar\.[^"]+"/,
            content
          ) ->
        Enum.at(match, 1)

      true ->
        nil
    end
  end

  defp get_gcc_version_config(toolchain_url) do
    # Extract GCC version from toolchain URL
    # Example URL: "https://github.com/nerves-project/toolchains/releases/download/v14.2.0/nerves_toolchain_..."
    case Regex.run(~r/v(\d+)\.(\d+)\./, toolchain_url) do
      [_, major, _minor] ->
        case major do
          "13" ->
            "BR2_TOOLCHAIN_EXTERNAL_GCC_13=y"

          "14" ->
            "BR2_TOOLCHAIN_EXTERNAL_GCC_14=y"

          "15" ->
            "BR2_TOOLCHAIN_EXTERNAL_GCC_15=y"

          "12" ->
            "BR2_TOOLCHAIN_EXTERNAL_GCC_12=y"

          "11" ->
            "BR2_TOOLCHAIN_EXTERNAL_GCC_11=y"

          _ ->
            Mix.shell().info("⚠️ Unknown GCC version #{major}, defaulting to GCC 14")
            "BR2_TOOLCHAIN_EXTERNAL_GCC_14=y"
        end

      _ ->
        Mix.shell().info(
          "⚠️ Could not extract GCC version from URL: #{toolchain_url}, defaulting to GCC 14"
        )

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
      kernel_url =
        "https://cdn.kernel.org/pub/linux/kernel/v#{String.slice(kernel_version, 0, 1)}.x/linux-#{kernel_version}.tar.xz"

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
      {_, 0} ->
        :ok

      {output, _} ->
        Mix.shell().info("❌ curl failed: #{output}")
        :error
    end
  end

  defp extract_defconfig_from_tarball(tarball_path, defconfig_path_in_tar, extract_dir) do
    File.mkdir_p!(extract_dir)

    case System.cmd("tar", ["-xf", tarball_path, "-C", extract_dir, defconfig_path_in_tar],
           stderr_to_stdout: true
         ) do
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

    updated_content =
      content
      # Remove only conflicting kernel config options, keep Git repo info
      |> String.replace(~r/BR2_LINUX_KERNEL_USE_ARCH_DEFAULT_CONFIG=y/, "")
      |> String.replace(~r/BR2_LINUX_KERNEL_CUSTOM_CONFIG_FILE="[^"]*"/, "")

    # Try different anchoring points to add the custom config file reference
    updated_content =
      cond do
        # First try: after custom repo version (for Git-based kernels)
        String.contains?(updated_content, "BR2_LINUX_KERNEL_CUSTOM_REPO_VERSION=") ->
          String.replace(
            updated_content,
            ~r/(BR2_LINUX_KERNEL_CUSTOM_REPO_VERSION="[^"]*")/,
            "\\1\nBR2_LINUX_KERNEL_CUSTOM_CONFIG_FILE=\"${NERVES_DEFCONFIG_DIR}/linux-#{kernel_version}.defconfig\""
          )

        # Second try: after custom version value (for version-based kernels)
        String.contains?(updated_content, "BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE=") ->
          String.replace(
            updated_content,
            ~r/(BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE="[^"]*")/,
            "\\1\nBR2_LINUX_KERNEL_CUSTOM_CONFIG_FILE=\"${NERVES_DEFCONFIG_DIR}/linux-#{kernel_version}.defconfig\""
          )

        # Third try: after use custom config (for custom config kernels)
        String.contains?(updated_content, "BR2_LINUX_KERNEL_USE_CUSTOM_CONFIG=y") ->
          String.replace(
            updated_content,
            "BR2_LINUX_KERNEL_USE_CUSTOM_CONFIG=y",
            "BR2_LINUX_KERNEL_USE_CUSTOM_CONFIG=y\nBR2_LINUX_KERNEL_CUSTOM_CONFIG_FILE=\"${NERVES_DEFCONFIG_DIR}/linux-#{kernel_version}.defconfig\""
          )

        # Last fallback: after basic kernel enable
        String.contains?(updated_content, "BR2_LINUX_KERNEL=y") ->
          String.replace(
            updated_content,
            "BR2_LINUX_KERNEL=y",
            "BR2_LINUX_KERNEL=y\nBR2_LINUX_KERNEL_CUSTOM_CONFIG_FILE=\"${NERVES_DEFCONFIG_DIR}/linux-#{kernel_version}.defconfig\""
          )

        # If nothing found, append at the end
        true ->
          updated_content <>
            "\nBR2_LINUX_KERNEL_CUSTOM_CONFIG_FILE=\"${NERVES_DEFCONFIG_DIR}/linux-#{kernel_version}.defconfig\"\n"
      end

    File.write!(nerves_defconfig_path, updated_content)

    Mix.shell().info(
      "✅ Updated nerves_defconfig to use custom kernel config: ${NERVES_DEFCONFIG_DIR}/linux-#{kernel_version}.defconfig"
    )
  end

  # Validates kernel version against what's supported by the local Buildroot version.
  # Returns the original version if supported, or a compatible version if not.
  defp validate_kernel_version_against_buildroot(kernel_version, buildroot_path) do
    supported_versions = get_supported_kernel_versions_from_hash(buildroot_path)

    if kernel_version in supported_versions do
      kernel_version
    else
      # Find the highest supported version that's compatible
      requested_major_minor = extract_major_minor_version(kernel_version)

      # Try to find a version with same major.minor
      compatible_version =
        supported_versions
        |> Enum.filter(fn v -> extract_major_minor_version(v) == requested_major_minor end)
        |> Enum.sort_by(&version_to_sortable/1, :desc)
        |> List.first()

      case compatible_version do
        nil ->
          # No compatible version found, use the highest supported version
          latest_supported =
            supported_versions
            |> Enum.sort_by(&version_to_sortable/1, :desc)
            |> List.first()

          Mix.shell().info(
            "⚠️ No compatible kernel version found for #{kernel_version}, using latest supported: #{latest_supported}"
          )

          latest_supported || get_default_kernel_version_for_buildroot(buildroot_path)

        version ->
          version
      end
    end
  end

  # Gets supported kernel versions from the local Buildroot's package/linux/ files.
  # In practice, Buildroot supports a wide range of kernel versions, so we use
  # a conservative approach with known LTS versions for the validation.
  defp get_supported_kernel_versions_from_hash(buildroot_path) do
    # Try multiple potential locations for Linux package information
    potential_paths = [
      Path.join([buildroot_path, "package", "linux", "linux.hash"]),
      Path.join([buildroot_path, "package", "linux-headers", "linux-headers.hash"]),
      Path.join([buildroot_path, "linux", "linux.hash"])
    ]

    versions_from_file =
      Enum.find_value(potential_paths, fn path ->
        if File.exists?(path) do
          content = File.read!(path)

          # Extract versions from hash file
          # Format: sha256 hash_value linux-X.Y.Z.tar.xz
          versions =
            content
            |> String.split("\n")
            |> Enum.filter(fn line ->
              String.contains?(line, "linux-") and String.ends_with?(line, ".tar.xz")
            end)
            |> Enum.map(fn line ->
              case Regex.run(~r/linux-([0-9]+\.[0-9]+\.[0-9]+)\.tar\.xz/, line) do
                [_, version] -> version
                _ -> nil
              end
            end)
            |> Enum.filter(&(&1 != nil))
            |> Enum.uniq()
            |> Enum.sort_by(&version_to_sortable/1, :desc)

          if length(versions) > 0 do
            Mix.shell().info(
              "📋 Found #{length(versions)} supported kernel versions in Buildroot #{path}"
            )

            versions
          else
            nil
          end
        else
          nil
        end
      end)

    # Use file versions if found, otherwise fallback to known LTS versions
    if versions_from_file do
      versions_from_file
    else
      Mix.shell().info(
        "⚠️ Could not find kernel version information in Buildroot, using known LTS versions"
      )

      ["6.6.93", "6.6.58", "6.1.114", "5.15.170", "5.10.227", "5.4.285"]
    end
  end

  # Gets the default kernel version for a Buildroot installation.
  defp get_default_kernel_version_for_buildroot(buildroot_path) do
    supported_versions = get_supported_kernel_versions_from_hash(buildroot_path)

    # Try to find an LTS version first (6.6, 6.1, 5.15, 5.10, 5.4, 4.19)
    lts_version =
      supported_versions
      |> Enum.find(fn version ->
        major_minor = extract_major_minor_version(version)
        major_minor in ["6.6", "6.1", "5.15", "5.10", "5.4"]
      end)

    lts_version || List.first(supported_versions) || "6.1.55"
  end

  defp extract_major_minor_version(version) do
    case String.split(version, ".") do
      [major, minor, _patch] -> "#{major}.#{minor}"
      [major, minor] -> "#{major}.#{minor}"
      _ -> version
    end
  end

  # Deduplicates Buildroot defconfig lines. When the same config key appears
  # multiple times, the last occurrence wins (so Nerves additions override
  # original defconfig values). Comments and blank lines are preserved.
  defp deduplicate_defconfig(content) do
    lines = String.split(content, "\n")

    # Walk lines in reverse so the last occurrence of each key is kept
    {deduped_reversed, _seen} =
      lines
      |> Enum.reverse()
      |> Enum.reduce({[], MapSet.new()}, fn line, {acc, seen} ->
        trimmed = String.trim(line)

        cond do
          # Keep blank lines and comments
          trimmed == "" or String.starts_with?(trimmed, "#") ->
            {[line | acc], seen}

          # Config line: extract key (part before "=")
          true ->
            key =
              case String.split(trimmed, "=", parts: 2) do
                [k, _] -> k
                [k] -> k
              end

            if MapSet.member?(seen, key) do
              # Skip this duplicate (earlier occurrence)
              {acc, seen}
            else
              {[line | acc], MapSet.put(seen, key)}
            end
        end
      end)

    # deduped_reversed is already in correct order (we prepended to acc while
    # iterating reversed lines, so the result is forward-ordered)
    Enum.join(deduped_reversed, "\n")
  end

  defp version_to_sortable(version) do
    parts =
      version
      |> String.split(".")
      |> Enum.map(&String.to_integer/1)

    # Normalize to {major, minor, patch} for consistent comparison
    case parts do
      [major] -> {major, 0, 0}
      [major, minor] -> {major, minor, 0}
      [major, minor, patch | _] -> {major, minor, patch}
    end
  end

  # Creates a minimal kernel configuration for custom kernels where we don't have a specific defconfig.
  # The arch parameter should be the Buildroot arch string from the defconfig content
  # (used to call determine_kernel_arch_from_defconfig/1).
  defp create_minimal_kernel_config(target_path, kernel_version, arch) do
    arch_config = arch_specific_kernel_config(arch)

    minimal_kernel_config = """
    # Minimal kernel configuration for custom kernel #{kernel_version} (#{arch})
    #{arch_config}
    CONFIG_MMU=y
    CONFIG_MODULES=y
    CONFIG_PRINTK=y
    CONFIG_TTY=y
    CONFIG_SERIAL_8250=y
    CONFIG_SERIAL_8250_CONSOLE=y
    CONFIG_EARLY_PRINTK=y
    CONFIG_NET=y
    CONFIG_INET=y
    CONFIG_PACKET=y
    CONFIG_UNIX=y
    CONFIG_SYSFS=y
    CONFIG_PROC_FS=y
    CONFIG_TMPFS=y
    CONFIG_DEVTMPFS=y
    CONFIG_DEVTMPFS_MOUNT=y
    CONFIG_EXT4_FS=y
    CONFIG_FAT_FS=y
    CONFIG_VFAT_FS=y
    CONFIG_NLS_CODEPAGE_437=y
    CONFIG_NLS_ISO8859_1=y

    # --- Nerves filesystem support ---
    CONFIG_F2FS_FS=y
    CONFIG_SQUASHFS=y
    CONFIG_SQUASHFS_LZ4=y

    # --- USB ETH support ---
    CONFIG_USB_GADGET=y
    CONFIG_USB_ETH=y
    """

    File.write!(target_path, minimal_kernel_config)

    Mix.shell().info(
      "✅ Created minimal kernel config for custom kernel #{kernel_version} (#{arch})"
    )
  end

  defp arch_specific_kernel_config("arm64") do
    """
    CONFIG_64BIT=y
    CONFIG_ARM64=y
    """
    |> String.trim()
  end

  defp arch_specific_kernel_config("arm") do
    """
    CONFIG_ARM=y
    CONFIG_AEABI=y
    CONFIG_CPU_V7=y
    CONFIG_VFP=y
    CONFIG_NEON=y
    """
    |> String.trim()
  end

  defp arch_specific_kernel_config("x86") do
    """
    CONFIG_64BIT=y
    CONFIG_X86_64=y
    CONFIG_SMP=y
    """
    |> String.trim()
  end

  defp arch_specific_kernel_config("riscv") do
    """
    CONFIG_64BIT=y
    CONFIG_RISCV=y
    CONFIG_ARCH_RV64I=y
    CONFIG_SMP=y
    """
    |> String.trim()
  end

  defp arch_specific_kernel_config("mips") do
    """
    CONFIG_MIPS=y
    CONFIG_CPU_MIPS32_R2=y
    """
    |> String.trim()
  end

  defp arch_specific_kernel_config("powerpc") do
    """
    CONFIG_PPC=y
    CONFIG_PPC64=y
    """
    |> String.trim()
  end

  defp arch_specific_kernel_config(_) do
    """
    CONFIG_64BIT=y
    CONFIG_ARM64=y
    """
    |> String.trim()
  end

  # Clones a custom kernel Git repository and extracts the appropriate defconfig
  defp clone_and_extract_kernel_defconfig(
         repo_url,
         repo_version,
         defconfig,
         target_defconfig_path,
         _kernel_version
       ) do
    # Create a temporary directory for kernel repository
    temp_dir = System.tmp_dir!() |> Path.join("kernel_repo_#{:erlang.system_time()}")

    try do
      Mix.shell().info("📥 Cloning custom kernel repository: #{repo_url} (#{repo_version})")

      # Clone the repository with the specific branch/tag
      case System.cmd(
             "git",
             ["clone", "--branch", repo_version, "--depth", "1", repo_url, temp_dir],
             stderr_to_stdout: true
           ) do
        {_, 0} ->
          Mix.shell().info("✅ Successfully cloned kernel repository")

          # Determine architecture for defconfig path
          arch_name = determine_kernel_arch_from_defconfig(defconfig)

          # Find the appropriate defconfig in the repository
          case find_kernel_defconfig_in_repo(temp_dir, arch_name, defconfig) do
            {:ok, found_defconfig_path} ->
              Mix.shell().info(
                "📋 Found kernel defconfig: #{Path.relative_to(found_defconfig_path, temp_dir)}"
              )

              File.cp!(found_defconfig_path, target_defconfig_path)
              add_nerves_kernel_configs(target_defconfig_path)
              :ok

            :error ->
              Mix.shell().info("⚠️ Could not find appropriate defconfig in repository")
              :error
          end

        {output, _} ->
          Mix.shell().info("❌ Failed to clone repository: #{output}")
          :error
      end
    after
      # Clean up temporary directory
      if File.exists?(temp_dir) do
        File.rm_rf!(temp_dir)
      end
    end
  end

  # Determines the kernel architecture from the defconfig content
  defp determine_kernel_arch_from_defconfig(defconfig) do
    cond do
      defconfig =~ "BR2_aarch64=y" -> "arm64"
      defconfig =~ "BR2_arm=y" -> "arm"
      defconfig =~ "BR2_x86_64=y" -> "x86"
      defconfig =~ "BR2_i386=y" -> "x86"
      defconfig =~ "BR2_riscv=y" -> "riscv"
      defconfig =~ "BR2_mips=y" -> "mips"
      defconfig =~ "BR2_powerpc=y" -> "powerpc"
      # Default fallback for Arduino Uno Q
      true -> "arm64"
    end
  end

  # Finds the appropriate kernel defconfig in the cloned repository
  defp find_kernel_defconfig_in_repo(repo_dir, arch_name, defconfig) do
    # Possible defconfig locations in order of preference
    potential_paths = [
      # 1. Look for board-specific defconfig if mentioned in BR2_LINUX_KERNEL_USE_ARCH_DEFAULT_CONFIG
      # Check if there's a specific defconfig mentioned (sometimes overridden)
      get_specific_defconfig_from_buildroot_config(repo_dir, defconfig, arch_name),

      # 2. Standard arch default config
      Path.join([repo_dir, "arch", arch_name, "configs", "defconfig"]),

      # 3. Look for board-specific configs that might match
      find_board_specific_defconfig(repo_dir, arch_name, defconfig),

      # 4. Any defconfig in the arch directory as fallback
      find_any_defconfig_in_arch(repo_dir, arch_name)
    ]

    # Find the first existing config
    found_config =
      Enum.find(potential_paths, fn path ->
        path && File.exists?(path)
      end)

    case found_config do
      nil -> :error
      path -> {:ok, path}
    end
  end

  # Checks if there's a specific defconfig mentioned in the buildroot configuration
  defp get_specific_defconfig_from_buildroot_config(repo_dir, defconfig, arch_name) do
    # Sometimes custom kernels specify a particular defconfig to use
    # This is rare but worth checking
    case Regex.run(~r/BR2_LINUX_KERNEL_DEFCONFIG="([^"]+)"/, defconfig) do
      [_, defconfig_name] ->
        Path.join([repo_dir, "arch", arch_name, "configs", "#{defconfig_name}_defconfig"])

      _ ->
        nil
    end
  end

  # Looks for board-specific defconfig files
  defp find_board_specific_defconfig(repo_dir, arch_name, _defconfig) do
    # Look for defconfigs that might be board-specific
    # Common patterns: qcom_defconfig, imx_defconfig, etc.
    configs_dir = Path.join([repo_dir, "arch", arch_name, "configs"])

    if File.exists?(configs_dir) do
      # Look for patterns that might match our board
      potential_configs = [
        # For Qualcomm boards like Arduino Uno Q
        "qcom_defconfig",
        # For i.MX boards
        "imx_defconfig",
        # For Allwinner boards
        "sunxi_defconfig",
        # For Raspberry Pi
        "bcm2835_defconfig",
        # Generic ARM
        "versatile_defconfig"
      ]

      found_config =
        Enum.find(potential_configs, fn config_name ->
          config_path = Path.join(configs_dir, config_name)
          File.exists?(config_path)
        end)

      case found_config do
        nil -> nil
        config_name -> Path.join(configs_dir, config_name)
      end
    else
      nil
    end
  end

  # Finds any defconfig in the arch directory as a last resort
  defp find_any_defconfig_in_arch(repo_dir, arch_name) do
    configs_dir = Path.join([repo_dir, "arch", arch_name, "configs"])

    if File.exists?(configs_dir) do
      # Get all defconfig files and pick the first one
      defconfigs = Path.wildcard(Path.join(configs_dir, "*defconfig"))
      List.first(defconfigs)
    else
      nil
    end
  end
end
