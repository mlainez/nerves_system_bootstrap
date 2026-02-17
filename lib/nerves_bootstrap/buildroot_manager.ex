defmodule NervesBootstrap.BuildrootManager do
  @moduledoc """
  Handles Buildroot repository management, including downloading, path resolution,
  and validation of Buildroot configurations.

  For the default (non-fork) path, this module leverages nerves_system_br's
  `download-buildroot.sh` to download the correct Buildroot version as a tarball
  (using the `~/.nerves/dl` cache), then applies nerves_system_br's patches
  via Buildroot's own `apply-patches.sh`. This ensures the Buildroot tree
  matches exactly what a real Nerves build uses.

  When `--buildroot-url` or `--buildroot` is specified, the fork/local path
  is used directly (git clone for URLs, passthrough for local paths).
  """

  @doc """
  Determines the Buildroot path from options, downloading if necessary.
  Returns the absolute path to the Buildroot source tree.
  """
  def determine_buildroot(opts) do
    cond do
      buildroot = opts[:buildroot] ->
        # Local path — use directly
        Path.expand(buildroot)

      url = opts[:buildroot_url] ->
        # Fork URL — git clone as before
        path = "buildroot"
        branch = opts[:buildroot_branch]
        clone_buildroot_fork(url, path, branch)
        Path.expand(path)

      true ->
        # Default: use nerves_system_br's download pipeline
        download_via_nerves_system_br()
    end
  end

  @doc """
  Returns the path to the nerves_system_br dependency.
  Tries Mix.Project dep paths first, falls back to well-known locations.
  """
  def nerves_system_br_path do
    # Try Mix.Project.deps_paths if available
    paths =
      try do
        Mix.Project.deps_paths()
      rescue
        _ -> %{}
      end

    case Map.get(paths, :nerves_system_br) do
      nil ->
        # Fallback: look in deps/nerves_system_br relative to project root
        fallback = Path.join([File.cwd!(), "deps", "nerves_system_br"])

        if File.dir?(fallback) do
          fallback
        else
          Mix.raise("""
          Could not find nerves_system_br dependency.

          Ensure your mix.exs includes {:nerves_system_br, "~> 1.20", runtime: false}
          and run `mix deps.get` first.
          """)
        end

      path ->
        to_string(path)
    end
  end

  @doc """
  Gets the Buildroot version used by nerves_system_br.
  Extracts NERVES_BR_VERSION from create-build.sh.
  """
  def get_nerves_br_version do
    br_path = nerves_system_br_path()
    create_build_script = Path.join(br_path, "create-build.sh")

    if File.exists?(create_build_script) do
      create_build_script
      |> File.read!()
      |> extract_buildroot_version()
    else
      Mix.shell().error(
        "nerves_system_br create-build.sh not found, using default version 2025.05"
      )

      "2025.05"
    end
  end

  @doc """
  Validates that a defconfig exists for the given board.
  """
  def validate_board_defconfig(buildroot_path, board) do
    defconfig = Path.join([buildroot_path, "configs", "#{board}_defconfig"])

    unless File.exists?(defconfig) do
      Mix.raise("Could not find #{board}_defconfig in #{buildroot_path}/configs")
    end

    defconfig
  end

  # ---------------------------------------------------------------------------
  # Default path: leverage nerves_system_br
  # ---------------------------------------------------------------------------

  defp download_via_nerves_system_br do
    br_path = nerves_system_br_path()
    version = get_nerves_br_version()

    # Use nerves_system_br's download cache directory
    dl_dir = nerves_dl_dir()
    File.mkdir_p!(dl_dir)

    symlink_path = Path.join(br_path, "buildroot")

    # Check state to see if we can skip download + patch
    if buildroot_up_to_date?(br_path, version) do
      Mix.shell().info("Buildroot #{version} already downloaded and patched (cached)")
      symlink_path
    else
      Mix.shell().info("Downloading Buildroot #{version} via nerves_system_br...")

      # Clean up any previous Buildroot trees inside nerves_system_br
      cleanup_old_buildroot(br_path)

      # Step 1: Download tarball using nerves_system_br's script
      download_script = Path.join([br_path, "scripts", "download-buildroot.sh"])

      unless File.exists?(download_script) do
        Mix.raise("Cannot find download-buildroot.sh at #{download_script}")
      end

      case System.cmd("bash", [download_script, version, dl_dir, br_path], stderr_to_stdout: true) do
        {output, 0} ->
          Mix.shell().info(output)

        {output, code} ->
          Mix.raise("download-buildroot.sh failed (exit #{code}):\n#{output}")
      end

      # Step 2: Apply Nerves-specific patches using Buildroot's own apply-patches.sh
      apply_patches_script =
        Path.join([symlink_path, "support", "scripts", "apply-patches.sh"])

      patches_dir = Path.join([br_path, "patches", "buildroot"])

      if File.exists?(apply_patches_script) and File.dir?(patches_dir) do
        Mix.shell().info("Applying nerves_system_br patches to Buildroot...")

        case System.cmd("bash", [apply_patches_script, symlink_path, patches_dir],
               stderr_to_stdout: true
             ) do
          {_output, 0} ->
            Mix.shell().info("Applied Nerves patches to Buildroot #{version}")

          {output, code} ->
            Mix.raise("apply-patches.sh failed (exit #{code}):\n#{output}")
        end
      else
        Mix.shell().error(
          "Could not find apply-patches.sh or patches directory, skipping patching"
        )
      end

      # Step 3: Symlink download cache into Buildroot's dl directory
      buildroot_dl = Path.join(symlink_path, "dl")

      unless File.exists?(buildroot_dl) do
        File.ln_s!(dl_dir, buildroot_dl)
      end

      # Step 4: Write state file so we can skip next time
      write_buildroot_state(br_path, version)

      Mix.shell().info("Buildroot #{version} ready at #{symlink_path}")
      symlink_path
    end
  end

  # Returns the Nerves download cache directory (~/.nerves/dl by default)
  @doc """
  Returns the Nerves download cache directory.
  Respects the `NERVES_BR_DL_DIR` environment variable; defaults to `~/.nerves/dl`.
  """
  def nerves_dl_dir do
    System.get_env("NERVES_BR_DL_DIR") || Path.join([System.user_home!(), ".nerves", "dl"])
  end

  # Check if the Buildroot tree is already set up with the right version + patches
  defp buildroot_up_to_date?(br_path, version) do
    symlink_path = Path.join(br_path, "buildroot")
    state_file = Path.join([br_path, "buildroot-#{version}", ".nerves-br-state"])

    unless File.exists?(symlink_path) and File.exists?(state_file) do
      false
    else
      # Compare state fingerprint
      state_script = Path.join([br_path, "scripts", "buildroot-state.sh"])
      patches_dir = Path.join([br_path, "patches", "buildroot"])

      if File.exists?(state_script) and File.dir?(patches_dir) do
        case System.cmd("bash", [state_script, version, patches_dir], stderr_to_stdout: true) do
          {expected_state, 0} ->
            current_state = File.read!(state_file)
            String.trim(current_state) == String.trim(expected_state)

          _ ->
            false
        end
      else
        # Can't verify state — assume stale
        false
      end
    end
  end

  # Write state fingerprint for future cache checks
  defp write_buildroot_state(br_path, version) do
    state_script = Path.join([br_path, "scripts", "buildroot-state.sh"])
    patches_dir = Path.join([br_path, "patches", "buildroot"])
    state_file = Path.join([br_path, "buildroot-#{version}", ".nerves-br-state"])

    if File.exists?(state_script) and File.dir?(patches_dir) do
      case System.cmd("bash", [state_script, version, patches_dir], stderr_to_stdout: true) do
        {state, 0} ->
          File.write!(state_file, state)

        _ ->
          :ok
      end
    end
  end

  # Remove old buildroot-* directories and the buildroot symlink
  defp cleanup_old_buildroot(br_path) do
    # Remove symlink
    symlink = Path.join(br_path, "buildroot")

    if File.exists?(symlink) or is_symlink?(symlink) do
      File.rm!(symlink)
    end

    # Remove any buildroot-* extraction directories
    br_path
    |> File.ls!()
    |> Enum.filter(&String.starts_with?(&1, "buildroot-"))
    |> Enum.each(fn dir ->
      File.rm_rf!(Path.join(br_path, dir))
    end)
  end

  defp is_symlink?(path) do
    case File.lstat(path) do
      {:ok, %{type: :symlink}} -> true
      _ -> false
    end
  end

  # ---------------------------------------------------------------------------
  # Fork path: git clone
  # ---------------------------------------------------------------------------

  defp clone_buildroot_fork(url, path, branch_or_version) do
    if File.exists?(path) do
      current_url = get_git_remote_url(path)

      if current_url && normalize_git_url(current_url) == normalize_git_url(url) do
        Mix.shell().info("Buildroot already exists from correct repository: #{url}")
      else
        Mix.shell().info("Removing existing Buildroot (different repository)")
        File.rm_rf!(path)
        do_clone(url, path, branch_or_version)
      end
    else
      do_clone(url, path, branch_or_version)
    end
  end

  defp do_clone(url, path, nil) do
    Mix.shell().info("Cloning Buildroot from #{url}...")
    {_, 0} = System.cmd("git", ["clone", "--depth", "1", url, path])
    Mix.shell().info("Buildroot cloned to #{path}")
  end

  defp do_clone(url, path, branch) do
    Mix.shell().info("Downloading Buildroot #{branch} from #{url}...")
    {_, 0} = System.cmd("git", ["clone", "--branch", branch, "--depth", "1", url, path])
    Mix.shell().info("Buildroot #{branch} downloaded to #{path}")
  end

  defp get_git_remote_url(path) do
    case System.cmd("git", ["remote", "get-url", "origin"], cd: path, stderr_to_stdout: true) do
      {url, 0} -> String.trim(url)
      _ -> nil
    end
  end

  defp normalize_git_url(url) do
    url
    |> String.replace_suffix(".git", "")
    |> String.replace(~r{^https?://}, "")
    |> String.replace(~r{^git@([^:]+):}, "\\1/")
    |> String.downcase()
  end

  # ---------------------------------------------------------------------------
  # Version extraction
  # ---------------------------------------------------------------------------

  defp extract_buildroot_version(script_content) do
    case Regex.run(~r/NERVES_BR_VERSION=(.+)/, script_content) do
      [_, version] ->
        String.trim(version)

      _ ->
        Mix.shell().error(
          "Could not extract Buildroot version from nerves_system_br, using default 2025.05"
        )

        "2025.05"
    end
  end
end
