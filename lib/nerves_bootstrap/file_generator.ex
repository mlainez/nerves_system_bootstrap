defmodule NervesBootstrap.FileGenerator do
  @moduledoc """
  Generates all the necessary files for a Nerves system using EEx templates
  from priv/templates/nerves_system, including mix.exs, fwup configurations,
  build scripts, and overlay directories.
  """

  @doc """
  Generates all files for the Nerves system using templates.
  """
  def generate_files(app, board, module_name, toolchain_dep, buildroot_path) do
    # Prepare template binding variables
    binding = prepare_template_binding(app, board, module_name, toolchain_dep, buildroot_path)

    # Generate files from templates
    generate_from_templates(app, binding)

    # Create additional directories that might be needed
    create_additional_directories(app)
  end

  defp prepare_template_binding(app, board, module_name, toolchain_dep, buildroot_path) do
    defconfig_path = Path.join([buildroot_path, "configs", "#{board}_defconfig"])
    platform_config = NervesBootstrap.PlatformDetector.detect_platform_config(defconfig_path)
    arch_config = NervesBootstrap.PlatformDetector.get_arch_config(toolchain_dep)

    [
      app: app,
      board: board,
      module_name: module_name,
      toolchain_dep: format_toolchain_dep(toolchain_dep),
      toolchain_dep_string: format_toolchain_dep_string(toolchain_dep),
      toolchain_tuple: toolchain_dep,
      platform_config: platform_config,
      arch_config: arch_config,
      dep_string: fn {name, version} -> "{:#{name}, \"#{version}\", runtime: false}" end,
      architecture: get_architecture(toolchain_dep),
      github_organization: "my-org",  # This could be configurable
      board_description: format_board_description(board),
      target_arch: arch_config.arch,
      target_cpu: arch_config.target_cpu,
      target_abi: arch_config.abi,
      target_gcc_flags: get_target_gcc_flags(arch_config),
      external_buildroot: buildroot_path
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
    Path.wildcard(Path.join(templates_dir, "**/*.eex"))
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
end
