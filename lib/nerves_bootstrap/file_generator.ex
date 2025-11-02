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
  def generate_files(app, board, module_name, toolchain_dep, buildroot_path) do
    # Prepare template binding variables
    binding = prepare_template_binding(app, board, module_name, toolchain_dep, buildroot_path)

    # Generate files from templates
    generate_from_templates(app, binding)

    # Copy additional files from buildroot board directory
    copy_buildroot_board_files(buildroot_path, board, app)

    # Create additional directories that might be needed
    create_additional_directories(app)
  end

  defp prepare_template_binding(app, board, module_name, toolchain_dep, buildroot_path) do
    defconfig_path = Path.join([buildroot_path, "configs", "#{board}_defconfig"])
    nerves_defconfig_path = Path.join(app, "nerves_defconfig")
    platform_config = NervesBootstrap.PlatformDetector.detect_platform_config(defconfig_path)
    arch_config = NervesBootstrap.PlatformDetector.get_arch_config(toolchain_dep)

    # Analyze genimage config to update platform_config with partition scheme
    platform_config = analyze_and_update_platform_config(platform_config, buildroot_path, board)

    # Extract DTSO names from nerves_defconfig if it exists
    dtso_names = extract_dtso_names(nerves_defconfig_path)

    # Generate GUIDs for GPT partitions
    partition_guids = generate_partition_guids(platform_config)

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
      dep_string: fn {name, version} -> "{:#{name}, \"#{version}\", runtime: false}" end,
      architecture: get_architecture(toolchain_dep),
      github_organization: "my-org",  # This could be configurable
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
    toolchain_string = toolchain_name
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
      p when p in [:generic_arm64, :rpi4] -> "arm64"
      p when p in [:generic_arm, :rpi, :sunxi_spl, :sunxi_standard] -> "arm"
      :x86_64 -> "x86_64"
      :riscv64 -> "riscv64"
      _ -> "arm"  # Default fallback
    end
  end

  defp analyze_and_update_platform_config(platform_config, buildroot_path, board) do
    # Find buildroot board directory
    case find_buildroot_board_directory(buildroot_path, board) do
      nil ->
        IO.puts("Warning: No buildroot board directory found for #{board}")
        platform_config

      board_dir ->
        # Look for genimage configuration files
        genimage_files = Path.wildcard(Path.join(board_dir, "genimage*.cfg"))

        if length(genimage_files) > 0 do
          genimage_file = hd(genimage_files)
          content = File.read!(genimage_file)

          # Detect partition scheme
          partition_scheme = cond do
            String.contains?(content, "gpt = true") or String.contains?(content, "partition-table-type = \"gpt\"") ->
              :gpt
            String.contains?(content, "efi") ->
              :efi
            true ->
              :mbr
          end

          IO.puts("✓ Detected #{partition_scheme} partition scheme from #{Path.basename(genimage_file)}")

          # Update platform_config with detected partition scheme
          Map.put(platform_config, :partition_scheme, partition_scheme)
        else
          IO.puts("Info: No genimage config files found in #{board_dir}, using default MBR")
          platform_config
        end
    end
  end

  defp copy_buildroot_board_files(buildroot_path, board, app) do
    # Find buildroot board directory
    case find_buildroot_board_directory(buildroot_path, board) do
      nil ->
        IO.puts("Warning: No buildroot board directory found for #{board}")

      board_dir ->
        copy_boot_cmd_if_exists(board_dir, app)
    end
  end

  defp find_buildroot_board_directory(buildroot_path, board) do
    board_base_dir = Path.join(buildroot_path, "board")

    if File.dir?(board_base_dir) do
      # List all directories first for debugging
      all_dirs = Path.wildcard(Path.join(board_base_dir, "**/"))

      # Search recursively for directories containing genimage.cfg or boot.cmd
      # This approach is generic and will work for any board layout
      relevant_dirs = all_dirs
      |> Enum.filter(fn dir ->
        # Check if directory contains files we're interested in
        has_genimage = length(Path.wildcard(Path.join(dir, "genimage*.cfg"))) > 0
        has_boot_cmd = File.exists?(Path.join(dir, "boot.cmd"))
        has_genimage or has_boot_cmd
      end)
      |> Enum.map(&String.trim_trailing(&1, "/"))

      case relevant_dirs do
        [] ->
          IO.puts("Debug: No directories with genimage.cfg or boot.cmd found in #{board_base_dir}")
          nil
        dirs ->
          # Find the best matching directory for the board
          best_match = find_best_board_match(dirs, board)
          IO.puts("Debug: Using board directory: #{best_match}")
          best_match
      end
    else
      IO.puts("Debug: Board base directory #{board_base_dir} does not exist")
      nil
    end
  end

  defp find_best_board_match(dirs, board) do
    # Try to find the directory that best matches the board name
    # Convert board name variations: arduino_uno_q -> arduino-uno-q, etc.
    board_patterns = [
      board,                                    # arduino_uno_q
      String.replace(board, "_", "-"),          # arduino-uno-q
      String.replace(board, "_", ""),           # arduinounoq
      String.replace(board, "_defconfig", "")   # remove _defconfig if present
    ]
    # First, try exact matches in directory names
    exact_match = Enum.find(dirs, fn dir ->
      dir_name = Path.basename(dir)
      Enum.any?(board_patterns, fn pattern ->
        String.contains?(dir_name, pattern)
      end)
    end)

    if exact_match do
      IO.puts("Debug: Found exact match: #{exact_match}")
      exact_match
    else
      # If no exact match, try partial matches in full path
      partial_match = Enum.find(dirs, fn dir ->
        Enum.any?(board_patterns, fn pattern ->
          String.contains?(dir, pattern)
        end)
      end)

      if partial_match do
        IO.puts("Debug: Found partial match: #{partial_match}")
        partial_match
      else
        # Fallback to first directory
        first_dir = hd(dirs)
        IO.puts("Debug: No match found, using first directory: #{first_dir}")
        first_dir
      end
    end
  end

  defp copy_boot_cmd_if_exists(board_dir, app) do
    boot_cmd_source = Path.join(board_dir, "boot.cmd")

    if File.exists?(boot_cmd_source) do
      # Create uboot directory in the generated system
      uboot_dir = Path.join([app, "uboot"])
      File.mkdir_p!(uboot_dir)

      # Copy boot.cmd to uboot directory
      boot_cmd_dest = Path.join(uboot_dir, "boot.cmd")
      File.cp!(boot_cmd_source, boot_cmd_dest)

      IO.puts("✓ Copied boot.cmd from #{boot_cmd_source} to #{boot_cmd_dest}")
    else
      IO.puts("Info: No boot.cmd found in #{board_dir} - will use U-Boot default behavior")
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
    c = (c &&& 0x0fff) ||| 0x4000  # Version 4
    d = (d &&& 0x3fff) ||| 0x8000  # Variant 10

    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
    |> List.to_string()
    |> String.downcase()
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
        %{} # MBR doesn't need GUIDs
    end
  end
end
