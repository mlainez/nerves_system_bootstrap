defmodule NervesBootstrap.FileGenerator do
  @moduledoc """
  Generates all the necessary files for a Nerves system using EEx templates
  from priv/templates/nerves_system, including mix.exs, fwup configurations,
  build scripts, and overlay directories.
  """

  import Bitwise

  @doc """
  Generates all files for the Nerves system using templates.
  """
  def generate_files(
        app,
        board,
        module_name,
        toolchain_dep,
        buildroot_path,
        defconfig_path,
        external_path \\ nil
      ) do
    # Copy custom packages from external tree before generating templates
    # (so Config.in can reference them)
    custom_packages = copy_custom_packages(app, external_path)

    # Prepare template binding variables
    binding =
      prepare_template_binding(
        app,
        board,
        module_name,
        toolchain_dep,
        buildroot_path,
        defconfig_path,
        custom_packages
      )

    # Generate files from templates
    generate_from_templates(app, binding)

    # Copy additional files from buildroot board directory
    copy_buildroot_board_files(buildroot_path, board, app, binding)

    # Create additional directories that might be needed
    create_additional_directories(app)
  end

  defp prepare_template_binding(
         app,
         board,
         module_name,
         toolchain_dep,
         buildroot_path,
         defconfig_path,
         custom_packages
       ) do
    nerves_defconfig_path = Path.join(app, "nerves_defconfig")
    platform_config = NervesBootstrap.PlatformDetector.detect_platform_config(defconfig_path)
    arch_config = NervesBootstrap.PlatformDetector.get_arch_config(toolchain_dep)

    # Analyze genimage config to update platform_config with partition scheme
    platform_config =
      analyze_and_update_platform_config(platform_config, buildroot_path, board, defconfig_path)

    # Extract DTSO names from nerves_defconfig if it exists
    dtso_names = extract_dtso_names(nerves_defconfig_path)

    # Generate GUIDs for GPT partitions
    partition_guids = generate_partition_guids(platform_config)

    # Estimate boot partition size dynamically
    boot_part_blocks =
      NervesBootstrap.PlatformDetector.estimate_boot_partition_blocks(platform_config)

    boot_part_mib = div(boot_part_blocks, 2048)

    [
      app: app,
      board: board,
      module_name: module_name,
      toolchain_dep: format_toolchain_dep(toolchain_dep),
      toolchain_dep_string: format_toolchain_dep_string(toolchain_dep),
      toolchain_tuple: toolchain_dep,
      platform_config: platform_config,
      arch_config: arch_config,
      dtso_names: dtso_names,
      partition_guids: partition_guids,
      custom_packages: custom_packages,
      boot_part_blocks: boot_part_blocks,
      boot_part_mib: boot_part_mib,
      nerves_system_br_req: nerves_system_br_version_req(),
      dep_string: fn {name, version} -> "{:#{name}, \"#{version}\", runtime: false}" end,
      architecture: get_architecture(toolchain_dep),
      # This could be configurable
      github_organization: detect_github_organization(),
      board_description: format_board_description(board),
      target_arch: arch_config.arch,
      target_cpu: arch_config.target_cpu,
      target_abi: arch_config.abi,
      target_gcc_flags: get_target_gcc_flags(arch_config),
      external_buildroot: buildroot_path,
      uboot_arch: get_uboot_arch(platform_config)
    ]
  end

  defp generate_from_templates(app, binding) do
    templates_dir = get_templates_dir()
    target_dir = app

    # Get all template files recursively
    template_files = get_all_template_files(templates_dir)

    Enum.each(template_files, fn template_path ->
      generate_file_from_template(template_path, templates_dir, target_dir, binding)
    end)
  end

  defp get_templates_dir do
    # Get the priv directory of this application
    case :code.priv_dir(:nerves_system_bootstrap) do
      {:error, _} ->
        # Fallback to relative path if priv_dir not found
        Path.join([File.cwd!(), "priv", "templates", "nerves_system"])

      priv_path ->
        # Convert to string if it's a charlist
        path_string = to_string(priv_path)
        Path.join([path_string, "templates", "nerves_system"])
    end
  end

  defp get_all_template_files(templates_dir) do
    # Get both normal files and hidden files (starting with .)
    normal_files = Path.wildcard(Path.join(templates_dir, "**/*.eex"))
    hidden_files = Path.wildcard(Path.join(templates_dir, "**/.*eex"))

    (normal_files ++ hidden_files)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp generate_file_from_template(template_path, templates_dir, target_dir, binding) do
    # Calculate relative path from templates_dir
    relative_path = Path.relative_to(template_path, templates_dir)

    # Remove .eex extension for target file
    target_relative_path = String.replace_suffix(relative_path, ".eex", "")
    target_file_path = Path.join(target_dir, target_relative_path)

    # Ensure target directory exists
    target_file_path
    |> Path.dirname()
    |> File.mkdir_p!()

    # Read template and evaluate
    try do
      template_content = File.read!(template_path)
      evaluated_content = EEx.eval_string(template_content, binding)

      # Write the evaluated content
      File.write!(target_file_path, evaluated_content)

      # Set executable permissions for script files
      if String.ends_with?(target_file_path, ".sh") do
        File.chmod!(target_file_path, 0o755)
      end

      Mix.shell().info("✅ Generated #{target_relative_path}")
    rescue
      error ->
        Mix.shell().error("❌ Failed to generate #{target_relative_path}: #{inspect(error)}")
        reraise error, __STACKTRACE__
    end
  end

  defp create_additional_directories(app) do
    # Create any additional directories that might not be covered by templates
    essential_dirs = [
      Path.join([app, "rootfs_overlay", "etc"]),
      Path.join([app, "rootfs_overlay", "root"]),
      Path.join([app, "fwup_include"])
    ]

    Enum.each(essential_dirs, &File.mkdir_p!/1)
  end

  defp get_architecture({toolchain_name, _version}) do
    toolchain_string = to_string(toolchain_name)

    cond do
      String.contains?(toolchain_string, "aarch64") -> "aarch64"
      String.contains?(toolchain_string, "arm") -> "arm"
      String.contains?(toolchain_string, "x86_64") -> "x86_64"
      String.contains?(toolchain_string, "x86") -> "x86"
      String.contains?(toolchain_string, "riscv64") -> "riscv64"
      true -> "unknown"
    end
  end

  defp format_board_description(board) do
    board
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp format_toolchain_dep({toolchain_name, version}) do
    toolchain_string =
      toolchain_name
      |> to_string()
      |> String.replace("nerves_toolchain_", "")
      |> String.replace("_", "-")

    "#{toolchain_string} #{version}"
  end

  defp format_toolchain_dep_string({toolchain_name, version}) do
    "{:#{toolchain_name}, \"#{version}\", runtime: false}"
  end

  defp get_target_gcc_flags(arch_config) do
    case arch_config.arch do
      "aarch64" ->
        "-mabi=lp64 -fstack-protector-strong -mcpu=cortex-a53 -fPIE -pie -Wl,-z,now -Wl,-z,relro"

      "arm" ->
        "-mthumb -mfpu=neon-vfpv4 -mfloat-abi=hard -mcpu=cortex-a7 -fstack-protector-strong -fPIE -pie -Wl,-z,now -Wl,-z,relro"

      "x86_64" ->
        "-m64 -march=x86-64 -fstack-protector-strong -fPIE -pie -Wl,-z,now -Wl,-z,relro"

      "riscv64" ->
        "-march=rv64imafdc -mabi=lp64d -fstack-protector-strong -fPIE -pie -Wl,-z,now -Wl,-z,relro"

      _ ->
        "-fstack-protector-strong -fPIE -pie -Wl,-z,now -Wl,-z,relro"
    end
  end

  defp get_uboot_arch(platform_config) do
    # Map platform configurations to U-Boot architecture names for mkimage
    case platform_config.platform do
      p when p in [:generic_arm64] -> "arm64"
      p when p in [:generic_arm, :rpi, :sunxi_spl, :sunxi_standard] -> "arm"
      :x86_64 -> "x86_64"
      :riscv64 -> "riscv64"
      # Default fallback
      _ -> "arm"
    end
  end

  defp analyze_and_update_platform_config(platform_config, buildroot_path, board, defconfig_path) do
    # Try to find board directory: first from defconfig content, then by name matching
    board_dir =
      extract_board_dir_from_defconfig(buildroot_path, defconfig_path) ||
        find_buildroot_board_directory(buildroot_path, board)

    case board_dir do
      nil ->
        Mix.shell().info("No buildroot board directory found for #{board}, using defaults")
        platform_config

      dir ->
        detect_partition_scheme(platform_config, dir)
    end
  end

  # Extracts the board directory from defconfig content by looking at
  # BR2_ROOTFS_POST_BUILD_SCRIPT, BR2_LINUX_KERNEL_CUSTOM_CONFIG_FILE, etc.
  # These paths explicitly reference the board directory (e.g., "board/qemu/x86_64/post-build.sh").
  defp extract_board_dir_from_defconfig(buildroot_path, defconfig_path) do
    content = File.read!(defconfig_path)

    # Try multiple keys that reference board directories
    board_path_patterns = [
      ~r/BR2_ROOTFS_POST_BUILD_SCRIPT="([^"]*board\/[^"]+)"/,
      ~r/BR2_LINUX_KERNEL_CUSTOM_CONFIG_FILE="([^"]*board\/[^"]+)"/,
      ~r/BR2_ROOTFS_POST_IMAGE_SCRIPT="([^"]*board\/[^"]+)"/
    ]

    board_dir =
      Enum.find_value(board_path_patterns, fn pattern ->
        case Regex.run(pattern, content) do
          [_, path] ->
            # Extract the board directory from the file path
            # e.g., "board/qemu/x86_64-efi/post-build.sh" -> "board/qemu/x86_64-efi"
            # Handle space-separated lists (e.g., "board/a/post.sh board/b/post.sh")
            first_path = path |> String.split(" ") |> Enum.find(&String.contains?(&1, "board/"))

            if first_path do
              Path.dirname(first_path)
            end

          _ ->
            nil
        end
      end)

    if board_dir do
      full_path = Path.join(buildroot_path, board_dir)

      if File.dir?(full_path) do
        Mix.shell().info("Found board directory from defconfig: #{board_dir}")
        full_path
      else
        nil
      end
    end
  end

  defp detect_partition_scheme(platform_config, board_dir) do
    # Buildroot uses both genimage.cfg and genimage.cfg.in templates
    genimage_files =
      Path.wildcard(Path.join(board_dir, "genimage*.cfg")) ++
        Path.wildcard(Path.join(board_dir, "genimage*.cfg.in"))

    if length(genimage_files) > 0 do
      genimage_file = hd(genimage_files)
      content = File.read!(genimage_file)

      partition_scheme =
        cond do
          String.contains?(content, "gpt = true") or
              String.contains?(content, "partition-table-type = \"gpt\"") ->
            :gpt

          String.contains?(content, "efi") ->
            :efi

          true ->
            :mbr
        end

      Mix.shell().info(
        "Detected #{partition_scheme} partition scheme from #{Path.basename(genimage_file)}"
      )

      Map.put(platform_config, :partition_scheme, partition_scheme)
    else
      Mix.shell().info("No genimage config found in #{board_dir}, using defaults")
      platform_config
    end
  end

  defp copy_buildroot_board_files(buildroot_path, board, app, binding) do
    platform_config = binding[:platform_config]

    # Find buildroot board directory
    case find_buildroot_board_directory(buildroot_path, board) do
      nil ->
        Mix.shell().info("No buildroot board directory found for #{board}")
        # Generate fallback boot config if platform needs it
        generate_fallback_boot_config(app, platform_config, binding)

      board_dir ->
        ensure_boot_config(board_dir, app, platform_config, binding)
    end
  end

  defp find_buildroot_board_directory(buildroot_path, board) do
    board_base_dir = Path.join(buildroot_path, "board")

    if File.dir?(board_base_dir) do
      # List all directories first for debugging
      all_dirs = Path.wildcard(Path.join(board_base_dir, "**/"))

      # Search recursively for directories containing genimage.cfg(.in) or boot.cmd
      # This approach is generic and will work for any board layout
      relevant_dirs =
        all_dirs
        |> Enum.filter(fn dir ->
          # Check if directory contains files we're interested in
          has_genimage =
            length(Path.wildcard(Path.join(dir, "genimage*.cfg"))) > 0 or
              length(Path.wildcard(Path.join(dir, "genimage*.cfg.in"))) > 0

          has_boot_cmd = File.exists?(Path.join(dir, "boot.cmd"))
          has_genimage or has_boot_cmd
        end)
        |> Enum.map(&String.trim_trailing(&1, "/"))

      case relevant_dirs do
        [] ->
          nil

        dirs ->
          find_best_board_match(dirs, board)
      end
    else
      nil
    end
  end

  defp find_best_board_match(dirs, board) do
    # Try to find the directory that best matches the board name.
    # Convert board name variations: arduino_uno_q -> arduino-uno-q, etc.
    board_patterns = [
      board,
      String.replace(board, "_", "-"),
      String.replace(board, "_", ""),
      String.replace(board, "_defconfig", "")
    ]

    # Extract meaningful board parts (e.g., "qemu_x86_64" -> ["qemu", "x86_64"])
    board_parts =
      board
      |> String.replace("_defconfig", "")
      |> String.split("_")

    # First, try exact basename match (dir name == pattern)
    exact_match =
      Enum.find(dirs, fn dir ->
        dir_name = Path.basename(dir)
        Enum.any?(board_patterns, &(&1 == dir_name))
      end)

    if exact_match do
      exact_match
    else
      # Try to find dirs where the last path component exactly matches
      # a significant board part (e.g., "x86_64" matches board/qemu/x86_64/
      # but NOT board/qemu/x86_64-efi/)
      segment_match =
        Enum.find(dirs, fn dir ->
          dir_name = Path.basename(dir)

          Enum.any?(board_parts, fn part ->
            dir_name == part
          end)
        end)

      if segment_match do
        segment_match
      else
        # Substring match in full path, ordered by specificity
        # Prefer dirs whose basename contains a board pattern as a substring
        partial_match =
          Enum.find(dirs, fn dir ->
            dir_name = Path.basename(dir)

            Enum.any?(board_patterns, fn pattern ->
              String.contains?(dir_name, pattern)
            end)
          end)

        if partial_match do
          partial_match
        else
          path_match =
            Enum.find(dirs, fn dir ->
              Enum.any?(board_patterns, fn pattern ->
                String.contains?(dir, pattern)
              end)
            end)

          path_match
        end
      end
    end
  end

  # Ensure boot configuration exists for the platform.
  # If the Buildroot board directory has a boot.cmd, copy it.
  # Otherwise, generate a fallback appropriate for the platform.
  defp ensure_boot_config(board_dir, app, platform_config, binding) do
    boot_cmd_source = Path.join(board_dir, "boot.cmd")

    if File.exists?(boot_cmd_source) do
      uboot_dir = Path.join([app, "uboot"])
      File.mkdir_p!(uboot_dir)

      boot_cmd_dest = Path.join(uboot_dir, "boot.cmd")
      File.cp!(boot_cmd_source, boot_cmd_dest)
      Mix.shell().info("Copied boot.cmd from Buildroot board directory")
    else
      generate_fallback_boot_config(app, platform_config, binding)
    end
  end

  # Generate platform-appropriate fallback boot configuration when the
  # Buildroot board directory doesn't provide one.
  defp generate_fallback_boot_config(app, platform_config, binding) do
    case platform_config.platform do
      p when p in [:x86_64] ->
        generate_extlinux_conf(app, platform_config, binding)

      p when p in [:rpi] ->
        # RPi uses its own proprietary bootloader (start4.elf), no boot.cmd needed
        :ok

      _ ->
        # U-Boot platforms get a fallback boot.cmd
        generate_fallback_boot_cmd(app, platform_config, binding)
    end
  end

  # Generate a fallback boot.cmd for U-Boot platforms.
  # This creates a Nerves-compatible A/B boot script.
  defp generate_fallback_boot_cmd(app, platform_config, binding) do
    dtb_name = platform_config.dtb_name
    kernel_name = platform_config.kernel_name
    dtso_names = binding[:dtso_names] || []

    kernel_addr = get_kernel_load_addr(platform_config)
    fdt_addr = get_fdt_load_addr(platform_config)
    ramdisk_addr = "-"

    boot_cmd = """
    # Nerves U-Boot boot script
    # Auto-generated — customize as needed for your board
    #
    # This script implements A/B partition switching for Nerves firmware updates.

    # Determine active partition
    if test "${nerves_fw_active}" = "b"; then
        setenv bootpart ${BOOT_B_PART_OFFSET}
        setenv rootpart ${ROOTFS_B_PART_OFFSET}
    else
        setenv bootpart ${BOOT_A_PART_OFFSET}
        setenv rootpart ${ROOTFS_A_PART_OFFSET}
    fi

    setenv bootargs console=${console} root=/dev/mmcblk0p${rootpart} rootfstype=squashfs rootwait

    # Load kernel
    fatload mmc 0:${bootpart} #{kernel_addr} #{kernel_name}
    #{if dtb_name do
      "# Load device tree\nfatload mmc 0:${bootpart} #{fdt_addr} #{dtb_name}"
    else
      "# No device tree for this platform"
    end}
    #{Enum.map_join(dtso_names, "\n", fn dtso -> "# Load device tree overlay: #{dtso}\nfatload mmc 0:${bootpart} ${fdtoverlay_addr_r} #{dtso}\nfdt apply ${fdtoverlay_addr_r}" end)}

    # Boot
    #{get_boot_command(platform_config, kernel_addr, fdt_addr, ramdisk_addr)}
    """

    uboot_dir = Path.join([app, "uboot"])
    File.mkdir_p!(uboot_dir)
    boot_cmd_path = Path.join(uboot_dir, "boot.cmd")
    File.write!(boot_cmd_path, boot_cmd)
    Mix.shell().info("Generated fallback boot.cmd for #{platform_config.platform}")
  end

  # Generate extlinux.conf for x86_64/EFI platforms that use syslinux-style boot.
  defp generate_extlinux_conf(app, platform_config, _binding) do
    kernel_name = platform_config.kernel_name

    extlinux_conf = """
    # Nerves extlinux boot configuration
    # Auto-generated — customize as needed
    DEFAULT nerves
    TIMEOUT 0

    LABEL nerves
        LINUX /#{kernel_name}
        APPEND root=/dev/sda2 rootfstype=squashfs rootwait console=ttyS0,115200
    """

    # extlinux.conf is typically placed in the boot partition,
    # but for Nerves we put it in the rootfs overlay for the post-build
    # script to copy to the right place
    extlinux_dir = Path.join([app, "rootfs_overlay", "boot", "extlinux"])
    File.mkdir_p!(extlinux_dir)
    extlinux_path = Path.join(extlinux_dir, "extlinux.conf")
    File.write!(extlinux_path, String.trim_leading(extlinux_conf))
    Mix.shell().info("Generated extlinux.conf for EFI/x86_64 platform")
  end

  defp get_kernel_load_addr(platform_config) do
    case platform_config.platform do
      p when p in [:generic_arm64] -> "0x44000000"
      p when p in [:generic_arm, :sunxi_spl, :sunxi_standard] -> "0x42000000"
      :riscv64 -> "0x84000000"
      _ -> "0x42000000"
    end
  end

  defp get_fdt_load_addr(platform_config) do
    case platform_config.platform do
      p when p in [:generic_arm64] -> "0x4a000000"
      p when p in [:generic_arm, :sunxi_spl, :sunxi_standard] -> "0x43000000"
      :riscv64 -> "0x86000000"
      _ -> "0x43000000"
    end
  end

  defp get_boot_command(platform_config, kernel_addr, fdt_addr, ramdisk_addr) do
    case platform_config.platform do
      p when p in [:generic_arm64] ->
        "booti #{kernel_addr} #{ramdisk_addr} #{fdt_addr}"

      p when p in [:generic_arm, :sunxi_spl, :sunxi_standard] ->
        "bootz #{kernel_addr} #{ramdisk_addr} #{fdt_addr}"

      :riscv64 ->
        "booti #{kernel_addr} #{ramdisk_addr} #{fdt_addr}"

      _ ->
        "bootm #{kernel_addr} #{ramdisk_addr} #{fdt_addr}"
    end
  end

  # Functions for extracting device tree overlay names

  defp extract_dtso_names(nerves_defconfig_path) do
    if File.exists?(nerves_defconfig_path) do
      content = File.read!(nerves_defconfig_path)

      case Regex.run(~r/BR2_LINUX_KERNEL_INTREE_DTSO_NAMES="([^"]+)"/, content) do
        [_, dtso_names_str] ->
          # Split by spaces and convert paths to just filenames with .dtbo extension
          dtso_names_str
          |> String.split(" ", trim: true)
          |> Enum.map(fn dtso_path ->
            # Convert "qcom/qrb2210-arduino-imola-gigadisplay" to "qrb2210-arduino-imola-gigadisplay.dtbo"
            Path.basename(dtso_path) <> ".dtbo"
          end)

        _ ->
          []
      end
    else
      []
    end
  end

  # Generate random GUID for GPT partitions
  defp generate_guid do
    bytes = :crypto.strong_rand_bytes(16)
    <<a::32, b::16, c::16, d::16, e::48>> = bytes

    # Set version (4) and variant bits according to RFC 4122
    # Version 4
    c = (c &&& 0x0FFF) ||| 0x4000
    # Variant 10
    d = (d &&& 0x3FFF) ||| 0x8000

    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
    |> List.to_string()
    |> String.downcase()
  end

  # Copy custom packages from an external tree into the generated system.
  # Returns a list of package name strings that were copied.
  defp copy_custom_packages(_app, nil), do: []

  defp copy_custom_packages(app, external_path) do
    package_dir = Path.join(external_path, "package")

    if File.dir?(package_dir) do
      package_dir
      |> File.ls!()
      |> Enum.filter(fn entry ->
        Path.join(package_dir, entry) |> File.dir?()
      end)
      |> Enum.filter(fn pkg_name ->
        # Only copy packages that have at least a .mk file (valid Buildroot package)
        mk_files = Path.wildcard(Path.join([package_dir, pkg_name, "*.mk"]))
        length(mk_files) > 0
      end)
      |> Enum.map(fn pkg_name ->
        src = Path.join(package_dir, pkg_name)
        dest = Path.join([app, "package", pkg_name])
        File.mkdir_p!(dest)

        # Copy all files and subdirectories in the package directory
        src
        |> File.ls!()
        |> Enum.each(fn file ->
          src_file = Path.join(src, file)
          dest_file = Path.join(dest, file)

          if File.dir?(src_file) do
            File.cp_r!(src_file, dest_file)
          else
            File.cp!(src_file, dest_file)
          end
        end)

        Mix.shell().info("Copied custom package: #{pkg_name}")
        pkg_name
      end)
      |> Enum.sort()
    else
      []
    end
  end

  # Derives a "~> major.minor" version requirement from the nerves_system_br
  # VERSION file so the generated system pins the same Buildroot release that
  # the bootstrap tool used to select the kernel version.
  defp nerves_system_br_version_req do
    br_path = NervesBootstrap.BuildrootManager.nerves_system_br_path()
    version_file = Path.join(br_path, "VERSION")

    if File.exists?(version_file) do
      version = version_file |> File.read!() |> String.trim()

      case String.split(version, ".") do
        [major, minor | _] -> "~> #{major}.#{minor}"
        _ -> "~> 1.33"
      end
    else
      "~> 1.33"
    end
  end

  # Detect GitHub organization/user from the git remote URL of the current
  # working directory. Falls back to "CHANGE-ME" if no remote is found.
  defp detect_github_organization do
    case System.cmd("git", ["remote", "get-url", "origin"], stderr_to_stdout: true) do
      {url, 0} ->
        url = String.trim(url)

        org =
          cond do
            # SSH: git@github.com:org/repo.git
            String.contains?(url, "github.com:") ->
              url
              |> String.split("github.com:")
              |> List.last()
              |> String.split("/")
              |> List.first()

            # HTTPS: https://github.com/org/repo.git
            String.contains?(url, "github.com/") ->
              url
              |> String.split("github.com/")
              |> List.last()
              |> String.split("/")
              |> List.first()

            true ->
              nil
          end

        if org && org != "" do
          org
        else
          "CHANGE-ME"
        end

      _ ->
        "CHANGE-ME"
    end
  end

  # Generate GUIDs for all partitions based on platform configuration
  defp generate_partition_guids(platform_config) do
    partition_scheme = Map.get(platform_config, :partition_scheme, :mbr)

    case partition_scheme do
      scheme when scheme in [:gpt, :efi] ->
        %{
          # Disk GUID
          disk_guid: generate_guid(),
          # Partition GUIDs
          boot_a_guid: generate_guid(),
          boot_b_guid: generate_guid(),
          rootfs_a_guid: generate_guid(),
          rootfs_b_guid: generate_guid(),
          app_guid: generate_guid()
        }

      _ ->
        # MBR doesn't need GUIDs
        %{}
    end
  end
end
